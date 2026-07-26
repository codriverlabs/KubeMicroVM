package ai.codriverlabs.microvm.operator.controller.reconciler;

import software.amazon.awssdk.services.lambdacore.model.GetNetworkConnectorResponse;
import software.amazon.awssdk.services.lambdacore.model.NetworkConnectorState;
import ai.codriverlabs.microvm.operator.controller.aws.MicroVMNetworkClient;
import ai.codriverlabs.microvm.operator.core.model.*;
import io.fabric8.kubernetes.client.KubernetesClient;
import io.javaoperatorsdk.operator.api.reconciler.*;
import jakarta.inject.Inject;
import org.jboss.logging.Logger;
import software.amazon.awssdk.services.lambdacore.model.ResourceNotFoundException;

import java.time.Duration;
import java.util.List;
import java.util.concurrent.TimeUnit;

@ControllerConfiguration(
        finalizerName = "lambda.aws.amazon.com/network-connector-finalizer",
        name = "microvmnetwork-reconciler"
)
public class MicroVMNetworkReconciler implements Reconciler<MicroVMNetwork>, Cleaner<MicroVMNetwork> {

    private static final Logger LOG = Logger.getLogger(MicroVMNetworkReconciler.class);
    private static final Duration POLL_INTERVAL = Duration.ofSeconds(5);
    private static final Duration RESYNC = Duration.ofMinutes(5);
    private static final long AWS_TIMEOUT_S = 30;

    private final MicroVMNetworkClient networkClient;
    private final KubernetesClient k8s;

    @Inject
    public MicroVMNetworkReconciler(MicroVMNetworkClient networkClient, KubernetesClient k8s) {
        this.networkClient = networkClient;
        this.k8s = k8s;
    }

    @Override
    public UpdateControl<MicroVMNetwork> reconcile(MicroVMNetwork resource, Context<MicroVMNetwork> context) {
        var spec = resource.getSpec();
        if (resource.getStatus() == null) resource.setStatus(new MicroVMNetworkStatus());
        var status = resource.getStatus();

        try {
            // CREATE: connector ARN not yet set — try to adopt existing before creating
            if (status.getConnectorArn() == null) {
                // Compute effective AWS connector name:
                // - spec.connectorName (explicit override) — use when importing CLI-created connectors
                // - <namespace>-<CR-name> (default) — preserves backward compatibility
                String defaultName = resource.getMetadata().getNamespace() + "-" + resource.getMetadata().getName();
                String effectiveName = (spec.getConnectorName() != null && !spec.getConnectorName().isBlank())
                        ? spec.getConnectorName()
                        : defaultName;

                // Adopt-if-exists: GetNetworkConnector accepts name, ID, or ARN directly —
                // no ARN construction needed. This handles re-install after cluster wipe,
                // CLI-created connectors (using spec.connectorName), and disaster recovery.
                try {
                    var existing = networkClient.getConnector(effectiveName).get(AWS_TIMEOUT_S, TimeUnit.SECONDS);
                    LOG.infof("Adopting existing network connector %s  arn=%s state=%s",
                            resource.getMetadata().getName(), existing.arn(), existing.stateAsString());
                    status.setConnectorArn(existing.arn());
                    status.setConnectorId(existing.id());
                    status.setConnectorState(existing.stateAsString());
                    status.setObservedGeneration(resource.getMetadata().getGeneration());
                    return UpdateControl.patchStatus(resource).rescheduleAfter(POLL_INTERVAL);
                } catch (Exception e) {
                    if (!isNotFound(e)) throw e;
                    LOG.debugf("Network connector %s not found in AWS, will create", effectiveName);
                }

                var resp = networkClient.createConnector(effectiveName, spec).get(AWS_TIMEOUT_S, TimeUnit.SECONDS);
                status.setConnectorArn(resp.arn());
                status.setConnectorId(resp.id());
                status.setConnectorState("PENDING");
                LOG.infof("Created network connector %s for MicroVMNetwork %s", resp.arn(),
                        resource.getMetadata().getName());
                return UpdateControl.patchStatus(resource).rescheduleAfter(POLL_INTERVAL);
            }

            // POLL or UPDATE
            var current = networkClient.getConnector(status.getConnectorArn())
                    .get(AWS_TIMEOUT_S, TimeUnit.SECONDS);

            // Spec changed — trigger update (best-effort, may fail if MicroVMs are running)
            long generation = resource.getMetadata().getGeneration() != null
                    ? resource.getMetadata().getGeneration() : 0L;
            if (status.getObservedGeneration() != null && status.getObservedGeneration() < generation) {
                networkClient.updateConnector(status.getConnectorArn(), spec).get(AWS_TIMEOUT_S, TimeUnit.SECONDS);
                status.setConnectorState("PENDING");
                LOG.infof("Updated network connector %s", status.getConnectorArn());
            }

            updateStatusFromAws(status, current, generation);

            return switch (current.state()) {
                case PENDING -> UpdateControl.patchStatus(resource).rescheduleAfter(POLL_INTERVAL);
                case ACTIVE -> UpdateControl.patchStatus(resource).rescheduleAfter(RESYNC);
                case FAILED, DELETE_FAILED -> {
                    LOG.warnf("Network connector %s in state %s: %s",
                            status.getConnectorArn(), current.stateAsString(), current.stateReason());
                    yield UpdateControl.patchStatus(resource).rescheduleAfter(RESYNC);
                }
                default -> UpdateControl.patchStatus(resource).rescheduleAfter(POLL_INTERVAL);
            };

        } catch (Exception e) {
            LOG.errorf(e, "Error reconciling MicroVMNetwork %s", resource.getMetadata().getName());
            return UpdateControl.patchStatus(resource).rescheduleAfter(POLL_INTERVAL);
        }
    }

