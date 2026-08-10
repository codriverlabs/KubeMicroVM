package ai.codriverlabs.microvm.operator.controller.reconciler;

import ai.codriverlabs.microvm.operator.controller.aws.*;
import ai.codriverlabs.microvm.operator.controller.metrics.OperatorMetrics;
import ai.codriverlabs.microvm.operator.controller.quota.QuotaGuard;
import ai.codriverlabs.microvm.operator.spi.image.ImageRefResolver;
import ai.codriverlabs.microvm.operator.spi.image.ImageResolution;
import ai.codriverlabs.microvm.operator.core.enums.DesiredState;
import ai.codriverlabs.microvm.operator.core.enums.MicroVMState;
import ai.codriverlabs.microvm.operator.core.model.Condition;
import ai.codriverlabs.microvm.operator.core.model.MicroVM;
import ai.codriverlabs.microvm.operator.core.model.MicroVMNetwork;
import ai.codriverlabs.microvm.operator.core.model.MicroVMSpec;
import ai.codriverlabs.microvm.operator.core.model.MicroVMStatus;
import ai.codriverlabs.microvm.operator.core.state.MicroVMStateMachine;
import ai.codriverlabs.microvm.operator.core.state.StateTransitionResult;
import io.javaoperatorsdk.operator.api.reconciler.*;
import io.javaoperatorsdk.operator.processing.retry.GenericRetry;
import io.fabric8.kubernetes.api.model.Event;
import io.fabric8.kubernetes.api.model.EventBuilder;
import io.fabric8.kubernetes.api.model.ObjectReferenceBuilder;
import io.fabric8.kubernetes.client.KubernetesClient;
import jakarta.inject.Inject;
import org.jboss.logging.Logger;

import java.time.Duration;
import java.time.Instant;
import java.util.List;
import java.util.Map;
import java.util.concurrent.CompletableFuture;
import java.util.concurrent.TimeUnit;

@ControllerConfiguration(
    finalizerName = "lambda.aws.amazon.com/microvm-finalizer",
    retry = GenericRetry.class
)
@io.quarkiverse.operatorsdk.annotations.AdditionalRBACRules({
    @io.quarkiverse.operatorsdk.annotations.RBACRule(
        apiGroups = "",
        resources = {"events"},
        verbs = {"create", "patch"}
    ),
    @io.quarkiverse.operatorsdk.annotations.RBACRule(
        apiGroups = "lambda.aws.amazon.com",
        resources = {"microvmtemplates", "microvmnetworks", "microvmimages"},
        verbs = {"get", "list", "watch"}
    )
})
public class MicroVMReconciler implements Reconciler<MicroVM>, Cleaner<MicroVM> {

    private static final Logger LOG = Logger.getLogger(MicroVMReconciler.class);
    private static final Duration RESYNC_PERIOD = Duration.ofSeconds(60);
    private static final int AWS_TIMEOUT_SECONDS = 30;

    private final MicroVMClient microVMClient;
    private final MicroVMStateMachine stateMachine;
    private final DriftDetector driftDetector;
    private final OperatorMetrics metrics;
    private final KubernetesClient kubernetesClient;
    private final QuotaGuard quotaGuard;
    private final ImageRefResolver imageRefResolver;

    @Inject
    public MicroVMReconciler(MicroVMClient microVMClient,
                             MicroVMStateMachine stateMachine,
                             DriftDetector driftDetector,
                             OperatorMetrics metrics,
                             KubernetesClient kubernetesClient,
                             QuotaGuard quotaGuard,
                             ImageRefResolver imageRefResolver) {
        this.microVMClient = microVMClient;
        this.stateMachine = stateMachine;
        this.driftDetector = driftDetector;
        this.metrics = metrics;
        this.kubernetesClient = kubernetesClient;
        this.quotaGuard = quotaGuard;
        this.imageRefResolver = imageRefResolver;
    }

