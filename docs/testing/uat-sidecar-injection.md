# UAT: Pod Sidecar Token Injection

## What

When a pod is annotated with `lambda.microvm.auth: <vm-name>`, the mutating
webhook injects a `microvm-auth-agent` sidecar. The sidecar fetches an AWS
auth token from the operator using the pod's ServiceAccount, writes it to a
shared in-memory volume, and refreshes it automatically.

## Prerequisites

- Namespace labelled `lambda.microvm.auth/inject=enabled`
- Pod's ServiceAccount has `create` on `microvms/token` for the target VM
- MicroVM in Running state

## Test Cases

| ID | Test | Expected |
|----|------|----------|
| SIDECAR-01 | Pod with annotation → sidecar injected | `microvm-auth-agent` container present |
| SIDECAR-02 | Sidecar image from ECR | Correct ECR image used |
| SIDECAR-03 | Agent fetches token | "Token written" in agent logs |
| SIDECAR-04 | Token files written to volume | `auth-token`, `endpoint`, `expires-at`, `.ready` |
| SIDECAR-05 | App reads token + calls MicroVM | `{"status":"ok"}` |

## Results (2026-07-02, EKS Auto Mode, us-east-1)

### Bugs fixed

1. `buildSidecar()` was mounting `kube-api-access` volume by name — invalid on
   EKS (auto-mounted SA volume has a generated name). Removed; Kubernetes
   auto-mounts SA token automatically.

2. `microvm-auth-agent` was compiled to Java 25 but base image had Java 21 only.
   Fixed: switched to `public.ecr.aws/amazoncorretto/amazoncorretto:25-al2023-headless`.

3. Agent used `operator-url=https://kubernetes.default.svc` (k8s API, not operator).
   Fixed: `${OPERATOR_URL:https://kube-microvm-operator.kube-microvm.svc:443}`.

4. Agent's `HttpClient` rejected the operator's self-signed cert-manager TLS cert.
   Fixed: custom `SSLContext` with trust-all for in-cluster connections.

5. Sidecar `imagePullPolicy: IfNotPresent` prevented new image from being pulled.
   Fixed: changed to `Always`.

6. Sidecar resource limits (16Mi) too low for JVM startup. Fixed: 128Mi/256Mi.

### Test Results

| ID | Result | Notes |
|----|--------|-------|
| SIDECAR-01 | ✅ PASS | `app` + `microvm-auth-agent` containers injected |
| SIDECAR-02 | ✅ PASS | `<ACCOUNT_ID>.dkr.ecr.us-east-1.amazonaws.com/plasticity-of-cloud/microvm-auth-agent:1.0.0-rc1` |
| SIDECAR-03 | ✅ PASS | `Token written to /var/run/microvm` in agent logs |
| SIDECAR-04 | ✅ PASS | `auth-token` (745 bytes), `endpoint`, `expires-at`, `.ready` |
| SIDECAR-05 | ✅ PASS | `{"status":"ok","path":"/","ts":"2026-07-02T04:21:05.240Z"}` |

Token expiry: 2026-07-02T04:50:35Z (30 min)
Endpoint: `3acf907f-e2b4-2812-74c9-542be8f63d1f.lambda-microvm.us-east-1.on.aws`
