# GraalVM Native Image: commons-compress Optional Dependencies

## Problem

After upgrading to AWS SDK 2.49.x and Quarkus 3.37.x, GraalVM native-image compilation
fails with `NoClassDefFoundError` for compression library classes:

```
Error: Class initialization of org.apache.commons.compress.compressors.brotli.BrotliCompressorInputStream failed.
Caused by: java.lang.NoClassDefFoundError: org/brotli/dec/BrotliInputStream

Error: Discovered unresolved method during parsing: org.apache.commons.compress.compressors.xz.XZCompressorInputStream.builder()
Caused by: java.lang.ClassNotFoundException: org.tukaani.xz.XZInputStream
```

## Root Cause

1. **`commons-compress:1.28.0`** is pulled transitively by `quarkus-kubernetes-client`
   via Fabric8 `kubernetes-client:7.8.0` (used for kubectl-cp / tar operations).

2. `commons-compress` has **optional** Maven dependencies on `org.tukaani:xz`,
   `org.brotli:dec`, and `com.github.luben:zstd-jni`. These classes are referenced in
   bytecode (e.g., `CompressorStreamFactory` references `XZCompressorInputStream`) but
   Maven doesn't pull them transitively because they're marked `<optional>true</optional>`.

3. At JVM runtime this is fine — code paths are guarded by try/catch or class-existence
   checks, so they only execute if the optional jars are present.

4. **GraalVM native-image** does static analysis and resolves ALL class references at
   build time. The Quarkus `kubernetes-client-deployment` extension registers
   `CompressorStreamFactory` for native-image linking, forcing GraalVM to walk the code
   and fail on the missing classes.

5. Maven exclusions on `commons-compress` don't help because Quarkus deployment extensions
   include it on the native-image classpath independently of the user's dependency tree.

## Solution: Provide the Missing Optional Dependencies

Add the three missing optional dependencies explicitly so GraalVM can resolve all class
references during static analysis:

```xml
<!-- Parent POM dependencyManagement (version pins) -->
<dependency>
    <groupId>org.tukaani</groupId>
    <artifactId>xz</artifactId>
    <version>1.10</version>
</dependency>
<dependency>
    <groupId>org.brotli</groupId>
    <artifactId>dec</artifactId>
    <version>0.1.2</version>
</dependency>
<dependency>
    <groupId>com.github.luben</groupId>
    <artifactId>zstd-jni</artifactId>
    <version>1.5.7-3</version>
</dependency>
```

Declared in `operator-controller` and `operator-cli` (modules that produce native binaries).

These libraries are **not used at runtime** — they only satisfy GraalVM's bytecode
resolution during native compilation.

## Alternative Considered: `--link-at-build-time-exclude`

GraalVM provides `--link-at-build-time-exclude=<packages>` to defer unresolved class
errors to runtime. This eliminates the need for extra dependencies:

```properties
quarkus.native.additional-build-args=\
  --link-at-build-time-exclude=org.apache.commons.compress.compressors.brotli\
  ,--link-at-build-time-exclude=org.apache.commons.compress.compressors.xz\
  ,--link-at-build-time-exclude=org.apache.commons.compress.compressors.zstandard
```

**Why we chose the dependency approach instead:**

- Explicit and portable — works regardless of GraalVM version or flag changes
- Build fails loudly if a genuinely needed class is missing (no silent masking)
- The extra ~2MB of unused JARs has negligible impact on native image size (GraalVM
  dead-code eliminates unreachable classes)

## Affected Modules

| Module | Native binary | Fix applied |
|--------|--------------|-------------|
| `operator-controller` | Operator pod | ✅ |
| `operator-cli` | `microvm` CLI binary | ✅ |
| `operator-auth-agent` | Auth sidecar | ✅ (inherits via controller deps) |

## Verification

```bash
./build-local.sh --native --only operator,cli,agent --skip-tests
# All three native builds pass
./mvnw -B -pl operator-tests verify
# 81 integration tests pass
```
