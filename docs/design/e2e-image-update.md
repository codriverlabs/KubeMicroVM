# Design: UpdateMicrovmImage E2E Verification

**Status**: Implementation ready — E2E only, no code changes needed  
**Branch**: `feature/e2e-image-update-v2`  
**Type**: E2E test execution + UAT documentation

---

## What Exists

- `UpdateMicrovmImage` is implemented in `MicroVMImageReconciler` — triggers when `metadata.generation` changes (spec update)
- Integration tests pass for the update + new version poll path
- `UpdateMicrovmImageVersion` (auto-activate) is also implemented and E2E verified

## What Is Missing

E2E verification that changing `spec.source` or `spec.baseImageArn` on an existing `MicroVMImage` CR triggers `UpdateMicrovmImage` and produces a new version.

## Test Plan

### Setup
```bash
# Create and wait for initial image
kubectl apply -f - <<EOF
apiVersion: lambda.aws.amazon.com/v1alpha1
kind: MicroVMImage
metadata:
  name: update-test-image
  namespace: default
spec:
  source:
    s3Bucket: kube-microvm-test-864899852480-us-east-1
    s3Key: uat/fixtures/microvm-hello-node.zip
  baseImageArn: "arn:aws:lambda:us-east-1:aws:microvm-image:al2023-1"
  buildRoleArn: "arn:aws:iam::864899852480:role/KubeMicroVMBuildRole"
EOF
kubectl wait microvmimage/update-test-image --for=jsonpath='{.status.imageState}'=CREATED --timeout=10m
```

### IU-01: Trigger image update by changing S3 source
```bash
kubectl patch microvmimage update-test-image -n default \
  --type=merge -p '{"spec":{"source":{"s3Key":"uat/fixtures/microvm-net-test.zip"}}}'
# New version should build
kubectl wait microvmimage/update-test-image \
  --for=jsonpath='{.status.latestVersionState}'=SUCCESSFUL --timeout=10m
```
**Pass**: new version appears in `status.versions[]`, `status.activeVersion` updated

### IU-02: VM using imageRef still works after update
```bash
# Create VM pointing at updated image
kubectl apply -f - <<EOF
...image version ref...
EOF
```
**Pass**: VM starts from new image version

### Teardown
```bash
kubectl patch microvmimage update-test-image -n default \
  --type=json -p='[{"op":"remove","path":"/metadata/finalizers"}]' --request-timeout=10s
kubectl delete microvmimage update-test-image -n default --timeout=30s
```

## UAT Document
Create `docs/testing/uat-image-update-v2.md` with results.
