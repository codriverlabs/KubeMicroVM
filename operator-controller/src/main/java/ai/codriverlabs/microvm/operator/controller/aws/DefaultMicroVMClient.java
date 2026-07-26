package ai.codriverlabs.microvm.operator.controller.aws;

import software.amazon.awssdk.services.lambdamicrovms.LambdaMicrovmsAsyncClient;
import software.amazon.awssdk.services.lambdamicrovms.model.*;
import java.net.URI;
import java.util.Optional;
import jakarta.annotation.PreDestroy;
import jakarta.enterprise.context.ApplicationScoped;
import jakarta.inject.Inject;
import org.eclipse.microprofile.config.inject.ConfigProperty;
import software.amazon.awssdk.regions.Region;
import software.amazon.awssdk.services.sts.StsClient;

import java.util.Map;
import java.util.concurrent.CompletableFuture;

@ApplicationScoped
public class DefaultMicroVMClient implements MicroVMClient {

    private final LambdaMicrovmsAsyncClient sdk;

    @Inject
    public DefaultMicroVMClient(
            @ConfigProperty(name = "aws.region", defaultValue = "us-east-1") String region,
            @ConfigProperty(name = "aws.microvm.endpoint") Optional<String> endpoint) {
        var builder = LambdaMicrovmsAsyncClient.builder()
                .region(Region.of(region));
        endpoint.filter(s -> !s.isBlank()).ifPresent(e -> builder.endpointOverride(URI.create(e)));
        this.sdk = builder.build();
    }

    @Override
    public CompletableFuture<RunMicroVMResponse> runMicroVM(RunMicroVMRequest request) {
        var builder = RunMicrovmRequest.builder()
                .imageIdentifier(request.imageIdentifier())
                .executionRoleArn(request.executionRoleArn())
                .runHookPayload(request.runHookPayload());

        if (request.imageVersion() != null) {
            builder.imageVersion(request.imageVersion());
        }
        if (request.maximumDurationSeconds() != null) {
            builder.maximumDurationInSeconds(request.maximumDurationSeconds());
        }
        if (request.maxIdleDurationSeconds() != null || request.suspendedDurationSeconds() != null
                || request.autoResumeEnabled() != null) {
            builder.idlePolicy(IdlePolicy.builder()
                    .maxIdleDurationSeconds(request.maxIdleDurationSeconds())
                    .suspendedDurationSeconds(request.suspendedDurationSeconds())
                    .autoResumeEnabled(request.autoResumeEnabled())
                    .build());
        }
        if (request.ingressNetworkConnectors() != null && !request.ingressNetworkConnectors().isEmpty()) {
            builder.ingressNetworkConnectors(request.ingressNetworkConnectors());
        }
        if (request.egressNetworkConnectors() != null && !request.egressNetworkConnectors().isEmpty()) {
            builder.egressNetworkConnectors(request.egressNetworkConnectors());
        }

        return sdk.runMicrovm(builder.build())
                .thenApply(r -> new RunMicroVMResponse(r.microvmId(), r.stateAsString(), r.endpoint()));
    }

    @Override
    public CompletableFuture<DescribeMicroVMResponse> getMicroVM(String microvmId) {
        return sdk.getMicrovm(GetMicrovmRequest.builder().microvmIdentifier(microvmId).build())
                .thenApply(r -> new DescribeMicroVMResponse(
                        r.microvmId(), r.stateAsString(), r.endpoint(), null, r.imageVersion()));
    }

    @Override
    public CompletableFuture<Void> suspendMicroVM(String microvmId) {
        return sdk.suspendMicrovm(SuspendMicrovmRequest.builder().microvmIdentifier(microvmId).build())
                .thenApply(r -> null);
    }

    @Override
    public CompletableFuture<Void> resumeMicroVM(String microvmId) {
        return sdk.resumeMicrovm(ResumeMicrovmRequest.builder().microvmIdentifier(microvmId).build())
                .thenApply(r -> null);
    }

    @Override
    public CompletableFuture<Void> terminateMicroVM(String microvmId) {
        return sdk.terminateMicrovm(TerminateMicrovmRequest.builder().microvmIdentifier(microvmId).build())
                .thenApply(r -> null);
    }

    @Override
    public CompletableFuture<Map<String, String>> createAuthToken(
            String microvmId, int expirationMinutes, boolean allPorts) {
        var portsBuilder = PortSpecification.builder();
        if (allPorts) {
            portsBuilder.allPorts(Unit.builder().build());
        } else {
            portsBuilder.port(8080);
        }
        return sdk.createMicrovmAuthToken(CreateMicrovmAuthTokenRequest.builder()
                .microvmIdentifier(microvmId)
                .expirationInMinutes(expirationMinutes)
                .allowedPorts(portsBuilder.build())
                .build())
                .thenApply(r -> r.authToken());
    }

    @Override
    public CompletableFuture<Map<String, String>> createShellAuthToken(
            String microvmId, int expirationMinutes) {
        return sdk.createMicrovmShellAuthToken(CreateMicrovmShellAuthTokenRequest.builder()
                .microvmIdentifier(microvmId)
                .expirationInMinutes(expirationMinutes)
                .build())
                .thenApply(r -> r.authToken());
    }

    @Override
    public CompletableFuture<java.util.List<software.amazon.awssdk.services.lambdamicrovms.model.MicrovmItem>> listMicroVMs(
            String imageIdentifier) {
        var builder = ListMicrovmsRequest.builder();
        if (imageIdentifier != null) builder.imageIdentifier(imageIdentifier);
        return sdk.listMicrovms(builder.build())
                .thenApply(r -> r.items());
    }

    @Override
    public CompletableFuture<Void> tagResource(String resourceArn, Map<String, String> tags) {
        return sdk.tagResource(TagResourceRequest.builder()
                .resource(resourceArn)
                .tags(tags)
                .build())
                .thenApply(r -> null);
    }

    @Override
    public CompletableFuture<Void> untagResource(String resourceArn, java.util.List<String> tagKeys) {
        return sdk.untagResource(UntagResourceRequest.builder()
                .resource(resourceArn)
                .tagKeys(tagKeys)
                .build())
                .thenApply(r -> null);
    }

    @Override
    public CompletableFuture<Map<String, String>> listTags(String resourceArn) {
        return sdk.listTags(ListTagsRequest.builder()
                .resource(resourceArn)
                .build())
                .thenApply(r -> r.tags());
    }

    @PreDestroy
    void close() {
        sdk.close();
    }
}
