package ai.codriverlabs.microvm.operator.spi;

import ai.codriverlabs.microvm.operator.spi.auth.TokenDeniedException;
import ai.codriverlabs.microvm.operator.spi.auth.TokenPolicy;
import ai.codriverlabs.microvm.operator.spi.lifecycle.ExtensionInitException;
import ai.codriverlabs.microvm.operator.spi.lifecycle.OperatorExtension;
import ai.codriverlabs.microvm.operator.spi.quota.QuotaPolicy;
import ai.codriverlabs.microvm.operator.spi.tenant.TenantContext;
import ai.codriverlabs.microvm.operator.spi.tenant.TenantResolver;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Nested;
import org.junit.jupiter.api.Test;

import static org.junit.jupiter.api.Assertions.*;

/**
 * Contract tests for operator-spi interfaces.
 *
 * These tests document and enforce the expected behaviour of the SPI contracts.
 * Any implementation (Community default or PRO override) must pass these tests.
 *
 * Run against the default no-op stubs defined inline to verify interface defaults.
 */
class SpiContractTest {

    // ── Minimal no-op implementations (stubs, not the real Default* beans) ────

    static class StubQuotaPolicy implements QuotaPolicy {
        @Override public int effectiveRate(String op, int rate) { return rate; }
        @Override public int effectiveImageBuildLimit(int limit) { return limit; }
    }

    static class StubTenantResolver implements TenantResolver {
        @Override public TenantContext resolve(String ns) { return TenantContext.DEFAULT; }
    }

    static class StubTokenPolicy implements TokenPolicy {}    // all defaults
    static class StubOperatorExtension implements OperatorExtension {} // all defaults

    // ── QuotaPolicy contract ───────────────────────────────────────────────────

    @Nested
    @DisplayName("QuotaPolicy contract")
    class QuotaPolicyContract {

        final QuotaPolicy policy = new StubQuotaPolicy();

        @Test
        @DisplayName("effectiveRate must return a positive value")
        void effectiveRateMustBePositive() {
            assertTrue(policy.effectiveRate("RunMicrovm", 5) > 0);
            assertTrue(policy.effectiveRate("SuspendMicrovm", 2) > 0);
        }

        @Test
        @DisplayName("effectiveRate must not exceed configured rate for Community")
        void communityMustNotExceedConfigured() {
            int configured = 5;
            assertTrue(policy.effectiveRate("RunMicrovm", configured) <= configured);
        }

        @Test
        @DisplayName("effectiveImageBuildLimit must return a positive value")
        void imageBuildLimitMustBePositive() {
            assertTrue(policy.effectiveImageBuildLimit(10) > 0);
        }
    }

    // ── TenantResolver contract ────────────────────────────────────────────────

    @Nested
    @DisplayName("TenantResolver contract")
    class TenantResolverContract {

        final TenantResolver resolver = new StubTenantResolver();

        @Test
        @DisplayName("resolve must never return null")
        void resolveMustNotReturnNull() {
            assertNotNull(resolver.resolve("default"));
            assertNotNull(resolver.resolve("some-namespace"));
        }

        @Test
        @DisplayName("isManaged default returns true")
        void isManagedDefaultIsTrue() {
            assertTrue(resolver.isManaged("any-namespace"));
        }
    }

    // ── TenantContext contract ─────────────────────────────────────────────────

    @Nested
    @DisplayName("TenantContext contract")
    class TenantContextContract {

        @Test
        @DisplayName("DEFAULT singleton has tenantId 'default'")
        void defaultTenantId() {
            assertEquals("default", TenantContext.DEFAULT.tenantId());
            assertTrue(TenantContext.DEFAULT.isDefault());
        }

        @Test
        @DisplayName("equality is based on tenantId only")
        void equalityByTenantId() {
            var a = new TenantContext("acme", "Acme Corp");
            var b = new TenantContext("acme", "Different Name");
            assertEquals(a, b);
            assertEquals(a.hashCode(), b.hashCode());
        }

        @Test
        @DisplayName("non-default context is not isDefault()")
        void nonDefaultIsNotDefault() {
            assertFalse(new TenantContext("acme", null).isDefault());
        }

        @Test
        @DisplayName("tenantId must not be null")
        void tenantIdMustNotBeNull() {
            assertThrows(NullPointerException.class,
                    () -> new TenantContext(null, "name"));
        }
    }

