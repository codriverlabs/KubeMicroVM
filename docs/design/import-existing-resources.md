# Design: Import Existing AWS Resources into Kubernetes Management

**Status**: Implementation ready  
**Branch**: `feature/import-existing-resources`  
**Affects**: `MicroVMReconciler`, `MicroVMNetworkReconciler`, `AwsIdentity`, `MicroVMSpec`

---

## Problem

All three resource types can be created outside Kubernetes (via AWS CLI, Console, or
SDK). When a corresponding CR is then created, the operator should adopt the existing
AWS resource rather than creating a duplicate or failing.

### Current behaviour by resource type

| Resource | Adopt path | Behaviour today |
|----------|-----------|-----------------|
| `MicroVMImage` | ✅ Implemented | Tries `GetMicrovmImage` by ARN on CREATE; adopts if found |
| `MicroVMNetwork` | ❌ Missing | Calls `CreateNetworkConnector` unconditionally; fails if connector exists |
| `MicroVM` | ❌ Missing | Calls `RunMicrovm` unconditionally; creates a second VM |

### Concrete scenarios requiring import

- **Operator re-install**: cluster wiped, CRs deleted, AWS resources remain running
- **Import from CLI**: team created VMs/networks via `aws lambda-microvms` before
  adopting the operator
- **Disaster recovery**: restore CRs from backup, AWS state intact
- **Migration**: move from direct AWS SDK usage to Kubernetes-managed lifecycle

---

## Solution

### MicroVMNetwork — name-based lookup on CREATE

`CreateNetworkConnector` fails if a connector with the same name already exists.
The fix mirrors `MicroVMImageReconciler`: before calling `CreateNetworkConnector`,
check whether a connector with the expected ARN already exists via `GetNetworkConnector`.

The connector ARN can be constructed from account ID, region, and name — same pattern
as image ARNs. Add `constructNetworkConnectorArn(String name)` to `AwsIdentity`:

```java
public String constructNetworkConnectorArn(String connectorName) {
    if (accountId == null || region == null) return null;
    return String.format(
        "arn:aws:lambda:%s:%s:network-connector:%s",
        region, accountId, connectorName);
}
```

**Reconciler CREATE path** (in `MicroVMNetworkReconciler`):

```
status.connectorArn == null:
  1. Construct expected ARN from name
  2. Call GetNetworkConnector(expectedArn)
     → Found: adopt — set status.connectorArn, status.connectorState, status.connectorId
     → Not found (404): fall through to CreateNetworkConnector
```

### MicroVM — explicit import via `spec.importMicroVmId`

A VM's `microVmId` is an opaque UUID (`microvm-xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx`)
assigned by AWS at `RunMicrovm` time. Unlike images and networks, it cannot be derived
from the CR name.

Two options considered:

| Option | Pros | Cons |
|--------|------|------|
| `spec.importMicroVmId` — user supplies ID explicitly | Simple, no ListMicrovms needed, clear intent | User must look up the ID manually |
| Auto-discovery via `ListMicrovms` — search by imageRef | No extra field needed | Ambiguous if multiple VMs use same image; expensive scan |

**Decision: `spec.importMicroVmId`** — explicit import is unambiguous and matches
Kubernetes conventions (similar to `spec.volumeName` for PersistentVolumes).

#### New field: `spec.importMicroVmId`

```yaml
apiVersion: lambda.aws.amazon.com/v1alpha1
kind: MicroVM
metadata:
  name: my-agent
spec:
  imageRef: my-image
  desiredState: Running
  importMicroVmId: "microvm-12345678-abcd-efgh-ijkl-123456789012"
  maxIdleDurationSeconds: 900
  suspendedDurationSeconds: 1800
```

When `spec.importMicroVmId` is set and `status.microVmId` is null, the reconciler
skips `RunMicrovm` and instead calls `GetMicrovm(spec.importMicroVmId)` to verify the
VM exists and populate status.

After successful import, `spec.importMicroVmId` is effectively consumed — the reconciler
does not need to read it again once `status.microVmId` is set. It remains in the spec
for auditability.

**Reconciler PENDING path** (in `MicroVMReconciler`):

```
spec.importMicroVmId is set AND status.microVmId == null:
  1. Call GetMicrovm(spec.importMicroVmId)
     → Found: adopt — set status.microVmId, status.endpointUrl, status.state from AWS
              log "Importing MicroVM <name> microVmId=<id> state=<state>"
              transition to appropriate state (RUNNING, SUSPENDED, etc.)
     → Not found (404): fail with clear message
              "importMicroVmId '<id>' not found in AWS — check the ID or remove the field"

spec.importMicroVmId not set:
  → existing RunMicrovm path (unchanged)
```

#### Validation (webhook)

