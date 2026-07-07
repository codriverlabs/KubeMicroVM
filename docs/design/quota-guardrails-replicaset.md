# Design: Wire QuotaGuard into MicroVMReplicaSetReconciler

**Status**: Implementation ready  
**Branch**: `feature/quota-guardrails-replicaset`  
**Depends on**: `feature/quota-guardrails` + `feature/quota-guardrails-spi` (both merged to main)

---

## Why

`QuotaGuard` was introduced in `feature/quota-guardrails` to enforce AWS Lambda MicroVMs
API rate limits at the operator level. It was wired into three callers:

| Caller | APIs guarded |
|--------|-------------|
| `MicroVMReconciler` | `RunMicrovm`, `TerminateMicrovm`, `SuspendMicrovm`, `ResumeMicrovm`, `GetMicrovm` |
| `MicroVMImageReconciler` | concurrent image build semaphore |
| `MicroVMTokenResource` | `CreateMicrovmAuthToken` (rate limit + backpressure queue) |

`MicroVMReplicaSetReconciler` was not wired at that time because it operated indirectly —
it only creates and patches child `MicroVM` CRs, and those children are then reconciled
by `MicroVMReconciler` which already has `QuotaGuard`. So at first glance, no direct AWS
calls seemed necessary.

### Why it still needs QuotaGuard

The ReplicaSet reconciler **does** make rate-sensitive API calls indirectly when it
patches `spec.desiredState` on children. Each such patch triggers an immediate reconcile
of the child `MicroVMReconciler`, which calls AWS. On a 1,000-VM ReplicaSet:

- **Suspend cascade**: `desiredReplicaSetState=Suspended` → patch all 1,000 children in
  one reconcile cycle → 1,000 `SuspendMicrovm` calls queued simultaneously.
  `SuspendMicrovm` has a 2 req/s rate limit. Without any pacing, this floods the token
  bucket and causes 429s on the child reconcilers.

- **Scale-down**: currently limited to 1 victim per reconcile (`selectVictims` picks all,
  but `spec.desiredState: Terminated` is set in a loop). If the ReplicaSet reconciler
  starts batching or if child reconcilers race to terminate, `TerminateMicrovm` (10 req/s)
  can be saturated.

- **Scale-up**: currently 1 create per reconcile cycle (`MAX_CREATES_PER_RECONCILE = 1`),
  which is already conservative. But the reconciler reschedules after 3s, meaning the
  effective throughput is one child every ~3s — well within the `RunMicrovm` 5 req/s
  limit. However this constant is not connected to the quota — if someone increases it,
  the quota guard provides the safety net.

### What QuotaGuard provides here

For the ReplicaSet reconciler, `QuotaGuard` is not used for direct AWS SDK calls (there
are none — those are in the child reconcilers). Instead, it is used to:

1. **Read effective rate limits at construction time** — so `MAX_CREATES_PER_RECONCILE`
   and the requeue delay can be derived from the quota, not hardcoded.

2. **Pace the suspend/resume cascade** — insert a `suspendBucket.acquire()` /
   `resumeBucket.acquire()` before each child patch, so the child MicroVMReconciler's
   AWS calls are spaced appropriately.

3. **Honour the `QuotaPolicy` SPI** — PRO can override `effectiveRate()` to apply
   per-tenant margin or override the max cascade rate.

---

## What Changes

### `MicroVMReplicaSetReconciler`

1. **Inject `QuotaGuard`** — add constructor parameter, update `@Inject` constructor.

2. **Pace suspend/resume cascade** — before each child patch in the cascade loop, call
   `quotaGuard.suspendMicrovm(...)` or `quotaGuard.resumeMicrovm(...)` with a no-op
   supplier (just the rate-limit acquisition):

   ```java
   // Acquire rate-limit permit before patching — throttles how fast
   // child reconcilers are triggered to call SuspendMicrovm/ResumeMicrovm
   if (wantSuspended) {
       quotaGuard.suspendMicrovm(() -> CompletableFuture.completedFuture(null)).get();
   } else {
       quotaGuard.resumeMicrovm(() -> CompletableFuture.completedFuture(null)).get();
   }
   child.getSpec().setDesiredState(DesiredState.fromValue(targetState));
   k8s.resource(child).patch();
   ```

   > **Note**: Calling `acquire()` here blocks the reconcile thread briefly per child.
   > This is intentional — it spreads the AWS load from the child reconcilers over time
   > rather than flooding them simultaneously. The reconcile thread is Vert.x event-loop
   > aware: JOSDK runs reconcilers on a worker thread pool, so blocking here is fine.

3. **Derive `MAX_CREATES_PER_RECONCILE` from quota** — replace the hardcoded `1` with
   the quota-aware value from `QuotaGuard`:

   ```java
   // Conservative: allow at most (rate/2) creates per reconcile cycle,
   // since each create triggers a RunMicrovm call from the child reconciler.
   // The 3s requeue means effective rate = maxCreates / 3 req/s.
   private int maxCreatesPerCycle() {
       return Math.max(1, quotaGuard.runMicrovmRatePerSecond() / 2);
   }
   ```

   This requires adding `runMicrovmRatePerSecond()` accessor to `QuotaGuard`.

