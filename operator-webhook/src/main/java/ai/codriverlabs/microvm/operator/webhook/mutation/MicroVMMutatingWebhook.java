package ai.codriverlabs.microvm.operator.webhook.mutation;

import ai.codriverlabs.microvm.operator.core.model.MicroVM;
import ai.codriverlabs.microvm.operator.core.model.MicroVMClass;
import ai.codriverlabs.microvm.operator.core.model.MicroVMClassSpec;
import ai.codriverlabs.microvm.operator.core.model.MicroVMSpec;
import com.fasterxml.jackson.databind.ObjectMapper;
import io.fabric8.kubernetes.api.model.admission.v1.AdmissionRequest;
import io.fabric8.kubernetes.api.model.admission.v1.AdmissionResponse;
import io.fabric8.kubernetes.api.model.admission.v1.AdmissionReview;
import io.fabric8.kubernetes.client.KubernetesClient;
import io.smallrye.common.annotation.RunOnVirtualThread;
import jakarta.inject.Inject;
import jakarta.ws.rs.Consumes;
import jakarta.ws.rs.POST;
import jakarta.ws.rs.Path;
import jakarta.ws.rs.Produces;
import jakarta.ws.rs.core.MediaType;
import org.jboss.logging.Logger;

import java.util.ArrayList;
import java.util.Base64;
import java.util.List;

/**
 * Mutating admission webhook for MicroVM resources.
 * - Applies spec.className defaults from MicroVMClass (if set)
 * - Applies global defaults for unset fields
 * FailurePolicy: Ignore — webhook errors never block admission
 */
@Path("/mutate-microvm")
public class MicroVMMutatingWebhook {

    private static final Logger LOG = Logger.getLogger(MicroVMMutatingWebhook.class);

    private final ObjectMapper objectMapper;
    private final KubernetesClient kubernetesClient;

    /** No-arg constructor for unit testing without CDI. */
    public MicroVMMutatingWebhook() {
        this.objectMapper = null;
        this.kubernetesClient = null;
    }

    @Inject
    public MicroVMMutatingWebhook(ObjectMapper objectMapper, KubernetesClient kubernetesClient) {
        this.objectMapper = objectMapper;
        this.kubernetesClient = kubernetesClient;
    }

    /**
     * Merges MicroVMClass defaults into spec, then applies global defaults.
     * Fields already set in spec are never overwritten.
     * className itself is optional — if null/blank, this is a no-op for class resolution.
     *
     * @param spec      MicroVMSpec to apply defaults to (mutated in place)
     * @param namespace namespace to look up the MicroVMClass in
     * @return the spec with defaults applied
     */
    public MicroVMSpec applyDefaults(MicroVMSpec spec, String namespace) {
        // 1. Merge MicroVMClass defaults (spec fields take precedence)
        String className = spec.getClassName();
        if (className != null && !className.isBlank() && kubernetesClient != null) {
            try {
                MicroVMClass clazz = kubernetesClient.resources(MicroVMClass.class)
                        .inNamespace(namespace).withName(className).get();
                if (clazz != null && clazz.getSpec() != null) {
                    mergeClassDefaults(spec, clazz.getSpec());
                    LOG.debugf("Applied MicroVMClass '%s' defaults to MicroVM in namespace '%s'",
                            className, namespace);
                }
            } catch (Exception e) {
                LOG.warnf("Could not resolve MicroVMClass '%s': %s — skipping class defaults",
                        className, e.getMessage());
            }
        }

        // 2. Apply global defaults for any still-unset fields
        if (spec.getMaximumDurationSeconds() == null) {
            spec.setMaximumDurationSeconds(28800);
        }
        if (spec.getAutoResumeEnabled() == null) {
            spec.setAutoResumeEnabled(true);
        }

        return spec;
    }

