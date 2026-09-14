package ai.codriverlabs.microvm.operator.controller.reconciler;

import software.amazon.awssdk.services.lambdamicrovms.model.GetMicrovmImageResponse;
import software.amazon.awssdk.services.lambdamicrovms.model.MicrovmImageState;
import software.amazon.awssdk.services.lambdamicrovms.model.MicrovmImageVersionState;
import ai.codriverlabs.microvm.operator.controller.aws.AwsApiException;
import ai.codriverlabs.microvm.operator.controller.aws.MicroVMImageClient;
import ai.codriverlabs.microvm.operator.controller.health.AwsIdentity;
import ai.codriverlabs.microvm.operator.controller.quota.QuotaExceededException;
import ai.codriverlabs.microvm.operator.controller.quota.QuotaGuard;
import ai.codriverlabs.microvm.operator.core.model.MicroVMImage;
import ai.codriverlabs.microvm.operator.core.model.MicroVMImageSpec;
import ai.codriverlabs.microvm.operator.core.model.MicroVMImageStatus;
import io.fabric8.kubernetes.api.model.Event;
import io.fabric8.kubernetes.api.model.EventBuilder;
import io.fabric8.kubernetes.api.model.ObjectReferenceBuilder;
import io.fabric8.kubernetes.client.KubernetesClient;
import io.javaoperatorsdk.operator.api.reconciler.*;
import io.javaoperatorsdk.operator.processing.retry.GenericRetry;
import jakarta.inject.Inject;
import org.jboss.logging.Logger;

import java.time.Duration;
import java.util.concurrent.TimeUnit;

@ControllerConfiguration(
    finalizerName = "lambda.aws.amazon.com/microvmimage-finalizer",
    retry = GenericRetry.class
)
public class MicroVMImageReconciler implements Reconciler<MicroVMImage>, Cleaner<MicroVMImage> {

    private static final Logger LOG = Logger.getLogger(MicroVMImageReconciler.class);
    private static final int TIMEOUT_S = 30;
    private static final Duration POLL_INTERVAL = Duration.ofSeconds(15);
    private static final Duration RESYNC = Duration.ofMinutes(5);

    // Capped exponential backoff for delete-blocked retries: 15s, 30s, 1m, 2m, then
    // capped at 5m. Indexed by retry count (see delete-retry-count annotation below).
    private static final Duration[] DELETE_RETRY_BACKOFF = {
        Duration.ofSeconds(15), Duration.ofSeconds(30), Duration.ofMinutes(1), Duration.ofMinutes(2)
    };
    private static final Duration DELETE_RETRY_BACKOFF_CAP = Duration.ofMinutes(5);
    private static final String DELETE_RETRY_COUNT_ANNOTATION = "lambda.aws.amazon.com/delete-retry-count";

    private final MicroVMImageClient imageClient;
    private final AwsIdentity awsIdentity;
    private final QuotaGuard quotaGuard;
    private final KubernetesClient kubernetesClient;

    @Inject
    public MicroVMImageReconciler(MicroVMImageClient imageClient, AwsIdentity awsIdentity,
                                  QuotaGuard quotaGuard, KubernetesClient kubernetesClient) {
        this.imageClient = imageClient;
        this.awsIdentity = awsIdentity;
        this.quotaGuard = quotaGuard;
        this.kubernetesClient = kubernetesClient;
    }

