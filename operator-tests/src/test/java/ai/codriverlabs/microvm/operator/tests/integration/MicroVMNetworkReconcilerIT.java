package ai.codriverlabs.microvm.operator.tests.integration;

import ai.codriverlabs.microvm.aws.lambdacore.model.*;
import ai.codriverlabs.microvm.operator.controller.aws.MicroVMNetworkClient;
import ai.codriverlabs.microvm.operator.controller.reconciler.MicroVMNetworkReconciler;
import ai.codriverlabs.microvm.operator.core.model.*;
import io.fabric8.kubernetes.api.model.ObjectMetaBuilder;
import io.fabric8.kubernetes.client.KubernetesClient;
import io.fabric8.kubernetes.client.server.mock.EnableKubernetesMockClient;
import io.javaoperatorsdk.operator.api.reconciler.Context;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;

import java.util.List;
import java.util.concurrent.CompletableFuture;

import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

/**
 * Integration tests for MicroVMNetworkReconciler using Fabric8 mock server (crud=true).
 * AWS (lambda-core) calls are mocked with Mockito. No cluster required.
 */
@EnableKubernetesMockClient(crud = true)
class MicroVMNetworkReconcilerIT {

    KubernetesClient client;

    private MicroVMNetworkClient mockNetworkClient;
    private MicroVMNetworkReconciler reconciler;

    @BeforeEach
    void setUp() {
        mockNetworkClient = mock(MicroVMNetworkClient.class);
        reconciler = new MicroVMNetworkReconciler(mockNetworkClient, client);
    }

    @Test
    @DisplayName("CREATE: calls createConnector and sets connectorArn + PENDING state")
    void create_setsConnectorArnAndPendingState() throws Exception {
        var network = testNetwork("my-vpc-egress");
        client.resource(network).create();

        // No existing connector in AWS — adopt-if-exists falls through to create
        // Reconciler looks up by name "default-my-vpc-egress" (namespace-CR-name default)
        when(mockNetworkClient.getConnector("default-my-vpc-egress"))
                .thenReturn(java.util.concurrent.CompletableFuture.failedFuture(
                        new RuntimeException(
                            ai.codriverlabs.microvm.aws.lambdacore.model.ResourceNotFoundException.builder()
                                .message("not found").build())));

        when(mockNetworkClient.createConnector(anyString(), any()))
                .thenReturn(CompletableFuture.completedFuture(
                        CreateNetworkConnectorResponse.builder()
                                .arn("arn:aws:lambda:us-east-1:123456789012:network-connector:my-vpc-egress")
                                .id("nc-abc123")
                                .build()));

        var result = reconciler.reconcile(network, mockContext());

        assertTrue(result.isPatchStatus());
        assertEquals("arn:aws:lambda:us-east-1:123456789012:network-connector:my-vpc-egress",
                network.getStatus().getConnectorArn());
        assertEquals("nc-abc123", network.getStatus().getConnectorId());
        assertEquals("PENDING", network.getStatus().getConnectorState());
        // Verify the effective name passed to createConnector is namespace-CRname
        verify(mockNetworkClient).createConnector(
                eq("default-my-vpc-egress"), any(MicroVMNetworkSpec.class));
    }

    @Test
    @DisplayName("POLL PENDING: reschedules while connector is still provisioning")
    void poll_reschedulesWhilePending() throws Exception {
        var network = testNetwork("my-vpc-egress");
        network.setStatus(statusWith("arn:aws:lambda:us-east-1:123456789012:network-connector:my-vpc-egress", "PENDING"));

        when(mockNetworkClient.getConnector(anyString()))
                .thenReturn(CompletableFuture.completedFuture(
                        GetNetworkConnectorResponse.builder()
                                .arn("arn:aws:lambda:us-east-1:123456789012:network-connector:my-vpc-egress")
                                .state(NetworkConnectorState.PENDING)
                                .build()));

        var result = reconciler.reconcile(network, mockContext());

        assertTrue(result.isPatchStatus());
        assertEquals("PENDING", network.getStatus().getConnectorState());
        verify(mockNetworkClient, never()).createConnector(any(), any());
    }

    @Test
    @DisplayName("POLL ACTIVE: sets Ready=True condition and reschedules at RESYNC interval")
    void poll_setsReadyConditionWhenActive() throws Exception {
        var network = testNetwork("my-vpc-egress");
        network.setStatus(statusWith("arn:aws:lambda:us-east-1:123456789012:network-connector:my-vpc-egress", "PENDING"));

        when(mockNetworkClient.getConnector(anyString()))
                .thenReturn(CompletableFuture.completedFuture(
                        GetNetworkConnectorResponse.builder()
                                .arn("arn:aws:lambda:us-east-1:123456789012:network-connector:my-vpc-egress")
                                .state(NetworkConnectorState.ACTIVE)
                                .build()));

        var result = reconciler.reconcile(network, mockContext());

        assertTrue(result.isPatchStatus());
        assertEquals("ACTIVE", network.getStatus().getConnectorState());
        assertNotNull(network.getStatus().getConditions());
        var readyCondition = network.getStatus().getConditions().stream()
                .filter(c -> "Ready".equals(c.getType())).findFirst();
        assertTrue(readyCondition.isPresent());
        assertEquals("True", readyCondition.get().getStatus());
    }

