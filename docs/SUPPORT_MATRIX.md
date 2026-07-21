# KubeMicroVM — Support Matrix

**Release:** v1.0.7  
**Date:** 2026-07-21  
**Test results:** [UAT v1.0.7 — 63/63 pass](../uat/results/v1.0.7/)

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
| MicroVMImage (create, build, delete) | `production-supported` | 01 Quick Start |
| MicroVMImage (adopt existing) | `integration-tested` | — |
| MicroVMImage (memory sizing) | `production-supported` | 08 Memory Sizing |
| MicroVMReplicaSet (scale up/down) | `production-supported` | 05 ReplicaSet |
| MicroVMReplicaSet (rolling update) | `production-supported` | 05 ReplicaSet |
| MicroVMNetwork (VPC egress) | `production-supported` | 03 Networking |
| MicroVMNetwork (internet egress) | `production-supported` | 03 Networking |
| MicroVMNetwork (adopt connector) | `integration-tested` | — |
| MicroVMClass (defaults inheritance) | `production-supported` | 06 MicroVMClass |

---

## Operator Features

| Feature | Maturity | UAT Suite |
|---------|----------|-----------|
| Validating webhook | `production-supported` | 02 RBAC (unlabelled ns rejected) |
| Mutating webhook (spec defaulting) | `production-supported` | 06 MicroVMClass |
| Pod sidecar injection (auth-agent) | `production-supported` | 04 Pod Token Injection |
| Token endpoint (operator sub-resource) | `production-supported` | 02 RBAC, 04 Pod Token Injection |
| Token via `--direct` flag (AWS SDK) | `production-supported` | 01 Quick Start |
| RBAC enforcement (SA → VM binding) | `production-supported` | 02 RBAC |
| QuotaGuard (API rate limiting) | `production-supported` | 05 ReplicaSet (implicit) |
| QuotaPolicy SPI (customisable limits) | `integration-tested` | — |
| Quota discovery (install-time) | `E2E-verified` | — |
| Quota discovery (runtime) | `implemented` | — |
| Leader election (HA multi-replica) | `integration-tested` | — |
| Drift detection + auto-recreate | `production-supported` | 07 Drift & Auto-Suspend |
| Auto-suspend on idle | `production-supported` | 07 Drift & Auto-Suspend |
| Auto-resume on traffic | `production-supported` | 07 Drift & Auto-Suspend |
| Namespace label selector (watch control) | `production-supported` | 02 RBAC |

---

## CLI (`microvm`)

| Command | Maturity |
|---------|----------|
| `microvm list` | `production-supported` |
| `microvm describe` | `production-supported` |
| `microvm create` | `production-supported` |
| `microvm delete` | `production-supported` |
| `microvm pause` | `production-supported` |
| `microvm resume` | `production-supported` |
| `microvm token --direct` | `production-supported` |
| `microvm token` (via operator) | `production-supported` |
| `microvm exec` | `implemented` |
| `microvm image list` | `production-supported` |
| `microvm image create` | `production-supported` |
| `microvm image base-images` | `implemented` |
| `microvm rs list` | `production-supported` |
| `microvm network list` | `production-supported` |

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
| CreateMicrovmShellAuthToken | ✅ | — | `implemented` |
| CreateMicrovmImage | ✅ | ✅ | `production-supported` |
| GetMicrovmImage | ✅ | ✅ | `production-supported` |
| UpdateMicrovmImage | ✅ | ✅ | `integration-tested` |
| DeleteMicrovmImage | ✅ | ✅ | `production-supported` |
| GetMicrovmImageVersion | ✅ | ✅ | `production-supported` |
| ListMicrovmImageVersions | ✅ | ✅ | `production-supported` |
| UpdateMicrovmImageVersion | ✅ | ✅ | `production-supported` |
| DeleteMicrovmImageVersion | ❌ | ❌ | `not-implemented` |
| ListMicrovmImages | ❌ | — | `not-implemented` |
| GetMicrovmImageBuild | ✅ | — | `implemented` |
| ListMicrovmImageBuilds | ✅ | — | `implemented` |
| ListManagedMicrovmImages | ✅ | — | `implemented` |
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

## Not Implemented / Planned

| Feature | Priority | Notes |
|---------|----------|-------|
| DeleteMicrovmImageVersion | P2 | Version pruning |
| ListManagedMicrovmImages in CLI | P2 | `microvm image base-images` (client exists, CLI not wired) |
| Build logs in CR status | P3 | Surface GetMicrovmImageBuild output |
| Cross-namespace imageRef | P3 | Current: same namespace only |
| Tag sync | Blocked | AWS API doesn't support `microvm:` resource type |
| macOS native CLI | P3 | Linux amd64/arm64 only |

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

## Test Counts (v1.0.7)

| Suite | Tests | Status |
|-------|-------|--------|
| Integration tests (`operator-tests`) | 81 | ✅ All pass |
| Robot Framework UAT (`uat/`) | 63 | ✅ All pass |
| Property-based tests (jqwik) | included in 81 | ✅ |
