# Design: UpdateNetworkConnector E2E Verification

**Status**: Code complete — E2E only  
**Branch**: `feature/e2e-network-update`  
**Priority**: P2

---

## What Exists

`MicroVMNetworkReconciler` detects spec changes via `observedGeneration` and calls `UpdateNetworkConnector` with new subnet/SG configuration. Integration tests pass (mocked). Never tested on a real cluster.

## What Is Missing

E2E verification that updating `spec.subnetIds` or `spec.securityGroupIds` on an existing `MicroVMNetwork` CR triggers `UpdateNetworkConnector` and the connector settles to ACTIVE.

**Known constraint**: `UpdateNetworkConnector` fails if MicroVMs are currently using the connector. The reconciler emits a warning event but does not block.

## Test Plan

### NU-01: Update subnet configuration
```bash
# Create connector
kubectl apply -f - <<EOF
apiVersion: lambda.aws.amazon.com/v1alpha1
kind: MicroVMNetwork
metadata:
  name: update-test-net
  namespace: default
spec:
  subnetIds:
    - subnet-0fdc8b729163e12a7
  securityGroupIds:
    - sg-07c55b13501ead309
  operatorRoleArn: "arn:aws:iam::864899852480:role/kube-microvm-operator"
EOF
# Wait for ACTIVE
for i in $(seq 1 30); do
  STATE=$(kubectl get microvmnetwork update-test-net -n default \
    -o jsonpath='{.status.connectorState}' 2>/dev/null)
  echo "[${i}] state=$STATE"
  [[ "$STATE" == "ACTIVE" ]] && break
  sleep 10
done

# Update: add a second subnet
kubectl patch microvmnetwork update-test-net -n default --type=merge \
  -p '{"spec":{"subnetIds":["subnet-0fdc8b729163e12a7","subnet-0bde13101743f4751"]}}'

# Wait for ACTIVE again (goes through PENDING during update)
for i in $(seq 1 30); do
  STATE=$(kubectl get microvmnetwork update-test-net -n default \
    -o jsonpath='{.status.connectorState}' 2>/dev/null)
  GEN=$(kubectl get microvmnetwork update-test-net -n default \
    -o jsonpath='{.status.observedGeneration}' 2>/dev/null)
  echo "[${i}] state=$STATE gen=$GEN"
  [[ "$STATE" == "ACTIVE" && "$GEN" == "2" ]] && echo "Update settled!" && break
  sleep 10
done
```
**Pass**: connector returns to ACTIVE with new subnet config, `observedGeneration=2`

### NU-02: Verify update blocked when VM is using connector
```bash
# Create VM using the connector
kubectl apply -f - <<EOF
...VM with networkRef: update-test-net...
EOF
kubectl wait microvm/update-net-vm --for=jsonpath='{.status.state}'=Running --timeout=2m

# Try to update connector while VM is using it
kubectl patch microvmnetwork update-test-net -n default --type=merge \
  -p '{"spec":{"subnetIds":["subnet-0066fc5ae37bd3d88"]}}'

# Check for warning event
kubectl get events -n default --field-selector reason=UpdateBlocked | grep update-test-net
```
**Pass**: Warning event emitted; connector not updated while VM in use

### Teardown
```bash
kubectl delete microvm update-net-vm -n default --timeout=30s 2>/dev/null || true
kubectl delete microvmnetwork update-test-net -n default --timeout=60s
```

## Implementation Checklist

- [ ] E2E: subnet update triggers connector update and ACTIVE (NU-01)
- [ ] E2E: update blocked with active VM, event emitted (NU-02)
- [ ] Create `docs/testing/uat-network-update.md` with results
- [ ] Update `docs/design/api-implementation-status.md`
