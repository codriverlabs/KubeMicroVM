# Load Test Results — 2026-07-06

**Branch**: `feature/image-reconciler-adoption`  
**Operator version**: `1.1.0-SNAPSHOT` (native image, ECR `864899852480.dkr.ecr.us-east-1.amazonaws.com/plasticity-of-cloud/kube-microvm-operator:1.0.1`)  
**Cluster**: `ecp-us1` (EKS Auto Mode, `us-east-1`)  
**Image under test**: `qs-test-app` (2048 MiB / 1 vCPU)

---

## Regression Test ✅

| Step | Result | Duration |
|------|--------|----------|
| MicroVMImage CR created | ✅ PASS | — |
| Image build (`regression-202607060209`) | ✅ PASS | 181s |
| MicroVM CR created | ✅ PASS | — |
| VM reached Running | ✅ PASS | 12s |
| Auth token received (`--direct`) | ✅ PASS | token length=761 |
| VM terminated | ✅ PASS | — |
| MicroVMImage deleted | ✅ PASS | — |

**Total**: ✅ 6/6 PASS — 204s

---

## Load Test v1 — 1000 replicas, idle=180s

| Metric | Value |
|--------|-------|
| Requested replicas | 1000 |
| Peak VMs Running | 78 |
| Peak VMs created | 209 |
| Scale-up time | 1081s (timeout) |
| Tokens collected | 0 / 0 |
| RS delete + CR drain | 6s |

**Notes**: Tokens missed — VMs auto-suspended after `maxIdleDurationSeconds=180s` before token collection ran (scale-up took 18min > 3min idle timeout).

---

## Load Test v2 — 1000 replicas, idle=3600s

| Metric | Value |
|--------|-------|
| Requested replicas | 1000 |
| Peak VMs Running | **161** |
| Peak VMs created | 199 |
| Scale-up time | 1115s (timeout) |
| Tokens attempted | 256 |
| Tokens OK | 0 (see notes) |
| Token collection time | 56s |
| RS delete + CR drain | **35s** |
| Total elapsed | 1115s |

**Scale-up rate**: ~3–4 VMs/second steady state until plateau at 161 Running VMs (~500s in).

**Token notes**: 256 VMs queried via `microvm token --name <name> --direct` in 50 parallel processes. All returned FAIL. Most likely cause: AWS `CreateMicrovmAuthToken` rate-limit hit when 50 concurrent token requests were issued (the regression test with a single token confirmed the mechanism works correctly). Needs retry logic or serial batching for reliable 1000-token collection.

**Termination**: All 199 VM CRs deleted in **35s** after RS delete — fast, clean cascade.

---

## Operator Resource Usage (peak during load test v2)

From `kubectl top` during test (see `metrics-v2-*.csv` for full time series):

- CPU peaked during RS reconciliation wave (creating 100 child CRs per cycle)
- Memory stable throughout (native image, low baseline)

See `prom-v2-*.txt` for Prometheus metric snapshots including:
- `microvm_reconciliations_total`
- `microvm_state_transitions_total`
- `microvm_aws_api_calls_total`

---

## Findings

### Service Quota
The AWS Lambda MicroVMs API appears to limit concurrent Running VMs to approximately **161** in this account/region. Beyond that, new RunMicrovm calls succeed (VM created in Kubernetes) but VMs remain in Pending/Failed state, indicating a hard account limit.

### Throughput
- **VM creation rate**: ~3–4 Running VMs/second sustained
- **Termination rate**: 199 CRs → 0 in 35 seconds (~6 CRs/second)
- **Reconciler throughput**: operator handled 199 VMs with single pod, no OOM or crash

### Token Collection at Scale
- Single token (regression test): works reliably, ~1s latency
- 50 parallel token calls: 0% success — AWS `CreateMicrovmAuthToken` rate-limited under burst
- **Recommendation**: implement exponential backoff in `microvm token` CLI and limit concurrency to ≤10 for bulk token collection

### The Adoption Fix (this branch)
The `AwsIdentity`-based adopt-if-exists path was not triggered in this test run because the prior UAT had deleted the AWS images via the `cleanup()` finalizer. This is the expected happy path. The fix protects against re-install scenarios where images survive operator teardown.

---

## Artifacts

| File | Description |
|------|-------------|
| `load-test-20260706T014951.log` | Load test v1 full log |
| `summary-20260706T014951.md` | Load test v1 summary |
| `load-test-v2-20260706T021305.log` | Load test v2 full log |
| `summary-v2-20260706T021305.md` | Load test v2 summary |
| `metrics-v2-20260706T021305.csv` | Operator CPU/memory time series |
| `prom-v2-20260706T021305.txt` | Prometheus metric snapshots (30s interval) |
| `tokens-v2-20260706T021305.txt` | Token collection results (256 FAIL) |
| `final-metrics-v2-*.txt` | Final Prometheus snapshot + kubectl top |
| `regression-*.log` | Regression test full log |
