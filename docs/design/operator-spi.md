# Design: operator-spi — KubeMicroVM Extension SPI

**Status**: Implementation  
**Branch**: `feature/operator-spi`

---

## Purpose

`operator-spi` is a new Maven module that defines the **stable extension interfaces**
between the Community operator and PRO implementations. It is:

- Published as a Maven artifact alongside the operator
- Depended on by the PRO module to implement extensions
- Small — only interfaces, no business logic, no AWS SDK, no Fabric8 dependency
- Versioned independently with binary compatibility guarantees

---

## Why a Separate Module

Community (`operator-controller`) contains all business logic. If PRO depended
directly on `operator-controller`, it would pull in the entire operator as a
dependency including reconciler logic, AWS clients, and Quarkus internals — creating
tight coupling that breaks on every internal refactor.

`operator-spi` is a thin facade:

```
operator-controller  ──depends on──► operator-spi (interfaces)
                                           ▲
operator-pro (private)  ────────────────── (implements)
```

`operator-controller` depends on `operator-spi` for the interface definitions.
`operator-pro` depends on `operator-spi` to implement them.
`operator-controller` discovers implementations via Quarkus CDI `@Alternative`.

---

## Module Structure

```
operator-spi/
├── pom.xml
└── src/main/java/ai/codriverlabs/microvm/operator/spi/
    ├── package-info.java              # API stability declaration
    ├── quota/
    │   ├── QuotaPolicy.java           # Rate limit enforcement contract
    │   └── QuotaAllocation.java       # Value object: per-operation limits
    ├── tenant/
    │   ├── TenantResolver.java        # Resolve tenant from namespace/resource
    │   └── TenantContext.java         # Value object: tenant identity
    ├── auth/
    │   └── TokenPolicy.java           # Token expiry, concurrency enforcement
    └── lifecycle/
        └── OperatorExtension.java     # Startup/shutdown hook for PRO init
```

---

## Interface Definitions

### QuotaPolicy

The primary extension point. Controls how the operator enforces AWS API rate limits.
Community default: uses configured values directly (no margin).
PRO: adds per-tenant accounting, safety margin, dynamic adjustment.

```java
package ai.codriverlabs.microvm.operator.spi.quota;

/**
 * Controls AWS API rate limit enforcement for the operator.
 *
 * Community default implementation uses exact configured values.
 * Custom implementations can add safety margins, per-tenant accounting,
 * or dynamic quota adjustment.
 *
 * Implementations are discovered via Quarkus CDI. To override the default,
 * annotate your implementation with @Alternative @Priority(100).
 *
 * @since 1.1.0
 */
public interface QuotaPolicy {

    /**
     * Returns the effective rate limit for the given operation.
     *
     * Called once at operator startup to configure rate limiters.
     * The returned allocation is used for the lifetime of the process.
     *
     * @param operation the AWS API operation name (e.g., "RunMicrovm")
     * @param configuredRate the rate configured in application properties (req/s)
     * @return effective rate to enforce (req/s); must be > 0
     */
    int effectiveRate(String operation, int configuredRate);

    /**
     * Returns the effective concurrent image build limit.
     *
     * @param configuredLimit the limit configured in application properties
     * @return effective concurrent build limit; must be > 0
     */
    int effectiveImageBuildLimit(int configuredLimit);
}
```

### TenantResolver

Resolves a tenant identity from a Kubernetes namespace or resource. Used by PRO
to implement namespace-scoped operator isolation and per-tenant quota accounting.

```java
package ai.codriverlabs.microvm.operator.spi.tenant;

/**
 * Resolves tenant identity from Kubernetes resource context.
 *
 * Community default: single-tenant (all namespaces map to the same tenant).
 * PRO: resolves tenant from namespace labels, annotations, or external registry.
 *
 * @since 1.1.0
 */
public interface TenantResolver {

    /**
     * Resolves the tenant for a given namespace.
     *
     * @param namespace Kubernetes namespace name
     * @return tenant context; never null (return TenantContext.DEFAULT for single-tenant)
     */
    TenantContext resolve(String namespace);

    /**
     * Returns true if the given namespace is managed by this operator instance.
     * Used by PRO to implement per-tenant operator isolation
     * (each operator instance owns a subset of namespaces).
     *
     * Community default: always true (operator watches all labelled namespaces).
     *
     * @param namespace Kubernetes namespace name
     * @return true if this operator instance should reconcile resources in this namespace
     */
    default boolean isManaged(String namespace) {
        return true;
    }
}
```

### TokenPolicy

Controls token issuance rules — expiry, concurrency, and access control.

