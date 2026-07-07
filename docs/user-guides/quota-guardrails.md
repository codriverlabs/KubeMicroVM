# Quota Guardrails

The operator enforces AWS Lambda MicroVMs API rate limits internally so that
your cluster never triggers 429 errors from AWS — even under heavy load.

---

## Why This Matters

AWS enforces hard per-account rate limits on all Lambda MicroVMs API operations.
These limits have no burst headroom — any call above the sustained rate is
immediately throttled. Without internal enforcement, a single operator managing
many VMs can saturate the account limit and cause failures for all users.

**Observed example**: 50 concurrent `microvm token` requests (one per sidecar
starting simultaneously) returned 0% success — all were throttled by the
`CreateMicrovmAuthToken` 50 req/s limit.

---

## Rate Limits Enforced

| API | Default limit | Configured by |
|-----|--------------|---------------|
| `RunMicrovm` | 5 req/s | `quotas.runMicrovmRate` |
| `TerminateMicrovm` | 10 req/s | `quotas.terminateMicrovmRate` |
| `SuspendMicrovm` | 2 req/s | `quotas.suspendMicrovmRate` |
| `ResumeMicrovm` | 5 req/s | `quotas.resumeMicrovmRate` |
| `GetMicrovm` | 100 req/s | `quotas.getMicrovmRate` |
| `CreateMicrovmAuthToken` | 50 req/s | `quotas.authTokenRate` |
| `CreateMicrovmShellAuthToken` | 5 req/s | `quotas.shellAuthTokenRate` |
| Concurrent image builds | 10 | `quotas.concurrentImageBuilds` |

All limits default to the AWS account defaults. Limits are discovered at install
time from the AWS Service Quotas API and baked into the Helm deployment — so if
your account has a quota increase, re-running the installer picks it up automatically.

---

## Discovering Active Limits

The operator logs its effective rate limits at startup:

```bash
kubectl logs -n kube-microvm deploy/kube-microvm-operator | grep QuotaGuard
```

Example output:
```
QuotaGuard initialised [DefaultQuotaPolicy]: run=5/s terminate=10/s suspend=2/s
  resume=5/s get=100/s authToken=50/s imageBuilds=10 tokenQueue=200
```

The class name in brackets confirms which `QuotaPolicy` implementation is active
(Community default: `DefaultQuotaPolicy`).

---

## Overriding After a Quota Increase

If AWS grants your account a quota increase, update the operator without rebuilding:

**Via install script** (re-runs Helm with new values):
```bash
./install_kube_microvm.sh \
  --cluster <CLUSTER> --region <REGION> \
  --quota-run-microvm-rate 20 \
  --quota-auth-token-rate 100
```

**Via Helm directly**:
```bash
helm upgrade kube-microvm-operator \
  oci://ghcr.io/plasticity-of-cloud/helm/kube-microvm-operator \
  --reuse-values \
  --set quotas.runMicrovmRate=20 \
  --set quotas.authTokenRate=100
```

**Via environment variable** (in `operator-controller` deployment):
```yaml
env:
  - name: AWS_QUOTA_RUN_MICROVM_RATE
    value: "20"
  - name: AWS_QUOTA_AUTH_TOKEN_RATE
    value: "100"
```

The operator must restart to pick up new values (they are applied at construction time).

---

## Install-Time Quota Discovery

By default, the installer queries the AWS Service Quotas API for your account's
actual limits and passes them as Helm values:

```bash
# Default: discovers quotas at install time, uses them for Helm values
./install_kube_microvm.sh --cluster <CLUSTER> --region <REGION> --iam

# Skip discovery (use AWS defaults):
./install_kube_microvm.sh --cluster <CLUSTER> --region <REGION> --no-quota-discovery

# Enable runtime re-check on every operator startup:
./install_kube_microvm.sh --cluster <CLUSTER> --region <REGION> --quota-discovery=runtime
```

Runtime discovery requires the IAM permission `service-quotas:GetServiceQuota` on
the operator's pod identity role. The installer adds it automatically when
`--quota-discovery=runtime` is specified.

If runtime discovery is enabled, the operator logs a warning at startup if the
configured value exceeds the discovered quota:

```
QUOTA MISMATCH: aws.quota.run-microvm-rate=20 exceeds AWS quota 5 —
operator may receive 429 errors. Run install script to re-discover quotas.
```

---

## ReplicaSet Cascade Behaviour

When you set `spec.desiredReplicaSetState: Suspended` on a large `MicroVMReplicaSet`,
the reconciler patches all children to `desiredState: Suspended`. Each patch triggers
the child `MicroVMReconciler` to call `SuspendMicrovm` on AWS.

`SuspendMicrovm` has a 2 req/s rate limit. The ReplicaSet reconciler deliberately
paces its child patches through the `QuotaGuard`, so a 100-VM suspend cascade takes
~50 seconds — not 100 simultaneous AWS calls.

**This is intentional.** A faster cascade would cause 429s on child reconcilers
and delay the suspend further through retries.

Effective throughput for suspend/resume cascades:

| Operation | Rate | Time for 100 VMs |
|-----------|------|-----------------|
| Suspend cascade | ~2 VMs/s | ~50s |
| Resume cascade | ~5 VMs/s | ~20s |
| Scale-up | ~1–5 VMs/reconcile cycle | depends on `RunMicrovm` quota |

---

## Token Endpoint Backpressure

The token endpoint (`POST .../microvms/{name}/token`) has a bounded request queue
(default: 200 in-flight slots). If more than 200 concurrent token requests arrive,
the operator returns HTTP 429 immediately rather than queuing indefinitely.

This prevents memory exhaustion when many sidecars start simultaneously. Callers
should implement exponential backoff with jitter (the `microvm-auth-agent` sidecar
does this automatically).

To increase the queue size:
```bash
helm upgrade kube-microvm-operator ... --set quotas.tokenQueueSize=500
```

---

## QuotaPolicy SPI (PRO)

PRO deployments can replace the default quota policy with a custom implementation
that applies per-tenant rate limits or a configurable safety margin. See the
[SPI Extension Points](../design/operator-spi.md) design document.
