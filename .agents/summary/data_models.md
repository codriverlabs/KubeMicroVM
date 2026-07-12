# Data Models

## Core CRD Models (operator-core)

```mermaid
classDiagram
    class MicroVM {
        +MicroVMSpec spec
        +MicroVMStatus status
    }
    class MicroVMSpec {
        +String imageRef
        +String imageVersion
        +String className
        +DesiredState desiredState
        +Integer maxIdleDurationSeconds
        +Integer suspendedDurationSeconds
        +Boolean autoResumeEnabled
        +Integer maximumDurationSeconds
        +String networkRef
        +List~String~ ingressNetworkConnectors
        +List~String~ egressNetworkConnectors
        +String executionRoleArn
        +String runHookPayload
        +String importMicroVmId
        +Map~String,String~ tags
        +Map~String,Object~ additionalProperties
    }
    class MicroVMStatus {
        +MicroVMState state
        +String microVmId
        +String endpointUrl
        +String resolvedImageArn
        +String resolvedImageVersion
        +List~Condition~ conditions
        +Long observedGeneration
    }
    class MicroVMImage {
        +MicroVMImageSpec spec
        +MicroVMImageStatus status
    }
    class MicroVMImageSpec {
        +MicroVMImageSource source
        +String baseImageArn
        +String buildRoleArn
        +Integer buildTimeoutSeconds
        +Boolean autoActivate
        +Integer memorySizeMiB
        +Integer maxVersionsToKeep
    }
    class MicroVMReplicaSet {
        +MicroVMReplicaSetSpec spec
        +MicroVMReplicaSetStatus status
    }
    class MicroVMReplicaSetSpec {
        +Integer replicas
        +MicroVMTemplateSpec template
        +Integer maxSurge
        +Integer minReady
        +ScaleDownSpec scaleDown
        +String updateStrategyType
        +Integer maxUnavailable
        +String desiredReplicaSetState
    }
    class MicroVMReplicaSetStatus {
        +Integer readyReplicas
        +Integer currentReplicas
        +Integer desiredReplicas
        +Integer suspendedReplicas
        +Integer updatedReplicas
        +String currentTemplateHash
        +List~Condition~ conditions
        +Long observedGeneration
    }
    class MicroVMClass {
        +MicroVMClassSpec spec
    }
    class MicroVMClassSpec {
        +Integer maxIdleDurationSeconds
        +Integer suspendedDurationSeconds
        +Boolean autoResumeEnabled
        +Integer maximumDurationSeconds
        +List~String~ ingressNetworkConnectors
        +List~String~ egressNetworkConnectors
    }
    
    MicroVM --> MicroVMSpec
    MicroVM --> MicroVMStatus
    MicroVMImage --> MicroVMImageSpec
    MicroVMReplicaSet --> MicroVMReplicaSetSpec
    MicroVMReplicaSet --> MicroVMReplicaSetStatus
    MicroVMSpec ..> MicroVMClass : className reference
    MicroVMSpec ..> MicroVMImage : imageRef reference
    MicroVMSpec ..> MicroVMNetwork : networkRef reference
```

## Enums

| Enum | Values |
|------|--------|
| `DesiredState` | Running, Suspended, Terminated |
| `MicroVMState` | Pending, Running, Suspending, Suspended, Terminating, Terminated, Failed |

## State Machine Transitions

| From | Valid Targets |
|------|-------------|
| Pending | Running, Failed |
| Running | Suspending, Terminating |
| Suspending | Suspended |
| Suspended | Running, Terminating |
| Failed | Pending, Terminating |
| Terminating | Terminated |
| Terminated | (none) |

## ReplicaSet Rolling Update Fields

`updateStrategyType` (default: `RollingUpdate`):
- `RollingUpdate` — create new VMs, wait for Running, then terminate old VMs one-by-one
- `Recreate` — terminate all existing VMs first, then create new ones

`currentTemplateHash` — SHA of `spec.template` contents. Changes trigger a rolling update cycle. Reconciler compares this to the current hash on each reconcile.

`updatedReplicas` — count of VMs currently running the current template version.

## AWS SDK Models (operator-aws-client)

Generated from service model. Key types:
- `RunMicrovmRequest/Response` — launch a MicroVM
- `CreateMicrovmImageRequest/Response` — build an image (includes `Resources` with `minimumMemoryInMiB`)
- `CreateMicrovmAuthTokenRequest/Response` — generate JWE auth token
- `NetworkConnector` — VPC egress connector state
- `Resources` — compute sizing (`minimumMemoryInMiB`)

## additionalProperties

`MicroVMSpec` includes `@JsonAnySetter`/`@JsonAnyGetter` for forward-compatibility with new AWS fields. Unknown fields from the API are preserved in a `Map<String, Object>` without breaking deserialization.

## Webhook Deserialization Note

The webhook layer uses `treeToValue(valueToTree(...))` for CRD deserialization — **not** `convertValue()`. `convertValue()` breaks with admission request objects. This is an intentional deviation from the typical Jackson pattern.
