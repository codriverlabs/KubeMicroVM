# Custom Resource Definitions

## API Group

All resources use the API group `lambda.aws.amazon.com` with version `v1alpha1`, following the ACK convention for AWS service resources managed by third-party controllers.

## Resources

### MicroVM

The primary resource. Each MicroVM CR maps to a single AWS Lambda MicroVM instance.

```yaml
apiVersion: lambda.aws.amazon.com/v1alpha1
kind: MicroVM
metadata:
  name: dev-sandbox-01
  namespace: team-alpha
spec:
  # Image reference (required)
  imageRef:
    name: python-sandbox        # Reference to MicroVMImage CR in same namespace
    version: "3.0"              # Specific image version (optional, defaults to latest ACTIVE)

  # Networking
  networkRef:
    name: private-vpc           # Reference to MicroVMNetwork CR (egress to VPC)
  ingressConnector: ALL_INGRESS # ALL_INGRESS (default) | NO_INGRESS | custom ARN

  # Lifecycle
  desiredState: Running         # Running | Suspended | Terminated
  idlePolicy:
    maxIdleDurationSeconds: 900
    suspendedDurationSeconds: 3600
    autoResumeEnabled: true
  maximumDurationSeconds: 14400 # Max 28800 (8 hours)

  # Runtime configuration
  executionRoleArn: "arn:aws:iam::123456789012:role/my-microvm-runtime-role"
  runHookPayload: '{"tenantId": "tenant-abc", "env": "production"}'

  # Template reference (optional — overrides above fields)
  templateRef:
    name: standard-sandbox

  # Tags propagated to AWS resource
  tags:
    team: alpha
    environment: development

status:
  state: Running                # Pending | Running | Suspending | Suspended | Terminating | Terminated | Failed
  microVmId: "mvm-0abc123def456"
  endpointUrl: "https://mvm-0abc123def456.lambda-url.us-east-1.on.aws"
  imageVersion: 3
  lastTransitionTime: "2026-06-25T10:30:00Z"
  observedGeneration: 2
  conditions:
    - type: Ready
      status: "True"
      reason: Running
      message: "MicroVM is running and accepting traffic"
    - type: ImageReady
      status: "True"
      reason: ActiveVersion
      message: "Image version 3 is active"
    - type: NetworkReady
      status: "True"
      reason: ConnectorActive
      message: "Network connector is active"
```

### MicroVMReplicaSet

Manages a set of identical MicroVMs, similar to ReplicaSet/Deployment semantics.

```yaml
apiVersion: lambda.aws.amazon.com/v1alpha1
kind: MicroVMReplicaSet
metadata:
  name: ci-runners
  namespace: platform
spec:
  replicas: 5
  maxSurge: 2
  minReady: 3

  # Template for child MicroVMs
  template:
    imageRef:
      name: ci-runner-image
    memorySizeMB: 4096
    networkRef:
      name: ci-vpc
    idlePolicy:
      maxIdleDurationSeconds: 300
      autoResumeEnabled: false
    tags:
      pool: ci-runners

  # Scaling behavior
  scaleDown:
    stabilizationWindowSeconds: 300
    policy: MostRecentFirst      # MostRecentFirst | OldestFirst | Random

status:
  readyReplicas: 5
  currentReplicas: 5
  desiredReplicas: 5
  suspendedReplicas: 0
  observedGeneration: 1
  conditions:
    - type: Ready
      status: "True"
      reason: AllReplicasReady
      message: "5/5 replicas ready"
```

### MicroVMTemplate

Reusable spec template. Not reconciled — purely a Kubernetes-side reference.

```yaml
apiVersion: lambda.aws.amazon.com/v1alpha1
kind: MicroVMTemplate
metadata:
  name: standard-sandbox
  namespace: team-alpha
spec:
  memorySizeMB: 2048
  imageRef:
    name: python-sandbox
  networkRef:
    name: private-vpc
  idlePolicy:
    maxIdleDurationSeconds: 900
    suspendedDurationSeconds: 3600
    autoResumeEnabled: true
  maximumDurationSeconds: 28800
  tags:
    managed-by: kube-microvm-operator
```

### MicroVMNetwork

Declarative wrapper around an AWS Lambda Network Connector for egress. Reconciled — the operator creates/manages the underlying Network Connector resource.

