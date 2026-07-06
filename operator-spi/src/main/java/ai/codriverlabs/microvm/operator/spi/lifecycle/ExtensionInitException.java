package ai.codriverlabs.microvm.operator.spi.lifecycle;

/**
 * Thrown by {@link OperatorExtension#onStartup} to abort operator startup.
 * The message is logged as a fatal error.
 *
 * @since 1.1.0
 */
public class ExtensionInitException extends Exception {
    public ExtensionInitException(String message) {
        super(message);
    }

    public ExtensionInitException(String message, Throwable cause) {
        super(message, cause);
    }
}
