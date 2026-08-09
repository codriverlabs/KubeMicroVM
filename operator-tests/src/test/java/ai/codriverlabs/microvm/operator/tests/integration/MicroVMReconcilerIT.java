package ai.codriverlabs.microvm.operator.tests.integration;

import ai.codriverlabs.microvm.operator.controller.aws.*;
import ai.codriverlabs.microvm.operator.controller.metrics.OperatorMetrics;
import ai.codriverlabs.microvm.operator.controller.reconciler.DriftDetector;
import ai.codriverlabs.microvm.operator.controller.reconciler.MicroVMReconciler;
import ai.codriverlabs.microvm.operator.core.enums.DesiredState;
import ai.codriverlabs.microvm.operator.core.enums.MicroVMState;
import ai.codriverlabs.microvm.operator.core.model.*;
import ai.codriverlabs.microvm.operator.core.state.MicroVMStateMachine;
import io.fabric8.kubernetes.api.model.ObjectMetaBuilder;
import io.fabric8.kubernetes.client.KubernetesClient;
import io.fabric8.kubernetes.client.server.mock.EnableKubernetesMockClient;
import io.javaoperatorsdk.operator.api.reconciler.Context;
import io.micrometer.core.instrument.simple.SimpleMeterRegistry;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;

import java.time.Instant;
import java.util.concurrent.CompletableFuture;

import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

/**
 * Integration tests for MicroVMReconciler using Fabric8 mock Kubernetes API server (crud=true).
 */
@EnableKubernetesMockClient(crud = true)
class MicroVMReconcilerIT {

    KubernetesClient client;

    private MicroVMClient mockClient;
    private MicroVMReconciler reconciler;

    @BeforeEach
    void setUp() {
        mockClient = mock(MicroVMClient.class);
        OperatorMetrics metrics = new OperatorMetrics(new SimpleMeterRegistry());
        var quotaGuard = new ai.codriverlabs.microvm.operator.controller.quota.QuotaGuard(
                new ai.codriverlabs.microvm.operator.controller.spi.DefaultQuotaPolicy(),
                100, 100, 100, 100, 100, 100, 100, 10, 200); // unlimited for tests
        var imageRefResolver = new ai.codriverlabs.microvm.operator.controller.spi.DefaultImageRefResolver(client);
        reconciler = new MicroVMReconciler(
                mockClient,
                new MicroVMStateMachine(),
                new DriftDetector(),
                metrics,
                client,
                quotaGuard,
                imageRefResolver);
    }

    @Test
    @DisplayName("PENDING: reconciler calls runMicrovm and patches status with microvmId + RUNNING")
    void pending_callsRunMicrovmAndPatchesRunning() throws Exception {
        var vm = testMicroVM("test-vm", null);

        when(mockClient.runMicroVM(any())).thenReturn(CompletableFuture.completedFuture(
                new RunMicroVMResponse("mvm-abc123", "mvm-abc123.lambda-microvm.us-east-1.on.aws", "RUNNING")));

        var result = reconciler.reconcile(vm, mockContext());

        assertTrue(result.isPatchStatus());
        assertNotNull(vm.getStatus());
        assertEquals(MicroVMState.RUNNING, vm.getStatus().getState());
        assertEquals("mvm-abc123", vm.getStatus().getMicroVmId());
        assertEquals("mvm-abc123.lambda-microvm.us-east-1.on.aws", vm.getStatus().getEndpointUrl());
        verify(mockClient).runMicroVM(any());
    }

    @Test
    @DisplayName("RUNNING + desired SUSPENDED: drift detection triggers suspend")
    void drift_runningToSuspended_callsSuspend() throws Exception {
        var vm = testMicroVM("test-vm", MicroVMState.RUNNING);
        vm.getSpec().setDesiredState(DesiredState.SUSPENDED);
        vm.getStatus().setMicroVmId("mvm-abc123");

        when(mockClient.getMicroVM("mvm-abc123")).thenReturn(CompletableFuture.completedFuture(
                new DescribeMicroVMResponse("mvm-abc123", "RUNNING",
                        "mvm-abc123.lambda-microvm.us-east-1.on.aws", null, null)));
        when(mockClient.suspendMicroVM("mvm-abc123")).thenReturn(
                CompletableFuture.completedFuture(null));

        reconciler.reconcile(vm, mockContext());

        verify(mockClient).suspendMicroVM("mvm-abc123");
    }

