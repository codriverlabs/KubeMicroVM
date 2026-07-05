# KubeMicroVM — Codebase Information

## Project Identity

- **Name**: KubeMicroVM
- **Type**: Kubernetes Operator + CLI
- **Language**: Java 25 (Quarkus 3, GraalVM native)
- **Framework**: JOSDK (Java Operator SDK) via Quarkus Operator SDK extension
- **License**: Elastic License 2.0 (ELv2)
- **Latest stable release**: v1.0.1 (dev branch: 1.1.0-SNAPSHOT)
- **Repository**: github.com/plasticity-of-cloud/KubeMicroVM

## Technology Stack

| Layer | Technology |
|-------|-----------|
| Runtime | Quarkus 3.36, Java 25, GraalVM native-image |
| Operator SDK | JOSDK via quarkus-operator-sdk |
| Kubernetes client | Fabric8 |
| AWS SDK | Custom code-generated async client (lambda-microvms) |
| CLI | PicoCLI (via quarkus-picocli) |
| Build | Maven (mvnw), Docker multi-stage |
| Helm | Quarkus Helm extension (auto-generated) + manual CRDs |
| Testing | JUnit 5, Mockito, jqwik (property-based), Fabric8 MockServer |
| UAT | Robot Framework (keyword-driven) |
| CI/CD | GitHub Actions |

## Module Structure (8 Maven modules)

| Module | Purpose | Key Classes |
|--------|---------|-------------|
| `operator-core` | CRD models, enums, state machine | MicroVM, MicroVMSpec, MicroVMStateMachine |
| `operator-aws-client-core` | Shared AWS SDK base types | — |
| `operator-aws-client` | Code-generated Lambda MicroVMs SDK | LambdaMicrovmsAsyncClient |
| `operator-controller` | Reconcilers, AWS clients, health, metrics | MicroVMReconciler, DefaultMicroVMClient |
| `operator-webhook` | Validating + mutating admission webhooks | MicroVMValidatingWebhook, MicroVMMutatingWebhook, PodMutatingWebhook |
| `operator-auth-agent` | Sidecar token refresh agent | TokenRefreshAgent |
| `operator-cli` | `microvm` CLI (native binary) | MicroVMCommand, TokenCommand |
| `operator-tests` | Integration tests (49 tests) | *IT classes |

## Custom Resources (5 CRDs)

| CRD | Scope | Reconciler | Description |
|-----|-------|-----------|-------------|
| `MicroVM` | Namespaced | MicroVMReconciler | Maps 1:1 to AWS Lambda MicroVM instance |
| `MicroVMImage` | Namespaced | MicroVMImageReconciler | Builds/manages MicroVM container images |
| `MicroVMReplicaSet` | Namespaced | MicroVMReplicaSetReconciler | Pool of identical MicroVM replicas |
| `MicroVMNetwork` | Namespaced | MicroVMNetworkReconciler | VPC egress network connector |
| `MicroVMClass` | Namespaced | None (static lookup) | Named runtime profile template |