Add webhook validation:
- `spec.importMicroVmId` must match pattern `^microvm-[a-f0-9-]{36}$` if set
- `spec.importMicroVmId` is immutable after creation (cannot be changed once set)
- `spec.importMicroVmId` and `spec.desiredState: Terminated` cannot be set together
  on a new CR (no point importing a VM you're immediately terminating)

---

## Implementation Checklist

### `operator-core`
- [ ] Add `importMicroVmId` field to `MicroVMSpec` with `@JsonProperty`

### `operator-controller`
- [ ] Add `constructNetworkConnectorArn(String name)` to `AwsIdentity`
- [ ] `MicroVMNetworkReconciler`: adopt-if-exists path on CREATE (before `CreateNetworkConnector`)
- [ ] `MicroVMReconciler`: import path in `handlePendingState` when `spec.importMicroVmId` is set

### `operator-webhook`
- [ ] `MicroVMValidatingWebhook`: validate `importMicroVmId` pattern
- [ ] `MicroVMValidatingWebhook`: immutability check on `importMicroVmId` (UPDATE)

### `operator-tests`
- [ ] `MicroVMNetworkReconcilerIT`: test adopt path — `GetNetworkConnector` returns existing connector, `CreateNetworkConnector` not called
- [ ] `MicroVMReconcilerIT`: test import path — `importMicroVmId` set, `GetMicrovm` called, `RunMicrovm` not called, status populated from AWS
- [ ] `MicroVMReconcilerIT`: test import-not-found — `GetMicrovm` returns 404, CR transitions to FAILED with clear message
- [ ] Webhook test: invalid `importMicroVmId` pattern rejected
- [ ] Webhook test: `importMicroVmId` immutable on UPDATE

### `docs/user-guides`
- [ ] New section in user guide (or new guide): "Importing Existing Resources"

---

## User Guide: Importing Existing Resources

### MicroVMImage (already supported)

Create a CR with the same name as an existing image. The operator adopts it automatically:

```yaml
apiVersion: lambda.aws.amazon.com/v1alpha1
kind: MicroVMImage
metadata:
  name: my-agent      # must match the AWS image name exactly
  namespace: default
spec:
  source:
    s3Bucket: my-bucket
    s3Key: path/to/app.zip
  baseImageArn: "arn:aws:lambda:us-east-1:aws:microvm-image:al2023-1"
  buildRoleArn: "arn:aws:iam::123456789012:role/KubeMicroVMBuildRole"
```

No special field needed — the operator checks for an existing image by name before
attempting to create one.

### MicroVMNetwork (new)

Same as MicroVMImage — create a CR with the same name as an existing network connector:

```yaml
apiVersion: lambda.aws.amazon.com/v1alpha1
kind: MicroVMNetwork
metadata:
  name: my-vpc-connector   # must match the AWS connector name exactly
  namespace: default
spec:
  subnetIds:
    - subnet-abc123
  securityGroupIds:
    - sg-xyz789
  operatorRoleArn: "arn:aws:iam::123456789012:role/MicroVMNetworkConnectorRole"
```

The operator attempts to find an existing connector with the same name. If found, it
is adopted into the CR's status. If not found, a new connector is created.

### MicroVM (new)

Use `spec.importMicroVmId` to import a specific running VM:

```bash
# 1. Find the microVmId of the running VM
aws lambda-microvms list-microvms \
  --image-identifier arn:aws:lambda:us-east-1:123456789012:microvm-image:my-agent \
  --query 'microvms[?name==`my-running-vm`].microvmId' --output text
# → microvm-12345678-abcd-efgh-ijkl-123456789012
```

```yaml
apiVersion: lambda.aws.amazon.com/v1alpha1
kind: MicroVM
metadata:
  name: my-running-vm
  namespace: default
spec:
  imageRef: my-agent
  desiredState: Running
  importMicroVmId: "microvm-12345678-abcd-efgh-ijkl-123456789012"
  maxIdleDurationSeconds: 900
  suspendedDurationSeconds: 1800
```

The operator calls `GetMicrovm` to verify the ID exists, then populates the CR status
from the current AWS state. No new VM is created. After import, the VM is fully managed
by the operator — the `importMicroVmId` field remains in spec for audit trail but is
not used again after `status.microVmId` is set.

**Error handling**: if the `importMicroVmId` is not found in AWS, the CR transitions
to `Failed` with the message:
```
importMicroVmId 'microvm-...' not found in AWS — check the ID or remove the field to create a new VM
```

---

## What Doesn't Change

- **Normal create flow**: unaffected. If `spec.importMicroVmId` is not set, `MicroVM`
  reconciliation works exactly as before.
- **MicroVMImage**: already implemented. No changes.
- **Drift detection**: works the same after import — once status is populated, the
  standard reconcile loop handles drift detection for all three resource types.
- **Finalizers and deletion**: unchanged. Imported resources are cleaned up the same
  as operator-created ones.

---

## ARN Construction Reference

| Resource | ARN pattern |
|----------|-------------|
| MicroVMImage | `arn:aws:lambda:<region>:<account>:microvm-image:<name>` |
| MicroVMNetwork | `arn:aws:lambda:<region>:<account>:network-connector:<name>` |
| MicroVM | No ARN-from-name possible — ID is opaque (`microvm-<uuid>`) |
