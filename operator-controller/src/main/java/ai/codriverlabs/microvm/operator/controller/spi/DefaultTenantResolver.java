package ai.codriverlabs.microvm.operator.controller.spi;

import ai.codriverlabs.microvm.operator.spi.tenant.TenantContext;
import ai.codriverlabs.microvm.operator.spi.tenant.TenantResolver;
import jakarta.enterprise.context.ApplicationScoped;

/**
 * Community default implementation of {@link TenantResolver}.
 *
 * Single-tenant mode — all namespaces map to {@link TenantContext#DEFAULT}.
 * The operator watches all labelled namespaces.
 *
 * PRO replaces this with @Alternative @Priority(100) for namespace-scoped
 * tenant isolation and per-operator-instance namespace ownership.
 */
@ApplicationScoped
public class DefaultTenantResolver implements TenantResolver {

    @Override
    public TenantContext resolve(String namespace) {
        return TenantContext.DEFAULT;
    }

    @Override
    public boolean isManaged(String namespace) {
        return true; // Community: operator manages all labelled namespaces
    }
}
