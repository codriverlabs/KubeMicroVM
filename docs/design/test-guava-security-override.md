# Test-scoped Guava security override

## Motivation

Dependabot reports five open alerts for `com.google.guava:guava` version
`33.6.0-jre`. The dependency is resolved only through Quarkus test support:

```text
quarkus-junit:test
→ quarkus-test-common:test
→ quarkus-bootstrap-maven-resolver:test
→ maven-embedder:test
→ guava:33.6.0-jre:test
```

No compile- or runtime-scoped Guava dependency, or application source import of
`com.google.common`, exists in this repository.

## Design

Each of the five modules that directly declares `quarkus-junit5` will declare
`com.google.guava:guava:33.7.2-jre` with `test` scope. Maven's direct-dependency
mediation selects the secure version for that module's test classpath without
adding Guava to a production classpath or changing dependency management for
future production dependencies.

Affected modules:

- `operator-auth-agent`
- `operator-webhook`
- `operator-controller`
- `operator-cli`
- `operator-tests`

## Testing

- Run Maven's dependency tree for Guava and verify every resolved path uses
  `33.7.2-jre` with `test` scope.
- Run the required project compilation and integration-test commands.
- Run the native build because Maven dependency changes can affect GraalVM
  native-image analysis.
