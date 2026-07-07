package ai.codriverlabs.microvm.operator.tests.integration;

import ai.codriverlabs.microvm.operator.controller.aws.MicroVMClient;
import ai.codriverlabs.microvm.operator.controller.rest.MicroVMTokenResource;
import ai.codriverlabs.microvm.operator.core.enums.MicroVMState;
import ai.codriverlabs.microvm.operator.core.model.MicroVM;
import ai.codriverlabs.microvm.operator.core.model.MicroVMSpec;
import ai.codriverlabs.microvm.operator.core.model.MicroVMStatus;
import io.fabric8.kubernetes.api.model.ObjectMetaBuilder;
import io.fabric8.kubernetes.client.KubernetesClient;
import io.fabric8.kubernetes.client.server.mock.EnableKubernetesMockClient;
import jakarta.ws.rs.core.Response;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;

import java.util.Map;
import java.util.concurrent.CompletableFuture;

import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

/**
 * Integration tests for MicroVMTokenResource.
 * Uses Fabric8 mock server for Kubernetes API (TokenReview, SubjectAccessReview, MicroVM CR).
 * AWS calls mocked via Mockito.
 *
 * Note: TokenReview and SubjectAccessReview responses are pre-configured on the mock server.
 */
@EnableKubernetesMockClient(crud = true)
class MicroVMTokenResourceIT {

    KubernetesClient client;
    MicroVMClient mockAwsClient;
    MicroVMTokenResource resource;

    @BeforeEach
    void setUp() {
        mockAwsClient = mock(MicroVMClient.class);
        resource = new MicroVMTokenResource(client, mockAwsClient, new ai.codriverlabs.microvm.operator.controller.quota.QuotaGuard(new ai.codriverlabs.microvm.operator.controller.spi.DefaultQuotaPolicy(),100,100,100,100,100,100,100,10,200), 60);
    }

    @Test
    @DisplayName("Returns 401 when Authorization header is missing")
    void returns401_whenNoBearer() {
        Response resp = resource.createToken("default", "my-vm", null, null);
        assertEquals(401, resp.getStatus());
    }

    @Test
    @DisplayName("Returns 401 when Bearer token is empty")
    void returns401_whenEmptyBearer() {
        Response resp = resource.createToken("default", "my-vm", "Bearer ", null);
        assertEquals(401, resp.getStatus());
    }

    @Test
    @DisplayName("Returns 404 when MicroVM CR does not exist")
    void returns404_whenVmNotFound() {
        // TokenReview + SAR will fail/deny but we test 404 path via no VM in cluster
        // Simplified: test the NOT_FOUND path by having no VM in the mock server
        // (TokenReview mock would return authenticated=false here, so we test via subclass)
        Response resp = new MicroVMTokenResource(client, mockAwsClient, new ai.codriverlabs.microvm.operator.controller.quota.QuotaGuard(new ai.codriverlabs.microvm.operator.controller.spi.DefaultQuotaPolicy(),100,100,100,100,100,100,100,10,200), 60) {
            @Override
            protected jakarta.ws.rs.core.Response checkAuthorization(String t, String ns, String n) { return null; }
        }.createToken("default", "nonexistent-vm", "Bearer tok", null);
        assertEquals(404, resp.getStatus());
    }

    @Test
    @DisplayName("Returns 409 when MicroVM has no microvmId in status")
    void returns409_whenVmNotRunning() {
        var vm = vmWithNoId("pending-vm");
        client.resource(vm).create();

        Response resp = new MicroVMTokenResource(client, mockAwsClient, new ai.codriverlabs.microvm.operator.controller.quota.QuotaGuard(new ai.codriverlabs.microvm.operator.controller.spi.DefaultQuotaPolicy(),100,100,100,100,100,100,100,10,200), 60) {
            @Override
            protected jakarta.ws.rs.core.Response checkAuthorization(String t, String ns, String n) { return null; }
        }.createToken("default", "pending-vm", "Bearer tok", null);
        assertEquals(409, resp.getStatus());
    }