    @Override
    public UpdateControl<MicroVM> reconcile(MicroVM resource, Context<MicroVM> context) {
        String name = resource.getMetadata().getName();
        String namespace = resource.getMetadata().getNamespace();
        LOG.infof("Reconciling MicroVM %s/%s", namespace, name);

        long startTime = System.nanoTime();
        String outcome = "success";

        try {
            ensureStatusInitialized(resource);
            MicroVMStatus status = resource.getStatus();
            MicroVMState currentState = status.getState();

            // If in Pending state, begin creation
            if (currentState == MicroVMState.PENDING) {
                return handlePendingState(resource);
            }

            // If in Failed state with no microVmId, creation was refused.
            // Only retry if the user changed the spec (generation bump).
            if (currentState == MicroVMState.FAILED && status.getMicroVmId() == null) {
                if (isCreationPermanentlyFailed(status) && !specChanged(resource)) {
                    // Stay in Failed — the spec hasn't changed, retrying is pointless
                    LOG.debugf("MicroVM %s/%s remains Failed (creation refused, spec unchanged)", namespace, name);
                    return UpdateControl.<MicroVM>noUpdate().rescheduleAfter(RESYNC_PERIOD);
                }
                // Spec changed (generation bump) — user fixed the issue, retry
                LOG.infof("MicroVM %s/%s spec changed (generation %d), retrying creation",
                        namespace, name, resource.getMetadata().getGeneration());
                return transitionState(resource, MicroVMState.PENDING, "Retrying",
                        "Spec changed, retrying creation");
            }

            // Describe current state from AWS
            DescribeMicroVMResponse awsState = describeFromAws(status.getMicroVmId());
            if (awsState == null) {
                // Resource not found in AWS, recreate
                LOG.warnf("MicroVM %s/%s not found in AWS, transitioning to Creating", namespace, name);
                return transitionState(resource, MicroVMState.PENDING, "ResourceNotFound", "AWS resource not found, recreating");
            }

            // Detect drift between desired and actual state
            MicroVMState actualState = MicroVMState.fromValue(awsState.state());
            DesiredState desired = resource.getSpec().getDesiredState();
            boolean autoResumeEnabled = Boolean.TRUE.equals(resource.getSpec().getAutoResumeEnabled());
            DriftDetector.DriftResult driftResult = driftDetector.detectDrift(desired, actualState, autoResumeEnabled);

            return switch (driftResult) {
                case DriftDetector.DriftResult.NoOp noOp -> {
                    // Aligned - update status, sync tags, schedule re-sync
                    updateStatusFromAws(resource, awsState);
                    syncTags(resource, status.getMicroVmId());
                    yield UpdateControl.patchStatus(resource).rescheduleAfter(RESYNC_PERIOD);
                }
                case DriftDetector.DriftResult.ActionRequired action -> {
                    yield executeDriftAction(resource, action);
                }
                case DriftDetector.DriftResult.Error error -> {
                    outcome = "error";
                    yield handleReconcileError(resource, error.reason());
                }
            };
        } catch (AwsApiException e) {
            outcome = "error";
            return handleAwsException(resource, e);
        } catch (Exception e) {
            outcome = "error";
            LOG.errorf(e, "Unexpected error reconciling MicroVM %s/%s", namespace, name);
            return handleReconcileError(resource, "UnexpectedError: " + e.getMessage());
        } finally {
            long duration = System.nanoTime() - startTime;
            metrics.recordReconciliation(outcome, duration);
        }
    }

    @Override
    public DeleteControl cleanup(MicroVM resource, Context<MicroVM> context) {
        String name = resource.getMetadata().getName();
        String namespace = resource.getMetadata().getNamespace();
        LOG.infof("Cleaning up MicroVM %s/%s", namespace, name);

        MicroVMStatus status = resource.getStatus();
        if (status == null || status.getState() == null) {
            return DeleteControl.defaultDelete();
        }

        MicroVMState currentState = status.getState();

        // If already terminated, allow deletion
        if (currentState == MicroVMState.TERMINATED) {
            return DeleteControl.defaultDelete();
        }

        // Transition to Terminating
        StateTransitionResult result = stateMachine.transition(currentState, MicroVMState.TERMINATING);
        if (result instanceof StateTransitionResult.Valid) {
            status.setState(MicroVMState.TERMINATING);
            status.setLastTransitionTime(Instant.now());
            emitEvent(resource, "Terminating", "MicroVM deletion initiated");
        }

        // Attempt termination (covers both fresh transition and already-Terminating)
        if (status.getState() == MicroVMState.TERMINATING || currentState == MicroVMState.TERMINATING) {
            try {
                String vmId = status.getMicroVmId();
                if (vmId != null) {
                    quotaGuard.terminateMicrovm(() -> microVMClient.terminateMicroVM(vmId))
                        .get(AWS_TIMEOUT_SECONDS, TimeUnit.SECONDS);
                }
                return terminationComplete(resource, status, namespace, name);
            } catch (Exception e) {
                if (isAlreadyTerminatedOrGone(e)) {
                    LOG.infof("MicroVM %s/%s already terminated or not found in AWS, removing finalizer",
                            namespace, name);
                    return terminationComplete(resource, status, namespace, name);
                }
                LOG.warnf(e, "Error destroying MicroVM %s/%s, retrying", namespace, name);
                return DeleteControl.noFinalizerRemoval().rescheduleAfter(Duration.ofSeconds(10));
            }
        }

        return DeleteControl.defaultDelete();
    }

