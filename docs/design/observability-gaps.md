# Observability Gaps & Improvement Plan

**Status**: Draft — pre-review  
**Date**: 2026-07-05  
**Branch**: `feature/observability-review-v1.0.1`

---

## Current State

### What exists today

| Signal | Technology | Endpoint | Notes |
|--------|-----------|----------|-------|
| Metrics | Micrometer + Prometheus | `GET /q/metrics` (port 8080) | 4 custom metrics, no OTEL |
| Logs | JBoss Logging (structured text) | stdout | Plain text format, not JSON |
| Traces | None | — | No distributed tracing at all |
| Health | SmallRye Health | `GET /q/health/live`, `/ready`, `/started` | Liveness + readiness + startup |
| Events | Kubernetes Events API | `kubectl get events` | Emitted on state transitions |

### Custom Prometheus metrics (OperatorMetrics.java)

| Metric | Type | Tags | What it measures |
|--------|------|------|-----------------|
| `microvm_reconciliations_total` | Counter | `outcome` | Reconciliation count per outcome (success/error/noop) |
| `microvm_reconciliation_duration_seconds` | Timer | `outcome` | Reconciliation latency |
| `microvm_state_transitions_total` | Counter | `from_state`, `to_state` | State machine transitions |
| `microvm_aws_api_calls_total` | Counter | `operation`, `status` | AWS API call count per operation |
| `microvmpool_reconciliations_total` | Counter | `outcome` | Pool reconciliation count |
| `microvmpool_reconciliation_duration_seconds` | Timer | `outcome` | Pool reconciliation latency |

### What's missing from the metrics

- No `namespace` tag on any metric — can't tell which namespace is most active
- No gauge for current VM count by state (e.g., how many Running/Suspended/Failed at any point)
- No AWS API error rate metric — `status` tag exists but error subtypes not distinguished
- No token endpoint metrics — request count, latency, 4xx/5xx rate
- No webhook metrics — admission request latency, rejection rate
- `microvmpool_*` metrics exist but `MicroVMPool` is not a user-facing resource yet

---

## Gaps by Signal

### 1. Logs — not structured

**Current**: Plain text format `%d{yyyy-MM-dd HH:mm:ss,SSS} %-5p [%c{3.}] (%t) %s%e%n`

**Problem**: Not JSON. Can't filter by `vm_name`, `namespace`, `aws_error_code`, etc. in log aggregators (Loki, CloudWatch Logs Insights, Datadog). Makes log-based alerting and correlation painful.

**Missing context on log lines**:
- VM name and namespace not always included in log message (only where explicitly added)
- AWS error codes/request IDs not extracted as structured fields
- No correlation ID linking a reconcile cycle's log lines together

**Fix**: Switch to JSON logging with structured fields.

```properties
# Switch to JSON format for production
quarkus.log.console.json=true
quarkus.log.console.json.additional-field."service".value=kube-microvm-operator
quarkus.log.console.json.additional-field."version".value=${quarkus.application.version}
```

And add MDC context in reconcilers:

```java
MDC.put("vm_namespace", namespace);
MDC.put("vm_name", name);
try {
    // reconcile
} finally {
    MDC.remove("vm_namespace");
    MDC.remove("vm_name");
}
```

---

### 2. Traces — completely absent

**Current**: No tracing instrumentation. A single reconcile cycle that calls AWS, patches status, and emits a Kubernetes event produces zero trace data.

**Problem**: When a MicroVM gets stuck or takes unexpectedly long, there is no way to see where time is spent. Is it the AWS API? The Kubernetes patch? The image ref resolution?

**What a trace would show**:
```
reconcile(MicroVM my-vm/default)          [320ms]
  ├── resolveImageRef(my-agent)           [2ms]
  ├── resolveNetworkRef(my-net)           [3ms]
  ├── aws.RunMicrovm(imageArn=...)        [298ms]  ← where time actually goes
  └── kubernetes.patchStatus(Running)    [17ms]
```

**Fix**: Add `quarkus-opentelemetry` extension + OTLP exporter. Instrument reconcilers with manual spans where auto-instrumentation doesn't cover.

```xml
<dependency>
    <groupId>io.quarkus</groupId>
    <artifactId>quarkus-opentelemetry</artifactId>
</dependency>
```

```properties
quarkus.otel.exporter.otlp.endpoint=${OTEL_EXPORTER_OTLP_ENDPOINT:}
quarkus.otel.traces.sampler=parentbased_traceidratio
quarkus.otel.traces.sampler.arg=${OTEL_TRACES_SAMPLER_ARG:0.1}
```

Manual span example:

```java
@Inject Tracer tracer;

Span span = tracer.spanBuilder("aws.RunMicrovm")
    .setAttribute("vm.name", name)
    .setAttribute("vm.namespace", namespace)
    .setAttribute("aws.image_arn", imageArn)
    .startSpan();
try (Scope s = span.makeCurrent()) {
    return client.runMicroVM(request);
} catch (Exception e) {
    span.recordException(e);
    span.setStatus(StatusCode.ERROR);
    throw e;
} finally {
    span.end();
}
```

