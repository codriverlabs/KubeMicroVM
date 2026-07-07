# E2E Burst Test Plan — QuotaGuard Validation

**Status**: Ready to execute  
**Branch**: `feature/quota-guardrails-replicaset`  
**Depends on**: `QuotaGuard` wired into `MicroVMReconciler`, `MicroVMImageReconciler`,
`MicroVMTokenResource`, and `MicroVMReplicaSetReconciler` (all merged to main / on this branch)

---

## Purpose

Validate that `QuotaGuard` correctly enforces AWS Lambda MicroVMs API rate limits in
production conditions on a live EKS cluster.

**Root cause being validated**: The 2026-07-06 load test showed `0/256` token requests
succeeded when fired with `xargs -P 50`. Root cause confirmed: `CreateMicrovmAuthToken`
has a 50 req/s account-level burst limit — 50 simultaneous requests exhaust the entire
burst allowance simultaneously, returning 429 for all. `QuotaGuard` now queues and
rate-limits token requests at 50 req/s with a bounded backpressure queue.

**Secondary validation**: `MicroVMReplicaSetReconciler` now paces suspend/resume cascades
through `QuotaGuard`, preventing `SuspendMicrovm` (2 req/s) from being saturated on large
ReplicaSets. This was not caught in the 2026-07-06 test because no suspend cascade was run.

---

## Prerequisites

```bash
# 1. Operator deployed from feature/quota-guardrails-replicaset
# 2. Image 'qs-test-app' must be in state CREATED
kubectl get microvmimage qs-test-app -o jsonpath='{.status.imageState}'
# expected: CREATED or UPDATED

# 3. Namespace labelled
kubectl get namespace default --show-labels | grep manage-microvms
# expected: lambda.aws.amazon.com/manage-microvms=true

# 4. microvm CLI installed and on PATH
microvm --version
```

---

## Test Suite

### T-01: QuotaGuard Startup Verification

**What**: Confirm operator logs the `QuotaGuard initialised` line at startup with the
correct rate values from quota discovery.

**Steps**:

```bash
# Check operator startup logs
kubectl logs -n kube-microvm deploy/kube-microvm-operator \
  | grep -E "QuotaGuard|quota"
```

**Expected output** (exact format):
```
QuotaGuard initialised via DefaultQuotaPolicy: run=5/s terminate=10/s suspend=2/s
  resume=5/s get=100/s authToken=50/s imageBuilds=10 tokenQueue=200
```

**Pass criteria**:
- `QuotaGuard initialised` line present
- `DefaultQuotaPolicy` appears in brackets (confirms Community SPI is active)
- Rate values match AWS account defaults (or discovered values if quota was increased)
- No `QUOTA MISMATCH` warning lines (confirms install-time discovery ran correctly)

**Fail criteria**:
- Line absent → `QuotaGuard` CDI injection failed
- `QUOTA MISMATCH` warning → configured rate exceeds discovered quota; re-run installer

---

### T-02: Token Burst — Operator Endpoint (50 Concurrent Requests)

**What**: Fire 50 concurrent token requests via the operator REST endpoint (not `--direct`).
This is the scenario that failed 0/256 on 2026-07-06. With `QuotaGuard`, requests are queued
and rate-limited at 50 req/s. Some may return HTTP 429 if the queue is full, but the success
rate should be significantly above 0%.

**Setup**:
```bash
NAMESPACE=default

# Create 1 Running VM for token requests (all 50 requests target the same VM —
# this isolates the rate-limit behaviour from VM-per-request variability)
kubectl apply -f - <<EOF
apiVersion: lambda.aws.amazon.com/v1alpha1
kind: MicroVM
metadata:
  name: burst-test-vm
  namespace: ${NAMESPACE}
spec:
  imageRef: qs-test-app
  desiredState: Running
  maxIdleDurationSeconds: 3600
EOF

# Wait for Running state
kubectl wait microvms/burst-test-vm -n ${NAMESPACE} \
  --for=jsonpath='{.status.state}'=Running --timeout=120s
```

