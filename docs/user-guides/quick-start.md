# User Guide: Quick Start

Get a MicroVM running in about 5 minutes.

> **Before you start**: Replace the following placeholders throughout this guide:
>
> | Placeholder | Replace with |
> |-------------|-------------|
> | `123456789012` | Your 12-digit AWS account ID (`aws sts get-caller-identity --query Account --output text`) |
> | `my-cluster` | Your EKS cluster name |
> | `my-bucket` | Your S3 bucket name |
> | `us-east-1` | Your AWS region |

## Prerequisites

- **Kubernetes cluster on AWS**, one of:
  - **Amazon EKS** with [Pod Identity](https://docs.aws.amazon.com/eks/latest/userguide/pod-identities.html) enabled (recommended)
  - **Any Kubernetes distribution** on AWS with [IRSA](https://docs.aws.amazon.com/eks/latest/userguide/iam-roles-for-service-accounts.html) configured
  - **[EKS-DX](https://eksdx.express)** — Kubernetes distribution with built-in EKS Pod Identity support
- `kubectl` configured for your cluster
- AWS credentials with permission to create IAM roles
- `helm` 3.x

## Step 1: Install the operator

```bash
# Download and verify installer
curl -fsSL https://github.com/codriverlabs/KubeMicroVM/releases/latest/download/install_kube_microvm.sh \
  -o install_kube_microvm.sh
curl -fsSL https://github.com/codriverlabs/KubeMicroVM/releases/latest/download/install_kube_microvm.sh.sha256 \
  -o install_kube_microvm.sh.sha256
sha256sum -c install_kube_microvm.sh.sha256
chmod +x install_kube_microvm.sh

# Run
./install_kube_microvm.sh \
  --cluster my-cluster \
  --region us-east-1 \
  --iam
```

This creates the IAM role, deploys the Helm chart, and installs the `microvm` CLI.

Or manually with Helm:

```bash
# Pin to a specific version (recommended — find latest at github.com/codriverlabs/KubeMicroVM/releases)
CHART_VERSION=1.0.14   # replace with the version you want

helm install kube-microvm-operator \
  oci://ghcr.io/codriverlabs/helm/kube-microvm-operator \
  --version $CHART_VERSION \
  --namespace kube-microvm --create-namespace \
  --set app.envs.AWS_REGION=us-east-1

aws eks create-pod-identity-association \
  --cluster-name my-cluster \
  --namespace kube-microvm \
  --service-account kube-microvm-operator \
  --role-arn arn:aws:iam::123456789012:role/kube-microvm-operator
```

## Step 2: Label your namespace

```bash
kubectl label namespace default lambda.aws.amazon.com/manage-microvms=true
```

## Step 3: Build a MicroVM image

Package your application as a zip and upload to S3:

```bash
zip -r app.zip Dockerfile app/
aws s3 cp app.zip s3://my-bucket/microvm/app.zip
```

Create the `MicroVMImage`:

```yaml
# image.yaml
apiVersion: lambda.aws.amazon.com/v1alpha1
kind: MicroVMImage
metadata:
  name: my-app
  namespace: default
spec:
  source:
    s3Bucket: my-bucket
    s3Key: microvm/app.zip
  baseImageArn: "arn:aws:lambda:us-east-1:aws:microvm-image:al2023-1"
  buildRoleArn: "arn:aws:iam::123456789012:role/KubeMicroVMBuildRole"
```

```bash
kubectl apply -f image.yaml

# Watch the build
microvm image describe my-app
```

> **Build time**: Image builds take 2–4 minutes (same as AWS Console or CLI) — this is
> a one-time cost. Once built, MicroVMs launch from the snapshot in seconds.

## Step 4: Run a MicroVM

```yaml
# vm.yaml
apiVersion: lambda.aws.amazon.com/v1alpha1
kind: MicroVM
metadata:
  name: my-vm
  namespace: default
spec:
  imageRef: my-app
  desiredState: Running
  maxIdleDurationSeconds: 900
  suspendedDurationSeconds: 1800
```

```bash
kubectl apply -f vm.yaml
microvm list   # watch it come up — wait until STATE shows Running
```

> **Note**: After the VM reaches `Running`, allow up to 60s for `status.endpointUrl`
> to be populated before calling it.

## Step 5: Call it

```bash
# Get a token directly (requires AWS credentials)
TOKEN=$(microvm token --name my-vm --direct)
ENDPOINT=$(kubectl get microvm my-vm -o jsonpath='{.status.endpointUrl}')
curl -H "X-aws-proxy-auth: $TOKEN" "https://$ENDPOINT/"
```

Or use the operator token endpoint (no AWS credentials needed — requires RBAC):

```bash
# See docs/user-guides/pod-token-injection.md for in-cluster token auth
TOKEN=$(microvm token --name my-vm)
```

## Tear down

```bash
kubectl patch microvm my-vm --type=merge -p '{"spec":{"desiredState":"Terminated"}}'
kubectl delete microvm my-vm
kubectl delete microvmimage my-app
```
