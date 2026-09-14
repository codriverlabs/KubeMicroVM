# Image Management

## Overview

`MicroVMImage` manages the build lifecycle of Firecracker snapshots. Each image is built from a Dockerfile + application code packaged as a zip archive in S3. The operator creates and tracks image versions via the AWS Lambda MicroVMs API.

## Build Pipeline

```
┌─────────────────────┐
│  User uploads zip   │  (Dockerfile + app code)
│  to S3 bucket       │
└──────────┬──────────┘
           │
           ↓
┌─────────────────────┐
│ User creates/updates│
│ MicroVMImage CR     │
│ (spec.source.s3Key) │
└──────────┬──────────┘
           │
           ↓  Operator reconciles
┌─────────────────────┐
│ create-microvm-image│  → AWS API
│ or                  │
│ update-microvm-image│  (new version from new s3Key)
└──────────┬──────────┘
           │
           ↓  AWS builds (Dockerfile → snapshot)
┌─────────────────────┐
│ Version transitions:│
│ PENDING → IN_PROGRESS → SUCCESSFUL
└──────────┬──────────┘
           │
           ↓  Operator activates (if autoActivate=true)
┌─────────────────────┐
│ Version → ACTIVE    │
│ Previous → INACTIVE │
└─────────────────────┘
```

## Reconciliation Logic

### Create Flow (new image)

1. User creates `MicroVMImage` CR
2. Operator calls `create-microvm-image` with:
   - S3 bucket/key for source artifact
   - Base image ARN
   - Build timeout
   - Ready hook configuration
3. Operator stores `status.imageArn` from response
4. Operator polls version state until SUCCESSFUL or FAILED
5. If `spec.autoActivate: true`, operator calls `activate-microvm-image-version`

### Update Flow (new version)

1. User updates `spec.source.s3Key` (new zip)
2. Operator detects `observedGeneration != metadata.generation`
3. Operator calls `create-microvm-image-version` (creates version N+1)
4. Polls until SUCCESSFUL
5. Activates new version, deactivates previous

### Delete Flow

1. User deletes `MicroVMImage` CR
2. Finalizer ensures:
   - No `MicroVM` CRs reference this image (reject deletion if in use)
   - Call `delete-microvm-image` to clean up AWS resource
3. Remove finalizer

## Version Management

Each `MicroVMImage` tracks multiple versions:

```yaml
status:
  latestVersion: 5
  activeVersion: 4          # Currently serving (might lag if build in progress)
  versions:
    - version: 5
      state: InProgress     # Building
      startedAt: "2026-06-25T10:00:00Z"
    - version: 4
      state: Active         # Serving
      builtAt: "2026-06-20T09:00:00Z"
    - version: 3
      state: Inactive       # Previous
      builtAt: "2026-06-15T09:00:00Z"
```

Only the last 5 versions are tracked in status (older ones pruned).

## Image Reference Resolution

When a `MicroVM` references an image:

```yaml
spec:
  imageRef:
    name: python-sandbox    # MicroVMImage CR name
    version: 4              # Optional — specific version
```

Resolution:
1. Look up `MicroVMImage` named `python-sandbox` in same namespace
2. If `version` specified: use that version's image ARN (must be ACTIVE or SUCCESSFUL)
3. If `version` omitted: use `status.activeVersion`
4. Pass resolved image ARN to `run-microvm --image-identifier`

## Build Failure Handling

If a build fails:
- `status.versions[N].state = Failed`
- `status.versions[N].failureReason = "..."` (from AWS API response)
- Condition `ImageReady` remains True (previous active version still valid)
- Event emitted: `Warning BuildFailed "Version 5 build failed: <reason>"`
- `status.activeVersion` unchanged (still on last good version)

## Quotas and Limits

| Limit | Value |
|-------|-------|
| Max image versions retained (status) | 5 |
| Build timeout range | 60–3600 seconds |
| Max concurrent builds per account | AWS service limit (typically 5) |
| Source artifact max size | AWS service limit |

## Namespace Identity vs. AWS Resource Identity

**`MicroVMImage` names are not namespace-isolated identifiers.** The underlying AWS
Lambda MicroVM image is identified by name within your AWS account + region, which has
no concept of Kubernetes namespaces:

```
arn:aws:lambda:<region>:<account-id>:microvm-image:<name>
```

Creating two `MicroVMImage` CRs with the same `metadata.name` in different namespaces
resolves to the exact same AWS ARN. This is rejected at admission time by the
validating webhook (see [webhooks.md](webhooks.md)) — you cannot create a
`MicroVMImage` whose name already resolves to an existing image owned by another
namespace.

To share one image across namespaces or tenants (PRO only), see
[cross-namespace image reference](../../../KubeMicroVM-PRO/docs/design/cross-namespace-imageref.md)
— never create a second same-named `MicroVMImage`. See
[image-arn-collision-prevention.md](image-arn-collision-prevention.md) for the full
design rationale and failure mode this prevents.
