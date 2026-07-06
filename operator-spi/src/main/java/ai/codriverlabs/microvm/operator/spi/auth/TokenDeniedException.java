package ai.codriverlabs.microvm.operator.spi.auth;

/**
 * Thrown by {@link TokenPolicy#beforeIssue} to block token issuance.
 * The message is returned as the HTTP 403 response body to the caller.
 *
 * @since 1.1.0
 */
public class TokenDeniedException extends Exception {
    public TokenDeniedException(String message) {
        super(message);
    }
}
