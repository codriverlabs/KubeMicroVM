package ai.codriverlabs.microvm.operator.controller.quota;

import ai.codriverlabs.microvm.operator.spi.quota.QuotaPolicy;
import jakarta.enterprise.context.ApplicationScoped;
import jakarta.inject.Inject;
import org.eclipse.microprofile.config.inject.ConfigProperty;
import org.jboss.logging.Logger;

import java.util.concurrent.CompletableFuture;
import java.util.concurrent.Semaphore;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicLong;
import java.util.function.Supplier;

/**
 * Operator-level quota guard — enforces AWS Lambda MicroVMs API rate limits.
 *
 * Configured values (from application properties / Helm values / install-time
 * discovery) are passed through {@link QuotaPolicy#effectiveRate} before being
 * applied to the internal token buckets. This allows PRO to inject a safety
 * margin or per-tenant adjustment without changing any reconciler code.
 *
 * Community default: {@link ai.codriverlabs.microvm.operator.controller.spi.DefaultQuotaPolicy}
 * returns the configured value unchanged.
 */
@ApplicationScoped
public class QuotaGuard {

    private static final Logger LOG = Logger.getLogger(QuotaGuard.class);

    private final TokenBucket runMicrovmBucket;
    private final TokenBucket terminateBucket;
    private final TokenBucket suspendBucket;
    private final TokenBucket resumeBucket;
    private final TokenBucket getMicrovmBucket;
    private final TokenBucket authTokenBucket;
    private final TokenBucket shellAuthTokenBucket;

    private final Semaphore imageBuildSemaphore;
    private final Semaphore tokenQueueSemaphore;

    @Inject
    public QuotaGuard(
            QuotaPolicy quotaPolicy,
            @ConfigProperty(name = "aws.quota.run-microvm-rate",        defaultValue = "5")  int runRate,
            @ConfigProperty(name = "aws.quota.terminate-microvm-rate",  defaultValue = "10") int terminateRate,
            @ConfigProperty(name = "aws.quota.suspend-microvm-rate",    defaultValue = "2")  int suspendRate,
            @ConfigProperty(name = "aws.quota.resume-microvm-rate",     defaultValue = "5")  int resumeRate,
            @ConfigProperty(name = "aws.quota.get-microvm-rate",        defaultValue = "100") int getRate,
            @ConfigProperty(name = "aws.quota.auth-token-rate",         defaultValue = "50") int authTokenRate,
            @ConfigProperty(name = "aws.quota.shell-auth-token-rate",   defaultValue = "5")  int shellAuthTokenRate,
            @ConfigProperty(name = "aws.quota.concurrent-image-builds", defaultValue = "10") int maxImageBuilds,
            @ConfigProperty(name = "aws.quota.token-queue-size",        defaultValue = "200") int tokenQueueSize
    ) {
        // Pass each configured value through QuotaPolicy — Community returns as-is,
        // PRO may apply safety margin, per-tenant limits, etc.
        int effectiveRun        = quotaPolicy.effectiveRate("RunMicrovm",                    runRate);
        int effectiveTerminate  = quotaPolicy.effectiveRate("TerminateMicrovm",              terminateRate);
        int effectiveSuspend    = quotaPolicy.effectiveRate("SuspendMicrovm",                suspendRate);
        int effectiveResume     = quotaPolicy.effectiveRate("ResumeMicrovm",                 resumeRate);
        int effectiveGet        = quotaPolicy.effectiveRate("GetMicrovm",                    getRate);
        int effectiveAuthToken  = quotaPolicy.effectiveRate("CreateMicrovmAuthToken",        authTokenRate);
        int effectiveShellToken = quotaPolicy.effectiveRate("CreateMicrovmShellAuthToken",   shellAuthTokenRate);
        int effectiveBuilds     = quotaPolicy.effectiveImageBuildLimit(maxImageBuilds);

        this.runMicrovmBucket      = new TokenBucket(effectiveRun,        "run-microvm");
        this.terminateBucket       = new TokenBucket(effectiveTerminate,   "terminate-microvm");
        this.suspendBucket         = new TokenBucket(effectiveSuspend,     "suspend-microvm");
        this.resumeBucket          = new TokenBucket(effectiveResume,      "resume-microvm");
        this.getMicrovmBucket      = new TokenBucket(effectiveGet,         "get-microvm");
        this.authTokenBucket       = new TokenBucket(effectiveAuthToken,   "auth-token");
        this.shellAuthTokenBucket  = new TokenBucket(effectiveShellToken,  "shell-auth-token");
        this.imageBuildSemaphore   = new Semaphore(effectiveBuilds);
        this.tokenQueueSemaphore   = new Semaphore(tokenQueueSize);

        LOG.infof("QuotaGuard initialised via %s: run=%d/s terminate=%d/s suspend=%d/s " +
                  "resume=%d/s get=%d/s authToken=%d/s imageBuilds=%d tokenQueue=%d",
                quotaPolicy.getClass().getSimpleName(),
                effectiveRun, effectiveTerminate, effectiveSuspend, effectiveResume,
                effectiveGet, effectiveAuthToken, effectiveBuilds, tokenQueueSize);
    }

