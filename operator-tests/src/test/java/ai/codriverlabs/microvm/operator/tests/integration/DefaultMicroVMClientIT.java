package ai.codriverlabs.microvm.operator.tests.integration;

import ai.codriverlabs.microvm.aws.lambdamicrovms.LambdaMicrovmsAsyncClient;
import ai.codriverlabs.microvm.aws.lambdamicrovms.model.*;
import ai.codriverlabs.microvm.operator.controller.aws.DefaultMicroVMClient;
import ai.codriverlabs.microvm.operator.controller.aws.RunMicroVMRequest;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;
import org.mockito.ArgumentCaptor;

import java.util.List;
import java.util.concurrent.CompletableFuture;

import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.Mockito.*;

/**
 * Unit tests verifying that DefaultMicroVMClient correctly maps all RunMicroVMRequest fields
 * to the AWS SDK RunMicrovmRequest — idle policy, connectors, maximumDuration.
 */
class DefaultMicroVMClientIT {

    private LambdaMicrovmsAsyncClient mockSdk;
    private DefaultMicroVMClient client;

    @BeforeEach
    void setUp() throws Exception {
        mockSdk = mock(LambdaMicrovmsAsyncClient.class);
        // Construct DefaultMicroVMClient and inject mock SDK via reflection
        client = new DefaultMicroVMClient("us-east-1", java.util.Optional.empty());
        var sdkField = DefaultMicroVMClient.class.getDeclaredField("sdk");
        sdkField.setAccessible(true);
        sdkField.set(client, mockSdk);
    }

    @Test
    @DisplayName("idlePolicy is correctly mapped from RunMicroVMRequest to SDK request")
    void runMicroVM_mapsIdlePolicy() throws Exception {
        stubRunMicrovm();

        client.runMicroVM(new RunMicroVMRequest(
                "arn:aws:lambda:us-east-1:123:microvm-image:my-image",
                null, null, null,
                null, null,
                900,    // maxIdleDurationSeconds
                1800,   // suspendedDurationSeconds
                true,   // autoResumeEnabled
                null, null, null)).get();

        var captor = ArgumentCaptor.forClass(RunMicrovmRequest.class);
        verify(mockSdk).runMicrovm(captor.capture());
        var sdkRequest = captor.getValue();

        assertNotNull(sdkRequest.idlePolicy());
        assertEquals(900, sdkRequest.idlePolicy().maxIdleDurationSeconds());
        assertEquals(1800, sdkRequest.idlePolicy().suspendedDurationSeconds());
        assertTrue(sdkRequest.idlePolicy().autoResumeEnabled());
    }

    @Test
    @DisplayName("no idlePolicy set when all idle fields are null")
    void runMicroVM_noIdlePolicy_whenFieldsNull() throws Exception {
        stubRunMicrovm();

        client.runMicroVM(new RunMicroVMRequest(
                "arn:aws:lambda:us-east-1:123:microvm-image:my-image",
                null, null, null, null, null,
                null, null, null, null, null, null)).get();

        var captor = ArgumentCaptor.forClass(RunMicrovmRequest.class);
        verify(mockSdk).runMicrovm(captor.capture());
        assertNull(captor.getValue().idlePolicy());
    }

    @Test
    @DisplayName("ingressNetworkConnectors passed to SDK")
    void runMicroVM_mapsIngressConnectors() throws Exception {
        stubRunMicrovm();

        client.runMicroVM(new RunMicroVMRequest(
                "arn:aws:lambda:us-east-1:123:microvm-image:my-image",
                null, null, null,
                List.of("arn:aws:lambda:us-east-1:aws:network-connector:aws-network-connector:ALL_INGRESS"),
                List.of("arn:aws:lambda:us-east-1:aws:network-connector:aws-network-connector:INTERNET_EGRESS"),
                null, null, null, null, null, null)).get();

        var captor = ArgumentCaptor.forClass(RunMicrovmRequest.class);
        verify(mockSdk).runMicrovm(captor.capture());
        assertEquals(1, captor.getValue().ingressNetworkConnectors().size());
        assertEquals(1, captor.getValue().egressNetworkConnectors().size());
        assertTrue(captor.getValue().ingressNetworkConnectors().get(0).contains("ALL_INGRESS"));
        assertTrue(captor.getValue().egressNetworkConnectors().get(0).contains("INTERNET_EGRESS"));
    }

    @Test
    @DisplayName("maximumDurationInSeconds passed to SDK")
    void runMicroVM_mapsMaximumDuration() throws Exception {
        stubRunMicrovm();

        client.runMicroVM(new RunMicroVMRequest(
                "arn:aws:lambda:us-east-1:123:microvm-image:my-image",
                null, null, null, null, null,
                null, null, null,
                7200,  // maximumDurationSeconds
                null, null)).get();

        var captor = ArgumentCaptor.forClass(RunMicrovmRequest.class);
        verify(mockSdk).runMicrovm(captor.capture());
        assertEquals(7200, captor.getValue().maximumDurationInSeconds());
    }

    private void stubRunMicrovm() {
        when(mockSdk.runMicrovm((RunMicrovmRequest) any())).thenReturn(CompletableFuture.completedFuture(
                RunMicrovmResponse.builder()
                        .microvmId("mvm-test")
                        .state(MicrovmState.PENDING)
                        .endpoint("mvm-test.lambda-microvm.us-east-1.on.aws")
                        .build()));
    }

    @Test
    @DisplayName("createShellAuthToken: calls AWS SDK and returns token map")
    void createShellAuthToken_returnsTokenMap() throws Exception {
        when(mockSdk.createMicrovmShellAuthToken(
                (ai.codriverlabs.microvm.aws.lambdamicrovms.model.CreateMicrovmShellAuthTokenRequest) any()))
            .thenReturn(CompletableFuture.completedFuture(
                ai.codriverlabs.microvm.aws.lambdamicrovms.model.CreateMicrovmShellAuthTokenResponse.builder()
                    .authToken(java.util.Map.of("X-aws-proxy-auth", "shell-token-abc"))
                    .build()));

        var result = client.createShellAuthToken("mvm-shell-test", 30).get(5, java.util.concurrent.TimeUnit.SECONDS);

        assertNotNull(result, "Result should not be null");
        assertFalse(result.isEmpty(), "Token map should not be empty");
        assertTrue(result.containsKey("X-aws-proxy-auth") || !result.values().isEmpty(),
                "Token map should contain an auth token");
    }
}
