# UAT: Token REST Endpoint (In-Cluster, No AWS Credentials)

**Status**: ✅ All tests pass  
**Branch**: `feature/e2e-token-endpoint`  
**Cluster**: `ecp-us1` (us-east-1)  
**Date**: 2026-07-08  
**Operator version**: `1.1.0-SNAPSHOT` native (ECR tag `1.0.3`, main branch)

---

## What Was Tested

The operator exposes a REST endpoint for in-cluster token requests:
```
POST /apis/lambda.aws.amazon.com/v1alpha1/namespaces/{ns}/microvms/{name}/token
```

Flow: Pod SA token → operator (TokenReview + SubjectAccessReview) → AWS CreateMicrovmAuthToken → returned to caller.

No AWS credentials required in the calling pod — only a Kubernetes ServiceAccount
with `create` on `microvms/token` sub-resource.

---

## Test Results

| Test | Result | Evidence |
|------|--------|----------|
| TE-01: Authorized SA gets token | ✅ PASS | HTTP 200, `authToken` field present (len=751) |
| TE-02: Unauthorized SA gets 403 | ✅ PASS | HTTP 403, `"not authorized — ask your admin..."` |
| TE-03: Token from endpoint calls VM | ✅ PASS | `{"status":"ok","path":"/","ts":"..."}` from VM |

---

## TE-01 Detail

Setup:
```yaml
# ServiceAccount + Role (create on microvms/token for token-test-vm only)
# RoleBinding
```

Call from within cluster pod:
```bash
curl -sk \
  -H "Authorization: Bearer $SA_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"expirationInMinutes": 5}' \
  https://kube-microvm-operator.kube-microvm.svc:443/apis/lambda.aws.amazon.com/v1alpha1/namespaces/default/microvms/token-test-vm/token
```

Response: HTTP 200, `{"authToken": "eyJ...", "endpoint": "PENDING", "expiresAt": "..."}`

---

## TE-02 Detail

Default ServiceAccount (no `microvms/token` RBAC):

Response: HTTP 403, `{"error": "not authorized — ask your admin to grant create on microvms/token for token-test-vm"}`

---

## TE-03 Detail

Token from TE-01 used to call VM endpoint directly:
```bash
curl -sk -H "X-aws-proxy-auth: $AUTH_TOKEN" "https://$ENDPOINT/"
```
Response: `{"status":"ok","path":"/","ts":"2026-07-08T11:53:21.686Z"}`

---

## Notes

- The endpoint URL in TE-01 response showed `"endpoint": "PENDING"` because the VM
  endpoint URL resolves asynchronously after VM creation. Using `status.endpointUrl`
  from the CR (populated by the reconciler poll) is the correct way to get the endpoint.
  The token itself is valid regardless of the endpoint field in the response.

---

## Sign-Off

- [x] TE-01: Authorized SA gets token from operator endpoint ✅
- [x] TE-02: Unauthorized SA gets 403 with clear message ✅
- [x] TE-03: Token from operator endpoint used to call VM ✅
- [x] Test resources torn down
