package ai.codriverlabs.microvm.operator.controller.spi;

import ai.codriverlabs.microvm.operator.spi.lifecycle.OperatorExtension;
import jakarta.enterprise.context.ApplicationScoped;

/**
 * Community default implementation of {@link OperatorExtension}.
 *
 * No-op startup and shutdown hooks.
 *
 * PRO replaces this with @Alternative @Priority(100) for license validation,
 * telemetry registration, and feature flag loading.
 */
@ApplicationScoped
public class DefaultOperatorExtension implements OperatorExtension {
    // All methods use the interface's default no-op implementations.
}
