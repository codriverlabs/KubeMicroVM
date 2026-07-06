package ai.codriverlabs.microvm.operator.controller.quota;

import io.quarkus.runtime.StartupEvent;
import jakarta.enterprise.context.ApplicationScoped;
import jakarta.enterprise.event.Observes;
import org.eclipse.microprofile.config.inject.ConfigProperty;
import org.jboss.logging.Logger;
import software.amazon.awssdk.regions.Region;
import software.amazon.awssdk.services.servicequotas.ServiceQuotasClient;
import software.amazon.awssdk.services.servicequotas.model.GetServiceQuotaRequest;

/**
 * Optional runtime quota discovery — queries AWS Service Quotas API at startup
 * and logs the operator's effective rate limits.
 *
 * Enabled via: aws.quota.discovery.enabled=true (or --quota-discovery=runtime install flag).
 *
 * When enabled, the operator logs the discovered quota values at startup.
 * The QuotaGuard is configured from application properties (populated by the
 * install script's discovery) — this bean provides a runtime cross-check and
 * logs a warning if the configured values exceed the discovered quotas.
 *
 * Requires IAM permission: service-quotas:GetServiceQuota
 * This permission is added to the operator role when --quota-discovery=runtime is used.
 */
@ApplicationScoped
public class QuotaDiscovery {

    private static final Logger LOG = Logger.getLogger(QuotaDiscovery.class);

    // AWS Service Quotas codes for Lambda MicroVMs (service-code: lambda)
    static final String CODE_RUN_BURST          = "L-91B95582"; // Burst rate of RunMicrovm
    static final String CODE_TERMINATE_BURST    = "L-2CCA0501"; // Burst rate of TerminateMicrovm
    static final String CODE_SUSPEND_BURST      = "L-139F9A48"; // Burst rate of SuspendMicrovm
    static final String CODE_RESUME_BURST       = "L-25EEC0A4"; // Burst rate of ResumeMicrovm
    static final String CODE_GET_BURST          = "L-C9C2110E"; // Burst rate of GetMicrovm
    static final String CODE_AUTH_TOKEN_BURST   = "L-D65D9F16"; // Burst rate of CreateMicrovmAuthToken
    static final String CODE_SHELL_TOKEN_BURST  = "L-9A5E43A5"; // Burst rate of CreateMicrovmShellAuthToken
    static final String CODE_IMAGE_BUILDS       = "L-72E0D058"; // Concurrent image builds

    @ConfigProperty(name = "aws.quota.discovery.enabled", defaultValue = "false")
    boolean discoveryEnabled;

    @ConfigProperty(name = "aws.region", defaultValue = "us-east-1")
    String region;

    // Configured values (from install-time discovery or defaults)
    @ConfigProperty(name = "aws.quota.run-microvm-rate",        defaultValue = "5")  int configuredRun;
    @ConfigProperty(name = "aws.quota.terminate-microvm-rate",  defaultValue = "10") int configuredTerminate;
    @ConfigProperty(name = "aws.quota.suspend-microvm-rate",    defaultValue = "2")  int configuredSuspend;
    @ConfigProperty(name = "aws.quota.resume-microvm-rate",     defaultValue = "5")  int configuredResume;
    @ConfigProperty(name = "aws.quota.auth-token-rate",         defaultValue = "50") int configuredAuthToken;
    @ConfigProperty(name = "aws.quota.concurrent-image-builds", defaultValue = "10") int configuredImageBuilds;

    void onStart(@Observes StartupEvent ev) {
        if (!discoveryEnabled) {
            LOG.infof("Quota discovery disabled — using configured values: " +
                      "run=%d/s terminate=%d/s suspend=%d/s authToken=%d/s imageBuilds=%d",
                    configuredRun, configuredTerminate, configuredSuspend,
                    configuredAuthToken, configuredImageBuilds);
            return;
        }

        LOG.info("Quota discovery enabled — querying AWS Service Quotas");
        try (var sq = ServiceQuotasClient.builder().region(Region.of(region)).build()) {
            int awsRun          = getQuota(sq, CODE_RUN_BURST,          configuredRun);
            int awsTerminate    = getQuota(sq, CODE_TERMINATE_BURST,    configuredTerminate);
            int awsSuspend      = getQuota(sq, CODE_SUSPEND_BURST,      configuredSuspend);
            int awsResume       = getQuota(sq, CODE_RESUME_BURST,       configuredResume);
            int awsAuthToken    = getQuota(sq, CODE_AUTH_TOKEN_BURST,   configuredAuthToken);
            int awsImageBuilds  = getQuota(sq, CODE_IMAGE_BUILDS,       configuredImageBuilds);

            LOG.infof("Discovered quotas: run=%d/s terminate=%d/s suspend=%d/s " +
                      "resume=%d/s authToken=%d/s imageBuilds=%d",
                    awsRun, awsTerminate, awsSuspend, awsResume, awsAuthToken, awsImageBuilds);

            // Warn if operator is configured above discovered quota
            warnIfExceeds("run-microvm-rate",        configuredRun,         awsRun);
            warnIfExceeds("terminate-microvm-rate",  configuredTerminate,   awsTerminate);
            warnIfExceeds("suspend-microvm-rate",    configuredSuspend,     awsSuspend);
            warnIfExceeds("resume-microvm-rate",     configuredResume,      awsResume);
            warnIfExceeds("auth-token-rate",         configuredAuthToken,   awsAuthToken);
            warnIfExceeds("concurrent-image-builds", configuredImageBuilds, awsImageBuilds);

        } catch (Exception e) {
            LOG.warnf("Quota discovery failed (requires service-quotas:GetServiceQuota): %s — " +
                      "continuing with configured values", e.getMessage());
        }
    }

    private int getQuota(ServiceQuotasClient sq, String code, int fallback) {
        try {
            double value = sq.getServiceQuota(GetServiceQuotaRequest.builder()
                    .serviceCode("lambda")
                    .quotaCode(code)
                    .build())
                    .quota().value();
            return (int) value;
        } catch (Exception e) {
            LOG.debugf("Could not retrieve quota %s: %s — using fallback %d", code, e.getMessage(), fallback);
            return fallback;
        }
    }

    private void warnIfExceeds(String name, int configured, int discovered) {
        if (configured > discovered) {
            LOG.warnf("QUOTA MISMATCH: aws.quota.%s=%d exceeds AWS quota %d — " +
                      "operator may receive 429 errors. Run install script to re-discover quotas.",
                    name, configured, discovered);
        }
    }
}
