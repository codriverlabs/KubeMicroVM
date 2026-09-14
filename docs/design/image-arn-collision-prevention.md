# MicroVMImage ARN Collision Prevention

**Status**: Design — approved for implementation
**Target**: KubeMicroVM (Community webhook + reconciler); KubeMicroVM-PRO (integration, docs, UAT coverage)
**Related**: [images.md](images.md), [webhooks.md](webhooks.md), [KubeMicroVM-PRO/docs/design/cross-namespace-imageref.md](../../../KubeMicroVM-PRO/docs/design/cross-namespace-imageref.md)

---

## Problem

`MicroVMImage` is a namespaced Kubernetes resource, but the AWS Lambda MicroVM image
it manages is **not namespace-scoped** — it is identified by name within a single AWS
account + region:

```
arn:aws:lambda:<region>:<account-id>:microvm-image:<name>
```

`<name>` comes directly from `metadata.name` of the `MicroVMImage` CR
(`MicroVMImageClient.createImage(name, ...)`, confirmed in
`operator-controller/src/main/java/.../aws/MicroVMImageClient.java`). Nothing in the
CRD, the reconciler, or the webhook currently prevents two `MicroVMImage` CRs — in two
different namespaces — from sharing the same `metadata.name`, and therefore the same
AWS ARN.

### How the collision happens

1. Namespace `team-a` creates `MicroVMImage/shared-app`. The reconciler calls
   `create-microvm-image --name shared-app`, gets back
   `arn:...:microvm-image:shared-app`, and stores it in `status.imageArn`.
2. Namespace `team-b` — independently, with no knowledge of `team-a` — also creates
   `MicroVMImage/shared-app`. The reconciler's create path
   (`MicroVMImageReconciler.reconcile`, "CREATE (or ADOPT if already exists in AWS)"
   branch) calls `awsIdentity.constructImageArn(name)`, finds the AWS image already
   exists, and **silently adopts it**:
   ```java
   var existing = imageClient.getImage(expectedArn).get(...);
   LOG.infof("Adopting existing image %s  arn=%s state=%s", ...);
   status.setImageArn(existing.imageArn());
   ```
   No error, no warning, no event. Both CRs now report the same `status.imageArn` and
   believe they independently own it.
3. Later, `team-a` deletes its `MicroVMImage/shared-app` (e.g. as part of deleting its
   whole namespace). The finalizer's `cleanup()` calls `delete-microvm-image` on the
   shared ARN.
4. If `team-b` still has `MicroVM`/`MicroVMReplicaSet` resources with `Running` VMs
   built from that image, AWS correctly rejects the delete:
   ```
   ValidationException: Cannot delete microvm image with running microvms.
   ```
5. `cleanup()` catches this as a generic exception and retries unconditionally:
   ```java
   } catch (Exception e) {
       ...
       return DeleteControl.noFinalizerRemoval().rescheduleAfter(Duration.ofSeconds(15));
   }
   ```
   There is no exception-type discrimination (unlike `MicroVMReconciler`, which already
   classifies via `AwsApiException.ErrorType`), no capped backoff, and no status/event
   surfaced explaining *why* the delete is stuck.
6. Because the finalizer never completes, the `MicroVMImage` object never actually
   deletes, so `team-a`'s namespace — which contains it — never finishes deleting
   either. It sits in `Terminating` indefinitely.

### Confirmed in practice

Reproduced directly on a live cluster during UAT test development (KubeMicroVM-PRO
multi-tenant suite, 2026-09-11): a test-created tenant namespace stuck `Terminating`
for 2+ hours, with the operator retrying the same failing `delete-microvm-image` call
every ~15 seconds the entire time. `kubectl get namespace <ns> -o json` showed:

```
NamespaceFinalizersRemaining: true — lambda.aws.amazon.com/microvmimage-finalizer in 1 resource instances
```

and the operator logs showed the identical `ValidationException` on a ~15s loop with
no change in state.

