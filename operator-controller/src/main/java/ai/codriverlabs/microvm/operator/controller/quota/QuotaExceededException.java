package ai.codriverlabs.microvm.operator.controller.quota;

/**
 * Thrown when an AWS API quota limit is reached and the request
 * cannot be queued. Callers should return HTTP 429 to clients.
 */
public class QuotaExceededException extends RuntimeException {
    public QuotaExceededException(String message) {
        super(message);
    }
}