    /** Copies fields from MicroVMClass into spec only where spec has no value. */
    private void mergeClassDefaults(MicroVMSpec spec, MicroVMClassSpec classSpec) {
        if (spec.getMaxIdleDurationSeconds() == null && classSpec.getMaxIdleDurationSeconds() != null) {
            spec.setMaxIdleDurationSeconds(classSpec.getMaxIdleDurationSeconds());
        }
        if (spec.getSuspendedDurationSeconds() == null && classSpec.getSuspendedDurationSeconds() != null) {
            spec.setSuspendedDurationSeconds(classSpec.getSuspendedDurationSeconds());
        }
        if (spec.getAutoResumeEnabled() == null && classSpec.getAutoResumeEnabled() != null) {
            spec.setAutoResumeEnabled(classSpec.getAutoResumeEnabled());
        }
        if (spec.getMaximumDurationSeconds() == null && classSpec.getMaximumDurationSeconds() != null) {
            spec.setMaximumDurationSeconds(classSpec.getMaximumDurationSeconds());
        }
        if ((spec.getIngressNetworkConnectors() == null || spec.getIngressNetworkConnectors().isEmpty())
                && classSpec.getIngressNetworkConnectors() != null) {
            spec.setIngressNetworkConnectors(classSpec.getIngressNetworkConnectors());
        }
        if ((spec.getEgressNetworkConnectors() == null || spec.getEgressNetworkConnectors().isEmpty())
                && classSpec.getEgressNetworkConnectors() != null) {
            spec.setEgressNetworkConnectors(classSpec.getEgressNetworkConnectors());
        }
    }

    @POST
    @RunOnVirtualThread
    @Consumes(MediaType.APPLICATION_JSON)
    @Produces(MediaType.APPLICATION_JSON)
    public AdmissionReview mutate(AdmissionReview review) {
        AdmissionRequest request = review.getRequest();
        LOG.infof("Mutating MicroVM admission request: %s/%s, operation=%s",
                request.getNamespace(), request.getName(), request.getOperation());

        List<String> patches = new ArrayList<>();

        try {
            MicroVM microVM = objectMapper.treeToValue(
                    objectMapper.valueToTree(request.getObject()), MicroVM.class);
            MicroVMSpec spec = microVM.getSpec();

            if (spec != null) {
                MicroVMSpec before = objectMapper.treeToValue(
                        objectMapper.valueToTree(spec), MicroVMSpec.class);
                applyDefaults(spec, request.getNamespace());

                // Build JSON patches for fields that changed
                if (spec.getMaximumDurationSeconds() != null
                        && !spec.getMaximumDurationSeconds().equals(before.getMaximumDurationSeconds())) {
                    patches.add(buildJsonPatchOp("add", "/spec/maximumDurationSeconds",
                            spec.getMaximumDurationSeconds()));
                }
                if (spec.getAutoResumeEnabled() != null
                        && !spec.getAutoResumeEnabled().equals(before.getAutoResumeEnabled())) {
                    patches.add(buildJsonPatchOp("add", "/spec/autoResumeEnabled",
                            spec.getAutoResumeEnabled()));
                }
                if (spec.getMaxIdleDurationSeconds() != null
                        && !spec.getMaxIdleDurationSeconds().equals(before.getMaxIdleDurationSeconds())) {
                    patches.add(buildJsonPatchOp("add", "/spec/maxIdleDurationSeconds",
                            spec.getMaxIdleDurationSeconds()));
                }
                if (spec.getSuspendedDurationSeconds() != null
                        && !spec.getSuspendedDurationSeconds().equals(before.getSuspendedDurationSeconds())) {
                    patches.add(buildJsonPatchOp("add", "/spec/suspendedDurationSeconds",
                            spec.getSuspendedDurationSeconds()));
                }
            }
        } catch (Exception e) {
            LOG.errorf(e, "Error mutating MicroVM admission request");
            return buildAllowedResponse(review);
        }

        return buildPatchResponse(review, patches);
    }

    private String buildJsonPatchOp(String op, String path, Object value) {
        if (value instanceof Number || value instanceof Boolean) {
            return String.format("{\"op\":\"%s\",\"path\":\"%s\",\"value\":%s}", op, path, value);
        }
        return String.format("{\"op\":\"%s\",\"path\":\"%s\",\"value\":\"%s\"}", op, path, value);
    }

    private AdmissionReview buildPatchResponse(AdmissionReview review, List<String> patches) {
        AdmissionResponse response = new AdmissionResponse();
        response.setUid(review.getRequest().getUid());
        response.setAllowed(true);
        if (!patches.isEmpty()) {
            String patchJson = "[" + String.join(",", patches) + "]";
            response.setPatchType("JSONPatch");
            response.setPatch(Base64.getEncoder().encodeToString(patchJson.getBytes()));
        }
        AdmissionReview responseReview = new AdmissionReview();
        responseReview.setResponse(response);
        return responseReview;
    }

    private AdmissionReview buildAllowedResponse(AdmissionReview review) {
        AdmissionResponse response = new AdmissionResponse();
        response.setUid(review.getRequest().getUid());
        response.setAllowed(true);
        AdmissionReview responseReview = new AdmissionReview();
        responseReview.setResponse(response);
        return responseReview;
    }
}
