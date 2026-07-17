# UAT Gap Analysis

> Reviewed: 2026-07-17 | Baseline: 10 suites, 62 tests | Last run: v1.0.5-rc4

---

## 1. Missing Suite: Quota Guardrails

The `docs/user-guides/quota-guardrails.md` guide has **no corresponding UAT suite**.
This is the only user guide without E2E coverage.

**What should be tested:**

| Test | Description |
|------|-------------|
| Operator logs effective quota limits at startup | Grep logs for `QuotaGuard initialised` |
| RunMicrovm rate limit is enforced | Create > 5 VMs simultaneously, verify no 429 from AWS |
| Token endpoint backpressure (HTTP 429 on queue full) | Fire > `tokenQueueSize` concurrent requests, verify 429 response |
| ReplicaSet cascade is paced | Suspend a large RS, verify VMs suspend over time (not all at once) |
| Quota override via Helm values takes effect | Install with `--set quotas.runMicrovmRate=3`, verify in logs |
| Install-time quota discovery populates values | Check Helm release values contain discovered quotas |

**Priority: High** — This is the most impactful missing coverage. Quota issues
caused the documented "50 concurrent tokens → 0% success" incident.

---

## 2. Missing Suite: CLI Reference

`docs/user-guides/cli-reference.md` documents 20+ CLI commands. Only a handful are
exercised in passing by other suites. Missing explicit CLI tests:

| Command | Currently tested? | Gap |
|---------|------------------|-----|
| `microvm list` | ✅ (QS-05, RS-02) | Tested |
| `microvm describe` | ❌ | Not tested — `-o endpoint`, `-o json`, basic output |
| `microvm create` | ❌ | Not tested via CLI (only via kubectl apply) |
| `microvm delete` | ❌ | Not tested — `--wait`, `--timeout` flags |
| `microvm pause` | ❌ | Not tested |
| `microvm resume` | ❌ | Not tested |
| `microvm token --direct` | ✅ (QS-06) | Tested |
| `microvm token` (via operator) | ❌ | Not tested — non-`--direct` path |
| `microvm exec` | ❌ | Not tested |
| `microvm image list` | ❌ | Not tested |
| `microvm image describe` | ✅ (MEM-05) | Partial — only Memory field |
| `microvm image create` | ❌ | Not tested via CLI |
| `microvm image update` | ❌ | Not tested |
| `microvm image delete` | ❌ | Not tested |
| `microvm image base-images` | ❌ | Not tested |
| `microvm image version-delete` | ❌ | Not tested |
| `microvm rs list` | ✅ (RS-02) | Tested |
| `microvm rs describe` | ❌ | Not tested |
| `microvm rs scale` | ❌ | Not tested (uses kubectl patch instead) |
| `microvm network list` | ✅ (NET-05) | Tested |
| `microvm network describe` | ❌ | Not tested |
| `microvm completion` | ❌ | Not tested |
| `microvm --version` | ❌ | Not tested |

**Priority: Medium** — CLI is a first-class interface. Users following the CLI
reference guide won't have these commands validated by UAT.

---

## 3. Missing Error-Path / Negative Tests

### 3.1 Networking (03_networking.robot)

| Missing test | Description |
|--------------|-------------|
| Invalid subnet ID rejected | Apply MicroVMNetwork with `subnet-invalid` — webhook should reject |
| Invalid security group rejected | Apply with `sg-invalid` |
| Duplicate network name rejected | Create same MicroVMNetwork twice |
| VM with non-existent networkRef rejected | Reference a network that doesn't exist |

### 3.2 ReplicaSet (05_replicaset.robot)

| Missing test | Description |
|--------------|-------------|
| Zero replicas accepted | Scale to 0 — all VMs terminate, RS stays |
| Negative replicas rejected | Webhook should reject `replicas: -1` |
| Non-existent imageRef rejected | RS template references missing image |
| Concurrent scale operations | Scale up then immediately scale down — verify final state |

### 3.3 Pod Injection (04_pod_token_injection.robot)

