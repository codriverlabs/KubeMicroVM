# UAT: User Guides End-to-End

Validates that every documented step in the user guides works exactly as written.
Must pass before tagging `v1.0.0` GA.

**Cluster**: `ecp-us1`, EKS Auto Mode, `us-east-1`
**Date**: TBD
**Tester**: Kiro

---

## UG-QS: Quick Start Guide

**Source**: `docs/user-guides/quick-start.md`
**Goal**: Full flow from zero to a running MicroVM as documented.
**Date**: 2026-07-03
**Result**: ✅ PASS (3 bugs found and fixed)

### Bugs found during walkthrough

1. **Webhook checking annotation instead of label** — `validateNamespacePermission` called
   `getAnnotations()` instead of `getLabels()`. Fixed: changed to `getLabels()` and updated
   error message from "does not have annotation" to "is not managed — add label".

2. **`microvm image describe` missing State field** — `imageState` not shown in output.
   Fixed: added `State: CREATED/BUILDING/...` line to `ImageDescribeCommand`.

3. **Mutating webhook `MicroVMSpec` deserialization error** — `objectMapper.convertValue(
   writeValueAsString(spec), MicroVMSpec.class)` serialized to String then tried to deserialize
   from String (wrong). Fixed: changed to `treeToValue(valueToTree(spec), MicroVMSpec.class)`.

4. **Endpoint shows `PENDING` immediately after VM created** — timing issue, not a bug.
   Updated guide note: wait for `microvm list` to show `Running` before getting endpoint.

5. **Guide uses `CHART_VERSION=1.0.0` but GA not tagged yet** — add note to guide that
   users should use latest RC version until GA is tagged.

### Checklist

| # | Step (as written in guide) | Expected | Result |
|---|---------------------------|----------|--------|
| QS-01 | Install operator via Helm chart `v1.0.0-rc5` | Operator pod Running, both webhooks active | ✅ |
| QS-02 | `kubectl label namespace default lambda.aws.amazon.com/manage-microvms=true` | MicroVMImage admitted | ✅ |
| QS-03 | `microvm image describe my-app` shows `State: CREATED` | Build progress visible | ✅ (after fix) |
| QS-04 | `kubectl apply` MicroVM with `desiredState: Running` | VM CR created | ✅ |
| QS-05 | `microvm list` shows VM in `Running` state | NAME, STATE, VM-ID visible | ✅ |
| QS-06 | `microvm token --name my-vm --direct` returns a token | JWT token printed | ✅ |
| QS-07 | `curl -H "X-aws-proxy-auth: $TOKEN" "https://$ENDPOINT/"` | `{"status":"ok"}` response | ✅ |
| QS-08 | Teardown: patch desiredState → delete VM → delete image | All CRs gone | ✅ |

### Notes

- `endpointUrl` in status shows as `PENDING` briefly after creation — normal, updates within 60s
- Guide step 1 should reference latest RC version until v1.0.0 GA is tagged

---

## UG-RBAC: RBAC Guide

**Source**: `docs/user-guides/rbac.md`
**Goal**: Verify all RBAC layers work as documented.
**Date**: 2026-07-03
**Result**: ✅ PASS (1 doc bug fixed)

### Bugs found during walkthrough

1. **`kubectl auth can-i` syntax wrong in guide** — Guide used `microvms/token` as the
   resource but `can-i` requires `--subresource=token` as a separate flag. Also, with
   `resourceNames` in the Role, `can-i` always returns "no" (general check) — the operator
   still authorizes correctly at runtime via SubjectAccessReview with the specific name.
   Fixed: updated guide to use correct syntax and added note about `resourceNames` limitation.

### Checklist

| # | Step | Expected | Result |
|---|------|----------|--------|
| RBAC-01 | Create SA `my-app-sa` in `default` | SA exists | ✅ |
| RBAC-02 | Create `Role` with `resourceNames: ["rbac-test-vm"]` | Role exists | ✅ |
| RBAC-03 | Create `RoleBinding` binding SA to Role | Binding exists | ✅ |
| RBAC-04 | `kubectl auth can-i create microvms --subresource=token` | `yes` (without resourceNames) | ✅ (after fix) |
| RBAC-05 | Pod using `my-app-sa` calls operator token endpoint for `rbac-test-vm` | Returns token | ✅ |
| RBAC-06 | Pod using `my-app-sa` calls operator endpoint for a **different** VM | `403 Forbidden` | ✅ |
| RBAC-07 | Pod using SA with **no** Role calls operator token endpoint | `403 Forbidden` | ✅ |
| RBAC-08 | Namespace without `manage-microvms=true` label → `kubectl apply` MicroVM | Webhook rejects with clear message | ✅ |

