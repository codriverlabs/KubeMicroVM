# AGENTS.md — KubeMicroVM

> Kubernetes operator + CLI for AWS Lambda MicroVMs. Java 25, Quarkus 3.36.3, JOSDK 5.0.4, GraalVM native.

## Directory Map

```
├── operator-core/          # CRD models, enums, state machine (no deps on k8s client)
├── operator-spi/           # Extension SPI — pure Java interfaces for Community/PRO parity
├── operator-aws-client-core/ # Shared AWS SDK base types
├── operator-aws-client/    # Code-generated async Lambda MicroVMs SDK
├── operator-controller/    # Reconcilers, AWS clients, token endpoint, health, metrics, SPI defaults, quota guard
├── operator-webhook/       # Validating + mutating admission webhooks (MicroVM + Pod)
├── operator-auth-agent/    # Sidecar: auto-refresh MicroVM auth tokens in pods
├── operator-cli/           # `microvm` CLI (PicoCLI, native binary)
├── operator-tests/         # Integration tests (76 tests, Fabric8 MockServer)
├── uat/                    # Robot Framework E2E test suites (10 suites, 62 tests)
├── docs/design/            # Design documents (feature specs before implementation)
├── docs/user-guides/       # User-facing guides
├── docs/testing/           # Load test and regression test scripts
├── .kiro/steering/         # Operational rules (MUST follow)
├── .agents/summary/        # AI-generated documentation (this ecosystem)
├── iam/                    # CloudFormation templates for IAM roles
└── uat/fixtures/           # S3 app packages for E2E testing
```

## Key Entry Points

| Task | Start Here |
|------|-----------|
| Add/modify a CRD field | `operator-core/src/main/java/.../model/` → then reconciler in `operator-controller` |
| Add webhook validation | `operator-webhook/.../validation/MicroVMValidatingWebhook.java` |
| Change mutating defaults | `operator-webhook/.../mutation/MicroVMMutatingWebhook.java` |
| Change sidecar injection | `operator-webhook/.../mutation/PodMutatingWebhook.java` + Helm `mutatingwebhookcfg.yaml` |
| Add CLI command | `operator-cli/.../commands/` (extend appropriate parent command) |
| Add AWS API call | `operator-controller/.../aws/` (client classes wrap the SDK) |
| Fix reconciler logic | `operator-controller/.../reconciler/MicroVMReconciler.java` |
| Fix ReplicaSet scaling/rolling update | `operator-controller/.../reconciler/MicroVMReplicaSetReconciler.java` |
| Add/modify SPI extension point | `operator-spi/src/main/java/.../spi/` (interfaces) + `operator-controller/.../spi/Default*.java` |
| Run tests | `./mvnw install -DskipTests && ./mvnw -pl operator-tests verify` |
| Deploy to EKS | See `.kiro/steering/eks-deployment.md` |

## Patterns That Deviate From Defaults

- **No `helm upgrade`** — always uninstall + install during development (finalizers + webhooks conflict)
- **MicroVMClass has no reconciler** — static lookup resource; CRD manually maintained in `operator-controller/src/main/helm/crds/`
- **Webhook and reconciler in same pod** — single operator pod handles all; not separate deployments
- **Custom SDK** — `operator-aws-client` is code-generated from an AWS service model, not a standard AWS SDK module
- **`additionalProperties` on MicroVMSpec** — uses `@JsonAnySetter`/`@JsonAnyGetter` for forward-compat with new AWS fields
- **`treeToValue(valueToTree(...))` pattern** — required for webhook deserialization; `convertValue()` breaks with admission request objects
- **SPI extension points** — `operator-spi` defines interfaces; `operator-controller/spi/Default*.java` provides Community defaults; PRO overrides via `@Alternative @Priority(100)` CDI beans
- **Token auth is two-step** — `MicroVMTokenResource` does TokenReview first (exchange Bearer for identity), then SubjectAccessReview (RBAC check on that identity); skipping TokenReview would let any pod get any VM's token
- **PodMutatingWebhook uses `failurePolicy: Ignore`** — never blocks pod creation even if operator is down; opt-in via `lambda.microvm.auth/inject=enabled` namespace label
- **`token`/`exec` CLI commands try operator sub-resource first** — fallback to AWS direct SDK; `--direct` flag forces AWS-only path
- **Auth agent writes `.ready` sentinel** — `/var/run/microvm/.ready` created after first token fetch; init containers / startup probes can gate on this file

## Config & CI Artifacts

| File | Purpose |
|------|---------|
| `pom.xml` (root) | Parent POM, 9 module list, dependency management |
| `operator-controller/src/main/resources/application.properties` | Operator config (region, endpoint, TLS, Helm, `%test` profile) |
| `operator-controller/src/main/helm/` | Helm chart source (extra RBAC, values, manual CRDs) |
| `.kiro/steering/*.md` | Operational steering rules (build, deploy, branching, releases) |
| `build-local.sh` | Build script (--push, --helm, --native, --skip-tests, --registry) |
| `deploy-local.sh` | EKS deploy script (cleanup + install) |
| `install_kube_microvm.sh` | Customer-facing installer (IAM + Helm + CLI + registry import) |
| `.github/workflows/ci.yml` | Build + test on push/PR |
| `.github/workflows/native-build.yml` | Native binary + container + Helm release on tag push |
| `.github/workflows/cla.yml` | CLA Assistant (appends to `signatures/cla.json` on `main`) |

## Testing Strategy

- **76 integration tests** (`operator-tests`): mocked AWS, real reconciler logic, Fabric8 MockServer
- **Property-based tests** (jqwik): state machine, serialization, scaling invariants, quota enforcement, drift detection
- **Robot Framework UAT** (`uat/`): 62 E2E tests across 10 suites on live EKS cluster, per-guide suites
- **Test before push rule**: `./mvnw install -DskipTests && ./mvnw -pl operator-tests verify`

## Custom Instructions
<!-- This section is for human and agent-maintained operational knowledge.
     Add repo-specific conventions, gotchas, and workflow rules here.
     This section is preserved exactly as-is when re-running codebase-summary. -->
