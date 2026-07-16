package ai.codriverlabs.microvm.operator.controller.spi;

import ai.codriverlabs.microvm.operator.core.model.MicroVMImage;
import ai.codriverlabs.microvm.operator.spi.image.ImageRefResolver;
import ai.codriverlabs.microvm.operator.spi.image.ImageResolution;
import io.fabric8.kubernetes.client.KubernetesClient;
import jakarta.enterprise.context.ApplicationScoped;
import jakarta.inject.Inject;
import org.jboss.logging.Logger;

/**
 * Community default implementation of {@link ImageRefResolver}.
 *
 * <p>Resolves same-namespace image references only. Cross-namespace references
 * (containing a {@code /} separator) are rejected with an error directing
 * users to KubeMicroVM PRO.</p>
 *
 * <p>PRO replaces this with {@code @Alternative @Priority(100)} for cross-namespace
 * resolution with binding and policy access controls.</p>
 */
@ApplicationScoped
public class DefaultImageRefResolver implements ImageRefResolver {

    private static final Logger LOG = Logger.getLogger(DefaultImageRefResolver.class);

    private final KubernetesClient kubernetesClient;

    @Inject
    public DefaultImageRefResolver(KubernetesClient kubernetesClient) {
        this.kubernetesClient = kubernetesClient;
    }

    /** No-arg constructor for CDI proxy creation. */
    DefaultImageRefResolver() {
        this.kubernetesClient = null;
    }

    @Override
    public ImageResolution resolve(String imageRef, String requestedVersion, String namespace) {
        if (imageRef == null || imageRef.isBlank()) {
            return ImageResolution.error("ImageRefMissing", "spec.imageRef is required");
        }

        // Cross-namespace refs (namespace/name) are a PRO feature
        if (imageRef.contains("/")) {
            return ImageResolution.error("CrossNamespaceImageRefNotSupported",
                    "Cross-namespace image references require KubeMicroVM PRO (imageRef: " + imageRef + ")");
        }

        // Look up MicroVMImage CR in the same namespace
        MicroVMImage image = kubernetesClient.resources(MicroVMImage.class)
                .inNamespace(namespace)
                .withName(imageRef)
                .get();

        if (image == null) {
            return ImageResolution.error("ImageNotFound",
                    "MicroVMImage '" + imageRef + "' not found in namespace '" + namespace + "'");
        }

        var status = image.getStatus();
        if (status == null || status.getImageArn() == null) {
            return ImageResolution.error("ImageNotReady",
                    "MicroVMImage '" + imageRef + "' has not been created yet (no imageArn)");
        }

        String imageState = status.getImageState();
        if (!"CREATED".equals(imageState) && !"UPDATED".equals(imageState)) {
            return ImageResolution.error("ImageNotReady",
                    "MicroVMImage '" + imageRef + "' is in state '" + imageState + "', expected CREATED or UPDATED");
        }

        // Resolve version: use requested, or fall back to activeVersion
        String resolvedVersion = requestedVersion;
        if (resolvedVersion == null || resolvedVersion.isBlank()) {
            resolvedVersion = status.getActiveVersion();
            if (resolvedVersion == null || resolvedVersion.isBlank()) {
                return ImageResolution.error("NoActiveVersion",
                        "MicroVMImage '" + imageRef + "' has no active version. Set spec.imageVersion or activate a version.");
            }
        }

        LOG.infof("Resolved imageRef '%s' → %s (version %s)", imageRef, status.getImageArn(), resolvedVersion);
        return ImageResolution.success(status.getImageArn(), resolvedVersion);
    }
}
