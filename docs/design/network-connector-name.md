# Design: MicroVMNetwork Connector Name Override (`spec.connectorName`)

**Status**: Implementation ready  
**Branch**: `feature/network-connector-name`  
**Affects**: `MicroVMNetworkSpec`, `MicroVMNetworkReconciler`, `AwsIdentity`

---

## Problem

The `MicroVMNetworkReconciler` adoption path (introduced in `feature/import-existing-resources`)
has a naming mismatch that makes it unusable for importing CLI-created connectors.

### Root cause

The reconciler constructs the AWS connector name as `<namespace>-<CR-name>`:

```java
String name = resource.getMetadata().getNamespace() + "-" + resource.getMetadata().getName();
```

So a CR named `my-vpc-connector` in namespace `default` maps to AWS connector name
`default-my-vpc-connector`.

A user creating a connector via AWS CLI would naturally use:

```bash
aws lambda-core create-network-connector --name my-vpc-connector ...
```

When they then create the CR to import it, the adoption lookup constructs ARN
`arn:aws:lambda:...:network-connector:default-my-vpc-connector` — which doesn't
match the connector named `my-vpc-connector`. The adoption silently falls through
to `CreateNetworkConnector`, which fails because a connector named
`my-vpc-connector` already exists (but the operator used a different name).

### Additional finding

`GetNetworkConnector` accepts `--identifier` which takes a name, ID, or ARN directly —
ARN construction is not required. The current `constructNetworkConnectorArn` approach
works but is unnecessarily brittle.

---

## Fix: `spec.connectorName`

Add an optional `spec.connectorName` field to `MicroVMNetworkSpec`. When set, this
is used as the AWS-side connector name for both creation and lookup. When not set,
the existing `<namespace>-<CR-name>` convention is preserved for backward compatibility.

```yaml
apiVersion: lambda.aws.amazon.com/v1alpha1
kind: MicroVMNetwork
metadata:
  name: my-vpc-connector    # Kubernetes name
  namespace: default
spec:
  connectorName: my-vpc-connector    # AWS connector name (optional)
  subnetIds:
    - subnet-abc123
  securityGroupIds:
    - sg-xyz789
  operatorRoleArn: "arn:aws:iam::123456789012:role/MicroVMNetworkConnectorRole"
```

If `spec.connectorName` is not set, the reconciler uses `<namespace>-<CR-name>` as
before. Setting `spec.connectorName` is required when importing a connector that was
created with a different name.

### Adoption flow with `spec.connectorName`

```
User creates connector via CLI:
  aws lambda-core create-network-connector --name my-vpc-connector ...

User creates CR to import it:
  spec.connectorName: my-vpc-connector

Reconciler:
  effectiveName = spec.connectorName ?? (namespace + "-" + CR-name)
  GetNetworkConnector(effectiveName)  ← uses name directly, not constructed ARN
  → Found: adopt
  → Not found: create with name=effectiveName
```

### Simplification: use name directly instead of ARN

`GetNetworkConnector` and `CreateNetworkConnector` both accept the connector name
directly. The ARN construction in `constructNetworkConnectorArn` can be replaced
with a direct name lookup — simpler and more reliable:

```java
// Before (brittle ARN construction):
String expectedArn = awsIdentity.constructNetworkConnectorArn(name);
var existing = networkClient.getConnector(expectedArn).get(...);

// After (direct name lookup):
var existing = networkClient.getConnector(effectiveName).get(...);
```

This removes the dependency on `AwsIdentity` for the network reconciler entirely.

---

## Implementation Checklist

### `operator-core`
- [ ] Add `connectorName` field to `MicroVMNetworkSpec` with getter/setter
  - Optional field; when null, reconciler falls back to `<namespace>-<CR-name>`

### `operator-controller`
- [ ] `MicroVMNetworkReconciler`: compute `effectiveName` from `spec.connectorName`
  or namespace+CR-name fallback
- [ ] `MicroVMNetworkReconciler`: use `effectiveName` directly for `getConnector`
  lookup instead of constructed ARN — removes `AwsIdentity` dependency
- [ ] `MicroVMNetworkReconciler`: pass `effectiveName` to `createConnector`

### `operator-tests`
- [ ] `MicroVMNetworkReconcilerIT`: test with `spec.connectorName` set — lookup
  and create use the override name
- [ ] `MicroVMNetworkReconcilerIT`: test without `spec.connectorName` — fallback
  to `<namespace>-<CR-name>` unchanged

### `docs/user-guides` (networking.md or import guide)
- [ ] Document `spec.connectorName` in the networking guide
- [ ] Add import example showing how to match a CLI-created connector

---

## Backward Compatibility

- CRs without `spec.connectorName` continue to work as before — the
  `<namespace>-<CR-name>` convention is preserved.
- Existing connectors created by the operator (using `<namespace>-<CR-name>`)
  are unaffected — their ARNs are stored in `status.connectorArn` and the
  reconciler uses that directly after adoption/creation.
- `spec.connectorName` is immutable after creation (changing it after the connector
  is created would create a naming mismatch between spec and the actual AWS resource).
