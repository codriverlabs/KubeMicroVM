# m80 Local Testing

## Overview

[m80](https://github.com/INTENTIUS/m80) is an open-source AWS Lambda MicroVMs API
emulator by INTENTIUS. It implements all 29 API operations against recorded fixtures
from live AWS, runs as a single 8 MiB container, and needs no AWS account or
credentials.

KubeMicroVM's full UAT suite can run against m80 via a local [k3d](https://k3d.io)
cluster. This gives a zero-cost, zero-credential confidence gate that runs in ~5
minutes instead of ~90 minutes on real AWS — and catches operator bugs before they
reach AWS (m80 found and helped fix three operator bugs:
[#51](https://github.com/codriverlabs/KubeMicroVM/issues/51) finalizer stuck,
[#50](https://github.com/codriverlabs/KubeMicroVM/issues/50) STS unreachable,
[#52](https://github.com/codriverlabs/KubeMicroVM/issues/52) Helm env key drop).

## Quick Start

```bash
# Prerequisites: docker, k3d, kubectl, helm, node >= 20, npm
# m80 is cloned automatically into .m80/

make full                     # clone m80, spin up k3d, run UAT, tear down
make m80-up && make m80-run   # step-by-step (leaves cluster running between runs)
make m80-down                 # tear down

# Use a specific chart version (default: nearest git tag)
make m80-up CHART_VERSION=1.0.17

# Test a local m80 build
make m80-up M80_IMAGE=m80:my-branch
```

Results land in `uat/results/m80/report.html`.

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│  k3d cluster (m80-uat)                                  │
│                                                         │
│  ┌──────────────────┐    ┌──────────────────────────┐  │
│  │   m80 container  │    │  kube-microvm-operator   │  │
│  │  (8 MiB, Go)     │◄───│  (v1.0.17 GA, Quarkus)  │  │
│  │                  │    │                          │  │
│  │  • all 29 API    │    │  AWS_MICROVM_ENDPOINT    │  │
│  │    operations    │    │  → http://m80.kube-      │  │
│  │  • state machine │    │    microvm.svc:4290      │  │
│  │  • sts shim      │    │                          │  │
│  └──────────────────┘    └──────────────────────────┘  │
│                                                         │
│  ┌──────────────────────────────────────────────────┐  │
│  │  cert-manager + Robot Framework runner           │  │
│  └──────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────┘
       ▲
       │ KUBEMICROVM=/path/to/KubeMicroVM make m80-run
       │ (Robot runner joins k3d's docker network)
```

The operator is configured with two env var overrides:

| Variable | Value | Why |
|----------|-------|-----|
| `AWS_MICROVM_ENDPOINT` | `http://m80.kube-microvm.svc:4290` | Routes all Lambda MicroVMs API calls to m80 |
| `AWS_ENDPOINT_URL_STS` | `http://m80.kube-microvm.svc:4290` | Routes `sts:GetCallerIdentity` to m80's STS shim; required for the operator's startup health gate ([#50](https://github.com/codriverlabs/KubeMicroVM/issues/50)) |

Credentials are set to `test`/`test` — m80 validates no signature, only that a credential scope is present.

## Cluster Provider

The `CLUSTER_PROVIDER` Makefile variable selects how the cluster is set up.

### `k3d` (default)

Uses [k3d](https://k3d.io) to spin up a local k3s cluster in Docker. This is
what m80's own harness uses. The Makefile delegates to `m80/uat/up.sh` for cluster
creation, cert-manager, and m80 deployment, then substitutes our local chart if
one is built.

### `k3s-xpress` (future)

Deploys m80 and the operator into an existing
[k3s-xpress](https://github.com/codriverlabs/k3s-xpress) cluster. k3s-xpress
includes an EKS Pod Identity layer, which is the production auth mechanism — this
provider tests against it instead of static `test`/`test` credentials.

```bash
make full CLUSTER_PROVIDER=k3s-xpress K3S_XPRESS_CLUSTER=my-cluster
```

The `m80-run` step is provider-agnostic; only `_cluster-up` and `_cluster-down`
differ. See `uat/k3s-xpress-up.sh`.

## Chart Bootstrap Fix (ClusterIssuer Chicken-and-Egg)

Starting in v1.0.16, the Helm chart includes a `ClusterIssuer` for cross-namespace
gateway TLS (see `docs/design/ca-distribution.md`). cert-manager validates the
`ClusterIssuer` synchronously at `helm install` time — but the CA Secret it
references (`kube-microvm-operator-ca`) doesn't exist yet. It's created by a
cert-manager `Certificate` CR that cert-manager reconciles after install. Install
fails with:

```
Error getting keypair for CA issuer: secrets "kube-microvm-operator-ca" not found
```

**Fix**: `cluster-issuer.yaml` uses `helm.sh/hook: post-install,post-upgrade` so
cert-manager sees it only after the `Certificate` CR has been reconciled and the
Secret created. Verified: fresh installs and upgrades both succeed.

No behaviour change for EKS deployments — on upgrade the Secret already exists, so
the hook is a no-op for production.

## Local Chart Substitution

m80's `up.sh` always installs from `oci://ghcr.io/codriverlabs/helm/kube-microvm-operator`.
This makes it impossible to test chart changes before releasing.

`uat/m80-up-wrapper.sh` wraps `up.sh` with a `helm` shim: when
`operator-controller/target/helm/kubernetes/` contains a built `.tgz`, the shim
intercepts the `helm install` command and substitutes the local path. The OCI ref
is used unchanged when no local chart is present (i.e. CI with a released version).

To test a chart change locally:

```bash
./mvnw -pl operator-controller package -DskipTests -q
make m80-up   # will find and use the local tgz
```

## Pass Matrix (v1.0.19 GA vs m80, CI release-gate run)

Latest CI run: 2026-10-06 (v1.0.19 release gate, `RELEASE_GATE=true`).
**63 of 64 pass, 1 skip.**

| Suite | Pass | Notes |
|-------|------|-------|
| 00 Cluster Setup | 6/6 ✅ (+1 skip) | Pod Identity check correctly skipped via `EMULATED=true` |
| 01 Quick Start | 7/7 ✅ | `QS-00` excluded under `RELEASE_GATE=true` (see below) |
| 02 RBAC | 8/8 ✅ | |
| 03 Networking | 2/2 ✅ | `NET-01/02/04` tagged `m80-endpoint-auth`, excluded under `EMULATED=true` |
| 04 Pod Token Injection | 8/8 ✅ | `INJ-08` tagged `m80-endpoint-auth`, excluded |
| 05 ReplicaSet | 6/6 ✅ | |
| 06 MicroVMClass | 6/6 ✅ | |
| 07 Drift Autosuspend | 4/4 ✅ | `AUTO-02` tagged `m80-endpoint-auth`, excluded |
| 08 Memory Sizing | 5/5 ✅ | `MEM-07` tagged `m80-endpoint-auth`, excluded |
| 11 Admission | 9/9 ✅ | |
| 99 Cleanup | 2/2 ✅ | |

**Total: 63/64 passed, 1 skipped** — a clean run with no cluster-level or
resource-leak failures. The real m80 endpoint-auth limitation (6 tests, see
below) is excluded by default on `k3d`/m80 via `EMULATED=true`, and `QS-00`'s
release-gate circular dependency is excluded via `RELEASE_GATE=true` — both
documented above. Confirmed separately against **real EKS**: all tests
including the 6 `m80-endpoint-auth`-tagged ones pass (72/72), validating that
the exclusions are scoped correctly to the emulator's actual limitation rather
than hiding a real bug.

### Why `m80-endpoint-auth` tests don't run against m80

#### Endpoint auth (6 tests: QS-07, NET-01/02/04, INJ-08, AUTO-02, MEM-07)

The UAT calls `https://<uuid>.lambda-microvm.<region>.on.aws/` — the real AWS
hostname. It resolves to real AWS, which rejects the m80-issued token with
`Token authentication failed`. The call never reaches m80.

Fix requires wildcard DNS + TLS in m80 so the cluster resolves those hostnames
to m80 instead. Tracked in
[INTENTIUS/m80#45](https://github.com/INTENTIUS/m80/issues/45). These tests
pass on real EKS (confirmed) — tagged `m80-endpoint-auth` and excluded only
when `EMULATED=true`.

## CI Release Gate (native-build.yml `uat-m80` job)

Since v1.0.19, `make full` (via `uat-m80` in `.github/workflows/native-build.yml`)
also runs as a **release gate**: the `release` job (which creates the GitHub
Release) depends on `uat-m80` passing first. This surfaced two instances of the
same chicken-and-egg problem — a test or build step depending on
`releases/latest`, which cannot be complete while the release it's testing is
still being gated by that same step.

### Problem 1: m80's Dockerfile fetches the CLI from `releases/latest`

`.m80/uat/Dockerfile` (third-party, re-cloned fresh on every run — not our code)
builds its test-runner container with:

```dockerfile
RUN curl -fsSL -o /usr/local/bin/microvm \
      "https://github.com/codriverlabs/KubeMicroVM/releases/latest/download/microvm-linux-${TARGETARCH}" \
    && chmod +x /usr/local/bin/microvm
```

When `uat-m80` gates a *new* release, `releases/latest` is either the *previous*
release (stale) or incomplete/in-flux (if assets are still being uploaded) —
either way this is wrong or fails outright (`curl` exit 22 / HTTP 404), and fails
identically on every retry since `releases/latest`'s state doesn't change between
attempts.

**Fix**: `uat/patch-m80-dockerfile.sh`, invoked by `make m80-run` right before
calling `.m80/uat/run.sh`, rewrites that `RUN curl ...` line to `COPY` in a
locally-provided `microvm-linux-${TARGETARCH}` binary instead — found via
`MICROVM_CLI_AMD64`/`MICROVM_CLI_ARM64` env overrides, a `microvm-linux-<arch>`
file at the repo root (how CI provides it — `uat-m80` downloads the
`microvm-linux-amd64` artifact from the `native-cli` job it depends on), or a
local `operator-cli/target/microvm-runner` build. If none of these are found,
the Dockerfile is left untouched and falls back to the original
`releases/latest` behavior — so plain `make full` without a pre-built CLI still
works for anyone not hitting this specific gate scenario.

### Problem 2: `QS-00` tests the installer script from `releases/latest`

`uat/tests/01_quick_start.robot`'s `QS-00` downloads `install_kube_microvm.sh`
directly from `releases/latest` as part of testing the real end-user install
flow. Same root cause, at the test-content level instead of the build-
infrastructure level: this test can only pass against an *already-published*
release, and can never pass as part of the gate for the release it's testing.

**Fix**: `QS-00` is tagged `release-gate-skip`. The Makefile's `RELEASE_GATE`
variable (default `false`) excludes that tag only when set to `true`:

```bash
make full RELEASE_GATE=true   # excludes release-gate-skip-tagged tests
make full                     # runs everything, including QS-00 (default)
```

CI's `uat-m80` job passes `RELEASE_GATE=true`. Any other context — local dev,
ad-hoc verification against an already-published release — still runs `QS-00`
normally, where it's a legitimate and valuable test.

Use the `release-gate-skip` tag for any future test with the same shape
(anything that depends on `releases/latest` reflecting a *settled, prior*
release rather than the one currently being gated).

### Diagnosing a failed `uat-m80` CI run

GitHub's log/artifact downloads require repo-admin auth even on a public repo —
confirm `gh auth status` shows a token with sufficient scope before relying on
`gh run view --log` / artifact downloads. If no working token is available, the
most reliable fallback is cloning the exact failing tag/commit fresh and running
`make full` locally — this reproduces real failures (confirmed against this
exact circular-dependency bug) since the external-dependency issues (like
`releases/latest` state) are environment-independent.

## Known Limitations

| Limitation | Reason | Fix path |
|---|---|---|
| VM endpoint URLs resolve to real AWS | m80 endpoints use random UUIDs; cluster has no wildcard DNS | m80#45 |
| Pod Identity check skipped under m80 | k3d is not EKS | Use k3s-xpress provider, or verify on real EKS (confirmed 72/72) |
| `QS-00` can't pass as part of its own release's gate | downloads `install_kube_microvm.sh` from `releases/latest`, which isn't complete yet | Tagged `release-gate-skip`, excluded via `RELEASE_GATE=true` in CI only |
| `--direct` CLI flag ignores endpoint override | `microvm --direct` builds its own SDK client that bypasses `AWS_MICROVM_ENDPOINT` | By design; untestable against any emulator |
| m80 state is in-memory | Restarting m80 orphans all CR finalizers | Always use `make m80-down` to tear down cleanly; never restart m80 under a live operator |

## File Reference

| File | Purpose |
|------|---------|
| `Makefile` | `full`, `m80-up`, `m80-run`, `m80-down`, `m80-clean` targets; `EMULATED`, `RELEASE_GATE` vars |
| `uat/m80-up-wrapper.sh` | Intercepts `helm install` in m80's `up.sh`; substitutes local tgz when available |
| `uat/patch-m80-dockerfile.sh` | Rewrites m80's `uat/Dockerfile` to use a local `microvm` CLI binary instead of `releases/latest`, when available |
| `uat/k3s-xpress-up.sh` | Cluster setup for the k3s-xpress provider |
| `uat/bootstrap-ca.sh` | Manual CA secret generation fallback (not used in normal flow) |
| `operator-controller/src/main/helm/templates/cluster-issuer.yaml` | `ClusterIssuer` with `post-install` hook (fixes chicken-and-egg) |
| `operator-controller/pom.xml` | `exec-maven-plugin` `repackage-helm-chart` — re-seals tgz after overlay copy |
| `.github/workflows/native-build.yml` | `uat-m80` job — runs this suite as a CI release gate with `RELEASE_GATE=true` |

## Related

- m80 documentation: https://intentius.github.io/m80/
- m80 KubeMicroVM guide: https://intentius.github.io/m80/kubemicrovm/
- [docs/design/ca-distribution.md](ca-distribution.md) — operator CA and ClusterIssuer design
- [docs/design/robot-framework-uat.md](robot-framework-uat.md) — UAT suite structure
