package ai.codriverlabs.microvm.operator.controller.spi;

import ai.codriverlabs.microvm.operator.spi.auth.TokenPolicy;
import jakarta.enterprise.context.ApplicationScoped;

/**
 * Community default implementation of {@link TokenPolicy}.
 *
 * Applies only the configured global maximum expiry.
 * No concurrency enforcement, no audit logging.
 *
 * PRO replaces this with @Alternative @Priority(100) for per-tenant
 * token budgets, exclusive access enforcement, and audit logging.
 */
@ApplicationScoped
public class DefaultTokenPolicy implements TokenPolicy {
    // All methods use the interface's default no-op implementations.
    // Overriding maxExpiryMinutes only to document the Community behaviour.

    @Override
    public int maxExpiryMinutes(String namespace, String vmName,
                                 int requestedMinutes, int globalMaxMinutes) {
        return Math.min(requestedMinutes, globalMaxMinutes);
    }
}
