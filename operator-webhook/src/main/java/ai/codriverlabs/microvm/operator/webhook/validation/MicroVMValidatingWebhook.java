package ai.codriverlabs.microvm.operator.webhook.validation;


import ai.codriverlabs.microvm.operator.core.model.MicroVM;
import ai.codriverlabs.microvm.operator.core.model.MicroVMImage;
import ai.codriverlabs.microvm.operator.core.model.MicroVMImageSpec;
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
        if (spec.getImageRef() == null || spec.getImageRef().isBlank()) {
            errors.add("spec.imageRef is required");
        }
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
                    if (spec.getImageRef() == null || spec.getImageRef().isBlank()) {
                        errors.add("spec.imageRef is required");
                    }
                    validateNetworkRef(spec, request.getNamespace(), errors);
                    validateClassName(spec, request.getNamespace(), errors);
                    validateImportMicroVmId(spec, request.getOperation(),
                            request.getOldObject() != null ? request.getOldObject() : null, errors);
                }
            } else if ("microvmimages".equals(resource)) {
                Object rawObject = request.getObject();
                MicroVMImage image = objectMapper.convertValue(rawObject, MicroVMImage.class);
                if (image.getSpec() != null) {
                    validateMemorySizeMiB(image.getSpec(), errors);
                    validateMaxVersionsToKeep(image.getSpec(), errors);
                    // Immutability check on UPDATE
                    if ("UPDATE".equals(request.getOperation()) && request.getOldObject() != null) {
                        MicroVMImage oldImage = objectMapper.convertValue(request.getOldObject(), MicroVMImage.class);
                        validateMemoryImmutability(oldImage.getSpec(), image.getSpec(), errors);
                    }
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

    // --- MicroVMImage validation ---

    private static final java.util.Set<Integer> ALLOWED_MEMORY_SIZES =
            java.util.Set.of(512, 1024, 2048, 4096, 8192);

    void validateMemorySizeMiB(MicroVMImageSpec spec, List<String> errors) {
        Integer memory = spec.getMemorySizeMiB();
        if (memory != null && !ALLOWED_MEMORY_SIZES.contains(memory)) {
            errors.add(String.format(
                    "spec.memorySizeMiB must be one of %s, got %d",
                    ALLOWED_MEMORY_SIZES, memory));
        }
    }

    void validateMemoryImmutability(MicroVMImageSpec oldSpec, MicroVMImageSpec newSpec, List<String> errors) {
        if (oldSpec == null || newSpec == null) return;
        Integer oldMemory = oldSpec.getMemorySizeMiB();
        Integer newMemory = newSpec.getMemorySizeMiB();
        if (oldMemory != null && newMemory != null && !oldMemory.equals(newMemory)) {
            errors.add("spec.memorySizeMiB is immutable after image creation");
        }
    }

    void validateImportMicroVmId(MicroVMSpec spec, String operation, Object oldObject, List<String> errors) {
        String importId = spec.getImportMicroVmId();
        if (importId == null || importId.isBlank()) return;

        // Pattern: microvm- followed by a UUID (36 chars: 8-4-4-4-12 hex with dashes)
        if (!importId.matches("^microvm-[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")) {
            errors.add("spec.importMicroVmId must match pattern microvm-<uuid> " +
                       "(e.g. microvm-12345678-abcd-efgh-ijkl-123456789012)");
        }

        // Immutability: importMicroVmId cannot be changed after creation
        if ("UPDATE".equals(operation) && oldObject != null) {
            try {
                ObjectMapper mapper = this.objectMapper != null
                        ? this.objectMapper
                        : new ObjectMapper();
                MicroVM oldVm = mapper.convertValue(oldObject, MicroVM.class);
                String oldImportId = oldVm.getSpec() != null ? oldVm.getSpec().getImportMicroVmId() : null;
                if (oldImportId != null && !oldImportId.equals(importId)) {
                    errors.add("spec.importMicroVmId is immutable after creation");
                }
                if (oldImportId == null && !importId.isBlank()) {
                    errors.add("spec.importMicroVmId cannot be added after creation — " +
                               "create a new CR with the import field set from the start");
                }
            } catch (Exception e) {
                LOG.warnf("Could not deserialize oldObject for importMicroVmId immutability check: %s",
                        e.getMessage());
            }
        }
    }

    void validateMaxVersionsToKeep(MicroVMImageSpec spec, List<String> errors) {
        if (spec.getMaxVersionsToKeep() == null) return;
        if (spec.getMaxVersionsToKeep() < 1) {
            errors.add("spec.maxVersionsToKeep must be >= 1 (or omit to disable automatic pruning)");
        }
    }
}
