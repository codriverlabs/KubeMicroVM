# PRO Artifact Consumability — Jandex Indexes and Helm Value Mappings

**Status**: Design
**Scope**: `codriverlabs/KubeMicroVM` (Community)
**Driven by**: `KubeMicroVM-PRO/docs/design/build-publish-open-gaps.md` (G0, G18) and
`build-and-publish-pipeline.md` §7.4, §7.6
**Branch**: `feature/pro-consumability`

---

## 1. Motivation

Community is the producer in a two-repository edition model. PRO consumes our published
Maven jars and augments them inside its own Quarkus application (`operator-pro-dist`),
overlaying CDI `@Alternative @Priority(100)` beans onto our `Default*` SPI
implementations. Our release is therefore a **published API**, and two of its properties
are currently broken in ways our own build cannot detect.

This document covers two independent defects. Both are cheap to fix and both are
verifiable in this repository.

### 1.1 Defect A — `operator-controller` and `operator-spi` publish no Jandex index

ArC only scans a dependency jar for CDI beans if that jar carries `META-INF/jandex.idx`,
a `beans.xml` marker, or is explicitly named in a consumer's
`quarkus.index-dependency.*`.

Current state in this repository:

| Module | `jandex-maven-plugin` | Contains |
|---|---|---|
| `operator-core` | declared (`pom.xml:21`) | CRD models |
| `operator-webhook` | declared (`pom.xml:107`) | webhook handlers |
| `operator-spi` | **absent** | SPI interfaces |
| `operator-controller` | **absent** | **all reconcilers + all `Default*` SPI beans** |

`operator-controller` is our *application* module. In our own build Quarkus indexes it as
the root application, so no index is needed and none is produced — which is precisely why
this is invisible to us.

**Consequence for PRO** — the PRO distribution was built containing *only* the PRO
gateway reconciler. No `MicroVMReconciler`, no `MicroVMImageReconciler`, no
`MicroVMReplicaSetReconciler`, no `MicroVMNetworkReconciler`. The overlay was broken in
both directions: `DefaultImageRefResolver`, `DefaultQuotaPolicy`, `DefaultTenantResolver`,
`DefaultTokenPolicy` and `DefaultOperatorExtension` all live in `operator-controller`, so
the PRO `@Alternative` beans had no Community defaults to override.

Nothing failed loudly. CDI resolution was satisfied, the build was green, and PRO's unit
tests construct the `Pro*` beans directly.

PRO currently works around this with `quarkus.index-dependency` entries in
`operator-pro-dist/src/main/resources/application.properties:28-31`. Those entries are
load-bearing: remove them, rename a module, or change Quarkus indexing behaviour and the
regression returns silently. The workaround is also invisible from our side, so a refactor
here cannot know it is depended upon.

### 1.2 Defect B — `quarkus.helm.values.*` mappings into the operator `env` array are inert

This one affects **our own releases**, not just PRO.

`application.properties:130-131` replaces the operator container's entire `env` array
with an include of the `envVars` helper:

```properties
quarkus.helm.expressions.0.path=(kind == Deployment)...containers.(name == kube-microvm-operator).env
quarkus.helm.expressions.0.expression={{- include "kube-microvm-operator.envVars" . | nindent 12 }}
```

The helper (`src/main/helm/templates/_helpers.tpl`) iterates `.Values.app.envs` and
`.Values.extraEnvs`. Any `quarkus.helm.values.<name>.paths` expression pointing *inside*
that array therefore targets a structure that no longer exists in the rendered template.

Two groups of mappings are affected. Verified against the generated chart in
`operator-controller/target/helm/kubernetes/kube-microvm-operator/`:

**B1 — auth-agent image (`application.properties:126-127`)**

The value *is* emitted into `values.yaml`, but under `app.authAgentImage`, and no template
references it. The rendered env var comes from `app.envs`:

```yaml
app:
  authAgentImage: ghcr.io/codriverlabs/microvm-auth-agent:7.7.7   # dead — no template reads this
  envs:
    MICROVM_AUTH_AGENT_IMAGE: ghcr.io/codriverlabs/microvm-auth-agent:latest   # what actually renders
```

