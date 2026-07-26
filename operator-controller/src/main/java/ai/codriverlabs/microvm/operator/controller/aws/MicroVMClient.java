package ai.codriverlabs.microvm.operator.controller.aws;

import software.amazon.awssdk.services.lambdamicrovms.model.MicrovmItem;

import java.util.List;
import java.util.Map;
import java.util.concurrent.CompletableFuture;

/**
 * Client interface for AWS Lambda MicroVMs API (service: lambda-microvms, version 2025-09-09).
 */
public interface MicroVMClient {

    /** Calls RunMicrovm — creates and starts a new MicroVM from an image snapshot. */
    CompletableFuture<RunMicroVMResponse> runMicroVM(RunMicroVMRequest request);

    /** Calls GetMicrovm — describes current state of a MicroVM. */
    CompletableFuture<DescribeMicroVMResponse> getMicroVM(String microvmId);

    /** Calls ListMicrovms — lists MicroVMs, optionally filtered by image identifier. */
    CompletableFuture<List<MicrovmItem>> listMicroVMs(String imageIdentifier);

    /** Calls SuspendMicrovm — suspends a running MicroVM (preserves state). */
    CompletableFuture<Void> suspendMicroVM(String microvmId);

    /** Calls ResumeMicrovm — resumes a suspended MicroVM. */
    CompletableFuture<Void> resumeMicroVM(String microvmId);

    /** Calls TerminateMicrovm — terminates a MicroVM and releases all resources. */
    CompletableFuture<Void> terminateMicroVM(String microvmId);

    /** Calls CreateMicrovmAuthToken — short-lived JWE token for HTTPS endpoint access. */
    CompletableFuture<Map<String, String>> createAuthToken(
            String microvmId, int expirationMinutes, boolean allPorts);

    /** Calls CreateMicrovmShellAuthToken — token for native shell (exec) access. */
    CompletableFuture<Map<String, String>> createShellAuthToken(
            String microvmId, int expirationMinutes);

    /** Calls TagResource — applies tags to a MicroVM or image ARN. */
    CompletableFuture<Void> tagResource(String resourceArn, Map<String, String> tags);

    /** Calls UntagResource — removes tags from a resource. */
    CompletableFuture<Void> untagResource(String resourceArn, List<String> tagKeys);

    /** Calls ListTags — retrieves current tags on a resource. */
    CompletableFuture<Map<String, String>> listTags(String resourceArn);
}
