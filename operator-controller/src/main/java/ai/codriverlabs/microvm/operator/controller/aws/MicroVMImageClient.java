package ai.codriverlabs.microvm.operator.controller.aws;

import ai.codriverlabs.microvm.aws.lambdamicrovms.LambdaMicrovmsAsyncClient;
import ai.codriverlabs.microvm.aws.lambdamicrovms.model.*;
import java.util.List;
import java.util.Optional;
import java.net.URI;
import jakarta.annotation.PreDestroy;
import jakarta.enterprise.context.ApplicationScoped;
import jakarta.inject.Inject;
import org.eclipse.microprofile.config.inject.ConfigProperty;
import software.amazon.awssdk.regions.Region;

import java.util.concurrent.CompletableFuture;

/**
 * AWS Lambda MicroVMs image operations.
 */
@ApplicationScoped
public class MicroVMImageClient {

    private final LambdaMicrovmsAsyncClient sdk;

    @Inject
    public MicroVMImageClient(
            @ConfigProperty(name = "aws.region", defaultValue = "us-east-1") String region,
            @ConfigProperty(name = "aws.microvm.endpoint") Optional<String> endpoint) {
        var builder = LambdaMicrovmsAsyncClient.builder()
                .region(Region.of(region));
        endpoint.filter(s -> !s.isBlank()).ifPresent(e -> builder.endpointOverride(URI.create(e)));
        this.sdk = builder.build();
    }

    public CompletableFuture<CreateMicrovmImageResponse> createImage(
            String name, String s3Uri, String baseImageArn, String buildRoleArn) {
        return createImage(name, s3Uri, baseImageArn, buildRoleArn, null);
    }

    public CompletableFuture<CreateMicrovmImageResponse> createImage(
            String name, String s3Uri, String baseImageArn, String buildRoleArn,
            Integer memorySizeMiB) {
        var builder = CreateMicrovmImageRequest.builder()
                .name(name)
                .codeArtifact(CodeArtifact.fromUri(s3Uri))
                .baseImageArn(baseImageArn)
                .buildRoleArn(buildRoleArn);
        if (memorySizeMiB != null) {
            builder.resources(List.of(
                    Resources.builder()
                            .minimumMemoryInMiB(memorySizeMiB)
                            .build()));
        }
        return sdk.createMicrovmImage(builder.build());
    }

    public CompletableFuture<UpdateMicrovmImageResponse> updateImage(
            String imageIdentifier, String s3Uri, String baseImageArn, String buildRoleArn) {
        return sdk.updateMicrovmImage(UpdateMicrovmImageRequest.builder()
                .imageIdentifier(imageIdentifier)
                .codeArtifact(CodeArtifact.fromUri(s3Uri))
                .baseImageArn(baseImageArn)
                .buildRoleArn(buildRoleArn)
                .build());
    }

    public CompletableFuture<GetMicrovmImageResponse> getImage(String imageIdentifier) {
        return sdk.getMicrovmImage(GetMicrovmImageRequest.builder()
                .imageIdentifier(imageIdentifier)
                .build());
    }

    public CompletableFuture<GetMicrovmImageVersionResponse> getImageVersion(String imageIdentifier, String imageVersion) {
        return sdk.getMicrovmImageVersion(GetMicrovmImageVersionRequest.builder()
                .imageIdentifier(imageIdentifier)
                .imageVersion(imageVersion)
                .build());
    }

    public CompletableFuture<DeleteMicrovmImageResponse> deleteImage(String imageIdentifier) {
        return sdk.deleteMicrovmImage(DeleteMicrovmImageRequest.builder()
                .imageIdentifier(imageIdentifier)
                .build());
    }

    public CompletableFuture<Void> deleteImageVersion(String imageIdentifier, String imageVersion) {
        return sdk.deleteMicrovmImageVersion(DeleteMicrovmImageVersionRequest.builder()
                .imageIdentifier(imageIdentifier)
                .imageVersion(imageVersion)
                .build())
                .thenApply(r -> null);
    }

    public CompletableFuture<List<MicrovmImageVersionSummary>> listVersions(String imageIdentifier) {
        return sdk.listMicrovmImageVersions(ListMicrovmImageVersionsRequest.builder()
                .imageIdentifier(imageIdentifier)
                .build())
                .thenApply(r -> r.items());
    }

    public CompletableFuture<UpdateMicrovmImageVersionResponse> activateVersion(
            String imageIdentifier, String imageVersion) {
        return sdk.updateMicrovmImageVersion(UpdateMicrovmImageVersionRequest.builder()
                .imageIdentifier(imageIdentifier)
                .imageVersion(imageVersion)
                .status(MicrovmImageVersionStatus.ACTIVE)
                .build());
    }

    public CompletableFuture<DeleteMicrovmImageVersionResponse> deleteVersion(
            String imageIdentifier, String imageVersion) {
        return sdk.deleteMicrovmImageVersion(DeleteMicrovmImageVersionRequest.builder()
                .imageIdentifier(imageIdentifier)
                .imageVersion(imageVersion)
                .build());
    }

    public CompletableFuture<List<ManagedMicrovmImageSummary>> listManagedBaseImages() {
        return sdk.listManagedMicrovmImages(ListManagedMicrovmImagesRequest.builder().build())
                .thenApply(r -> r.items());
    }

    public CompletableFuture<List<ManagedMicrovmImageVersion>> listManagedBaseImageVersions(
            String imageArn) {
        return sdk.listManagedMicrovmImageVersions(
                ListManagedMicrovmImageVersionsRequest.builder()
                        .imageIdentifier(imageArn)
                        .build())
                .thenApply(r -> r.items());
    }

    public CompletableFuture<GetMicrovmImageBuildResponse> getLatestBuild(
            String imageIdentifier, String imageVersion) {
        return sdk.listMicrovmImageBuilds(ListMicrovmImageBuildsRequest.builder()
                .imageIdentifier(imageIdentifier)
                .imageVersion(imageVersion)
                .maxResults(1)
                .build())
                .thenCompose(list -> {
                    if (!list.hasItems() || list.items().isEmpty()) {
                        return java.util.concurrent.CompletableFuture.completedFuture(null);
                    }
                    String buildId = list.items().get(0).buildId();
                    return sdk.getMicrovmImageBuild(GetMicrovmImageBuildRequest.builder()
                            .imageIdentifier(imageIdentifier)
                            .imageVersion(imageVersion)
                            .buildId(buildId)
                            .build());
                });
    }

    /**
     * Lists the most recent build summaries for the image (all versions).
     */
    public CompletableFuture<List<ai.codriverlabs.microvm.aws.lambdamicrovms.model.MicrovmImageBuildSummary>> listBuilds(
            String imageIdentifier) {
        return sdk.listMicrovmImageBuilds(ListMicrovmImageBuildsRequest.builder()
                .imageIdentifier(imageIdentifier)
                .maxResults(5)
                .build())
                .thenApply(r -> r.hasItems() ? r.items() : java.util.List.of());
    }

    @PreDestroy
    void close() { sdk.close(); }
}
