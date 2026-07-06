package ai.codriverlabs.microvm.operator.spi.auth;

/**
 * Controls MicroVM auth token issuance policy.
 *
 * <p>The Community default applies no restrictions beyond the configured global
 * maximum expiry. PRO implementations can add per-tenant token budgets,
 * exclusive access enforcement, and audit logging.</p>
 *
 * <p>All methods have default no-op implementations so that Community code
 * compiles without requiring an implementation to override every method.</p>
 *
 * @since 1.1.0
 */
public interface TokenPolicy {

    /**
     * Returns the effective maximum token expiry for the given context.
     *
     * <p>The operator clamps the caller-requested expiry to this value.</p>
     *
     * @param namespace         Kubernetes namespace of the requesting pod
     * @param vmName            name of the target MicroVM CR
     * @param requestedMinutes  expiry requested by the caller
     * @param globalMaxMinutes  configured global maximum from application properties
     * @return effective maximum expiry in minutes; must be &gt; 0
     */
    default int maxExpiryMinutes(String namespace, String vmName,
                                  int requestedMinutes, int globalMaxMinutes) {
        return Math.min(requestedMinutes, globalMaxMinutes);
    }

    /**
     * Called before a token is issued. May throw {@link TokenDeniedException}
     * to block issuance — the exception message is returned as HTTP 403 to the caller.
     *
     * <p>Community default: no-op.</p>
     *
     * @param namespace      namespace of the requesting pod
     * @param vmName         name of the MicroVM CR
     * @param serviceAccount service account of the requesting pod
     * @throws TokenDeniedException if token issuance should be blocked
     */
    default void beforeIssue(String namespace, String vmName, String serviceAccount)
            throws TokenDeniedException {
        // no-op in Community
    }

    /**
     * Called after a token is successfully issued.
     *
     * <p>Used by PRO for audit logging and per-tenant token quota accounting.
     * Community default: no-op.</p>
     *
     * @param namespace      namespace of the requesting pod
     * @param vmName         name of the MicroVM CR
     * @param serviceAccount service account of the requesting pod
     * @param expiryMinutes  actual expiry granted
     */
    default void afterIssue(String namespace, String vmName,
                             String serviceAccount, int expiryMinutes) {
        // no-op in Community
    }
}
