# UAT: Quota Guardrails

**Status**: ⏳ Pending execution  
**Branch**: `feature/quota-guardrails-replicaset`  
**Cluster**: _(fill in)_  
**Date**: _(fill in)_  
**Operator version**: _(fill in)_  
**Tester**: _(fill in)_

Test plan: [`docs/testing/burst-test-plan.md`](burst-test-plan.md)

---

## Results

| Test | Result | Notes |
|------|--------|-------|
| T-01: QuotaGuard startup log | ⏳ | |
| T-02: Token burst (50 concurrent) | ⏳ | |
| T-03: Suspend cascade pacing | ⏳ | |
| T-04: QuotaDiscovery cross-check | ⏳ / N/A | |
| T-05: Operator health after burst | ⏳ | |

---

## T-01: QuotaGuard Startup Log

**Operator log output**:
```
(paste here)
```

**Pass**: ☐ `QuotaGuard initialised` present  
**Pass**: ☐ DefaultQuotaPolicy in brackets  
**Pass**: ☐ Rates match account defaults or discovered values  
**Pass**: ☐ No QUOTA MISMATCH warnings  

**Overall**: ⏳ PASS / FAIL

---

## T-02: Token Burst (50 Concurrent Requests)

**Configuration**:
- Token parallelism: 50
- Target VM: `burst-test-vm`
- Token endpoint: operator REST / --direct (circle one)

**Results**:
```
(paste xargs output here)
```

| Metric | Value |
|--------|-------|
| Total requests | 50 |
| Success (200) | |
| Backpressure (429) | |
| Errors (other) | |
| Elapsed (ms) | |
| Success rate | |

**Previous result (2026-07-06)**: 0/256 (0%)

**Pass**: ☐ OK > 0  
**Pass**: ☐ FAIL (non-429) == 0  

**Overall**: ⏳ PASS / FAIL

---

## T-03: Suspend Cascade Pacing

**Configuration**:
- ReplicaSet: `cascade-test-rs`
- Replicas: 20
- Expected minimum elapsed: 10s (20 VMs / 2 req/s)

**Results**:
```
(paste poll output here)
```

| Metric | Value |
|--------|-------|
| VMs suspended | / 20 |
| Elapsed (s) | |
| Expected minimum (s) | 10 |
| Pacing active | YES / NO |
| 429 errors in logs | |

**Pass**: ☐ All VMs reach Suspended  
**Pass**: ☐ Elapsed ≥ N/2 seconds  
**Pass**: ☐ Zero 429 errors in operator logs  

**Overall**: ⏳ PASS / FAIL

---

## T-04: QuotaDiscovery Cross-Check

> Mark N/A if `--quota-discovery=runtime` was not enabled at install time.

**Runtime discovery enabled**: YES / NO / N/A

**Log output**:
```
(paste here)
```

**Overall**: ⏳ PASS / FAIL / N/A

---

## T-05: Operator Health After Burst

```
(paste health check output here)
```

| Check | Result |
|-------|--------|
| /q/health/live | |
| /q/health/ready | |
| Pod restarts | |
| Reconciliation metrics present | |

**Overall**: ⏳ PASS / FAIL

---

## Sign-Off

- [ ] All tests executed
- [ ] Results documented above
- [ ] Test CRs torn down
- [ ] Results committed to `docs/testing/burst-test-<date>/`
- [ ] `docs/design/api-implementation-status.md` updated
- [ ] Ready to merge to main

**Sign-off**: _(name + date)_
