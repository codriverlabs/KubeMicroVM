# KubeMicroVM — Codebase Information

## Project Identity

- **Name**: KubeMicroVM
- **Type**: Kubernetes Operator + CLI
- **Language**: Java 25 (Quarkus 3, GraalVM native)
- **Framework**: JOSDK (Java Operator SDK) via Quarkus Operator SDK extension
- **License**: Elastic License 2.0 (ELv2)
- **Latest stable release**: v1.0.5 (dev branch: 1.1.0-SNAPSHOT)
- **Repository**: github.com/plasticity-of-cloud/KubeMicroVM

## Technology Stack

| Layer | Technology |
|-------|-----------|
| Runtime | Quarkus 3.36.3, Java 25, GraalVM native-image |
| Operator SDK | JOSDK 5.0.4 via quarkus-operator-sdk |
| Kubernetes client | Fabric8 7.7.0 |
| AWS SDK | Custom code-generated async client (lambda-microvms), AWS SDK v2 2.44.6 |
| CLI | PicoCLI 4.7.6 (via quarkus-picocli) |
| Build | Maven 3.9+ (mvnw), Docker multi-stage |
| Helm | Quarkus Helm extension (auto-generated) + manual CRDs |
| Testing | JUnit 5, Mockito, jqwik 1.9.2 (property-based), Fabric8 MockServer |
| UAT | Robot Framework (keyword-driven) |
| CI/CD | GitHub Actions |

## Module Structure (9 Maven modules)

| Module | Purpose | Key Classes |
|--------|---------|-------------|
| `operator-core` | CRD models, enums, state machine | MicroVM, MicroVMSpec, MicroVMStateMachine |
| `operator-spi` | Extension SPI — pure Java interfaces | QuotaPolicy, TenantResolver, TokenPolicy, OperatorExtension |
| `operator-aws-client-core` | Shared AWS SDK base types | — |
| `operator-aws-client` | Code-generated Lambda MicroVMs SDK | LambdaMicrovmsAsyncClient |
| `operator-controller` | Reconcilers, AWS clients, health, metrics, SPI defaults | MicroVMReconciler, DefaultMicroVMClient, QuotaGuard |
| `operator-webhook` | Validating + mutating admission webhooks | MicroVMValidatingWebhook, MicroVMMutatingWebhook, PodMutatingWebhook |
| `operator-auth-agent` | Sidecar token refresh agent | TokenRefreshAgent |
| `operator-cli` | `microvm` CLI (native binary) | MicroVMCommand, TokenCommand |
| `operator-tests` | Integration tests (76 tests) | *IT classes |

## Custom Resources (5 CRDs)

| CRD | Scope | Reconciler | Description |
|-----|-------|-----------|-------------|
| `MicroVM` | Namespaced | MicroVMReconciler | Maps 1:1 to AWS Lambda MicroVM instance |
| `MicroVMImage` | Namespaced | MicroVMImageReconciler | Builds/manages MicroVM container images |
| `MicroVMReplicaSet` | Namespaced | MicroVMReplicaSetReconciler | Pool of identical MicroVM replicas with rolling update |
| `MicroVMNetwork` | Namespaced | MicroVMNetworkReconciler | VPC egress network connector |
| `MicroVMClass` | Namespaced | None (static lookup) | Named runtime profile template |