```java
package ai.codriverlabs.microvm.operator.spi.auth;

/**
 * Controls MicroVM auth token issuance policy.
 *
 * Community default: standard expiry, no concurrency enforcement.
 * PRO: per-tenant token budgets, exclusive mode enforcement, audit logging.
 *
 * @since 1.1.0
 */
public interface TokenPolicy {

    /**
     * Maximum token expiry in minutes for the given namespace.
     * The operator clamps the requested expiry to this value.
     *
     * @param namespace Kubernetes namespace
     * @param requestedMinutes expiry requested by the caller
     * @param globalMaxMinutes configured global maximum
     * @return effective maximum expiry in minutes
     */
    default int maxExpiryMinutes(String namespace, int requestedMinutes, int globalMaxMinutes) {
        return Math.min(requestedMinutes, globalMaxMinutes);
    }

    /**
     * Called before issuing a token. May throw {@link TokenDeniedException}
     * to block issuance with a reason (returned as HTTP 403 to the caller).
     *
     * Community default: no-op.
     *
     * @param namespace namespace of the requesting pod
     * @param vmName name of the MicroVM CR
     * @param serviceAccount service account of the requesting pod
     */
    default void beforeIssue(String namespace, String vmName, String serviceAccount)
            throws TokenDeniedException {
        // no-op in Community
    }

    /**
     * Called after a token is successfully issued.
     * Used by PRO for audit logging and quota accounting.
     */
    default void afterIssue(String namespace, String vmName, String serviceAccount) {
        // no-op in Community
    }
}
```

### OperatorExtension

Lifecycle hook for PRO module initialisation — license validation, telemetry
registration, feature flag loading.

```java
package ai.codriverlabs.microvm.operator.spi.lifecycle;

/**
 * Lifecycle hook called during operator startup and shutdown.
 *
 * Allows PRO module to perform initialisation (license check, telemetry setup,
 * feature flag loading) before the operator begins reconciling.
 *
 * Community default: no-op.
 *
 * @since 1.1.0
 */
public interface OperatorExtension {

    /**
     * Called after AWS connectivity is confirmed but before reconcilers start.
     * Throw {@link ExtensionInitException} to abort startup.
     */
    default void onStartup() throws ExtensionInitException {
        // no-op in Community
    }

    /**
     * Called during graceful shutdown before reconcilers stop.
     */
    default void onShutdown() {
        // no-op in Community
    }
}
```

---

## Community Default Implementations

Each interface has a `Default*` implementation in `operator-controller` that ships
with Community. These are `@ApplicationScoped` Quarkus CDI beans. PRO replaces
them with `@Alternative @Priority(100)` beans in the private PRO module.

```java
// In operator-controller (Community)
@ApplicationScoped
public class DefaultQuotaPolicy implements QuotaPolicy {
    @Override
    public int effectiveRate(String operation, int configuredRate) {
        return configuredRate; // exact value, no margin
    }

    @Override
    public int effectiveImageBuildLimit(int configuredLimit) {
        return configuredLimit;
    }
}
```

```java
// In operator-pro (PRO, private)
@Alternative @Priority(100)
@ApplicationScoped
public class ProQuotaPolicy implements QuotaPolicy {
    @ConfigProperty(name = "pro.quota.safety-margin-percent", defaultValue = "10")
    int safetyMarginPercent;

    @Override
    public int effectiveRate(String operation, int configuredRate) {
        return (int) (configuredRate * (1.0 - safetyMarginPercent / 100.0));
    }
    // ...
}
```

---

## How QuotaGuard Uses the SPI

`QuotaGuard` injects `QuotaPolicy` instead of using raw config values:

```java
@ApplicationScoped
public class QuotaGuard {

    @Inject QuotaPolicy quotaPolicy;

    @ConfigProperty(name = "aws.quota.run-microvm-rate", defaultValue = "5")
    int configuredRunRate;

    // At construction, apply the policy:
    // effectiveRunRate = quotaPolicy.effectiveRate("RunMicrovm", configuredRunRate)
}
```

This single injection point is where Community and PRO diverge — no other code
needs to change.

---

## Versioning & Binary Compatibility

`operator-spi` follows semantic versioning independently of the operator:

- **Patch**: no interface changes, bug fixes in default implementations
- **Minor**: new default methods added to existing interfaces (backward compatible)
- **Major**: interface changes that break existing implementations (requires PRO update)

The `@since` Javadoc tag marks when each interface was introduced.
Interfaces are marked `@Stable` once they have been in a GA release.

---

## What is NOT in operator-spi

The SPI deliberately excludes:

- AWS SDK types — PRO does not need to know AWS API internals
- Fabric8 / Kubernetes client types — keeps PRO decoupled from k8s client version
- Reconciler logic — PRO extends behaviour, not replaces it
- CRD model classes — PRO reads CR specs via the operator's status fields, not raw models
- Any Quarkus-specific annotations — SPI is framework-neutral; CDI annotations are only
  in the implementations, not the interfaces
