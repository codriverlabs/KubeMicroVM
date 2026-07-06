package ai.codriverlabs.microvm.operator.controller.spi;

import ai.codriverlabs.microvm.operator.spi.quota.QuotaPolicy;
import jakarta.enterprise.context.ApplicationScoped;

/**
 * Community default implementation of {@link QuotaPolicy}.
 *
 * Returns configured values exactly as-is — no safety margin applied.
 * Quota values are discovered at install time by the install script and
 * passed as application properties / Helm values.
 *
 * PRO replaces this with @Alternative @Priority(100) for per-tenant
 * accounting and configurable safety margin.
 */
@ApplicationScoped
public class DefaultQuotaPolicy implements QuotaPolicy {

    @Override
    public int effectiveRate(String operation, int configuredRate) {
        return configuredRate;
    }

    @Override
    public int effectiveImageBuildLimit(int configuredLimit) {
        return configuredLimit;
    }
}
