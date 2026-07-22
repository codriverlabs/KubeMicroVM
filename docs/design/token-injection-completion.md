# Token Injection — Completion Plan

**Branch**: `feat/token-injection-complete` — **fully merged to main (2026-07-09)**. All items below complete.

---

## What's Missing

| Gap | Impact |
|-----|--------|
| `TokenReview` not called — RBAC check uses wrong identity | Security: operator blindly trusts the request; any pod can get any VM's token |
| `PodMutatingWebhook` not in `MutatingWebhookConfiguration` Helm template | Sidecar injection never fires |
| `kubectl microvm token` always calls AWS directly — no operator fallback | CLI unusable without AWS credentials (breaks in-cluster CI/CD) |
| `kubectl microvm exec` same problem | Same |
| No Dockerfile for `operator-auth-agent` sidecar | Image can't be built or pushed |
| No integration tests for `MicroVMTokenResource` or `PodMutatingWebhook` | No test coverage |

---

## 1. Security: TokenReview → SubjectAccessReview

### How it works

When a pod calls `POST .../microvms/{name}/token`, it presents its ServiceAccount Bearer token.
The operator must:
1. **`TokenReview`**: exchange the Bearer token for a username + groups (who is calling?)
2. **`SubjectAccessReview`**: check if that identity can `create` on `microvms/token` for this VM

Without step 1, the SAR checks permissions for nobody — useless.

### Implementation

```java
// In MicroVMTokenResource.isAuthorized()
// Step 1: resolve caller identity
TokenReview tr = k8s.authentication().v1().tokenReview().create(
    new TokenReviewBuilder()
        .withNewSpec().withToken(callerToken).endSpec()
        .build());
if (!Boolean.TRUE.equals(tr.getStatus().getAuthenticated())) {
    return false;  // invalid/expired token
}
String username = tr.getStatus().getUser().getUsername();
List<String> groups = tr.getStatus().getUser().getGroups();

// Step 2: check RBAC for the resolved identity
SubjectAccessReview sar = k8s.authorization().v1().subjectAccessReview().create(
    new SubjectAccessReviewBuilder()
        .withNewSpec()
            .withUser(username)
            .withGroups(groups)
            .withNewResourceAttributes()
                .withGroup("lambda.aws.amazon.com")
                .withResource("microvms")
                .withSubresource("token")
                .withVerb("create")
                .withNamespace(namespace)
                .withName(vmName)
            .endResourceAttributes()
        .endSpec()
        .build());
return Boolean.TRUE.equals(sar.getStatus().getAllowed());
```

The operator's own ServiceAccount needs `authentication.k8s.io/tokenreviews: create` and
`authorization.k8s.io/subjectaccessreviews: create` — both go in the `ClusterRole`.

---

## 2. Helm: Register PodMutatingWebhook

### MutatingWebhookConfiguration addition

The existing `charts/.../templates/mutatingwebhookcfg.yaml` (or new file) must add:

```yaml
- name: pod-inject.lambda.aws.amazon.com
  admissionReviewVersions: ["v1"]
  clientConfig:
    service:
      name: {{ include "..service-name" . }}
      namespace: {{ .Release.Namespace }}
      path: /mutate-pod
  rules:
    - apiGroups: [""]
      apiVersions: ["v1"]
      resources: ["pods"]
      operations: ["CREATE"]
  namespaceSelector:
    matchLabels:
      lambda.microvm.auth/inject: "enabled"   # opt-in per namespace
  failurePolicy: Ignore   # never block pod creation on webhook error
  sideEffects: None
```

**Key design decisions:**
- `failurePolicy: Ignore` — the webhook must never block pod startup if the operator is down
- `namespaceSelector` — opt-in: operators label namespaces where injection is wanted
- Only fires on `CREATE` — no injection on `UPDATE` (pods are immutable once running)

### Opt-in namespace label

```bash
kubectl label namespace my-app lambda.microvm.auth/inject=enabled
```

---

## 3. CLI Fallback: Operator Sub-Resource First, AWS Direct Second

### Design

`kubectl microvm token` and `kubectl microvm exec` should work in two modes:

**Mode A — Operator sub-resource (preferred, works in-cluster without AWS credentials):**
```
POST https://kubernetes.default.svc/apis/lambda.aws.amazon.com/v1alpha1/namespaces/{ns}/microvms/{name}/token
Authorization: Bearer <service-account-token or kubeconfig token>
```

