# Design: DeleteMicrovmImageVersion

**Status**: Implementation ready  
**Branch**: `feature/delete-image-version`  
**Priority**: P2

---

## Problem

`MicroVMImage` CRs accumulate versions over time. Each `UpdateMicrovmImage` call creates a new version. There is currently no way to prune old versions via the operator — the `DeleteMicrovmImageVersion` API is implemented in the SDK client (`MicroVMImageClient`) but not wired into any reconciler or CLI command.

Without version pruning:
- Old unused versions consume storage quota (account limit: 50 versions per image)
- Build history grows indefinitely with no cleanup path

## Solution

### Option A — Automatic pruning via `spec.maxVersionsToKeep`
Add `spec.maxVersionsToKeep` (integer, default: unlimited) to `MicroVMImageSpec`. After each successful version activation, the reconciler calls `ListMicrovmImageVersions`, sorts by creation time, and deletes any versions beyond the retention count.

### Option B — CLI command only
Add `microvm image version delete --image <name> --version <id>` CLI command. No automatic pruning — user-driven.

### Option C — Both (recommended)
Implement Option A for automatic pruning + Option B for manual control.

---

## Implementation Plan

### `MicroVMImageSpec` (operator-core)
```java
/**
 * Optional: maximum number of image versions to retain.
 * After each successful version activation, versions beyond this count
 * (oldest first) are automatically deleted.
 * Default: null (no automatic pruning).
 */
private Integer maxVersionsToKeep;
```

### `MicroVMImageReconciler` (operator-controller)
After `UpdateMicrovmImageVersion` activates a new version:
```java
if (spec.getMaxVersionsToKeep() != null) {
    pruneOldVersions(name, imageArn, spec.getMaxVersionsToKeep());
}
```

`pruneOldVersions`:
1. Call `listImageVersions(imageArn)`
2. Sort by `createdAt` ascending (oldest first)
3. While `versions.size() > maxVersionsToKeep`: call `deleteImageVersion(imageArn, version.id())`
4. Log each deletion

### `ImageVersionDeleteCommand` (operator-cli)
New subcommand: `microvm image version delete --image <name> --version <version-id>`
- Calls the operator's existing `MicroVMImageClient.deleteImageVersion()`
- Requires `AWS_REGION` and valid credentials (same as `--direct` token flow)

### Webhook validation
- `spec.maxVersionsToKeep` must be ≥ 1 if set
- Cannot be 0 (would delete all versions including the active one)

---

## Implementation Checklist

- [ ] Add `maxVersionsToKeep` to `MicroVMImageSpec` + getter/setter
- [ ] `MicroVMImageReconciler`: call `pruneOldVersions` after version activation
- [ ] `MicroVMImageClient`: verify `deleteImageVersion(arn, versionId)` exists (client has it)
- [ ] `ImageVersionDeleteCommand` CLI subcommand
- [ ] Webhook: validate `maxVersionsToKeep >= 1`
- [ ] Integration tests: pruning triggers after activation with `maxVersionsToKeep=2`
- [ ] Integration tests: CLI delete command
- [ ] E2E: create image with `maxVersionsToKeep=2`, trigger 3 versions, verify oldest deleted
- [ ] User guide: update `docs/user-guides/memory-sizing.md` or create `image-versioning.md`
