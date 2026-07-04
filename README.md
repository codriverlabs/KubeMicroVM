# KubeMicroVM

Kubernetes operator and CLI for **AWS Lambda MicroVMs** — run isolated, fast-starting
compute environments directly from your cluster, with the same Kubernetes workflow
you already use.

Built with **Quarkus 3**, **JOSDK**, **GraalVM native image** (Java 25).

[![Release](https://img.shields.io/github/v/release/plasticity-of-cloud/KubeMicroVM)](https://github.com/plasticity-of-cloud/KubeMicroVM/releases)

---

## What is KubeMicroVM?

AWS Lambda MicroVMs are lightweight, fast-booting virtual machines managed by AWS.
KubeMicroVM brings them into the Kubernetes resource model:

- Define MicroVMs as Kubernetes CRs (`kubectl apply -f vm.yaml`)
- Scale with `MicroVMReplicaSet`
- Access from pods via sidecar token injection — no AWS credentials in your app
- Use `microvm` CLI for day-to-day operations

---

## Components

| Module | Description |
|--------|-------------|
| `operator-core` | CRD models, state machine, enums |
| `operator-controller` | JOSDK reconcilers, AWS SDK integration, drift detection |
| `operator-webhook` | Validating + mutating admission webhooks (co-located in operator pod) |
| `operator-auth-agent` | Sidecar that auto-refreshes MicroVM auth tokens in pods |
| `operator-cli` | `microvm` CLI (native binary, also works as `kubectl microvm`) |

---

## Custom Resources

| Resource | Description |
|----------|-------------|
| `MicroVM` | Maps 1:1 to an AWS Lambda MicroVM instance |
| `MicroVMImage` | Builds and manages MicroVM container images from S3 source |
| `MicroVMReplicaSet` | Manages a pool of identical MicroVM replicas |
| `MicroVMNetwork` | VPC egress network connector configuration |
| `MicroVMClass` | Named runtime profile (idle policy, networking) — like StorageClass |

---

## Installation

> **Latest stable release: `v1.0.0`** — [Download](https://github.com/plasticity-of-cloud/KubeMicroVM/releases/latest)
>
> **Requires a Kubernetes cluster on AWS**, one of:
> - **Amazon EKS** with [Pod Identity](https://docs.aws.amazon.com/eks/latest/userguide/pod-identities.html) enabled (recommended)
> - **Any Kubernetes distribution** on AWS with [IRSA](https://docs.aws.amazon.com/eks/latest/userguide/iam-roles-for-service-accounts.html) configured
> - **[EKS-DX](https://eksdx.express)** — Kubernetes distribution with built-in EKS Pod Identity support

### Quickstart (one command)

```bash
# Download and verify installer
curl -fsSL https://github.com/plasticity-of-cloud/KubeMicroVM/releases/latest/download/install_kube_microvm.sh \
  -o install_kube_microvm.sh
curl -fsSL https://github.com/plasticity-of-cloud/KubeMicroVM/releases/latest/download/install_kube_microvm.sh.sha256 \
  -o install_kube_microvm.sh.sha256
sha256sum -c install_kube_microvm.sh.sha256
chmod +x install_kube_microvm.sh

./install_kube_microvm.sh \
  --cluster my-eks-cluster \
  --region us-east-1 \
  --iam
```

### Full installer (with private registry)

```bash
# Download installer
curl -fsSL https://github.com/plasticity-of-cloud/KubeMicroVM/releases/latest/download/install_kube_microvm.sh \
  -o install_kube_microvm.sh && chmod +x install_kube_microvm.sh

# Install with private ECR registry + IAM setup
./install_kube_microvm.sh \
  --cluster my-cluster \
  --region us-east-1 \
  --registry 123456789012.dkr.ecr.us-east-1.amazonaws.com \
  --iam \
  --auth-agent

# CLI only (no cluster required)
./install_kube_microvm.sh --cli-only
```

### Helm (manual)

```bash
# Pin to a specific version (find latest at github.com/plasticity-of-cloud/KubeMicroVM/releases)
CHART_VERSION=1.0.0   # replace with the version you want

# EKS Pod Identity (recommended)
helm install kube-microvm-operator \
  oci://ghcr.io/plasticity-of-cloud/helm/kube-microvm-operator \
  --version $CHART_VERSION \
  --namespace kube-microvm --create-namespace \
  --set app.envs.AWS_REGION=us-east-1

# Create Pod Identity association
aws eks create-pod-identity-association \
  --cluster-name <CLUSTER> \
  --namespace kube-microvm \
  --service-account kube-microvm-operator \
  --role-arn arn:aws:iam::<ACCOUNT_ID>:role/kube-microvm-operator
```

### CLI

```bash
# Detect architecture and install microvm binary
ARCH=$(uname -m | sed 's/x86_64/amd64/' | sed 's/aarch64/arm64/')
curl -fsSL "https://github.com/plasticity-of-cloud/KubeMicroVM/releases/latest/download/microvm-linux-${ARCH}" \
  -o ~/bin/microvm && chmod +x ~/bin/microvm
ln -sf ~/bin/microvm ~/bin/kubectl-microvm

# Verify
microvm --version

# Shell completion
source <(microvm completion bash)   # or zsh
```

---

## IAM Requirements

The operator needs these permissions:

```yaml
# Core MicroVM operations
- lambda:*Microvm*
- lambda:*NetworkConnector*
- lambda:*MicrovmImage*
# EC2 networking (for VPC connectors)
- ec2:DescribeSecurityGroups
- ec2:DescribeSubnets
- ec2:CreateNetworkInterface
# IAM (for build role pass + service-linked role)
- iam:PassRole       # for KubeMicroVMBuildRole and self
- iam:CreateServiceLinkedRole
# STS
- sts:GetCallerIdentity
```

See [`iam/kube-microvm-operator-role.yaml`](iam/kube-microvm-operator-role.yaml) for the
complete CloudFormation template.

---

## Quick Example

> Replace `123456789012` with your AWS account ID and `my-bucket` with your S3 bucket name.

```yaml
# 1. Build a MicroVM image from your S3 source
apiVersion: lambda.aws.amazon.com/v1alpha1
kind: MicroVMImage
metadata:
  name: my-agent
  namespace: default
spec:
  source:
    s3Bucket: my-bucket
    s3Key: agent/app.zip
  baseImageArn: "arn:aws:lambda:us-east-1:aws:microvm-image:al2023-1"
  buildRoleArn: "arn:aws:iam::123456789012:role/KubeMicroVMBuildRole"
---
# 2. Run a MicroVM
apiVersion: lambda.aws.amazon.com/v1alpha1
kind: MicroVM
metadata:
  name: agent-session-1
  namespace: default
spec:
  imageRef: my-agent
  className: agentic-standard
  desiredState: Running
```

```bash
# Watch it come up
microvm list -w

# Get a token and call the endpoint
TOKEN=$(microvm token --name agent-session-1 --direct)
ENDPOINT=$(microvm describe agent-session-1 -o endpoint)
curl -H "X-aws-proxy-auth: $TOKEN" "https://$ENDPOINT/"
```

---

## CLI Reference

```
microvm                          # show help
microvm list                     # list all MicroVMs
microvm describe <name>          # show details
microvm create --name x --image y # create a MicroVM
microvm delete <name>            # delete (sets desiredState: Terminated)
microvm pause <name>             # suspend
microvm resume <name>            # resume
microvm token --name <name>      # get auth token (via operator, no AWS creds needed)
microvm token --name <name> --direct  # get token directly via AWS SDK
microvm exec <name>              # get shell credentials
microvm image list               # list MicroVMImages
microvm image create ...         # create image from S3
microvm image base-images        # list AWS-managed base images
microvm rs list                  # list ReplicaSets
microvm network list             # list MicroVMNetworks
```

---

## Namespace Setup

Label a namespace to enable MicroVM management:

```bash
kubectl label namespace my-team lambda.aws.amazon.com/manage-microvms=true
```

The operator only watches labelled namespaces. The validating webhook enforces this at admission time.

---

## Pod Sidecar Token Injection

Annotate a pod to have auth tokens automatically refreshed:

```yaml
metadata:
  annotations:
    lambda.microvm.auth: my-vm    # VM name
spec:
  serviceAccountName: my-app-sa  # must have create on microvms/token
```

The `microvm-auth-agent` sidecar is injected automatically. Token is available at
`/var/run/microvm/auth-token`. See [pod token injection guide](docs/user-guides/pod-token-injection.md).

---

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│  Kubernetes Cluster                                       │
│                                                           │
│  ┌──────────────────────────────────┐                    │
│  │  kube-microvm namespace           │                    │
│  │  ┌────────────────────────────┐  │                    │
│  │  │  kube-microvm-operator     │  │                    │
│  │  │  ├─ MicroVM reconciler     │  │──→ AWS Lambda      │
│  │  │  ├─ Image reconciler       │  │    MicroVMs API    │
│  │  │  ├─ ReplicaSet reconciler  │  │                    │
│  │  │  ├─ Validating webhook     │  │                    │
│  │  │  ├─ Mutating webhook       │  │                    │
│  │  │  └─ Token endpoint (HTTPS) │  │                    │
│  │  └────────────────────────────┘  │                    │
│  └──────────────────────────────────┘                    │
│                                                           │
│  ┌─────────────────────────────────────────────────────┐ │
│  │  User namespace (lambda.aws.amazon.com/manage-      │ │
│  │                  microvms=true)                     │ │
│  │  ┌──────────────────────┐  ┌──────────────────────┐ │ │
│  │  │ Pod                  │  │ MicroVM CR           │ │ │
│  │  │ ├─ app container     │  │ ├─ spec.imageRef     │ │ │
│  │  │ └─ microvm-auth-agent│  │ ├─ spec.className    │ │ │
│  │  │    (injected sidecar)│  │ └─ status.state      │ │ │
│  │  └──────────────────────┘  └──────────────────────┘ │ │
│  └─────────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────┘
```

---

## Security

- **TLS**: Operator webhook endpoint uses cert-manager-issued certificate (port 8443)
- **Token auth**: Two-step Kubernetes TokenReview + SubjectAccessReview before calling AWS
- **RBAC scoped**: Pods can only get tokens for VMs they're explicitly granted access to
- **In-memory tokens**: Auth tokens stored in `emptyDir medium: Memory` — never touch disk
- **Namespace isolation**: Operator watches only labelled namespaces

---

## Development

```bash
# Build all modules
./mvnw package -DskipTests

# Run integration tests (49 tests)
./mvnw -pl operator-tests verify

# Build native CLI
./mvnw -pl operator-cli package -Pnative -DskipTests

# Build + push to ECR + Helm chart
./build-local.sh --push --helm --skip-tests \
  --registry <your-ecr-registry>
```

---

## Documentation

| Guide | Description |
|-------|-------------|
| [Quick Start](docs/user-guides/quick-start.md) | Get a MicroVM running in 5 minutes |
| [RBAC](docs/user-guides/rbac.md) | All roles — IAM, Kubernetes, app SA setup |
| [Pod Token Injection](docs/user-guides/pod-token-injection.md) | Auth tokens in pods without AWS credentials |
| [MicroVMClass](docs/user-guides/microvm-class.md) | Runtime profiles for idle policy and networking |
| [Networking](docs/user-guides/networking.md) | Networking modes, VPC egress, MicroVMNetwork |
| [ReplicaSet](docs/user-guides/replicaset.md) | Scaling and managing VM pools |
| [Drift & Auto-Suspend](docs/user-guides/drift-and-autosuspend.md) | Drift detection and idle policy |
| [CLI Reference](docs/user-guides/cli-reference.md) | Complete `microvm` CLI reference |
| [Namespace Watching](docs/design/namespace-watching.md) | Controlling which namespaces the operator manages |
| [Token Injection Design](docs/design/token-injection.md) | Auth architecture and RBAC design |
| [CLI Naming](docs/design/cli-naming.md) | `microvm` vs `kubectl microvm` |

---

## License

Copyright (c) 2026 Plasticity.Cloud & Codriverlabs

Licensed under the [Elastic License 2.0 (ELv2)](LICENSE.md).
