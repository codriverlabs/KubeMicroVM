# Build & Test Requirements

## Pre-Push Verification

Run the full test suite before pushing **only when there are code changes**.

```bash
# Full verification (required before pushing code changes)
cd /home/ubuntu/projects/microvm/KubeMicroVM
./mvnw -B install -DskipTests -q && \
./mvnw -B -pl operator-tests verify && \
./build-local.sh --native --only operator,cli,agent --skip-tests
```

**All three steps must pass before pushing.** No exceptions when code has changed.

**Skip tests when pushing:**
- Documentation-only changes (`.md`, `.kiro/`, `docs/`)
- CI/workflow-only changes (`.github/`)
- Test fixture files (`uat/fixtures/`)
- UAT result files

## What Gets Verified

| Step | Command | What it checks |
|------|---------|----------------|
| Compile | `./mvnw install -DskipTests` | All modules compile, dependencies resolve |
| Integration tests | `./mvnw -pl operator-tests verify` | All 81 integration tests pass (mocked AWS, reconciler logic, webhooks, token endpoint) |
| Native build | `./build-local.sh --native --only operator,cli,agent --skip-tests` | GraalVM native-image compilation succeeds for all three binaries (operator, CLI, auth-agent) |

## Why Native Build Is Required

GraalVM native-image does **static analysis** at build time and resolves all class
references. Dependency upgrades can introduce transitive classes that:
- Are missing optional dependencies (e.g., commons-compress → xz, brotli, zstd)
- Use reflection not registered in native-image metadata
- Have classes registered for build-time linking that can't be resolved

These failures are **invisible** to the JVM build and integration tests — they only
manifest during native compilation. Always verify native builds after dependency changes.

## Common Failures

- **SDK client changes** (DefaultMicroVMClient, MicroVMImageClient, MicroVMNetworkClient): these are injected via CDI — constructor signature changes break tests
- **application.properties changes**: `%test` profile must disable TLS, endpoints, etc.
- **CRD model changes**: integration tests use real CR instances — field renames break them
- **Dependency upgrades**: new transitive deps may introduce classes that GraalVM can't resolve (NoClassDefFoundError at native-image build time)
- **aws-crt version mismatch**: the `aws-crt` version must match what the AWS SDK was compiled against — check `awscrt.version` in the SDK's parent pom
- **zstd-jni FFM regression (1.5.7-17+)**: versions 1.5.7-17 and later ship a Java 22+
  multi-release `ZstdBinding` class that uses the Foreign Function & Memory (FFM/Panama)
  API instead of classic JNI. GraalVM/Mandrel native-image cannot statically analyze the
  FFM `MethodHandle` downcalls, which are reachable transitively via Netty's `ZstdEncoder`
  from fabric8's `KubernetesClientImpl` HTTP/2 flush path. This fails native compilation
  with `VMError$HostedError: should not reach here: unexpected input could not be handled:
  linkToNative` — passes JVM build and all tests, only breaks native-image (see
  [oracle/graal#9727](https://github.com/oracle/graal/issues/9727) for the same failure
  mode via a different FFM binding). **Pin `zstd-jni` to `1.5.7-16` or earlier** until
  GraalVM/Mandrel supports FFM downcall analysis or zstd-jni ships native-image
  reachability metadata. Dependabot will try to bump this — reject bumps past `1.5.7-16`
  without re-verifying the native build.
- **fabric8 / JOSDK version skew**: `fabric8.version` and `josdk.version` must match what
  the Quarkiverse `quarkus-operator-sdk` extension (pinned via `quarkus-operator-sdk-bom`,
  itself pinned to the `quarkus.platform.version`) was built against — currently fabric8
  `7.8.0` / JOSDK `5.5.0` (extension capped at `7.8.0`, no newer release exists as of this
  writing). Overriding these ahead of the extension causes either a split dependency tree
  (client at a newer version, `kubernetes-model-*` still on the extension's pinned version
  via the Quarkus BOM → `NoClassDefFoundError` during CRD generation) or a binary
  incompatibility with the extension's compiled bytecode (`NoSuchMethodError` on
  `InformerConfiguration` at runtime). Before bumping either property, check what
  `io.quarkiverse.operatorsdk:quarkus-operator-sdk-deployment:<version>` on Maven Central
  actually declares for `operator-framework-core`/`fabric8-client.version`.

## Quick Commands

```bash
# Just compile (fast check)
./mvnw -B install -DskipTests -q

# Run only integration tests
./mvnw -B -pl operator-tests verify

# Run a single test class
./mvnw -B -pl operator-tests verify -Dit.test=MicroVMImageReconcilerIT

# Native build only (after compile)
./build-local.sh --native --only operator,cli,agent --skip-tests

# Full build + push (the correct workflow)
./mvnw -B install -DskipTests -q && \
./mvnw -B -pl operator-tests verify && \
./build-local.sh --native --only operator,cli,agent --skip-tests && \
git push
```
