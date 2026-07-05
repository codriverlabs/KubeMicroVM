# AGENTS.md — KubeMicroVM

> Kubernetes operator + CLI for AWS Lambda MicroVMs. Java 25, Quarkus 3, JOSDK, GraalVM native.

## Directory Map

```
├── operator-core/          # CRD models, enums, state machine (no deps on k8s client)
├── operator-aws-client/    # Code-generated async Lambda MicroVMs SDK
├── operator-controller/    # Reconcilers, AWS clients, token endpoint, health, metrics
├── operator-webhook/       # Validating + mutating admission webhooks
├── operator-auth-agent/    # Sidecar: auto-refresh MicroVM auth tokens in pods
├── operator-cli/           # `microvm` CLI (PicoCLI, native binary)
├── operator-tests/         # Integration tests (49 tests, Fabric8 MockServer)
├── uat-robot/              # Robot Framework E2E test suites (8 guides, 52 tests)
├── docs/design/            # Design documents (feature specs before implementation)
├── docs/user-guides/       # User-facing guides (8 guides, UAT-validated)
├── docs/testing/           # UAT results and test plans
├── .kiro/steering/         # Operational rules (MUST follow)
├── .agents/summary/        # AI-generated documentation (this ecosystem)
├── iam/                    # CloudFormation templates for IAM roles
└── test-fixtures/          # S3 app packages for E2E testing
```

## Key Entry Points

| Task | Start Here |
|------|-----------|
| Add/modify a CRD field | `operator-core/src/main/java/.../model/` → then reconciler in `operator-controller` |
| Add webhook validation | `operator-webhook/.../validation/MicroVMValidatingWebhook.java` |
| Change mutating defaults | `operator-webhook/.../mutation/MicroVMMutatingWebhook.java` |
| Add CLI command | `operator-cli/.../commands/` (extend appropriate parent command) |
| Add AWS API call | `operator-controller/.../aws/` (client classes wrap the SDK) |
| Fix reconciler logic | `operator-controller/.../reconciler/MicroVMReconciler.java` (520 LOC, main logic) |
| Run tests | `./mvnw -B install -DskipTests -q && ./mvnw -B -pl operator-tests verify` |
| Deploy to EKS | See `.kiro/steering/eks-deployment.md` |

## Patterns That Deviate From Defaults

- **No `helm upgrade`** — always uninstall + install during development (finalizers + webhooks conflict)
- **MicroVMClass has no reconciler** — it's a static lookup resource; CRD is manually maintained in `operator-controller/src/main/helm/crds/`
- **Webhook and reconciler in same pod** — not separate deployments; single operator pod handles all
- **Custom SDK** — `operator-aws-client` is code-generated from an AWS service model, not a standard AWS SDK module
- **`additionalProperties` on MicroVMSpec** — uses `@JsonAnySetter`/`@JsonAnyGetter` for forward-compat with new AWS fields
- **`treeToValue(valueToTree(...))` pattern** — required for webhook deserialization; `convertValue()` breaks with admission request objects

## Config & CI Artifacts

| File | Purpose |
|------|---------|
| `pom.xml` (root) | Parent POM, module list, dependency management |
| `operator-controller/src/main/resources/application.properties` | Operator config (region, endpoint, TLS, Helm) |
| `operator-controller/src/main/helm/` | Helm chart source (extra RBAC, values, manual CRDs) |
| `.kiro/steering/*.md` | Operational steering rules (build, deploy, branching, releases) |
| `build-local.sh` | Build script (--push, --helm, --native, --skip-tests, --registry) |
| `deploy-local.sh` | EKS deploy script (cleanup + install) |
| `install_kube_microvm.sh` | Customer-facing installer (IAM + Helm + CLI + registry import) |
| `.github/workflows/cla.yml` | CLA Assistant workflow (signs `signatures/cla.json` on `main`) |

## Testing Strategy

- **49 integration tests** (`operator-tests`): mocked AWS, real reconciler logic, Fabric8 MockServer
- **Property-based tests** (jqwik): state machine, serialization, scaling invariants, quota enforcement
- **Robot Framework UAT** (`uat-robot/`): 52 E2E tests on live EKS cluster, per-guide suites
- **Test before push rule**: `./mvnw install -DskipTests && ./mvnw -pl operator-tests verify`

## Custom Instructions
<!-- This section is for human and agent-maintained operational knowledge.
     Add repo-specific conventions, gotchas, and workflow rules here.
     This section is preserved exactly as-is when re-running codebase-summary. -->
