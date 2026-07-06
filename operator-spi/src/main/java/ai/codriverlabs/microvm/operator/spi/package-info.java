/**
 * KubeMicroVM Operator Extension SPI.
 *
 * <p>This package defines the stable extension interfaces between the Community
 * operator and optional PRO implementations. All interfaces in this package
 * carry binary compatibility guarantees across minor versions.</p>
 *
 * <h2>Extension Points</h2>
 * <ul>
 *   <li>{@link ai.codriverlabs.microvm.operator.spi.quota.QuotaPolicy} —
 *       AWS API rate limit enforcement</li>
 *   <li>{@link ai.codriverlabs.microvm.operator.spi.tenant.TenantResolver} —
 *       Tenant identity resolution from namespace context</li>
 *   <li>{@link ai.codriverlabs.microvm.operator.spi.auth.TokenPolicy} —
 *       Auth token issuance rules and audit hooks</li>
 *   <li>{@link ai.codriverlabs.microvm.operator.spi.lifecycle.OperatorExtension} —
 *       Startup and shutdown lifecycle hooks</li>
 * </ul>
 *
 * <h2>Usage</h2>
 * <p>Community ships default implementations in {@code operator-controller}.
 * To override, annotate your implementation with
 * {@code @Alternative @Priority(100)} and ensure it is on the classpath.</p>
 *
 * @since 1.1.0
 */
package ai.codriverlabs.microvm.operator.spi;
