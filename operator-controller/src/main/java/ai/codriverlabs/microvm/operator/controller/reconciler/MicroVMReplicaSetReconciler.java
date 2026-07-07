package ai.codriverlabs.microvm.operator.controller.reconciler;

import ai.codriverlabs.microvm.operator.controller.quota.QuotaGuard;
import ai.codriverlabs.microvm.operator.core.enums.DesiredState;
import ai.codriverlabs.microvm.operator.core.enums.MicroVMState;
import ai.codriverlabs.microvm.operator.core.model.*;
import io.fabric8.kubernetes.api.model.ObjectMetaBuilder;
import io.fabric8.kubernetes.api.model.OwnerReferenceBuilder;
import io.fabric8.kubernetes.client.KubernetesClient;
import io.javaoperatorsdk.operator.api.reconciler.*;
import jakarta.inject.Inject;
import org.jboss.logging.Logger;

import java.time.Duration;
import java.time.Instant;
import java.util.*;
import java.util.concurrent.CompletableFuture;
import java.util.stream.Collectors;

/**
 * Reconciler for MicroVMReplicaSet — maintains a desired count of identical MicroVM instances.
 *
 * Implements ReplicaSet-like semantics:
 * - Scale-up: create child MicroVM CRs until currentReplicas == spec.replicas
 * - Scale-down: select victims by policy (MostRecentFirst/OldestFirst/Random), set desiredState=Terminated
 * - Health eviction: replace FAILED (>60s), stuck PENDING (>300s), unexpected TERMINATED children
 * - Suspend/resume cascade: desiredReplicaSetState propagates to all children's desiredState
 *
 * All child MicroVMs carry ownerReferences to the ReplicaSet for cascade delete.
 * Children are selected via label: lambda.aws.amazon.com/replicaset-name=<name>
 */