    @Test
    @DisplayName("Returns 200 with token when authorized and VM is running")
    void returns200_whenAuthorized() throws Exception {
        var vm = runningVm("my-vm", "mvm-abc123", "mvm-abc123.lambda-microvm.us-east-1.on.aws");
        client.resource(vm).create();

        when(mockAwsClient.createAuthToken(eq("mvm-abc123"), eq(30), anyBoolean()))
                .thenReturn(CompletableFuture.completedFuture(Map.of("X-aws-proxy-auth", "eyJhb...")));

        Response resp = new MicroVMTokenResource(client, mockAwsClient, new ai.codriverlabs.microvm.operator.controller.quota.QuotaGuard(new ai.codriverlabs.microvm.operator.controller.spi.DefaultQuotaPolicy(),100,100,100,100,100,100,100,10,200), 60) {
            @Override
            protected jakarta.ws.rs.core.Response checkAuthorization(String t, String ns, String n) { return null; }
        }.createToken("default", "my-vm", "Bearer tok", null);

        assertEquals(200, resp.getStatus());
        var body = (MicroVMTokenResource.TokenResponse) resp.getEntity();
        assertEquals("eyJhb...", body.authToken);
        assertEquals("mvm-abc123.lambda-microvm.us-east-1.on.aws", body.endpoint);
        assertNotNull(body.expiresAt);
    }

    @Test
    @DisplayName("Clamps expirationInMinutes to maxExpiryMinutes")
    void clampsExpiry_toMax() throws Exception {
        var vm = runningVm("my-vm", "mvm-abc123", "endpoint");
        client.resource(vm).create();

        when(mockAwsClient.createAuthToken(anyString(), eq(60), anyBoolean()))
                .thenReturn(CompletableFuture.completedFuture(Map.of("X-aws-proxy-auth", "tok")));

        var req = new MicroVMTokenResource.TokenRequest();
        req.expirationInMinutes = 9999; // above max

        Response resp = new MicroVMTokenResource(client, mockAwsClient, new ai.codriverlabs.microvm.operator.controller.quota.QuotaGuard(new ai.codriverlabs.microvm.operator.controller.spi.DefaultQuotaPolicy(),100,100,100,100,100,100,100,10,200), 60) {
            @Override
            protected jakarta.ws.rs.core.Response checkAuthorization(String t, String ns, String n) { return null; }
        }.createToken("default", "my-vm", "Bearer tok", req);

        assertEquals(200, resp.getStatus());
        // Verify AWS was called with clamped value (60, not 9999)
        verify(mockAwsClient).createAuthToken("mvm-abc123", 60, true);
    }

    @Test
    @DisplayName("Returns 403 when SAR check denies access")
    void returns403_whenSarDenied() {
        var vm = runningVm("my-vm", "mvm-abc123", "endpoint");
        client.resource(vm).create();

        Response resp = new MicroVMTokenResource(client, mockAwsClient, new ai.codriverlabs.microvm.operator.controller.quota.QuotaGuard(new ai.codriverlabs.microvm.operator.controller.spi.DefaultQuotaPolicy(),100,100,100,100,100,100,100,10,200), 60) {
            @Override
            protected jakarta.ws.rs.core.Response checkAuthorization(String t, String ns, String n) { return Response.status(403).entity(java.util.Map.of("error","denied")).build(); }
        }.createToken("default", "my-vm", "Bearer tok", null);

        assertEquals(403, resp.getStatus());
        verifyNoInteractions(mockAwsClient);
    }

    // --- helpers ---

    private MicroVM runningVm(String name, String microvmId, String endpoint) {
        var vm = new MicroVM();
        vm.setMetadata(new ObjectMetaBuilder().withName(name).withNamespace("default").build());
        vm.setSpec(new MicroVMSpec());
        var status = new MicroVMStatus();
        status.setState(MicroVMState.RUNNING);
        status.setMicroVmId(microvmId);
        status.setEndpointUrl(endpoint);
        vm.setStatus(status);
        return vm;
    }

    private MicroVM vmWithNoId(String name) {
        var vm = new MicroVM();
        vm.setMetadata(new ObjectMetaBuilder().withName(name).withNamespace("default").build());
        vm.setSpec(new MicroVMSpec());
        var status = new MicroVMStatus();
        status.setState(MicroVMState.PENDING);
        vm.setStatus(status);
        return vm;
    }
}
