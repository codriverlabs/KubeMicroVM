# Implementation Status

Last updated: 2026-07-08

## AWS Lambda MicroVMs API (24 operations)

| Operation | Client | Reconciler | E2E on EKS | Notes |
|-----------|--------|------------|------------|-------|
| RunMicrovm | ✅ | ✅ imageRef resolution | ✅ | |
| GetMicrovm | ✅ | ✅ poll + drift | ✅ | |
| SuspendMicrovm | ✅ | ✅ | ❌ | Integration tests pass; never verified on real cluster — see `feature/e2e-suspend-resume` |
| ResumeMicrovm | ✅ | ✅ | ❌ | Same as above |
| TerminateMicrovm | ✅ | ✅ finalizer | ✅ | |
| ListMicrovms | ✅ | — | — | CLI lists CRs only; AWS-side list not surfaced |
| CreateMicrovmAuthToken | ✅ | — | ✅ | via `--direct` flag |
| CreateMicrovmShellAuthToken | ✅ | — | ❌ | `microvm exec` not E2E tested; no integration test — see `feature/exec-shellauth` |
| TagResource | ✅ | ❌ disabled | — | API doesn't support `microvm:` resource type — blocked |
| UntagResource | ✅ | ❌ | — | Blocked (same) |
| ListTags | ✅ | ❌ | — | Blocked (same) |
| CreateMicrovmImage | ✅ | ✅ + adopt-if-exists | ✅ | Adoption verified 2026-07-08 |
| GetMicrovmImage | ✅ | ✅ poll | ✅ | |
| UpdateMicrovmImage | ✅ | ✅ generation change | ❌ | Integration tests pass; never E2E tested — see `feature/e2e-image-update-v2` |
| DeleteMicrovmImage | ✅ | ✅ finalizer | ✅ | |
| GetMicrovmImageVersion | ✅ | ✅ | ✅ | |
| ListMicrovmImageVersions | ✅ | ✅ status.versions[] | ✅ | |
| UpdateMicrovmImageVersion | ✅ | ✅ auto-activate | ✅ | |
| DeleteMicrovmImageVersion | ❌ | ❌ | — | Not implemented — see `feature/delete-image-version` |
| ListMicrovmImages | ❌ | — | — | Not implemented — P3 |
| GetMicrovmImageBuild | ✅ | ❌ | — | Client exists; build logs not surfaced in status — see `feature/image-build-logs` |
| ListMicrovmImageBuilds | ✅ | ❌ | — | Same |
| ListManagedMicrovmImages | ✅ | ❌ | — | Client exists; not wired to CLI — see `feature/base-images-cli` |
| ListManagedMicrovmImageVersions | ✅ | ❌ | — | Same |

## Lambda Core API (Network Connectors)

| Operation | Client | Reconciler | E2E on EKS |
|-----------|--------|------------|------------|
| CreateNetworkConnector | ✅ | ✅ + adopt-if-exists | ✅ |
| GetNetworkConnector | ✅ | ✅ poll | ✅ |
| UpdateNetworkConnector | ✅ | ✅ | ❌ — see `feature/e2e-network-update` |
| DeleteNetworkConnector | ✅ | ✅ finalizer + protection | ✅ |
| ListNetworkConnectors | ✅ | — | — |

## Networking Modes (E2E verified)

| Mode | Tested | Result |
|------|--------|--------|
| No egress (default) | ✅ | Outbound blocked (503) |
| Internet egress (AWS-managed) | ✅ | checkip.amazonaws.com reachable |
| VPC egress (customer-managed) | ✅ | Connector ACTIVE, VM starts |
| Connector import (`spec.connectorName`) | ✅ 2026-07-08 | Adoption verified, no duplicate |

## Import / Adoption (E2E verified 2026-07-08)

| Resource | Method | E2E |
|----------|--------|-----|
| MicroVMImage | Name-based (ARN constructed from name) | ✅ |
| MicroVMNetwork | Name-based (`spec.connectorName` or `<ns>-<name>`) | ✅ |
| MicroVM | Explicit `spec.importMicroVmId` | ✅ |

## Operator Extensions

| Feature | Code | Integration Tests | E2E on EKS | Notes |
|---------|------|-------------------|------------|-------|
| imageRef resolution by CR name | ✅ | ✅ | ✅ | |
| networkRef resolution by CR name | ✅ | ✅ | ✅ | |
| MicroVMReplicaSet reconciler | ✅ | ✅ 9 tests | ❌ | Scale up/down on real cluster never run — see `feature/e2e-replicaset-v2` |
| Token REST endpoint (operator) | ✅ | ✅ 7 tests | ❌ | In-cluster token flow never E2E tested — see `feature/e2e-token-endpoint` |
| Pod mutating webhook (sidecar) | ✅ | ✅ 5 tests | ❌ | Never verified on cluster — see `feature/e2e-sidecar-v2` |
| Validating webhook | ✅ | ❌ | ❌ | Endpoint not confirmed working on cluster; no integration tests — see `feature/webhook-fix` |
| Mutating webhook (spec defaulting) | ✅ | ❌ | ❌ | No integration tests — see `feature/webhook-fix` |
| Drift detection | ✅ | ✅ mocked | ❌ | Never tested with real external termination — see `feature/e2e-drift-v2` |
| kubectl microvm exec | ✅ | ❌ | ❌ | No integration test, no E2E — see `feature/exec-shellauth` |
| QuotaGuard (rate limiting) | ✅ | ✅ 67 tests | ✅ 2026-07-07 | Burst test: 50/50 tokens (was 0/256) |
| QuotaPolicy SPI | ✅ | ✅ | ✅ 2026-07-07 | DefaultQuotaPolicy confirmed |
| Quota discovery (install-time) | ✅ | — | ✅ 2026-07-07 | |
| Quota discovery (runtime) | ✅ | — | ❌ | `--quota-discovery=runtime` never tested — see `feature/e2e-quota-discovery` |

## Not Implemented

| Feature | Priority | Branch | Notes |
|---------|----------|--------|-------|
| DeleteMicrovmImageVersion | P2 | `feature/delete-image-version` | Version pruning |
| ListManagedMicrovmImages in CLI | P2 | `feature/base-images-cli` | `microvm image base-images` command |
| Build logs in CR status | P3 | `feature/image-build-logs` | Surface GetMicrovmImageBuild in status |
| Rolling update (ReplicaSet) | P2 | `feature/replicaset-rolling-update` | Design in docs/design/replicaset.md |
| ListMicrovmImages (AWS state) | P3 | — | CLI shows CRs only |
| Tag sync | Blocked | — | API doesn't support microvm resource type |
| Cross-namespace imageRef | P3 | — | MVP = same namespace only |
| Krew manifest | P3 | — | Distribution |
| macOS native CLI | P3 | — | Linux only for now |

## E2E Test Coverage Summary

| Area | Tested | Not Tested |
|------|--------|------------|
| MicroVMImage lifecycle | create, build, adopt, delete | update (new version) |
| MicroVM lifecycle | run, terminate, import | suspend, resume, exec |
| Networking | all 3 egress modes, adopt, connectorName | network update |
| Auth | token --direct + curl | token via operator, sidecar, exec |
| Webhooks | — | validating, mutating |
| ReplicaSet | — | scale up/down on real cluster |
| Drift | — | real external termination |
| QuotaGuard | burst test, cascade pacing | runtime quota discovery |

## Current Test Count

| Suite | Tests | Status |
|-------|-------|--------|
| Integration tests (`operator-tests`) | 74 | ✅ All pass |
| Robot Framework UAT (`uat/`) | 62 | ✅ All pass (v1.0.x) |