**Execute burst**:
```bash
# Fire 50 concurrent token requests via operator endpoint
# Each request uses the pod's service account token to call the operator REST API
# The operator does TokenReview + SubjectAccessReview, then calls CreateMicrovmAuthToken

OPERATOR_SVC="https://kube-microvm-operator.kube-microvm.svc:443"
SA_TOKEN=$(kubectl create token burst-test-sa -n ${NAMESPACE} --duration=10m)

RESULTS_FILE="/tmp/burst-results-$(date +%Y%m%dT%H%M%S).txt"
> "$RESULTS_FILE"

START=$(date +%s%N)

seq 1 50 | xargs -P 50 -I{} bash -c "
  RESP=\$(curl -sk -w '\n%{http_code}' \
    -H 'Authorization: Bearer ${SA_TOKEN}' \
    -H 'Content-Type: application/json' \
    -d '{\"expirationInMinutes\": 5}' \
    '${OPERATOR_SVC}/apis/lambda.aws.amazon.com/v1alpha1/namespaces/${NAMESPACE}/microvms/burst-test-vm/token' \
    2>/dev/null)
  HTTP_CODE=\$(echo \"\$RESP\" | tail -1)
  if [[ \"\$HTTP_CODE\" == '200' ]]; then
    echo 'OK {}'
  elif [[ \"\$HTTP_CODE\" == '429' ]]; then
    echo 'BACKPRESSURE {}'
  else
    echo \"FAIL \$HTTP_CODE {}\"
  fi
" | tee "$RESULTS_FILE"

END=$(date +%s%N)
ELAPSED_MS=$(( (END - START) / 1000000 ))

OK_COUNT=$(grep -c "^OK" "$RESULTS_FILE" || true)
BACKPRESSURE_COUNT=$(grep -c "^BACKPRESSURE" "$RESULTS_FILE" || true)
FAIL_COUNT=$(grep -c "^FAIL" "$RESULTS_FILE" || true)

echo ""
echo "=== BURST TEST RESULTS ==="
echo "Total requests : 50"
echo "Success (200)  : $OK_COUNT"
echo "Backpressure (429): $BACKPRESSURE_COUNT"
echo "Errors (other) : $FAIL_COUNT"
echo "Elapsed        : ${ELAPSED_MS}ms"
echo "Rate           : $(( OK_COUNT * 100 / 50 ))% success"
```

**Pass criteria**:
- `OK_COUNT > 0` — at least some requests succeed (before: 0)
- `FAIL_COUNT == 0` — no unexpected errors (non-200, non-429 responses)
- `BACKPRESSURE_COUNT` may be > 0 if queue depth exceeded — this is correct behaviour
- Elapsed > 0ms — requests serialised through rate limiter, not all instant
- Operator logs show `microvm_aws_api_calls_total{operation="CreateMicrovmAuthToken"}` 
  counter incrementing (visible in Prometheus metrics)

**Fail criteria**:
- `OK_COUNT == 0` — rate limiter not working (regression to pre-QuotaGuard behaviour)
- `FAIL_COUNT > 0` — unexpected non-429 errors (5xx = operator bug)

> **Note**: This test requires the operator token endpoint to be working E2E
> (currently in TODO.md as a remaining item). If the token endpoint is not
> accessible from the test pod, use the `--direct` variant below as a substitute.

**Fallback — `--direct` variant** (tests AWS-side rate limiting only, not QuotaGuard):
```bash
# Using --direct bypasses the operator entirely and calls AWS SDK directly.
# This does NOT test QuotaGuard. Use only to confirm token collection works
# independently of the quota validation goal.
RUNNING_VMS=$(kubectl get microvms -n ${NAMESPACE} \
  -l "lambda.aws.amazon.com/replicaset-name=burst-test-rs" \
  -o jsonpath='{range .items[?(@.status.state=="Running")]}{.metadata.name}{"\n"}{end}')
echo "$RUNNING_VMS" | head -50 | \
  xargs -P 10 -I{} bash -c "
    TOKEN=\$(microvm token --name {} --namespace ${NAMESPACE} --direct 2>/dev/null || echo '')
    [[ \${#TOKEN} -gt 20 ]] && echo 'OK {}' || echo 'FAIL {}'
  " | tee "$RESULTS_FILE"
```

---

### T-03: ReplicaSet Suspend Cascade Timing

**What**: Verify that suspending a large ReplicaSet is paced through `QuotaGuard`
(SuspendMicrovm 2 req/s), not fired simultaneously. Without pacing, 20 VMs would
generate 20 near-simultaneous AWS calls and likely hit the 2 req/s rate limit.
With pacing, the cascade should take approximately `N / 2` seconds.

