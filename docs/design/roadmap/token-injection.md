# MicroVM Token Injection — Design Spec

**Status**: Draft  
**Milestone**: v0.3.0

---

## Problem

A pod that needs to call a MicroVM's HTTPS endpoint must present a short-lived JWE token
in every request (`X-aws-proxy-auth` header). There is no unauthenticated access.

Today, obtaining a token requires direct AWS IAM access and a manual call to
`CreateMicrovmAuthToken`. Application pods should not need AWS credentials — they should
be able to get tokens using their existing Kubernetes service account identity.

---

## Goals

- Pods annotated with `lambda.microvm.auth=<vm-name>` automatically receive fresh tokens
- Authorization is enforced via standard Kubernetes RBAC (no custom permission systems)
- Tokens are refreshed before expiry — application never sees a stale token
- Application reads token from a well-known file path (no SDK changes in application code)
- The MicroVM endpoint URL is co-located with the token for convenience
- Pods without the annotation are unaffected (strictly opt-in)

## Non-goals

- Not a general secret injection system (only MicroVM auth tokens)
- Not a replacement for AWS credentials (operator still uses IAM/Pod Identity)
- Does not support cross-namespace token requests

---

## Architecture

```
[Pod]
  annotation: lambda.microvm.auth=my-vm
  ┌──────────────────────────────────────────┐
  │  main container                          │
  │    reads /var/run/microvm/auth-token     │
  │    reads /var/run/microvm/endpoint       │
  │                          ↑               │
  │  sidecar: microvm-auth-agent             │
  │    every ~25 min (before 30 min expiry): │
  │      GET microvms/my-vm/token            │ ← uses projected k8s service account token
  │      write to /var/run/microvm/          │
  └──────────────────────────────────────────┘
           ↓ k8s API (RBAC-gated)
  [Operator token sub-resource API]
           ↓ AWS IAM (operator's Pod Identity role)
  [CreateMicrovmAuthToken → JWE string]
```

---

## Components

### 1. `microvms/token` Kubernetes sub-resource

The operator registers a new sub-resource on `MicroVM` CRs:

```
POST /apis/lambda.aws.amazon.com/v1alpha1/namespaces/{ns}/microvms/{name}/token
```

**Request body:**
```json
{
  "expirationInMinutes": 30,
  "allowedPorts": [{"allPorts": {}}]
}
```

**Response:**
```json
{
  "authToken": "eyJhb...",
  "endpoint": "mvm-abc123.lambda-microvm.us-east-1.on.aws",
  "expiresAt": "2026-06-28T21:30:00Z"
}
```

The operator authenticates the caller's Kubernetes service account token,
checks RBAC, then calls `CreateMicrovmAuthToken` on AWS and returns the result.

**RBAC resource name:** `microvms/token`  
**Verb:** `create`

### 2. RBAC model

Platform admins grant service accounts access to specific MicroVMs:

```yaml
# Namespace-scoped: grants access to tokens for a specific VM
kind: Role
apiVersion: rbac.authorization.k8s.io/v1
metadata:
  name: microvm-token-reader
  namespace: my-app
rules:
- apiGroups: ["lambda.aws.amazon.com"]
  resources: ["microvms/token"]
  resourceNames: ["my-vm"]          # scope to specific VM (omit for all VMs in namespace)
  verbs: ["create"]
---
kind: RoleBinding
subjects:
- kind: ServiceAccount
  name: my-app-service-account
roleRef:
  kind: Role
  name: microvm-token-reader
```

### 3. Pod annotation contract

| Annotation | Required | Description |
|------------|----------|-------------|
| `lambda.microvm.auth` | Yes | Name of the `MicroVM` CR to get tokens for |
| `lambda.microvm.auth/port` | No | Port to scope tokens to (default: all ports) |
| `lambda.microvm.auth/expires` | No | Token expiry in minutes (default: 30) |
| `lambda.microvm.auth/mount-path` | No | Override mount path (default: `/var/run/microvm`) |

Example:
```yaml
metadata:
  annotations:
    lambda.microvm.auth: my-agent-vm
    lambda.microvm.auth/port: "8080"
    lambda.microvm.auth/expires: "60"
```

### 4. Mutating webhook — sidecar injection

When a `Pod` is admitted with the `lambda.microvm.auth` annotation, the webhook injects:

