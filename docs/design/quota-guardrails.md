# Design: Operator-Level Rate Limiting & Backpressure

**Status**: RFC  
**Branch**: `feature/token-burst-investigation`  
**Motivation**: AWS Lambda MicroVMs API enforces hard per-account rate limits.
The operator is the single API caller for the entire cluster and must enforce
these limits internally to prevent 429 errors and cascading retry storms.

---

## Complete Quota Reference

| API / Limit | Rate (sustained) | Burst | Scope |
|-------------|-----------------|-------|-------|
| `RunMicrovm` | 5 req/s | 5 req/s | Account |
| `TerminateMicrovm` | 10 req/s | 10 req/s | Account |
| `SuspendMicrovm` | 2 req/s | 2 req/s | Account |
| `ResumeMicrovm` | 5 req/s | 5 req/s | Account |
| `GetMicrovm` | 100 req/s | 100 req/s | Account |
| `CreateMicrovmAuthToken` | 50 req/s | 50 req/s | Account |
| `CreateMicrovmShellAuthToken` | 5 req/s | 5 req/s | Account |
| Concurrent image builds | 10 | — | Account |
| Total MicroVM images | 100 | — | Account |
| Versions per image | 50 | — | Account |

**Key observation**: burst == sustained rate for all APIs — there is no burst headroom.
Any spike above the rate limit is immediately throttled.

---

## Where the Operator Currently Violates These Limits

| Scenario | API | Current behaviour | Risk |
|----------|-----|-------------------|------|
| MicroVMReplicaSet scale-up | `RunMicrovm` (5/s) | 1 VM per reconcile, reschedule after 3s → ~0.3/s per RS | Safe for 1 RS; multiple RSes scale linearly, could breach |
| RS scale-down / suspend cascade | `TerminateMicrovm` (10/s), `SuspendMicrovm` (2/s) | All victims patched in same reconcile | Easily exceeds 2/s for SuspendMicrovm |
| Token endpoint under sidecar burst | `CreateMicrovmAuthToken` (50/s) | No queuing — all concurrent requests hit AWS simultaneously | 50 sidecars starting = burst exhausted, 0% success |
| Multiple MicroVMImage builds | Concurrent builds (10) | No build count tracking | 11th build silently fails or returns error |
| RS polling across many VMs | `GetMicrovm` (100/s) | Each reconcile polls 1 VM; safe at current scale | Could breach with >100 VMs in active polling phase |

---

## Proposed Solution: `QuotaGuard` Bean

A single CDI `@ApplicationScoped` bean wraps all outbound AWS API calls with:
- **Token bucket rate limiter** per operation (respects sustained rate)
- **Semaphore** for count-limited resources (image builds)
- **Bounded queue with backpressure** for token endpoint requests

```
MicroVMReconciler
MicroVMImageReconciler    ──→  QuotaGuard  ──→  DefaultMicroVMClient  ──→  AWS
MicroVMReplicaSetReconciler                      MicroVMImageClient
MicroVMTokenResource                             MicroVMNetworkClient
```

### Rate Limiter per Operation

```java
@ApplicationScoped
public class QuotaGuard {

    // Token bucket per operation — burst == rate (no headroom)
    private final RateLimiter runMicrovmLimiter      = RateLimiter.create(4.5);  // 5/s, 10% margin
    private final RateLimiter terminateLimiter        = RateLimiter.create(9.0);  // 10/s
    private final RateLimiter suspendLimiter          = RateLimiter.create(1.8);  // 2/s
    private final RateLimiter resumeLimiter           = RateLimiter.create(4.5);  // 5/s
    private final RateLimiter getMicrovmLimiter       = RateLimiter.create(90.0); // 100/s
    private final RateLimiter authTokenLimiter        = RateLimiter.create(45.0); // 50/s
    private final RateLimiter shellAuthTokenLimiter   = RateLimiter.create(4.5);  // 5/s

    // Semaphore for concurrent image builds
    private final Semaphore imageBuildSemaphore = new Semaphore(10);

    // Bounded queue for token requests (backpressure)
    private final Semaphore tokenQueueSemaphore = new Semaphore(200); // max 200 in-flight + queued

    public <T> CompletableFuture<T> runMicrovm(Supplier<CompletableFuture<T>> call) {
        runMicrovmLimiter.acquire();
        return call.get();
    }

    public <T> CompletableFuture<T> terminateMicrovm(Supplier<CompletableFuture<T>> call) {
        terminateLimiter.acquire();
        return call.get();
    }

    public <T> CompletableFuture<T> suspendMicrovm(Supplier<CompletableFuture<T>> call) {
        suspendLimiter.acquire();
        return call.get();
    }

    public <T> CompletableFuture<T> createAuthToken(Supplier<CompletableFuture<T>> call) {
        if (!tokenQueueSemaphore.tryAcquire()) {
            throw new QuotaExceededException("Token request queue full — backpressure");
        }
        try {
            authTokenLimiter.acquire();  // blocks until rate allows
            return call.get();
        } finally {
            tokenQueueSemaphore.release();
        }
    }

    public <T> T withImageBuildPermit(Supplier<T> call) throws InterruptedException {
        if (!imageBuildSemaphore.tryAcquire(30, TimeUnit.SECONDS)) {
            throw new QuotaExceededException(
                "Image build quota full (10 concurrent builds) — retry later");
        }
        try {
            return call.get();
        } finally {
            imageBuildSemaphore.release();
        }
    }
}
```