### `QuotaGuard`

Add a read accessor for the effective run rate (needed by the ReplicaSet reconciler to
derive its max-creates-per-cycle):

```java
public int runMicrovmRatePerSecond() {
    return runMicrovmBucket.ratePerSecond();
}
```

Add `ratePerSecond()` to the inner `TokenBucket` class (it already stores `intervalNanos`,
so `ratePerSecond = (int)(1_000_000_000L / intervalNanos)`).

---

## Integration Tests Required

### `MicroVMReplicaSetReconcilerIT` — new tests

The existing 5 tests construct `MicroVMReplicaSetReconciler(client)`. After this change,
the constructor requires `QuotaGuard` too. All 5 existing tests must be updated to pass a
`QuotaGuard` instance (constructed with test-safe rates, same pattern as `MicroVMReconcilerIT`).

New tests to add:

| Test | What it verifies |
|------|-----------------|
| `suspendCascade_acquiresRateLimitPerChild` | Suspending N children calls the `suspendBucket` N times — verify via a spy QuotaGuard that counts `suspendMicrovm` acquisitions |
| `resumeCascade_acquiresRateLimitPerChild` | Same for resume |
| `scaleUp_maxCreatesPerCycleDerivedFromQuota` | When `runMicrovmRate=2`, `maxCreatesPerCycle()` returns 1; when `runMicrovmRate=10`, returns 5 |
| `quotaGuard_injected_notNull` | Sanity: reconciler construction with QuotaGuard injects correctly |

### `SpiDefaultsIT` — existing test

Verify `DefaultQuotaPolicy.effectiveRate("RunMicrovm", 5)` returns `5` (already tested).
No new tests needed in this file for this feature — the SPI contract is already covered.

---

## User Guide Additions

The existing **[Quota Guardrails](../user-guides/quota-guardrails.md)** guide (to be created
as part of this feature) should explain:

1. What rate limits exist and why the operator enforces them
2. How to check the active quota configuration (`kubectl logs` startup message)
3. How to override after a quota increase (`--quota-run-microvm-rate` install flag or
   `helm upgrade --set quotas.runMicrovmRate=10`)
4. What happens during a large ReplicaSet suspend/resume (cascades are paced — they take
   longer than a direct AWS SDK call, intentionally)
5. How `QuotaDiscovery` works at install time and optionally at runtime

See [User Guide: Quota Guardrails](#user-guide-quota-guardrailsmd) section below.

---

## User Guide: `quota-guardrails.md`

File to create at `docs/user-guides/quota-guardrails.md`.

### Sections

- **Why quota guardrails exist** — AWS account-level rate limits, what happens without them
  (load test: 0% token success at 50 concurrent requests)
- **What is rate-limited** — table of all 7 APIs with their default limits
- **How limits are discovered** — install-time via `aws service-quotas`, fallback to defaults
- **How to view active limits** — `kubectl logs -n kube-microvm deploy/kube-microvm-operator | grep QuotaGuard`
- **How to override** — `--quota-*` install flags, Helm values `quotas.*`, env vars `AWS_QUOTA_*`
- **ReplicaSet cascade behaviour** — why large suspend/resume operations are intentionally paced
- **Runtime quota discovery** — `--quota-discovery=runtime`, IAM requirement
- **QuotaPolicy SPI** — brief mention for PRO users; link to SPI docs

---

## Implementation Checklist

- [ ] Add `ratePerSecond()` to `QuotaGuard.TokenBucket`
- [ ] Add `runMicrovmRatePerSecond()` accessor to `QuotaGuard`
- [ ] Inject `QuotaGuard` into `MicroVMReplicaSetReconciler` constructor
- [ ] Pace suspend/resume cascade with `quotaGuard.suspendMicrovm/resumeMicrovm`
- [ ] Derive `maxCreatesPerCycle()` from `quotaGuard.runMicrovmRatePerSecond()`
- [ ] Update existing 5 `MicroVMReplicaSetReconcilerIT` tests to pass `QuotaGuard`
- [ ] Add 4 new integration tests (cascade rate-limit verification, quota-derived max creates)
- [ ] Create `docs/user-guides/quota-guardrails.md`
- [ ] Update `docs/design/api-implementation-status.md` — add quota-guardrails row
- [ ] All tests pass (`./mvnw -B install -DskipTests && ./mvnw -B -pl operator-tests verify`)

---

## Out of Scope

- Changing the `SuspendMicrovm` / `ResumeMicrovm` quota values (these are account limits,
  not operator limits — request increase via AWS Support)
- Per-namespace rate limiting (PRO feature via `QuotaPolicy` + `TenantResolver` SPI)
- Metrics for quota guard acquisitions / wait times (tracked separately in observability gaps)
