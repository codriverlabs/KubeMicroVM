# Design: Drift Detection E2E Verification

**Status**: Code complete, mocked tests pass — E2E only  
**Branch**: `feature/e2e-drift-v2`  
**Priority**: P2

---

## What Exists

`DriftDetector` detects when AWS state diverges from `spec.desiredState` and triggers the appropriate action. `MicroVMReconciler` polls AWS state every `RESYNC_PERIOD` and compares.

Integration tests verify the logic with mocked AWS responses. Never tested with a real externally-terminated VM.

## What Is Missing

E2E verification that the operator detects and recovers from external state changes:
1. VM terminated externally → operator detects and re-creates
2. VM suspended externally → operator resumes if `desiredState=Running`

## Test Plan

### DR-01: External termination detected and VM re-created
```bash
# Create VM via operator
kubectl apply -f - <<EOF
apiVersion: lambda.aws.amazon.com/v1alpha1
kind: MicroVM
metadata:
  name: drift-test-vm
  namespace: default
spec:
  imageRef: qs-test-app
  desiredState: Running
  maxIdleDurationSeconds: 3600
  suspendedDurationSeconds: 7200
EOF
kubectl wait microvm/drift-test-vm --for=jsonpath='{.status.state}'=Running --timeout=2m

# Get the microVmId
VM_ID=$(kubectl get microvm drift-test-vm -n default -o jsonpath='{.status.microVmId}')
echo "VM ID: $VM_ID"

# Terminate directly via AWS CLI (bypass operator)
aws lambda-microvms terminate-microvm --microvm-identifier "$VM_ID"

# Wait for operator to detect the drift (reconcile period ~30s)
# Expected: VM transitions to Pending, then re-created with new ID
for i in $(seq 1 30); do
  STATE=$(kubectl get microvm drift-test-vm -n default -o jsonpath='{.status.state}')
  NEW_ID=$(kubectl get microvm drift-test-vm -n default -o jsonpath='{.status.microVmId}')
  echo "[${i}] state=$STATE  id=$NEW_ID"
  [[ "$STATE" == "Running" && "$NEW_ID" != "$VM_ID" ]] && echo "Drift detected and recovered!" && break
  sleep 10
done
```
**Pass**: VM reaches `Running` with a new `microVmId` different from `$VM_ID`

### DR-02: No spurious RESUME calls during idle suspend
```bash
# VM with idle policy — operator should NOT fight AWS auto-suspend
kubectl apply -f - <<EOF
apiVersion: lambda.aws.amazon.com/v1alpha1
kind: MicroVM
metadata:
  name: idle-drift-vm
  namespace: default
spec:
  imageRef: qs-test-app
  desiredState: Running
  maxIdleDurationSeconds: 60
  suspendedDurationSeconds: 300
  autoResumeEnabled: true
EOF
kubectl wait microvm/idle-drift-vm --for=jsonpath='{.status.state}'=Running --timeout=2m
# Wait for auto-suspend (>60s no traffic)
sleep 90
# Check operator logs — should NOT see RESUME calls
kubectl logs -n kube-microvm deploy/kube-microvm-operator --tail=30 | grep RESUME
```
**Pass**: no spurious RESUME log lines (operator honours idle policy)

### Teardown
```bash
for vm in drift-test-vm idle-drift-vm; do
  kubectl patch microvm $vm -n default --type=merge -p '{"spec":{"desiredState":"Terminated"}}' 2>/dev/null || true
  kubectl delete microvm $vm -n default --timeout=30s 2>/dev/null || true
done
```

## Implementation Checklist

- [ ] E2E: external termination detected (DR-01)
- [ ] E2E: operator doesn't fight idle policy (DR-02)
- [ ] Create `docs/testing/uat-drift-v2.md` with results
- [ ] Update `docs/design/api-implementation-status.md`
