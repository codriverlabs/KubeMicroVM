package ai.codriverlabs.microvm.operator.controller.rest;

import ai.codriverlabs.microvm.operator.controller.aws.MicroVMClient;
import ai.codriverlabs.microvm.operator.core.model.MicroVM;
import com.fasterxml.jackson.annotation.JsonInclude;
import io.fabric8.kubernetes.api.model.authentication.TokenReviewBuilder;
import io.fabric8.kubernetes.api.model.authorization.v1.SubjectAccessReviewBuilder;
import io.fabric8.kubernetes.client.KubernetesClient;
import jakarta.inject.Inject;
import jakarta.ws.rs.*;
import jakarta.ws.rs.core.HttpHeaders;
import jakarta.ws.rs.core.MediaType;
import jakarta.ws.rs.core.Response;
import org.eclipse.microprofile.config.inject.ConfigProperty;
import org.jboss.logging.Logger;

import java.time.Instant;
import java.time.temporal.ChronoUnit;
import io.smallrye.common.annotation.RunOnVirtualThread;
import java.util.List;
import java.util.Map;
import java.util.concurrent.TimeUnit;

/**
 * Operator token sub-resource REST endpoint.
 *
 * Allows in-cluster pods to obtain MicroVM auth tokens using their Kubernetes
 * ServiceAccount identity — without needing AWS credentials directly.
 *
 * POST /apis/lambda.aws.amazon.com/v1alpha1/namespaces/{ns}/microvms/{name}/token
 *
 * Authorization flow:
 * 1. TokenReview — resolves the caller's Bearer token to a Kubernetes username + groups
 * 2. SubjectAccessReview — checks if that identity can `create` on `microvms/token` for this VM
 * 3. CreateMicrovmAuthToken — calls AWS on behalf of the caller
 */
@Path("/apis/lambda.aws.amazon.com/v1alpha1/namespaces/{ns}/microvms/{name}/token")
@Produces(MediaType.APPLICATION_JSON)
@Consumes(MediaType.APPLICATION_JSON)
public class MicroVMTokenResource {

    private static final Logger LOG = Logger.getLogger(MicroVMTokenResource.class);

    @Inject
    KubernetesClient k8s;

    @Inject
    MicroVMClient microVMClient;

    @ConfigProperty(name = "microvm.token.max-expiry-minutes", defaultValue = "60")
    int maxExpiryMinutes;

    // Package-visible for testing
    MicroVMTokenResource() {}

    public MicroVMTokenResource(KubernetesClient k8s, MicroVMClient microVMClient, int maxExpiryMinutes) {
        this.k8s = k8s;
        this.microVMClient = microVMClient;
        this.maxExpiryMinutes = maxExpiryMinutes;
    }

    @POST
    @RunOnVirtualThread
    public Response createToken(
            @PathParam("ns") String namespace,
            @PathParam("name") String vmName,
            @HeaderParam(HttpHeaders.AUTHORIZATION) String authorization,
            TokenRequest request) {

        // 1. Extract Bearer token
        String callerToken = extractBearerToken(authorization);
        if (callerToken == null) {
            return Response.status(Response.Status.UNAUTHORIZED)
                    .entity(Map.of("error", "missing Bearer token")).build();
        }

        // 2+3. TokenReview → SubjectAccessReview (overridable for testing)
        Response authError = checkAuthorization(callerToken, namespace, vmName);
        if (authError != null) return authError;

        // 4. Resolve microvmId
        MicroVM vm = k8s.resources(MicroVM.class).inNamespace(namespace).withName(vmName).get();
        if (vm == null) {
            return Response.status(Response.Status.NOT_FOUND)
                    .entity(Map.of("error", "MicroVM not found: " + vmName)).build();
        }
        if (vm.getStatus() == null || vm.getStatus().getMicroVmId() == null) {
            return Response.status(Response.Status.CONFLICT)
                    .entity(Map.of("error", "MicroVM " + vmName + " has no microvmId (state: "
                            + (vm.getStatus() != null ? vm.getStatus().getState() : "unknown") + ")"))
                    .build();
        }

        String microvmId = vm.getStatus().getMicroVmId();
        String endpoint = vm.getStatus().getEndpointUrl();

        // 5. Determine token parameters
        int expiryMinutes = request != null && request.expirationInMinutes != null
                ? Math.min(request.expirationInMinutes, maxExpiryMinutes) : 30;
        if (expiryMinutes < 1) {
            return Response.status(Response.Status.BAD_REQUEST)
                    .entity(Map.of("error", "expirationInMinutes must be between 1 and " + maxExpiryMinutes))
                    .build();
        }
        boolean allPorts = request == null || request.allowedPorts == null
                || request.allowedPorts.stream().anyMatch(p -> p.containsKey("allPorts"));

        // 6. Call AWS CreateMicrovmAuthToken
        try {
            Map<String, String> tokenMap = microVMClient
                    .createAuthToken(microvmId, expiryMinutes, allPorts)
                    .get(30, TimeUnit.SECONDS);
            String authToken = tokenMap.getOrDefault("X-aws-proxy-auth",
                    tokenMap.values().iterator().next());
            Instant expiresAt = Instant.now().plus(expiryMinutes, ChronoUnit.MINUTES);
            return Response.ok(new TokenResponse(authToken, endpoint, expiresAt.toString())).build();
        } catch (Exception e) {
            LOG.errorf(e, "Failed to create auth token for MicroVM %s/%s", namespace, vmName);
            return Response.status(Response.Status.INTERNAL_SERVER_ERROR)
                    .entity(Map.of("error", "failed to create token")).build();
        }
    }

