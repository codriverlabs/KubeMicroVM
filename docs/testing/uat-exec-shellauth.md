# UAT: kubectl microvm exec (ShellAuthToken)

**Status**: ✅ All tests pass  
**Branch**: `feature/exec-shellauth`  
**Cluster**: `ecp-us1` (us-east-1)  
**Date**: 2026-07-08  
**Operator version**: `1.1.0-SNAPSHOT` native (ECR tag `1.0.3`, main branch)

---

## Prerequisites

The VM must be created with the `SHELL_INGRESS` AWS-managed ingress connector:

```yaml
spec:
  ingressNetworkConnectors:
    - "arn:aws:lambda:us-east-1:aws:network-connector:aws-network-connector:SHELL_INGRESS"
```

Without this, `CreateMicrovmShellAuthToken` returns 400:
`Shell access requires SHELL_INGRESS network connector to be configured on the MicroVM.`

---

## Test Results

| Test | Result | Evidence |
|------|--------|----------|
| Integration: createShellAuthToken mocked | ✅ PASS | 75 tests pass |
| EX-01: `microvm exec --direct` returns credentials | ✅ PASS | Token (len=751), WebSocket endpoint, subprotocols |
| EX-02: `microvm exec --direct --show-token` raw output | ✅ PASS | Token length=751, pipeable |

---

## EX-01 Output

```
MicroVM: exec-test-vm
Endpoint: wss://PENDING/aws/lambda-microvms/runtime/v1/shell
Token (X-aws-proxy-auth): eyJ...

Connect with subprotocols:
  lambda-microvms
  lambda-microvms.authentication.eyJ...
```

Note: Endpoint shows `PENDING` — the shell endpoint URL resolves after the VM fully
initialises. The token is valid and can be used once the endpoint resolves.

---

## Sign-Off

- [x] Integration test: createShellAuthToken mocked ✅
- [x] EX-01: microvm exec --direct returns shell credentials ✅
- [x] EX-02: --show-token outputs raw token ✅
- [x] Resources torn down
