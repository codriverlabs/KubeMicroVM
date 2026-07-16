package ai.codriverlabs.microvm.operator.spi.image;

/**
 * Resolves a {@code spec.imageRef} string to an AWS image ARN and version.
 *
 * <p>The Community default implementation ({@code DefaultImageRefResolver} in
 * {@code operator-controller}) resolves same-namespace image references only.
 * Cross-namespace references (containing a {@code /} separator) are rejected
 * with an error directing users to KubeMicroVM PRO.</p>
 *
 * <p>PRO provides an {@code @Alternative @Priority(100)} implementation that
 * resolves cross-namespace references by validating {@code MicroVMImageBinding}
 * and optional {@code MicroVMImagePolicy} access controls.</p>
 *
 * @since 1.1.0
 */
public interface ImageRefResolver {

    /**
     * Resolves the given imageRef to an AWS image ARN and version.
     *
     * @param imageRef         the {@code spec.imageRef} value (plain name or namespace/name)
     * @param requestedVersion optional requested image version (may be null)
     * @param namespace        the namespace of the MicroVM CR requesting resolution
     * @return resolution result — either success with ARN+version, or error with reason
     */
    ImageResolution resolve(String imageRef, String requestedVersion, String namespace);
}