    private DeleteControl terminationComplete(MicroVM resource, MicroVMStatus status,
                                              String namespace, String name) {
        status.setState(MicroVMState.TERMINATED);
        status.setLastTransitionTime(Instant.now());
        metrics.recordStateTransition(MicroVMState.TERMINATING, MicroVMState.TERMINATED);
        emitEvent(resource, "Terminated", "MicroVM successfully destroyed");
        return DeleteControl.defaultDelete();
    }

    /**
     * Checks whether a terminate exception indicates the MicroVM is already terminated
     * or no longer exists — both are the desired end state for cleanup.
     */
    public static boolean isAlreadyTerminatedOrGone(Throwable t) {
        Throwable cause = t;
        // Unwrap ExecutionException / CompletionException from CompletableFuture.get()
        while (cause.getCause() != null && (cause instanceof java.util.concurrent.ExecutionException
                || cause instanceof java.util.concurrent.CompletionException)) {
            cause = cause.getCause();
        }
        String className = cause.getClass().getSimpleName();
        return className.contains("ResourceNotFoundException")
                || className.contains("ConflictException")
                || className.contains("ResourceConflictException")
                || (cause instanceof AwsApiException ae && ae.isNotFound());
    }

    private void ensureStatusInitialized(MicroVM resource) {
        if (resource.getStatus() == null) {
            MicroVMStatus status = new MicroVMStatus();
            status.setState(MicroVMState.PENDING);
            status.setLastTransitionTime(Instant.now());
            resource.setStatus(status);
        }
    }

    private UpdateControl<MicroVM> handlePendingState(MicroVM resource) {
        MicroVMSpec spec = resource.getSpec();
        String namespace = resource.getMetadata().getNamespace();
        String name = resource.getMetadata().getName();

        // --- Import path: adopt an existing VM by its microVmId ---
        if (spec.getImportMicroVmId() != null && !spec.getImportMicroVmId().isBlank()) {
            String importId = spec.getImportMicroVmId().trim();
            LOG.infof("Importing MicroVM %s/%s using importMicroVmId=%s", namespace, name, importId);
            try {
                DescribeMicroVMResponse existing = quotaGuard.getMicrovm(
                        () -> microVMClient.getMicroVM(importId))
                    .get(AWS_TIMEOUT_SECONDS, TimeUnit.SECONDS);
                if (existing == null) {
                    return transitionState(resource, MicroVMState.FAILED, "ImportNotFound",
                            "importMicroVmId '" + importId + "' not found in AWS — " +
                            "check the ID or remove the field to create a new VM");
                }
                MicroVMStatus status = resource.getStatus();
                status.setMicroVmId(existing.microvmId());
                status.setEndpointUrl(existing.endpoint());
                MicroVMState importedState = MicroVMState.fromValue(existing.state());
                LOG.infof("Imported MicroVM %s/%s  microVmId=%s  state=%s",
                        namespace, name, importId, importedState);
                return transitionState(resource, importedState, "Imported",
                        "MicroVM imported, microVmId=" + importId);
            } catch (Exception e) {
                Throwable cause = e.getCause() != null ? e.getCause() : e;
                if (cause.getMessage() != null &&
                        (cause.getMessage().contains("ResourceNotFoundException") ||
                         cause.getMessage().contains("not found"))) {
                    return transitionState(resource, MicroVMState.FAILED, "ImportNotFound",
                            "importMicroVmId '" + importId + "' not found in AWS — " +
                            "check the ID or remove the field to create a new VM");
                }
                throw e instanceof RuntimeException re ? re : new RuntimeException(e);
            }
        }

        // --- Normal create path ---

        // --- Image reference resolution ---
        String imageIdentifier;
        String imageVersion;
        var resolution = imageRefResolver.resolve(spec.getImageRef(), spec.getImageVersion(), namespace);
        if (!resolution.isSuccess()) {
            return transitionState(resource, MicroVMState.FAILED, resolution.reason(), resolution.error());
        }
        imageIdentifier = resolution.imageArn();
        imageVersion = resolution.imageVersion();
        resource.getStatus().setResolvedImageArn(imageIdentifier);
        resource.getStatus().setResolvedImageVersion(imageVersion);

        // --- Network reference resolution ---
        List<String> egressConnectors = spec.getEgressNetworkConnectors() != null
                ? new java.util.ArrayList<>(spec.getEgressNetworkConnectors()) : new java.util.ArrayList<>();
        if (spec.getNetworkRef() != null && !spec.getNetworkRef().isBlank()) {
            var netResolution = resolveNetworkRef(spec.getNetworkRef(), namespace);
            if (netResolution.error != null) {
                return transitionState(resource, MicroVMState.FAILED, netResolution.reason, netResolution.error);
            }
            egressConnectors.add(netResolution.connectorArn);
            LOG.infof("Resolved networkRef '%s' → %s", spec.getNetworkRef(), netResolution.connectorArn);
        }

        RunMicroVMRequest request = new RunMicroVMRequest(
            imageIdentifier,
            imageVersion,
            spec.getExecutionRoleArn(),
            spec.getRunHookPayload(),
            spec.getIngressNetworkConnectors(),
            egressConnectors,
            spec.getMaxIdleDurationSeconds(),
            spec.getSuspendedDurationSeconds(),
            spec.getAutoResumeEnabled(),
            spec.getMaximumDurationSeconds(),
            spec.getTags(),
            spec.getRegion()
        );

        try {
            RunMicroVMResponse response = quotaGuard.runMicrovm(
                    () -> microVMClient.runMicroVM(request))
                .get(AWS_TIMEOUT_SECONDS, TimeUnit.SECONDS);

            resource.getStatus().setMicroVmId(response.microvmId());
            resource.getStatus().setEndpointUrl(response.endpoint());
            return transitionState(resource, MicroVMState.RUNNING, "Running", "MicroVM running, id=" + response.microvmId());
        } catch (Exception e) {
            return handleCreationError(resource, e);
        }
    }

