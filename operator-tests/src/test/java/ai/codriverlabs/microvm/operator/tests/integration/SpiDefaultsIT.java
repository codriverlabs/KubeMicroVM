package ai.codriverlabs.microvm.operator.tests.integration;

import ai.codriverlabs.microvm.operator.controller.spi.*;
import ai.codriverlabs.microvm.operator.spi.auth.TokenPolicy;
import ai.codriverlabs.microvm.operator.spi.lifecycle.OperatorExtension;
import ai.codriverlabs.microvm.operator.spi.quota.QuotaPolicy;
import ai.codriverlabs.microvm.operator.spi.tenant.TenantContext;
import ai.codriverlabs.microvm.operator.spi.tenant.TenantResolver;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;

import static org.junit.jupiter.api.Assertions.*;

/**
 * Integration tests for the Community SPI default implementations.
 *
 * Verifies that each Default* bean satisfies the SPI contract and behaves
 * as documented. These tests guard against accidental logic changes in defaults.
 *
 * CDI wiring is verified here via direct instantiation (no Quarkus test harness
 * needed — these are plain @ApplicationScoped beans with no injected dependencies).
 */
@DisplayName("Community SPI defaults")
class SpiDefaultsIT {

    // ── DefaultQuotaPolicy ─────────────────────────────────────────────────────

    @Test
    @DisplayName("DefaultQuotaPolicy returns configured rate exactly (no margin)")
    void defaultQuotaPolicy_returnsExactRate() {
        var policy = new DefaultQuotaPolicy();
        assertEquals(5,   policy.effectiveRate("RunMicrovm", 5));
        assertEquals(2,   policy.effectiveRate("SuspendMicrovm", 2));
        assertEquals(50,  policy.effectiveRate("CreateMicrovmAuthToken", 50));
        assertEquals(100, policy.effectiveRate("GetMicrovm", 100));
    }

    @Test
    @DisplayName("DefaultQuotaPolicy returns configured image build limit exactly")
    void defaultQuotaPolicy_returnsExactBuildLimit() {
        var policy = new DefaultQuotaPolicy();
        assertEquals(10, policy.effectiveImageBuildLimit(10));
        assertEquals(50, policy.effectiveImageBuildLimit(50)); // after quota increase
    }

    @Test
    @DisplayName("DefaultQuotaPolicy implements QuotaPolicy")
    void defaultQuotaPolicy_implementsSpi() {
        assertInstanceOf(QuotaPolicy.class, new DefaultQuotaPolicy());
    }

    // ── DefaultTenantResolver ──────────────────────────────────────────────────

    @Test
    @DisplayName("DefaultTenantResolver resolves all namespaces to DEFAULT")
    void defaultTenantResolver_alwaysDefault() {
        var resolver = new DefaultTenantResolver();
        assertEquals(TenantContext.DEFAULT, resolver.resolve("default"));
        assertEquals(TenantContext.DEFAULT, resolver.resolve("production"));
        assertEquals(TenantContext.DEFAULT, resolver.resolve("team-a"));
    }

    @Test
    @DisplayName("DefaultTenantResolver manages all namespaces")
    void defaultTenantResolver_managesAll() {
        var resolver = new DefaultTenantResolver();
        assertTrue(resolver.isManaged("default"));
        assertTrue(resolver.isManaged("any-namespace"));
    }

    @Test
    @DisplayName("DefaultTenantResolver implements TenantResolver")
    void defaultTenantResolver_implementsSpi() {
        assertInstanceOf(TenantResolver.class, new DefaultTenantResolver());
    }

    // ── DefaultTokenPolicy ─────────────────────────────────────────────────────

    @Test
    @DisplayName("DefaultTokenPolicy clamps expiry to global max")
    void defaultTokenPolicy_clampsExpiry() throws Exception {
        var policy = new DefaultTokenPolicy();
        assertEquals(30,  policy.maxExpiryMinutes("ns", "vm", 30, 60));
        assertEquals(60,  policy.maxExpiryMinutes("ns", "vm", 120, 60));
        assertEquals(1,   policy.maxExpiryMinutes("ns", "vm", 1, 60));
    }

    @Test
    @DisplayName("DefaultTokenPolicy.beforeIssue is a no-op")
    void defaultTokenPolicy_beforeIssueNoOp() {
        var policy = new DefaultTokenPolicy();
        assertDoesNotThrow(() -> policy.beforeIssue("ns", "my-vm", "my-sa"));
    }

    @Test
    @DisplayName("DefaultTokenPolicy.afterIssue is a no-op")
    void defaultTokenPolicy_afterIssueNoOp() {
        var policy = new DefaultTokenPolicy();
        assertDoesNotThrow(() -> policy.afterIssue("ns", "my-vm", "my-sa", 30));
    }

    @Test
    @DisplayName("DefaultTokenPolicy implements TokenPolicy")
    void defaultTokenPolicy_implementsSpi() {
        assertInstanceOf(TokenPolicy.class, new DefaultTokenPolicy());
    }

    // ── DefaultOperatorExtension ───────────────────────────────────────────────

    @Test
    @DisplayName("DefaultOperatorExtension.onStartup is a no-op")
    void defaultExtension_onStartupNoOp() {
        var ext = new DefaultOperatorExtension();
        assertDoesNotThrow(() -> ext.onStartup());
    }

    @Test
    @DisplayName("DefaultOperatorExtension.onShutdown is a no-op")
    void defaultExtension_onShutdownNoOp() {
        var ext = new DefaultOperatorExtension();
        assertDoesNotThrow(() -> ext.onShutdown());
    }

    @Test
    @DisplayName("DefaultOperatorExtension implements OperatorExtension")
    void defaultExtension_implementsSpi() {
        assertInstanceOf(OperatorExtension.class, new DefaultOperatorExtension());
    }
}
