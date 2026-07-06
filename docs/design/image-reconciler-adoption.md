# Design: MicroVMImage Reconciler — Adopt-If-Exists & Active Version Sync

**Status**: Implementation ready  
**Branch**: `feature/image-reconciler-adoption`  
**Affects**: `MicroVMImageReconciler`, `AwsConnectivityStartup`, new `AwsIdentity` bean

---

## Problem

### Bug 1: No adopt-if-exists path

When a `MicroVMImage` CR is created with `status.imageArn == null`, the reconciler unconditionally calls `CreateMicrovmImage`. If an image with the same name already exists in AWS (created via CLI, Console, or a previous operator install), the API returns:

```
ValidationException: A MicroVM image with the name 'qs-test-app' already exists in this account
```

The reconciler treats this as a retryable error and loops indefinitely. The image is never adopted — the CR is permanently stuck.

**Affected scenarios:**
- Re-installing the operator after a cluster wipe (CRs deleted, AWS images remain)
- Importing an image created outside Kubernetes
- Disaster recovery (restore CRs from backup, AWS state intact)

### Bug 2: `activeVersion` never populated after adoption or settled resync

`GetMicrovmImageResponse` from AWS includes `latestActiveImageVersion`. The reconciler never reads this field. After adopting an existing image (or on periodic resync of a settled image), `status.activeVersion` stays null even when the image has an active version.

---

## Fix

### New bean: `AwsIdentity`

Store account ID at startup so reconcilers can construct image ARNs by name:

```java
@ApplicationScoped
public class AwsIdentity {
    private volatile String accountId;
    private volatile String region;

    public void set(String accountId, String region) {
        this.accountId = accountId;
        this.region = region;
    }

    public String constructImageArn(String imageName) {
        return String.format("arn:aws:lambda:%s:%s:microvm-image:%s",
                region, accountId, imageName);
    }
}
```

`AwsConnectivityStartup` populates it from the STS `GetCallerIdentity` response it already makes.

### Reconciler CREATE path — try getImage first

```
Before:
  imageArn == null → CreateImage → (explodes if already exists)

After:
  imageArn == null
    → construct expectedArn from AwsIdentity
    → try GetImage(expectedArn)
      → found: adopt (set status.imageArn, imageState, activeVersion) → reschedule
      → NotFound: proceed with CreateImage as before
      → other error: propagate
```

### Active version sync — on every settled poll

When `GetMicrovmImageResponse.latestActiveImageVersion()` is non-null, always write it to `status.activeVersion`. This applies in both the adopt path and the periodic settled resync.

---

## Changes

| File | Change |
|------|--------|
| `AwsConnectivityStartup.java` | Inject `AwsIdentity`, call `awsIdentity.set(account, region)` after STS call |
| `AwsIdentity.java` (new) | CDI bean storing account ID + region, exposes `constructImageArn(name)` |
| `MicroVMImageReconciler.java` | Inject `AwsIdentity`; add adopt-if-exists in CREATE path; sync `activeVersion` from GetImage response |
| `MicroVMImageReconcilerIT.java` | Add `adopt_existingImageIsAdoptedNotCreated` test case |

---

## What is NOT changed

- `MicroVMImageSpec` — no new fields; source remains required for new builds, unused for adoption
- Webhook validation — no changes; source fields are already not validated for pre-existing images
- Delete behaviour — unchanged; cleanup still calls `DeleteImage`

---

## User-visible behaviour after fix

```bash
# Create CR for an existing image — just works, no placeholder needed
kubectl apply -f - <<EOF
apiVersion: lambda.aws.amazon.com/v1alpha1
kind: MicroVMImage
metadata:
  name: qs-test-app
  namespace: default
spec:
  source:
    s3Bucket: any-value   # ignored for adoption; required by schema
    s3Key: any-value
  baseImageArn: "arn:aws:lambda:us-east-1:aws:microvm-image:al2023-1"
  buildRoleArn: "arn:aws:iam::123456789012:role/KubeMicroVMBuildRole"
EOF

# Within one reconcile cycle (~15s):
microvm image describe qs-test-app
# State:          CREATED
# Image ARN:      arn:aws:lambda:us-east-1:...:microvm-image:qs-test-app
# Active Version: 1.0        ← populated from GetImage response
```
