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
        +Map~String,String~ tags
    }
    class MicroVMStatus {
        +MicroVMState state
        +String microVmId
        +String endpointUrl
        +String resolvedImageArn
        +String resolvedImageVersion
        +List~Condition~ conditions
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

## AWS SDK Models (operator-aws-client)

Generated from service model. Key types:
- `RunMicrovmRequest/Response` — launch a MicroVM
- `CreateMicrovmImageRequest/Response` — build an image (includes `Resources` with `minimumMemoryInMiB`)
- `CreateMicrovmAuthTokenRequest/Response` — generate JWE auth token
- `NetworkConnector` — VPC egress connector state
- `Resources` — compute sizing (`minimumMemoryInMiB`)

## additionalProperties

`MicroVMSpec` includes `@JsonAnySetter`/`@JsonAnyGetter` for forward-compatibility with new AWS fields. Unknown fields from the API are preserved in a `Map<String, Object>` without breaking deserialization.
