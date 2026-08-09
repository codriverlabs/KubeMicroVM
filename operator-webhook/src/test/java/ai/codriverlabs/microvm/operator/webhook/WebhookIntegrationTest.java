package ai.codriverlabs.microvm.operator.webhook;


import ai.codriverlabs.microvm.operator.core.model.MicroVMSpec;
import ai.codriverlabs.microvm.operator.webhook.mutation.MicroVMMutatingWebhook;
import ai.codriverlabs.microvm.operator.webhook.validation.MicroVMValidatingWebhook;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.DisplayName;

import java.util.List;

import static org.junit.jupiter.api.Assertions.*;

/**
 * Integration tests verifying the full admission pipeline:
 * mutation (apply defaults) -> validation (reject invalid).
 */
class WebhookIntegrationTest {

    private MicroVMValidatingWebhook validator;
    private MicroVMMutatingWebhook mutator;

    @BeforeEach
    void setUp() {
        validator = new MicroVMValidatingWebhook();
        mutator = new MicroVMMutatingWebhook();
    }

    @Test
    @DisplayName("Full pipeline: mutation applies defaults then validation passes")
    void fullPipelineMutationThenValidation() {
        MicroVMSpec spec = new MicroVMSpec();
        spec.setImageRef("python-sandbox");
        spec.setMaxIdleDurationSeconds(900);
        spec.setSuspendedDurationSeconds(1800);
        // autoResumeEnabled and maximumDurationSeconds are null — should get defaults

        // Step 1: Mutate
        MicroVMSpec mutated = mutator.applyDefaults(spec, "default");
        assertEquals(28800, mutated.getMaximumDurationSeconds()); // global default
        assertTrue(mutated.getAutoResumeEnabled()); // global default

        // Step 2: Validate
        List<String> errors = validator.validate(mutated, "default");
        assertTrue(errors.isEmpty(), "After mutation, spec should pass validation: " + errors);
    }

    @Test
    @DisplayName("Null imageRef rejected by validator")
    void invalidImageRefNullRejected() {
        MicroVMSpec spec = new MicroVMSpec();
        spec.setImageRef(null);

        List<String> errors = validator.validate(spec, "default");
        assertFalse(errors.isEmpty());
        assertTrue(errors.stream().anyMatch(e -> e.contains("imageRef")));
    }

    @Test
    @DisplayName("Mutation does not override explicitly set values")
    void mutationPreservesExplicitValues() {
        MicroVMSpec spec = new MicroVMSpec();
        spec.setImageRef("python-sandbox");
        spec.setMaximumDurationSeconds(3600);
        spec.setMaxIdleDurationSeconds(60);
        spec.setSuspendedDurationSeconds(300);
        spec.setAutoResumeEnabled(false);
        spec.setNetworkRef("custom-network");

        MicroVMSpec mutated = mutator.applyDefaults(spec, "default");

        assertEquals("python-sandbox", mutated.getImageRef());
        assertEquals(3600, mutated.getMaximumDurationSeconds()); // preserved, not overridden to 28800
        assertEquals(60, mutated.getMaxIdleDurationSeconds());
        assertEquals(300, mutated.getSuspendedDurationSeconds());
        assertFalse(mutated.getAutoResumeEnabled()); // preserved, not overridden to true
        assertEquals("custom-network", mutated.getNetworkRef());
    }

    @Test
    @DisplayName("Mutation applies both defaults when both are null")
    void mutationAppliesBothDefaults() {
        MicroVMSpec spec = new MicroVMSpec();
        spec.setImageRef("my-agent");
        // maximumDurationSeconds = null, autoResumeEnabled = null

        MicroVMSpec mutated = mutator.applyDefaults(spec, "default");
        assertEquals(28800, mutated.getMaximumDurationSeconds());
        assertTrue(mutated.getAutoResumeEnabled());
    }

    @Test
    @DisplayName("Valid spec with all idle policy fields passes end-to-end")
    void validSpecWithIdlePolicyPasses() {
        MicroVMSpec spec = new MicroVMSpec();
        spec.setImageRef("my-agent");
        spec.setMaxIdleDurationSeconds(900);
        spec.setSuspendedDurationSeconds(1800);
        spec.setMaximumDurationSeconds(14400);
        spec.setAutoResumeEnabled(true);

        MicroVMSpec mutated = mutator.applyDefaults(spec, "default");
        List<String> errors = validator.validate(mutated, "default");
        assertTrue(errors.isEmpty(), "Full idle policy spec should pass: " + errors);
    }

    @Test
    @DisplayName("Large idle policy values pass (AWS validates limits, not webhook)")
    void largeIdlePolicyValuesPass() {
        MicroVMSpec spec = new MicroVMSpec();
        spec.setImageRef("batch-worker");
        spec.setMaxIdleDurationSeconds(28800);
        spec.setSuspendedDurationSeconds(28800);
        spec.setMaximumDurationSeconds(28800);

        List<String> errors = validator.validate(spec, "default");
        assertTrue(errors.isEmpty(), "Large values should pass webhook (AWS validates): " + errors);
    }
}