**Mode B — Direct AWS (fallback, requires AWS credentials in environment):**
```
LambdaMicrovmsClient → CreateMicrovmAuthToken
```

**Decision logic:**
1. Try operator sub-resource using the kubeconfig credential (same client used for `kubectl get`)
2. If it fails with 501/404/connection-refused (operator doesn't support endpoint) → fall back to AWS
3. If it fails with 403 (RBAC denied) → fail with clear error: "not authorized — ask your admin for microvm-token-requester Role"
4. If it fails with 409/conflict (VM not running) → fail with clear error

**CLI flag `--direct`**: skip operator fallback, call AWS directly always (for testing/debugging)

### User guide

```bash
# In-cluster (pod with ServiceAccount, no AWS credentials needed):
kubectl microvm token --name my-vm
# → uses operator sub-resource automatically

# Local development with AWS credentials:
kubectl microvm token --name my-vm
# → tries operator first, falls back to AWS SDK if operator endpoint not available

# Force direct AWS call (skip operator):
kubectl microvm token --name my-vm --direct
```

---

## 4. operator-auth-agent Dockerfile

```dockerfile
# Multi-stage: build native binary, package into minimal runtime image
FROM quay.io/quarkus/ubi9-quarkus-mandrel-builder-image:jdk-25 AS builder
COPY --chown=quarkus:quarkus . /code
WORKDIR /code
USER quarkus
RUN ./mvnw package -pl operator-auth-agent -am -Dnative -DskipTests \
    -Dquarkus.native.container-build=false

FROM registry.access.redhat.com/ubi9/ubi-minimal:9.4
COPY --from=builder /code/operator-auth-agent/target/*-runner /usr/local/bin/microvm-auth-agent
RUN chmod 775 /usr/local/bin/microvm-auth-agent && chown 1001:root /usr/local/bin/microvm-auth-agent
USER 1001
LABEL org.opencontainers.image.source="https://github.com/codriverlabs/KubeMicroVM"
ENTRYPOINT ["microvm-auth-agent"]
```

---

## 5. Integration Tests

### `MicroVMTokenResourceIT`

Tests for the operator REST endpoint using Fabric8 mock server + Mockito for AWS client.

| Test | What it verifies |
|------|-----------------|
| `createToken_returns200_whenAuthorized` | Valid SAR+TokenReview → calls CreateMicrovmAuthToken → returns authToken + endpoint |
| `createToken_returns401_whenNoBearer` | Missing Authorization header → 401 |
| `createToken_returns403_whenSarDenied` | SAR returns allowed=false → 403 |
| `createToken_returns404_whenVmNotFound` | MicroVM CR doesn't exist → 404 |
| `createToken_returns409_whenVmNotRunning` | MicroVM has no microvmId in status → 409 |
| `createToken_respecsMaxExpiry` | expirationInMinutes > maxExpiryMinutes → clamped |

### `PodMutatingWebhookIT`

Tests for the pod injection webhook.

| Test | What it verifies |
|------|-----------------|
| `mutate_injectsSidecar_whenAnnotationPresent` | Pod with `lambda.microvm.auth: my-vm` → patch adds sidecar + volume + volumeMount |
| `mutate_noOp_whenAnnotationAbsent` | Pod without annotation → allowed=true, no patch |
| `mutate_idempotent_whenSidecarAlreadyPresent` | Pod already has sidecar → no duplicate injection |
| `mutate_usesCustomMountPath_whenAnnotated` | `lambda.microvm.auth/mount-path: /custom` → sidecar uses custom path |
| `mutate_failOpen_onException` | Simulated error → allowed=true (never blocks pod creation) |

### `TokenCommandIT` (CLI)

Tests for `kubectl microvm token` fallback logic.

| Test | What it verifies |
|------|-----------------|
| `token_usesOperatorEndpoint_whenAvailable` | Operator returns 200 → CLI prints token, no AWS call |
| `token_fallsBackToAws_whenOperator404` | Operator returns 404 → falls back to AWS SDK |
| `token_failsWithClearMessage_whenOperator403` | Operator returns 403 → error message explains RBAC |
| `token_usesAwsDirect_whenFlagSet` | `--direct` flag → skips operator, calls AWS directly |

---

## 6. User Guide: End-to-End Token Injection

### Setup (platform admin, once per namespace)

```bash
# 1. Label the namespace to enable sidecar injection
kubectl label namespace my-app lambda.microvm.auth/inject=enabled

# 2. Grant the pod's ServiceAccount permission to get tokens for specific VMs
kubectl apply -f - <<EOF
kind: Role
apiVersion: rbac.authorization.k8s.io/v1
metadata:
  name: my-app-microvm-token
  namespace: my-app
rules:
- apiGroups: ["lambda.aws.amazon.com"]
  resources: ["microvms/token"]
  resourceNames: ["my-agent-vm"]   # scope to specific VM
  verbs: ["create"]
---
kind: RoleBinding
apiVersion: rbac.authorization.k8s.io/v1
metadata:
  name: my-app-microvm-token
  namespace: my-app
subjects:
- kind: ServiceAccount
  name: my-app
  namespace: my-app
roleRef:
  kind: Role
  name: my-app-microvm-token
  apiGroup: rbac.authorization.k8s.io
EOF
```

### Application pod (developer, per deployment)

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: my-app
  namespace: my-app
spec:
  template:
    metadata:
      annotations:
        lambda.microvm.auth: my-agent-vm           # which VM to get tokens for
        lambda.microvm.auth/expires: "60"           # optional: token expiry in minutes
        lambda.microvm.auth/mount-path: /vm-creds   # optional: override default mount path
    spec:
      serviceAccountName: my-app
      containers:
      - name: app
        image: my-app:latest
        # microvm-auth-agent sidecar injected automatically
        # /var/run/microvm/auth-token    ← read this for X-aws-proxy-auth header
        # /var/run/microvm/endpoint      ← read this for the VM's HTTPS hostname
        # /var/run/microvm/.ready        ← wait for this before making VM calls
```

### Reading the token in application code

```python
import pathlib

def get_microvm_token():
    return pathlib.Path("/var/run/microvm/auth-token").read_text().strip()

def get_microvm_endpoint():
    return pathlib.Path("/var/run/microvm/endpoint").read_text().strip()

def call_microvm(path, body):
    endpoint = get_microvm_endpoint()
    token = get_microvm_token()
    return requests.post(
        f"https://{endpoint}{path}",
        headers={"X-aws-proxy-auth": token},
        json=body
    )
```

```javascript
const fs = require('fs');

function getMicrovmToken() {
  return fs.readFileSync('/var/run/microvm/auth-token', 'utf8').trim();
}
```

### Waiting for readiness

The auth-agent writes `/var/run/microvm/.ready` once the first token is available.
Use an init container or a startup probe if your app must not start before the VM is reachable:

```yaml
initContainers:
- name: wait-for-token
  image: busybox
  command: ["sh", "-c", "until [ -f /var/run/microvm/.ready ]; do sleep 1; done"]
  volumeMounts:
  - name: microvm-token
    mountPath: /var/run/microvm
```

### Operator IAM requirements (platform admin)

The operator's Pod Identity role needs two additional permissions:

```json
{
  "Statement": [
    {
      "Effect": "Allow",
      "Action": "lambda:CreateMicrovmAuthToken",
      "Resource": "*"
    }
  ]
}
```

Plus the operator's ServiceAccount needs cluster RBAC for TokenReview + SubjectAccessReview
(added to `charts/kube-microvm-operator/templates/clusterrole.yaml`):

```yaml
- apiGroups: ["authentication.k8s.io"]
  resources: ["tokenreviews"]
  verbs: ["create"]
- apiGroups: ["authorization.k8s.io"]
  resources: ["subjectaccessreviews"]
  verbs: ["create"]
```

---

## Files to Change

| File | Change |
|------|--------|
| `operator-controller/.../rest/MicroVMTokenResource.java` | Add TokenReview step before SAR |
| `charts/.../templates/mutatingwebhookcfg.yaml` | Add `/mutate-pod` webhook entry |
| `charts/.../templates/clusterrole.yaml` | Add tokenreviews + subjectaccessreviews RBAC |
| `operator-cli/.../commands/TokenCommand.java` | Add operator fallback, `--direct` flag |
| `operator-cli/.../commands/ExecCommand.java` | Add operator fallback, `--direct` flag |
| `Dockerfile.auth-agent` | New: sidecar container image |
| `.github/workflows/native-build.yml` | Add auth-agent to native build + release matrix |
| `operator-tests/.../MicroVMTokenResourceIT.java` | New: 6 tests |
| `operator-tests/.../PodMutatingWebhookIT.java` | New: 5 tests |
| `operator-tests/.../TokenCommandIT.java` | New: 4 tests |