    @Override
    public UpdateControl<MicroVMImage> reconcile(MicroVMImage resource, Context<MicroVMImage> ctx) {
        String name = resource.getMetadata().getName();
        String namespace = resource.getMetadata().getNamespace();
        MicroVMImageSpec spec = resource.getSpec();
        MicroVMImageStatus status = ensureStatus(resource);

        LOG.infof("Reconciling MicroVMImage %s/%s  imageArn=%s", namespace, name, status.getImageArn());

        try {
            // --- CREATE (or ADOPT if already exists in AWS) ---
            if (status.getImageArn() == null) {
                // Try to discover an existing image by the same name before attempting creation.
                // This handles re-install after cluster wipe and images created outside Kubernetes.
                String expectedArn = awsIdentity.constructImageArn(name);
                if (expectedArn != null) {
                    try {
                        var existing = imageClient.getImage(expectedArn).get(TIMEOUT_S, TimeUnit.SECONDS);
                        LOG.infof("Adopting existing image %s  arn=%s state=%s",
                                name, existing.imageArn(), existing.stateAsString());
                        status.setImageArn(existing.imageArn());
                        status.setImageState(existing.stateAsString());
                        if (existing.latestActiveImageVersion() != null) {
                            status.setActiveVersion(existing.latestActiveImageVersion());
                        }
                        updateMemoryStatus(status, spec.getMemorySizeMiB());
                        status.setObservedGeneration(resource.getMetadata().getGeneration());
                        return UpdateControl.patchStatus(resource).rescheduleAfter(POLL_INTERVAL);
                    } catch (Exception e) {
                        // Not found or other error — fall through to create
                        if (!isNotFound(e)) {
                            throw e;
                        }
                        LOG.debugf("Image %s not found in AWS, will create", name);
                    }
                }

                String s3Uri = "s3://" + spec.getSource().getS3Bucket() + "/" + spec.getSource().getS3Key();
                LOG.infof("Creating image %s from %s", name, s3Uri);
                quotaGuard.acquireImageBuildPermit(name);
                try {
                    var response = imageClient.createImage(
                            name, s3Uri, spec.getBaseImageArn(), spec.getBuildRoleArn(),
                            spec.getMemorySizeMiB())
                            .get(TIMEOUT_S, TimeUnit.SECONDS);

                    status.setImageArn(response.imageArn());
                    status.setImageState(response.stateAsString());
                    status.setLatestVersion(response.imageVersion());
                    status.setLatestVersionState(MicrovmImageVersionState.PENDING.toString());
                    status.setObservedGeneration(resource.getMetadata().getGeneration());
                    updateMemoryStatus(status, spec.getMemorySizeMiB());
                    LOG.infof("Image %s created: arn=%s state=%s memory=%s",
                            name, response.imageArn(), response.stateAsString(),
                            spec.getMemorySizeMiB() != null ? spec.getMemorySizeMiB() + " MiB" : "default");
                    return UpdateControl.patchStatus(resource).rescheduleAfter(POLL_INTERVAL);
                } catch (Exception e) {
                    // Release permit immediately if createImage fails — don't hold it
                    // until the next reconcile cycle or lease expiry
                    quotaGuard.releaseImageBuildPermit(name);
                    throw e;
                }
            }

            // --- UPDATE (spec changed) ---
            long gen = resource.getMetadata().getGeneration() != null ? resource.getMetadata().getGeneration() : 0L;
            long observed = status.getObservedGeneration() != null ? status.getObservedGeneration() : 0L;
            if (gen > observed && isBuildSettled(status.getImageState()) && !isVersionBuilding(status.getLatestVersionState())) {
                String s3Uri = "s3://" + spec.getSource().getS3Bucket() + "/" + spec.getSource().getS3Key();
                LOG.infof("Updating image %s (generation %d -> %d)", name, observed, gen);
                var response = imageClient.updateImage(
                        status.getImageArn(), s3Uri, spec.getBaseImageArn(), spec.getBuildRoleArn())
                        .get(TIMEOUT_S, TimeUnit.SECONDS);
                status.setImageState(response.stateAsString());
                status.setLatestVersion(response.imageVersion());
                status.setLatestVersionState(MicrovmImageVersionState.PENDING.toString());
                status.setObservedGeneration(gen);
                return UpdateControl.patchStatus(resource).rescheduleAfter(POLL_INTERVAL);
            }

            // --- POLL --- while image or version build is in progress
            if (!isBuildSettled(status.getImageState()) || isVersionBuilding(status.getLatestVersionState())) {
                // Poll image state
                GetMicrovmImageResponse imageResp;
                try {
                    imageResp = imageClient.getImage(status.getImageArn()).get(TIMEOUT_S, TimeUnit.SECONDS);
                } catch (Exception e) {
                    if (isNotFound(e)) {
                        // Image deleted in AWS while we were tracking it — reset and recreate
                        LOG.warnf("Image %s no longer exists in AWS (arn=%s) — resetting for recreation",
                                name, status.getImageArn());
                        status.setImageArn(null);
                        status.setImageState(null);
                        status.setLatestVersion(null);
                        status.setLatestVersionState(null);
                        status.setActiveVersion(null);
                        status.setCurrentBuildId(null);
                        status.setBuildMessage(null);
                        return UpdateControl.patchStatus(resource).rescheduleAfter(POLL_INTERVAL);
                    }
                    throw e;
                }
                status.setImageState(imageResp.stateAsString());

                // Poll version state if we have a version to track
                if (status.getLatestVersion() != null) {
                    var versionResp = imageClient.getImageVersion(status.getImageArn(), status.getLatestVersion())
                            .get(TIMEOUT_S, TimeUnit.SECONDS);
                    status.setLatestVersionState(versionResp.stateAsString());
                    if (versionResp.stateReason() != null) {
                        status.setLatestVersionStateReason(versionResp.stateReason());
                    }

                    // Surface build progress info while version is building
                    if (isVersionBuilding(versionResp.stateAsString())) {
                        populateBuildProgress(name, status.getImageArn(), status);
                    } else {
                        // Build settled — clear build progress fields
                        status.setCurrentBuildId(null);
                        status.setBuildMessage(null);
                    }

                    // Auto-activate once version reaches SUCCESSFUL
                    boolean autoActivate = spec.getAutoActivate() == null || spec.getAutoActivate();
                    if (MicrovmImageVersionState.SUCCESSFUL.toString().equals(versionResp.stateAsString())
                            && autoActivate) {
                        LOG.infof("Auto-activating image %s version %s", name, status.getLatestVersion());
                        imageClient.activateVersion(status.getImageArn(), status.getLatestVersion())
                                .get(TIMEOUT_S, TimeUnit.SECONDS);
                        status.setActiveVersion(status.getLatestVersion());
                        // Prune old versions if maxVersionsToKeep is set
                        if (spec.getMaxVersionsToKeep() != null && spec.getMaxVersionsToKeep() >= 1) {
                            pruneOldVersions(name, status.getImageArn(), spec.getMaxVersionsToKeep());
                        }
                    }

                    LOG.infof("Image %s state=%s version=%s versionState=%s",
                            name, imageResp.stateAsString(), status.getLatestVersion(), versionResp.stateAsString());
                } else {
                    LOG.infof("Image %s state=%s", name, imageResp.stateAsString());
                }
                return UpdateControl.patchStatus(resource).rescheduleAfter(POLL_INTERVAL);
            }

            // Settled — sync full version list then periodic resync
            try {
                var imageResp = imageClient.getImage(status.getImageArn()).get(TIMEOUT_S, TimeUnit.SECONDS);
                if (imageResp.latestActiveImageVersion() != null) {
                    status.setActiveVersion(imageResp.latestActiveImageVersion());
                }
            } catch (Exception e) {
                if (isNotFound(e)) {
                    LOG.warnf("Image %s no longer exists in AWS (arn=%s) — resetting for recreation",
                            name, status.getImageArn());
                    status.setImageArn(null);
                    status.setImageState(null);
                    status.setLatestVersion(null);
                    status.setLatestVersionState(null);
                    status.setActiveVersion(null);
                    return UpdateControl.patchStatus(resource).rescheduleAfter(POLL_INTERVAL);
                }
                LOG.warnf("Failed to sync active version for %s: %s", name, e.getMessage());
            }
            // Release build permit once settled (idempotent — no-op if already released)
            quotaGuard.releaseImageBuildPermit(name);
            try {
                var versions = imageClient.listVersions(status.getImageArn()).get(TIMEOUT_S, TimeUnit.SECONDS);
                status.setVersions(versions.stream().map(v -> {
                    var info = new ai.codriverlabs.microvm.operator.core.model.MicroVMImageVersionInfo();
                    info.setVersion(v.imageVersion());
                    info.setState(v.stateAsString());
                    info.setStatus(v.statusAsString());
                    return info;
                }).collect(java.util.stream.Collectors.toList()));
            } catch (Exception e) {
                LOG.warnf("Failed to list image versions for %s: %s", name, e.getMessage());
            }
            return UpdateControl.patchStatus(resource).rescheduleAfter(RESYNC);

        } catch (Exception e) {
            LOG.errorf(e, "Error reconciling MicroVMImage %s/%s", namespace, name);
            return UpdateControl.patchStatus(resource).rescheduleAfter(Duration.ofSeconds(30));
        }
    }

