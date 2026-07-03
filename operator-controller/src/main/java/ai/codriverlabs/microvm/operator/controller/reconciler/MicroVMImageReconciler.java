package ai.codriverlabs.microvm.operator.controller.reconciler;

import ai.codriverlabs.microvm.aws.lambdamicrovms.model.MicrovmImageState;
import ai.codriverlabs.microvm.aws.lambdamicrovms.model.MicrovmImageVersionState;
import ai.codriverlabs.microvm.operator.controller.aws.MicroVMImageClient;
import ai.codriverlabs.microvm.operator.core.model.MicroVMImage;
import ai.codriverlabs.microvm.operator.core.model.MicroVMImageSpec;
import ai.codriverlabs.microvm.operator.core.model.MicroVMImageStatus;
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

    private final MicroVMImageClient imageClient;

    @Inject
    public MicroVMImageReconciler(MicroVMImageClient imageClient) {
        this.imageClient = imageClient;
    }

    @Override
    public UpdateControl<MicroVMImage> reconcile(MicroVMImage resource, Context<MicroVMImage> ctx) {
        String name = resource.getMetadata().getName();
        String namespace = resource.getMetadata().getNamespace();
        MicroVMImageSpec spec = resource.getSpec();
        MicroVMImageStatus status = ensureStatus(resource);

        LOG.infof("Reconciling MicroVMImage %s/%s  imageArn=%s", namespace, name, status.getImageArn());

        try {
            // --- CREATE ---
            if (status.getImageArn() == null) {
                String s3Uri = "s3://" + spec.getSource().getS3Bucket() + "/" + spec.getSource().getS3Key();
                LOG.infof("Creating image %s from %s", name, s3Uri);
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
                var imageResp = imageClient.getImage(status.getImageArn()).get(TIMEOUT_S, TimeUnit.SECONDS);
                status.setImageState(imageResp.stateAsString());

                // Poll version state if we have a version to track
                if (status.getLatestVersion() != null) {
                    var versionResp = imageClient.getImageVersion(status.getImageArn(), status.getLatestVersion())
                            .get(TIMEOUT_S, TimeUnit.SECONDS);
                    status.setLatestVersionState(versionResp.stateAsString());
                    if (versionResp.stateReason() != null) {
                        status.setLatestVersionStateReason(versionResp.stateReason());
                    }

                    // Auto-activate once version reaches SUCCESSFUL
                    boolean autoActivate = spec.getAutoActivate() == null || spec.getAutoActivate();
                    if (MicrovmImageVersionState.SUCCESSFUL.toString().equals(versionResp.stateAsString())
                            && autoActivate) {
                        LOG.infof("Auto-activating image %s version %s", name, status.getLatestVersion());
                        imageClient.activateVersion(status.getImageArn(), status.getLatestVersion())
                                .get(TIMEOUT_S, TimeUnit.SECONDS);
                        status.setActiveVersion(status.getLatestVersion());
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
        try {
            LOG.infof("Deleting image %s  arn=%s", resource.getMetadata().getName(), status.getImageArn());
            imageClient.deleteImage(status.getImageArn()).get(TIMEOUT_S, TimeUnit.SECONDS);
        } catch (Exception e) {
            LOG.warnf("Error deleting image %s: %s — retrying", status.getImageArn(), e.getMessage());
            return DeleteControl.noFinalizerRemoval().rescheduleAfter(Duration.ofSeconds(15));
        }
        return DeleteControl.defaultDelete();
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

    private void updateMemoryStatus(MicroVMImageStatus status, Integer memorySizeMiB) {
        int effectiveMemory = memorySizeMiB != null ? memorySizeMiB : 2048;
        status.setMemorySizeMiB(effectiveMemory);
        status.setComputeProfile(buildComputeProfile(effectiveMemory));
    }

    static String buildComputeProfile(int memoryMiB) {
        double vcpu = memoryMiB / 2048.0;
        int peakMemory = memoryMiB * 4;
        double peakVcpu = vcpu * 4;
        return String.format("%d MiB / %.2g vCPU (peak: %d MiB / %.2g vCPU)",
                memoryMiB, vcpu, peakMemory, peakVcpu);
    }
}