    @Test
    @DisplayName("POLL FAILED: sets Ready=False condition with stateReason")
    void poll_setsFailedConditionOnFailure() throws Exception {
        var network = testNetwork("my-vpc-egress");
        network.setStatus(statusWith("arn:aws:lambda:us-east-1:123456789012:network-connector:my-vpc-egress", "PENDING"));

        when(mockNetworkClient.getConnector(anyString()))
                .thenReturn(CompletableFuture.completedFuture(
                        GetNetworkConnectorResponse.builder()
                                .arn("arn:aws:lambda:us-east-1:123456789012:network-connector:my-vpc-egress")
                                .state(NetworkConnectorState.FAILED)
                                .stateReason("Subnet not found")
                                .build()));

        reconciler.reconcile(network, mockContext());

        assertEquals("FAILED", network.getStatus().getConnectorState());
        assertEquals("Subnet not found", network.getStatus().getStateReason());
        var readyCondition = network.getStatus().getConditions().stream()
                .filter(c -> "Ready".equals(c.getType())).findFirst();
        assertTrue(readyCondition.isPresent());
        assertEquals("False", readyCondition.get().getStatus());
    }

    @Test
    @DisplayName("DELETE: removes finalizer after deleteConnector succeeds")
    void delete_removesFinalizer() throws Exception {
        var network = testNetwork("my-vpc-egress");
        network.setStatus(statusWith("arn:aws:lambda:us-east-1:123456789012:network-connector:my-vpc-egress", "ACTIVE"));

        when(mockNetworkClient.deleteConnector(anyString()))
                .thenReturn(CompletableFuture.completedFuture(
                        DeleteNetworkConnectorResponse.builder().build()));

        var result = reconciler.cleanup(network, mockContext());

        assertTrue(result.isRemoveFinalizer());
        verify(mockNetworkClient).deleteConnector(
                eq("arn:aws:lambda:us-east-1:123456789012:network-connector:my-vpc-egress"));
    }

    @Test
    @DisplayName("DELETE: blocks when a MicroVM still references this network")
    void delete_blockedWhenInUse() throws Exception {
        var network = testNetwork("my-vpc-egress");
        network.setStatus(statusWith("arn:aws:lambda:us-east-1:123456789012:network-connector:my-vpc-egress", "ACTIVE"));

        // Create a MicroVM that references this network
        var vm = new MicroVM();
        vm.setMetadata(new ObjectMetaBuilder().withName("my-vm").withNamespace("default").build());
        var spec = new MicroVMSpec();
        spec.setNetworkRef("my-vpc-egress");
        vm.setSpec(spec);
        client.resource(vm).create();

        var result = reconciler.cleanup(network, mockContext());

        assertFalse(result.isRemoveFinalizer());
        verify(mockNetworkClient, never()).deleteConnector(any());
    }

    @Test
    @DisplayName("DELETE: no-op when no connectorArn in status")
    void delete_noOpWithoutArn() throws Exception {
        var network = testNetwork("my-vpc-egress");
        // No status

        var result = reconciler.cleanup(network, mockContext());

        assertTrue(result.isRemoveFinalizer());
        verify(mockNetworkClient, never()).deleteConnector(any());
    }

    // --- helpers ---

    private MicroVMNetwork testNetwork(String name) {
        var network = new MicroVMNetwork();
        network.setMetadata(new ObjectMetaBuilder()
                .withName(name).withNamespace("default").withGeneration(1L).build());
        var spec = new MicroVMNetworkSpec();
        spec.setSubnetIds(List.of("subnet-abc123", "subnet-def456"));
        spec.setSecurityGroupIds(List.of("sg-xyz789"));
        spec.setOperatorRoleArn("arn:aws:iam::123456789012:role/MicroVMNetworkConnectorRole");
        network.setSpec(spec);
        return network;
    }

    private MicroVMNetworkStatus statusWith(String arn, String state) {
        var status = new MicroVMNetworkStatus();
        status.setConnectorArn(arn);
        status.setConnectorState(state);
        return status;
    }

    @SuppressWarnings("unchecked")
    private Context<MicroVMNetwork> mockContext() {
        Context<MicroVMNetwork> ctx = mock(Context.class);
        when(ctx.getClient()).thenReturn(client);
        return ctx;
    }

    // ── Adoption tests ────────────────────────────────────────────────────────

