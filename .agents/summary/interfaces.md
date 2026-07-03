# Interfaces & APIs

## Kubernetes APIs (CRDs)

### MicroVM (`lambda.aws.amazon.com/v1alpha1`)
- **spec**: imageRef, imageVersion, className, desiredState, maxIdleDurationSeconds, suspendedDurationSeconds, autoResumeEnabled, maximumDurationSeconds, networkRef, ingressNetworkConnectors, egressNetworkConnectors, executionRoleArn, runHookPayload, tags
- **status**: state, microVmId, endpointUrl, resolvedImageArn, resolvedImageVersion, conditions, lastTransitionTime

### MicroVMImage (`lambda.aws.amazon.com/v1alpha1`)
- **spec**: source (s3Bucket, s3Key), baseImageArn, buildRoleArn, buildTimeoutSeconds, autoActivate, memorySizeMiB, region
- **status**: imageState, imageArn, latestVersion, activeVersion, latestVersionState, memorySizeMiB, computeProfile, versions[]

### MicroVMReplicaSet (`lambda.aws.amazon.com/v1alpha1`)
- **spec**: replicas, template (imageRef, maxIdleDurationSeconds, ...), maxSurge, minReady, scaleDown
- **status**: readyReplicas, currentReplicas, desiredReplicas, suspendedReplicas, conditions

### MicroVMNetwork (`lambda.aws.amazon.com/v1alpha1`)
- **spec**: subnetIds[], securityGroupIds[], operatorRoleArn, networkProtocol, region, tags
- **status**: connectorArn, connectorId, connectorState, stateReason, conditions

### MicroVMClass (`lambda.aws.amazon.com/v1alpha1`)
- **spec**: maxIdleDurationSeconds, suspendedDurationSeconds, autoResumeEnabled, maximumDurationSeconds, ingressNetworkConnectors, egressNetworkConnectors, description

## Operator REST API

| Endpoint | Method | Auth | Description |
|----------|--------|------|-------------|
| `/apis/.../namespaces/{ns}/microvms/{name}/token` | POST | Bearer (SA token) | Get MicroVM auth token via operator |
| `/validate-microvm` | POST | Webhook cert | Validating admission webhook |
| `/mutate-microvm` | POST | Webhook cert | Mutating admission webhook (MicroVM) |
| `/mutate-pod` | POST | Webhook cert | Mutating admission webhook (Pod sidecar injection) |

## AWS APIs Used

| Service | Operations |
|---------|-----------|
| `lambda-microvms` | RunMicrovm, TerminateMicrovm, SuspendMicrovm, ResumeMicrovm, GetMicrovm, ListMicrovms, CreateMicrovmAuthToken, CreateMicrovmShellAuthToken, CreateMicrovmImage, UpdateMicrovmImage, DeleteMicrovmImage, GetMicrovmImage, ListMicrovmImageVersions, UpdateMicrovmImageVersion |
| `lambda-core` | CreateNetworkConnector, GetNetworkConnector, UpdateNetworkConnector, DeleteNetworkConnector |
| `sts` | GetCallerIdentity |

## CLI Interface

```
microvm [command] [flags]
├── list [-n namespace] [-w watch]
├── describe <name> [-o endpoint|json]
├── create --name <n> --image <img> [--class <cls>]
├── delete <name>
├── pause <name>
├── resume <name>
├── token --name <n> [--direct] [--expiry-minutes N]
├── exec <name>
├── image
│   ├── list
│   ├── create --name <n> --s3-bucket <b> --s3-key <k> [--memory <MiB>]
│   ├── describe <name>
│   ├── update <name> --s3-key <k>
│   ├── delete <name>
│   └── base-images
├── rs
│   ├── list
│   ├── describe <name>
│   └── scale <name> --replicas <N>
└── network
    ├── list
    └── describe <name>
```
