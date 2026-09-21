# KubeMicroVM — Roadmap

**Current release:** v1.0.18 (Community) / v1.1.1 (PRO)
**Last updated:** 2026-09-21

This document tracks planned improvements grouped by theme. Items are not
committed to specific release dates. PRO items require a KubeMicroVM PRO
licence.

---

## Recently Shipped (v1.0.17 / v1.0.18)

| Feature | Release | Notes |
|---------|---------|-------|
| ARN collision prevention — duplicate `MicroVMImage` names rejected by webhook | v1.0.17 | ADM-08/09 UAT |
| `DeleteBlocked` events with capped exponential backoff | v1.0.17 | ADM-09 UAT |
| `CaSecretReplicator` tls.crt/tls.key fix | v1.0.17 | Gateway TLS in managed namespaces |
| ClusterIssuer post-install hook | v1.0.17 | Fixes fresh installs |
| m80 local UAT harness | v1.0.17 | `make full` — no AWS needed |
| Reconciliation intervals documented | v1.0.17 | 60s RESYNC_PERIOD |
| Pod Identity verification in cluster setup | v1.0.18 | CS-05 UAT, hard-stop on missing IAM |
| `install_kube_microvm.sh --edition pro` | v1.0.18 | Single installer for CE and PRO |
| `--helm-registry` for air-gapped ECR deployments | v1.0.18 | Helm chart from private ECR |
| **PRO:** `MicroVMImageBinding` / `MicroVMImagePolicy` CRDs | PRO v1.1.1 | Cross-namespace imageRef |
| **PRO:** `MicroVMGateway` — session-affine HTTP proxy | PRO v1.1.1 | Exclusive session + round-robin |
| **PRO:** Multi-tenant namespace isolation | PRO v1.1.1 | MT UAT |
| **PRO:** Community + PRO combined UAT (`run-full.sh`) | PRO v1.1.1 | 38/38 published |

---

## Near-term (v1.0.19 / v1.1.2)

### UAT gaps → `production-supported`

Several CLI commands are `production-supported` by implementation but not
explicitly covered by the release UAT gate. Adding explicit CLI assertion
steps would promote them fully:

| Command | Gap | Proposed test |
|---------|-----|---------------|
| `microvm create` | Uses kubectl in UAT | Add to QS suite |
| `microvm delete` | Uses kubectl in UAT | Add to QS teardown |
| `microvm pause` | Not explicitly called | Add to drift suite |
| `microvm resume` | Not explicitly called | Add to drift suite |
| `microvm token` (via operator) | Uses raw HTTP in UAT | Add to RBAC suite |
| `microvm image list` | Not called in UAT | Add to quick-start |
| `microvm image create` | Uses kubectl in UAT | Add to quick-start |
| `microvm rs list` | Not called in UAT | Add to replicaset suite |
| `microvm network list` | Called in NET-05 ✅ | Already covered — update matrix |

### `integration-tested` → `E2E-verified`

| Feature | What's needed |
|---------|---------------|
| `MicroVMImage (adopt existing)` | UAT test: create image externally, apply matching CR |
| `MicroVM (import by ID)` | UAT test: run VM via AWS CLI, import |
| `MicroVMReplicaSet (health eviction)` | UAT test: inject VM failure, verify eviction |

### Infrastructure

- **Public PRO UAT repo** (`KubeMicroVM-PRO-UAT`) — run PRO UAT publicly via ECP cluster + GitHub OIDC, publish live badge and report (see `docs/design/public-uat-pipeline.md`)
- **Dependabot PRs** — merge JOSDK 5.5.1→5.6.0, Quarkus 3.39.2→3.39.3, AWS SDK, Fabric8 (held pending v1.0.18 GA validation)

---

## Medium-term

### Community

| Feature | Priority | Notes |
|---------|----------|-------|
| `microvm logs` | P2 | Streams CloudWatch logs via operator |
| `microvm rs scale` | P2 | CLI wrapper for scale operation |
| `microvm image describe` | P2 | Already impl + MEM-05 UAT — promote to `production-supported` |
| `MicroVMImage (version pruning)` | P2 | Prune old versions on build |
| Leader election / HA multi-replica | P2 | Currently single-replica only |
| Quota discovery (runtime) | P3 | Operator queries quotas on startup |
| Micrometer metrics — Prometheus scrape | P3 | Counters and timers already emitted |
| `ListMicrovmImages` (AWS state) | P3 | CLI shows CRs only, not raw AWS list |
| macOS native CLI | P3 | Currently Linux amd64/arm64 only |
| Krew manifest | P3 | Distribution via `kubectl krew install microvm` |

### PRO

| Feature | Priority | Notes |
|---------|----------|-------|
| `MicroVMImagePolicy` enforcement in gateway | P1 | Policy CRD shipped, enforcement pending |
| TC-06/07/08 idle suspend in exclusive session | P1 | Timing-sensitive; needs gateway config with short timeout |
| ECP Workload Identity integration | P1 | Replace EKS Pod Identity for k3s-xpress deployments |
| ECP cluster auto-cleanup on resume | P2 | Eliminate client-side cleanup step in `run-full.sh` |
| `install_kube_microvm.sh` — PRO version auto-resolve | P2 | Currently falls back to CE version if GHCR unavailable |

---

## Long-term / Under Consideration

| Feature | Notes |
|---------|-------|
| Windows CLI binary | ARM64 Macs via Rosetta workaround today |
| Tag sync (`microvm:` resource type) | Blocked by AWS API — no `microvm:` ARN prefix supported |
| Cross-account MicroVM access | Requires CARM-style federation |
| `MicroVMNetwork (delete protection — in-use)` | Prevents network deletion when VMs still attached |
| `MicroVMReplicaSet (suspend/resume cascade)` | Cascade suspend to all pool VMs |
| SPI: QuotaPolicy | Pluggable quota enforcement (PRO) |

---

## Not Planned

| Feature | Reason |
|---------|--------|
| ACK controller replacement | KubeMicroVM is a higher-level product layer, not an ACK pattern |
| CARM / FieldExport / read-only adopted resources | ACK-specific patterns not in scope |
| Generic Kubernetes distributions (non-AWS) | Lambda MicroVMs API is AWS-only |