### Why this isn't caught by the existing PRO cross-namespace sharing feature

KubeMicroVM-PRO already has a deliberate, governed mechanism for sharing one image
across namespaces: `spec.imageRef: <namespace>/<name>` on the *consumer*
(`MicroVM`/`MicroVMReplicaSet`), gated by `MicroVMImageBinding` and optional
`MicroVMImagePolicy` (see
[cross-namespace-imageref.md](../../../KubeMicroVM-PRO/docs/design/cross-namespace-imageref.md)).
That feature is unaffected by this issue — it never creates a second `MicroVMImage`
CR; it grants controlled read access to one canonical CR owned by a single catalog
namespace.

The collision described here happens only when two *independent* `MicroVMImage` CRs
are created with the same name in different namespaces — i.e., when a consumer
namespace bypasses the binding path and creates its own CR instead of referencing the
existing one. This is exactly what happened in the UAT test that surfaced this issue.

---

## Design Goals

1. **Fail fast, fail clearly.** A duplicate-name collision should be rejected at
   `kubectl apply` time with an actionable message, not discovered hours later as a
   stuck namespace.
2. **Never touch the AWS resource ownership model.** Exactly one `MicroVMImage` CR
   should ever be the AWS-side lifecycle owner (create/update/delete) of a given
   image ARN. Sharing must always go through the existing, governed
   `MicroVMImageBinding` path — never through a second same-named CR.
3. **Bounded-cost degradation for the cases admission can't catch.** A race between
   two near-simultaneous creates, or a legitimate delete blocked by live VMs
   elsewhere, must not degrade into an unbounded, silent retry loop. The state must be
   legible (`kubectl describe`, `kubectl get events`) and the retry cost must be
   capped.
4. **No breaking changes.** Do not alter how `metadata.name` maps to the AWS image
   name (that would break the existing cross-namespace-imageref feature's mental
   model of "one canonical image, one name"). Do not touch the finalizer-removal-on-
   deletion behavior added for the webhook fix in
   [webhook-fix.md](webhook-fix.md) — deleting objects must still skip validation.

### Rejected alternative: auto-namespace the AWS image name

One tempting fix is to derive the AWS image name from `<namespace>-<name>` (or a
hash), making collisions structurally impossible without any validation logic at all.

This is **rejected**. It would silently change the semantics of the existing
cross-namespace-imageref feature, whose entire value proposition is that a platform
team builds *one* AWS image and multiple tenant namespaces consume the *same* ARN.
Auto-namespacing would make every namespace build/own its own copy, defeating the
cost and governance model the PRO feature was explicitly designed around, and would
be a breaking rename for every existing Community/PRO installation.

---

## Solution: Three Layers of Defense

### Layer 1 — Admission webhook rejection at CREATE (primary defense)

Extend `MicroVMValidatingWebhook`'s existing `microvmimages` branch
(`operator-webhook/.../MicroVMValidatingWebhook.java`) to reject a `MicroVMImage`
CREATE if another `MicroVMImage` CR, in any *other* namespace, already resolves to
the same AWS ARN.

**Why this can be a cheap, synchronous, Kubernetes-only check**: the webhook does not
need to call AWS. `AwsIdentity.constructImageArn(name)` deterministically computes the
candidate ARN from `metadata.name` alone (region + account + name — no AWS API call).
The webhook only needs a cheap Kubernetes API `list` across namespaces for existing
`MicroVMImage` objects whose `status.imageArn` matches, which is the same style of
lookup the webhook already does for `MicroVMClass` (`validateClassName`) and
`MicroVMNetwork` (`validateNetworkRef`).

