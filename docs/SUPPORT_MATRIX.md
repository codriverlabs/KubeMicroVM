# KubeMicroVM — Support Matrix

**Release:** v1.0.12  
**Date:** 2026-08-05  
**Test results:** [UAT v1.0.12-rc1 — 63/63 pass](../uat/results/v1.0.12-rc1/)

---

## Maturity Levels

| Level | Meaning |
|-------|---------|
| `production-supported` | E2E verified, documented in user guide, covered by release UAT |
| `E2E-verified` | Passes live EKS UAT but not yet in user guide |
| `integration-tested` | Passes mocked integration tests only |
| `implemented` | Code exists, no automated test coverage |
| `not-implemented` | Not yet built |
| `blocked` | Cannot implement due to AWS API limitation |

---

## Custom Resources

| Resource | Maturity | UAT Suite |
|----------|----------|-----------|
| MicroVM (create, run, terminate) | `production-supported` | 01 Quick Start |
| MicroVM (suspend, resume) | `production-supported` | 07 Drift & Auto-Suspend |
| MicroVM (drift detection, re-create) | `production-supported` | 07 Drift & Auto-Suspend |
| MicroVM (import by ID) | `integration-tested` | — |
| MicroVM (networkRef resolution) | `integration-tested` | — |
| MicroVMImage (create, build, delete) | `production-supported` | 01 Quick Start |
| MicroVMImage (adopt existing) | `integration-tested` | — |
| MicroVMImage (memory sizing) | `production-supported` | 08 Memory Sizing |
| MicroVMImage (version pruning) | `integration-tested` | — |
| MicroVMImage (generation update) | `integration-tested` | — |
| MicroVMReplicaSet (scale up/down) | `production-supported` | 05 ReplicaSet |
| MicroVMReplicaSet (rolling update) | `production-supported` | 05 ReplicaSet |
| MicroVMReplicaSet (health eviction) | `integration-tested` | — |
| MicroVMReplicaSet (suspend/resume cascade) | `integration-tested` | — |
| MicroVMNetwork (VPC egress) | `production-supported` | 03 Networking |
| MicroVMNetwork (internet egress) | `production-supported` | 03 Networking |
| MicroVMNetwork (adopt connector) | `integration-tested` | — |
| MicroVMNetwork (delete protection — in-use) | `integration-tested` | — |
| MicroVMClass (defaults inheritance) | `production-supported` | 06 MicroVMClass |
| MicroVMClass (validation — non-existent class) | `production-supported` | 06 MicroVMClass |

---

## Operator Features

| Feature | Maturity | UAT Suite | Integration Tests |
|---------|----------|-----------|-------------------|
| Validating webhook | `production-supported` | 02 RBAC, 06 Class, 08 Memory | 12 + 5 property |
| Mutating webhook (spec defaulting) | `production-supported` | 06 MicroVMClass | property tests |
| Pod sidecar injection (auth-agent) | `production-supported` | 04 Pod Token Injection | 5 |
| Token endpoint (operator sub-resource) | `production-supported` | 02 RBAC, 04 Pod Token Injection | 7 |
| Token via `--direct` flag (AWS SDK) | `production-supported` | 01 Quick Start | — |
| RBAC enforcement (SA → VM binding) | `production-supported` | 02 RBAC | 7 (TokenResource) |
| QuotaGuard (API rate limiting) | `production-supported` | 05 ReplicaSet (implicit) | 11 (ReplicaSet) |
| QuotaPolicy SPI (customisable limits) | `integration-tested` | — | 13 (SPI defaults) |
| Quota discovery (install-time) | `E2E-verified` | — | — |
| Quota discovery (runtime) | `implemented` | — | — |
| Leader election (HA multi-replica) | `integration-tested` | — | — |
| Drift detection + auto-recreate | `production-supported` | 07 Drift & Auto-Suspend | 11 (Reconciler) |
| Auto-suspend on idle | `production-supported` | 07 Drift & Auto-Suspend | — |
| Auto-resume on traffic | `production-supported` | 07 Drift & Auto-Suspend | — |
| Namespace label selector (watch control) | `production-supported` | 02 RBAC | — |
| AWS connectivity health check | `implemented` | — | — |
| Operator liveness/readiness probes | `production-supported` | 00 Cluster Setup | — |
| Micrometer metrics (counters, timers) | `implemented` | — | — |
| SPI: ImageRefResolver | `integration-tested` | — | 13 (SPI defaults) |
| SPI: TenantResolver | `integration-tested` | — | 13 (SPI defaults) |
| SPI: TokenPolicy | `integration-tested` | — | 13 (SPI defaults) |

---

## CLI (`microvm`)

| Command | Maturity | Notes |
|---------|----------|-------|
| `microvm list` | `production-supported` | |
| `microvm describe` | `production-supported` | |
| `microvm create` | `production-supported` | |
| `microvm delete` | `production-supported` | |
| `microvm pause` | `production-supported` | |
| `microvm resume` | `production-supported` | |
| `microvm start` | `implemented` | Alias for resume |
| `microvm stop` | `implemented` | Alias for pause |
| `microvm logs` | `implemented` | |
| `microvm token --direct` | `production-supported` | |
| `microvm token` (via operator) | `production-supported` | |
| `microvm exec` | `implemented` | Shell auth token |
| `microvm image list` | `production-supported` | |
| `microvm image create` | `production-supported` | |
| `microvm image describe` | `implemented` | |
| `microvm image update` | `implemented` | |
| `microvm image delete` | `implemented` | |
| `microvm image base-images` | `implemented` | Lists AWS-managed base images |
| `microvm image version-delete` | `implemented` | |
| `microvm rs list` | `production-supported` | |
| `microvm rs describe` | `implemented` | |
| `microvm rs scale` | `implemented` | |
| `microvm network list` | `production-supported` | |
| `microvm network describe` | `implemented` | |

