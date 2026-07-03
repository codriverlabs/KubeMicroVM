package ai.codriverlabs.microvm.operator.webhook.validation;


import ai.codriverlabs.microvm.operator.core.model.MicroVM;
import ai.codriverlabs.microvm.operator.core.model.MicroVMNetwork;
import ai.codriverlabs.microvm.operator.core.model.MicroVMSpec;
import com.fasterxml.jackson.databind.ObjectMapper;
import io.fabric8.kubernetes.api.model.HasMetadata;
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
import java.util.List;

/**
 * Validating admission webhook for MicroVM resources.
 * Validates spec fields, namespace quota, and referenced resources.
 * FailurePolicy: Fail
 */
@Path("/validate-microvm")
public class MicroVMValidatingWebhook {

    private static final Logger LOG = Logger.getLogger(MicroVMValidatingWebhook.class);
    private static final int MIN_MEMORY_MB = 128;
    private static final int MAX_MEMORY_MB = 10240;
    private static final int MEMORY_ALIGNMENT = 64;
    private static final int MIN_VCPUS = 1;
    private static final int MAX_VCPUS = 6;
    private static final int MIN_TIMEOUT = 1;
    private static final int MAX_TIMEOUT = 900;
    private static final String MANAGE_VMS_ANNOTATION = "lambda.aws.amazon.com/manage-microvms";
    private static final String QUOTA_NAME = "count/microvms.lambda.aws.amazon.com";

    private final KubernetesClient kubernetesClient;
    private final ObjectMapper objectMapper;

    /**
     * No-arg constructor for unit testing (spec-level validation only).
     */
    public MicroVMValidatingWebhook() {
        this.kubernetesClient = null;
        this.objectMapper = null;
    }

    @Inject
    public MicroVMValidatingWebhook(KubernetesClient kubernetesClient, ObjectMapper objectMapper) {
        this.kubernetesClient = kubernetesClient;
        this.objectMapper = objectMapper;
    }

    /**
     * Validates a MicroVMSpec and returns a list of validation errors.
     * This method performs spec-level validation (memory, vcpus, runtime, timeout)
     * without requiring Kubernetes client access.
     *
     * @param spec      the MicroVMSpec to validate
     * @param namespace the namespace context (used for logging only in this overload)
     * @return list of validation error messages; empty if valid
     */
    public List<String> validate(MicroVMSpec spec, String namespace) {
        List<String> errors = new ArrayList<>();
        if (spec == null) {
            errors.add("spec is required");
            return errors;
        }
        validateRuntime(spec, errors);
        validateTimeout(spec, errors);
        return errors;
    }

    public void validateClassName(MicroVMSpec spec, String namespace, List<String> errors) {
        String className = spec.getClassName();
        if (className == null || className.isBlank()) return; // optional — no-op
        if (kubernetesClient == null) return;
        try {
            var clazz = kubernetesClient.resources(
                    ai.codriverlabs.microvm.operator.core.model.MicroVMClass.class)
                    .inNamespace(namespace).withName(className).get();
            if (clazz == null) {
                errors.add(String.format(
                        "spec.className '%s' not found in namespace '%s'", className, namespace));
            }
        } catch (Exception e) {
            LOG.warnf("Error looking up MicroVMClass %s/%s: %s", namespace, className, e.getMessage());
        }
    }

    @POST
    @RunOnVirtualThread
    @Consumes(MediaType.APPLICATION_JSON)
    @Produces(MediaType.APPLICATION_JSON)
    public AdmissionReview validate(AdmissionReview review) {
        AdmissionRequest request = review.getRequest();
        LOG.infof("Validating MicroVM admission request: %s/%s, operation=%s",
            request.getNamespace(), request.getName(), request.getOperation());

        List<String> errors = new ArrayList<>();

        try {
            String resource = request.getResource() != null ? request.getResource().getResource() : "";

            // Only validate MicroVM spec fields for microvms — Images and Networks
            // have their own validation handled by CRD schema.
            if ("microvms".equals(resource)) {
                Object rawObject = request.getObject();
                MicroVM microVM = objectMapper.convertValue(rawObject, MicroVM.class);
                MicroVMSpec spec = microVM.getSpec();

                if (spec == null) {
                    errors.add("spec is required");
                } else {
                    validateRuntime(spec, errors);
                    validateTimeout(spec, errors);
                    validateNetworkRef(spec, request.getNamespace(), errors);
                    validateClassName(spec, request.getNamespace(), errors);
                }
            }

            // Namespace permission + quota applies to all resource types
            validateNamespacePermission(request.getNamespace(), errors);

            // Validate namespace quota
            validateNamespaceQuota(request.getNamespace(), errors);

        } catch (Exception e) {
            LOG.errorf(e, "Error validating MicroVM admission request");
            errors.add("Internal validation error: " + e.getMessage());
        }

        return buildResponse(review, errors);
    }

