# Architecture

## System Overview

```mermaid
graph TB
    subgraph "Kubernetes Cluster"
        subgraph "kube-microvm namespace"
            OP[Operator Pod]
            OP --> REC[Reconcilers]
            OP --> WH[Webhooks]
            OP --> TOK[Token Endpoint]
        end
        subgraph "User namespace"
            POD[App Pod]
            SIDE[Auth Agent Sidecar]
            CRs[MicroVM CRs]
        end
    end
    
    REC -->|lambda-microvms API| AWS[AWS Lambda MicroVMs]
    TOK -->|TokenReview + SAR| KAPI[Kubernetes API]
    SIDE -->|POST /token| TOK
    POD -->|read /var/run/microvm/| SIDE
    POD -->|HTTPS + JWE token| AWS
```

## Reconciliation Pattern

Each reconciler follows the ACK (AWS Controllers for Kubernetes) pattern:

```mermaid
sequenceDiagram
    participant K8s as Kubernetes
    participant R as Reconciler
    participant AWS as AWS API
    
    K8s->>R: CR event (create/update/delete)
    R->>AWS: Describe resource
    alt Resource exists
        R->>R: Compare spec vs AWS state
        alt Drift detected
            R->>AWS: Correct drift
        end
        R->>K8s: Patch status
    else Resource not found
        R->>AWS: Create resource
        R->>K8s: Patch status + reschedule
    end
```

## State Machine (MicroVM lifecycle)

```mermaid
stateDiagram-v2
    [*] --> Pending: create
    Pending --> Running: AWS confirms running
    Pending --> Failed: creation error
    Running --> Suspending: idle timeout / suspend API
    Running --> Terminating: delete / desiredState=Terminated
    Suspending --> Suspended: AWS confirms
    Suspended --> Running: traffic / resume API
    Suspended --> Terminating: delete / timeout
    Failed --> Pending: retry
    Failed --> Terminating: delete
    Terminating --> Terminated: AWS confirms
    Terminated --> [*]
```

## Admission Control Flow

```mermaid
graph LR
    REQ[kubectl apply] --> VW[Validating Webhook]
    VW -->|namespace label check| VW
    VW -->|className exists check| VW
    VW -->|memorySizeMiB validation| VW
    VW -->|networkRef resolution| VW
    VW --> MW[Mutating Webhook]
    MW -->|merge MicroVMClass defaults| MW
    MW -->|set global defaults| MW
    MW --> ETCD[etcd]
    ETCD --> REC2[Reconciler]
```

## Design Principles

- **Namespace isolation**: Operator watches only namespaces labelled `lambda.aws.amazon.com/manage-microvms=true`
- **Finalizer-based cleanup**: All CRs with AWS resources have finalizers to prevent orphaning
- **Drift detection**: Reconcilers poll AWS state and correct divergence
- **Token-based auth**: Two-step Kubernetes TokenReview + SubjectAccessReview before proxying to AWS
- **Immutable image sizing**: Memory is set at image creation (AWS constraint)
- **Class inheritance**: MicroVMClass provides opt-in defaults merged at admission time
