# Dependencies

## Core Framework

| Dependency | Version | Purpose |
|-----------|---------|---------|
| Quarkus | 3.36.3 | Application framework, DI, REST, health, metrics |
| JOSDK | 5.0.4 | Operator SDK, CRD generation, reconciler lifecycle |
| josdk-webhooks | 3.0.3 | Admission webhook framework |
| Fabric8 Kubernetes Client | 7.7.0 | Kubernetes API access, CRD models, MockServer for tests |
| Jackson | (via Quarkus BOM) | JSON serialization (CRD specs, webhook requests) |
| PicoCLI | 4.7.6 | CLI argument parsing (via quarkus-picocli) |

## AWS

| Dependency | Version | Purpose |
|-----------|---------|---------|
| Custom lambda-microvms SDK (code-generated) | — | Async client for Lambda MicroVMs API |
| AWS SDK v2 core | 2.44.6 | HTTP client, auth, region resolution |
| EKS Pod Identity | — | Credential injection at runtime (preferred over IRSA) |

## Build & Test

| Dependency | Version | Purpose |
|-----------|---------|---------|
| Maven 3.9+ (via mvnw) | 3.9+ | Build system (enforced by enforcer plugin) |
| GraalVM / Mandrel | Java 25 | Native image compilation; builder image: `quay.io/quarkus/ubi9-quarkus-mandrel-builder-image:jdk-25` |
| JUnit 5 | (via Quarkus BOM) | Unit + integration tests |
| Mockito | (via Quarkus BOM) | Mocking AWS clients in tests |
| jqwik | 1.9.2 | Property-based tests (state machine, serialization, scaling, drift detection) |
| Fabric8 MockServer | 7.7.0 | In-memory Kubernetes API for integration tests |
| Robot Framework | — | Automated UAT on EKS (62 tests across 10 suites) |

## Container Base Images

| Image | Used By |
|-------|---------|
| `public.ecr.aws/amazoncorretto/amazoncorretto:25-al2023-headless` | Operator JVM, auth-agent |
| `public.ecr.aws/amazonlinux/amazonlinux:2023` | Test pods |
| `quay.io/quarkus/ubi9-quarkus-mandrel-builder-image:jdk-25` | Native build |

## Infrastructure

| Dependency | Purpose |
|-----------|---------|
| cert-manager | TLS certificates for webhook endpoints (port 8443) |
| EKS Pod Identity / IRSA | AWS credential injection |
| VPC Endpoints | Private API access — lambda-microvm, sts, ecr.api, ecr.dkr, s3 (Gateway), eks-auth |

## External Services

| Service | Endpoint | Purpose |
|---------|----------|---------|
| Lambda MicroVMs API | `lambda-microvm.<region>.on.aws` | Core MicroVM operations |
| STS | `sts.<region>.amazonaws.com` | Identity validation (GetCallerIdentity) |
| S3 | `s3.<region>.amazonaws.com` | Code artifact storage for image builds |
| ECR | `<account>.dkr.ecr.<region>.amazonaws.com` | Operator + auth-agent container images |

## GitHub Actions Workflows

| Workflow | Trigger | Action |
|----------|---------|--------|
| `ci.yml` | Push/PR | Build, test (`./mvnw install -DskipTests && ./mvnw -pl operator-tests verify`) |
| `native-build.yml` | Tag push | Build native binaries (linux/amd64, linux/arm64), push container images to GHCR, push Helm chart, create GitHub Release |
| `cla.yml` | PR | CLA check; appends signature to `signatures/cla.json` on `main` |
| `version-bump.yml` | Manual/tag | Version bump automation |