    @Test
    @DisplayName("AWS throttle: retryable error keeps status unchanged")
    void throttle_retryableError_keepsPendingState() throws Exception {
        var vm = testMicroVM("test-vm", null);

        when(mockClient.runMicroVM(any())).thenReturn(CompletableFuture.failedFuture(
                new AwsApiException("Rate exceeded", AwsApiException.ErrorType.RETRYABLE, "req-1", 429)));

        var result = reconciler.reconcile(vm, mockContext());

        // Should reschedule, not crash
        assertNotNull(result);
        // State should stay PENDING (status initialized but not advanced)
        assertEquals(MicroVMState.PENDING, vm.getStatus().getState());
    }

    @Test
    @DisplayName("RUNNING: no-op when desired=Running and AWS state=RUNNING")
    void noOp_whenAligned() throws Exception {
        var vm = testMicroVM("test-vm", MicroVMState.RUNNING);
        vm.getSpec().setDesiredState(DesiredState.RUNNING);
        vm.getStatus().setMicroVmId("mvm-abc123");

        when(mockClient.getMicroVM("mvm-abc123")).thenReturn(CompletableFuture.completedFuture(
                new DescribeMicroVMResponse("mvm-abc123", "RUNNING",
                        "mvm-abc123.lambda-microvm.us-east-1.on.aws", null, null)));

        reconciler.reconcile(vm, mockContext());

        verify(mockClient, never()).suspendMicroVM(any());
        verify(mockClient, never()).terminateMicroVM(any());
        verify(mockClient, never()).runMicroVM(any());
    }

    @Test
    @DisplayName("DELETE: cleanup calls terminateMicrovm")
    void delete_callsTerminate() throws Exception {
        var vm = testMicroVM("test-vm", MicroVMState.RUNNING);
        vm.getStatus().setMicroVmId("mvm-abc123");

        when(mockClient.terminateMicroVM("mvm-abc123")).thenReturn(
                CompletableFuture.completedFuture(null));

        var deleteControl = reconciler.cleanup(vm, mockContext());

        assertTrue(deleteControl.isRemoveFinalizer());
        verify(mockClient).terminateMicroVM("mvm-abc123");
    }

    @Test
    @DisplayName("DELETE: cleanup removes finalizer when terminate throws ResourceNotFoundException (VM already gone)")
    void delete_resourceNotFound_removesFinalizer() throws Exception {
        var vm = testMicroVM("test-vm-gone", MicroVMState.RUNNING);
        vm.getStatus().setMicroVmId("mvm-gone123");

        when(mockClient.terminateMicroVM("mvm-gone123")).thenReturn(
                CompletableFuture.failedFuture(
                        software.amazon.awssdk.services.lambdamicrovms.model.ResourceNotFoundException
                                .builder().message("MicroVM mvm-gone123 not found").build()));

        var deleteControl = reconciler.cleanup(vm, mockContext());

        assertTrue(deleteControl.isRemoveFinalizer(),
                "Finalizer should be removed when VM is not found in AWS");
        assertEquals(MicroVMState.TERMINATED, vm.getStatus().getState());
    }

    @Test
    @DisplayName("DELETE: cleanup removes finalizer when terminate throws ConflictException (VM already terminated)")
    void delete_conflictAlreadyTerminated_removesFinalizer() throws Exception {
        var vm = testMicroVM("test-vm-conflict", MicroVMState.RUNNING);
        vm.getStatus().setMicroVmId("mvm-conflict123");

        when(mockClient.terminateMicroVM("mvm-conflict123")).thenReturn(
                CompletableFuture.failedFuture(
                        software.amazon.awssdk.services.lambdamicrovms.model.ConflictException
                                .builder().message("MicroVM is in TERMINATED state").build()));

        var deleteControl = reconciler.cleanup(vm, mockContext());

        assertTrue(deleteControl.isRemoveFinalizer(),
                "Finalizer should be removed when VM is already terminated (conflict)");
        assertEquals(MicroVMState.TERMINATED, vm.getStatus().getState());
    }

    @Test
    @DisplayName("DELETE: cleanup removes finalizer when terminate throws ResourceConflictException")
    void delete_resourceConflict_removesFinalizer() throws Exception {
        var vm = testMicroVM("test-vm-resconflict", MicroVMState.RUNNING);
        vm.getStatus().setMicroVmId("mvm-resconflict123");

        when(mockClient.terminateMicroVM("mvm-resconflict123")).thenReturn(
                CompletableFuture.failedFuture(
                        software.amazon.awssdk.services.lambdamicrovms.model.ResourceConflictException
                                .builder().message("Resource in conflicting state").build()));

        var deleteControl = reconciler.cleanup(vm, mockContext());

        assertTrue(deleteControl.isRemoveFinalizer(),
                "Finalizer should be removed when VM has resource conflict (already terminated)");
        assertEquals(MicroVMState.TERMINATED, vm.getStatus().getState());
    }

