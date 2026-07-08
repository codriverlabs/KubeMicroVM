# UAT: kubectl microvm exec (ShellAuthToken)

**Status**: ⚠️ Partial — integration test added, E2E blocked by infrastructure prerequisite  
**Branch**: `feature/exec-shellauth`  
**Date**: 2026-07-08

---

## What Was Done

Added integration test for `createShellAuthToken` in `DefaultMicroVMClientIT`:
- `createShellAuthToken_returnsTokenMap` — mocks SDK, verifies token map returned ✅

75 integration tests pass (was 74).

---

## E2E Blocker

`microvm exec --direct` requires the VM to have a `SHELL_INGRESS` network connector
configured. Without it, the API returns:

```
Shell access requires SHELL_INGRESS network connector to be configured on the MicroVM.
(Status Code: 400)
```

`SHELL_INGRESS` is a specific network connector type that must be pre-provisioned as
part of the account/VPC setup before VMs can be created with shell access. This is
not the same as the `VPC_EGRESS` connectors used for networking tests.

**To complete this E2E**, a `SHELL_INGRESS` connector must be available in the account.
Contact AWS support or refer to the Lambda MicroVMs shell access documentation to
provision the connector.

---

## Sign-Off

- [x] Integration test: createShellAuthToken mocked test ✅
- [ ] E2E: microvm exec returns shell credentials — **BLOCKED** (SHELL_INGRESS required)