    /**
     * Resolves a MicroVMNetwork CR name to its connector ARN.
     */
    private NetworkResolution resolveNetworkRef(String networkRef, String namespace) {
        MicroVMNetwork network = kubernetesClient.resources(MicroVMNetwork.class)
                .inNamespace(namespace)
                .withName(networkRef)
                .get();

        if (network == null) {
            return NetworkResolution.error("NetworkNotFound",
                    "MicroVMNetwork '" + networkRef + "' not found in namespace '" + namespace + "'");
        }

        var status = network.getStatus();
        if (status == null || status.getConnectorArn() == null) {
            return NetworkResolution.error("NetworkNotReady",
                    "MicroVMNetwork '" + networkRef + "' has not been created yet (no connectorArn)");
        }

        if (!"ACTIVE".equals(status.getConnectorState())) {
            return NetworkResolution.error("NetworkNotReady",
                    "MicroVMNetwork '" + networkRef + "' connector is in state '" + status.getConnectorState() + "', expected ACTIVE");
        }

        return NetworkResolution.success(status.getConnectorArn());
    }

    private record NetworkResolution(String connectorArn, String reason, String error) {
        static NetworkResolution success(String arn) { return new NetworkResolution(arn, null, null); }
        static NetworkResolution error(String reason, String message) { return new NetworkResolution(null, reason, message); }
    }

    private UpdateControl<MicroVM> handleCreatingState(MicroVM resource) {
        String microvmId = resource.getStatus().getMicroVmId();
        if (microvmId == null) {
            return handlePendingState(resource);
        }

        try {
            DescribeMicroVMResponse response = microVMClient.getMicroVM(microvmId)
                .get(AWS_TIMEOUT_SECONDS, TimeUnit.SECONDS);

            MicroVMState awsState = MicroVMState.fromValue(response.state());
            if (awsState == MicroVMState.RUNNING) {
                resource.getStatus().setEndpointUrl(response.endpoint());
                return transitionState(resource, MicroVMState.RUNNING, "Running", "MicroVM is running");
            }

            // Still pending, requeue
            return UpdateControl.patchStatus(resource).rescheduleAfter(Duration.ofSeconds(5));
        } catch (AwsApiException e) {
            if (e.isNotFound()) {
                return UpdateControl.patchStatus(resource).rescheduleAfter(Duration.ofSeconds(5));
            }
            throw e;
        } catch (Exception e) {
            return UpdateControl.patchStatus(resource).rescheduleAfter(Duration.ofSeconds(10));
        }
    }

