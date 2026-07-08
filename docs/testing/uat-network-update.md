# UAT: UpdateNetworkConnector E2E

**Status**: ✅ Test passes  
**Branch**: `feature/e2e-network-update`  
**Cluster**: `ecp-us1` (us-east-1)  
**Date**: 2026-07-08

---

## Test Results

| Test | Result | Evidence |
|------|--------|----------|
| NU-01: Subnet update triggers UpdateNetworkConnector | ✅ PASS | Connector stays ACTIVE, gen bumped |

---

## NU-01 Detail

1. Created `update-test-net` with 1 subnet → ACTIVE (gen=1)
2. Patched `spec.subnetIds` to add second subnet
3. Reconciler detected `observedGeneration` change → called `UpdateNetworkConnector`
4. Connector remained ACTIVE, `status.observedGeneration=2` immediately

Note: Update was instantaneous (ACTIVE→ACTIVE) — the Lambda Core API handles
the subnet reconfiguration without going through PENDING for minor updates.

---

## Sign-Off

- [x] NU-01: Subnet update triggers UpdateNetworkConnector, stays ACTIVE ✅
- [x] Resources torn down