```java
void validateNoArnCollision(MicroVMImage image, String namespace, List<String> errors) {
    String name = image.getMetadata().getName();
    String candidateArn = awsIdentity.constructImageArn(name);
    if (candidateArn == null || kubernetesClient == null) return; // identity not resolved yet — skip, reconciler still protected by Layer 2

    var allImages = kubernetesClient.resources(MicroVMImage.class)
            .inAnyNamespace()
            .list()
            .getItems();

    for (MicroVMImage other : allImages) {
        String otherNs = other.getMetadata().getNamespace();
        if (namespace.equals(otherNs)) continue; // same-namespace update/re-apply is fine
        String otherArn = other.getStatus() != null ? other.getStatus().getImageArn() : null;
        if (candidateArn.equals(otherArn)) {
            errors.add(String.format(
                "MicroVMImage '%s' rejected: an image with this name already exists in " +
                "namespace '%s' (%s). To consume it from this namespace, use " +
                "spec.imageRef: '%s/%s' on your MicroVM/MicroVMReplicaSet and request a " +
                "MicroVMImageBinding from the owning namespace instead of creating a " +
                "duplicate MicroVMImage (see docs/design/image-arn-collision-prevention.md).",
                name, otherNs, otherArn, otherNs, name));
            return;
        }
    }
}
```

Call this from the existing `"microvmimages".equals(resource)` branch in `validate()`,
**only on CREATE** (matching-name UPDATE churn should not re-trigger this — the object
already owns its ARN by the time it can be updated).

Rejection message example surfaced to the user:

```
Error from server (Forbidden): error when creating "shared-app.yaml": admission
webhook "validate-microvm.kube-microvm.svc" denied the request: MicroVMImage
'shared-app' rejected: an image with this name already exists in namespace 'team-a'
(arn:aws:lambda:us-east-1:123456789012:microvm-image:shared-app). To consume it from
this namespace, use spec.imageRef: 'team-a/shared-app' on your
MicroVM/MicroVMReplicaSet and request a MicroVMImageBinding from the owning namespace
instead of creating a duplicate MicroVMImage.
```

This closes the collision at the point of user error, before any AWS API call is
made, before any status is written, and before any namespace can be put at future
risk of a stuck-Terminating state.

