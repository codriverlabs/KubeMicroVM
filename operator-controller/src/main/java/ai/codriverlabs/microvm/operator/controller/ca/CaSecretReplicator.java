package ai.codriverlabs.microvm.operator.controller.ca;

import io.fabric8.kubernetes.api.model.Namespace;
import io.fabric8.kubernetes.api.model.Secret;
import io.fabric8.kubernetes.api.model.SecretBuilder;
import io.fabric8.kubernetes.client.KubernetesClient;
import io.quarkus.runtime.StartupEvent;
import jakarta.enterprise.context.ApplicationScoped;
import jakarta.enterprise.event.Observes;
import jakarta.inject.Inject;
import org.eclipse.microprofile.config.inject.ConfigProperty;
import org.jboss.logging.Logger;

import java.util.Map;
import java.util.concurrent.Executors;
import java.util.concurrent.ScheduledExecutorService;
import java.util.concurrent.TimeUnit;

/**
 * Replicates the operator's CA certificate Secret to each managed namespace.
 *
 * Reads the full {@code kube-microvm-operator-ca} Secret from the operator namespace
 * (including {@code tls.crt}, {@code tls.key}, {@code ca.crt}) and replicates it as a
 * {@code kubernetes.io/tls} Secret to every namespace labelled
 * {@value #MANAGED_LABEL}=true.
 *
 * Replicating the full keypair (not just ca.crt) is required so that consumers can
 * use it as a cert-manager CA Issuer ({@code spec.ca.secretName}), which needs both
 * {@code tls.crt} and {@code tls.key} to sign certificates.
 *
 * <p>Required RBAC (cluster-scoped, declared on MicroVMReconciler via @AdditionalRBACRules):
 * <ul>
 *   <li>{@code "" / namespaces: get, list, watch} — to discover managed namespaces</li>
 *   <li>{@code "" / secrets: get, list, create, update} — to read source + replicate CA Secret</li>
 * </ul>
 * See docs/design/uat-failure-analysis-rc2.md RC-1.
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
            // Read the full CA Secret from the operator namespace — includes tls.crt, tls.key,
            // and ca.crt. All three keys are required for cert-manager CA Issuers.
            String operatorNamespace = resolveOperatorNamespace();
            Secret sourceSecret = client.secrets()
                    .inNamespace(operatorNamespace)
                    .withName(CA_SECRET_NAME)
                    .get();

            if (sourceSecret == null || sourceSecret.getData() == null || sourceSecret.getData().isEmpty()) {
                LOG.warn("CA Secret " + CA_SECRET_NAME + " not found in namespace " + operatorNamespace
                        + " — skipping sync. It will be created by cert-manager after operator TLS is issued.");
                return;
            }

            var namespaces = client.namespaces().list().getItems();
            int synced = 0;
            for (Namespace ns : namespaces) {
                String nsName = ns.getMetadata().getName();
                if (isManagedNamespace(ns) && !nsName.equals(operatorNamespace)) {
                    ensureCaSecret(nsName, sourceSecret.getData(), sourceSecret.getType());
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
     *
     * @param namespace   target namespace
     * @param data        Secret data map (all keys from the source Secret)
     * @param secretType  Secret type (e.g. kubernetes.io/tls)
     */
    public void ensureCaSecret(String namespace, Map<String, String> data, String secretType) {
        try {
            Secret existing = client.secrets()
                    .inNamespace(namespace)
                    .withName(CA_SECRET_NAME)
                    .get();

            if (existing != null) {
                // Check if data has changed (compare ca.crt as proxy for full content)
                String currentCa = existing.getData() != null ? existing.getData().get(CA_KEY) : null;
                String newCa = data.get(CA_KEY);
                if (newCa != null && newCa.equals(currentCa)) {
                    return; // up to date
                }
                existing.setData(data);
                client.secrets().inNamespace(namespace).resource(existing).update();
                LOG.infof("Updated CA Secret %s/%s", namespace, CA_SECRET_NAME);
            } else {
                Secret caSecret = new SecretBuilder()
                        .withNewMetadata()
                            .withName(CA_SECRET_NAME)
                            .withNamespace(namespace)
                            .addToLabels("app.kubernetes.io/managed-by", "kube-microvm-operator")
                            .addToLabels("app.kubernetes.io/component", "ca-distribution")
                        .endMetadata()
                        .withType(secretType != null ? secretType : "kubernetes.io/tls")
                        .withData(data)
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

    /**
     * Resolve the operator's own namespace from the KUBERNETES_NAMESPACE env var
     * (injected by Quarkus/Kubernetes via fieldRef metadata.namespace).
     * Falls back to "kube-microvm" as the default install namespace.
     */
    private String resolveOperatorNamespace() {
        String ns = System.getenv("KUBERNETES_NAMESPACE");
        return (ns != null && !ns.isBlank()) ? ns : "kube-microvm";
    }

    private boolean isManagedNamespace(Namespace ns) {
        var labels = ns.getMetadata().getLabels();
        return labels != null && "true".equals(labels.get(MANAGED_LABEL));
    }
}
