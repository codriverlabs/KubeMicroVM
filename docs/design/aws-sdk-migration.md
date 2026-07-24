# Migration to Official AWS SDK `lambdamicrovms` Module

**Status**: Planned  
**Date**: 2026-07-24  
**Priority**: High — unblocks AWS SDK upgrades beyond 2.44.6

---

## Context

When KubeMicroVM development started, AWS had not yet published an official Java SDK
module for Lambda MicroVMs. We reverse-engineered the service model from the AWS API
(via the JavaScript SDK's service model and API documentation) and used the AWS SDK
`codegen-maven-plugin` to generate a custom async client (`operator-aws-client`).

As of AWS SDK for Java **2.49.x** (July 2026), AWS has officially published:

```xml
<dependency>
    <groupId>software.amazon.awssdk</groupId>
    <artifactId>lambdamicrovms</artifactId>
    <version>2.49.3</version>
</dependency>
```

Source: https://github.com/aws/aws-sdk-java-v2/tree/master/services/lambdamicrovms

---

## Why We Used Custom Codegen

1. **No official SDK module existed** — Lambda MicroVMs launched June 2026; the Java SDK
   lagged behind the JavaScript SDK which had `@aws-sdk/client-lambda-microvms` from day one.

2. **Service model was available** — The API reference PDF and JS SDK provided the complete
   service model (`service-2.json`), which the Java SDK codegen plugin accepts directly.

3. **Speed to market** — Custom codegen gave us a working async client within hours of
   service launch, without waiting for AWS to publish the official module.

4. **Full control over customization** — Our `customization.config` allowed us to tune
   client defaults (timeouts, retry strategies) for the operator's specific access patterns.

---

## Current State

- **Custom module**: `operator-aws-client` (24 operations, codegen from `service-2.json`)
- **Pinned SDK version**: 2.44.6 (last version compatible with our codegen output)
- **Blocker**: SDK 2.49.3 introduced internal API changes (`AwsEndpointProviderUtils` removed,
  `ClientExecutionParams.withAuthSchemeOptionsResolver` added) that break our generated code.

---

## Migration Plan

### Phase 1: API Parity Check

Compare our custom service model operations against the official SDK module:

**Our model (24 operations):**
- CreateMicrovmAuthToken
- CreateMicrovmImage
- CreateMicrovmShellAuthToken
- DeleteMicrovmImage
- DeleteMicrovmImageVersion
- GetMicrovm
- GetMicrovmImage
- GetMicrovmImageBuild
- GetMicrovmImageVersion
- ListManagedMicrovmImageVersions
- ListManagedMicrovmImages
- ListMicrovmImageBuilds
- ListMicrovmImageVersions
- ListMicrovmImages
- ListMicrovms
- ListTags
- ResumeMicrovm
- RunMicrovm
- SuspendMicrovm
- TagResource
- TerminateMicrovm
- UntagResource
- UpdateMicrovmImage
- UpdateMicrovmImageVersion

**TODO**: Pull the official `lambdamicrovms` module source and compare:
- Operation names and signatures
- Request/response model field names
- Enum values
- Pagination configuration
- Any new operations we don't have (e.g., NetworkConnector APIs)

### Phase 2: Replace `operator-aws-client`

1. Remove `operator-aws-client` module from the multi-module build
2. Add `software.amazon.awssdk:lambdamicrovms` as a dependency in `operator-controller`
3. Update all import paths (`ai.codriverlabs.microvm.aws.lambdamicrovms.*` → `software.amazon.awssdk.services.lambdamicrovms.*`)
4. Adapt client construction (our wrapper classes in `operator-controller/.../aws/`)
5. Verify async client behavior matches (we use `LambdaMicrovmsAsyncClient` exclusively)

### Phase 3: Upgrade AWS SDK to 2.49.x+

Once the custom module is removed, we can freely upgrade the AWS SDK version.
Dependabot will handle ongoing updates automatically.

---

## Risks

- **Missing operations**: The official module may not include NetworkConnector APIs
  or newer operations we added manually to our service model.
- **Model differences**: Field names or enum values may differ between our
  reverse-engineered model and the official one.
- **Async behavior**: Our generated client uses specific error handling and retry
  patterns that may differ from the official defaults.
- **JOSDK 5.5.0 + SDK 2.49.x compatibility**: Both are major bumps; test together.

---

## Decision

Proceed with migration once API parity is confirmed. The custom codegen approach
served its purpose (first-mover advantage) but is now technical debt that blocks
SDK upgrades and adds build complexity.