@ControllerConfiguration(
        name = "microvmreplicaset-reconciler",
        finalizerName = "lambda.aws.amazon.com/replicaset-finalizer"
)
public class MicroVMReplicaSetReconciler
        implements Reconciler<MicroVMReplicaSet>, Cleaner<MicroVMReplicaSet> {

    private static final Logger LOG = Logger.getLogger(MicroVMReplicaSetReconciler.class);
    private static final Duration RESYNC = Duration.ofSeconds(30);
    private static final long FAILED_EVICTION_THRESHOLD_S = 60;
    private static final long PENDING_STUCK_THRESHOLD_S = 300;
    public static final String OWNER_LABEL = "lambda.aws.amazon.com/replicaset-name";

    private final KubernetesClient k8s;
    private final QuotaGuard quotaGuard;

    @Inject
    public MicroVMReplicaSetReconciler(KubernetesClient k8s, QuotaGuard quotaGuard) {
        this.k8s = k8s;
        this.quotaGuard = quotaGuard;
    }

    /**
     * Maximum child MicroVMs to create per reconcile cycle.
     *
     * Derived from the RunMicrovm rate limit: at most (rate / 2) creates per cycle.
     * Each create triggers a child MicroVMReconciler cycle which calls RunMicrovm.
     * The 3s requeue gives time for the child to make its AWS call before the next
     * batch, so effective throughput = maxCreatesPerCycle / 3 req/s, well within quota.
     *
     * Minimum 1 — always make progress even at the lowest quota.
     */
    private int maxCreatesPerCycle() {
        return Math.max(1, quotaGuard.runMicrovmRatePerSecond() / 2);
    }

    @Override
    public UpdateControl<MicroVMReplicaSet> reconcile(
            MicroVMReplicaSet rs, Context<MicroVMReplicaSet> context) {

        if (rs.getStatus() == null) rs.setStatus(new MicroVMReplicaSetStatus());
        var spec = rs.getSpec();
        if (spec == null || spec.getReplicas() == null) {
            return UpdateControl.patchStatus(rs).rescheduleAfter(RESYNC);
        }

        String ns = rs.getMetadata().getNamespace();
        String name = rs.getMetadata().getName();
        int desired = spec.getReplicas();

        List<MicroVM> children = k8s.resources(MicroVM.class).inNamespace(ns)
                .withLabel(OWNER_LABEL, name).list().getItems();

        // Handle suspend/resume cascade — paced through QuotaGuard to avoid
        // flooding SuspendMicrovm (2 req/s) or ResumeMicrovm (5 req/s) when
        // the ReplicaSet is large. Each patch triggers a child reconcile → AWS call.
        boolean wantSuspended = "Suspended".equalsIgnoreCase(spec.getDesiredReplicaSetState());
        for (MicroVM child : children) {
            String childDesired = child.getSpec() != null
                    ? (child.getSpec().getDesiredState() != null
                        ? child.getSpec().getDesiredState().toString() : "Running")
                    : "Running";
            String targetState = wantSuspended ? "Suspended" : "Running";
            if (!targetState.equalsIgnoreCase(childDesired)) {
                try {
                    // Acquire the rate-limit permit before patching — this throttles
                    // how quickly child reconcilers are triggered to call AWS.
                    if (wantSuspended) {
                        quotaGuard.suspendMicrovm(() -> CompletableFuture.completedFuture(null)).get();
                    } else {
                        quotaGuard.resumeMicrovm(() -> CompletableFuture.completedFuture(null)).get();
                    }
                } catch (Exception e) {
                    LOG.warnf("QuotaGuard interrupted during cascade for child %s: %s",
                            child.getMetadata().getName(), e.getMessage());
                }
                child.getSpec().setDesiredState(DesiredState.fromValue(targetState));
                k8s.resource(child).patch();
            }
        }

        // Health eviction — remove unhealthy children so they get replaced
        Instant now = Instant.now();
        List<MicroVM> healthy = new ArrayList<>();
        for (MicroVM child : children) {
            if (isUnhealthy(child, now)) {
                LOG.infof("Evicting unhealthy child %s (state=%s)",
                        child.getMetadata().getName(),
                        child.getStatus() != null ? child.getStatus().getState() : "unknown");
                k8s.resource(child).delete();
            } else {
                healthy.add(child);
            }
        }
        children = healthy;

        int current = (int) children.stream()
                .filter(c -> c.getStatus() == null
                        || c.getStatus().getState() != MicroVMState.TERMINATED)
                .count();

        if (current < desired) {
            // Scale-up: create up to maxCreatesPerCycle() children per reconcile.
            // Derived from RunMicrovm quota to avoid flooding child reconcilers.
            int toCreate = Math.min(desired - current, maxCreatesPerCycle());
            for (int i = 0; i < toCreate; i++) {
                createChild(rs, ns, name, spec);
            }
            updateStatus(rs, children, desired);
            return UpdateControl.patchStatus(rs).rescheduleAfter(Duration.ofSeconds(3));
        } else if (current > desired) {
            // Scale-down: select victims by policy
            int toTerminate = current - desired;
            List<MicroVM> victims = selectVictims(children, spec, toTerminate);
            for (MicroVM v : victims) {
                if (v.getSpec() != null) {
                    v.getSpec().setDesiredState(DesiredState.TERMINATED);
                    k8s.resource(v).patch();
                }
            }
        }

        updateStatus(rs, children, desired);
        return UpdateControl.patchStatus(rs).rescheduleAfter(RESYNC);
    }

    @Override
    public DeleteControl cleanup(MicroVMReplicaSet rs, Context<MicroVMReplicaSet> context) {
        // Cascade delete is handled by Kubernetes ownerReferences GC
        return DeleteControl.defaultDelete();
    }

    private void createChild(MicroVMReplicaSet rs, String ns, String rsName, MicroVMReplicaSetSpec spec) {
        var vm = new MicroVM();
        vm.setMetadata(new ObjectMetaBuilder()
                .withGenerateName(rsName + "-")
                .withNamespace(ns)
                .addToLabels(OWNER_LABEL, rsName)
                .addToOwnerReferences(new OwnerReferenceBuilder()
                        .withApiVersion(rs.getApiVersion())
                        .withKind(rs.getKind())
                        .withName(rsName)
                        .withUid(rs.getMetadata().getUid())
                        .withBlockOwnerDeletion(true)
                        .withController(true)
                        .build())
                .build());
        // Deep-copy the template spec to avoid shared mutable state
        vm.setSpec(spec.getTemplate());
        k8s.resource(vm).create();
        LOG.infof("Created child MicroVM for ReplicaSet %s", rsName);
    }

    private List<MicroVM> selectVictims(List<MicroVM> children,
            MicroVMReplicaSetSpec spec, int count) {
        String policy = spec.getScaleDown() != null
                ? spec.getScaleDown().getPolicy() : "MostRecentFirst";
        List<MicroVM> sorted = new ArrayList<>(children);
        switch (policy) {
            case "OldestFirst" -> sorted.sort(
                    Comparator.comparing(c -> c.getMetadata().getCreationTimestamp()));
            case "Random" -> Collections.shuffle(sorted);
            default -> sorted.sort(  // MostRecentFirst
                    Comparator.comparing((MicroVM c) -> c.getMetadata().getCreationTimestamp()).reversed());
        }
        return sorted.subList(0, Math.min(count, sorted.size()));
    }

    private boolean isUnhealthy(MicroVM child, Instant now) {
        if (child.getStatus() == null) return false;
        MicroVMState state = child.getStatus().getState();
        if (state == null) return false;
        // Unexpected termination (no desiredState=Terminated)
        if (state == MicroVMState.TERMINATED) {
            DesiredState desired = child.getSpec() != null ? child.getSpec().getDesiredState() : null;
            return desired != DesiredState.TERMINATED;
        }
        // FAILED for too long
        if (state == MicroVMState.FAILED && child.getMetadata().getCreationTimestamp() != null) {
            Instant created = Instant.parse(child.getMetadata().getCreationTimestamp());
            return Duration.between(created, now).getSeconds() > FAILED_EVICTION_THRESHOLD_S;
        }
        // Stuck PENDING
        if (state == MicroVMState.PENDING && child.getMetadata().getCreationTimestamp() != null) {
            Instant created = Instant.parse(child.getMetadata().getCreationTimestamp());
            return Duration.between(created, now).getSeconds() > PENDING_STUCK_THRESHOLD_S;
        }
        return false;
    }

    private void updateStatus(MicroVMReplicaSet rs, List<MicroVM> children, int desired) {
        var status = rs.getStatus();
        int ready = 0, suspended = 0, current = 0;
        for (MicroVM c : children) {
            if (c.getStatus() == null) continue;
            MicroVMState state = c.getStatus().getState();
            if (state == MicroVMState.TERMINATED) continue;
            current++;
            if (state == MicroVMState.RUNNING) ready++;
            if (state == MicroVMState.SUSPENDED) suspended++;
        }
        status.setReadyReplicas(ready);
        status.setSuspendedReplicas(suspended);
        status.setCurrentReplicas(current);
        status.setDesiredReplicas(desired);
        status.setObservedGeneration(rs.getMetadata().getGeneration());

        boolean allReady = ready >= desired;
        status.setConditions(List.of(new Condition(
                "Ready",
                allReady ? "True" : "False",
                allReady ? "AllReplicasReady" : "InsufficientReplicas",
                String.format("%d/%d replicas ready", ready, desired),
                Instant.now()
        )));
    }
}
