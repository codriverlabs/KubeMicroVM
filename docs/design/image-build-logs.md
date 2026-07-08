# Design: Image Build Logs in CR Status

**Status**: Clients exist, not surfaced  
**Branch**: `feature/image-build-logs`  
**Priority**: P3

---

## What Exists

- `MicroVMImageClient.getBuild(imageArn, buildId)` — calls `GetMicrovmImageBuild`
- `MicroVMImageClient.listBuilds(imageArn)` — calls `ListMicrovmImageBuilds`
- `MicroVMImageStatus` — has `imageState`, `versionState`, `versions[]`, but no build info

## What Is Missing

During image build (`imageState=CREATING`, `versionState=IN_PROGRESS`), users have no visibility into build progress. They must poll externally or wait for the state to settle. Build logs and build ID are not surfaced in the CR status.

## Solution

### `MicroVMImageStatus` additions

```java
/** Build ID of the currently in-progress build (if any). */
private String currentBuildId;
/** Short status message from the current build (tail of build log). */
private String buildMessage;
/** Timestamp when the current build started. */
private String buildStartedAt;
```

### Reconciler — populate build info while CREATING

In `MicroVMImageReconciler`, during the CREATING poll loop:
```java
if ("CREATING".equals(status.getImageState())) {
    // Get latest build
    imageClient.listBuilds(status.getImageArn()).thenAccept(builds -> {
        if (!builds.isEmpty()) {
            var latestBuild = builds.get(0); // most recent
            status.setCurrentBuildId(latestBuild.buildId());
            status.setBuildMessage(latestBuild.statusMessage());
            status.setBuildStartedAt(latestBuild.startedAt().toString());
        }
    }).get(10, SECONDS);
}
```

### CLI — show build info in `microvm image describe`

```
$ microvm image describe my-image
Name:         my-image
State:        CREATING
Build:        build-abc123 (started 2m ago)
Build status: Compiling dependencies...
```

### `microvm image build-logs <name>` (new command, optional stretch goal)

Stream or tail the build log for a currently-building image:
```bash
microvm image build-logs my-image
# Streams GetMicrovmImageBuild.logOutput as it appears
```

## Implementation Checklist

- [ ] Add `currentBuildId`, `buildMessage`, `buildStartedAt` to `MicroVMImageStatus`
- [ ] `MicroVMImageReconciler`: populate build fields while `imageState=CREATING`
- [ ] `ImageDescribeCommand`: show build info when present
- [ ] Integration test: build fields populated during CREATING state
- [ ] E2E: `microvm image describe` shows build ID and message during build
- [ ] Optional: `microvm image build-logs` streaming command
- [ ] Update `docs/user-guides/cli-reference.md`