`native-build.yml:264` overrides `quarkus.helm.values.authAgentImage.value` per release.
That override lands in the dead key. **Every released Community chart pins the auth-agent
sidecar to `:latest`.** A `v1.0.15` install gets whatever `:latest` happens to be at
install time, which defeats version-matched deployment and makes rollback
non-deterministic.

**B2 — quota rate limits (`application.properties:111-123`)**

Worse: these produce no `values.yaml` key at all. There is no `quotas` key in the
generated `values.yaml`, and no template reference.

The `AWS_QUOTA_*` values that *do* render come from Quarkus's automatic detection of
`${VAR:default}` config expressions, so they carry the **code defaults**, not the values
in these mappings:

| Env var | Intended (`helm.values.quotas.*`) | Actually rendered | AWS burst limit |
|---|---|---|---|
| `AWS_QUOTA_RUN_MICROVM_RATE` | 4 | **5** | 5/s |
| `AWS_QUOTA_TERMINATE_MICROVM_RATE` | 9 | **10** | 10/s |
| `AWS_QUOTA_SUSPEND_MICROVM_RATE` | 1 | **2** | 2/s |
| `AWS_QUOTA_RESUME_MICROVM_RATE` | 4 | **5** | 5/s |
| `AWS_QUOTA_AUTH_TOKEN_RATE` | 45 | **50** | 50/s |
| `AWS_QUOTA_CONCURRENT_IMAGE_BUILDS` | 9 | **10** | 10 |

The intent of the mappings is clear from the numbers: each sits one below the
corresponding AWS burst limit, giving the quota guard headroom. Because they never
applied, the shipped chart configures the guard **exactly at** the AWS burst rate, so the
guard permits traffic right up to the throttling threshold rather than just below it.

This is consistent with the load-test observation recorded in the README: 50 concurrent
`CreateMicrovmAuthToken` requests returned 0% success against a 50/s burst limit.

Whether to adopt the intended headroom defaults is a product decision and is **out of
scope for this change** — see §4.

---

## 2. Design

### 2.1 Jandex indexes

Add `jandex-maven-plugin` to `operator-spi` and `operator-controller`, and move the
version into the parent `pluginManagement` so all four indexed modules share one
declaration. `operator-core` and `operator-webhook` currently hardcode `3.6.0`
independently.

Adding the plugin to `operator-controller` — a Quarkus application module — only writes
`META-INF/jandex.idx` into the classes jar. It does not change how Quarkus augments this
module in our own build, where the module is the application root and is indexed
regardless. This must be verified against the native build, not just the JVM build.

`operator-spi` is pure interfaces with no CDI beans, so an index there is defensive rather
than strictly required. It is included because PRO names it in `index-dependency` and
because an unindexed jar is a trap for any future consumer.

Once a release ships with indexes and PRO bumps `<community.version>` past it, PRO's
`index-dependency` entries become redundant. They are harmless in that state and PRO
should keep them until the bump lands.

### 2.2 Helm value mappings

Delete the inert mappings and drive the auth-agent image through the surface the helper
actually iterates.

| Mapping | Action |
|---|---|
| `quarkus.helm.values.authAgentImage.*` | delete — replaced by `quarkus.kubernetes.env.vars.MICROVM_AUTH_AGENT_IMAGE` |
| `quarkus.helm.values.quotas.*` (6 entries, 12 lines) | delete — inert, and the effective defaults already come from code |
| `quarkus.helm.values.crdValidatingRoleName.*` | **keep** — targets `metadata.name` / `roleRef.name`, not the env array |
| `quarkus.helm.values.replicas.*` | **keep** — targets `spec.replicas`, not the env array |

`native-build.yml` changes from

```
-Dquarkus.helm.values.authAgentImage.value=ghcr.io/codriverlabs/microvm-auth-agent:${VERSION}
```

to

```
-Dquarkus.kubernetes.env.vars.MICROVM_AUTH_AGENT_IMAGE=ghcr.io/codriverlabs/microvm-auth-agent:${VERSION}
```

which lands in `values.yaml` under `app.envs.MICROVM_AUTH_AGENT_IMAGE` — the key the
helper reads, and the key already documented for install-time override in
`src/main/helm/values.yaml`. This is the same mechanism PRO uses for `PRO_GATEWAY_IMAGE`,
verified there in both directions (CI bake and `--set`).

