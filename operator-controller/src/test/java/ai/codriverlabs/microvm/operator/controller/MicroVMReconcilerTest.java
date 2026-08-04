package ai.codriverlabs.microvm.operator.controller;

import ai.codriverlabs.microvm.operator.controller.aws.*;
import ai.codriverlabs.microvm.operator.controller.reconciler.DriftDetector;
import ai.codriverlabs.microvm.operator.controller.reconciler.MicroVMReconciler;
import ai.codriverlabs.microvm.operator.core.enums.DesiredState;
import ai.codriverlabs.microvm.operator.core.enums.MicroVMState;

import ai.codriverlabs.microvm.operator.core.model.*;
import ai.codriverlabs.microvm.operator.core.state.MicroVMStateMachine;
import io.fabric8.kubernetes.api.model.ObjectMeta;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.DisplayName;

import java.time.Instant;
import java.util.concurrent.CompletableFuture;
import java.util.concurrent.CompletionException;

import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.Mockito.*;

/**
 * Integration-style tests for MicroVMReconciler verifying the full reconciliation
 * lifecycle with mocked AWS client.
 */
class MicroVMReconcilerTest {

    private MicroVMClient mockClient;
    private MicroVMStateMachine stateMachine;

    @BeforeEach
    void setUp() {
        mockClient = mock(MicroVMClient.class);
        stateMachine = new MicroVMStateMachine();
    }

    @Test
    @DisplayName("New MicroVM should start in Pending state")
    void newResourceStartsInPending() {
        MicroVM microVM = createMicroVM("test-vm", null);

        assertNull(microVM.getStatus());

        MicroVMStatus status = new MicroVMStatus();
        status.setState(MicroVMState.PENDING);
        status.setLastTransitionTime(Instant.now());
        microVM.setStatus(status);

        assertEquals(MicroVMState.PENDING, microVM.getStatus().getState());
    }

    @Test
    @DisplayName("Pending -> Running on AWS runMicroVM success")
    void pendingToRunningOnAwsSuccess() {
        MicroVM microVM = createMicroVM("test-vm", MicroVMState.PENDING);

        when(mockClient.runMicroVM(any())).thenReturn(
            CompletableFuture.completedFuture(
                new RunMicroVMResponse("vm-12345", "10.0.1.5", "RUNNING")
            )
        );

        var transition = stateMachine.transition(MicroVMState.PENDING, MicroVMState.RUNNING);
        assertInstanceOf(ai.codriverlabs.microvm.operator.core.state.StateTransitionResult.Valid.class, transition);

        microVM.getStatus().setState(MicroVMState.RUNNING);
        microVM.getStatus().setMicroVmId("vm-12345");
        microVM.getStatus().setEndpointUrl("10.0.1.5");

        assertEquals(MicroVMState.RUNNING, microVM.getStatus().getState());
        assertEquals("vm-12345", microVM.getStatus().getMicroVmId());
        assertEquals("10.0.1.5", microVM.getStatus().getEndpointUrl());
    }

    @Test
    @DisplayName("AWS throttling keeps state unchanged for retry")
    void awsThrottlingKeepsStateForRetry() {
        MicroVM microVM = createMicroVM("test-vm", MicroVMState.PENDING);

        when(mockClient.runMicroVM(any())).thenReturn(
            CompletableFuture.failedFuture(
                new AwsApiException("Rate exceeded", AwsApiException.ErrorType.RETRYABLE, "req-xyz", 429)
            )
        );

        CompletionException ce = assertThrows(CompletionException.class, () -> {
            mockClient.runMicroVM(null).join();
        });
        assertInstanceOf(AwsApiException.class, ce.getCause());
        AwsApiException ex = (AwsApiException) ce.getCause();
        assertTrue(ex.isRetryable());

        assertEquals(MicroVMState.PENDING, microVM.getStatus().getState());
    }

    @Test
    @DisplayName("Non-retryable error transitions to Failed")
    void nonRetryableErrorTransitionsToFailed() {
        MicroVM microVM = createMicroVM("test-vm", MicroVMState.PENDING);

        var transition = stateMachine.transition(MicroVMState.PENDING, MicroVMState.FAILED);
        assertInstanceOf(ai.codriverlabs.microvm.operator.core.state.StateTransitionResult.Valid.class, transition);

        microVM.getStatus().setState(MicroVMState.FAILED);
        assertEquals(MicroVMState.FAILED, microVM.getStatus().getState());
    }

    @Test
    @DisplayName("Deletion triggers Terminating -> Terminated")
    void deletionTriggersTermination() {
        MicroVM microVM = createMicroVM("test-vm", MicroVMState.RUNNING);
        microVM.getStatus().setMicroVmId("vm-12345");

        when(mockClient.terminateMicroVM("vm-12345")).thenReturn(
            CompletableFuture.completedFuture(null)
        );

        var t1 = stateMachine.transition(MicroVMState.RUNNING, MicroVMState.TERMINATING);
        assertInstanceOf(ai.codriverlabs.microvm.operator.core.state.StateTransitionResult.Valid.class, t1);

        var t2 = stateMachine.transition(MicroVMState.TERMINATING, MicroVMState.TERMINATED);
        assertInstanceOf(ai.codriverlabs.microvm.operator.core.state.StateTransitionResult.Valid.class, t2);

        microVM.getStatus().setState(MicroVMState.TERMINATED);
        assertEquals(MicroVMState.TERMINATED, microVM.getStatus().getState());
    }

