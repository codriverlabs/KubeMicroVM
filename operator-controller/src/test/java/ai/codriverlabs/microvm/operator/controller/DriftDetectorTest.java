package ai.codriverlabs.microvm.operator.controller;

import ai.codriverlabs.microvm.operator.core.enums.DesiredState;
import ai.codriverlabs.microvm.operator.core.enums.MicroVMState;
import ai.codriverlabs.microvm.operator.controller.reconciler.DriftDetector;
import ai.codriverlabs.microvm.operator.controller.reconciler.DriftDetector.DriftAction;
import ai.codriverlabs.microvm.operator.controller.reconciler.DriftDetector.DriftResult;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;

import static org.junit.jupiter.api.Assertions.*;

class DriftDetectorTest {

    private DriftDetector detector;

    @BeforeEach
    void setUp() {
        detector = new DriftDetector();
    }

    @Test
    void nullDesiredStateReturnsError() {
        DriftResult result = detector.detectDrift(null, MicroVMState.RUNNING);
        assertInstanceOf(DriftResult.Error.class, result);
    }

    @Test
    void nullActualStateReturnsError() {
        DriftResult result = detector.detectDrift(DesiredState.RUNNING, null);
        assertInstanceOf(DriftResult.Error.class, result);
    }

    @Test
    void runningWithDesiredRunningReturnsNoOp() {
        DriftResult result = detector.detectDrift(DesiredState.RUNNING, MicroVMState.RUNNING);
        assertInstanceOf(DriftResult.NoOp.class, result);
    }

    @Test
    void suspendedWithDesiredSuspendedReturnsNoOp() {
        DriftResult result = detector.detectDrift(DesiredState.SUSPENDED, MicroVMState.SUSPENDED);
        assertInstanceOf(DriftResult.NoOp.class, result);
    }

    @Test
    void runningWithDesiredSuspendedReturnsSuspendAction() {
        DriftResult result = detector.detectDrift(DesiredState.SUSPENDED, MicroVMState.RUNNING);
        assertInstanceOf(DriftResult.ActionRequired.class, result);
        DriftResult.ActionRequired action = (DriftResult.ActionRequired) result;
        assertEquals(DriftAction.SUSPEND, action.action());
    }

    @Test
    void suspendedWithDesiredRunningReturnsResumeAction() {
        DriftResult result = detector.detectDrift(DesiredState.RUNNING, MicroVMState.SUSPENDED);
        assertInstanceOf(DriftResult.ActionRequired.class, result);
        DriftResult.ActionRequired action = (DriftResult.ActionRequired) result;
        assertEquals(DriftAction.RESUME, action.action());
    }

    @Test
    void failedWithDesiredRunningReturnsRecreateAction() {
        DriftResult result = detector.detectDrift(DesiredState.RUNNING, MicroVMState.FAILED);
        assertInstanceOf(DriftResult.ActionRequired.class, result);
        DriftResult.ActionRequired action = (DriftResult.ActionRequired) result;
        assertEquals(DriftAction.RECREATE, action.action());
    }

    @Test
    void terminatedWithDesiredRunningReturnsRecreateAction() {
        DriftResult result = detector.detectDrift(DesiredState.RUNNING, MicroVMState.TERMINATED);
        assertInstanceOf(DriftResult.ActionRequired.class, result);
        DriftResult.ActionRequired action = (DriftResult.ActionRequired) result;
        assertEquals(DriftAction.RECREATE, action.action());
    }

    @Test
    void pendingWithDesiredRunningReturnsNoOp() {
        // PENDING is transitioning toward RUNNING, so no action needed
        DriftResult result = detector.detectDrift(DesiredState.RUNNING, MicroVMState.PENDING);
        assertInstanceOf(DriftResult.NoOp.class, result);
    }

    @Test
    void suspendingWithDesiredSuspendedReturnsNoOp() {
        // SUSPENDING is transitioning toward SUSPENDED
        DriftResult result = detector.detectDrift(DesiredState.SUSPENDED, MicroVMState.SUSPENDING);
        assertInstanceOf(DriftResult.NoOp.class, result);
    }

    @Test
    void terminatingWithDesiredRunningReturnsError() {
        // TERMINATING has no path to RUNNING - should return error
        DriftResult result = detector.detectDrift(DesiredState.RUNNING, MicroVMState.TERMINATING);
        assertInstanceOf(DriftResult.Error.class, result);
    }

    @Test
    void runningWithDesiredTerminatedReturnsTerminateAction() {
        DriftResult result = detector.detectDrift(DesiredState.TERMINATED, MicroVMState.RUNNING);
        assertInstanceOf(DriftResult.ActionRequired.class, result);
        DriftResult.ActionRequired action = (DriftResult.ActionRequired) result;
        assertEquals(DriftAction.TERMINATE, action.action());
    }

    @Test
    void terminatedWithDesiredTerminatedReturnsNoOp() {
        DriftResult result = detector.detectDrift(DesiredState.TERMINATED, MicroVMState.TERMINATED);
        assertInstanceOf(DriftResult.NoOp.class, result);
    }

    @Test
    void suspendedWithDesiredRunningAndAutoResumeEnabledReturnsNoOp() {
        // autoResumeEnabled=true: idle policy owns resume — operator must not fight it
        DriftResult result = detector.detectDrift(DesiredState.RUNNING, MicroVMState.SUSPENDED, true);
        assertInstanceOf(DriftResult.NoOp.class, result);
        assertTrue(((DriftResult.NoOp) result).reason().contains("idle policy"));
    }

    @Test
    void suspendedWithDesiredRunningAndAutoResumeDisabledReturnsResume() {
        // autoResumeEnabled=false: user controls lifecycle — operator resumes when desiredState=Running
        DriftResult result = detector.detectDrift(DesiredState.RUNNING, MicroVMState.SUSPENDED, false);
        assertInstanceOf(DriftResult.ActionRequired.class, result);
        assertEquals(DriftAction.RESUME, ((DriftResult.ActionRequired) result).action());
    }
}