### Rate limiter margin (10% safety buffer)

We set each limiter to 90% of the quota to absorb clock skew between operator
instances and avoid hitting the limit edge. With a single operator pod this is
conservative; with future multi-replica operators it prevents cross-replica races.

---

## Where Each Guard is Applied

### `MicroVMReconciler` — RunMicrovm, TerminateMicrovm, SuspendMicrovm, ResumeMicrovm

```java
// Before:
client.runMicroVM(request).get(TIMEOUT, SECONDS);

// After:
quotaGuard.runMicrovm(() -> client.runMicroVM(request)).get(TIMEOUT, SECONDS);
```

The `acquire()` call blocks the reconciler thread until a token is available.
JOSDK reconcilers run in a thread pool — blocked threads park and release CPU.

### `MicroVMImageReconciler` — Concurrent build limit

The semaphore is acquired when a new build is triggered (imageArn == null, create path)
and released when the image reaches a terminal state (CREATED, CREATE_FAILED).

```java
// In ensureStatus / CREATE path:
quotaGuard.withImageBuildPermit(() -> {
    imageClient.createImage(...);
    status.setBuildPermitHeld(true);  // tracked in status to know when to release
});
```

Release happens in the SETTLED path when `isBuildSettled()` returns true.

### `MicroVMTokenResource` — CreateMicrovmAuthToken with backpressure

The token endpoint already has Kubernetes TokenReview + SubjectAccessReview before
reaching AWS. The QuotaGuard is applied after auth passes, before the AWS call:

```java
// In MicroVMTokenResource.createToken():
return quotaGuard.createAuthToken(
    () -> microVMClient.createAuthToken(vmId, expirySeconds)
).get(TIMEOUT, SECONDS);
```

If the queue is full (200 in-flight requests), the endpoint returns **HTTP 429**
with `Retry-After: 1` — the sidecar auth-agent retries with backoff.

---

## Backpressure Flow for Token Requests

```
1000 sidecars start simultaneously
         │
         ▼
POST /token (1000 concurrent)
         │
         ▼
┌─────────────────────────────────┐
│ QuotaGuard.createAuthToken()    │
│                                 │
│ tokenQueueSemaphore (max 200)   │
│   ├── first 200 acquire permit  │
│   └── remaining 800 → HTTP 429  │◄── sidecars receive 429, backoff+retry
│                                 │
│ authTokenLimiter (45/s)         │
│   └── 200 queue up, drain at    │
│       45 tokens/second          │
│       200 / 45 = ~4.4s to drain │
└─────────────────────────────────┘
         │
         ▼
AWS CreateMicrovmAuthToken (≤45/s)
```

The 800 rejected sidecars retry with exponential backoff (1s, 2s, 4s...).
By the time they retry, the queue has drained and accepts them.

---

## Metrics to Add

These guards should emit Prometheus metrics via `OperatorMetrics`:

```
microvm_quota_wait_seconds{operation="run_microvm"}         # time spent waiting for rate limiter
microvm_quota_wait_seconds{operation="create_auth_token"}
microvm_quota_rejected_total{operation="create_auth_token"} # 429s returned
microvm_image_build_permits_available                        # current semaphore count (0-10)
microvm_token_queue_size                                     # current in-flight token requests
```

---

## Implementation Plan

| Step | Component | Change |
|------|-----------|--------|
| 1 | `QuotaGuard.java` (new) | Token bucket limiters + semaphores |
| 2 | `DefaultMicroVMClient` | Wrap RunMicrovm, Terminate, Suspend, Resume calls |
| 3 | `MicroVMImageReconciler` | Acquire/release image build semaphore |
| 4 | `MicroVMTokenResource` | Queue + rate limit auth token calls, return 429 on overflow |
| 5 | `TokenRefreshAgent` | Handle 429 with exponential backoff + jitter |
| 6 | `OperatorMetrics` | Add quota wait time + rejection counters |
| 7 | Integration tests | Test backpressure, semaphore exhaustion, rate limit behaviour |

---

## What This Does NOT Cover

- **GetMicrovm (100/s)**: Safe at current scale; add guard if operator manages >50 VMs in active polling
- **Multi-replica single operator**: In-process rate limiters are sufficient — a single operator pod per cluster is the correct deployment model. Multiple replicas of the same operator would compete with themselves and are not a supported configuration.
- **Cross-tenant quota coordination (PRO)**: In a multi-tenant deployment where each namespace runs its own isolated operator instance (one operator per tenant, namespace-scoped roles/bindings, no ClusterRole), all operator processes share the same AWS account-level quotas but each has an independent in-process limiter. This is a PRO-tier concern and requires a shared quota arbiter — either a lightweight coordinator CRD that operators update with their current token consumption, or a dedicated quota service that all tenant operators call before issuing AWS requests. This is out of scope for Community edition where a single operator manages the cluster.