    @Override
    public DeleteControl cleanup(MicroVMImage resource, Context<MicroVMImage> ctx) {
        MicroVMImageStatus status = resource.getStatus();
        if (status == null || status.getImageArn() == null) {
            return DeleteControl.defaultDelete();
        }
        // Release build permit if the image was still building when deleted —
        // prevents the in-memory semaphore from leaking across CR deletions.
        if (!isBuildSettled(status.getImageState()) || isVersionBuilding(status.getLatestVersionState())) {
            LOG.debugf("Releasing build permit for %s (deleted while building)", resource.getMetadata().getName());
            quotaGuard.releaseImageBuildPermit(resource.getMetadata().getName());
        }
        try {
            LOG.infof("Deleting image %s  arn=%s", resource.getMetadata().getName(), status.getImageArn());
            imageClient.deleteImage(status.getImageArn()).get(TIMEOUT_S, TimeUnit.SECONDS);
        } catch (Exception e) {
            if (isNotFound(e)) {
                // Already deleted in AWS — proceed with CR cleanup
                LOG.debugf("Image %s already gone in AWS, proceeding with CR deletion", status.getImageArn());
                clearDeleteRetryCount(resource);
                return DeleteControl.defaultDelete();
            }
            if (isDeleteBlockedByRunningVms(e)) {
                String reason = "Cannot delete: AWS reports running MicroVMs still reference this image ("
                        + status.getImageArn() + "). Waiting for those MicroVMs to be deleted or moved to "
                        + "another image before this can be removed.";
                status.setLatestVersionStateReason(reason);
                emitImageEvent(resource, "DeleteBlocked", reason);
                Duration backoff = nextDeleteRetryBackoff(resource);
                LOG.warnf("Image %s delete blocked by running VMs — retrying in %s: %s",
                        status.getImageArn(), backoff, e.getMessage());
                return DeleteControl.noFinalizerRemoval().rescheduleAfter(backoff);
            }
            // Unknown/unexpected error — keep retrying, but still cap the backoff
            // instead of hammering the AWS API at a flat interval forever.
            Duration backoff = nextDeleteRetryBackoff(resource);
            LOG.warnf("Error deleting image %s: %s — retrying in %s", status.getImageArn(), e.getMessage(), backoff);
            return DeleteControl.noFinalizerRemoval().rescheduleAfter(backoff);
        }
        clearDeleteRetryCount(resource);
        return DeleteControl.defaultDelete();
    }

