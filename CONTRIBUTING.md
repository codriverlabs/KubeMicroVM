# Contributing to KubeMicroVM

Thank you for your interest in contributing to KubeMicroVM! This document explains
how to set up your development environment, run the test suite, and submit changes.

---

## Contributor License Agreement (CLA)

Before we can merge your Pull Request, you must sign our Contributor License Agreement.
This is a one-time, frictionless process:

1. Open a Pull Request.
2. The CLA Assistant bot will post a comment with a link.
3. Click the link, sign in with GitHub, and accept the agreement.
4. The bot marks your PR as ready — takes about 5 seconds.

The CLA grants Plasticity.Cloud and Codriverlabs a non-exclusive, perpetual, worldwide,
royalty-free license to use, modify, and distribute your contribution in all versions of
KubeMicroVM (Community and PRO). You retain full copyright ownership of your code.

---

## Prerequisites

- **Java 25** (GraalVM CE or Oracle GraalVM for native builds)
- **Maven 3.9+** (wrapper included: `./mvnw`)
- **Docker** (for container builds)
- **kubectl** configured against a Kubernetes cluster
- **Helm 3** (for chart testing)
- **Robot Framework** + Python 3.11+ (for UAT, optional)

---

## Repository Structure

```
operator-core/          CRD models, enums, state machine
operator-controller/    JOSDK reconcilers, AWS clients, token endpoint
operator-webhook/       Validating + mutating admission webhooks
operator-auth-agent/    Sidecar for auto-refreshing MicroVM auth tokens
operator-cli/           `microvm` CLI (PicoCLI, GraalVM native binary)
operator-tests/         Integration tests (Fabric8 MockServer)
uat-robot/              Robot Framework E2E tests (8 suites, 62 tests)
docs/                   User guides and design documents
```

---

## Development Workflow

### 1. Fork and clone

```bash
git clone https://github.com/<your-fork>/KubeMicroVM.git
cd KubeMicroVM
```

### 2. Create a feature branch

```bash
git checkout -b feature/my-change
```

### 3. Build

```bash
# Compile all modules (fast, no tests)
./mvnw -B install -DskipTests --no-transfer-progress

# Build native CLI (requires GraalVM)
./mvnw -pl operator-cli package -Pnative -DskipTests
```

### 4. Run integration tests

```bash
# All 49+ integration tests (mocked AWS, no cluster needed)
./mvnw -B -pl operator-tests verify --no-transfer-progress
```

All tests must pass before submitting a PR.

### 5. Run a single test class

```bash
./mvnw -B -pl operator-tests verify -Dit.test=MicroVMReconcilerIT
```

### 6. Build container images (optional)

```bash
./build-local.sh --push --registry <your-ecr-registry>

# Native image (smaller, faster startup)
./build-local.sh --native --push --registry <your-ecr-registry>
```

### 7. Run Robot Framework UAT (optional, requires live EKS cluster)

```bash
cd uat-robot
robot --outputdir results tests/
```

---

## Code Style

- **Java**: Follow existing patterns — CDI injection, JOSDK reconciler structure, status fields
- **Formatting**: Standard Java conventions (4-space indent, no tabs)
- **Commits**: Use [Conventional Commits](https://www.conventionalcommits.org/) prefixes:
  - `feat:` — new feature
  - `fix:` — bug fix
  - `chore:` — maintenance (deps, CI, docs tooling)
  - `docs:` — documentation only
  - `test:` — test additions or fixes
- **One logical change per PR** — keep PRs focused and reviewable

---

## What We Accept

- Bug fixes with a test that reproduces the issue
- Performance improvements with benchmarks or before/after metrics
- Documentation improvements (typos, clarity, new examples)
- New features that align with the project roadmap (open an issue first to discuss)
- Additional integration or E2E tests

---

## What Requires Discussion First

Open a GitHub Issue before investing significant effort on:

- New Custom Resource types
- Changes to the CRD API surface (`v1alpha1` schema)
- New external dependencies
- Architectural changes (new modules, different frameworks)
- Features that overlap with the PRO roadmap

---

## Pull Request Checklist

- [ ] CLA signed (bot will prompt you)
- [ ] Branch is up-to-date with `main`
- [ ] `./mvnw -B install -DskipTests && ./mvnw -B -pl operator-tests verify` passes
- [ ] Commit messages follow Conventional Commits
- [ ] New/changed behavior is covered by tests
- [ ] Documentation updated if user-facing behavior changed

---

## Reporting Security Issues

Do **not** open a public GitHub issue for security vulnerabilities.
Email **security@plasticity.cloud** with details. We will respond within 48 hours.

---

## Getting Help

- **Community**: ecosystem@plasticity.cloud
- **Discussions**: GitHub Discussions (coming soon)
- **Bug Reports**: GitHub Issues

Thank you for making KubeMicroVM better!
