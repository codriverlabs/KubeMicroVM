package ai.codriverlabs.microvm.operator.spi.lifecycle;

/**
 * Lifecycle hook called during operator startup and shutdown.
 *
 * <p>Allows the PRO module to perform initialisation before reconcilers start
 * (e.g., license validation, telemetry registration, feature flag loading) and
 * cleanup on shutdown.</p>
 *
 * <p>Community default: no-op for both methods.</p>
 *
 * @since 1.1.0
 */
public interface OperatorExtension {

    /**
     * Called after AWS connectivity is confirmed but before reconcilers start.
     *
     * <p>Throw {@link ExtensionInitException} to abort operator startup with
     * a clear error message (e.g., license validation failure).</p>
     *
     * @throws ExtensionInitException if startup should be aborted
     */
    default void onStartup() throws ExtensionInitException {
        // no-op in Community
    }

    /**
     * Called during graceful shutdown before reconcilers stop.
     *
     * <p>Used by PRO for telemetry flush, audit log finalisation.</p>
     */
    default void onShutdown() {
        // no-op in Community
    }
}
