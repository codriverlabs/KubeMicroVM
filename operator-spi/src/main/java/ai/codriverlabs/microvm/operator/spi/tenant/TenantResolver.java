package ai.codriverlabs.microvm.operator.spi.tenant;

/**
 * Resolves tenant identity from a Kubernetes namespace.
 *
 * <p>The Community default implementation maps all namespaces to a single
 * implicit tenant (single-tenant mode). PRO provides an implementation that
 * resolves tenant identity from namespace labels, annotations, or an external
 * registry, enabling per-tenant quota accounting and operator isolation.</p>
 *
 * @since 1.1.0
 */
public interface TenantResolver {

    /**
     * Resolves the tenant context for a given Kubernetes namespace.
     *
     * @param namespace Kubernetes namespace name
     * @return tenant context; never null — return {@link TenantContext#DEFAULT}
     *         for single-tenant deployments
     */
    TenantContext resolve(String namespace);

    /**
     * Returns true if this operator instance should reconcile resources
     * in the given namespace.
     *
     * <p>Used by PRO to implement per-tenant operator isolation where each
     * operator instance owns a subset of namespaces. Community default always
     * returns {@code true} — the operator watches all labelled namespaces.</p>
     *
     * @param namespace Kubernetes namespace name
     * @return true if this operator manages this namespace
     */
    default boolean isManaged(String namespace) {
        return true;
    }
}