```yaml
apiVersion: lambda.aws.amazon.com/v1alpha1
kind: MicroVMNetwork
metadata:
  name: private-vpc
  namespace: team-alpha
spec:
  # Egress configuration — maps to AWS Network Connector
  subnetIds:
    - subnet-0abc123
    - subnet-0def456
  securityGroupIds:
    - sg-0abc123
  networkProtocol: IPv4          # IPv4 | DualStack
  operatorRoleArn: "arn:aws:iam::123456789012:role/NetworkConnectorOperatorRole"

  # Ingress (informational — managed by AWS)
  # Each MicroVM gets its own HTTPS endpoint; no user config needed for inbound.

status:
  connectorArn: "arn:aws:lambda:us-east-1:123456789012:network-connector:my-connector"
  connectorState: Active         # Pending | Active | Inactive | Failed | Deleting
  lastSyncTime: "2026-06-25T10:00:00Z"
  conditions:
    - type: Ready
      status: "True"
      reason: ConnectorActive
      message: "Network connector is active"
```

### MicroVMImage

Manages the MicroVM image build lifecycle. Each image version represents a Firecracker snapshot built from a Dockerfile. Memory/vCPU sizing is configured here (applies to all MicroVMs running from this image).

```yaml
apiVersion: lambda.aws.amazon.com/v1alpha1
kind: MicroVMImage
metadata:
  name: python-sandbox
  namespace: team-alpha
spec:
  # Source artifact (S3 zip containing Dockerfile + application code)
  source:
    s3Bucket: my-artifacts-bucket
    s3Key: images/python-sandbox-v3.zip

  # Base image (Lambda-managed)
  baseImageArn: "arn:aws:lambda:us-east-1::microvm-base-image:al2023/x86_64/standard:latest"

  # CPU architecture. Omit for AWS default (ARM_64).
  # The base image version and source artifact must support this architecture.
  architecture: X86_64          # ARM_64 or X86_64

  # Compute sizing (baseline — peak is 4x automatically)
  memorySizeMB: 2048            # 512, 1024, 2048 (default), 4096, 8192

  # Build configuration
  buildRoleArn: "arn:aws:iam::123456789012:role/MicrovmBuildRole"
  buildTimeout: 600             # seconds (readyTimeoutInSeconds)
  readyHookEnabled: true        # Wait for /ready signal during build
  validateHookEnabled: true     # Run /validate after build

  # Runtime environment (set at build time, shared across all MicroVMs)
  environmentVariables:
    APP_ENV: production
    LOG_LEVEL: info

  # OS capabilities
  additionalOsCapabilities: []  # ["ALL"] for elevated privileges

  # Hook configuration
  hookPort: 8080                # Port for lifecycle hook HTTP calls

  # Version management
  autoActivate: true            # Automatically activate successful builds
  description: "Python sandbox with Jupyter and common data science libs"

status:
  imageArn: "arn:aws:lambda:us-east-1:123456789012:microvm-image:python-sandbox"
  imageState: Created           # Creating | Created | CreationFailed | Updating | Updated | UpdateFailed
  latestVersion: "3.0"
  activeVersion: "3.0"
  versions:
    - version: "3.0"
      buildState: Successful    # Pending | InProgress | Successful | Failed
      activation: Active        # Active | Inactive (user-controlled)
      builtAt: "2026-06-25T09:00:00Z"
    - version: "2.0"
      buildState: Successful
      activation: Inactive
      builtAt: "2026-06-20T09:00:00Z"
  conditions:
    - type: Ready
      status: "True"
      reason: ActiveVersionAvailable
      message: "Version 3 is active and ready"
```

## Field Validation Rules

| Resource | Field | Constraint |
|----------|-------|-----------|
| MicroVM | `maximumDurationSeconds` | 1–28800 (1 sec to 8 hours) |
| MicroVM | `idlePolicy.maxIdleDurationSeconds` | 1–28800 |
| MicroVM | `idlePolicy.suspendedDurationSeconds` | 1–28800 |
| MicroVM | `desiredState` | Running, Suspended, Terminated |
| MicroVM | `runHookPayload` | Max 16 KB string |
| MicroVMReplicaSet | `replicas` | 0–100 |
| MicroVMReplicaSet | `maxSurge` | 0–10 |
| MicroVMNetwork | `networkProtocol` | IPv4, DualStack |
| MicroVMImage | `memorySizeMB` | One of: 512, 1024, 2048, 4096, 8192 |
| MicroVMImage | `buildTimeout` | 1–3600 |
| MicroVMImage | `environmentVariables` | Max 50 entries |

## Owner References

- `MicroVMReplicaSet` → owns child `MicroVM` resources (cascade delete)
- `MicroVM` → references `MicroVMImage`, `MicroVMNetwork`, `MicroVMTemplate` (non-owning)
