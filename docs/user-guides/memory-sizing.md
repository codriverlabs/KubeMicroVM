# User Guide: Memory Sizing

Lambda MicroVMs support configurable memory/vCPU sizing using a baseline-peak model.
You set the baseline when creating a MicroVMImage. During peak activity, MicroVMs
automatically burst to 4x the baseline. You pay the baseline rate while running.

> **Replace throughout this guide**:
> - `123456789012` → your AWS account ID
> - `my-bucket` → your S3 bucket name

---

## Available sizes

| Baseline | Peak (4x burst) | Max Disk | Bandwidth |
|----------|-----------------|----------|-----------|
| 512 MiB / 0.25 vCPU | 2 GiB / 1 vCPU | 8 GB | 8 Mbps |
| 1024 MiB / 0.5 vCPU | 4 GiB / 2 vCPU | 8 GB | 16 Mbps |
| **2048 MiB / 1 vCPU (default)** | 8 GiB / 4 vCPU | 8 GB | 32 Mbps |
| 4096 MiB / 2 vCPU | 16 GiB / 8 vCPU | 16 GB | 64 Mbps |
| 8192 MiB / 4 vCPU | 32 GiB / 16 vCPU | 32 GB | 128 Mbps |

vCPU scales proportionally: **2048 MiB = 1 vCPU**.

---

## Setting memory size

Add `memorySizeMiB` to your `MicroVMImage` spec:

```yaml
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
  memorySizeMiB: 4096    # 2 vCPU baseline, bursts to 8 vCPU
```

---

## Default behaviour

If you **omit** `memorySizeMiB`, AWS uses the default: **2048 MiB / 1 vCPU**.

```yaml
spec:
  source:
    s3Bucket: my-bucket
    s3Key: agent/app.zip
  baseImageArn: "arn:aws:lambda:us-east-1:aws:microvm-image:al2023-1"
  buildRoleArn: "arn:aws:iam::123456789012:role/KubeMicroVMBuildRole"
  # memorySizeMiB not set → AWS default 2048 MiB / 1 vCPU
```

---

## Immutability

Memory size is **set at image creation and cannot be changed**. This is an AWS
constraint — memory is baked into the snapshot at build time.

To change the memory size, create a new `MicroVMImage` with the desired size.

```yaml
# This will be REJECTED by the webhook:
# Changing memorySizeMiB from 4096 to 8192 on an existing image
```

---

## Checking memory size

```bash
# CLI
microvm image describe my-agent

# Output includes:
# Memory:         4096 MiB
# Compute:        4096 MiB / 2 vCPU (peak: 16384 MiB / 8 vCPU)

# kubectl
kubectl get microvmimage my-agent -o jsonpath='{.status.memorySizeMiB}'
kubectl get microvmimage my-agent -o jsonpath='{.status.computeProfile}'
```

---

## Choosing the right size

| Workload | Recommended | Rationale |
|----------|-------------|-----------|
| Lightweight agents, CLI tools | 512 MiB | Minimal memory, low cost |
| Web apps, standard agents | 2048 MiB (default) | Good balance of cost and performance |
| Data processing, notebooks | 4096 MiB | More memory for datasets |
| ML inference, heavy compute | 8192 MiB | Maximum baseline (32 GiB peak) |

**Tip**: Start with the default (2048 MiB). If your workload hits memory limits
or CPU saturation during peak, create a new image with a larger size.

---

## Examples

### Small batch worker (cost-optimized)

```yaml
apiVersion: lambda.aws.amazon.com/v1alpha1
kind: MicroVMImage
metadata:
  name: batch-worker
spec:
  source: { s3Bucket: my-bucket, s3Key: worker.zip }
  baseImageArn: "arn:aws:lambda:us-east-1:aws:microvm-image:al2023-1"
  buildRoleArn: "arn:aws:iam::123456789012:role/KubeMicroVMBuildRole"
  memorySizeMiB: 512
```

### Large ML inference (performance-optimized)

```yaml
apiVersion: lambda.aws.amazon.com/v1alpha1
kind: MicroVMImage
metadata:
  name: ml-inference
spec:
  source: { s3Bucket: my-bucket, s3Key: model-server.zip }
  baseImageArn: "arn:aws:lambda:us-east-1:aws:microvm-image:al2023-1"
  buildRoleArn: "arn:aws:iam::123456789012:role/KubeMicroVMBuildRole"
  memorySizeMiB: 8192
```