    @Test
    @DisplayName("ADOPT: existing connector found by name — CreateNetworkConnector not called")
    void adopt_existingConnector_skipsCreate() throws Exception {
        var network = testNetwork("my-vpc-egress");
        client.resource(network).create();

        // Reconciler looks up by name "default-my-vpc-egress" (namespace-CR-name)
        String expectedArn = "arn:aws:lambda:us-east-1:123456789012:network-connector:default-my-vpc-egress";
        var existingResp = mock(ai.codriverlabs.microvm.aws.lambdacore.model.GetNetworkConnectorResponse.class);
        when(existingResp.arn()).thenReturn(expectedArn);
        when(existingResp.id()).thenReturn("conn-id-001");
        when(existingResp.stateAsString()).thenReturn("ACTIVE");

        when(mockNetworkClient.getConnector("default-my-vpc-egress"))
                .thenReturn(java.util.concurrent.CompletableFuture.completedFuture(existingResp));

        reconciler.reconcile(network, mockContext());

        verify(mockNetworkClient, never()).createConnector(any(), any());
        assertEquals(expectedArn, network.getStatus().getConnectorArn());
        assertEquals("ACTIVE", network.getStatus().getConnectorState());
    }

    @Test
    @DisplayName("ADOPT: connector not found — falls through to createConnector")
    void adopt_notFound_fallsThroughToCreate() throws Exception {
        var network = testNetwork("new-connector");
        client.resource(network).create();

        when(mockNetworkClient.getConnector("default-new-connector"))
                .thenReturn(java.util.concurrent.CompletableFuture.failedFuture(
                        new RuntimeException(
                            ai.codriverlabs.microvm.aws.lambdacore.model.ResourceNotFoundException.builder()
                                .message("not found").build())));

        var createResp = mock(ai.codriverlabs.microvm.aws.lambdacore.model.CreateNetworkConnectorResponse.class);
        when(createResp.arn()).thenReturn("arn:aws:lambda:us-east-1:123456789012:network-connector:default-new-connector");
        when(createResp.id()).thenReturn("conn-id-new");
        when(mockNetworkClient.createConnector(any(), any()))
                .thenReturn(java.util.concurrent.CompletableFuture.completedFuture(createResp));

        reconciler.reconcile(network, mockContext());

        verify(mockNetworkClient, times(1)).createConnector(eq("default-new-connector"), any());
        assertEquals("PENDING", network.getStatus().getConnectorState());
    }

    @Test
    @DisplayName("CONNECTOR NAME: spec.connectorName used as effective name for lookup and create")
    void connectorName_override_usedForLookupAndCreate() throws Exception {
        var network = testNetwork("my-vpc-egress");
        network.getSpec().setConnectorName("cli-created-connector"); // CLI name, not namespace-prefixed
        client.resource(network).create();

        // Reconciler should look up by the explicit connectorName, not by namespace-CR-name
        when(mockNetworkClient.getConnector("cli-created-connector"))
                .thenReturn(java.util.concurrent.CompletableFuture.failedFuture(
                        new RuntimeException(
                            ai.codriverlabs.microvm.aws.lambdacore.model.ResourceNotFoundException.builder()
                                .message("not found").build())));

        var createResp = mock(ai.codriverlabs.microvm.aws.lambdacore.model.CreateNetworkConnectorResponse.class);
        when(createResp.arn()).thenReturn("arn:aws:lambda:us-east-1:123456789012:network-connector:cli-created-connector");
        when(createResp.id()).thenReturn("conn-id-cli");
        when(mockNetworkClient.createConnector(any(), any()))
                .thenReturn(java.util.concurrent.CompletableFuture.completedFuture(createResp));

        reconciler.reconcile(network, mockContext());

        // Must use "cli-created-connector", NOT "default-my-vpc-egress"
        verify(mockNetworkClient, never()).getConnector("default-my-vpc-egress");
        verify(mockNetworkClient).getConnector("cli-created-connector");
        verify(mockNetworkClient).createConnector(eq("cli-created-connector"), any());
    }

    @Test
    @DisplayName("CONNECTOR NAME: spec.connectorName adopts existing CLI connector")
    void connectorName_override_adoptsExistingCliConnector() throws Exception {
        var network = testNetwork("my-vpc-egress");
        network.getSpec().setConnectorName("cli-created-connector");
        client.resource(network).create();

        String cliArn = "arn:aws:lambda:us-east-1:123456789012:network-connector:cli-created-connector";
        var existingResp = mock(ai.codriverlabs.microvm.aws.lambdacore.model.GetNetworkConnectorResponse.class);
        when(existingResp.arn()).thenReturn(cliArn);
        when(existingResp.id()).thenReturn("conn-id-cli");
        when(existingResp.stateAsString()).thenReturn("ACTIVE");

        when(mockNetworkClient.getConnector("cli-created-connector"))
                .thenReturn(java.util.concurrent.CompletableFuture.completedFuture(existingResp));

        reconciler.reconcile(network, mockContext());

        verify(mockNetworkClient, never()).createConnector(any(), any());
        assertEquals(cliArn, network.getStatus().getConnectorArn());
        assertEquals("ACTIVE", network.getStatus().getConnectorState());
    }
}
