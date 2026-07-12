# Workflows

## Feature Development Workflow

```mermaid
graph LR
    A[Design doc in docs/design/] --> B[Feature branch]
    B --> C[Implement]
    C --> D[Integration tests pass]
    D --> E[Build + push image]
    E --> F[Deploy to EKS]
    F --> G[E2E test on cluster]
    G --> H[Merge to main]
    H --> I[Tag release]
```

Key rules:
- Tests required before push (code changes only)
- `helm uninstall` + `helm install` (never `upgrade` during dev)
- Delete webhooks before CRs when operator is down
- Patch finalizers before deleting CRs without operator

## Image Build Workflow

```mermaid
sequenceDiagram
    participant U as User
    participant K as Kubernetes
    participant R as ImageReconciler
    participant AWS as AWS Lambda

    U->>K: kubectl apply MicroVMImage
    K->>R: Reconcile (imageArn=null)
    R->>AWS: CreateMicrovmImage(name, s3Uri, baseArn, buildRole, resources)
    AWS-->>R: imageArn, state=CREATING
    R->>K: Patch status (imageArn, CREATING)
    loop Poll every 15s
        R->>AWS: GetMicrovmImage
        AWS-->>R: state, versionState
        R->>K: Patch status
    end
    Note over AWS: Build completes
    R->>AWS: GetMicrovmImage → CREATED, version SUCCESSFUL
    R->>AWS: UpdateMicrovmImageVersion(ACTIVE)
    R->>K: Patch status (CREATED, activeVersion)
```

## MicroVM Run Workflow

```mermaid
sequenceDiagram
    participant U as User
    participant K as Kubernetes
    participant R as MicroVMReconciler
    participant AWS as AWS Lambda

    U->>K: kubectl apply MicroVM (desiredState: Running)
    K->>R: Reconcile (state=null)
    R->>R: resolveImageRef → imageArn
    R->>R: resolveNetworkRef → connectorArn (if set)
    R->>AWS: RunMicrovm(imageArn, idlePolicy, connectors)
    AWS-->>R: microvmId, endpoint, state=RUNNING
    R->>K: Patch status (Running, endpoint, vmId)
```

## Token Flow (in-cluster, sidecar injection)

```mermaid
sequenceDiagram
    participant App as App Container
    participant Agent as Auth Agent Sidecar
    participant Op as Operator Token Endpoint
    participant K8s as Kubernetes API
    participant AWS as AWS Lambda

    Agent->>Op: POST /token (SA bearer token)
    Op->>K8s: TokenReview (identify SA caller)
    K8s-->>Op: username + groups
    Op->>K8s: SubjectAccessReview (can identity create microvms/token/{name}?)
    K8s-->>Op: allowed
    Op->>AWS: CreateMicrovmAuthToken
    AWS-->>Op: JWE token
    Op-->>Agent: {authToken, endpoint, expiresAt}
    Agent->>Agent: Write to /var/run/microvm/ (auth-token, endpoint, .ready)
    App->>App: Detect .ready sentinel, read token file
    App->>AWS: HTTPS request with X-aws-proxy-auth
```

## ReplicaSet Rolling Update Workflow

```mermaid
sequenceDiagram
    participant U as User
    participant R as ReplicaSetReconciler
    participant VMs as Child MicroVMs

    U->>U: Change spec.template.imageRef
    R->>R: Compute new templateHash
    R->>R: Detect hash != status.currentTemplateHash
    loop Until all VMs updated
        R->>VMs: Create new VM (new image, surge slot)
        R->>R: Wait for new VM → Running
        R->>VMs: Set oldest outdated VM desiredState=Terminated
        R->>R: Reschedule(10s)
    end
    R->>R: Update status.currentTemplateHash
    R->>R: Update status.updatedReplicas
```

## EKS Deployment Workflow

```mermaid
graph TD
    A[Delete webhook configs] --> B[Patch finalizers + delete CRs]
    B --> C[helm uninstall]
    C --> D[Delete stale secrets/certs]
    D --> E[helm install with new image]
    E --> F[Verify operator pod Running]
    F --> G[Verify webhooks active]
    G --> H[Create test CRs]
```

## Release Workflow

```mermaid
graph LR
    A[All tests pass] --> B[Tag vX.Y.Z-rcN]
    B --> C[GitHub Actions]
    C --> D[Native binaries linux/amd64 + arm64]
    C --> E[Container images → GHCR]
    C --> F[Helm chart → OCI registry]
    C --> G[GitHub Release with checksums]
```

Tag notation: `v<major>.<minor>.<patch>-rc<N>` → GA drops `-rcN` suffix.