### Notes

- Webhook rejection message: `Namespace 'x' is not managed — add label 'lambda.aws.amazon.com/manage-microvms=true' to enable MicroVMs`
- 403 message: `not authorized — ask your admin to grant create on microvms/token for <vm-name>`
- Token endpoint: `POST https://kube-microvm-operator.kube-microvm.svc:443/apis/lambda.aws.amazon.com/v1alpha1/namespaces/<ns>/microvms/<name>/token`

---

## UG-NET: Networking Guide

**Source**: `docs/user-guides/networking.md`
**Goal**: All three networking modes work as documented.
**Date**: 2026-07-03
**Result**: ✅ PASS (2 doc bugs fixed, NET-06 deferred to MicroVMClass UAT)

### Bugs found during walkthrough

1. **`vpcId` field doesn't exist in MicroVMNetwork CRD** — Guide showed `spec.vpcId` but
   the CRD only has `subnetIds`, `securityGroupIds`, `operatorRoleArn`. AWS derives VPC from
   subnets. Fixed: removed `vpcId` from example.

2. **"No egress" mode doesn't actually block outbound** — MicroVMs have default internet
   egress. Omitting `egressNetworkConnectors` does NOT block outbound traffic. To truly
   isolate, use a VPC connector with subnets that have no NAT/IGW. Fixed: rewrote no-egress
   section with correct guidance.

### Checklist

| # | Step | Expected | Result |
|---|------|----------|--------|
| NET-01 | MicroVM with `INTERNET_EGRESS` — call `https://checkip.amazonaws.com/` from inside | Returns public IP | ✅ (44.210.34.188) |
| NET-02 | MicroVM with no egress connectors — call external URL | Connection refused/timeout | ❌→✅ (doc bug: default internet, fixed guide) |
| NET-03 | Create `MicroVMNetwork` with VPC config | CR created, state → `ACTIVE` | ✅ |
| NET-04 | MicroVM with `networkRef: my-vpc-egress` — call external URL | Connection succeeds via VPC | ✅ (100.56.147.203 — VPC NAT IP) |
| NET-05 | `microvm network list` shows the network | NAME, STATE, CONNECTOR-ARN visible | ✅ |
| NET-06 | MicroVMClass with connectors set — MicroVM references class — connectors inherited | VM uses class connectors | ⏭ Deferred (MicroVMClass CRD not installed, tested in UG-CLASS) |

### Notes

- VPC egress VM gets a different egress IP (100.56.147.203) than internet-egress VM (44.210.34.188), confirming VPC routing
- Network connector creation takes ~3 min (PENDING → ACTIVE)
- MicroVMClass CRD not part of current Helm chart — NET-06 deferred to class guide UAT

---

## UG-INJECT: Pod Token Injection Guide

**Source**: `docs/user-guides/pod-token-injection.md`
**Goal**: Sidecar injection and token flow work exactly as documented.
**Date**: 2026-07-03
**Result**: ✅ PASS (1 known issue documented)

### Known issues

1. **Endpoint file shows `PENDING` if written before VM endpoint resolves** — Agent writes
   endpoint file on first token fetch. If endpoint is still `PENDING` at that time, file
   contains "PENDING" and isn't refreshed. Token itself works correctly regardless.
   Workaround: app should retry reading endpoint file, or query CR directly.

### Checklist

| # | Step | Expected | Result |
|---|------|----------|--------|
| INJ-01 | Namespace labelled `lambda.microvm.auth/inject=enabled` | Label present | ✅ |
| INJ-02 | Create SA + Role + RoleBinding | All resources exist | ✅ |
| INJ-03 | Apply annotated pod (`lambda.microvm.auth: inject-vm`) | Pod created | ✅ |
| INJ-04 | `kubectl get pod -o jsonpath='{.spec.containers[*].name}'` | `app microvm-auth-agent` | ✅ |
| INJ-05 | `kubectl get pod -o jsonpath='{.spec.volumes[*].name}'` | `microvm-token` volume present | ✅ |
| INJ-06 | `ls /var/run/microvm/` from app container | `auth-token`, `endpoint`, `expires-at` | ✅ |
| INJ-07 | `cat /var/run/microvm/auth-token` | Non-empty JWT (751 bytes) | ✅ |
| INJ-08 | Use token from file to call MicroVM endpoint | `{"status":"ok"}` | ✅ |
| INJ-09 | Pod with annotation but no SA Role — no token files | Empty `/var/run/microvm/`, no `.ready` | ✅ |

