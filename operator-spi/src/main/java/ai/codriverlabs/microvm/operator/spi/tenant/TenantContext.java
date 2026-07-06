package ai.codriverlabs.microvm.operator.spi.tenant;

import java.util.Objects;

/**
 * Immutable value object representing a resolved tenant identity.
 *
 * @since 1.1.0
 */
public final class TenantContext {

    /**
     * Singleton tenant context used in single-tenant (Community) deployments.
     */
    public static final TenantContext DEFAULT = new TenantContext("default", null);

    private final String tenantId;
    private final String displayName;

    public TenantContext(String tenantId, String displayName) {
        this.tenantId = Objects.requireNonNull(tenantId, "tenantId must not be null");
        this.displayName = displayName;
    }

    /** Unique tenant identifier — used for quota accounting and log correlation. */
    public String tenantId() { return tenantId; }

    /** Human-readable tenant name, or null if not available. */
    public String displayName() { return displayName; }

    public boolean isDefault() { return DEFAULT.tenantId.equals(tenantId); }

    @Override public String toString() {
        return displayName != null ? displayName + " (" + tenantId + ")" : tenantId;
    }

    @Override public boolean equals(Object o) {
        if (this == o) return true;
        if (!(o instanceof TenantContext t)) return false;
        return tenantId.equals(t.tenantId);
    }

    @Override public int hashCode() { return tenantId.hashCode(); }
}
