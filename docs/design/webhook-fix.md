# Design: Validating + Mutating Webhook Fix

**Status**: Bug investigation + fix required  
**Branch**: `feature/webhook-fix`  
**Priority**: P1 (blocks admission control)

---

## Problem

Both webhooks (`validate.microvms.lambda.aws.amazon.com` and `mutate.microvms.lambda.aws.amazon.com`) are deployed and the Kubernetes webhook configurations reference them, but previous E2E runs showed the endpoints were not reliably reachable from the API server.

Symptoms observed:
- `kubectl apply` on invalid CRs sometimes succeeds (should be rejected)
- Mutating webhook defaults (e.g. `maxIdleDurationSeconds` from MicroVMClass) not always applied
- No consistent error — sometimes the webhook returns a response, sometimes the admission request times out

Possible root causes:
1. **TLS cert SAN mismatch** — cert-manager-issued cert might not include the correct service DNS names
2. **Path mismatch** — Quarkus serves at `/validate-microvm` but webhook config references a different path
3. **Port routing** — service on 443 → pod on 8443 mapping not correctly set up
4. **FailurePolicy** — `Fail` policy causes silent failures when operator is starting up

## Investigation Plan

### Step 1: Verify webhook endpoints respond
```bash
# From inside a pod in the cluster:
kubectl run -it --rm debug --image=curlimages/curl --restart=Never -- \
  curl -sk https://kube-microvm-operator.kube-microvm.svc:443/validate-microvm \
  -X POST -H "Content-Type: application/json" -d '{}'
```

### Step 2: Check cert SANs
```bash
kubectl get secret kube-microvm-operator-webhook-tls -n kube-microvm \
  -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -noout -text \
  | grep "DNS:"
# Expected: DNS:kube-microvm-operator.kube-microvm.svc
#           DNS:kube-microvm-operator.kube-microvm.svc.cluster.local
```

### Step 3: Verify webhook config caBundle
```bash
kubectl get validatingwebhookconfiguration kube-microvm-operator-validating \
  -o jsonpath='{.webhooks[0].clientConfig.caBundle}' | base64 -d \
  | openssl x509 -noout -text | grep "Subject:"
```

### Step 4: Test rejection with invalid CR
```bash
kubectl apply -f - <<EOF
apiVersion: lambda.aws.amazon.com/v1alpha1
kind: MicroVM
metadata:
  name: webhook-test-invalid
  namespace: default
spec:
  desiredState: Running
  # Missing imageRef — should be rejected
EOF
# Expected: "admission webhook denied the request: spec.imageRef is required"
```

### Step 5: Test mutating defaults
```bash
kubectl apply -f - <<EOF
apiVersion: lambda.aws.amazon.com/v1alpha1
kind: MicroVM
metadata:
  name: webhook-test-defaults
  namespace: default
spec:
  imageRef: qs-test-app
  desiredState: Running
  className: some-class
  maxIdleDurationSeconds: 900
  suspendedDurationSeconds: 1800
EOF
kubectl get microvm webhook-test-defaults -o jsonpath='{.spec}' | python3 -m json.tool
# Verify class defaults applied
```

## Fix Options

### If TLS issue:
- Verify cert-manager `Certificate` resource SAN configuration in Helm chart
- Ensure `dnsNames` includes both `<service>.<namespace>.svc` and `<service>.<namespace>.svc.cluster.local`

### If path mismatch:
- Check `@Path` annotations in `MicroVMValidatingWebhook` and `MicroVMMutatingWebhook`
- Check `webhooks[].clientConfig.service.path` in `ValidatingWebhookConfiguration`

### If FailurePolicy issue:
- Consider `FailurePolicy: Ignore` during operator startup (`readinessProbe` not yet passing)
- Or add `matchConditions` to skip when operator is not ready

## Integration Tests Needed

Currently `MicroVMValidatingWebhookTest` exists but is marked as failing in the status doc. Need to verify:
- [ ] `MicroVMValidatingWebhookTest` passes
- [ ] `WebhookIntegrationTest` passes
- [ ] `WebhookValidationPropertyTest` passes
- [ ] E2E: invalid CR rejected at admission
- [ ] E2E: mutating defaults applied

## Implementation Checklist

- [ ] Diagnose root cause (TLS / path / port)
- [ ] Fix identified issue
- [ ] Verify integration test suite passes (webhook tests)
- [ ] E2E: apply invalid CR → expect rejection message
- [ ] E2E: apply CR with className → expect defaults merged
- [ ] Document fix in this design doc