**Sidecar container (`microvm-auth-agent`):**
```yaml
name: microvm-auth-agent
image: ghcr.io/codriverlabs/microvm-auth-agent:latest
env:
  - name: MICROVM_NAME
    value: <annotation value>
  - name: MICROVM_NAMESPACE
    valueFrom:
      fieldRef:
        fieldPath: metadata.namespace
  - name: TOKEN_EXPIRY_MINUTES
    value: "30"
  - name: MOUNT_PATH
    value: /var/run/microvm
  - name: OPERATOR_API
    value: https://kubernetes.default.svc
volumeMounts:
  - name: microvm-token
    mountPath: /var/run/microvm
  - name: kube-api-access
    mountPath: /var/run/secrets/kubernetes.io/serviceaccount
    readOnly: true
resources:
  requests: {cpu: 5m, memory: 16Mi}
  limits:   {cpu: 50m, memory: 32Mi}
```

**Shared EmptyDir volume:**
```yaml
volumes:
  - name: microvm-token
    emptyDir:
      medium: Memory   # in-memory — token never written to disk
```

**Volume mount injected into main container:**
```yaml
volumeMounts:
  - name: microvm-token
    mountPath: /var/run/microvm
    readOnly: true
```

### 5. `microvm-auth-agent` sidecar behavior

```
startup:
  1. Wait for MicroVM to reach RUNNING (poll GET /microvms/{name} via k8s API)
  2. Call POST /microvms/{name}/token → write auth-token + endpoint to mount path
  3. Signal readiness (write /var/run/microvm/.ready)

refresh loop (every refresh_interval = expiry_minutes * 0.8):
  1. Call POST /microvms/{name}/token
  2. Atomically write new token (rename, not truncate — avoids partial reads)
  3. Log refresh with new expiry

on MicroVM SUSPENDED:
  - Keep current token (MicroVM endpoint still valid while auto-resume possible)

on MicroVM TERMINATED:
  - Clear token file
  - Write /var/run/microvm/.terminated
```

**Files written to mount path:**
```
/var/run/microvm/
  auth-token      — raw JWE string (the X-aws-proxy-auth header value)
  endpoint        — hostname only (e.g. mvm-abc123.lambda-microvm.us-east-1.on.aws)
  expires-at      — RFC3339 timestamp of current token expiry
  .ready          — written once token is first available (app can wait on this)
  .terminated     — written if MicroVM terminates permanently
```

---

## Operator changes required

### `MicroVMClient` interface
```java
CompletableFuture<CreateAuthTokenResponse> createAuthToken(
    String microvmId, int expirationInMinutes, List<AllowedPort> allowedPorts);
```

### New REST endpoint in operator-controller
A Quarkus JAX-RS resource implementing the token sub-resource:
```
POST /apis/lambda.aws.amazon.com/v1alpha1/namespaces/{ns}/microvms/{name}/token
```
- Validates caller's k8s service account token (via TokenReview API)
- Checks RBAC SubjectAccessReview: `create` on `microvms/token`
- Resolves `microvmId` from `MicroVM` CR status
- Calls `CreateMicrovmAuthToken` on AWS
- Returns response

### Mutating webhook extension
- New path `/mutate-pod` for Pod resources
- Detects `lambda.microvm.auth` annotation
- Injects sidecar + volumes + main container volume mount

---

## Security considerations

- Token files live in `emptyDir: {medium: Memory}` — never written to disk
- Sidecar runs as non-root (UID 1001)
- Service account only needs `create` on `microvms/token` — no other RBAC
- `resourceNames` constraint limits to specific VMs (principle of least privilege)
- Token expiry is set by the caller — short-lived by default (30 min)
- The operator (not the pod) holds AWS IAM permissions — pods have zero AWS access

---

## Helm chart additions

```yaml
# values.yaml additions
tokenInjection:
  enabled: true
  sidecarImage:
    repository: ghcr.io/codriverlabs/microvm-auth-agent
    tag: latest
  defaultExpiryMinutes: 30
  mountPath: /var/run/microvm
```

New Helm templates:
- `templates/mutatingwebhookcfg-pod.yaml` — webhook for Pod resources
- `templates/clusterrole-token.yaml` — ClusterRole for token sub-resource
- RBAC helper: `Role` + `RoleBinding` example in chart Notes

---

## Implementation plan

| Phase | Work | Milestone |
|-------|------|-----------|
| 1 | `CreateMicrovmAuthToken` in `DefaultMicroVMClient` | v0.2.1 |
| 1 | `kubectl microvm token` CLI command | v0.2.1 |
| 2 | Operator token sub-resource REST endpoint | v0.3.0 |
| 2 | `microvm-auth-agent` sidecar (new module) | v0.3.0 |
| 2 | Pod mutating webhook + sidecar injection | v0.3.0 |
| 3 | Helm chart integration + RBAC scaffolding | v0.3.0 |

Phase 1 (v0.2.1) unblocks manual testing and gives the CLI `token` command.
Phase 2 (v0.3.0) delivers the full auto-injection experience for production use.