    /**
     * Detects the specific AWS error raised when a microvm-image cannot be deleted
     * because MicroVMs are still running from it. See
     * docs/design/image-arn-collision-prevention.md for the full failure scenario
     * this is part of (two same-named MicroVMImage CRs in different namespaces
     * silently sharing one AWS ARN).
     */
    private boolean isDeleteBlockedByRunningVms(Throwable t) {
        Throwable cause = t.getCause() != null ? t.getCause() : t;
        String msg = cause.getMessage();
        return cause.getClass().getSimpleName().contains("ValidationException")
                && msg != null && msg.toLowerCase().contains("running microvms");
    }

    /**
     * Computes the next capped-exponential backoff for a delete retry, tracked via
     * an annotation on the resource so the count survives operator restarts.
     * Sequence: 15s, 30s, 1m, 2m, then capped at 5m.
     */
    private Duration nextDeleteRetryBackoff(MicroVMImage resource) {
        int count = getDeleteRetryCount(resource);
        Duration next = count < DELETE_RETRY_BACKOFF.length
                ? DELETE_RETRY_BACKOFF[count]
                : DELETE_RETRY_BACKOFF_CAP;
        setDeleteRetryCount(resource, count + 1);
        return next;
    }

    private int getDeleteRetryCount(MicroVMImage resource) {
        var annotations = resource.getMetadata().getAnnotations();
        if (annotations == null) return 0;
        String raw = annotations.get(DELETE_RETRY_COUNT_ANNOTATION);
        if (raw == null) return 0;
        try {
            return Integer.parseInt(raw);
        } catch (NumberFormatException e) {
            return 0;
        }
    }

