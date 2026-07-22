package ai.codriverlabs.microvm.operator.tests.integration;

import ai.codriverlabs.microvm.operator.webhook.mutation.PodMutatingWebhook;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import io.fabric8.kubernetes.api.model.admission.v1.*;
import io.fabric8.kubernetes.client.KubernetesClient;
import io.fabric8.kubernetes.client.server.mock.EnableKubernetesMockClient;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;

import java.util.Base64;
import java.util.Map;

import static org.junit.jupiter.api.Assertions.*;

@EnableKubernetesMockClient(crud = true)
class PodMutatingWebhookIT {

    KubernetesClient client;
    PodMutatingWebhook webhook;
    ObjectMapper mapper = new ObjectMapper();

    @BeforeEach
    void setUp() {
        webhook = new PodMutatingWebhook();
        webhook.agentImage = "ghcr.io/codriverlabs/microvm-auth-agent:latest";
        webhook.mapper = mapper;
    }

    @Test
    @DisplayName("No-op when annotation is absent")
    void noOp_whenAnnotationAbsent() throws Exception {
        AdmissionReview review = buildReview("my-pod", Map.of());
        AdmissionReview result = webhook.mutate(review);
        assertTrue(result.getResponse().getAllowed());
        assertNull(result.getResponse().getPatch(), "No patch when annotation absent");
    }

    @Test
    @DisplayName("Injects sidecar when lambda.microvm.auth annotation is present")
    void injectsSidecar_whenAnnotationPresent() throws Exception {
        AdmissionReview review = buildReview("my-pod",
                Map.of(PodMutatingWebhook.ANNOTATION, "my-vm"));
        AdmissionReview result = webhook.mutate(review);

        assertTrue(result.getResponse().getAllowed());
        assertNotNull(result.getResponse().getPatch(), "Patch should be present");

        String patchJson = new String(Base64.getDecoder().decode(result.getResponse().getPatch()));
        JsonNode patch = mapper.readTree(patchJson);
        assertTrue(patch.isArray() && patch.size() > 0, "Patch should have entries");

        // Verify sidecar is in the patch
        boolean hasSidecar = false;
        for (JsonNode op : patch) {
            if ("add".equals(op.path("op").asText())
                    && op.path("value").path("name").asText("").equals(PodMutatingWebhook.SIDECAR_NAME)) {
                hasSidecar = true;
                break;
            }
        }
        assertTrue(hasSidecar, "Patch should include microvm-auth-agent sidecar");
    }

    @Test
    @DisplayName("Uses custom mount path from annotation")
    void usesCustomMountPath_whenAnnotated() throws Exception {
        AdmissionReview review = buildReview("my-pod", Map.of(
                PodMutatingWebhook.ANNOTATION, "my-vm",
                PodMutatingWebhook.ANNOTATION + "/mount-path", "/custom/path"
        ));
        AdmissionReview result = webhook.mutate(review);
        String patchJson = new String(Base64.getDecoder().decode(result.getResponse().getPatch()));
        assertTrue(patchJson.contains("/custom/path"), "Custom mount path should appear in patch");
    }

    @Test
    @DisplayName("Idempotent — does not inject if sidecar already present")
    void idempotent_whenSidecarAlreadyPresent() throws Exception {
        AdmissionReview review = buildReviewWithSidecar("my-pod",
                Map.of(PodMutatingWebhook.ANNOTATION, "my-vm"));
        AdmissionReview result = webhook.mutate(review);
        assertTrue(result.getResponse().getAllowed());
        // Patch may be null or empty — no duplicate sidecar
        if (result.getResponse().getPatch() != null) {
            String patchJson = new String(Base64.getDecoder().decode(result.getResponse().getPatch()));
            JsonNode patch = mapper.readTree(patchJson);
            long sidecarAdds = 0;
            for (JsonNode op : patch) {
                if ("add".equals(op.path("op").asText())
                        && PodMutatingWebhook.SIDECAR_NAME.equals(
                                op.path("value").path("name").asText(""))) {
                    sidecarAdds++;
                }
            }
            assertEquals(0, sidecarAdds, "Should not add duplicate sidecar");
        }
    }

    @Test
    @DisplayName("Fail-open — allowed=true even if webhook throws")
    void failOpen_onException() {
        // Null object → triggers NPE inside webhook
        var review = new AdmissionReview();
        var req = new AdmissionRequest();
        req.setUid("test-uid");
        req.setObject(null);
        review.setRequest(req);

        AdmissionReview result = webhook.mutate(review);
        assertTrue(result.getResponse().getAllowed(), "Webhook must never block pod creation");
    }

    // --- helpers ---

    private AdmissionReview buildReview(String podName, Map<String, String> annotations) throws Exception {
        var podSpec = mapper.createObjectNode();
        podSpec.set("containers", mapper.createArrayNode().add(
                mapper.createObjectNode().put("name", "app").put("image", "my-app")));

        var meta = mapper.createObjectNode();
        meta.put("name", podName);
        meta.put("namespace", "default");
        var annNode = mapper.createObjectNode();
        annotations.forEach(annNode::put);
        meta.set("annotations", annNode);

        var pod = mapper.createObjectNode();
        pod.set("metadata", meta);
        pod.set("spec", podSpec);

        var review = new AdmissionReview();
        var req = new AdmissionRequest();
        req.setUid("test-uid");
        req.setName(podName);
        req.setNamespace("default");
        req.setObject(mapper.convertValue(pod, com.fasterxml.jackson.databind.node.ObjectNode.class));
        review.setRequest(req);
        return review;
    }

    private AdmissionReview buildReviewWithSidecar(String podName, Map<String, String> annotations) throws Exception {
        var containers = mapper.createArrayNode();
        containers.add(mapper.createObjectNode().put("name", "app"));
        containers.add(mapper.createObjectNode().put("name", PodMutatingWebhook.SIDECAR_NAME));

        var podSpec = mapper.createObjectNode();
        podSpec.set("containers", containers);

        var meta = mapper.createObjectNode();
        meta.put("name", podName);
        meta.put("namespace", "default");
        var annNode = mapper.createObjectNode();
        annotations.forEach(annNode::put);
        meta.set("annotations", annNode);

        var pod = mapper.createObjectNode();
        pod.set("metadata", meta);
        pod.set("spec", podSpec);

        var review = new AdmissionReview();
        var req = new AdmissionRequest();
        req.setUid("test-uid");
        req.setName(podName);
        req.setNamespace("default");
        req.setObject(mapper.convertValue(pod, com.fasterxml.jackson.databind.node.ObjectNode.class));
        review.setRequest(req);
        return review;
    }
}