| Missing test | Description |
|--------------|-------------|
| Missing annotation — no sidecar injected | Pod without `lambda.microvm.auth` annotation gets no sidecar |
| Namespace without injection label — no sidecar | Pod in unlabelled namespace gets no sidecar |
| Invalid VM name in annotation | Sidecar injected but token fetch fails gracefully |
| Pod restart preserves sidecar | Delete pod, verify re-created pod still has sidecar |

### 3.4 Quick Start (01_quick_start.robot)

| Missing test | Description |
|--------------|-------------|
| Duplicate MicroVM name rejected | Create same MicroVM twice — webhook rejects second |
| Invalid imageRef rejected | Create VM referencing non-existent image |
| Token for non-existent VM fails gracefully | `microvm token --name missing-vm` returns clear error |

### 3.5 Memory Sizing (08_memory_sizing.robot)

| Missing test | Description |
|--------------|-------------|
| Boundary values accepted | Test `memorySizeMiB: 128` (minimum) and `memorySizeMiB: 10240` (maximum) |
| Zero memorySizeMiB rejected | `memorySizeMiB: 0` should fail validation |

---

## 4. Flakiness Risks (Timing-Dependent Tests)

These tests use fixed `Sleep` delays instead of polling, making them fragile:

| Test | Current approach | Recommended fix |
|------|-----------------|-----------------|
| RS-01 (RS creates 3 VMs) | `Sleep 15s` then count | Poll until count >= 3 (max 60s) |
| RS-03 (Scale up to 5) | `Sleep 20s` then check CLI | Poll `rs list` until shows 5 |
| RS-04 (Scale down to 2) | `Sleep 20s` then check CLI | Poll until shows 2 |
| RS-06 (Delete terminates all) | `Sleep 10s` then assert empty | Poll until empty (max 60s) |
| INJ-06 (Token files written) | `Sleep 45s` then ls | Poll for file existence |
| INJ-09 (No RBAC pod empty dir) | `Sleep 20s` then ls | Sleep is appropriate here (proving absence), but could be reduced |
| AUTO-01 (VM suspends after idle) | `Sleep 90s` + conditional `Sleep 60s` | Use `Wait For VM State Suspended` with 180s timeout |
| AUTO-02 (Auto-resume updates status) | `Sleep 60s` then check state | Poll state == Running |
| DRIFT-01 (External termination) | Immediate after AWS call | Correct — uses `Wait For VM State` |

**Priority: High** — Fixed sleeps are the #1 cause of intermittent failures in CI.
Every `Sleep` followed by an assertion should be replaced with a retry loop.

---

## 5. Hardcoded / Environment-Specific Values

### 5.1 Networking subnet/SG IDs in test file

```robot
# 03_networking.robot — hardcoded to specific VPC
${SUBNET_1}     subnet-0fdc8b729163e12a7
${SUBNET_2}     subnet-0bde13101743f4751
${SG_ID}        sg-01032cc226cb1615d
```

**Fix:** Move to `variables.robot` so all environment-specific values are in one
place and overridable via `--variable` at runtime.

### 5.2 CODEBASE_PATH is wrong

```robot
# variables.robot
${CODEBASE_PATH}    /home/ubuntu/projects/pl-cloud/KubeMicroVM
```

Actual path is `/home/ubuntu/projects/pl-cloud/microvm/KubeMicroVM`. The `Upload
Test Fixtures` keyword uses this path to zip fixtures. If fixtures aren't already
in S3, this will silently produce empty zips.

### 5.3 Cluster name hardcoded in test

```robot
# 00_cluster_setup.robot
...    --cluster-name    ecp-us1
```

Should be `${CLUSTER_NAME}` from variables.robot (currently missing from variables).

---

## 6. Structural Issues

### 6.1 Test numbering gap

Tests go MEM-01 through MEM-05, then jump to MEM-07. Either:
- MEM-06 was removed but numbering wasn't adjusted
- MEM-06 was planned but not implemented

### 6.2 `99_final_cleanup.robot` fragility

If run standalone (`robot tests/99_final_cleanup.robot`), `Kubectl Delete Force`
on `${SHARED_IMAGE}` will error if the image doesn't exist. Should guard with
`Run Keyword And Ignore Error` or check existence first.

