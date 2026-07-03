package ai.codriverlabs.microvm.operator.tests.integration;

import ai.codriverlabs.microvm.aws.lambdamicrovms.model.*;
import ai.codriverlabs.microvm.operator.controller.aws.MicroVMImageClient;
import ai.codriverlabs.microvm.operator.controller.reconciler.MicroVMImageReconciler;
import ai.codriverlabs.microvm.operator.core.model.MicroVMImage;
import ai.codriverlabs.microvm.operator.core.model.MicroVMImageSource;
import ai.codriverlabs.microvm.operator.core.model.MicroVMImageSpec;
import io.fabric8.kubernetes.api.model.ObjectMetaBuilder;
import io.fabric8.kubernetes.client.KubernetesClient;
import io.fabric8.kubernetes.client.server.mock.EnableKubernetesMockClient;
import io.javaoperatorsdk.operator.api.reconciler.Context;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;

import java.util.concurrent.CompletableFuture;

import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

/**
 * Integration tests for MicroVMImageReconciler using Fabric8 mock Kubernetes API server (crud=true).
 * AWS API calls are mocked with Mockito. No cluster required.
 */
@EnableKubernetesMockClient(crud = true)
class MicroVMImageReconcilerIT {

    KubernetesClient client;

    private MicroVMImageClient mockImageClient;
    private MicroVMImageReconciler reconciler;

    @BeforeEach
    void setUp() {
        mockImageClient = mock(MicroVMImageClient.class);
        reconciler = new MicroVMImageReconciler(mockImageClient);
    }

    @Test
    @DisplayName("CREATE: reconciler calls createImage and patches status with imageArn + CREATING state")
    void create_patchesStatusWithImageArn() throws Exception {
        var image = testImage("hello-node");
        client.resource(image).create();

        var createResp = CreateMicrovmImageResponse.builder()
                .imageArn("arn:aws:lambda:us-east-1:123456789012:microvm-image:hello-node")
                .imageVersion("1.0")
                .state(MicrovmImageState.CREATING)
                .build();
        when(mockImageClient.createImage(eq("hello-node"), anyString(), anyString(), anyString(), any()))
                .thenReturn(CompletableFuture.completedFuture(createResp));

        var ctx = mockContext();
        var result = reconciler.reconcile(image, ctx);

        assertTrue(result.isPatchStatus());
        assertNotNull(image.getStatus());
        assertEquals("arn:aws:lambda:us-east-1:123456789012:microvm-image:hello-node",
                image.getStatus().getImageArn());
        assertEquals("CREATING", image.getStatus().getImageState());
        assertEquals("1.0", image.getStatus().getLatestVersion());
        assertEquals("PENDING", image.getStatus().getLatestVersionState());
        verify(mockImageClient).createImage(eq("hello-node"),
                eq("s3://test-bucket/test/app.zip"), anyString(), anyString(), any());
    }

    @Test
    @DisplayName("POLL: reconciler fetches image + version state while building")
    void poll_updatesVersionState() throws Exception {
        var image = testImage("hello-node");
        // Pre-set status as if CREATE already ran
        var status = new ai.codriverlabs.microvm.operator.core.model.MicroVMImageStatus();
        status.setImageArn("arn:aws:lambda:us-east-1:123456789012:microvm-image:hello-node");
        status.setImageState("CREATING");
        status.setLatestVersion("1.0");
        status.setLatestVersionState("PENDING");
        image.setStatus(status);

        var imageResp = GetMicrovmImageResponse.builder()
                .imageArn("arn:aws:lambda:us-east-1:123456789012:microvm-image:hello-node")
                .state(MicrovmImageState.CREATING)
                .build();
        var versionResp = GetMicrovmImageVersionResponse.builder()
                .imageArn("arn:aws:lambda:us-east-1:123456789012:microvm-image:hello-node")
                .imageVersion("1.0")
                .state(MicrovmImageVersionState.IN_PROGRESS)
                .build();
        when(mockImageClient.getImage(anyString()))
                .thenReturn(CompletableFuture.completedFuture(imageResp));
        when(mockImageClient.getImageVersion(anyString(), eq("1.0")))
                .thenReturn(CompletableFuture.completedFuture(versionResp));

        var result = reconciler.reconcile(image, mockContext());

        assertTrue(result.isPatchStatus());
        assertEquals("CREATING", image.getStatus().getImageState());
        assertEquals("IN_PROGRESS", image.getStatus().getLatestVersionState());
        verify(mockImageClient, never()).createImage(any(), any(), any(), any(), any());
    }