**Setup**:
```bash
NAMESPACE=default
CASCADE_SIZE=20  # enough to observe pacing without long wait

kubectl apply -f - <<EOF
apiVersion: lambda.aws.amazon.com/v1alpha1
kind: MicroVMReplicaSet
metadata:
  name: cascade-test-rs
  namespace: ${NAMESPACE}
spec:
  replicas: ${CASCADE_SIZE}
  template:
    imageRef: qs-test-app
    desiredState: Running
    maxIdleDurationSeconds: 3600
EOF

# Wait for all VMs to reach Running
echo "Waiting for ${CASCADE_SIZE} Running VMs..."
for i in $(seq 1 90); do
  READY=$(kubectl get microvmreplicaset cascade-test-rs -n ${NAMESPACE} \
    -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)
  echo "  ready=${READY}/${CASCADE_SIZE}"
  [[ "$READY" -ge "$CASCADE_SIZE" ]] && break
  sleep 10
done
echo "All VMs Running — starting cascade test"
```

**Execute cascade**:
```bash
CASCADE_START=$(date +%s)

# Trigger suspend cascade
kubectl patch microvmreplicaset cascade-test-rs -n ${NAMESPACE} \
  --type=merge -p '{"spec":{"desiredReplicaSetState":"Suspended"}}'

echo "Cascade triggered at $(date -u)"

# Poll until all children reach Suspended
for i in $(seq 1 120); do
  SUSPENDED=$(kubectl get microvms -n ${NAMESPACE} \
    -l "lambda.aws.amazon.com/replicaset-name=cascade-test-rs" \
    -o jsonpath='{range .items[?(@.status.state=="Suspended")]}{.metadata.name}{"\n"}{end}' \
    2>/dev/null | grep -c . || true)
  ELAPSED=$(( $(date +%s) - CASCADE_START ))
  echo "  [${ELAPSED}s] Suspended: ${SUSPENDED}/${CASCADE_SIZE}"
  [[ "$SUSPENDED" -ge "$CASCADE_SIZE" ]] && break
  sleep 5
done

CASCADE_ELAPSED=$(( $(date +%s) - CASCADE_START ))
echo ""
echo "=== CASCADE RESULTS ==="
echo "VMs suspended    : ${SUSPENDED}/${CASCADE_SIZE}"
echo "Elapsed          : ${CASCADE_ELAPSED}s"
echo "Expected minimum : $(( CASCADE_SIZE / 2 ))s  (SuspendMicrovm rate=2/s)"
echo "Pacing active    : $( [[ $CASCADE_ELAPSED -ge $(( CASCADE_SIZE / 2 )) ]] && echo YES || echo NO )"
```

**Pass criteria**:
- `SUSPENDED == CASCADE_SIZE` — all VMs reach Suspended state
- `CASCADE_ELAPSED >= CASCADE_SIZE / 2` — elapsed time consistent with 2 req/s pacing
  (20 VMs @ 2/s = ~10s minimum; some reconcile overhead expected)
- No 429 errors in operator logs during cascade:
  ```bash
  kubectl logs -n kube-microvm deploy/kube-microvm-operator \
    --since=5m | grep -c "429\|ThrottlingException\|TooManyRequests" || echo 0
  ```
  Expected: `0`

**Fail criteria**:
- `SUSPENDED < CASCADE_SIZE` — some VMs never reached Suspended (operator error)
- `CASCADE_ELAPSED < 2s` — cascade fired simultaneously (pacing not active)
- 429 errors in operator logs — QuotaGuard not preventing throttling

**Resume (cleanup)**:
```bash
kubectl patch microvmreplicaset cascade-test-rs -n ${NAMESPACE} \
  --type=merge -p '{"spec":{"desiredReplicaSetState":"Running"}}'
```

---

### T-04: QuotaDiscovery Cross-Check (Runtime Mode)

**What**: If the operator was deployed with `--quota-discovery=runtime`, verify the
startup log shows discovered values and correctly warns when configured rate exceeds quota.

> Skip this test if the operator was deployed without `--quota-discovery=runtime`.

**Steps**:
```bash
# Check if runtime discovery is enabled
kubectl get cm kube-microvm-operator-config -n kube-microvm \
  -o jsonpath='{.data.AWS_QUOTA_DISCOVERY_ENABLED}' 2>/dev/null || \
kubectl get deploy kube-microvm-operator -n kube-microvm \
  -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="AWS_QUOTA_DISCOVERY_ENABLED")].value}' 2>/dev/null

# Check startup logs
kubectl logs -n kube-microvm deploy/kube-microvm-operator \
  | grep -E "Discovered quotas|QUOTA MISMATCH|Quota discovery"
```