    private UpdateControl<MicroVM> executeDriftAction(MicroVM resource, DriftDetector.DriftResult.ActionRequired action) {
        String microvmId = resource.getStatus().getMicroVmId();
        try {
            CompletableFuture<Void> future = switch (action.action()) {
                case RECREATE -> CompletableFuture.completedFuture(null);
                case SUSPEND   -> quotaGuard.suspendMicrovm(() -> microVMClient.suspendMicroVM(microvmId));
                case RESUME    -> quotaGuard.resumeMicrovm(() -> microVMClient.resumeMicroVM(microvmId));
                case TERMINATE -> quotaGuard.terminateMicrovm(() -> microVMClient.terminateMicroVM(microvmId));
                case NO_OP     -> CompletableFuture.completedFuture(null);
            };

            if (action.action() == DriftDetector.DriftAction.RECREATE) {
                return transitionState(resource, MicroVMState.PENDING, "Recreating", "Drift correction: recreating MicroVM");
            }

            future.get(AWS_TIMEOUT_SECONDS, TimeUnit.SECONDS);
            return transitionState(resource, action.targetState(), action.action().name(),
                "Drift correction: " + action.action().name().toLowerCase());
        } catch (Exception e) {
            return handleReconcileError(resource, "Failed to execute drift action " + action.action() + ": " + e.getMessage());
        }
    }

    private UpdateControl<MicroVM> transitionState(MicroVM resource, MicroVMState newState, String reason, String message) {
        MicroVMStatus status = resource.getStatus();
        MicroVMState oldState = status.getState();

        status.setState(newState);
        status.setLastTransitionTime(Instant.now());
        status.setObservedGeneration(resource.getMetadata().getGeneration());

        setReadyCondition(status, newState, reason, message);
        metrics.recordStateTransition(oldState, newState);
        emitEvent(resource, reason, message);

        return UpdateControl.patchStatus(resource).rescheduleAfter(RESYNC_PERIOD);
    }

    private UpdateControl<MicroVM> handleAwsException(MicroVM resource, AwsApiException e) {
        if (e.isRetryable()) {
            LOG.warnf("Retryable AWS error for %s/%s: %s", resource.getMetadata().getNamespace(),
                resource.getMetadata().getName(), e.getMessage());
            return UpdateControl.patchStatus(resource).rescheduleAfter(Duration.ofSeconds(10));
        }

        if (e.isNotFound()) {
            return transitionState(resource, MicroVMState.PENDING, "ResourceNotFound", "AWS resource not found, recreating");
        }

        if (e.isAuthFailure()) {
            setReadyCondition(resource.getStatus(), resource.getStatus().getState(), "AWSAuthError", e.getMessage());
            emitEvent(resource, "AWSAuthError", "AWS authentication failure: " + e.getMessage());
            return UpdateControl.patchStatus(resource).rescheduleAfter(Duration.ofSeconds(30));
        }

        // Non-retryable error
        return transitionState(resource, MicroVMState.FAILED, "AWSError", e.getMessage());
    }

    private UpdateControl<MicroVM> handleCreationError(MicroVM resource, Exception e) {
        String namespace = resource.getMetadata().getNamespace();
        String name = resource.getMetadata().getName();
        Throwable cause = e.getCause() != null ? e.getCause() : e;
        String errorMessage = cause.getMessage() != null ? cause.getMessage() : e.getMessage();

        if (cause instanceof AwsApiException awsEx && awsEx.isRetryable()) {
            LOG.warnf("Retryable creation error for %s/%s: %s", namespace, name, errorMessage);
            return UpdateControl.patchStatus(resource).rescheduleAfter(Duration.ofSeconds(10));
        }

        // Non-retryable (400, validation error, permanent refusal)
        LOG.errorf("MicroVM %s/%s creation refused by AWS (non-retryable): %s", namespace, name, errorMessage);
        return transitionState(resource, MicroVMState.FAILED, "CreationFailed",
                "Failed to create MicroVM: " + errorMessage);
    }

    private UpdateControl<MicroVM> handleReconcileError(MicroVM resource, String reason) {
        setReadyCondition(resource.getStatus(), resource.getStatus().getState(), "Error", reason);
        return UpdateControl.patchStatus(resource).rescheduleAfter(Duration.ofSeconds(30));
    }

