# UAT: MicroVMReplicaSet E2E

**Status**: ✅ All tests pass  
**Branch**: `feature/e2e-replicaset-v2`  
**Cluster**: `ecp-us1` (us-east-1)  
**Date**: 2026-07-08  
**Operator version**: `1.1.0-SNAPSHOT` native (ECR tag `1.0.3`, main branch)

---

## Test Results

| Test | Result | Key Numbers |
|------|--------|-------------|
| RS-01: Create 3 VMs | ✅ PASS | 3/3 Running in ~20s |
| RS-02: Scale up to 5 | ✅ PASS | 5/5 Running in ~70s |
| RS-03: Scale down to 2 | ✅ PASS | 2/2 Running, excess terminated in ~40s |
| RS-04: Suspend cascade | ✅ PASS | 2/2 Suspended in 63s, 0 throttle errors |
| RS-05: Delete cascades all VMs | ✅ PASS | 0 VMs remaining after RS delete |

---

## RS-04 Cascade Timing

Suspend cascade for 2 VMs took 63s (paced at SuspendMicrovm 2 req/s via QuotaGuard).
Zero 429/throttle errors in operator logs — rate limiter working correctly.

---

## Sign-Off

- [x] RS-01: Create 3 VMs ✅
- [x] RS-02: Scale up to 5 ✅
- [x] RS-03: Scale down to 2 ✅
- [x] RS-04: Suspend cascade paced, no throttling ✅
- [x] RS-05: Delete cascades all children ✅
- [x] Test resources torn down