The user-facing override contract is unchanged:

```bash
--set app.envs.MICROVM_AUTH_AGENT_IMAGE=<repo>:<tag>
```

### 2.3 Rule for future env vars

Any operator env var that must be overridable at chart build time or install time is
declared with `quarkus.kubernetes.env.vars.<NAME>`, never with a
`quarkus.helm.values.*.paths` expression pointing inside the container `env` array. The
`expressions.0` replacement makes the latter silently inert.

---

## 3. Testing strategy

Both defects shipped green, so each fix needs an assertion that fails without it.

**Jandex** — assert the index is present in the built jars:

```bash
for m in operator-core operator-spi operator-controller operator-webhook; do
  unzip -l "$m/target/$m-"*.jar | grep -q 'META-INF/jandex.idx' \
    || { echo "MISSING jandex index: $m"; exit 1; }
done
```

**Helm mappings** — assert the rendered env var carries the baked version, not `:latest`:

```bash
mvn -pl operator-controller package -DskipTests \
  -Dquarkus.helm.enabled=true \
  -Dquarkus.kubernetes.env.vars.MICROVM_AUTH_AGENT_IMAGE=ghcr.io/codriverlabs/microvm-auth-agent:9.9.9
CHART=operator-controller/target/helm/kubernetes/kube-microvm-operator
grep -q 'microvm-auth-agent:9.9.9' "$CHART/values.yaml"
helm template t "$CHART" | grep -A1 MICROVM_AUTH_AGENT_IMAGE | grep -q '9.9.9'
```

Also assert install-time override still works, and that no dead keys remain:

```bash
helm template t "$CHART" --set app.envs.MICROVM_AUTH_AGENT_IMAGE=my.registry/agent:5.5.5 \
  | grep -q 'my.registry/agent:5.5.5'
grep -q 'authAgentImage' "$CHART/values.yaml" && { echo "dead key still emitted"; exit 1; }
```

**Regression suite** — `./mvnw -pl operator-tests verify` must stay green. The native
build must also be verified per `.kiro/steering/build-test-requirements.md`, since the
Jandex change touches how a Quarkus application module is packaged and native-image
failures do not surface in JVM mode.

**E2E** — install the chart on the EKS test cluster and confirm the injected sidecar
image tag matches the chart version rather than `latest`.

---

## 4. Out of scope

- **Quota default values.** §1.2 B2 establishes that the shipped defaults sit at the AWS
  burst limit rather than one below it, and that the one-below values were the original
  intent. Changing them alters throttling behaviour for every existing installation and
  should be a deliberate, separately tested decision. This change only removes the
  mappings that never worked; effective defaults are unchanged.
- **Publishing `src/main/helm/` as a consumable artifact** (PRO G17). PRO currently
  vendors three of our four overlay files and they drift on every `<community.version>`
  bump. Separate change.
- **`platform-versions.properties` release asset** and the **`notify-pro`
  `repository_dispatch` job**. Separate change; both are additive workflow steps.
- **`AWS_QUOTA_DISCOVERY` vs `AWS_QUOTA_DISCOVERY_ENABLED`.** The generated chart emits
  the former; `src/main/helm/values.yaml` documents the latter. Documentation defect,
  noted here so it is not lost.

---

## 5. Compatibility

Both changes are backward compatible for chart consumers.

- No `values.yaml` key that any template reads is removed. `app.authAgentImage` and the
  absent `quotas` tree were never consumable.
- `--set app.envs.MICROVM_AUTH_AGENT_IMAGE=...` behaves exactly as before, and as already
  documented.
- Anyone passing `-Dquarkus.helm.values.authAgentImage.value=...` in their own build
  loses a flag that had no effect. `native-build.yml` is the only known caller.

The auth-agent fix changes released behaviour in the intended direction: charts will pin
the sidecar to the release version instead of `:latest`.

---

## 6. References

- `KubeMicroVM-PRO/docs/design/build-publish-open-gaps.md` — G0, G18
- `KubeMicroVM-PRO/docs/design/build-and-publish-pipeline.md` — §7.4 (CDI across the jar
  boundary), §7.6 (`helm.values` cannot target the env array)
- `.kiro/steering/build-test-requirements.md` — pre-push verification, native build
  rationale