---

### 3. Metrics — gaps

**Missing metrics (prioritised)**:

| Metric | Type | Tags | Why it matters |
|--------|------|------|---------------|
| `microvm_active_count` | Gauge | `namespace`, `state` | "How many VMs are Running/Suspended/Failed right now?" |
| `microvm_token_requests_total` | Counter | `outcome` (success/denied/notfound/not_running) | Token endpoint usage and error rates |
| `microvm_token_request_duration_seconds` | Timer | `outcome` | Token endpoint latency |
| `microvm_webhook_requests_total` | Counter | `webhook` (validating/mutating), `result` (allowed/denied) | Webhook admission rate and rejection reasons |
| `microvm_aws_api_errors_total` | Counter | `operation`, `error_type` (throttle/notfound/auth/unknown) | AWS error breakdown — throttles vs auth failures vs 5xx |
| `microvm_image_build_duration_seconds` | Histogram | `result` (success/failure) | Image build time distribution |
| `microvm_drift_detections_total` | Counter | `action` (recreate/suspend/terminate/noop) | How often is drift detected and what actions are taken |

**Missing tag on existing metrics**:
- Add `namespace` tag to `microvm_reconciliations_total` and `microvm_state_transitions_total`

---

### 4. No SLO-oriented instrumentation

There are no metrics that would directly power SLOs. For an operator, the natural SLIs are:

| SLI | What to measure |
|-----|----------------|
| Reconciliation success rate | `reconciliations_total{outcome="success"}` / `reconciliations_total` |
| VM reach-Running latency | Time from MicroVM creation to first `Running` state |
| Token endpoint availability | `token_requests_total{outcome!="error"}` / `token_requests_total` |
| AWS API error rate | `aws_api_errors_total{error_type="throttle"}` rate over 5m |

The reconciliation success rate SLI is achievable today with existing metrics. The others require new instrumentation.

---

### 5. No runbook or alert definitions

No `PrometheusRule` CRD resources, no alert definitions. Users deploying to clusters with Prometheus Operator have no out-of-box alerting.

**Recommended alerts**:

```yaml
- alert: MicroVMReconciliationErrorRate
  expr: |
    rate(microvm_reconciliations_total{outcome="error"}[5m])
    / rate(microvm_reconciliations_total[5m]) > 0.1
  for: 5m
  labels:
    severity: warning
  annotations:
    summary: "MicroVM operator reconciliation error rate > 10%"

- alert: MicroVMOperatorDown
  expr: absent(microvm_reconciliations_total)
  for: 10m
  labels:
    severity: critical
  annotations:
    summary: "MicroVM operator is not emitting reconciliation metrics"
```

---

## Priority Order

| Priority | Gap | Effort | Impact |
|----------|-----|--------|--------|
| P0 | JSON structured logging with MDC context | Small (config + 5 MDC sites) | High — log aggregation immediately useful |
| P0 | `microvm_active_count` gauge by namespace+state | Small (1 new gauge in OperatorMetrics) | High — basic operational visibility |
| P1 | Add `namespace` tag to existing reconciliation metrics | Trivial | Medium |
| P1 | Token endpoint metrics | Small (annotate MicroVMTokenResource) | Medium |
| P1 | AWS error breakdown metric | Small (update recordAwsApiCall) | Medium |
| P2 | OpenTelemetry traces | Medium (new dep, span instrumentation in 4 reconcilers) | High but complex |
| P2 | Image build duration histogram | Small | Medium |
| P2 | Drift detection counter | Small | Medium |
| P3 | PrometheusRule alert definitions in Helm chart | Medium | High for production adopters |
| P3 | SLO dashboard (Grafana) | Large | High for Grafana users |

---

## Open Questions

1. **Log format**: JSON to stdout is standard — is there a preference for log schema (OTEL log body vs arbitrary JSON)?
2. **Trace propagation**: Should the operator propagate trace context from incoming webhook requests (admission controller context is often lost)?
3. **Cardinality**: Is `vm_name` as a metric tag acceptable for environments with many short-lived VMs, or should it be excluded from all metrics?
4. **OTLP vs Prometheus**: Should traces go to an OTLP collector (e.g., ADOT, OpenTelemetry Collector) or is Prometheus-only acceptable for the v1.x timeframe?
5. **Auth agent**: The sidecar (`TokenRefreshAgent`) has no metrics or traces at all — should it be in scope for v1.1?
6. **Exemplars**: Micrometer supports Prometheus exemplars to link metrics→traces. Worth enabling alongside OTEL?

---

## Out of Scope (for this review)

- MicroVM runtime observability (what runs inside the VM is the user's responsibility)
- AWS-side metrics (CloudWatch MicroVM metrics are AWS's surface, not ours)
- Continuous profiling (async-profiler, Pyroscope)