    private void setDeleteRetryCount(MicroVMImage resource, int count) {
        try {
            var annotations = resource.getMetadata().getAnnotations();
            if (annotations == null) {
                annotations = new java.util.HashMap<>();
                resource.getMetadata().setAnnotations(annotations);
            }
            annotations.put(DELETE_RETRY_COUNT_ANNOTATION, String.valueOf(count));
            if (kubernetesClient != null) {
                kubernetesClient.resource(resource).patch(io.fabric8.kubernetes.client.dsl.base.PatchContext
                        .of(io.fabric8.kubernetes.client.dsl.base.PatchType.JSON_MERGE));
            }
        } catch (Exception e) {
            LOG.debugf("Could not persist delete-retry-count annotation for %s/%s: %s",
                    resource.getMetadata().getNamespace(), resource.getMetadata().getName(), e.getMessage());
            // Non-fatal — worst case the backoff resets to 15s after an operator restart.
        }
    }

    private void clearDeleteRetryCount(MicroVMImage resource) {
        var annotations = resource.getMetadata().getAnnotations();
        if (annotations != null && annotations.remove(DELETE_RETRY_COUNT_ANNOTATION) != null && kubernetesClient != null) {
            try {
                kubernetesClient.resource(resource).patch(io.fabric8.kubernetes.client.dsl.base.PatchContext
                        .of(io.fabric8.kubernetes.client.dsl.base.PatchType.JSON_MERGE));
            } catch (Exception e) {
                LOG.debugf("Could not clear delete-retry-count annotation: %s", e.getMessage());
            }
        }
    }

    private void emitImageEvent(MicroVMImage resource, String reason, String message) {
        if (kubernetesClient == null) return;
        try {
            Event event = new EventBuilder()
                .withNewMetadata()
                    .withGenerateName(resource.getMetadata().getName() + "-")
                    .withNamespace(resource.getMetadata().getNamespace())
                .endMetadata()
                .withReason(reason)
                .withMessage(message)
                .withType("Warning")
                .withInvolvedObject(new ObjectReferenceBuilder()
                    .withApiVersion(resource.getApiVersion())
                    .withKind(resource.getKind())
                    .withName(resource.getMetadata().getName())
                    .withNamespace(resource.getMetadata().getNamespace())
                    .withUid(resource.getMetadata().getUid())
                    .build())
                .withNewSource()
                    .withComponent("microvmimage-controller")
                .endSource()
                .build();

            kubernetesClient.v1().events().inNamespace(resource.getMetadata().getNamespace()).resource(event).create();
        } catch (Exception e) {
            LOG.warnf("Failed to emit event for %s/%s: %s",
                resource.getMetadata().getNamespace(), resource.getMetadata().getName(), e.getMessage());
        }
    }

    private boolean isNotFound(Throwable t) {
        // Unwrap ExecutionException from CompletableFuture.get()
        Throwable cause = t.getCause() != null ? t.getCause() : t;
        return cause.getClass().getSimpleName().contains("ResourceNotFoundException")
                || (cause.getMessage() != null && cause.getMessage().contains("ResourceNotFoundException"));
    }

