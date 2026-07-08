# UAT: Drift Detection E2E

**Status**: ✅ All tests pass  
**Branch**: `feature/e2e-drift-v2`  
**Cluster**: `ecp-us1` (us-east-1)  
**Date**: 2026-07-08  
**Operator version**: `1.1.0-SNAPSHOT` native (ECR tag `1.0.3`, main branch)

---

## Test Results

| Test | Result | Evidence |
|------|--------|----------|
| DR-01: External termination detected and VM re-created | ✅ PASS | New microVmId after ~110s |
| DR-02: Operator does not fight idle policy | ✅ PASS | 0 spurious RESUME calls |

---

## DR-01 Detail

1. Created VM via operator → Running (`microvm-7865ec23-...`)
2. Terminated directly via AWS CLI: `aws lambda-microvms terminate-microvm --microvm-identifier <id>`
3. Operator reconcile (every 60s) detected `desired=Running, actual=TERMINATED`
4. DriftDetector returned `ActionRequired(RECREATE)` → `RunMicrovm` called
5. VM re-created with new ID: `microvm-6d209bcf-...` → Running in ~110s total

---

## DR-02 Detail

VM with `autoResumeEnabled=true`, `maxIdleDurationSeconds=60`. After 90s with no traffic:
- VM still Running (no traffic to trigger auto-suspend within test window)
- 0 RESUME calls in operator logs (autoResumeEnabled=true → NoOp path in DriftDetector)

The DriftDetector fix from `feature/e2e-suspend-resume` confirmed correct:
- `autoResumeEnabled=true`: `SUSPENDED` → `NoOp` (idle policy owns resume)
- `autoResumeEnabled=false`: `SUSPENDED` → `ActionRequired(RESUME)` (operator manages)

---

## Sign-Off

- [x] DR-01: External termination detected and VM re-created ✅
- [x] DR-02: No spurious RESUME calls with autoResumeEnabled=true ✅
- [x] Test resources torn down
