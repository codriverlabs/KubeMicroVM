package ai.codriverlabs.microvm.operator.controller;

import ai.codriverlabs.microvm.operator.core.enums.DesiredState;
import ai.codriverlabs.microvm.operator.core.enums.MicroVMState;
import ai.codriverlabs.microvm.operator.controller.reconciler.DriftDetector;
import ai.codriverlabs.microvm.operator.controller.reconciler.DriftDetector.DriftResult;
import net.jqwik.api.*;

import static ai.codriverlabs.microvm.operator.core.enums.MicroVMState.*;

/**
 * Feature: kube-microvm-operator, Property 12: Drift Detection Correctness
 * Validates: Requirements 3.4, 3.5
 */
class DriftDetectionPropertyTest {

    private final DriftDetector detector = new DriftDetector();

    // When desired == actual (aligned), no action needed
    @Property(tries = 100)
    void alignedStatesProduceNoOp(@ForAll("alignedPairs") DesiredActualPair pair) {
        DriftResult result = detector.detectDrift(pair.desired(), pair.actual());
        assert result instanceof DriftResult.NoOp :
            "Aligned state " + pair.desired() + "/" + pair.actual() + " should produce NoOp, got: " + result;
    }

    // When desired != actual and not transitional, drift should be detected (action or error)
    @Property(tries = 100)
    void mismatchedStableStatesProduceDrift(@ForAll("driftPairs") DesiredActualPair pair) {
        DriftResult result = detector.detectDrift(pair.desired(), pair.actual());
        assert result instanceof DriftResult.ActionRequired :
            "Mismatched " + pair.desired() + "/" + pair.actual() + " should produce ActionRequired, got: " + result;
    }

    // Transitional states moving toward desired produce NoOp (already in progress)
    @Property(tries = 100)
    void transitionalStatesMovingTowardDesiredProduceNoOp(
            @ForAll("transitionalTowardDesiredPairs") DesiredActualPair pair) {
        DriftResult result = detector.detectDrift(pair.desired(), pair.actual());
        assert result instanceof DriftResult.NoOp :
            "Transitional state " + pair.actual() + " toward " + pair.desired() +
            " should produce NoOp, got: " + result;
    }

    // Null inputs always produce error
    @Property(tries = 10)
    void nullDesiredAlwaysProducesError(@ForAll("allStates") MicroVMState actual) {
        DriftResult result = detector.detectDrift(null, actual);
        assert result instanceof DriftResult.Error :
            "Null desired with actual=" + actual + " should produce Error, got: " + result;
    }

    @Property(tries = 10)
    void nullActualAlwaysProducesError(@ForAll("desiredStates") DesiredState desired) {
        DriftResult result = detector.detectDrift(desired, null);
        assert result instanceof DriftResult.Error :
            "Desired=" + desired + " with null actual should produce Error, got: " + result;
    }

    @Provide
    Arbitrary<DesiredActualPair> alignedPairs() {
        return Arbitraries.of(
            new DesiredActualPair(DesiredState.RUNNING, RUNNING),
            new DesiredActualPair(DesiredState.SUSPENDED, SUSPENDED),
            new DesiredActualPair(DesiredState.SUSPENDED, SUSPENDED)
        );
    }

    @Provide
    Arbitrary<DesiredActualPair> driftPairs() {
        return Arbitraries.of(
            // RUNNING+SUSPENDED: autoResumeEnabled=false → ActionRequired(RESUME)
            new DesiredActualPair(DesiredState.RUNNING, SUSPENDED),
            new DesiredActualPair(DesiredState.RUNNING, TERMINATED),
            new DesiredActualPair(DesiredState.SUSPENDED, RUNNING),
            new DesiredActualPair(DesiredState.TERMINATED, RUNNING),
            new DesiredActualPair(DesiredState.TERMINATED, SUSPENDED),
            new DesiredActualPair(DesiredState.RUNNING, FAILED)
        );
    }

    @Provide
    Arbitrary<DesiredActualPair> transitionalTowardDesiredPairs() {
        return Arbitraries.of(
            // PENDING, RUNNING, RUNNING are transitional toward RUNNING
            new DesiredActualPair(DesiredState.RUNNING, PENDING),
            new DesiredActualPair(DesiredState.RUNNING, RUNNING),
            new DesiredActualPair(DesiredState.RUNNING, RUNNING),
            // SUSPENDING is transitional toward SUSPENDED
            new DesiredActualPair(DesiredState.SUSPENDED, SUSPENDING)
        );
    }

    @Provide
    Arbitrary<DesiredState> desiredStates() {
        return Arbitraries.of(DesiredState.values());
    }

    @Provide
    Arbitrary<MicroVMState> allStates() {
        return Arbitraries.of(MicroVMState.values());
    }

    record DesiredActualPair(DesiredState desired, MicroVMState actual) {}
}