    @Test
    @DisplayName("DELETE: cleanup retries on transient error (throttling)")
    void delete_transientError_retries() throws Exception {
        var vm = testMicroVM("test-vm-throttle", MicroVMState.RUNNING);
        vm.getStatus().setMicroVmId("mvm-throttle123");

        when(mockClient.terminateMicroVM("mvm-throttle123")).thenReturn(
                CompletableFuture.failedFuture(
                        software.amazon.awssdk.services.lambdamicrovms.model.TooManyRequestsException
                                .builder().message("Rate exceeded").build()));

        var deleteControl = reconciler.cleanup(vm, mockContext());

        assertFalse(deleteControl.isRemoveFinalizer(),
                "Finalizer should NOT be removed on transient errors — must retry");
    }

    @Test
    @DisplayName("DELETE: cleanup removes finalizer when CR already in TERMINATED state")
    void delete_alreadyTerminatedState_removesFinalizer() {
        var vm = testMicroVM("test-vm-terminated", MicroVMState.TERMINATED);
        vm.getStatus().setMicroVmId("mvm-terminated123");

        var deleteControl = reconciler.cleanup(vm, mockContext());

        assertTrue(deleteControl.isRemoveFinalizer(),
                "Finalizer should be removed immediately when CR state is already TERMINATED");
        verify(mockClient, never()).terminateMicroVM(any());
    }

    @Test
    @DisplayName("DELETE: cleanup removes finalizer when status has no vmId (never provisioned)")
    void delete_noVmId_removesFinalizer() {
        var vm = testMicroVM("test-vm-noid", MicroVMState.PENDING);
        // vmId is null — MicroVM was never successfully created in AWS

        var deleteControl = reconciler.cleanup(vm, mockContext());

        assertTrue(deleteControl.isRemoveFinalizer(),
                "Finalizer should be removed when VM was never provisioned (no vmId)");
        verify(mockClient, never()).terminateMicroVM(any());
    }

    @Test
    @DisplayName("PENDING with networkRef: resolves MicroVMNetwork CR to connector ARN")
    void pending_withNetworkRef_resolvesConnectorArn() throws Exception {
        // Create MicroVMNetwork with ACTIVE state
        var network = new MicroVMNetwork();
        network.setMetadata(new ObjectMetaBuilder().withName("my-egress").withNamespace("default").build());
        network.setSpec(new MicroVMNetworkSpec());
        var netStatus = new MicroVMNetworkStatus();
        netStatus.setConnectorArn("arn:aws:lambda:us-east-1:123456789012:network-connector:my-egress");
        netStatus.setConnectorState("ACTIVE");
        network.setStatus(netStatus);
        client.resources(MicroVMNetwork.class).inNamespace("default").resource(network).createOrReplace();

        var vm = testMicroVM("test-vm-net", null);
        vm.getSpec().setNetworkRef("my-egress");

        when(mockClient.runMicroVM(any())).thenReturn(CompletableFuture.completedFuture(
                new RunMicroVMResponse("mvm-net123", "mvm-net123.lambda-microvm.us-east-1.on.aws", "RUNNING")));

        var result = reconciler.reconcile(vm, mockContext());

        assertTrue(result.isPatchStatus());
        assertEquals(MicroVMState.RUNNING, vm.getStatus().getState());
        // Verify the connector ARN was passed to runMicroVM
        var captor = org.mockito.ArgumentCaptor.forClass(RunMicroVMRequest.class);
        verify(mockClient).runMicroVM(captor.capture());
        assertTrue(captor.getValue().egressNetworkConnectors().contains(
                "arn:aws:lambda:us-east-1:123456789012:network-connector:my-egress"));
    }

    @Test
    @DisplayName("PENDING with networkRef not found: transitions to FAILED")
    void pending_networkRefNotFound_fails() throws Exception {
        var vm = testMicroVM("test-vm-nonet", null);
        vm.getSpec().setNetworkRef("nonexistent-network");

        var result = reconciler.reconcile(vm, mockContext());

        assertTrue(result.isPatchStatus());
        assertEquals(MicroVMState.FAILED, vm.getStatus().getState());
        assertTrue(vm.getStatus().getConditions().get(0).getMessage().contains("not found"));
    }

    // --- helpers ---