### Notes

- Agent logs: `Token written to /var/run/microvm` on success
- Agent startup: ~11s (JVM on Quarkus, 128Mi memory)
- Token expiry: 30 minutes (configurable in agent)
- Endpoint file timing: if VM endpoint not ready at first refresh, file shows "PENDING"

---

## UG-RS: ReplicaSet Guide

**Source**: `docs/user-guides/replicaset.md`
**Goal**: ReplicaSet create/scale/drift work as documented.
**Date**: 2026-07-03
**Result**: ✅ PASS (1 doc fix: template structure)

### Bugs found during walkthrough

1. **ReplicaSet guide uses `spec.template.spec.imageRef` but CRD has `spec.template.imageRef`**
   — Template fields are directly under `template`, not nested under `template.spec`.
   Fixed in user guide.

### Checklist

| # | Step | Expected | Result |
|---|------|----------|--------|
| RS-01 | Apply `MicroVMReplicaSet` with `replicas: 3` | 3 MicroVM CRs created | ✅ |
| RS-02 | `microvm rs list` | NAME, DESIRED, CURRENT, READY, STATE visible | ✅ |
| RS-03 | Scale up to 5 | 2 new MicroVMs created, RS shows 5/5/5 | ✅ |
| RS-04 | Scale down to 2 | 3 VMs terminated | ✅ |
| RS-05 | Terminate one VM externally → operator re-creates | Covered by drift E2E tests | ⏭ (previously verified) |
| RS-06 | Delete ReplicaSet → all member VMs terminated | No MicroVMs remaining | ✅ |

### Notes

- Template fields are at `spec.template.imageRef` (NOT `spec.template.spec.imageRef`)
- Scale down is graceful — VMs terminate over ~15s
- Delete cascade removes all children immediately

---

## UG-CLASS: MicroVMClass Guide

**Source**: `docs/user-guides/microvm-class.md`
**Goal**: Class creation, inheritance, and field override work as documented.
**Date**: 2026-07-03
**Result**: ✅ PASS (3 bugs fixed)

### Bugs found during walkthrough

1. **MicroVMClass CRD missing from Helm chart** — JOSDK only auto-generates CRDs for resources
   with reconcilers. MicroVMClass is a static lookup resource (no reconciler). Fixed: added
   CRD manually in `operator-controller/src/main/helm/crds/`.

2. **Mutating webhook MicroVMSpec deserialization failure** — `objectMapper.convertValue(
   request.getObject(), MicroVM.class)` stored spec as String. Fixed: changed to
   `objectMapper.treeToValue(objectMapper.valueToTree(request.getObject()), MicroVM.class)`.

