# Implementation Status

Last updated: 2026-07-01 (post v1.0.0-rc1 E2E validation)

## AWS Lambda MicroVMs API (24 operations)

| Operation | Client | Reconciler | E2E on EKS | Notes |
|-----------|--------|------------|------------|-------|
| RunMicrovm | ✅ | ✅ imageRef resolution | ✅ | |
| GetMicrovm | ✅ | ✅ poll + drift | ✅ | |
| SuspendMicrovm | ✅ | ✅ | ❌ | Not tested on real cluster |
| ResumeMicrovm | ✅ | ✅ | ❌ | Not tested on real cluster |
| TerminateMicrovm | ✅ | ✅ finalizer | ✅ | |
| ListMicrovms | ✅ | — | — | CLI lists CRs only |
| CreateMicrovmAuthToken | ✅ | — | ✅ | via kubectl plugin `--direct` |
| CreateMicrovmShellAuthToken | ✅ | — | ❌ | `kubectl microvm exec` not tested |
| TagResource | ✅ | ❌ disabled | — | API doesn't support `microvm:` resource type |
| UntagResource | ✅ | ❌ | — | Same as above |
| ListTags | ✅ | ❌ | — | Same as above |
| CreateMicrovmImage | ✅ | ✅ | ✅ | |
| GetMicrovmImage | ✅ | ✅ poll | ✅ | |
| UpdateMicrovmImage | ✅ | ✅ generation change | ❌ | Not tested on real cluster |
| DeleteMicrovmImage | ✅ | ✅ finalizer | ✅ | |
| GetMicrovmImageVersion | ✅ | ✅ | ✅ | |
| ListMicrovmImageVersions | ✅ | ✅ status.versions[] | ✅ | |
| UpdateMicrovmImageVersion | ✅ | ✅ auto-activate | ✅ | |
| DeleteMicrovmImageVersion | ❌ | ❌ | — | Version pruning not implemented |
| ListMicrovmImages | ❌ | — | — | Not implemented |
| GetMicrovmImageBuild | ✅ | ❌ | — | Client exists, not surfaced in status |
| ListMicrovmImageBuilds | ✅ | ❌ | — | Same |
| ListManagedMicrovmImages | ✅ | ❌ | — | Client exists, not wired to CLI |
| ListManagedMicrovmImageVersions | ✅ | ❌ | — | Same |

## Lambda Core API (Network Connectors)

| Operation | Client | Reconciler | E2E on EKS |
|-----------|--------|------------|------------|
| CreateNetworkConnector | ✅ | ✅ | ✅ |
| GetNetworkConnector | ✅ | ✅ poll | ✅ |
| UpdateNetworkConnector | ✅ | ✅ | ❌ (not tested) |
| DeleteNetworkConnector | ✅ | ✅ finalizer + protection | ✅ |
| ListNetworkConnectors | ✅ | — | — |

## Networking Modes (E2E verified)

| Mode | Tested | Result |
|------|--------|--------|
| No egress (default) | ✅ | Outbound blocked (503) |
| Internet egress (AWS-managed) | ✅ | checkip.amazonaws.com reachable |
| VPC egress (customer-managed) | ✅ | Connector ACTIVE, VM starts |

## Operator Extensions (beyond AWS API)

| Feature | Code | Integration Tests | E2E on EKS | Notes |
|---------|------|-------------------|------------|-------|
| imageRef resolution by CR name | ✅ | ✅ | ✅ | RBAC-enforced, validates state |
| networkRef resolution by CR name | ✅ | ✅ | ✅ | Validates connector ACTIVE |
| MicroVMReplicaSet reconciler | ✅ | ✅ (5 tests) | ❌ | Scale up/down works in mocks; QuotaGuard not wired yet (see quota-guardrails-replicaset) |
| Token REST endpoint (operator) | ✅ | ✅ (7 tests) | ❌ | TokenReview + SubjectAccessReview |
| Pod mutating webhook (sidecar) | ✅ | ✅ (5 tests) | ❌ | Injects auth-agent container |
| Validating webhook | ✅ (code) | ❌ | ❌ | Endpoints not working on cluster |
| Mutating webhook (spec defaulting) | ✅ (code) | ❌ | ❌ | Not tested |
| Drift detection | ✅ | ✅ (mocked) | ❌ | Detects AWS ≠ desired state |
| kubectl microvm exec | ✅ (code) | ❌ | ❌ | Uses ShellAuthToken |
| QuotaGuard (rate limiting + backpressure) | ✅ | ✅ (wired in all 4 reconcilers + TokenResource) | ✅ 2026-07-07 | burst test: 50/50 tokens (was 0/256); cascade pacing verified |
| QuotaPolicy SPI | ✅ | ✅ (SpiDefaultsIT) | ✅ 2026-07-07 | DefaultQuotaPolicy confirmed in startup log |
| Quota discovery (install-time) | ✅ | — | ✅ 2026-07-07 | install_kube_microvm.sh queries service-quotas; fallback to AWS defaults |
| Quota discovery (runtime) | ✅ | — | ❌ | --quota-discovery=runtime; requires service-quotas:GetServiceQuota IAM |

## Not Implemented

| Feature | Priority | Notes |
|---------|----------|-------|
| DeleteMicrovmImageVersion | P2 | Version pruning |
| ListMicrovmImages (AWS state) | P3 | CLI shows CRs only |
| ListManagedMicrovmImages in CLI | P2 | `kubectl microvm image list-base` |
| Build logs in CR status | P3 | GetMicrovmImageBuild not surfaced |
| Tag sync | Blocked | API doesn't support microvm resource type |
| Rolling update (ReplicaSet) | P2 | Design exists, not coded |
| Cross-namespace image ref | P3 | MVP = same namespace only |
| Krew manifest | P3 | Distribution |
| macOS native CLI | P3 | Linux only for now |

## E2E Test Coverage Summary

| Area | Tested | Not Tested |
|------|--------|------------|
| MicroVMImage lifecycle | create, build, activate, delete | update (new version) |
| MicroVM lifecycle | run, terminate | suspend, resume |
| Networking | all 3 egress modes | network update, VPC→private target |
| Auth | token --direct + curl | token via operator, sidecar, exec |
| Webhooks | — | validating, mutating |
| ReplicaSet | — | scale up/down on real cluster |
