package ai.codriverlabs.microvm.operator.webhook;


import ai.codriverlabs.microvm.operator.core.model.MicroVMSpec;
import ai.codriverlabs.microvm.operator.core.model.MicroVMImageSpec;
import ai.codriverlabs.microvm.operator.webhook.validation.MicroVMValidatingWebhook;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.ValueSource;

import java.util.List;

import static org.junit.jupiter.api.Assertions.*;

class MicroVMValidatingWebhookTest {

    private MicroVMValidatingWebhook webhook;

    @BeforeEach
    void setUp() {
        webhook = new MicroVMValidatingWebhook();
    }

    @Test
    void validSpecPassesValidation() {
        MicroVMSpec spec = new MicroVMSpec();
        spec.setImageRef("python-sandbox");
        spec.setMaximumDurationSeconds(3600);
        spec.setMaxIdleDurationSeconds(900);
        spec.setSuspendedDurationSeconds(1800);

        List<String> errors = webhook.validate(spec, "default");
        assertTrue(errors.isEmpty(), "Valid spec should have no errors: " + errors);
    }

    @Test
    void nullImageRefRejected() {
        MicroVMSpec spec = new MicroVMSpec();
        spec.setImageRef(null);

        List<String> errors = webhook.validate(spec, "default");
        assertFalse(errors.isEmpty(), "Null imageRef should be rejected");
        assertTrue(errors.stream().anyMatch(e -> e.contains("imageRef")));
    }

    @Test
    void blankImageRefRejected() {
        MicroVMSpec spec = new MicroVMSpec();
        spec.setImageRef("   ");

        List<String> errors = webhook.validate(spec, "default");
        assertFalse(errors.isEmpty(), "Blank imageRef should be rejected");
    }

    @Test
    void nullSpecRejected() {
        List<String> errors = webhook.validate(null, "default");
        assertFalse(errors.isEmpty());
        assertTrue(errors.stream().anyMatch(e -> e.contains("spec is required")));
    }

    @Test
    void arbitraryIdlePolicyValuesAccepted() {
        // MicroVM idle policy values are not validated by webhook —
        // AWS validates them at API call time
        MicroVMSpec spec = new MicroVMSpec();
        spec.setImageRef("my-image");
        spec.setMaxIdleDurationSeconds(28800);
        spec.setSuspendedDurationSeconds(28800);
        spec.setMaximumDurationSeconds(28800);

        List<String> errors = webhook.validate(spec, "default");
        assertTrue(errors.isEmpty(), "Idle policy values should pass webhook: " + errors);
    }

    // --- MicroVMImage memorySizeMiB validation ---

    @ParameterizedTest
    @ValueSource(ints = {512, 1024, 2048, 4096, 8192})
    void validMemorySizeMiBAccepted(int memory) {
        MicroVMImageSpec spec = new MicroVMImageSpec();
        spec.setMemorySizeMiB(memory);

        List<String> errors = new java.util.ArrayList<>();
        webhook.validateMemorySizeMiB(spec, errors);
        assertTrue(errors.isEmpty(), "Memory " + memory + " should be accepted: " + errors);
    }

    @ParameterizedTest
    @ValueSource(ints = {0, 128, 256, 500, 999, 2000, 3000, 5000, 10240})
    void invalidMemorySizeMiBRejected(int memory) {
        MicroVMImageSpec spec = new MicroVMImageSpec();
        spec.setMemorySizeMiB(memory);

        List<String> errors = new java.util.ArrayList<>();
        webhook.validateMemorySizeMiB(spec, errors);
        assertFalse(errors.isEmpty(), "Memory " + memory + " should be rejected");
        assertTrue(errors.get(0).contains("must be one of"));
    }

    @Test
    void nullMemorySizeMiBAccepted() {
        MicroVMImageSpec spec = new MicroVMImageSpec();
        spec.setMemorySizeMiB(null);

        List<String> errors = new java.util.ArrayList<>();
        webhook.validateMemorySizeMiB(spec, errors);
        assertTrue(errors.isEmpty(), "Null memorySizeMiB should be accepted (AWS default)");
    }

    @Test
    void memorySizeMiBImmutabilityEnforced() {
        MicroVMImageSpec oldSpec = new MicroVMImageSpec();
        oldSpec.setMemorySizeMiB(4096);

        MicroVMImageSpec newSpec = new MicroVMImageSpec();
        newSpec.setMemorySizeMiB(8192);

        List<String> errors = new java.util.ArrayList<>();
        webhook.validateMemoryImmutability(oldSpec, newSpec, errors);
        assertFalse(errors.isEmpty(), "Changing memorySizeMiB should be rejected");
        assertTrue(errors.get(0).contains("immutable"));
    }

    @Test
    void memorySizeMiBSameValueAllowed() {
        MicroVMImageSpec oldSpec = new MicroVMImageSpec();
        oldSpec.setMemorySizeMiB(4096);

        MicroVMImageSpec newSpec = new MicroVMImageSpec();
        newSpec.setMemorySizeMiB(4096);

        List<String> errors = new java.util.ArrayList<>();
        webhook.validateMemoryImmutability(oldSpec, newSpec, errors);
        assertTrue(errors.isEmpty(), "Same memorySizeMiB should be allowed");
    }
}
