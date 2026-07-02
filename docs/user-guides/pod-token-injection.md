# User Guide: Pod Token Injection (Sidecar)

This guide explains how to access MicroVM endpoints from pods **without embedding
AWS credentials** in your application, using automatic sidecar injection.

> For full RBAC details see [rbac.md](rbac.md).
> For manual token fetching (no sidecar) see the [CLI reference](cli-reference.md#microvm-token).

## How It Works

KubeMicroVM provides a sidecar injection mechanism. When you annotate a pod
with `lambda.microvm.auth: <vm-name>`, the operator automatically injects
an auth-agent sidecar that:

- Fetches an AWS auth token from the operator using your pod's Kubernetes identity
- Writes it to `/var/run/microvm/token` (in-memory volume, never hits disk)
- Refreshes it before expiry

Your application just reads the token from a file — no AWS SDK, no credentials.

## Prerequisites

1. The namespace must be labelled for pod injection
2. The pod's ServiceAccount must have RBAC permission to request tokens for the VM

## Step-by-Step Setup

### 1. Enable injection in the namespace

```bash
kubectl label namespace default lambda.microvm.auth/inject=enabled
```

### 2. Create a ServiceAccount with token RBAC

Replace `my-app-sa` and `my-vm` with your values:

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: my-app-sa
  namespace: default
---
# Grants this SA permission to get auth tokens for 'my-vm' only
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: microvm-token-my-vm
  namespace: default
rules:
- apiGroups: ["lambda.aws.amazon.com"]
  resources: ["microvms/token"]
  verbs: ["create"]
  resourceNames: ["my-vm"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: my-app-sa-microvm-token
  namespace: default
subjects:
- kind: ServiceAccount
  name: my-app-sa
  namespace: default
roleRef:
  kind: Role
  name: microvm-token-my-vm
  apiGroup: rbac.authorization.k8s.io
```

> **Note**: The `resourceNames` field scopes permission to a specific VM.
> To allow access to multiple VMs, list them: `resourceNames: ["vm-a", "vm-b"]`

### 3. Annotate your pod

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: my-app
  namespace: default
  annotations:
    lambda.microvm.auth: my-vm        # required: VM name
    # lambda.microvm.auth/mount-path: /var/run/microvm  # optional
    # lambda.microvm.auth/expires: "30"                 # optional, minutes
spec:
  serviceAccountName: my-app-sa       # must match the SA in Step 2
  containers:
  - name: app
    image: my-app:latest
    # The sidecar is injected automatically — no changes needed here
    # Token will be available at /var/run/microvm/token
```

### 4. Use the token in your application

The sidecar writes three files to `/var/run/microvm/`:

| File | Content |
|------|---------|
| `token` | Auth token — use as `X-aws-proxy-auth` header |
| `endpoint` | MicroVM endpoint hostname |
| `expires_at` | Token expiry (ISO 8601) |

**Shell:**
```bash
TOKEN=$(cat /var/run/microvm/token)
ENDPOINT=$(cat /var/run/microvm/endpoint)
curl -H "X-aws-proxy-auth: $TOKEN" "https://$ENDPOINT/"
```

**Python:**
```python
token    = open("/var/run/microvm/token").read().strip()
endpoint = open("/var/run/microvm/endpoint").read().strip()

import urllib.request
req = urllib.request.Request(f"https://{endpoint}/")
req.add_header("X-aws-proxy-auth", token)
resp = urllib.request.urlopen(req)
```

**Node.js:**
```javascript
const fs = require('fs');
const https = require('https');

const token    = fs.readFileSync('/var/run/microvm/token', 'utf8').trim();
const endpoint = fs.readFileSync('/var/run/microvm/endpoint', 'utf8').trim();

const req = https.request({ hostname: endpoint, path: '/',
  headers: { 'X-aws-proxy-auth': token } }, res => { ... });
```

## What Gets Injected

When the webhook fires, it adds to your pod spec:

```yaml
spec:
  volumes:
  - name: microvm-token          # injected
    emptyDir:
      medium: Memory             # token never touches disk
  containers:
  - name: app
    volumeMounts:
    - name: microvm-token        # injected
      mountPath: /var/run/microvm
      readOnly: true
  - name: microvm-auth-agent     # injected sidecar
    image: ghcr.io/plasticity-of-cloud/microvm-auth-agent:latest
    env:
    - name: MICROVM_NAME
      value: my-vm
    - name: MICROVM_NAMESPACE
      value: default
    - name: MOUNT_PATH
      value: /var/run/microvm
    - name: TOKEN_EXPIRY_MINUTES
      value: "30"
    resources:
      requests: { cpu: 5m, memory: 16Mi }
      limits:   { cpu: 50m, memory: 32Mi }
    volumeMounts:
    - name: microvm-token
      mountPath: /var/run/microvm
```

## Multiple VMs per Pod

To access multiple VMs from one pod, use separate mount paths per VM:

```yaml
annotations:
  lambda.microvm.auth: vm-a
  lambda.microvm.auth/mount-path: /var/run/microvm/vm-a
```

> **Note**: Multi-VM injection (multiple annotations) is a post-GA feature.
> For now, annotate one VM per pod or use `kubectl microvm token` directly.

## RBAC Notes

- The Role uses `resourceNames` to scope to a specific VM — **principle of least privilege**
- If the SA lacks permission, the operator returns `403 Forbidden` and the
  sidecar logs the error but does **not** block pod creation (FailurePolicy: Ignore)
- Use a separate ServiceAccount per application — avoid sharing SAs across workloads

## Troubleshooting

**Token file is empty or missing:**
```bash
kubectl logs my-app -c microvm-auth-agent
# Look for: "ERROR: Failed to get token" or "403 Forbidden"
```

**Sidecar not injected:**
- Check namespace label: `kubectl get namespace default --show-labels`
- Verify webhook is active: `kubectl get mutatingwebhookconfiguration`
- Check operator logs: `kubectl logs -n kube-microvm deploy/kube-microvm-operator`

**403 from operator:**
- SA missing Role or RoleBinding
- `resourceNames` doesn't include the VM name
- Run: `kubectl auth can-i create microvms/token --as=system:serviceaccount:default:my-app-sa -n default`
