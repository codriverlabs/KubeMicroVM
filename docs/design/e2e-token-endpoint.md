# Design: Token REST Endpoint E2E Verification

**Status**: Code complete, integration tests pass — E2E only  
**Branch**: `feature/e2e-token-endpoint`  
**Priority**: P1

---

## What Exists

The operator exposes a REST endpoint for in-cluster token requests:
```
POST /apis/lambda.aws.amazon.com/v1alpha1/namespaces/{ns}/microvms/{name}/token
```

The endpoint (`MicroVMTokenResource`):
1. Validates the caller's Kubernetes ServiceAccount token via `TokenReview`
2. Checks RBAC via `SubjectAccessReview` (must have `create` on `microvms/token`)
3. Calls `CreateMicrovmAuthToken` on AWS
4. Returns `{authToken, endpoint, expiresAt}`

7 integration tests pass. Never tested on a real cluster.

## What Is Missing

E2E verification that the full flow works:
1. Pod → operator HTTPS endpoint (port 8443)
2. Operator → Kubernetes TokenReview API
3. Operator → Kubernetes SubjectAccessReview API
4. Operator → AWS CreateMicrovmAuthToken
5. Token returned to pod

## Prerequisites

- Operator running with TLS on port 8443 (already the case)
- A ServiceAccount with `create` on `microvms/token` sub-resource
- A running MicroVM

## Test Plan

### Setup
```bash
# Create ServiceAccount and RBAC
kubectl apply -f - <<EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  name: token-endpoint-test-sa
  namespace: default
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: token-endpoint-test-role
  namespace: default
rules:
  - apiGroups: ["lambda.aws.amazon.com"]
    resources: ["microvms/token"]
    verbs: ["create"]
    resourceNames: ["token-test-vm"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: token-endpoint-test-binding
  namespace: default
subjects:
  - kind: ServiceAccount
    name: token-endpoint-test-sa
roleRef:
  kind: Role
  name: token-endpoint-test-role
  apiGroup: rbac.authorization.k8s.io
EOF

# Create a Running VM
kubectl apply -f - <<EOF
apiVersion: lambda.aws.amazon.com/v1alpha1
kind: MicroVM
metadata:
  name: token-test-vm
  namespace: default
spec:
  imageRef: qs-test-app
  desiredState: Running
  maxIdleDurationSeconds: 3600
  suspendedDurationSeconds: 7200
EOF
kubectl wait microvm/token-test-vm --for=jsonpath='{.status.state}'=Running --timeout=2m
```

### TE-01: Request token via operator endpoint from a pod
```bash
# Run a test pod with the test SA
kubectl run token-test-pod \
  --image=curlimages/curl \
  --serviceaccount=token-endpoint-test-sa \
  --restart=Never \
  --rm -it \
  -- sh -c '
    SA_TOKEN=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)
    curl -sk \
      -H "Authorization: Bearer $SA_TOKEN" \
      -H "Content-Type: application/json" \
      -d "{\"expirationInMinutes\": 5}" \
      https://kube-microvm-operator.kube-microvm.svc:443/apis/lambda.aws.amazon.com/v1alpha1/namespaces/default/microvms/token-test-vm/token
  '
```
**Pass**: JSON response with `authToken` field, non-empty

### TE-02: Unauthorized SA rejected (403)
```bash
# Pod without RBAC — should get 403
kubectl run token-unauthorized-pod \
  --image=curlimages/curl \
  --restart=Never \
  --rm -it \
  -- sh -c '
    SA_TOKEN=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)
    STATUS=$(curl -sk -o /dev/null -w "%{http_code}" \
      -H "Authorization: Bearer $SA_TOKEN" \
      -H "Content-Type: application/json" \
      -d "{\"expirationInMinutes\": 5}" \
      https://kube-microvm-operator.kube-microvm.svc:443/apis/lambda.aws.amazon.com/v1alpha1/namespaces/default/microvms/token-test-vm/token)
    echo "HTTP status: $STATUS"
  '
```
**Pass**: HTTP 403

### TE-03: Token works to call VM endpoint
```bash
# Use token from TE-01 to call the MicroVM
ENDPOINT=$(kubectl get microvm token-test-vm -o jsonpath='{.status.endpointUrl}')
curl -sk -H "X-aws-proxy-auth: <token-from-TE-01>" "https://$ENDPOINT/"
```
**Pass**: HTTP 200 from VM

### Teardown
```bash
kubectl delete microvm token-test-vm -n default --timeout=30s
kubectl delete serviceaccount,role,rolebinding -l app=token-endpoint-test -n default
```

## Implementation Checklist

- [ ] E2E: SA with correct RBAC gets token from operator endpoint (TE-01)
- [ ] E2E: SA without RBAC gets 403 (TE-02)
- [ ] E2E: token from operator endpoint works to call VM (TE-03)
- [ ] Update `docs/design/api-implementation-status.md`
- [ ] Create `docs/testing/uat-token-endpoint.md` with results