    // ── Public API ────────────────────────────────────────────────────────────

    public <T> CompletableFuture<T> runMicrovm(Supplier<CompletableFuture<T>> call) {
        runMicrovmBucket.acquire();
        return call.get();
    }

    public <T> CompletableFuture<T> terminateMicrovm(Supplier<CompletableFuture<T>> call) {
        terminateBucket.acquire();
        return call.get();
    }

    public <T> CompletableFuture<T> suspendMicrovm(Supplier<CompletableFuture<T>> call) {
        suspendBucket.acquire();
        return call.get();
    }

    public <T> CompletableFuture<T> resumeMicrovm(Supplier<CompletableFuture<T>> call) {
        resumeBucket.acquire();
        return call.get();
    }

    public <T> CompletableFuture<T> getMicrovm(Supplier<CompletableFuture<T>> call) {
        getMicrovmBucket.acquire();
        return call.get();
    }

    /**
     * Rate-limited auth token call with bounded queue backpressure.
     * Throws QuotaExceededException if the queue is full — callers return HTTP 429.
     */
    public <T> CompletableFuture<T> createAuthToken(Supplier<CompletableFuture<T>> call)
            throws QuotaExceededException {
        if (!tokenQueueSemaphore.tryAcquire()) {
            throw new QuotaExceededException("Token request queue full — retry later");
        }
        try {
            authTokenBucket.acquire();
            return call.get();
        } finally {
            tokenQueueSemaphore.release();
        }
    }

    public <T> CompletableFuture<T> createShellAuthToken(Supplier<CompletableFuture<T>> call)
            throws QuotaExceededException {
        if (!tokenQueueSemaphore.tryAcquire()) {
            throw new QuotaExceededException("Shell token request queue full — retry later");
        }
        try {
            shellAuthTokenBucket.acquire();
            return call.get();
        } finally {
            tokenQueueSemaphore.release();
        }
    }

    /**
     * Acquire an image build permit. Blocks up to 60s.
     * Throws QuotaExceededException if no slot becomes available.
     */
    public void acquireImageBuildPermit() throws QuotaExceededException {
        try {
            if (!imageBuildSemaphore.tryAcquire(60, TimeUnit.SECONDS)) {
                throw new QuotaExceededException(
                    "Concurrent image build limit reached — retry later");
            }
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
            throw new QuotaExceededException("Interrupted waiting for image build permit");
        }
        LOG.debugf("Image build permit acquired (%d remaining)",
                imageBuildSemaphore.availablePermits());
    }

    public void releaseImageBuildPermit() {
        imageBuildSemaphore.release();
        LOG.debugf("Image build permit released (%d available)",
                imageBuildSemaphore.availablePermits());
    }

    public int availableImageBuildPermits() {
        return imageBuildSemaphore.availablePermits();
    }

    public int availableTokenQueueSlots() {
        return tokenQueueSemaphore.availablePermits();
    }

    // ── Token bucket implementation ───────────────────────────────────────────

    static class TokenBucket {
        private final String name;
        private final long intervalNanos;
        private final AtomicLong nextPermitNanos;

        TokenBucket(int ratePerSecond, String name) {
            this.name = name;
            this.intervalNanos = ratePerSecond > 0
                    ? (long) (1_000_000_000.0 / ratePerSecond)
                    : 0;
            this.nextPermitNanos = new AtomicLong(System.nanoTime());
        }

        void acquire() {
            if (intervalNanos == 0) return;
            while (true) {
                long now = System.nanoTime();
                long next = nextPermitNanos.get();
                long wait = next - now;
                if (wait <= 0) {
                    if (nextPermitNanos.compareAndSet(next, now + intervalNanos)) {
                        return;
                    }
                } else {
                    try {
                        TimeUnit.NANOSECONDS.sleep(Math.min(wait, intervalNanos));
                    } catch (InterruptedException e) {
                        Thread.currentThread().interrupt();
                        return;
                    }
                }
            }
        }
    }
}
