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

### Checklist

| # | Step | Expected | Result |
|---|------|----------|--------|
| RBAC-01 | Create SA `my-app-sa` in `default` | SA exists | ⬜ |
| RBAC-02 | Create `Role` with `resourceNames: ["my-vm"]` | Role exists | ⬜ |
| RBAC-03 | Create `RoleBinding` binding SA to Role | Binding exists | ⬜ |
| RBAC-04 | `kubectl auth can-i create microvms/token --as=system:serviceaccount:default:my-app-sa -n default` | `yes` | ⬜ |
| RBAC-05 | Pod using `my-app-sa` calls operator token endpoint for `my-vm` | Returns token | ⬜ |
| RBAC-06 | Pod using `my-app-sa` calls operator endpoint for a **different** VM | `403 Forbidden` | ⬜ |
| RBAC-07 | Pod using SA with **no** Role calls operator token endpoint | `403 Forbidden` | ⬜ |
| RBAC-08 | Namespace without `manage-microvms=true` label → `kubectl apply` MicroVM | Webhook rejects with clear message | ⬜ |

### Notes

---

## UG-NET: Networking Guide

**Source**: `docs/user-guides/networking.md`
**Goal**: All three networking modes work as documented.

### Checklist

| # | Step | Expected | Result |
|---|------|----------|--------|
| NET-01 | MicroVM with `INTERNET_EGRESS` — call `https://checkip.amazonaws.com/` from inside | Returns public IP | ⬜ |
| NET-02 | MicroVM with no egress connectors — call external URL | Connection refused/timeout | ⬜ |
| NET-03 | Create `MicroVMNetwork` with VPC config | CR created, state → `ACTIVE` | ⬜ |
| NET-04 | MicroVM with `networkRef: my-vpc-egress` — call internal VPC endpoint | Connection succeeds | ⬜ |
| NET-05 | `microvm network list` shows the network | NAME, STATE, CONNECTOR-ARN visible | ⬜ |
| NET-06 | MicroVMClass with connectors set — MicroVM references class — connectors inherited | VM uses class connectors | ⬜ |

### Notes

---

## UG-INJECT: Pod Token Injection Guide

**Source**: `docs/user-guides/pod-token-injection.md`
**Goal**: Sidecar injection and token flow work exactly as documented.

### Checklist

| # | Step | Expected | Result |
|---|------|----------|--------|
| INJ-01 | `kubectl label namespace default lambda.microvm.auth/inject=enabled` | Namespace labelled | ⬜ |
| INJ-02 | Create SA + Role + RoleBinding as shown in guide | All resources exist | ⬜ |
| INJ-03 | Apply annotated pod (`lambda.microvm.auth: my-vm`) | Pod created | ⬜ |
| INJ-04 | `kubectl get pod my-pod -o jsonpath='{.spec.containers[*].name}'` | `app microvm-auth-agent` both present | ⬜ |
| INJ-05 | `kubectl get pod my-pod -o jsonpath='{.spec.volumes[*].name}'` | `microvm-token` volume present | ⬜ |
| INJ-06 | `kubectl exec my-pod -c app -- ls /var/run/microvm/` | `auth-token`, `endpoint`, `expires-at`, `.ready` | ⬜ |
| INJ-07 | `kubectl exec my-pod -c app -- cat /var/run/microvm/auth-token` | Non-empty JWT token | ⬜ |
| INJ-08 | `curl` from inside app container using token from file | `{"status":"ok"}` | ⬜ |
| INJ-09 | Pod with annotation but **no** SA Role — sidecar logs | `403 Forbidden` in agent logs | ⬜ |

### Notes

---

## UG-RS: ReplicaSet Guide

**Source**: `docs/user-guides/replicaset.md`
**Goal**: ReplicaSet create/scale/drift work as documented.

### Checklist

| # | Step | Expected | Result |
|---|------|----------|--------|
| RS-01 | Apply `MicroVMReplicaSet` with `replicas: 3` | 3 MicroVM CRs created | ⬜ |
| RS-02 | `microvm rs list` shows the ReplicaSet | NAME, REPLICAS visible | ⬜ |
| RS-03 | `microvm rs scale agent-pool --replicas 5` | 2 new MicroVMs created | ⬜ |
| RS-04 | Scale down to 2 | 3 VMs terminated | ⬜ |
| RS-05 | Terminate one VM externally via AWS CLI | Operator re-creates it within 60s | ⬜ |
| RS-06 | `kubectl delete microvmreplicaset agent-pool` | All member VMs terminated | ⬜ |

### Notes

---

## UG-CLASS: MicroVMClass Guide

**Source**: `docs/user-guides/microvm-class.md`
**Goal**: Class creation, inheritance, and field override work as documented.

### Checklist

| # | Step | Expected | Result |
|---|------|----------|--------|
| CLASS-01 | Create `MicroVMClass` with `maxIdleDurationSeconds: 60` and `autoResumeEnabled: true` | Class CR exists | ⬜ |
| CLASS-02 | Create MicroVM with `className: my-class` | VM inherits idle policy from class | ⬜ |
| CLASS-03 | `microvm describe my-vm` shows values from class | Idle policy visible in spec | ⬜ |
| CLASS-04 | Create MicroVM with `className: my-class` + `maxIdleDurationSeconds: 300` (override) | VM uses 300s, not class value | ⬜ |
| CLASS-05 | `kubectl get microvmclasses -n default` | Class listed | ⬜ |
| CLASS-06 | Create MicroVM referencing non-existent class | Webhook rejects: `spec.className 'x' not found` | ⬜ |

### Notes

---

## UG-DRIFT: Drift & Auto-Suspend Guide

**Source**: `docs/user-guides/drift-and-autosuspend.md`
**Goal**: Drift detection and idle policy work as documented.

### Checklist

| # | Step | Expected | Result |
|---|------|----------|--------|
| DRIFT-01 | Get VM ID, terminate via `aws lambda-microvms terminate-microvm` | VM transitions to `Pending` | ⬜ |
| DRIFT-02 | Wait 60s — operator re-creates VM | New VM-ID, state → `Running` | ⬜ |
| AUTO-01 | Create VM with `maxIdleDurationSeconds: 60`, wait 90s idle | `status.state` → `Suspended` | ⬜ |
| AUTO-02 | Send request with `autoResumeEnabled: true` | Response received, state → `Running` | ⬜ |
| AUTO-03 | Operator does NOT fight idle policy | No spurious `RESUME` calls in operator logs | ⬜ |

### Notes

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
