package ai.codriverlabs.microvm.operator.controller.health;

import io.quarkus.runtime.StartupEvent;
import jakarta.enterprise.context.ApplicationScoped;
import jakarta.enterprise.event.Observes;
import jakarta.inject.Inject;
import org.eclipse.microprofile.config.inject.ConfigProperty;
import org.jboss.logging.Logger;
import software.amazon.awssdk.regions.Region;
import software.amazon.awssdk.services.sts.StsClient;

@ApplicationScoped
public class AwsConnectivityStartup {

    private static final Logger LOG = Logger.getLogger(AwsConnectivityStartup.class);

    @ConfigProperty(name = "aws.region", defaultValue = "us-east-1")
    String region;

    @Inject
    AwsIdentity awsIdentity;

    void onStart(@Observes StartupEvent ev) {
        try (StsClient sts = StsClient.builder().region(Region.of(region)).build()) {
            var identity = sts.getCallerIdentity();
            LOG.infof("AWS connectivity confirmed: account=%s arn=%s",
                    identity.account(), identity.arn());
            awsIdentity.set(identity.account(), region);
            AwsConnectivityHealthCheck.setAwsConnectivityConfirmed(true);
            AwsConnectivityHealthCheck.setInformerCachesSynced(true);
        } catch (Exception e) {
            LOG.warnf("AWS connectivity check failed: %s", e.getMessage());
        }
    }
}