    // ── TokenPolicy contract ───────────────────────────────────────────────────

    @Nested
    @DisplayName("TokenPolicy contract")
    class TokenPolicyContract {

        final TokenPolicy policy = new StubTokenPolicy();

        @Test
        @DisplayName("maxExpiryMinutes default clamps to globalMax")
        void clampsToGlobalMax() throws Exception {
            assertEquals(30, policy.maxExpiryMinutes("ns", "vm", 30, 60));
            assertEquals(60, policy.maxExpiryMinutes("ns", "vm", 120, 60));
        }

        @Test
        @DisplayName("maxExpiryMinutes must return a positive value")
        void mustReturnPositive() throws Exception {
            assertTrue(policy.maxExpiryMinutes("ns", "vm", 5, 60) > 0);
        }

        @Test
        @DisplayName("beforeIssue default does not throw")
        void beforeIssueDefaultDoesNotThrow() {
            assertDoesNotThrow(() ->
                    policy.beforeIssue("default", "my-vm", "my-sa"));
        }

        @Test
        @DisplayName("afterIssue default does not throw")
        void afterIssueDefaultDoesNotThrow() {
            assertDoesNotThrow(() ->
                    policy.afterIssue("default", "my-vm", "my-sa", 30));
        }
    }

    // ── OperatorExtension contract ─────────────────────────────────────────────

    @Nested
    @DisplayName("OperatorExtension contract")
    class OperatorExtensionContract {

        final OperatorExtension ext = new StubOperatorExtension();

        @Test
        @DisplayName("onStartup default does not throw")
        void onStartupDoesNotThrow() {
            assertDoesNotThrow(() -> ext.onStartup());
        }

        @Test
        @DisplayName("onShutdown default does not throw")
        void onShutdownDoesNotThrow() {
            assertDoesNotThrow(() -> ext.onShutdown());
        }
    }

    // ── Alternative override behaviour ─────────────────────────────────────────

    @Nested
    @DisplayName("@Alternative override semantics")
    class AlternativeOverrideSemantics {

        @Test
        @DisplayName("PRO can apply safety margin via effectiveRate")
        void proCanApplySafetyMargin() {
            // Simulates what ProQuotaPolicy would do
            QuotaPolicy proPolicy = new QuotaPolicy() {
                @Override public int effectiveRate(String op, int rate) {
                    return (int) (rate * 0.9); // 10% safety margin
                }
                @Override public int effectiveImageBuildLimit(int limit) {
                    return (int) (limit * 0.9);
                }
            };
            assertEquals(4, proPolicy.effectiveRate("RunMicrovm", 5));
            assertEquals(9, proPolicy.effectiveImageBuildLimit(10));
        }

        @Test
        @DisplayName("PRO can block token issuance via beforeIssue")
        void proCanBlockToken() {
            TokenPolicy proPolicy = new TokenPolicy() {
                @Override
                public void beforeIssue(String ns, String vm, String sa)
                        throws TokenDeniedException {
                    throw new TokenDeniedException("tenant quota exceeded");
                }
            };
            var ex = assertThrows(TokenDeniedException.class,
                    () -> proPolicy.beforeIssue("ns", "vm", "sa"));
            assertEquals("tenant quota exceeded", ex.getMessage());
        }

        @Test
        @DisplayName("PRO can abort startup via onStartup")
        void proCanAbortStartup() {
            OperatorExtension proExt = new OperatorExtension() {
                @Override
                public void onStartup() throws ExtensionInitException {
                    throw new ExtensionInitException("license validation failed");
                }
            };
            var ex = assertThrows(ExtensionInitException.class,
                    () -> proExt.onStartup());
            assertEquals("license validation failed", ex.getMessage());
        }

        @Test
        @DisplayName("PRO can restrict namespace management")
        void proCanRestrictNamespace() {
            TenantResolver proResolver = new TenantResolver() {
                @Override public TenantContext resolve(String ns) {
                    return new TenantContext("tenant-a", "Tenant A");
                }
                @Override public boolean isManaged(String ns) {
                    return ns.startsWith("tenant-a-");
                }
            };
            assertTrue(proResolver.isManaged("tenant-a-prod"));
            assertFalse(proResolver.isManaged("tenant-b-prod"));
        }
    }
}