### 6.3 No smoke-only run path documented

Tags exist (`smoke`) but the README doesn't show how to run just smoke tests
quickly — useful for CI pre-merge gates:

```bash
robot --outputdir results -i smoke tests/
```

This runs only: QS-00, QS-07, RBAC-05, NET-01, INJ-04, INJ-08, DRIFT-01,
AUTO-01, MEM-01, MEM-07 = 10 tests covering critical paths.

---

## 7. Missing Lifecycle Tests

### 7.1 MicroVM lifecycle transitions not fully tested

| Transition | Tested? |
|-----------|---------|
| Pending → Running | ✅ (many suites) |
| Running → Suspended (idle timeout) | ✅ (AUTO-01) |
| Suspended → Running (auto-resume) | ✅ (AUTO-02) |
| Running → Suspended (explicit `pause`) | ❌ |
| Suspended → Running (explicit `resume`) | ❌ |
| Running → Terminated (graceful) | ✅ (QS-08) |
| Any → Terminated (forced delete) | ✅ (cleanup keywords) |
| Terminated → re-create (same name) | ❌ |
| Running → Pending (drift detection) | ✅ (DRIFT-01) |
| Pending → Running (drift re-create) | ✅ (DRIFT-02) |

### 7.2 MicroVMImage lifecycle gaps

| Transition | Tested? |
|-----------|---------|
| Create → BUILDING → CREATED/SUCCESSFUL | ✅ (many suites) |
| Build failure (bad S3 key) | ❌ |
| Image update (new S3 key triggers rebuild) | ❌ |
| Image version-delete | ❌ |
| Delete image while VM references it | ❌ |

---

## 8. Operator Resilience / Edge Cases

| Scenario | Tested? |
|----------|---------|
| Operator restart mid-reconcile | ❌ |
| AWS API timeout during VM creation | ❌ (would need fault injection) |
| Webhook rejects while operator is restarting | ❌ |
| Multiple VMs created simultaneously (burst) | ❌ (quota suite would cover) |
| Finalizer stuck after AWS resource deleted externally | ❌ |
| CR edit while VM is in transitional state (Pending) | ❌ |

---

## 9. Security Tests Not Covered

| Scenario | Tested? |
|----------|---------|
| Token expires after TTL | ❌ |
| Expired token rejected by MicroVM endpoint | ❌ |
| Token scoped to specific VM only | ✅ (RBAC-06) |
| Cross-namespace token access denied | ❌ |
| Operator webhook TLS cert validation | ❌ |
| Pod without SA token cannot call token endpoint | ❌ |

---

## 10. Summary: Coverage Heatmap

| Area | Happy path | Error path | Edge cases | Score |
|------|-----------|------------|------------|-------|
| Quick Start | ✅ | ⚠️ partial | ❌ | 7/10 |
| RBAC | ✅ | ✅ | ⚠️ | 8/10 |
| Networking | ✅ | ❌ | ❌ | 5/10 |
| Pod Injection | ✅ | ⚠️ partial | ❌ | 6/10 |
| ReplicaSet | ✅ | ❌ | ⚠️ | 6/10 |
| MicroVMClass | ✅ | ✅ | ❌ | 7/10 |
| Drift & Auto-Suspend | ✅ | ❌ | ⚠️ | 7/10 |
| Memory Sizing | ✅ | ✅ | ❌ | 7/10 |
| **Quota Guardrails** | ❌ | ❌ | ❌ | **0/10** |
| **CLI Reference** | ⚠️ | ❌ | ❌ | **2/10** |

---

## Recommended Priority Order

1. **Fix CODEBASE_PATH** — one-line fix, prevents silent fixture upload failures
2. **Replace fixed Sleeps with polling** — eliminates flakiness
3. **Move hardcoded networking values to variables.robot** — portability
4. **Add Quota Guardrails suite** — highest-impact missing coverage
5. **Add CLI Reference suite** — validates documented commands
6. **Add networking negative tests** — webhook rejection tests are cheap to write
7. **Add lifecycle transition tests** — pause/resume via CLI
8. **Add security/token expiry tests** — validates documented security properties