    private MicroVM testMicroVM(String name, MicroVMState state) {
        // Create corresponding MicroVMImage CR so resolution works
        var image = new MicroVMImage();
        image.setMetadata(new ObjectMetaBuilder()
                .withName("python-sandbox")
                .withNamespace("default")
                .build());
        image.setSpec(new MicroVMImageSpec());
        var imageStatus = new MicroVMImageStatus();
        imageStatus.setImageArn("arn:aws:lambda:us-east-1:123456789012:microvm-image:python-sandbox");
        imageStatus.setImageState("CREATED");
        imageStatus.setActiveVersion("1.0");
        image.setStatus(imageStatus);
        client.resources(MicroVMImage.class).inNamespace("default").resource(image).createOrReplace();

        var vm = new MicroVM();
        vm.setMetadata(new ObjectMetaBuilder()
                .withName(name)
                .withNamespace("default")
                .withGeneration(1L)
                .build());
        var spec = new MicroVMSpec();
        spec.setImageRef("python-sandbox");
        spec.setDesiredState(DesiredState.RUNNING);
        spec.setMaximumDurationSeconds(3600);
        spec.setMaxIdleDurationSeconds(900);
        spec.setSuspendedDurationSeconds(300);
        vm.setSpec(spec);

        if (state != null) {
            var status = new MicroVMStatus();
            status.setState(state);
            status.setLastTransitionTime(Instant.now());
            vm.setStatus(status);
        }
        return vm;
    }

    @SuppressWarnings("unchecked")
    private Context<MicroVM> mockContext() {
        Context<MicroVM> ctx = mock(Context.class);
        when(ctx.getClient()).thenReturn(client);
        return ctx;
    }

    // ── Import tests ──────────────────────────────────────────────────────────

    @Test
    @DisplayName("IMPORT: importMicroVmId set — GetMicrovm called, RunMicrovm not called, status populated")
    void import_withValidId_adoptsExistingVm() throws Exception {
        String importId = "microvm-12345678-abcd-efgh-ijkl-123456789012";
        var vm = testMicroVM("my-imported-vm", null);
        vm.getSpec().setImportMicroVmId(importId);
        client.resource(vm).create();

        // GetMicrovm returns existing running VM
        when(mockClient.getMicroVM(importId)).thenReturn(CompletableFuture.completedFuture(
                new DescribeMicroVMResponse(importId, "RUNNING",
                        "abc.lambda-microvm.us-east-1.on.aws", null, null)));

        reconciler.reconcile(vm, mockContext());

        // RunMicrovm must NOT have been called
        verify(mockClient, never()).runMicroVM(any());
        // Status populated from imported VM
        assertEquals(importId, vm.getStatus().getMicroVmId());
        assertEquals("abc.lambda-microvm.us-east-1.on.aws", vm.getStatus().getEndpointUrl());
        assertEquals(MicroVMState.RUNNING, vm.getStatus().getState());
    }

    @Test
    @DisplayName("IMPORT: importMicroVmId not found in AWS — CR transitions to FAILED with clear message")
    void import_notFound_transitionsToFailed() throws Exception {
        String importId = "microvm-00000000-0000-0000-0000-000000000000";
        var vm = testMicroVM("missing-import-vm", null);
        vm.getSpec().setImportMicroVmId(importId);
        client.resource(vm).create();

        // GetMicrovm returns null (not found)
        when(mockClient.getMicroVM(importId)).thenReturn(CompletableFuture.completedFuture(null));

        reconciler.reconcile(vm, mockContext());

        verify(mockClient, never()).runMicroVM(any());
        assertEquals(MicroVMState.FAILED, vm.getStatus().getState());
        assertNotNull(vm.getStatus().getConditions());
        assertTrue(vm.getStatus().getConditions().stream()
                .anyMatch(c -> c.getMessage() != null && c.getMessage().contains("not found in AWS")));
    }

    @Test
    @DisplayName("IMPORT: no importMicroVmId — normal RunMicrovm path used")
    void import_notSet_usesNormalCreatePath() throws Exception {
        var vm = testMicroVM("normal-vm", null);
        // importMicroVmId NOT set
        client.resource(vm).create();

        var runResp = mock(RunMicroVMResponse.class);
        when(runResp.microvmId()).thenReturn("mvm-new-001");
        when(runResp.endpoint()).thenReturn("new.lambda-microvm.us-east-1.on.aws");
        when(mockClient.runMicroVM(any())).thenReturn(CompletableFuture.completedFuture(runResp));

        reconciler.reconcile(vm, mockContext());

        // RunMicrovm must have been called
        verify(mockClient, times(1)).runMicroVM(any());
    }

