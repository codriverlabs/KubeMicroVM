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

## Pass Matrix (v1.0.17 GA vs m80 v0.4.1)

First run: 2026-09-15. **61 of 72 pass** (after UAT timing fixes).

| Suite | Pass | Notes |
|-------|------|-------|
| 00 Cluster Setup | 6/7 | Pod Identity check always fails on k3d (no EKS) |
| 01 Quick Start | 7/9 | QS-07/08: endpoint auth group (see below) |
| 02 RBAC | 8/8 ✅ | |
| 03 Networking | 2/5 | NET-01/04: poll race; NET-02: endpoint auth |
| 04 Pod Token Injection | 8/9 | INJ-08: endpoint auth |
| 05 ReplicaSet | 6/6 ✅ | RS-06 fixed: label-scoped VM poll + m80 v0.4.1 idempotent terminate |
| 06 MicroVMClass | 6/6 ✅ | |
| 07 Drift Autosuspend | 4/5 | AUTO-02: endpoint auth |
| 08 Memory Sizing | 5/6 | MEM-07: endpoint auth |
| 11 Admission | 7/9 | ADM-08: m80 uses `latest` image tag; ADM-09: m80 fixture gap |
| 99 Cleanup | 1/2 | Debris from prior run on same cluster |

**Total: 61/72**

> Note: ADM-08 fails because `make m80-up` installs the operator using the
> `latest` OCI image tag from GHCR (the chart's default), not the specific
> version you set via `CHART_VERSION`. Pass `--set app.image=ghcr.io/codriverlabs/kube-microvm-operator:v1.0.17`
> to pin the image explicitly. The ARN collision webhook fix ships in v1.0.17 GA.

### Why they fail

#### Endpoint auth (5 failures: QS-07, NET-02, INJ-08, AUTO-02, MEM-07)

The UAT calls `https://<uuid>.lambda-microvm.<region>.on.aws/` — the real AWS
hostname. It resolves to real AWS, which rejects the m80-issued token with
`Token authentication failed`. The call never reaches m80.

Fix requires wildcard DNS + TLS in m80 so the cluster resolves those hostnames
to m80 instead. Tracked in
[INTENTIUS/m80#45](https://github.com/INTENTIUS/m80/issues/45).

#### Poll race (2 failures: NET-01, NET-04)

The test polls `status.endpointUrl` with a 90s timeout. The operator's resync
cycle is 61–65s against m80, which fits in 90s but occasionally loses to a
2-cycle delay. These tests win or lose run-to-run.

#### No Pod Identity (1 failure: 00 cluster setup)

k3d is not EKS; there is no Pod Identity association. This check is expected to
fail and is acknowledged in m80's documentation.

Fix: the k3s-xpress cluster provider will include Pod Identity.

#### ADM-08 uses wrong operator image (1 failure)

ADM-08 tests the ARN collision webhook. `make m80-up` installs the chart from
a local tgz but the operator image defaults to the `latest` GHCR tag, which
may not be `v1.0.17`. Override with:

```bash
make m80-up CHART_VERSION=1.0.17 \
  M80_HELM_SET="--set app.image=ghcr.io/codriverlabs/kube-microvm-operator:v1.0.17"
```

Until the Makefile supports this override, ADM-08 is expected to fail unless
the `latest` tag happens to point at v1.0.17.

#### ADM-09 m80 gap (1 failure)

`ADM-09` asserts that deleting a `MicroVMImage` while VMs are running emits a
`DeleteBlocked` Warning event. This path is triggered when the Lambda API returns
`ValidationException: Cannot delete microvm image with running microvms`.

m80 v0.4.1 does not return this error — it accepts the delete unconditionally.
The operator's delete-blocked path (Layer 2 of the ARN collision prevention fix)
never fires.

**Action**: file an issue against INTENTIUS/m80 requesting a fixture for
delete-image-with-running-vms returning the recorded `ValidationException`.
Once m80 implements it, ADM-09 will pass without any operator changes.

#### 99 Cleanup debris (1 failure)

Inherits from prior suites that left VMs behind (endpoint-auth failures or
m80 restart orphans). Will clear when the inheriting failures are fixed.

## Known Limitations

| Limitation | Reason | Fix path |
|---|---|---|
| VM endpoint URLs resolve to real AWS | m80 endpoints use random UUIDs; cluster has no wildcard DNS | m80#45 |
| ADM-09 passes only on real AWS | m80 doesn't return delete-blocked ValidationException | File against m80 |
| Pod Identity check fails | k3d is not EKS | Use k3s-xpress provider |
| `--direct` CLI flag ignores endpoint override | `microvm --direct` builds its own SDK client that bypasses `AWS_MICROVM_ENDPOINT` | By design; untestable against any emulator |
| m80 state is in-memory | Restarting m80 orphans all CR finalizers | Always use `make m80-down` to tear down cleanly; never restart m80 under a live operator |

## File Reference

| File | Purpose |
|------|---------|
| `Makefile` | `full`, `m80-up`, `m80-run`, `m80-down`, `m80-clean` targets |
| `uat/m80-up-wrapper.sh` | Intercepts `helm install` in m80's `up.sh`; substitutes local tgz when available |
| `uat/k3s-xpress-up.sh` | Cluster setup for the k3s-xpress provider |
| `uat/bootstrap-ca.sh` | Manual CA secret generation fallback (not used in normal flow) |
| `operator-controller/src/main/helm/templates/cluster-issuer.yaml` | `ClusterIssuer` with `post-install` hook (fixes chicken-and-egg) |
| `operator-controller/pom.xml` | `exec-maven-plugin` `repackage-helm-chart` — re-seals tgz after overlay copy |

## Related

- m80 documentation: https://intentius.github.io/m80/
- m80 KubeMicroVM guide: https://intentius.github.io/m80/kubemicrovm/
- [docs/design/ca-distribution.md](ca-distribution.md) — operator CA and ClusterIssuer design
- [docs/design/robot-framework-uat.md](robot-framework-uat.md) — UAT suite structure
