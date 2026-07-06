# UAT: MicroVM Image Update (New Version)

## Test Cases

| ID | Test | Steps | Expected |
|----|------|-------|----------|
| IMG-UPD-01 | Create initial image | Apply MicroVMImage CR | Image CREATED, v1.0 ACTIVE |
| IMG-UPD-02 | Update source code | Upload new zip to S3, edit CR `source.s3Key` | New version builds (v2.0 IN_PROGRESS → SUCCESSFUL) |
| IMG-UPD-03 | Auto-activate new version | Wait for build to complete | `status.activeVersion` advances to 2.0 |
| IMG-UPD-04 | Run VM from updated image | Create MicroVM with `imageRef` | VM runs using v2.0 |
| IMG-UPD-05 | Verify new code is running | Call endpoint | Response differs from v1.0 |

## Prerequisites

- Operator deployed on EKS
- Two different S3 zip files (different app behavior)
- Validating webhook deleted

## Test Data

- v1.0: `s3://kube-microvm-test-<ACCOUNT_ID>-us-east-1/test-fixtures/microvm-hello-node.zip`
  - Returns: `{"status":"ok","path":"/","ts":"..."}`
- v2.0: `s3://kube-microvm-test-<ACCOUNT_ID>-us-east-1/test-fixtures/microvm-net-test.zip`
  - Returns: `{"status":"ok","path":"/","ts":"..."}` on `/` but also has `/fetch`, `/dns`, `/env`

## Acceptance Criteria

- Image builds a new version on spec change
- New version auto-activates
- status.versions[] shows both versions
- MicroVM uses latest active version when imageVersion not specified

## Results (2026-07-01, EKS Auto Mode, us-east-1)

| ID | Result | Notes |
|----|--------|-------|
| IMG-UPD-01 | ✅ PASS | Image CREATED, v1.0 ACTIVE |
| IMG-UPD-02 | ✅ PASS | Patched s3Key → v2.0 built (PENDING → IN_PROGRESS → SUCCESSFUL, ~3min) |
| IMG-UPD-03 | ✅ PASS | `activeVersion` advanced to 2.0 automatically |
| IMG-UPD-04 | ✅ PASS | MicroVM resolvedImageVersion=2.0, Running |
| IMG-UPD-05 | ✅ PASS | `/dns` and `/fetch` endpoints confirmed (only in v2.0 code) |

Key observations:
- Updating `spec.source.s3Key` triggers a new version build (generation change detected)
- New version auto-activates on SUCCESSFUL
- MicroVM with no explicit `imageVersion` picks up the latest active version
- Version build takes ~3 minutes