**Expected (runtime discovery enabled)**:
```
Quota discovery enabled — querying AWS Service Quotas
Discovered quotas: run=5/s terminate=10/s suspend=2/s resume=5/s authToken=50/s imageBuilds=10
```

**Expected (discovery disabled)**:
```
Quota discovery disabled — using configured values: run=5/s terminate=10/s suspend=2/s
  authToken=50/s imageBuilds=10
```

**Pass criteria**: One of the two patterns above is present. No `QUOTA MISMATCH` warnings.

---

### T-05: Operator Health After Burst

**What**: After running T-02 (token burst) and T-03 (cascade), verify the operator is
still healthy and reconciling normally.

```bash
# Health endpoints
kubectl exec -n kube-microvm deploy/kube-microvm-operator -- \
  wget -qO- http://localhost:8080/q/health/live && echo "LIVE OK"
kubectl exec -n kube-microvm deploy/kube-microvm-operator -- \
  wget -qO- http://localhost:8080/q/health/ready && echo "READY OK"

# Metrics — confirm reconciliation counters are still incrementing
kubectl exec -n kube-microvm deploy/kube-microvm-operator -- \
  wget -qO- http://localhost:8080/q/metrics \
  | grep "microvm_reconciliations_total\|microvm_aws_api_calls_total" | head -10

# No crash loops
kubectl get pod -n kube-microvm
# expected: Running, RESTARTS=0
```

**Pass criteria**:
- `/q/health/live` returns 200
- `/q/health/ready` returns 200
- Pod RESTARTS == 0
- Reconciliation metrics present and non-zero

---

## Teardown

```bash
NAMESPACE=default

# Delete burst test VM
kubectl delete microvm burst-test-vm -n ${NAMESPACE} --timeout=30s 2>/dev/null || true

# Delete cascade test RS (terminates children via ownerReference GC)
kubectl delete microvmreplicaset cascade-test-rs -n ${NAMESPACE} \
  --timeout=60s 2>/dev/null || true

# Verify no VMs remaining
kubectl get microvms,microvmreplicasets -n ${NAMESPACE}
```

---

## Pass Criteria Summary

| Test | Key Assertion | Previous Result (2026-07-06) | Expected After QuotaGuard |
|------|--------------|------------------------------|--------------------------|
| T-01 | `QuotaGuard initialised` in logs | N/A (feature not present) | ✅ Present, correct rates |
| T-02 | Token burst: `OK > 0` | ❌ 0/256 (0%) | ✅ >0 success, 0 non-429 errors |
| T-03 | Cascade elapsed ≥ N/2 seconds | N/A (not tested) | ✅ Paced, no 429s in logs |
| T-04 | Quota discovery log line | N/A | ✅ Discovered values logged |
| T-05 | Operator healthy after burst | N/A | ✅ Live, ready, no restarts |

---

## Sign-Off Checklist

After completing all tests:

- [ ] T-01: `QuotaGuard initialised` log confirmed with correct rates
- [ ] T-02: Token burst — `OK > 0` (rate limiter queuing requests)
- [ ] T-03: Cascade elapsed ≥ `N/2`s, no 429s in operator logs
- [ ] T-04: Quota discovery log line present (or skipped if runtime mode not enabled)
- [ ] T-05: Operator healthy after all burst tests
- [ ] Teardown: all test CRs removed
- [ ] Results captured and committed to `docs/testing/burst-test-<date>/`

**UAT document**: Update `docs/testing/uat-quota-guardrails.md` with actual results
after execution.

---

## Known Limitations

- **T-02 requires the operator token endpoint to be E2E working**. If the endpoint
  is not reachable from within the cluster (still a TODO — see `docs/testing/TODO.md`),
  use the `--direct` fallback. The fallback tests AWS-side behaviour only, not
  `QuotaGuard`.
- **T-03 cascade timing** is best-effort — the pacing delays the child patch loop in
  the reconcile thread, but network and Kubernetes API latency add jitter. Allow ±20%
  tolerance on the `N/2` expected duration.
- **T-01 quota values** depend on account. If your account has higher quotas, the
  values in the log will differ from the defaults. Check against the output of:
  ```bash
  aws service-quotas get-service-quota \
    --service-code lambda \
    --quota-code L-91B95582 \
    --query 'Quota.Value'
  ```
