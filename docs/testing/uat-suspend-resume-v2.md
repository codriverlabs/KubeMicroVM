# UAT: SuspendMicrovm / ResumeMicrovm

**Status**: ⚠️ Partially complete — bugs found and fixed, SR-02 E2E pending merge  
**Branch**: `feature/e2e-suspend-resume`  
**Cluster**: `ecp-us1` (us-east-1)  
**Date**: 2026-07-08

---

## Bugs Found During This E2E

### Bug 1: DriftDetector never calls ResumeMicrovm (FIXED)

**Symptom**: After patching `spec.desiredState: Running` on a Suspended VM, the
operator reconciles every minute but never calls `ResumeMicrovm`. The VM stays
Suspended indefinitely.

**Root cause**: Commit `a8d0b5e` changed `detectRunningDrift(SUSPENDED)` from
`ActionRequired(RESUME)` to `NoOp` to avoid fighting the idle policy. But the
change was too broad — it suppressed the RESUME action even when the user
explicitly changed `desiredState=Running`.

**Fix**: `DriftDetector.detectDrift()` now accepts `autoResumeEnabled` flag:
- `autoResumeEnabled=true`: `SUSPENDED` → `NoOp` (idle policy owns resume)
- `autoResumeEnabled=false`: `SUSPENDED` → `ActionRequired(RESUME)`

`MicroVMReconciler` passes `spec.autoResumeEnabled` to `detectDrift()`.

**Tests added**: `suspendedWithDesiredRunningAndAutoResumeEnabledReturnsNoOp`,
`suspendedWithDesiredRunningAndAutoResumeDisabledReturnsResume`

---

### Bug 2: operator-webhook not a declared dependency of operator-controller

**Symptom**: `/validate-microvm` returns 404. Webhook rejections don't fire.

**Root cause**: `operator-webhook` was not declared in `operator-controller/pom.xml`.
It worked by accident when the full Maven reactor ran all modules, but broke when
`build-local.sh --only operator` was used (only builds declared dependencies).

**Fix**: Added `operator-webhook` as explicit dependency in `operator-controller/pom.xml`.

**Note**: `main` already has this fix (added when `operator-spi` was added).
This branch predates those changes.

---

## Test Results

| Test | Result | Notes |
|------|--------|-------|
| SR-01: Suspend Running VM | ✅ PASS | `status.state → Suspended` in ~60s |
| SR-02: Resume Suspended VM | ⚠️ Fix applied, pending full E2E | DriftDetector bug fixed; retry after merge to main |
| SR-03: Token works after resume | ⏳ Pending SR-02 | |

### SR-01 Detail

```
kubectl patch microvm suspend-test-vm -n default \
  --type=merge -p '{"spec":{"desiredState":"Suspended"}}'
```
- VM transitioned from `Running` → `Suspending` → `Suspended` ✅
- Operator log: `"Drift correction: suspend"` ✅
- AWS state confirmed SUSPENDED via CLI ✅

### SR-02 Status

Before fix: operator reconciled every 60s, AWS returned SUSPENDED, but
`detectDrift(Running, SUSPENDED)` → `NoOp` due to Bug 1. No RESUME call made.

After fix applied to this branch: manual CLI test confirmed `resume-microvm`
works instantly. The operator will now call it when `desired=Running, actual=SUSPENDED,
autoResumeEnabled=false`.

Full E2E verification of SR-02 and SR-03 to be completed after this branch is
merged to main and deployed with the correct operator-webhook dependency.

---

## Notes on autoResumeEnabled Behaviour

| desiredState | actual AWS state | autoResumeEnabled | Operator action |
|-------------|-----------------|-------------------|-----------------|
| Running | Suspended | false | **RESUME** (operator manages lifecycle) |
| Running | Suspended | true | **NoOp** (idle policy manages; VM auto-resumes on traffic) |
| Suspended | Suspended | any | NoOp (aligned) |

When `autoResumeEnabled=true`, the operator trusts the idle policy to resume
the VM when traffic arrives. Patching `desiredState=Running` while the VM is
Suspended AND `autoResumeEnabled=true` has NO immediate effect — the VM will
resume when traffic hits it.

To force an immediate resume regardless of idle policy:
1. Set `autoResumeEnabled=false`
2. Set `desiredState=Running`
3. Operator calls `ResumeMicrovm`

---

## Sign-Off Checklist

- [x] SR-01: Suspend verified on real cluster
- [x] DriftDetector bug found and fixed
- [x] operator-webhook dependency bug found and fixed (this branch)
- [x] 2 new DriftDetector unit tests added
- [ ] SR-02: Resume verified on real cluster (pending merge)
- [ ] SR-03: Token works after resume (pending)
- [ ] Merge to main
