package ai.codriverlabs.microvm.operator.spi.image;

/**
 * Result of resolving a {@code spec.imageRef} to an AWS image ARN.
 *
 * <p>Either a successful resolution (ARN + version) or an error (reason + message).</p>
 *
 * @param imageArn     resolved AWS image ARN, or null on error
 * @param imageVersion resolved image version string, or null on error
 * @param reason       machine-readable error reason code, or null on success
 * @param error        human-readable error message, or null on success
 * @since 1.1.0
 */
public record ImageResolution(String imageArn, String imageVersion, String reason, String error) {

    /** Successful resolution with ARN and version. */
    public static ImageResolution success(String arn, String version) {
        return new ImageResolution(arn, version, null, null);
    }

    /** Failed resolution with machine-readable reason and user-facing message. */
    public static ImageResolution error(String reason, String message) {
        return new ImageResolution(null, null, reason, message);
    }

    /** Returns true if this resolution was successful. */
    public boolean isSuccess() {
        return imageArn != null;
    }
}