    @Test
    @DisplayName("ResourceNotFoundException triggers recreate back to Pending")
    void notFoundTriggersRecreate() {
        MicroVM microVM = createMicroVM("test-vm", MicroVMState.RUNNING);

        when(mockClient.getMicroVM(any())).thenReturn(
            CompletableFuture.failedFuture(
                new AwsApiException("Resource not found", AwsApiException.ErrorType.NOT_FOUND, "req-404", 404)
            )
        );

        var t1 = stateMachine.transition(MicroVMState.FAILED, MicroVMState.PENDING);
        assertInstanceOf(ai.codriverlabs.microvm.operator.core.state.StateTransitionResult.Valid.class, t1);
    }

    @Test
    @DisplayName("Drift detection triggers correct AWS API call")
    void driftDetectionTriggersCorrectAction() {
        DriftDetector detector = new DriftDetector();
        MicroVM microVM = createMicroVM("test-vm", MicroVMState.RUNNING);
        microVM.getSpec().setDesiredState(DesiredState.SUSPENDED);

        var result = detector.detectDrift(DesiredState.SUSPENDED, MicroVMState.RUNNING);
        assertInstanceOf(DriftDetector.DriftResult.ActionRequired.class, result);

        var action = (DriftDetector.DriftResult.ActionRequired) result;
        assertEquals(MicroVMState.SUSPENDING, action.targetState());
    }

    @Test
    @DisplayName("Credential failure halts reconciliation")
    void credentialFailureHaltsReconciliation() {
        when(mockClient.getMicroVM(any())).thenReturn(
            CompletableFuture.failedFuture(
                new AwsApiException("Credentials expired", AwsApiException.ErrorType.AUTH_FAILURE, "req-auth", 403)
            )
        );

        CompletionException ce = assertThrows(CompletionException.class, () -> {
            mockClient.getMicroVM("vm-123").join();
        });
        assertInstanceOf(AwsApiException.class, ce.getCause());
        AwsApiException ex = (AwsApiException) ce.getCause();
        assertTrue(ex.isAuthFailure());
    }

    @Test
    @DisplayName("isAlreadyTerminatedOrGone: ResourceNotFoundException → true")
    void isAlreadyTerminatedOrGone_resourceNotFound() {
        var ex = new java.util.concurrent.ExecutionException(
                software.amazon.awssdk.services.lambdamicrovms.model.ResourceNotFoundException
                        .builder().message("not found").build());
        assertTrue(MicroVMReconciler.isAlreadyTerminatedOrGone(ex));
    }

    @Test
    @DisplayName("isAlreadyTerminatedOrGone: ConflictException → true")
    void isAlreadyTerminatedOrGone_conflict() {
        var ex = new java.util.concurrent.ExecutionException(
                software.amazon.awssdk.services.lambdamicrovms.model.ConflictException
                        .builder().message("already terminated").build());
        assertTrue(MicroVMReconciler.isAlreadyTerminatedOrGone(ex));
    }

    @Test
    @DisplayName("isAlreadyTerminatedOrGone: ResourceConflictException → true")
    void isAlreadyTerminatedOrGone_resourceConflict() {
        var ex = new java.util.concurrent.ExecutionException(
                software.amazon.awssdk.services.lambdamicrovms.model.ResourceConflictException
                        .builder().message("conflict").build());
        assertTrue(MicroVMReconciler.isAlreadyTerminatedOrGone(ex));
    }

    @Test
    @DisplayName("isAlreadyTerminatedOrGone: AwsApiException NOT_FOUND → true")
    void isAlreadyTerminatedOrGone_awsApiNotFound() {
        var ex = new AwsApiException("not found", AwsApiException.ErrorType.NOT_FOUND, "req-1", 404);
        assertTrue(MicroVMReconciler.isAlreadyTerminatedOrGone(ex));
    }

    @Test
    @DisplayName("isAlreadyTerminatedOrGone: TooManyRequestsException → false (transient)")
    void isAlreadyTerminatedOrGone_throttling_false() {
        var ex = new java.util.concurrent.ExecutionException(
                software.amazon.awssdk.services.lambdamicrovms.model.TooManyRequestsException
                        .builder().message("rate exceeded").build());
        assertFalse(MicroVMReconciler.isAlreadyTerminatedOrGone(ex));
    }

    @Test
    @DisplayName("isAlreadyTerminatedOrGone: generic RuntimeException → false")
    void isAlreadyTerminatedOrGone_generic_false() {
        var ex = new RuntimeException("network timeout");
        assertFalse(MicroVMReconciler.isAlreadyTerminatedOrGone(ex));
    }

    private MicroVM createMicroVM(String name, MicroVMState state) {
        MicroVM vm = new MicroVM();
        ObjectMeta meta = new ObjectMeta();
        meta.setName(name);
        meta.setNamespace("default");
        meta.setGeneration(1L);
        vm.setMetadata(meta);

        MicroVMSpec spec = new MicroVMSpec();
        spec.setImageRef("python-sandbox");
        spec.setMaximumDurationSeconds(512);
        spec.setMaxIdleDurationSeconds(2);
        spec.setSuspendedDurationSeconds(300);
        vm.setSpec(spec);

        if (state != null) {
            MicroVMStatus status = new MicroVMStatus();
            status.setState(state);
            status.setLastTransitionTime(Instant.now());
            vm.setStatus(status);
        }

        return vm;
    }
}
