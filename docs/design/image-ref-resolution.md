# Design: MicroVM Image Reference Resolution

## Summary

The `MicroVM.spec.imageRef` field references a `MicroVMImage` custom resource **by name**
(not by ARN). The operator resolves the CR name to the AWS image ARN at reconcile time.
This enforces Kubernetes RBAC as the authorization boundary.

## Motivation

1. **RBAC consistency** — The operator holds IAM credentials, not the user. If `imageRef`
   accepted a raw ARN, any user who can create a MicroVM CR could use any image in the account,
   bypassing namespace-scoped access control.

2. **Validation before launch** — By resolving via the CR, the operator can verify the image
   is in `CREATED` state with an `ACTIVE` version before calling `RunMicrovm`, avoiding
   wasted API calls and confusing error messages.

3. **Kubernetes-native UX** — Same pattern as PVC→StorageClass, Pod→Secret, Pod→ConfigMap.
   Users reference resources by name; the system resolves them.

## Specification

### MicroVM CR

```yaml
apiVersion: lambda.aws.amazon.com/v1alpha1
kind: MicroVM
metadata:
  name: my-app
  namespace: team-a
spec:
  imageRef: my-app-image          # MicroVMImage CR name (same namespace)
  imageVersion: "1.0"             # optional, defaults to activeVersion
  className: micro
  desiredState: Running
```

### Resolution Rules

| `imageRef` value | Behavior |
|------------------|----------|
| Simple name (`my-app-image`) | Look up MicroVMImage CR in **same namespace** |
| Not found | Fail with condition: `ImageNotFound` |
| Found but `status.imageState != CREATED` | Fail with condition: `ImageNotReady` |
| Found but no active version | Fail with condition: `NoActiveVersion` |
| Found and ready | Use `status.imageArn` + resolve version |

### Version Resolution

| `spec.imageVersion` | Behavior |
|---------------------|----------|
| Set (e.g. `"1.0"`) | Use exactly that version |
| Not set / null | Use `MicroVMImage.status.activeVersion` |

### Status Fields (MicroVM)

```yaml
status:
  resolvedImageArn: arn:aws:lambda:us-east-1:<ACCOUNT_ID>:microvm-image:my-app-image
  resolvedImageVersion: "1.0"
  state: Running
  microVmId: microvm-abc123
  endpointUrl: abc123.lambda-microvm.us-east-1.on.aws
```

### No ARN Bypass

Direct ARNs are **not accepted** in `imageRef`. This is intentional:
- Prevents RBAC bypass (namespace isolation)
- Ensures the referenced image is tracked as a CR (lifecycle, garbage collection)
- Forces explicit import of shared/external images

### Shared/Cross-Namespace Images

For images that should be available across namespaces, the admin creates
a MicroVMImage CR in each namespace (or a future `ClusterMicroVMImage` resource).
For MVP, same-namespace only.

## Base Image Handling

The `MicroVMImage.spec.baseImageArn` field accepts the AWS-managed base image ARN.
Currently only one exists: `arn:aws:lambda:<region>:aws:microvm-image:al2023-1`.

- This is NOT a user image and does NOT need a CRD
- It's a build-time input, not a runtime reference
- The operator can default it if not specified
- `kubectl microvm image list-base` exposes available managed base images via CLI

## RBAC Model

```
User creates MicroVM in namespace "team-a"
  → K8s RBAC check: can user CREATE microvms in team-a?        ✓
  → Operator resolves imageRef "my-app-image" in namespace "team-a"
  → K8s RBAC implicit: MicroVMImage must EXIST in team-a       ✓
    (only users with CREATE microvmimages in team-a can create them)
  → Operator has IAM role → calls RunMicrovm with resolved ARN
```

No user ever sees or needs AWS credentials. The namespace boundary controls access.

## Implementation Plan

1. Add `resolvedImageArn` and `resolvedImageVersion` to `MicroVMStatus`
2. Add resolution logic in `MicroVMReconciler.handlePendingState()`:
   - Look up MicroVMImage CR by name in same namespace
   - Validate state and version
   - Set resolved fields in status
3. Pass resolved ARN (not `spec.imageRef`) to `RunMicroVMRequest`
4. Add conditions: `ImageNotFound`, `ImageNotReady`, `NoActiveVersion`
5. Remove any code path that passes `imageRef` directly as an ARN
6. Update CRD validation: `imageRef` must NOT match `^arn:`

## Testing

- Unit: mock MicroVMImage CR lookup, test all resolution branches
- Integration: create MicroVMImage + MicroVM, verify resolution in logs
- E2E on EKS: full flow — image build → VM launch via CR name reference
- Negative: reference non-existent image, reference image still building
