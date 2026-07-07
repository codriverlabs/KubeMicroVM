# Build & Test Requirements

## Pre-Push Verification

Run the full test suite before pushing **only when there are code changes**.

```bash
# Full verification (required before pushing code changes)
cd /home/ubuntu/projects/pl-cloud/KubeMicroVM
./mvnw -B install -DskipTests --no-transfer-progress -q && \
./mvnw -B -pl operator-tests verify --no-transfer-progress
```

**Skip tests when pushing:**
- Documentation-only changes (`.md`, `.kiro/`, `docs/`)
- CI/workflow-only changes (`.github/`)
- Test fixture files (`uat/fixtures/`)
- UAT result files

## What Gets Verified

| Step | Command | What it checks |
|------|---------|----------------|
| Compile | `./mvnw install -DskipTests` | All modules compile, SDK codegen works |
| Integration tests | `./mvnw -pl operator-tests verify` | All 47 integration tests pass (mocked AWS, reconciler logic, webhooks, token endpoint) |

## Common Failures

- **SDK client changes** (DefaultMicroVMClient, MicroVMImageClient, MicroVMNetworkClient): these are injected via CDI — constructor signature changes break tests
- **application.properties changes**: `%test` profile must disable TLS, endpoints, etc.
- **CRD model changes**: integration tests use real CR instances — field renames break them

## Quick Commands

```bash
# Just compile (fast check)
./mvnw -B install -DskipTests -q

# Run only integration tests
./mvnw -B -pl operator-tests verify

# Run a single test class
./mvnw -B -pl operator-tests verify -Dit.test=MicroVMImageReconcilerIT

# Full build + push (the correct workflow)
./mvnw -B install -DskipTests -q && \
./mvnw -B -pl operator-tests verify && \
git push
```