    @Override
    public DeleteControl cleanup(MicroVMNetwork resource, Context<MicroVMNetwork> context) {
        var status = resource.getStatus();
        if (status == null || status.getConnectorArn() == null) {
            return DeleteControl.defaultDelete();
        }

        // Block deletion if any MicroVM still references this network
        String networkName = resource.getMetadata().getName();
        String namespace = resource.getMetadata().getNamespace();
        List<MicroVM> using = k8s.resources(MicroVM.class).inNamespace(namespace).list().getItems()
                .stream()
                .filter(vm -> networkName.equals(vm.getSpec() != null ? vm.getSpec().getNetworkRef() : null))
                .toList();

        if (!using.isEmpty()) {
            LOG.warnf("MicroVMNetwork %s still in use by %d MicroVM(s), blocking deletion", networkName, using.size());
            return DeleteControl.noFinalizerRemoval();
        }

        try {
            networkClient.deleteConnector(status.getConnectorArn()).get(AWS_TIMEOUT_S, TimeUnit.SECONDS);
            LOG.infof("Deleted network connector %s", status.getConnectorArn());
        } catch (Exception e) {
            // ResourceNotFoundException means already gone — safe to proceed
            if (!(e.getCause() instanceof ResourceNotFoundException)) {
                LOG.errorf(e, "Failed to delete network connector %s", status.getConnectorArn());
                return DeleteControl.noFinalizerRemoval();
            }
        }
        return DeleteControl.defaultDelete();
    }

    private void updateStatusFromAws(MicroVMNetworkStatus status, GetNetworkConnectorResponse r, long generation) {
        status.setConnectorState(r.stateAsString());
        status.setStateReason(r.stateReason());
        status.setStateReasonCode(r.stateReasonCodeAsString());
        status.setObservedGeneration(generation);
        status.setConditions(List.of(new Condition(
                "Ready",
                r.state() == NetworkConnectorState.ACTIVE ? "True" : "False",
                r.state() == NetworkConnectorState.ACTIVE ? "ConnectorActive" : r.stateAsString(),
                r.stateReason(),
                java.time.Instant.now()
        )));
    }

    private static boolean isNotFound(Exception e) {
        Throwable cause = e.getCause() != null ? e.getCause() : e;
        return cause instanceof ResourceNotFoundException
                || (cause.getMessage() != null && cause.getMessage().contains("ResourceNotFoundException"));
    }
}