---

## AWS API Coverage

### Lambda MicroVMs API

| Operation | Client | Reconciler | Maturity |
|-----------|--------|------------|----------|
| RunMicrovm | ✅ | ✅ | `production-supported` |
| GetMicrovm | ✅ | ✅ | `production-supported` |
| SuspendMicrovm | ✅ | ✅ | `production-supported` |
| ResumeMicrovm | ✅ | ✅ | `production-supported` |
| TerminateMicrovm | ✅ | ✅ | `production-supported` |
| ListMicrovms | ✅ | — | `implemented` |
| CreateMicrovmAuthToken | ✅ | — | `production-supported` |
| CreateMicrovmShellAuthToken | ✅ | — | `integration-tested` |
| CreateMicrovmImage | ✅ | ✅ | `production-supported` |
| GetMicrovmImage | ✅ | ✅ | `production-supported` |
| UpdateMicrovmImage | ✅ | ✅ | `integration-tested` |
| DeleteMicrovmImage | ✅ | ✅ | `production-supported` |
| GetMicrovmImageVersion | ✅ | ✅ | `production-supported` |
| ListMicrovmImageVersions | ✅ | ✅ | `production-supported` |
| UpdateMicrovmImageVersion | ✅ | ✅ | `production-supported` |
| DeleteMicrovmImageVersion | ✅ | ✅ | `integration-tested` |
| ListMicrovmImages | ❌ | — | `not-implemented` |
| GetMicrovmImageBuild | ✅ | — | `implemented` |
| ListMicrovmImageBuilds | ✅ | — | `implemented` |
| ListManagedMicrovmImages | ✅ | — | `integration-tested` |
| ListManagedMicrovmImageVersions | ✅ | — | `implemented` |
| TagResource | ✅ | — | `blocked` |
| UntagResource | ✅ | — | `blocked` |
| ListTags | ✅ | — | `blocked` |

### Lambda Core API (Network Connectors)

| Operation | Client | Reconciler | Maturity |
|-----------|--------|------------|----------|
| CreateNetworkConnector | ✅ | ✅ | `production-supported` |
| GetNetworkConnector | ✅ | ✅ | `production-supported` |
| UpdateNetworkConnector | ✅ | ✅ | `integration-tested` |
| DeleteNetworkConnector | ✅ | ✅ | `production-supported` |
| ListNetworkConnectors | ✅ | — | `implemented` |

---

## Helm Chart Features

| Feature | Status | Notes |
|---------|--------|-------|
| CRD installation | ✅ | Included in chart |
| cert-manager integration (TLS) | ✅ | Self-signed issuer chain |
| RBAC (operator SA) | ✅ | ClusterRole + bindings |
| RBAC personas (reader/writer) | ✅ | `microvm-reader`, `microvm-writer` ClusterRoles |
| Leader election RBAC (Lease) | ✅ | Role + RoleBinding in operator namespace |
| Token auth RBAC (TokenReview/SAR) | ✅ | ClusterRole + binding |
| Webhook RBAC (namespace/class lookup) | ✅ | ClusterRole + binding |
| Validating webhook config | ✅ | cert-manager certificate |
| Mutating webhook config (pod injection) | ✅ | failurePolicy: Ignore |
| `app.envs.*` passthrough | ✅ | All operator config via env vars |
| Multi-arch images (amd64/arm64) | ✅ | Built by CI |

---

## Not Implemented / Planned

| Feature | Priority | Notes |
|---------|----------|-------|
| ListMicrovmImages (AWS state) | P3 | CLI shows CRs only |
| Cross-namespace imageRef | P3 | Current: same namespace only |
| Tag sync | Blocked | AWS API doesn't support `microvm:` resource type |
| macOS native CLI | P3 | Linux amd64/arm64 only |
| Krew manifest | P3 | Distribution |

---

## What KubeMicroVM Is Not

KubeMicroVM is **not** an AWS ACK controller replacement. It does not implement:
- CARM (Cross-Account Resource Management)
- IAMRoleSelector / FieldExport
- Read-only adopted resources
- Generic ACK controller patterns

KubeMicroVM is a **higher-level Kubernetes product layer** for AWS Lambda MicroVMs,
adding workload orchestration, admission control, token delivery, quota management,
and CLI workflows beyond the official ACK controller.

---

## Test Counts (v1.0.12)

| Suite | Tests | Status |
|-------|-------|--------|
| Integration tests (`operator-tests`) | 81 | ✅ All pass |
| Webhook unit/property tests | 17 | ✅ All pass |
| CLI property tests | 2 | ✅ All pass |
| Robot Framework UAT (`uat/`) | 63 | ✅ All pass |
| Performance UAT (optional) | 8 | ⚠️ Account-limit dependent |
| **Total automated tests** | **186** | |