**Note on Community vs. PRO applicability**: this check is useful and correct in
*both* editions. Community has no cross-namespace `imageRef` syntax at all (plain
`name` only, always same-namespace), so a Community user hitting this rejection has
no sanctioned way to intentionally share images across namespaces yet — the message
should degrade gracefully to omit the "use spec.imageRef" suggestion when the PRO
feature is not installed. See [Community vs. PRO Behavior](#community-vs-pro-behavior)
below.

### Layer 2 — Reconciler: classify the delete-blocked error, cap the backoff, surface status (secondary defense)

Layer 1 cannot catch every case:

- A narrow creation race (two namespaces both pass admission before either observes
  the other — rare, but possible under concurrent load).
- The legitimate scenario this bug was originally discovered from: a `MicroVMImage`
  CR that has always been the sole owner of its ARN, being deleted while
  `MicroVM`/`MicroVMReplicaSet` resources *elsewhere* still reference it through the
  sanctioned PRO cross-namespace-imageref + binding path. That is not a bug — the
  image genuinely cannot be deleted yet — but the current unconditional-retry
  behavior is still wrong: it should be bounded-cost and legible, not a silent
  15-second infinite loop.

Change `MicroVMImageReconciler.cleanup()` to classify the delete exception instead of
treating every exception identically:

```java
@Override
public DeleteControl cleanup(MicroVMImage resource, Context<MicroVMImage> ctx) {
    ...
    try {
        imageClient.deleteImage(status.getImageArn()).get(TIMEOUT_S, TimeUnit.SECONDS);
    } catch (Exception e) {
        if (isNotFound(e)) {
            return DeleteControl.defaultDelete();
        }
        if (isDeleteBlockedByRunningVms(e)) {
            String reason = "Cannot delete: AWS reports running MicroVMs still reference this image";
            status.setLatestVersionStateReason(reason); // reuse existing surfaced-reason field
            emitEvent(resource, "DeleteBlocked", reason);
            LOG.warnf("Image %s delete blocked by running VMs — backing off: %s",
                    status.getImageArn(), e.getMessage());
            return DeleteControl.noFinalizerRemoval()
                    .rescheduleAfter(nextCappedBackoff(resource));
        }
        // Unknown/unexpected error — keep prior behavior but still cap backoff
        LOG.warnf("Error deleting image %s: %s — retrying", status.getImageArn(), e.getMessage());
        return DeleteControl.noFinalizerRemoval().rescheduleAfter(nextCappedBackoff(resource));
    }
    return DeleteControl.defaultDelete();
}

private boolean isDeleteBlockedByRunningVms(Throwable t) {
    Throwable cause = t.getCause() != null ? t.getCause() : t;
    String msg = cause.getMessage();
    return cause.getClass().getSimpleName().contains("ValidationException")
            && msg != null && msg.contains("running microvms");
}
```

**Capped exponential backoff** (`nextCappedBackoff`): 15s → 30s → 1m → 2m → 5m,
ceiling 5m — tracked via a counter annotation on the resource (e.g.
`lambda.aws.amazon.com/delete-retry-count`) so it survives operator restarts, cleared
on successful delete. This keeps the AWS API call rate bounded and the log volume
sane for a condition that can legitimately persist for hours (a long-lived shared
image with active consumers elsewhere), while still self-healing automatically once
those consumers are gone — no user action required in the success path.

**Kubernetes Event, not just a log line.** `emitEvent(resource, "DeleteBlocked", ...)`
means `kubectl describe microvmimage <name>` and `kubectl get events -n <namespace>`
both surface the reason immediately, rather than requiring the user to grep operator
pod logs (which is what was needed to diagnose this during the original
investigation).

**Explicitly not changed**: the finalizer must **not** be force-removed by this
logic. If the AWS image is still genuinely referenced by running VMs, the correct
behavior is to keep the namespace blocked from deleting until that's resolved — the
fix is making that state observable and cheap to hold, not bypassing it. (Contrast
with the unrelated, already-fixed issue in
[webhook-fix.md](webhook-fix.md), which was about the *validating webhook* wrongly
blocking finalizer-removal *patches* on objects already marked for deletion — a
different bug, not to be conflated with this one.)

### Layer 3 — Documentation

Add an explicit callout to [images.md](images.md) (Community) stating the
namespace-vs-ARN identity mismatch as a first-class caveat, and cross-link it from
[cross-namespace-imageref.md](../../../KubeMicroVM-PRO/docs/design/cross-namespace-imageref.md)
(PRO) so anyone reading the sharing-feature docs sees the failure mode they'd hit if
they bypass the binding mechanism.

Suggested text for `images.md`:

> **`MicroVMImage` names are not namespace-isolated identifiers.** The underlying AWS
> Lambda MicroVM image is identified by name within your AWS account + region, which
> has no concept of Kubernetes namespaces. Creating two `MicroVMImage` CRs with the
> same `metadata.name` in different namespaces is rejected by the validating webhook
> (Community and PRO). To share one image across namespaces or tenants, see the PRO
> [cross-namespace image reference](../../../KubeMicroVM-PRO/docs/design/cross-namespace-imageref.md)
> feature — never create a second same-named `MicroVMImage`.

---

## Community vs. PRO Behavior

| | Community | PRO |
|---|---|---|
| Layer 1 (admission rejection) | Implemented — message omits the `spec.imageRef: <ns>/<name>` suggestion since Community has no cross-namespace `imageRef` syntax; instead points to "delete the duplicate and use the same-namespace image, or upgrade to PRO for cross-namespace sharing" | Implemented — message includes the actionable `spec.imageRef: <ns>/<name>` + `MicroVMImageBinding` suggestion |
| Layer 2 (capped backoff + status/event on delete-blocked) | Implemented — this is core reconciler behavior shared by both editions (`MicroVMImageReconciler` lives in `operator-controller`, used unmodified by PRO) | Inherited unchanged from Community |
| Layer 3 (docs) | `images.md` updated | `cross-namespace-imageref.md` updated with cross-reference |

No PRO-specific code changes are required for Layers 1–2 — `MicroVMValidatingWebhook`
and `MicroVMImageReconciler` are both Community modules that PRO consumes as-is (PRO
overrides specific beans via CDI `@Alternative`, e.g. `ProImageRefResolver`, but does
not currently override the image webhook or image reconciler). PRO's work here is:
bump `community.version` once the Community fix ships, add UAT coverage proving the
webhook rejection and the capped-backoff/event behavior end-to-end against a real
PRO deployment (including the legitimate cross-namespace-binding scenario, to prove
Layer 1 doesn't false-positive against sanctioned sharing), and the doc cross-link.

---

## Testing Plan

### Community — unit/integration tests (`operator-webhook`, `operator-tests`)

1. `MicroVMValidatingWebhookTest`: CREATE `MicroVMImage/foo` in `ns-a` with no
   existing images anywhere → allowed.
2. CREATE `MicroVMImage/foo` in `ns-b` when `MicroVMImage/foo` already exists with a
   matching `status.imageArn` in `ns-a` → rejected, error message contains both
   namespace names and the ARN.
3. CREATE `MicroVMImage/foo` in `ns-a` when a same-named image exists in `ns-a` itself
   (i.e. a legitimate re-apply/update of the same object) → allowed (namespace check
   excludes self).
4. CREATE when `status.imageArn` is not yet set on the pre-existing object (still
   building) → no collision detected yet (expected — Layer 2 covers the residual
   race), verify no false-positive/exception.
5. `MicroVMImageReconcilerIT`: `cleanup()` on a `ValidationException`
   containing "running microvms" → asserts `DeleteControl.noFinalizerRemoval()`,
   capped backoff schedule, `DeleteBlocked` event emitted, `status.latestVersionStateReason`
   populated.
6. `MicroVMImageReconcilerIT`: backoff counter increments across repeated
   `cleanup()` calls and caps at 5 minutes; resets after a successful delete.

### PRO — UAT (Robot Framework)

Add to the multi-tenant suite (`uat/tests/03_multi_tenant.robot`) or a new
`08_image_governance.robot`:

- **IMG-01**: creating a duplicate-named `MicroVMImage` in a second namespace is
  rejected by `kubectl apply`, with the expected error substring.
- **IMG-02**: the sanctioned cross-namespace-imageref + `MicroVMImageBinding` path
  (existing PRO feature) is unaffected — a consumer namespace can still reference the
  catalog image via `spec.imageRef: <catalog-ns>/<name>` without creating its own
  `MicroVMImage`, and this is never flagged by Layer 1.
- **IMG-03**: deleting a `MicroVMImage` while a bound consumer namespace still has
  running VMs produces a `DeleteBlocked` Kubernetes Event and a bounded (not
  unbounded) retry count within a fixed observation window, and the namespace
  deletion is not required to complete for the test to pass (that's expected —
  correctly blocked, not a bug).

---

## Milestones

| # | Item | Repo |
|---|------|------|
| 1 | `validateNoArnCollision` in `MicroVMValidatingWebhook` + unit tests | KubeMicroVM |
| 2 | `cleanup()` exception classification + capped backoff + event in `MicroVMImageReconciler` + integration tests | KubeMicroVM |
| 3 | `images.md` doc update | KubeMicroVM |
| 4 | `community.version` bump in PRO `pom.xml` once (1)–(2) are tagged | KubeMicroVM-PRO |
| 5 | `cross-namespace-imageref.md` cross-reference update | KubeMicroVM-PRO |
| 6 | UAT coverage (IMG-01..03) | KubeMicroVM-PRO |
