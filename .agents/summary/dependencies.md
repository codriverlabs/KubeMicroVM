# Dependencies

## Core Framework

| Dependency | Version | Purpose |
|-----------|---------|---------|
| Quarkus | 3.36.x | Application framework, DI, REST, health, metrics |
| quarkus-operator-sdk | — | JOSDK integration, CRD generation, reconciler lifecycle |
| Fabric8 Kubernetes Client | — | Kubernetes API access, CRD models |
| Jackson | — | JSON serialization (CRD specs, webhook requests) |
| PicoCLI (via quarkus-picocli) | — | CLI argument parsing |

## AWS

| Dependency | Purpose |
|-----------|---------|
| Custom lambda-microvms SDK (code-generated) | Async client for Lambda MicroVMs API |
| AWS SDK v2 core | HTTP client, auth, region resolution |
| EKS Pod Identity | Credential injection at runtime |

## Build & Test

| Dependency | Purpose |
|-----------|---------|
| Maven 3.9+ (via mvnw) | Build system |
| GraalVM (Java 25) | Native image compilation (CLI + operator) |
| JUnit 5 | Unit + integration tests |
| Mockito | Mocking AWS clients in tests |
| jqwik | Property-based tests (state machine, serialization, scaling) |
| Fabric8 MockServer | In-memory Kubernetes API for integration tests |
| Robot Framework | Automated UAT on EKS |

## Container Base Images

| Image | Used By |
|-------|---------|
| `public.ecr.aws/amazoncorretto/amazoncorretto:25-al2023-headless` | Operator JVM, auth-agent |
| `public.ecr.aws/amazonlinux/amazonlinux:2023` | Test pods |
| `ghcr.io/graalvm/native-image:java25` | Native CLI build |

## Infrastructure

| Dependency | Purpose |
|-----------|---------|
| cert-manager | TLS certificates for webhook endpoints |
| EKS Pod Identity / IRSA | AWS credential injection |
| VPC Endpoints | Private API access (lambda-microvms, sts, ecr) |

## External Services

| Service | Endpoint | Purpose |
|---------|----------|---------|
| Lambda MicroVMs API | `lambda-microvm.<region>.on.aws` | Core MicroVM operations |
| STS | `sts.<region>.amazonaws.com` | Identity validation |
| S3 | `s3.<region>.amazonaws.com` | Code artifact storage |
| ECR | `<account>.dkr.ecr.<region>.amazonaws.com` | Container images |
