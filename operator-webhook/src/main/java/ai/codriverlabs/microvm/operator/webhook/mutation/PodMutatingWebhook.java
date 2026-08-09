package ai.codriverlabs.microvm.operator.webhook.mutation;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.node.ArrayNode;
import com.fasterxml.jackson.databind.node.ObjectNode;
import io.fabric8.kubernetes.api.model.admission.v1.AdmissionRequest;
import io.fabric8.kubernetes.api.model.admission.v1.AdmissionResponse;
import io.fabric8.kubernetes.api.model.admission.v1.AdmissionReview;
import jakarta.inject.Inject;
import jakarta.ws.rs.*;
import io.smallrye.common.annotation.RunOnVirtualThread;
import jakarta.ws.rs.core.MediaType;
import org.eclipse.microprofile.config.inject.ConfigProperty;
import org.jboss.logging.Logger;

import java.util.Base64;

/**
 * Mutating webhook for Pod resources.
 *
 * When a Pod has the annotation `lambda.microvm.auth: <vm-name>`, injects:
 * 1. `microvm-auth-agent` sidecar container
 * 2. `microvm-token` emptyDir volume (medium: Memory)
 * 3. Volume mount into all non-sidecar containers (readOnly)
 *
 * The sidecar polls the operator's token sub-resource and writes fresh tokens to
 * the shared volume at /var/run/microvm/.
 *
 * Registered at webhook path: /mutate-pod
 */
@Path("/mutate-pod")
@Consumes(MediaType.APPLICATION_JSON)
@Produces(MediaType.APPLICATION_JSON)
public class PodMutatingWebhook {

    private static final Logger LOG = Logger.getLogger(PodMutatingWebhook.class);
    public static final String ANNOTATION = "lambda.microvm.auth";
    public static final String SIDECAR_NAME = "microvm-auth-agent";
    public static final String VOLUME_NAME = "microvm-token";
    public static final String CA_VOLUME_NAME = "microvm-ca";
    public static final String CA_SECRET_NAME = "kube-microvm-operator-ca";
    public static final String DEFAULT_MOUNT_PATH = "/var/run/microvm";
    public static final String CA_MOUNT_PATH = "/var/run/secrets/microvm";

    @ConfigProperty(name = "microvm.webhook.agent-image",
            defaultValue = "ghcr.io/codriverlabs/microvm-auth-agent:latest")
    public String agentImage;

    @Inject
    public ObjectMapper mapper;

