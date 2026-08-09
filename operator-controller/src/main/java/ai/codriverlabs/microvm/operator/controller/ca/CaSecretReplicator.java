package ai.codriverlabs.microvm.operator.controller.ca;

import io.fabric8.kubernetes.api.model.Namespace;
import io.fabric8.kubernetes.api.model.Secret;
import io.fabric8.kubernetes.api.model.SecretBuilder;
import io.fabric8.kubernetes.client.KubernetesClient;
import io.fabric8.kubernetes.client.informers.ResourceEventHandler;
import io.quarkus.runtime.StartupEvent;
import jakarta.enterprise.context.ApplicationScoped;
import jakarta.enterprise.event.Observes;
import jakarta.inject.Inject;
import org.eclipse.microprofile.config.inject.ConfigProperty;
import org.jboss.logging.Logger;

import java.nio.file.Files;
import java.nio.file.Path;
import java.util.Base64;
import java.util.Map;
import java.util.concurrent.Executors;
import java.util.concurrent.ScheduledExecutorService;
import java.util.concurrent.TimeUnit;

/**
 * Replicates the operator's CA certificate to a well-known Secret in each managed namespace.
 *
 * This enables auth-agent sidecars to verify TLS when connecting to the operator's
 * token endpoint, without requiring trust-all or cross-namespace Secret reads.
 *
 * The CA is read from the operator's TLS Secret (mounted by cert-manager at /tls/ca.crt).
 * It is replicated to a Secret named {@value #CA_SECRET_NAME} in every namespace labelled
 * with {@value #MANAGED_LABEL}=true.
 *
 * Rotation: this component runs periodically and on namespace events to ensure
 * the CA Secret stays in sync. Kubernetes automatically propagates Secret changes
 * to mounted volumes within ~60-120 seconds.
 */
@ApplicationScoped
public class CaSecretReplicator {

    private static final Logger LOG = Logger.getLogger(CaSecretReplicator.class);

    public static final String CA_SECRET_NAME = "kube-microvm-operator-ca";
    public static final String CA_KEY = "ca.crt";
    public static final String MANAGED_LABEL = "lambda.aws.amazon.com/manage-microvms";

    private static final long SYNC_INTERVAL_SECONDS = 300; // 5 minutes

    @Inject
    KubernetesClient client;

    @ConfigProperty(name = "microvm.ca.cert-path", defaultValue = "/tls/ca.crt")
    String caCertPath;

    private final ScheduledExecutorService scheduler = Executors.newSingleThreadScheduledExecutor(r -> {
        Thread t = new Thread(r, "ca-replicator");
        t.setDaemon(true);
        return t;
    });

    void onStart(@Observes StartupEvent ev) {
        // Initial sync after a short delay (let the operator fully start)
        scheduler.schedule(this::syncAll, 10, TimeUnit.SECONDS);
        // Periodic re-sync to catch rotation and new namespaces
        scheduler.scheduleAtFixedRate(this::syncAll, SYNC_INTERVAL_SECONDS,
                SYNC_INTERVAL_SECONDS, TimeUnit.SECONDS);
        LOG.info("CA Secret replicator started — syncing to managed namespaces every 5 minutes");
    }

    /**
     * Sync CA Secret to all managed namespaces.
     */
    public void syncAll() {
        try {
            String caCert = readCaCert();
            if (caCert == null) {
                LOG.warn("CA cert not available at " + caCertPath + " — skipping sync");
                return;
            }

            var namespaces = client.namespaces().list().getItems();
            int synced = 0;
            for (Namespace ns : namespaces) {
                if (isManagedNamespace(ns)) {
                    ensureCaSecret(ns.getMetadata().getName(), caCert);
                    synced++;
                }
            }
            LOG.debugf("CA Secret synced to %d managed namespaces", synced);
        } catch (Exception e) {
            LOG.errorf(e, "Failed to sync CA Secrets to managed namespaces");
        }
    }

    /**
     * Ensure the CA Secret exists and is up-to-date in a specific namespace.
     */
    public void ensureCaSecret(String namespace, String caCert) {
        try {
            Secret existing = client.secrets()
                    .inNamespace(namespace)
                    .withName(CA_SECRET_NAME)
                    .get();

            String encodedCa = Base64.getEncoder().encodeToString(caCert.getBytes());

            if (existing != null) {
                // Check if CA has changed
                String currentCa = existing.getData() != null ? existing.getData().get(CA_KEY) : null;
                if (encodedCa.equals(currentCa)) {
                    return; // up to date
                }
                // Update
                existing.setData(Map.of(CA_KEY, encodedCa));
                client.secrets().inNamespace(namespace).resource(existing).update();
                LOG.infof("Updated CA Secret %s/%s (CA rotated)", namespace, CA_SECRET_NAME);
            } else {
                // Create
                Secret caSecret = new SecretBuilder()
                        .withNewMetadata()
                            .withName(CA_SECRET_NAME)
                            .withNamespace(namespace)
                            .addToLabels("app.kubernetes.io/managed-by", "kube-microvm-operator")
                            .addToLabels("app.kubernetes.io/component", "ca-distribution")
                        .endMetadata()
                        .withType("Opaque")
                        .withData(Map.of(CA_KEY, encodedCa))
                        .build();
                client.secrets().inNamespace(namespace).resource(caSecret).create();
                LOG.infof("Created CA Secret %s/%s", namespace, CA_SECRET_NAME);
            }
        } catch (Exception e) {
            LOG.warnf("Failed to sync CA Secret to namespace %s: %s", namespace, e.getMessage());
        }
    }

    /**
     * Remove the CA Secret from a namespace (when management label is removed).
     */
    public void removeCaSecret(String namespace) {
        try {
            Secret existing = client.secrets()
                    .inNamespace(namespace)
                    .withName(CA_SECRET_NAME)
                    .get();
            if (existing != null) {
                // Only delete if we own it
                var labels = existing.getMetadata().getLabels();
                if (labels != null && "kube-microvm-operator".equals(labels.get("app.kubernetes.io/managed-by"))) {
                    client.secrets().inNamespace(namespace).withName(CA_SECRET_NAME).delete();
                    LOG.infof("Removed CA Secret %s/%s (namespace no longer managed)", namespace, CA_SECRET_NAME);
                }
            }
        } catch (Exception e) {
            LOG.warnf("Failed to remove CA Secret from namespace %s: %s", namespace, e.getMessage());
        }
    }

    private String readCaCert() {
        try {
            Path path = Path.of(caCertPath);
            if (Files.exists(path) && Files.isReadable(path)) {
                return Files.readString(path).trim();
            }
        } catch (Exception e) {
            LOG.warnf("Error reading CA cert from %s: %s", caCertPath, e.getMessage());
        }
        return null;
    }

    private boolean isManagedNamespace(Namespace ns) {
        var labels = ns.getMetadata().getLabels();
        return labels != null && "true".equals(labels.get(MANAGED_LABEL));
    }
}