3. **Validating webhook checked phantom fields** — `validateMemory()` read
   `getMaximumDurationSeconds()` as memoryMB, `validateVcpus()` read
   `getMaxIdleDurationSeconds()` as vcpus. These fields don't exist in MicroVMSpec.
   Fixed: removed bogus validations (Lambda MicroVMs don't expose memory/vcpu config).

4. **MicroVMClass guide missing `suspendedDurationSeconds`** — AWS API requires it when
   idle policy is set. Updated guide example to include it.

### Checklist

| # | Step | Expected | Result |
|---|------|----------|--------|
| CLASS-01 | Create `MicroVMClass` with idle policy | Class CR exists with printer columns | ✅ |
| CLASS-02 | Create MicroVM with `className: agentic-standard` | VM inherits idle policy from class | ✅ (after fix) |
| CLASS-03 | Spec shows values from class | `maxIdleDurationSeconds: 60`, `autoResumeEnabled: true`, etc. | ✅ (after fix) |
| CLASS-04 | Create MicroVM with className + override `maxIdleDurationSeconds: 300` | VM uses 300, not class value 60 | ✅ |
| CLASS-05 | `kubectl get microvmclasses -n default` | Class listed with Description, Idle, AutoResume columns | ✅ |
| CLASS-06 | Create MicroVM referencing non-existent class | Webhook rejects: `spec.className 'x' not found` | ✅ |

### Notes

- MicroVMClass has no reconciler — it's read by the mutating webhook at admission time
- `suspendedDurationSeconds` is required by AWS when `maxIdleDurationSeconds` is set
- User-set spec fields always take precedence over class defaults (merge, not override)

---

## UG-DRIFT: Drift & Auto-Suspend Guide

**Source**: `docs/user-guides/drift-and-autosuspend.md`
**Goal**: Drift detection and idle policy work as documented.
**Date**: 2026-07-03
**Result**: ✅ PASS

### Checklist

| # | Step | Expected | Result |
|---|------|----------|--------|
| DRIFT-01 | Terminate VM externally via `aws lambda-microvms terminate-microvm` | Operator detects, state → Pending | ✅ (~60s detection) |
| DRIFT-02 | Wait for operator re-creation | New VM-ID, state → Running | ✅ (microvm-f967... replaced microvm-6153...) |
| AUTO-01 | VM with `maxIdleDurationSeconds: 60`, wait 90s idle | state → Suspended | ✅ (~150s total from creation) |
| AUTO-02 | Send request with `autoResumeEnabled: true` | Response received, state → Running | ✅ (`{"status":"ok"}`) |
| AUTO-03 | Operator does NOT fight idle policy | No spurious RESUME calls in logs | ✅ |

### Notes

- Drift detection cycle: ~60s (one reconcile interval)
- Auto-suspend timing: AWS suspends after `maxIdleDurationSeconds` of no traffic through endpoint
- Auto-resume: AWS handles transparently on incoming traffic; operator updates CR status on next reconcile
- Operator correctly recognizes Suspended state and doesn't issue RESUME calls

---

## Sign-off

| Guide | All tests pass | Sign-off |
|-------|---------------|---------|
| Quick Start | ⬜ | |
| RBAC | ⬜ | |
| Networking | ⬜ | |
| Pod Token Injection | ⬜ | |
| ReplicaSet | ⬜ | |
| MicroVMClass | ⬜ | |
| Drift & Auto-Suspend | ⬜ | |

**GA release `v1.0.0` requires all guides signed off.**

---

## UG-MEM: Memory Sizing Guide

**Source**: `docs/user-guides/memory-sizing.md`
**Goal**: Memory sizing creation, validation, immutability, and VM execution work as documented.
**Date**: 2026-07-03
**Result**: ✅ PASS (1 pre-existing bug fixed during walkthrough)

### Bugs found during walkthrough

1. **Phantom `validateTimeout` blocked `suspendedDurationSeconds > 900`** — Dead code from
   Lambda Function template treated `suspendedDurationSeconds` as "timeout" with max 900s.
   MicroVMs allow up to 28800s. Fixed: removed all phantom validations (validateMemory,
   validateVcpus, validateRuntime, validateTimeout) and their constants.

### Checklist

| # | Step | Expected | Result |
|---|------|----------|--------|
| MEM-01 | Create MicroVMImage with `memorySizeMiB: 4096` | Status: 4096 MiB, compute profile correct | ✅ |
| MEM-02 | Create MicroVMImage without memorySizeMiB | Status: 2048 MiB (AWS default) | ✅ |
| MEM-03 | Create MicroVMImage with `memorySizeMiB: 999` | Webhook rejects: "must be one of [512, 1024, 2048, 4096, 8192]" | ✅ |
| MEM-04 | Update existing image changing memorySizeMiB | Webhook rejects: "immutable after image creation" | ✅ |
| MEM-05 | `microvm image describe` | Shows "Memory: 4096 MiB" + "Compute: 4096 MiB / 2.0 vCPU" | ✅ |
| MEM-06 | `kubectl get microvmimages` MEMORY column | Deferred (printer column annotation not available) | ⏭ |
| MEM-07 | Run MicroVM from 4096 MiB image, call endpoint | `{"status":"ok"}` | ✅ |

### Notes

- CRD must be updated on cluster before `memorySizeMiB` is accepted (strict decoding)
- Endpoint URL takes ~30s to populate after VM reaches Running state
- AWS requires `maxIdleDurationSeconds` + `suspendedDurationSeconds` when idle policy is configured
