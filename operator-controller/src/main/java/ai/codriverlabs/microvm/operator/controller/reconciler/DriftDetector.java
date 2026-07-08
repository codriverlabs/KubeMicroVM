package ai.codriverlabs.microvm.operator.controller.reconciler;

import ai.codriverlabs.microvm.operator.core.enums.DesiredState;
import ai.codriverlabs.microvm.operator.core.enums.MicroVMState;
import jakarta.enterprise.context.ApplicationScoped;

/**
 * Detects drift between desired state (CR spec) and actual AWS state.
 * Aligned with AWS Lambda MicroVMs API lifecycle (no stop/pause — only suspend/resume/terminate).
 */
@ApplicationScoped
public class DriftDetector {

    public enum DriftAction {
        RECREATE, SUSPEND, RESUME, TERMINATE, NO_OP
    }

    public sealed interface DriftResult {
        record NoOp(String reason) implements DriftResult {}
        record ActionRequired(DriftAction action, MicroVMState targetState) implements DriftResult {}
        record Error(String reason) implements DriftResult {}
    }

    public DriftResult detectDrift(DesiredState desired, MicroVMState actual) {
        return detectDrift(desired, actual, false);
    }

    /**
     * Detects drift between desired state and actual AWS state.
     *
     * @param desired         the desired state from spec
     * @param actual          the actual state from AWS
     * @param autoResumeEnabled whether the VM's idle policy will auto-resume it.
     *                        When true and the VM is Suspended with desired=Running,
     *                        the operator does NOT call ResumeMicrovm — the idle policy
     *                        handles resume when traffic arrives.
     *                        When false, the operator manages suspend/resume explicitly.
     */
    public DriftResult detectDrift(DesiredState desired, MicroVMState actual, boolean autoResumeEnabled) {
        if (desired == null) return new DriftResult.Error("desiredState is null");
        if (actual == null) return new DriftResult.Error("actual state is null");

        return switch (desired) {
            case RUNNING -> detectRunningDrift(actual, autoResumeEnabled);
            case SUSPENDED -> detectSuspendedDrift(actual);
            case TERMINATED -> detectTerminatedDrift(actual);
        };
    }

    private DriftResult detectRunningDrift(MicroVMState actual, boolean autoResumeEnabled) {
        return switch (actual) {
            case RUNNING -> new DriftResult.NoOp("Aligned: Running");
            case PENDING -> new DriftResult.NoOp("Transitional: provisioning in progress");
            case SUSPENDING -> new DriftResult.NoOp("Transitional: suspending (idle policy or explicit suspend)");
            case SUSPENDED -> {
                if (autoResumeEnabled) {
                    // Idle policy owns resume — do not fight it.
                    // Status updated; VM will auto-resume when traffic arrives.
                    yield new DriftResult.NoOp("Auto-suspended by idle policy; auto-resume enabled");
                }
                // autoResumeEnabled=false: user controls lifecycle via desiredState.
                // desiredState=Running while actual=Suspended → call ResumeMicrovm.
                yield new DriftResult.ActionRequired(DriftAction.RESUME, MicroVMState.RUNNING);
            }
            case TERMINATED -> new DriftResult.ActionRequired(DriftAction.RECREATE, MicroVMState.PENDING);
            case FAILED -> new DriftResult.ActionRequired(DriftAction.RECREATE, MicroVMState.PENDING);
            case TERMINATING -> new DriftResult.Error("Cannot resume: termination in progress");
        };
    }

    private DriftResult detectSuspendedDrift(MicroVMState actual) {
        return switch (actual) {
            case SUSPENDED -> new DriftResult.NoOp("Aligned: Suspended");
            case SUSPENDING -> new DriftResult.NoOp("Transitional: suspending");
            case RUNNING -> new DriftResult.ActionRequired(DriftAction.SUSPEND, MicroVMState.SUSPENDING);
            case PENDING -> new DriftResult.NoOp("Transitional: provisioning (will suspend after running)");
            case TERMINATED -> new DriftResult.Error("Cannot suspend a terminated MicroVM");
            case TERMINATING -> new DriftResult.Error("Cannot suspend: termination in progress");
            case FAILED -> new DriftResult.Error("Cannot suspend a failed MicroVM");
        };
    }

    private DriftResult detectTerminatedDrift(MicroVMState actual) {
        return switch (actual) {
            case TERMINATED -> new DriftResult.NoOp("Aligned: Terminated");
            case TERMINATING -> new DriftResult.NoOp("Transitional: terminating");
            case RUNNING -> new DriftResult.ActionRequired(DriftAction.TERMINATE, MicroVMState.TERMINATING);
            case SUSPENDED -> new DriftResult.ActionRequired(DriftAction.TERMINATE, MicroVMState.TERMINATING);
            case PENDING -> new DriftResult.ActionRequired(DriftAction.TERMINATE, MicroVMState.TERMINATING);
            case SUSPENDING -> new DriftResult.NoOp("Transitional: will terminate after suspend completes");
            case FAILED -> new DriftResult.ActionRequired(DriftAction.TERMINATE, MicroVMState.TERMINATING);
        };
    }
}