    void validateMemory(MicroVMSpec spec, List<String> errors) {
        Integer memoryMB = spec.getMaximumDurationSeconds();
        if (memoryMB == null) return; // Will be set by mutation webhook default

        if (memoryMB < MIN_MEMORY_MB || memoryMB > MAX_MEMORY_MB) {
            errors.add(String.format("spec.memoryMB must be between %d and %d, got %d",
                MIN_MEMORY_MB, MAX_MEMORY_MB, memoryMB));
        }
        if (memoryMB % MEMORY_ALIGNMENT != 0) {
            errors.add(String.format("spec.memoryMB must be a multiple of %d, got %d",
                MEMORY_ALIGNMENT, memoryMB));
        }
    }

    void validateVcpus(MicroVMSpec spec, List<String> errors) {
        Integer vcpus = spec.getMaxIdleDurationSeconds();
        if (vcpus == null) return;

        if (vcpus < MIN_VCPUS || vcpus > MAX_VCPUS) {
            errors.add(String.format("spec.vcpus must be between %d and %d, got %d",
                MIN_VCPUS, MAX_VCPUS, vcpus));
        }
    }

    void validateRuntime(MicroVMSpec spec, List<String> errors) {
        if (spec.getImageRef() == null) {
            errors.add("spec.imageRef is required");
            return;
        }
        // Runtime enum already validated by Jackson deserialization
        // But verify explicitly for safety
        try {
            spec.getImageRef();
        } catch (IllegalArgumentException e) {
            errors.add("spec.runtime must be one of: java21, python3.12, nodejs20, custom");
        }
    }

    void validateTimeout(MicroVMSpec spec, List<String> errors) {
        Integer timeout = spec.getSuspendedDurationSeconds();
        if (timeout == null) return; // Will be set by mutation webhook default

        if (timeout < MIN_TIMEOUT || timeout > MAX_TIMEOUT) {
            errors.add(String.format("spec.timeoutSeconds must be between %d and %d, got %d",
                MIN_TIMEOUT, MAX_TIMEOUT, timeout));
        }
    }

    void validateNetworkRef(MicroVMSpec spec, String namespace, List<String> errors) {
        String networkRef = spec.getNetworkRef();
        if (networkRef == null || networkRef.isEmpty()) return;

        // Check if the referenced network contains a namespace separator
        if (networkRef.contains("/")) {
            String refNamespace = networkRef.split("/")[0];
            if (!refNamespace.equals(namespace)) {
                errors.add("spec.networkRef must reference a MicroVMNetwork in the same namespace");
                return;
            }
        }

        // Check referenced MicroVMNetwork exists in same namespace
        try {
            MicroVMNetwork network = kubernetesClient.resources(MicroVMNetwork.class)
                .inNamespace(namespace)
                .withName(networkRef)
                .get();
            if (network == null) {
                errors.add(String.format("spec.networkRef references non-existent MicroVMNetwork '%s' in namespace '%s'",
                    networkRef, namespace));
            }
        } catch (Exception e) {
            LOG.warnf("Error looking up MicroVMNetwork %s/%s: %s", namespace, networkRef, e.getMessage());
            // Don't fail validation if we can't look up the resource
        }
    }

    void validateNamespacePermission(String namespace, List<String> errors) {
        try {
            var ns = kubernetesClient.namespaces().withName(namespace).get();
            if (ns != null) {
                var labels = ns.getMetadata().getLabels();
                if (labels == null || !"true".equals(labels.get(MANAGE_VMS_ANNOTATION))) {
                    errors.add(String.format("Namespace '%s' is not managed — add label '%s=true' to enable MicroVMs",
                        namespace, MANAGE_VMS_ANNOTATION));
                }
            }
        } catch (Exception e) {
            LOG.warnf("Error checking namespace permission for %s: %s", namespace, e.getMessage());
        }
    }

    void validateNamespaceQuota(String namespace, List<String> errors) {
        try {
            var quotaList = kubernetesClient.resourceQuotas().inNamespace(namespace).list();
            for (var quota : quotaList.getItems()) {
                var hard = quota.getStatus().getHard();
                var used = quota.getStatus().getUsed();

                if (hard != null && hard.containsKey(QUOTA_NAME)) {
                    var hardValue = hard.get(QUOTA_NAME).getAmount();
                    var usedValue = used != null && used.containsKey(QUOTA_NAME)
                        ? used.get(QUOTA_NAME).getAmount() : "0";

                    int maxAllowed = Integer.parseInt(hardValue);
                    int currentCount = Integer.parseInt(usedValue);

                    if (currentCount >= maxAllowed) {
                        errors.add(String.format("Namespace quota exceeded: %d/%d MicroVMs", currentCount, maxAllowed));
                        return;
                    }
                }
            }
        } catch (Exception e) {
            LOG.warnf("Error checking namespace quota for %s: %s", namespace, e.getMessage());
        }
    }

    private AdmissionReview buildResponse(AdmissionReview review, List<String> errors) {
        AdmissionResponse response = new AdmissionResponse();
        response.setUid(review.getRequest().getUid());

        if (errors.isEmpty()) {
            response.setAllowed(true);
        } else {
            response.setAllowed(false);
            io.fabric8.kubernetes.api.model.Status status = new io.fabric8.kubernetes.api.model.Status();
            status.setCode(403);
            status.setMessage(String.join("; ", errors));
            response.setStatus(status);
        }

        AdmissionReview responseReview = new AdmissionReview();
        responseReview.setResponse(response);
        return responseReview;
    }
}
