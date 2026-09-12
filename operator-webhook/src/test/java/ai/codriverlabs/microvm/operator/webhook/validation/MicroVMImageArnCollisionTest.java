package ai.codriverlabs.microvm.operator.webhook.validation;

import ai.codriverlabs.microvm.operator.core.model.MicroVMImage;
import ai.codriverlabs.microvm.operator.core.model.MicroVMImageStatus;
import io.fabric8.kubernetes.api.model.ObjectMetaBuilder;
import io.fabric8.kubernetes.client.KubernetesClient;
import io.fabric8.kubernetes.client.dsl.MixedOperation;
import io.fabric8.kubernetes.client.dsl.Resource;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;

import java.util.ArrayList;
import java.util.List;

import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.Mockito.*;

/**
 * Unit tests for {@link MicroVMValidatingWebhook#validateNoArnCollision}.
 * <p>
 * See docs/design/image-arn-collision-prevention.md for the full failure mode this
 * check prevents: two MicroVMImage CRs with the same metadata.name in different
 * namespaces silently resolving to the same AWS Lambda MicroVM image ARN, which
 * causes a permanent AWS-side delete rejection and a stuck Terminating namespace
 * if one is deleted while the other's MicroVMs are still running.
 */
class MicroVMImageArnCollisionTest {

    private KubernetesClient kubernetesClient;
    private MicroVMValidatingWebhook webhook;

    @BeforeEach
    @SuppressWarnings("unchecked")
    void setUp() {
        kubernetesClient = mock(KubernetesClient.class);
        webhook = new MicroVMValidatingWebhook(kubernetesClient, new com.fasterxml.jackson.databind.ObjectMapper());
    }

    @SuppressWarnings("unchecked")
    private void stubExistingImages(List<MicroVMImage> images) {
        var mixedOp = mock(MixedOperation.class);
        var listable = mock(io.fabric8.kubernetes.client.dsl.NonNamespaceOperation.class);
        var list = mock(io.fabric8.kubernetes.api.model.KubernetesResourceList.class);

        when(kubernetesClient.resources(MicroVMImage.class)).thenReturn(mixedOp);
        when(mixedOp.inAnyNamespace()).thenReturn(listable);
        when(listable.list()).thenReturn(list);
        when(list.getItems()).thenReturn((List) images);
    }

    private MicroVMImage image(String namespace, String name, String imageArn) {
        var img = new MicroVMImage();
        img.setMetadata(new ObjectMetaBuilder().withName(name).withNamespace(namespace).build());
        if (imageArn != null) {
            var status = new MicroVMImageStatus();
            status.setImageArn(imageArn);
            img.setStatus(status);
        }
        return img;
    }

    @Test
    void noExistingImages_allowed() {
        stubExistingImages(List.of());
        List<String> errors = new ArrayList<>();

        webhook.validateNoArnCollision(image("ns-a", "foo", null), "ns-a", errors);

        assertTrue(errors.isEmpty(), "No existing images anywhere — should be allowed: " + errors);
    }

    @Test
    void sameNameDifferentNamespace_rejected() {
        stubExistingImages(List.of(
                image("ns-a", "foo", "arn:aws:lambda:us-east-1:123456789012:microvm-image:foo")));
        List<String> errors = new ArrayList<>();

        webhook.validateNoArnCollision(image("ns-b", "foo", null), "ns-b", errors);

        assertFalse(errors.isEmpty(), "Same name in another namespace should be rejected");
        assertTrue(errors.get(0).contains("ns-a"), "Error should name the owning namespace");
        assertTrue(errors.get(0).contains("ns-a/foo"),
                "Error should suggest the cross-namespace imageRef pointing at the owning namespace");
        assertTrue(errors.get(0).contains("arn:aws:lambda:us-east-1:123456789012:microvm-image:foo"),
                "Error should include the colliding ARN for diagnosis");
    }

    @Test
    void sameNameSameNamespace_allowed() {
        // Re-applying / updating the object that already owns this name in this namespace
        // must never be flagged as a collision against itself.
        stubExistingImages(List.of(
                image("ns-a", "foo", "arn:aws:lambda:us-east-1:123456789012:microvm-image:foo")));
        List<String> errors = new ArrayList<>();

        webhook.validateNoArnCollision(image("ns-a", "foo", null), "ns-a", errors);

        assertTrue(errors.isEmpty(), "Same namespace should never collide with itself: " + errors);
    }

    @Test
    void differentName_allowed() {
        stubExistingImages(List.of(
                image("ns-a", "foo", "arn:aws:lambda:us-east-1:123456789012:microvm-image:foo")));
        List<String> errors = new ArrayList<>();

        webhook.validateNoArnCollision(image("ns-b", "bar", null), "ns-b", errors);

        assertTrue(errors.isEmpty(), "Different name should never collide: " + errors);
    }

    @Test
    void existingImageWithNoArnYet_stillFlaggedByNameAlone() {
        // Even if the existing image hasn't finished creating yet (status.imageArn
        // still null — e.g. a race between two near-simultaneous creates), the name
        // match alone is sufficient to flag the collision. Since this operator
        // manages a single AWS account + region, metadata.name deterministically
        // maps to the same ARN regardless of whether AWS has confirmed it yet —
        // waiting for status.imageArn to populate would reopen the exact creation
        // race this check exists to close.
        stubExistingImages(List.of(image("ns-a", "foo", null)));
        List<String> errors = new ArrayList<>();

        webhook.validateNoArnCollision(image("ns-b", "foo", null), "ns-b", errors);

        assertFalse(errors.isEmpty(), "Name match alone should be sufficient to flag the collision");
        assertTrue(errors.get(0).contains("ns-a"));
    }

    @Test
    void kubernetesClientNull_skipsCheckGracefully() {
        MicroVMValidatingWebhook noClientWebhook = new MicroVMValidatingWebhook();
        List<String> errors = new ArrayList<>();

        assertDoesNotThrow(() ->
                noClientWebhook.validateNoArnCollision(image("ns-a", "foo", null), "ns-a", errors));
        assertTrue(errors.isEmpty());
    }

    @Test
    void kubernetesApiError_doesNotFailValidation() {
        when(kubernetesClient.resources(MicroVMImage.class)).thenThrow(new RuntimeException("API unavailable"));
        List<String> errors = new ArrayList<>();

        assertDoesNotThrow(() ->
                webhook.validateNoArnCollision(image("ns-a", "foo", null), "ns-a", errors));
        assertTrue(errors.isEmpty(), "A lookup failure should degrade gracefully, not block admission: " + errors);
    }
}
