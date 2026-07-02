# User Guide: Quick Start

Get a MicroVM running in about 5 minutes.

## Prerequisites

- EKS cluster with Pod Identity enabled
- `kubectl` configured for your cluster
- AWS credentials with permission to create IAM roles
- `helm` 3.x

## Step 1: Install the operator

```bash
./install_kube_microvm.sh \
  --cluster my-cluster \
  --region us-east-1 \
  --iam
```

This creates the IAM role, deploys the Helm chart, and installs the `microvm` CLI.

Or manually with Helm:

```bash
helm install kube-microvm-operator \
  oci://ghcr.io/plasticity-of-cloud/helm/kube-microvm-operator \
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
  ingressNetworkConnectors:
    - "arn:aws:lambda:us-east-1:aws:network-connector:aws-network-connector:ALL_INGRESS"
```

```bash
kubectl apply -f vm.yaml
microvm list   # watch it come up
```

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
