# Design: SuspendMicrovm / ResumeMicrovm E2E Verification

**Status**: Implementation ready — E2E only, no code changes needed  
**Branch**: `feature/e2e-suspend-resume`  
**Type**: E2E test execution + UAT documentation

---

## What Exists

- `SuspendMicrovm` and `ResumeMicrovm` are fully implemented in the reconciler
- `DriftDetector` handles the `SUSPENDED` → `RUNNING` transition
- Integration tests pass (mocked AWS)
- `MicroVMSpec.desiredState: Suspended` / `Running` triggers the transitions

## What Is Missing

E2E verification on a real EKS cluster. The operations have never been exercised against the live AWS API.

## Test Plan

### Setup
```bash
# Create VM
kubectl apply -f - <<EOF
apiVersion: lambda.aws.amazon.com/v1alpha1
kind: MicroVM
metadata:
  name: suspend-test-vm
  namespace: default
spec:
  imageRef: qs-test-app
  desiredState: Running
  maxIdleDurationSeconds: 3600
  suspendedDurationSeconds: 7200
EOF
kubectl wait microvm/suspend-test-vm --for=jsonpath='{.status.state}'=Running --timeout=2m
```

### SR-01: Suspend Running VM
```bash
kubectl patch microvm suspend-test-vm -n default \
  --type=merge -p '{"spec":{"desiredState":"Suspended"}}'
# Wait for Suspended state
kubectl wait microvm/suspend-test-vm --for=jsonpath='{.status.state}'=Suspended --timeout=2m
```
**Pass**: state transitions to `Suspended`; operator logs `SuspendMicrovm` call

### SR-02: Resume Suspended VM
```bash
kubectl patch microvm suspend-test-vm -n default \
  --type=merge -p '{"spec":{"desiredState":"Running"}}'
kubectl wait microvm/suspend-test-vm --for=jsonpath='{.status.state}'=Running --timeout=2m
```
**Pass**: state transitions back to `Running`; endpoint still reachable

### SR-03: Token still works after resume
```bash
TOKEN=$(./operator-cli/target/microvm-runner token --name suspend-test-vm --direct)
ENDPOINT=$(kubectl get microvm suspend-test-vm -o jsonpath='{.status.endpointUrl}')
curl -sk -H "X-aws-proxy-auth: $TOKEN" "https://$ENDPOINT/"
```
**Pass**: HTTP 200 response from VM

### Teardown
```bash
kubectl patch microvm suspend-test-vm -n default --type=merge -p '{"spec":{"desiredState":"Terminated"}}'
kubectl delete microvm suspend-test-vm -n default --timeout=30s
```

## UAT Document
Create `docs/testing/uat-suspend-resume-v2.md` with results.
