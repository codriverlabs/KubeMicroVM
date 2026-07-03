# Design: MicroVM Memory Sizing

## Status

**Proposed** — document first, implement on feature branch.

## Motivation

AWS Lambda MicroVMs support configurable memory/vCPU sizing at the **image level**.
Memory determines the baseline compute allocation, with vCPU scaling proportionally
(2 GB = 1 vCPU). During peak activity, MicroVMs burst to 4x baseline automatically.

This is a core feature that should be exposed in the `MicroVMImage` CRD spec. Currently
our operator passes no `memory` parameter to the `create-microvm-image` API, so all
images default to 2 GB / 1 vCPU.

## AWS API

The `resources` parameter is set at **image creation time** (not run time):

```bash
aws lambda-microvms create-microvm-image \
  --name my-image \
  --code-artifact uri=s3://bucket/app.zip \
  --base-image-arn arn:aws:lambda:us-east-1:aws:microvm-image:al2023-1 \
  --build-role-arn arn:aws:iam::123456789012:role/BuildRole \
  --resources '[{"minimumMemoryInMiB": 4096}]'
```

The CLI parameter is `--resources` containing a list (max 1 item) with `minimumMemoryInMiB`.

### Available sizes (baseline-peak model)

| Baseline | Peak (4x) | Max Disk | Bandwidth |
|----------|-----------|----------|-----------|
| 512 MB / 0.25 vCPU | 2 GB / 1 vCPU | 8 GB | 8 Mbps |
| 1024 MB / 0.5 vCPU | 4 GB / 2 vCPU | 8 GB | 16 Mbps |
| 2048 MB / 1 vCPU (default) | 8 GB / 4 vCPU | 8 GB | 32 Mbps |
| 4096 MB / 2 vCPU | 16 GB / 8 vCPU | 16 GB | 64 Mbps |
| 8192 MB / 4 vCPU | 32 GB / 16 vCPU | 32 GB | 128 Mbps |

Valid values: 512, 1024, 2048, 4096, 8192 (MB).

## Design

### CRD Change: `MicroVMImageSpec`

Add `memorySizeMB` field to the `MicroVMImage` spec:

```yaml
apiVersion: lambda.aws.amazon.com/v1alpha1
kind: MicroVMImage
metadata:
  name: my-agent
spec:
  source:
    s3Bucket: my-bucket
    s3Key: agent/app.zip
  baseImageArn: "arn:aws:lambda:us-east-1:aws:microvm-image:al2023-1"
  buildRoleArn: "arn:aws:iam::123456789012:role/BuildRole"
  memorySizeMB: 4096    # optional, default: 2048
```

### Field spec

| Field | Type | Required | Default | Valid values |
|-------|------|----------|---------|--------------|
| `memorySizeMB` | Integer | No | 2048 | 512, 1024, 2048, 4096, 8192 |

### Behaviour

- If not set, the AWS default (2048 MB / 1 vCPU) applies.
- The field is **immutable after creation** — changing memory requires creating a new image
  (same as AWS behaviour: memory is set at image creation, cannot be changed with update).
- Validating webhook rejects values not in the allowed set.
- `microvm image describe` shows the configured memory size.

### Status field

Add to `MicroVMImageStatus`:

```java
private Integer memorySizeMB;   // reflects what was passed to AWS
private String computeProfile;  // e.g. "4096 MB / 2 vCPU (peak: 16 GB / 8 vCPU)"
```

### Implementation plan

1. Add `memorySizeMB` to `MicroVMImageSpec.java`
2. Update CRD schema (auto-generated from model)
3. Pass to `CreateMicrovmImageRequest` in `MicroVMImageClient`
4. Add validation in webhook (allowed values: 512, 1024, 2048, 4096, 8192)
5. Add to `microvm image describe` CLI output
6. Update `MicroVMImageStatus` with resolved memory
7. Update user guide and quick-start examples
8. Integration tests

### What NOT to change

- `MicroVMSpec` — memory is NOT a per-VM setting, it's per-image
- `MicroVMClass` — no memory field (class applies to run-time params only)
- `run-microvm` API — AWS doesn't accept memory at run time

## Testing

- Create image with `memorySizeMB: 4096` → verify AWS receives it
- Create image without memorySizeMB → verify default 2048 used
- Create image with `memorySizeMB: 999` → webhook rejects
- Describe shows correct compute profile