    @POST
    @RunOnVirtualThread
    public AdmissionReview mutate(AdmissionReview review) {
        AdmissionRequest req = review.getRequest();
        AdmissionResponse resp = new AdmissionResponse();
        resp.setUid(req.getUid());

        try {
            JsonNode podNode = mapper.convertValue(req.getObject(), JsonNode.class);
            String vmName = getAnnotation(podNode, ANNOTATION);

            if (vmName == null || vmName.isBlank()) {
                resp.setAllowed(true);
                review.setResponse(resp);
                return review;
            }

            String namespace = req.getNamespace();
            String mountPath = getAnnotation(podNode, ANNOTATION + "/mount-path");
            if (mountPath == null || mountPath.isBlank()) mountPath = DEFAULT_MOUNT_PATH;
            String expiryMinutes = getAnnotation(podNode, ANNOTATION + "/expires");
            if (expiryMinutes == null) expiryMinutes = "30";

            // Build JSON patch
            ArrayNode patch = mapper.createArrayNode();
            JsonNode containers = podNode.path("spec").path("containers");
            JsonNode volumes = podNode.path("spec").path("volumes");

            // Add volume if not already present
            boolean hasVolume = false;
            if (volumes.isArray()) {
                for (JsonNode v : volumes) {
                    if (VOLUME_NAME.equals(v.path("name").asText())) { hasVolume = true; break; }
                }
            }
            if (!hasVolume) {
                String volumePath = volumes.isMissingNode() ? "/spec/volumes" : "/spec/volumes/-";
                ObjectNode volumePatch = mapper.createObjectNode();
                volumePatch.put("op", volumes.isMissingNode() ? "add" : "add");
                volumePatch.put("path", volumePath);
                ObjectNode volumeVal = mapper.createObjectNode();
                volumeVal.put("name", VOLUME_NAME);
                ObjectNode emptyDir = mapper.createObjectNode();
                emptyDir.put("medium", "Memory");
                volumeVal.set("emptyDir", emptyDir);
                volumePatch.set("value", volumes.isMissingNode()
                        ? mapper.createArrayNode().add(volumeVal) : volumeVal);
                patch.add(volumePatch);
            }

            // Add CA volume (Secret-backed) if not already present
            boolean hasCaVolume = false;
            if (volumes.isArray()) {
                for (JsonNode v : volumes) {
                    if (CA_VOLUME_NAME.equals(v.path("name").asText())) { hasCaVolume = true; break; }
                }
            }
            if (!hasCaVolume) {
                ObjectNode caVolumePatch = mapper.createObjectNode();
                caVolumePatch.put("op", "add");
                caVolumePatch.put("path", "/spec/volumes/-");
                ObjectNode caVolumeVal = mapper.createObjectNode();
                caVolumeVal.put("name", CA_VOLUME_NAME);
                ObjectNode secretRef = mapper.createObjectNode();
                secretRef.put("secretName", CA_SECRET_NAME);
                ArrayNode items = mapper.createArrayNode();
                ObjectNode item = mapper.createObjectNode();
                item.put("key", "ca.crt");
                item.put("path", "ca.crt");
                items.add(item);
                secretRef.set("items", items);
                caVolumeVal.set("secret", secretRef);
                caVolumePatch.set("value", caVolumeVal);
                patch.add(caVolumePatch);
            }

            // Add volumeMount to each existing container
            if (containers.isArray()) {
                for (int i = 0; i < containers.size(); i++) {
                    JsonNode c = containers.get(i);
                    if (SIDECAR_NAME.equals(c.path("name").asText())) continue;
                    JsonNode mounts = c.path("volumeMounts");
                    boolean hasMnt = false;
                    if (mounts.isArray()) {
                        for (JsonNode m : mounts) {
                            if (VOLUME_NAME.equals(m.path("name").asText())) { hasMnt = true; break; }
                        }
                    }
                    if (!hasMnt) {
                        ObjectNode mntPatch = mapper.createObjectNode();
                        mntPatch.put("op", "add");
                        mntPatch.put("path", "/spec/containers/" + i + "/volumeMounts/-");
                        ObjectNode mntVal = mapper.createObjectNode();
                        mntVal.put("name", VOLUME_NAME);
                        mntVal.put("mountPath", mountPath);
                        mntVal.put("readOnly", true);
                        mntPatch.set("value", mntVal);
                        patch.add(mntPatch);
                    }
                }
            }

            // Add sidecar container if not already present
            boolean hasSidecar = false;
            if (containers.isArray()) {
                for (JsonNode c : containers) {
                    if (SIDECAR_NAME.equals(c.path("name").asText())) { hasSidecar = true; break; }
                }
            }
            if (!hasSidecar) {
                ObjectNode sidecarPatch = mapper.createObjectNode();
                sidecarPatch.put("op", "add");
                sidecarPatch.put("path", "/spec/containers/-");
                sidecarPatch.set("value", buildSidecar(vmName, namespace, mountPath, expiryMinutes));
                patch.add(sidecarPatch);
            }

            if (!patch.isEmpty()) {
                resp.setPatchType("JSONPatch");
                resp.setPatch(Base64.getEncoder().encodeToString(patch.toString().getBytes()));
            }
            resp.setAllowed(true);
            LOG.infof("Injected microvm-auth-agent sidecar for vm=%s in pod %s/%s",
                    vmName, namespace, req.getName());

        } catch (Exception e) {
            LOG.errorf(e, "Pod mutation failed for %s/%s", req.getNamespace(), req.getName());
            resp.setAllowed(true); // fail-open: don't block pod creation on webhook error
        }

        review.setResponse(resp);
        return review;
    }

    private JsonNode buildSidecar(String vmName, String namespace, String mountPath, String expiryMinutes) {
        ObjectNode c = mapper.createObjectNode();
        c.put("name", SIDECAR_NAME);
        c.put("image", agentImage);
        c.put("imagePullPolicy", "Always");

        ArrayNode env = mapper.createArrayNode();
        env.add(envVar("MICROVM_NAME", vmName));
        env.add(envVar("MICROVM_NAMESPACE", namespace));
        env.add(envVar("MOUNT_PATH", mountPath));
        env.add(envVar("TOKEN_EXPIRY_MINUTES", expiryMinutes));
        env.add(envVar("OPERATOR_URL", "https://kube-microvm-operator.kube-microvm.svc:443"));
        c.set("env", env);

        ArrayNode mounts = mapper.createArrayNode();
        ObjectNode tokenMnt = mapper.createObjectNode();
        tokenMnt.put("name", VOLUME_NAME);
        tokenMnt.put("mountPath", mountPath);
        mounts.add(tokenMnt);
        ObjectNode caMnt = mapper.createObjectNode();
        caMnt.put("name", CA_VOLUME_NAME);
        caMnt.put("mountPath", CA_MOUNT_PATH);
        caMnt.put("readOnly", true);
        mounts.add(caMnt);
        c.set("volumeMounts", mounts);

        // Resource requests — sized for JVM mode; native mode uses much less
        ObjectNode resources = mapper.createObjectNode();
        ObjectNode requests = mapper.createObjectNode();
        requests.put("cpu", "50m");
        requests.put("memory", "128Mi");
        ObjectNode limits = mapper.createObjectNode();
        limits.put("cpu", "200m");
        limits.put("memory", "256Mi");
        resources.set("requests", requests);
        resources.set("limits", limits);
        c.set("resources", resources);

        return c;
    }

    private ObjectNode envVar(String name, String value) {
        ObjectNode e = mapper.createObjectNode();
        e.put("name", name);
        e.put("value", value);
        return e;
    }

    private String getAnnotation(JsonNode pod, String key) {
        JsonNode annotations = pod.path("metadata").path("annotations");
        if (annotations.isMissingNode() || !annotations.has(key)) return null;
        return annotations.get(key).asText(null);
    }
}
