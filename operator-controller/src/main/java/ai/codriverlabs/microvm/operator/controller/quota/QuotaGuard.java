package ai.codriverlabs.microvm.operator.controller.quota;

import jakarta.enterprise.context.ApplicationScoped;
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
 * All limits are configurable via application properties (and therefore via
 * Helm values / install script flags) so customers who receive quota increases
 * can tune without rebuilding the operator.
 *
 * Default values match AWS account-level defaults.
 *
 * Rate limiting uses a simple token bucket: permits are replenished at the
 * configured rate and callers block until a permit is available.
 */
@ApplicationScoped
public class QuotaGuard {

    private static final Logger LOG = Logger.getLogger(QuotaGuard.class);

    // ── Rate limiters (tokens per second) ─────────────────────────────────────

    private final TokenBucket runMicrovmBucket;
    private final TokenBucket terminateBucket;
    private final TokenBucket suspendBucket;
    private final TokenBucket resumeBucket;
    private final TokenBucket getMicrovmBucket;
    private final TokenBucket authTokenBucket;
    private final TokenBucket shellAuthTokenBucket;

    // ── Count limiters ────────────────────────────────────────────────────────

    private final Semaphore imageBuildSemaphore;
    private final Semaphore tokenQueueSemaphore;

    public QuotaGuard(
            @ConfigProperty(name = "aws.quota.run-microvm-rate", defaultValue = "4")
            int runMicrovmRate,
            @ConfigProperty(name = "aws.quota.terminate-microvm-rate", defaultValue = "9")
            int terminateRate,
            @ConfigProperty(name = "aws.quota.suspend-microvm-rate", defaultValue = "1")
            int suspendRate,
            @ConfigProperty(name = "aws.quota.resume-microvm-rate", defaultValue = "4")
            int resumeRate,
            @ConfigProperty(name = "aws.quota.get-microvm-rate", defaultValue = "90")
            int getMicrovmRate,
            @ConfigProperty(name = "aws.quota.auth-token-rate", defaultValue = "45")
            int authTokenRate,
            @ConfigProperty(name = "aws.quota.shell-auth-token-rate", defaultValue = "4")
            int shellAuthTokenRate,
            @ConfigProperty(name = "aws.quota.concurrent-image-builds", defaultValue = "9")
            int maxImageBuilds,
            @ConfigProperty(name = "aws.quota.token-queue-size", defaultValue = "200")
            int tokenQueueSize
    ) {
        this.runMicrovmBucket      = new TokenBucket(runMicrovmRate,      "run-microvm");
        this.terminateBucket       = new TokenBucket(terminateRate,        "terminate-microvm");
        this.suspendBucket         = new TokenBucket(suspendRate,          "suspend-microvm");
        this.resumeBucket          = new TokenBucket(resumeRate,           "resume-microvm");
        this.getMicrovmBucket      = new TokenBucket(getMicrovmRate,       "get-microvm");
        this.authTokenBucket       = new TokenBucket(authTokenRate,        "auth-token");
        this.shellAuthTokenBucket  = new TokenBucket(shellAuthTokenRate,   "shell-auth-token");
        this.imageBuildSemaphore   = new Semaphore(maxImageBuilds);
        this.tokenQueueSemaphore   = new Semaphore(tokenQueueSize);

        LOG.infof("QuotaGuard initialised: run=%d/s terminate=%d/s suspend=%d/s " +
                  "resume=%d/s get=%d/s authToken=%d/s imageBuilds=%d tokenQueue=%d",
                runMicrovmRate, terminateRate, suspendRate, resumeRate,
                getMicrovmRate, authTokenRate, maxImageBuilds, tokenQueueSize);
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
     * Returns false if the queue is full — callers should return HTTP 429.
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
     * Acquire an image build permit. Blocks up to 60s waiting for a slot.
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

    /**
     * Simple token bucket rate limiter.
     * Replenishes tokens at the configured rate and blocks callers until
     * a token is available.
     */
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
            if (intervalNanos == 0) return; // unlimited
            while (true) {
                long now = System.nanoTime();
                long next = nextPermitNanos.get();
                long wait = next - now;
                if (wait <= 0) {
                    // Try to claim this slot
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
