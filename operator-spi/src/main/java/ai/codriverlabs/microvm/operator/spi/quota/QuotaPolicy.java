package ai.codriverlabs.microvm.operator.spi.quota;

/**
 * Controls AWS API rate limit enforcement for the operator.
 *
 * <p>The Community default implementation ({@code DefaultQuotaPolicy} in
 * {@code operator-controller}) uses the exact configured values with no
 * modification.</p>
 *
 * <p>To override, provide an implementation annotated with
 * {@code @Alternative @Priority(100)} as a Quarkus CDI bean.</p>
 *
 * @since 1.1.0
 */
public interface QuotaPolicy {

    /**
     * Returns the effective rate limit for the given AWS API operation.
     *
     * <p>Called once at operator startup to configure internal rate limiters.
     * The returned value is used for the lifetime of the process.</p>
     *
     * @param operation     the AWS API operation name (e.g., {@code "RunMicrovm"},
     *                      {@code "CreateMicrovmAuthToken"})
     * @param configuredRate the rate (req/s) configured in application properties
     *                       or discovered from AWS Service Quotas at install time
     * @return effective rate to enforce in req/s; must be &gt; 0
     */
    int effectiveRate(String operation, int configuredRate);

    /**
     * Returns the effective concurrent image build limit.
     *
     * @param configuredLimit the limit configured in application properties
     * @return effective concurrent build limit; must be &gt; 0
     */
    int effectiveImageBuildLimit(int configuredLimit);
}