    @Test
    @DisplayName("SETTLED: no polling when image CREATED and version SUCCESSFUL")
    void settled_noMorePolling() throws Exception {
        var image = testImage("hello-node");
        var status = new ai.codriverlabs.microvm.operator.core.model.MicroVMImageStatus();
        status.setImageArn("arn:aws:lambda:us-east-1:123456789012:microvm-image:hello-node");
        status.setImageState("CREATED");
        status.setLatestVersion("1.0");
        status.setLatestVersionState("SUCCESSFUL");
        status.setObservedGeneration(1L);
        image.setStatus(status);

        reconciler.reconcile(image, mockContext());

        // No AWS calls when settled
        verify(mockImageClient, never()).getImage(any());
        verify(mockImageClient, never()).getImageVersion(any(), any());
    }

    @Test
    @DisplayName("UPDATE: calls updateImage when generation advances and build settled")
    void update_callsUpdateImageOnGenerationChange() throws Exception {
        var image = testImage("hello-node");
        image.getMetadata().setGeneration(2L);
        var status = new ai.codriverlabs.microvm.operator.core.model.MicroVMImageStatus();
        status.setImageArn("arn:aws:lambda:us-east-1:123456789012:microvm-image:hello-node");
        status.setImageState("CREATED");
        status.setLatestVersion("1.0");
        status.setLatestVersionState("SUCCESSFUL");
        status.setObservedGeneration(1L); // generation 1 < resource generation 2
        image.setStatus(status);

        var updateResp = UpdateMicrovmImageResponse.builder()
                .imageArn("arn:aws:lambda:us-east-1:123456789012:microvm-image:hello-node")
                .imageVersion("2.0")
                .state(MicrovmImageState.UPDATING)
                .build();
        when(mockImageClient.updateImage(anyString(), anyString(), anyString(), anyString()))
                .thenReturn(CompletableFuture.completedFuture(updateResp));

        reconciler.reconcile(image, mockContext());

        verify(mockImageClient).updateImage(
                eq("arn:aws:lambda:us-east-1:123456789012:microvm-image:hello-node"),
                eq("s3://test-bucket/test/app.zip"), anyString(), anyString());
        assertEquals(2L, image.getStatus().getObservedGeneration());
        assertEquals("2.0", image.getStatus().getLatestVersion());
    }

    @Test
    @DisplayName("DELETE: cleanup calls deleteImage via finalizer")
    void delete_callsDeleteImage() throws Exception {
        var image = testImage("hello-node");
        var status = new ai.codriverlabs.microvm.operator.core.model.MicroVMImageStatus();
        status.setImageArn("arn:aws:lambda:us-east-1:123456789012:microvm-image:hello-node");
        image.setStatus(status);

        when(mockImageClient.deleteImage(anyString()))
                .thenReturn(CompletableFuture.completedFuture(
                        DeleteMicrovmImageResponse.builder().build()));

        var deleteControl = reconciler.cleanup(image, mockContext());

        assertTrue(deleteControl.isRemoveFinalizer());
        verify(mockImageClient).deleteImage(
                eq("arn:aws:lambda:us-east-1:123456789012:microvm-image:hello-node"));
    }

    @Test
    @DisplayName("DELETE: cleanup is no-op when no imageArn in status")
    void delete_noOpWhenNoArn() throws Exception {
        var image = testImage("hello-node");
        // No status set

        var deleteControl = reconciler.cleanup(image, mockContext());

        assertTrue(deleteControl.isRemoveFinalizer());
        verify(mockImageClient, never()).deleteImage(any());
    }

    // --- helpers ---

    private MicroVMImage testImage(String name) {
        var image = new MicroVMImage();
        image.setMetadata(new ObjectMetaBuilder()
                .withName(name)
                .withNamespace("default")
                .withGeneration(1L)
                .build());
        var spec = new MicroVMImageSpec();
        var source = new MicroVMImageSource();
        source.setS3Bucket("test-bucket");
        source.setS3Key("test/app.zip");
        spec.setSource(source);
        spec.setBaseImageArn("arn:aws:lambda:us-east-1:aws:microvm-image:al2023-1");
        spec.setBuildRoleArn("arn:aws:iam::123456789012:role/BuildRole");
        image.setSpec(spec);
        return image;
    }

    @SuppressWarnings("unchecked")
    private Context<MicroVMImage> mockContext() {
        Context<MicroVMImage> ctx = mock(Context.class);
        when(ctx.getClient()).thenReturn(client);
        return ctx;
    }
}
