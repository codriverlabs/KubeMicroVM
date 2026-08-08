package ai.codriverlabs.microvm.operator.webhook.validation;


import ai.codriverlabs.microvm.operator.core.model.MicroVMSpec;
import ai.codriverlabs.microvm.operator.core.model.MicroVMImageSpec;
import ai.codriverlabs.microvm.operator.webhook.validation.MicroVMValidatingWebhook;
import net.jqwik.api.*;

import java.util.List;
import java.util.Set;

/**
 * Property-based tests for webhook validation.
 *
 * Property 1: imageRef required — null/blank always rejected
 * Property 2: memorySizeMiB — only {512, 1024, 2048, 4096, 8192} accepted
 * Property 3: memorySizeMiB immutability — changing from non-null to different non-null rejected
 */
class WebhookValidationPropertyTest {

    private static final Set<Integer> ALLOWED_MEMORY = Set.of(512, 1024, 2048, 4096, 8192);
    private final MicroVMValidatingWebhook webhook = new MicroVMValidatingWebhook();

    // Property 1: valid imageRef always passes (with required idle policy)
    @Property(tries = 50)
    void validImageRefAccepted(@ForAll("validImageRef") String imageRef) {
        MicroVMSpec spec = new MicroVMSpec();
        spec.setImageRef(imageRef);
        spec.setMaxIdleDurationSeconds(900);
        spec.setSuspendedDurationSeconds(1800);
        List<String> errors = webhook.validate(spec, "default");
        assert errors.isEmpty() : "Valid imageRef '" + imageRef + "' should be accepted, got: " + errors;
    }

    // Property 2a: allowed memorySizeMiB values always pass
    @Property(tries = 20)
    void allowedMemorySizeAccepted(@ForAll("allowedMemorySize") int memory) {
        MicroVMImageSpec spec = new MicroVMImageSpec();
        spec.setMemorySizeMiB(memory);
        List<String> errors = new java.util.ArrayList<>();
        webhook.validateMemorySizeMiB(spec, errors);
        assert errors.isEmpty() : "Allowed memory " + memory + " should pass, got: " + errors;
    }

    // Property 2b: disallowed memorySizeMiB values always rejected
    @Property(tries = 100)
    void disallowedMemorySizeRejected(@ForAll("disallowedMemorySize") int memory) {
        MicroVMImageSpec spec = new MicroVMImageSpec();
        spec.setMemorySizeMiB(memory);
        List<String> errors = new java.util.ArrayList<>();
        webhook.validateMemorySizeMiB(spec, errors);
        assert !errors.isEmpty() : "Disallowed memory " + memory + " should be rejected";
    }

    // Property 3: changing memorySizeMiB from value A to different value B is always rejected
    @Property(tries = 50)
    void memoryImmutabilityEnforced(
            @ForAll("allowedMemorySize") int oldMemory,
            @ForAll("allowedMemorySize") int newMemory) {
        Assume.that(oldMemory != newMemory);
        MicroVMImageSpec oldSpec = new MicroVMImageSpec();
        oldSpec.setMemorySizeMiB(oldMemory);
        MicroVMImageSpec newSpec = new MicroVMImageSpec();
        newSpec.setMemorySizeMiB(newMemory);
        List<String> errors = new java.util.ArrayList<>();
        webhook.validateMemoryImmutability(oldSpec, newSpec, errors);
        assert !errors.isEmpty() : "Changing " + oldMemory + " -> " + newMemory + " should be rejected";
    }

    // Property 3b: same value is always allowed
    @Property(tries = 20)
    void memorySameValueAllowed(@ForAll("allowedMemorySize") int memory) {
        MicroVMImageSpec oldSpec = new MicroVMImageSpec();
        oldSpec.setMemorySizeMiB(memory);
        MicroVMImageSpec newSpec = new MicroVMImageSpec();
        newSpec.setMemorySizeMiB(memory);
        List<String> errors = new java.util.ArrayList<>();
        webhook.validateMemoryImmutability(oldSpec, newSpec, errors);
        assert errors.isEmpty() : "Same value " + memory + " should be allowed";
    }

    @Provide
    Arbitrary<String> validImageRef() {
        return Arbitraries.of("my-image", "python-sandbox", "agent-v2", "ml-model", "ci-runner");
    }

    @Provide
    Arbitrary<Integer> allowedMemorySize() {
        return Arbitraries.of(512, 1024, 2048, 4096, 8192);
    }

    @Provide
    Arbitrary<Integer> disallowedMemorySize() {
        return Arbitraries.integers().between(1, 10000)
                .filter(i -> !ALLOWED_MEMORY.contains(i));
    }
}
