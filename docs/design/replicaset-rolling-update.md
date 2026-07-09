# Design: ReplicaSet Rolling Update

**Status**: Implemented and E2E verified (2026-07-09)  
**Branch**: `feature/replicaset-rolling-update` → merged to main

---

## What Exists

`MicroVMReplicaSetReconciler` handles scale up/down and health eviction. It does not detect when `spec.template` changes and does not implement a rolling update strategy.

Currently: changing `spec.template.imageRef` on a running ReplicaSet has no effect on existing VMs — they continue running the old image until manually terminated.

## Desired Behaviour

When `spec.template` changes (detected via `observedGeneration` or a dedicated `templateGeneration` field), the reconciler gradually replaces existing VMs with new ones:

```
Before: [vm-1 (old image), vm-2 (old image), vm-3 (old image)]  replicas=3
After template change:
  Round 1: create vm-4 (new image) → wait for Running → terminate vm-1
  Round 2: create vm-5 (new image) → wait for Running → terminate vm-2
  Round 3: create vm-6 (new image) → wait for Running → terminate vm-3
```

Maintains `minReady` running VMs throughout. `maxSurge` controls how many new VMs can be created above `replicas` during rollout.

## Spec Changes

```yaml
spec:
  replicas: 3
  template: ...
  minReady: 1            # minimum Running VMs during rollout (existing)
  maxSurge: 1            # max new VMs above replicas during rollout (existing)
  updateStrategy:
    type: RollingUpdate  # NEW: RollingUpdate | Recreate (default: RollingUpdate)
    rollingUpdate:
      maxUnavailable: 1  # NEW: max VMs that can be terminating at once
```

## New Fields in `MicroVMReplicaSetSpec`

```java
/** Update strategy. Default: RollingUpdate. */
private String updateStrategyType = "RollingUpdate";
/** Max VMs that can be unavailable during rolling update. Default: 1. */
private Integer maxUnavailable = 1;
```

## Reconciler Logic

```
detectTemplateChange():
  hash current spec.template (exclude per-instance fields like runHookPayload)
  compare with status.currentTemplateHash
  if different → start rolling update

rollingUpdate():
  outdated = children where status.imageIdentifier != spec.template.imageRef ARN
  if outdated.isEmpty() → update status.currentTemplateHash, done
  if newCreatedCount < maxSurge:
    create 1 new child from current template
    return reschedule(3s)
  newRunning = [c for c in children if c is Running and c uses new template]
  if newRunning.size() > 0 and outdated.size() > 0:
    select 1 victim from outdated (oldest first)
    set victim.desiredState = Terminated
  return reschedule(10s)
```

## Status Changes

```java
/** Hash of the current spec.template — changes trigger rolling update. */
private String currentTemplateHash;
/** Number of VMs running the current template version. */
private Integer updatedReplicas;
```

## Implementation Checklist

- [x] Add `updateStrategyType`, `maxUnavailable` to `MicroVMReplicaSetSpec`
- [x] Add `currentTemplateHash`, `updatedReplicas` to `MicroVMReplicaSetStatus`
- [x] `MicroVMReplicaSetReconciler`: compute template hash, detect change
- [x] `MicroVMReplicaSetReconciler`: rolling update loop (create new → wait → terminate old)
- [x] `MicroVMReplicaSetReconciler`: `Recreate` strategy (terminate all, then create new)
- [x] Integration tests: rolling update replaces outdated VMs one-by-one
- [x] Integration tests: `Recreate` strategy terminates all before creating
- [x] E2E: change imageRef on running RS → all VMs updated with new image (RS-05 un-skipped 2026-07-09)
- [x] Update `docs/user-guides/replicaset.md`
