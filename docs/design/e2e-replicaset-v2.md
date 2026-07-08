# Design: MicroVMReplicaSet E2E Verification

**Status**: Code complete, 9 integration tests pass — E2E only  
**Branch**: `feature/e2e-replicaset-v2`  
**Priority**: P1

---

## What Exists

`MicroVMReplicaSetReconciler` implements:
- Scale up (creates children, `maxCreatesPerCycle` derived from QuotaGuard)
- Scale down (selects victims by policy)
- Health eviction (FAILED, stuck PENDING, unexpected TERMINATED)
- Suspend/resume cascade (paced through QuotaGuard)
- Status: `readyReplicas`, `currentReplicas`, `suspendedReplicas`

9 integration tests pass including QuotaGuard wiring tests. The burst test (2026-07-07) verified cascade pacing but not basic RS create/scale on a real cluster.

## What Is Missing

Scale up / scale down / cascade verified on a real EKS cluster with real AWS VMs.

## Test Plan

### Setup
```bash
# Image must be CREATED first
kubectl apply -f - <<EOF
apiVersion: lambda.aws.amazon.com/v1alpha1
kind: MicroVMImage
metadata:
  name: rs-e2e-image
  namespace: default
spec:
  source:
    s3Bucket: kube-microvm-test-864899852480-us-east-1
    s3Key: uat/fixtures/microvm-hello-node.zip
  baseImageArn: "arn:aws:lambda:us-east-1:aws:microvm-image:al2023-1"
  buildRoleArn: "arn:aws:iam::864899852480:role/KubeMicroVMBuildRole"
EOF
kubectl wait microvmimage/rs-e2e-image --for=jsonpath='{.status.imageState}'=CREATED --timeout=10m
```

### RS-01: Create ReplicaSet with 3 replicas
```bash
kubectl apply -f - <<EOF
apiVersion: lambda.aws.amazon.com/v1alpha1
kind: MicroVMReplicaSet
metadata:
  name: rs-e2e-test
  namespace: default
spec:
  replicas: 3
  template:
    imageRef: rs-e2e-image
    desiredState: Running
    maxIdleDurationSeconds: 3600
    suspendedDurationSeconds: 7200
EOF
# Wait for 3 Running
for i in $(seq 1 60); do
  READY=$(kubectl get microvmreplicaset rs-e2e-test -n default \
    -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)
  echo "[${i}] ready=${READY}/3"
  [[ "${READY}" -ge 3 ]] && break
  sleep 10
done
```
**Pass**: `status.readyReplicas == 3`, 3 child MicroVM CRs exist

### RS-02: Scale up to 5
```bash
kubectl patch microvmreplicaset rs-e2e-test -n default \
  --type=merge -p '{"spec":{"replicas":5}}'
# Wait for 5
```
**Pass**: `status.readyReplicas == 5`

### RS-03: Scale down to 2
```bash
kubectl patch microvmreplicaset rs-e2e-test -n default \
  --type=merge -p '{"spec":{"replicas":2}}'
# Wait for 2
```
**Pass**: `status.readyReplicas == 2`, terminated VMs cleaned up

### RS-04: Suspend cascade
```bash
kubectl patch microvmreplicaset rs-e2e-test -n default \
  --type=merge -p '{"spec":{"desiredReplicaSetState":"Suspended"}}'
# Wait for all Suspended — should take ~1s per VM at 2/s rate
```
**Pass**: all VMs suspended, no 429 errors in logs

### RS-05: Delete cascades
```bash
kubectl delete microvmreplicaset rs-e2e-test -n default --timeout=60s
kubectl get microvms -n default -l lambda.aws.amazon.com/replicaset-name=rs-e2e-test
```
**Pass**: all child VMs gone

### Teardown
```bash
kubectl patch microvmimage rs-e2e-image -n default \
  --type=json -p='[{"op":"remove","path":"/metadata/finalizers"}]' --request-timeout=10s
kubectl delete microvmimage rs-e2e-image -n default --timeout=30s
```

## Implementation Checklist

- [ ] E2E: RS creates 3 VMs (RS-01)
- [ ] E2E: Scale up to 5 (RS-02)
- [ ] E2E: Scale down to 2 (RS-03)
- [ ] E2E: Suspend cascade — paced, no 429s (RS-04)
- [ ] E2E: Delete cascades all children (RS-05)
- [ ] Create `docs/testing/uat-replicaset-v2.md` with results
- [ ] Update `docs/design/api-implementation-status.md`