    // Build is settled when image state is final AND version has reached a terminal state
    private boolean isBuildSettled(String imageState) {
        if (imageState == null) return false;
        return imageState.equals(MicrovmImageState.CREATED.toString())
                || imageState.equals(MicrovmImageState.UPDATED.toString())
                || imageState.equals(MicrovmImageState.CREATE_FAILED.toString())
                || imageState.equals(MicrovmImageState.UPDATE_FAILED.toString())
                || imageState.equals(MicrovmImageState.DELETE_FAILED.toString());
    }

    private boolean isVersionBuilding(String versionState) {
        if (versionState == null) return true; // unknown = assume still building
        return versionState.equals(MicrovmImageVersionState.PENDING.toString())
                || versionState.equals(MicrovmImageVersionState.IN_PROGRESS.toString());
    }

    private MicroVMImageStatus ensureStatus(MicroVMImage resource) {
        if (resource.getStatus() == null) {
            resource.setStatus(new MicroVMImageStatus());
        }
        return resource.getStatus();
    }

    /**
     * Fetches the latest build info and populates status build fields.
     * Called while the version is still in PENDING/IN_PROGRESS state.
     */
    private void populateBuildProgress(String imageName, String imageArn, MicroVMImageStatus status) {
        if (status.getLatestVersion() == null) return;
        try {
            var buildDetail = imageClient.getLatestBuild(imageArn, status.getLatestVersion())
                    .get(TIMEOUT_S, TimeUnit.SECONDS);
            if (buildDetail != null) {
                status.setCurrentBuildId(buildDetail.buildId());
                if (status.getBuildStartedAt() == null && buildDetail.createdAt() != null) {
                    status.setBuildStartedAt(buildDetail.createdAt().toString());
                }
                // Use stateReason as message if present, else use build state
                if (buildDetail.stateReason() != null && !buildDetail.stateReason().isBlank()) {
                    status.setBuildMessage(buildDetail.stateReason());
                } else {
                    status.setBuildMessage(buildDetail.buildStateAsString());
                }
            }
        } catch (Exception e) {
            LOG.debugf("Could not fetch build info for image %s: %s", imageName, e.getMessage());
        }
    }

    private void updateMemoryStatus(MicroVMImageStatus status, Integer memorySizeMiB) {
        int effectiveMemory = memorySizeMiB != null ? memorySizeMiB : 2048;
        status.setMemorySizeMiB(effectiveMemory);
        status.setComputeProfile(buildComputeProfile(effectiveMemory));
    }

    /**
     * Prunes old image versions, keeping only the {@code maxToKeep} most recent.
     * Versions are sorted by creation time ascending (oldest first) and deleted
     * until the count is within the retention limit.
     */
    private void pruneOldVersions(String imageName, String imageArn, int maxToKeep) {
        try {
            var versions = imageClient.listVersions(imageArn).get(TIMEOUT_S, TimeUnit.SECONDS);
            if (versions == null || versions.size() <= maxToKeep) return;

            // Sort oldest first by imageVersion string (versions are sequential: "1.0", "2.0", ...)
            var sorted = new java.util.ArrayList<>(versions);
            sorted.sort(java.util.Comparator.comparing(
                v -> v.imageVersion() != null ? v.imageVersion() : ""));

            int toDelete = sorted.size() - maxToKeep;
            for (int i = 0; i < toDelete; i++) {
                String versionId = sorted.get(i).imageVersion();
                LOG.infof("Pruning image %s version %s (maxVersionsToKeep=%d)",
                        imageName, versionId, maxToKeep);
                imageClient.deleteImageVersion(imageArn, versionId).get(TIMEOUT_S, TimeUnit.SECONDS);
            }
        } catch (Exception e) {
            LOG.warnf("Failed to prune old versions for image %s: %s", imageName, e.getMessage());
        }
    }

    static String buildComputeProfile(int memoryMiB) {
        double vcpu = memoryMiB / 2048.0;
        int peakMemory = memoryMiB * 4;
        double peakVcpu = vcpu * 4;
        return String.format("%d MiB / %.2g vCPU (peak: %d MiB / %.2g vCPU)",
                memoryMiB, vcpu, peakMemory, peakVcpu);
    }
}