    private void setReadyCondition(MicroVMStatus status, MicroVMState state, String reason, String message) {
        String conditionStatus = (state == MicroVMState.RUNNING) ? "True" : "False";
        Condition ready = new Condition("Ready", conditionStatus, reason, message, Instant.now());

        status.getConditions().removeIf(c -> "Ready".equals(c.getType()));
        status.getConditions().add(ready);
    }

    /**
     * Returns true if the CR is in a permanent creation failure state.
     * A permanent failure means the AWS API refused the create with a non-retryable error
     * (e.g. 400 ValidationException). Retrying with the same spec will never succeed.
     *
     * Transient failures (NetworkNotReady, retryable AWS errors) are NOT included —
     * the reconciler should retry those on the next cycle.
     */
    private boolean isCreationPermanentlyFailed(MicroVMStatus status) {
        return status.getConditions().stream()
                .filter(c -> "Ready".equals(c.getType()))
                .findFirst()
                .map(c -> "CreationFailed".equals(c.getReason())
                        || "ImageNotFound".equals(c.getReason())
                        || "NetworkNotFound".equals(c.getReason())
                        || "ImportNotFound".equals(c.getReason()))
                .orElse(false);
    }

    /**
     * Returns true if the user has modified the spec since the last reconcile.
     * Detected by comparing metadata.generation with status.observedGeneration.
     */
    private boolean specChanged(MicroVM resource) {
        Long observed = resource.getStatus().getObservedGeneration();
        Long current = resource.getMetadata().getGeneration();
        return observed == null || !observed.equals(current);
    }

    private void updateStatusFromAws(MicroVM resource, DescribeMicroVMResponse awsState) {
        MicroVMStatus status = resource.getStatus();
        MicroVMState newState = MicroVMState.fromValue(awsState.state());

        if (status.getState() != newState) {
            metrics.recordStateTransition(status.getState(), newState);
            status.setState(newState);
            status.setLastTransitionTime(Instant.now());
        }

        status.setMicroVmId(awsState.microvmId());
        status.setEndpointUrl(awsState.endpoint());
        status.setObservedGeneration(resource.getMetadata().getGeneration());
    }

    private DescribeMicroVMResponse describeFromAws(String vmId) {
        if (vmId == null) return null;
        try {
            return quotaGuard.getMicrovm(() -> microVMClient.getMicroVM(vmId))
                    .get(AWS_TIMEOUT_SECONDS, TimeUnit.SECONDS);
        } catch (Exception e) {
            if (e.getCause() instanceof AwsApiException awsEx && awsEx.isNotFound()) {
                return null;
            }
            if (e.getCause() instanceof AwsApiException awsEx) {
                throw awsEx;
            }
            throw new RuntimeException("Failed to describe MicroVM: " + e.getMessage(), e);
        }
    }

    private void syncTags(MicroVM resource, String microvmId) {
        // Tag sync disabled: Lambda MicroVMs TagResource API does not yet support
        // microvm resources (only functions, layers, network-connectors, etc.)
        // TODO: re-enable once TagResource supports microvm ARN format
        if (microvmId == null) return;
    }

    private void emitEvent(MicroVM resource, String reason, String message) {
        try {
            Event event = new EventBuilder()
                .withNewMetadata()
                    .withGenerateName(resource.getMetadata().getName() + "-")
                    .withNamespace(resource.getMetadata().getNamespace())
                .endMetadata()
                .withReason(reason)
                .withMessage(message)
                .withType(isErrorReason(reason) ? "Warning" : "Normal")
                .withInvolvedObject(new ObjectReferenceBuilder()
                    .withApiVersion(resource.getApiVersion())
                    .withKind(resource.getKind())
                    .withName(resource.getMetadata().getName())
                    .withNamespace(resource.getMetadata().getNamespace())
                    .withUid(resource.getMetadata().getUid())
                    .build())
                .withNewSource()
                    .withComponent("microvm-controller")
                .endSource()
                .build();

            kubernetesClient.v1().events().inNamespace(resource.getMetadata().getNamespace()).resource(event).create();
        } catch (Exception e) {
            LOG.warnf("Failed to emit event for %s/%s: %s",
                resource.getMetadata().getNamespace(), resource.getMetadata().getName(), e.getMessage());
        }
    }

    private boolean isErrorReason(String reason) {
        return reason != null && (reason.contains("Error") || reason.contains("Failed") || reason.contains("NotFound"));
    }
}
