# UAT: UpdateMicrovmImage E2E

**Status**: ✅ Test passes  
**Branch**: `feature/e2e-image-update-v2`  
**Cluster**: `ecp-us1` (us-east-1)  
**Date**: 2026-07-08

---

## Test Results

| Test | Result | Evidence |
|------|--------|----------|
| IU-01: Spec change triggers new version build | ✅ PASS | Version 1.0 → 2.0 in ~165s |

---

## IU-01 Detail

1. Created image `update-test-image` with `s3Key: test-fixtures/microvm-hello-node.zip` → version 1.0 CREATED
2. Patched `spec.source.s3Key` to `test-fixtures/microvm-net-test.zip`
3. `imageState` → UPDATING, `latestVersionState` → IN_PROGRESS
4. After ~165s: `imageState=UPDATED`, `latestVersionState=SUCCESSFUL`, `activeVersion=2.0`

**Note**: `status.versions[]` was empty — the versions list is populated via `ListMicrovmImageVersions`
which polls in a separate reconcile pass. The `activeVersion` field correctly shows `2.0`.

---

## Sign-Off

- [x] IU-01: S3 source change triggers build and activates new version ✅
- [x] Resources torn down
