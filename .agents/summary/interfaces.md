# Interfaces & APIs

## Kubernetes APIs (CRDs)

### MicroVM (`lambda.aws.amazon.com/v1alpha1`)
- **spec**: imageRef, imageVersion, className, desiredState, maxIdleDurationSeconds, suspendedDurationSeconds, autoResumeEnabled, maximumDurationSeconds, networkRef, ingressNetworkConnectors, egressNetworkConnectors, executionRoleArn, runHookPayload, importMicroVmId, region, tags, `additionalProperties` (forward-compat, `@JsonAnySetter`)
- **status**: state, microVmId, endpointUrl, resolvedImageArn, resolvedImageVersion, imageVersion, conditions, observedGeneration, lastTransitionTime

### MicroVMImage (`lambda.aws.amazon.com/v1alpha1`)
- **spec**: source (s3Bucket, s3Key), baseImageArn, buildRoleArn, buildTimeoutSeconds, autoActivate, memorySizeMiB, region, maxVersionsToKeep
- **status**: imageState, imageArn, latestVersion, activeVersion, latestVersionState, latestVersionStateReason, memorySizeMiB, computeProfile, versions[], currentBuildId, buildMessage, buildStartedAt, observedGeneration

### MicroVMReplicaSet (`lambda.aws.amazon.com/v1alpha1`)
- **spec**: replicas, template (imageRef, maxIdleDurationSeconds, ...), maxSurge, minReady, scaleDown (policy, stabilizationWindowSeconds), updateStrategyType (RollingUpdate | Recreate), maxUnavailable, desiredReplicaSetState
- **status**: readyReplicas, currentReplicas, desiredReplicas, suspendedReplicas, updatedReplicas, currentTemplateHash, conditions, observedGeneration

### MicroVMNetwork (`lambda.aws.amazon.com/v1alpha1`)
- **spec**: subnetIds[], securityGroupIds[], operatorRoleArn, networkProtocol, connectorName (optional override), region, tags
- **status**: connectorArn, connectorId, connectorState, stateReason, stateReasonCode, conditions, observedGeneration

### MicroVMClass (`lambda.aws.amazon.com/v1alpha1`)
- **spec**: maxIdleDurationSeconds, suspendedDurationSeconds, autoResumeEnabled, maximumDurationSeconds, ingressNetworkConnectors, egressNetworkConnectors, description

## Pod Annotations (Sidecar Injection)

| Annotation | Required | Description |
|-----------|----------|-------------|
| `lambda.microvm.auth: <vm-name>` | Yes | VM name to get tokens for; triggers sidecar injection |
| `lambda.microvm.auth/expires: "60"` | No | Token expiry in minutes |
| `lambda.microvm.auth/mount-path: /custom` | No | Override default `/var/run/microvm` mount path |

Namespace must be labelled `lambda.microvm.auth/inject=enabled` for sidecar injection to activate.

## Operator REST API

| Endpoint | Method | Auth | Description |
|----------|--------|------|-------------|
| `/apis/.../namespaces/{ns}/microvms/{name}/token` | POST | Bearer (SA token) | Get MicroVM auth token via operator |
| `/validate-microvm` | POST | Webhook cert | Validating admission webhook |
| `/mutate-microvm` | POST | Webhook cert | Mutating admission webhook (MicroVM) |
| `/mutate-pod` | POST | Webhook cert | Mutating admission webhook (Pod sidecar injection) |
| `/q/health/live` | GET | None | Liveness probe |
| `/q/health/ready` | GET | None | Readiness probe |
| `/q/metrics` | GET | None | Prometheus metrics |

## AWS APIs Used

| Service | Operations |
|---------|-----------|
| `lambda-microvms` | RunMicrovm, TerminateMicrovm, SuspendMicrovm, ResumeMicrovm, GetMicrovm, ListMicrovms, CreateMicrovmAuthToken, CreateMicrovmShellAuthToken, CreateMicrovmImage, UpdateMicrovmImage, DeleteMicrovmImage, GetMicrovmImage, ListMicrovmImageVersions, UpdateMicrovmImageVersion, DeleteMicrovmImageVersion, ListManagedBaseImageVersions, TagResource, UntagResource |
| `lambda-core` | CreateNetworkConnector, GetNetworkConnector, UpdateNetworkConnector, DeleteNetworkConnector, ListNetworkConnectors |
| `sts` | GetCallerIdentity |

## Kubernetes API (used by operator)

| API | Resource | Verbs | Purpose |
|-----|----------|-------|---------|
| `authentication.k8s.io/v1` | tokenreviews | create | Validate pod SA tokens |
| `authorization.k8s.io/v1` | subjectaccessreviews | create | Check RBAC for token requests |

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
├── exec <name> [--direct]
├── image
│   ├── list
│   ├── create --name <n> --s3-bucket <b> --s3-key <k> [--memory <MiB>]
│   ├── describe <name>
│   ├── update <name> --s3-key <k>
│   ├── delete <name>
│   ├── version delete <image> <version>
│   └── base-images
├── rs
│   ├── list
│   ├── describe <name>
│   └── scale <name> --replicas <N>
└── network
    ├── list
    └── describe <name>
```