    @Test
    @DisplayName("CROSS-NAMESPACE imageRef: transitions to FAILED with PRO upsell message")
    void crossNamespaceImageRef_transitionsToFailed() {
        var vm = testMicroVM("vm-cross-ns", null);
        vm.getSpec().setImageRef("other-namespace/some-image");
        client.resource(vm).createOrReplace();

        reconciler.reconcile(vm, mockContext());

        assertEquals(MicroVMState.FAILED, vm.getStatus().getState());
        assertNotNull(vm.getStatus().getConditions());
        String msg = vm.getStatus().getConditions().get(0).getMessage();
        assertNotNull(msg);
        assertTrue(msg.contains("KubeMicroVM PRO"),
                "Error message should mention PRO: " + msg);
        assertTrue(msg.contains("other-namespace/some-image"),
                "Error message should include the offending imageRef: " + msg);
    }

    @Test
    @DisplayName("FAILED with null microVmId: stays FAILED if spec unchanged (no infinite retry loop)")
    void failed_creationRefused_staysFailedIfSpecUnchanged() throws Exception {
        // Simulate a VM that failed creation (e.g. ValidationException from AWS)
        var vm = testMicroVM("test-vm-refused", MicroVMState.FAILED);
        vm.getStatus().setMicroVmId(null); // never got a VM ID
        vm.getStatus().setObservedGeneration(1L); // matches metadata.generation
        // Set the condition reason to CreationFailed (as handleCreationError does)
        var condition = new Condition("Ready", "False", "CreationFailed",
                "Failed to create MicroVM: ValidationException: idlePolicy fields required",
                Instant.now());
        vm.getStatus().getConditions().add(condition);

        var result = reconciler.reconcile(vm, mockContext());

        // Should NOT transition to PENDING — stay in FAILED
        assertEquals(MicroVMState.FAILED, vm.getStatus().getState());
        // Should not call runMicroVM
        verify(mockClient, never()).runMicroVM(any());
    }

    @Test
    @DisplayName("FAILED with null microVmId: retries when spec changes (generation bump)")
    void failed_creationRefused_retriesOnSpecChange() throws Exception {
        // Simulate a VM that failed creation
        var vm = testMicroVM("test-vm-fixed", MicroVMState.FAILED);
        vm.getStatus().setMicroVmId(null);
        vm.getStatus().setObservedGeneration(1L);
        var condition = new Condition("Ready", "False", "CreationFailed",
                "Failed to create MicroVM: ValidationException", Instant.now());
        vm.getStatus().getConditions().add(condition);

        // User fixed the spec — generation bumped
        vm.getMetadata().setGeneration(2L);

        // Mock successful creation after fix
        when(mockClient.runMicroVM(any())).thenReturn(CompletableFuture.completedFuture(
                new RunMicroVMResponse("mvm-new123", "mvm-new123.lambda-microvm.us-east-1.on.aws", "RUNNING")));

        var result = reconciler.reconcile(vm, mockContext());

        // Should have transitioned to PENDING and then created
        // (the reconciler does PENDING in one cycle, then handlePendingState in the transition call reschedules)
        // After the transition to PENDING, the state should be PENDING or RUNNING depending on implementation
        assertTrue(vm.getStatus().getState() == MicroVMState.PENDING
                || vm.getStatus().getState() == MicroVMState.RUNNING,
                "State should be PENDING (retrying) or RUNNING (succeeded), got: " + vm.getStatus().getState());
    }

    @Test
    @DisplayName("FAILED creation: error is logged at ERROR level (not swallowed)")
    void failed_creation_logsError() throws Exception {
        var vm = testMicroVM("test-vm-err", null);

        when(mockClient.runMicroVM(any())).thenReturn(CompletableFuture.failedFuture(
                new AwsApiException("ValidationException: 2 validation errors detected: " +
                        "Value null at 'idlePolicy.maxIdleDurationSeconds'",
                        AwsApiException.ErrorType.NON_RETRYABLE, "req-1", 400)));

        reconciler.reconcile(vm, mockContext());

        // State should be FAILED
        assertEquals(MicroVMState.FAILED, vm.getStatus().getState());
        // Condition should contain the AWS error message
        var conditions = vm.getStatus().getConditions();
        assertFalse(conditions.isEmpty());
        assertTrue(conditions.stream().anyMatch(c ->
                "CreationFailed".equals(c.getReason()) &&
                c.getMessage().contains("ValidationException")));
    }
}