    private String extractBearerToken(String authorization) {
        if (authorization == null || !authorization.startsWith("Bearer ")) return null;
        String token = authorization.substring(7).trim();
        return token.isBlank() ? null : token;
    }

    @JsonInclude(JsonInclude.Include.NON_NULL)
    @io.quarkus.runtime.annotations.RegisterForReflection
    public static class TokenRequest {
        public Integer expirationInMinutes;
        public List<Map<String, Object>> allowedPorts;
    }

    @JsonInclude(JsonInclude.Include.NON_NULL)
    @io.quarkus.runtime.annotations.RegisterForReflection
    public static class TokenResponse {
        public final String authToken;
        public final String endpoint;
        public final String expiresAt;
        public TokenResponse(String authToken, String endpoint, String expiresAt) {
            this.authToken = authToken;
            this.endpoint = endpoint;
            this.expiresAt = expiresAt;
        }
    }

    /** Overridable for testing — performs TokenReview + SubjectAccessReview. Returns null if authorized. */
    protected Response checkAuthorization(String callerToken, String namespace, String vmName) {
        // Step 1: TokenReview — who is calling?
        String username;
        List<String> groups;
        try {
            var tr = k8s.authentication().v1().tokenReviews().create(
                    new TokenReviewBuilder()
                            .withNewSpec().withToken(callerToken).endSpec()
                            .build());
            if (!Boolean.TRUE.equals(tr.getStatus().getAuthenticated())) {
                return Response.status(Response.Status.UNAUTHORIZED)
                        .entity(Map.of("error", "token not authenticated")).build();
            }
            username = tr.getStatus().getUser().getUsername();
            groups = tr.getStatus().getUser().getGroups();
        } catch (Exception e) {
            LOG.errorf(e, "TokenReview failed for %s/%s", namespace, vmName);
            return Response.status(Response.Status.INTERNAL_SERVER_ERROR)
                    .entity(Map.of("error", "token review failed")).build();
        }
        // Step 2: SubjectAccessReview — is the caller allowed?
        if (!isAuthorized(username, groups, namespace, vmName)) {
            LOG.infof("SAR denied for user=%s vm=%s/%s", username, namespace, vmName);
            return Response.status(Response.Status.FORBIDDEN)
                    .entity(Map.of("error",
                            "not authorized — ask your admin to grant create on microvms/token for "
                                    + vmName)).build();
        }
        return null; // authorized
    }

    /** Overridable for testing — checks RBAC for the resolved identity. */
    protected boolean isAuthorized(String username, List<String> groups, String namespace, String vmName) {
        var sar = k8s.authorization().v1().subjectAccessReview().create(
                new SubjectAccessReviewBuilder()
                        .withNewSpec()
                            .withUser(username)
                            .withGroups(groups)
                            .withNewResourceAttributes()
                                .withGroup("lambda.aws.amazon.com")
                                .withResource("microvms")
                                .withSubresource("token")
                                .withVerb("create")
                                .withNamespace(namespace)
                                .withName(vmName)
                            .endResourceAttributes()
                        .endSpec()
                        .build());
        return Boolean.TRUE.equals(sar.getStatus().getAllowed());
    }
}
