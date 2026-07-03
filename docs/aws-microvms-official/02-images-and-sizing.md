# MicroVM Images
Source: https://docs.aws.amazon.com/lambda/latest/dg/microvms-images.html
Downloaded: 2026-07-03T14:32:00Z

A MicroVM image defines the filesystem and application environment. Includes runtime
environment, application code, and supporting programs. Created from a zip (Dockerfile +
artifacts) uploaded to S3.

## How Lambda builds a MicroVM image

1. Retrieves packaged artifacts from S3
2. Starts a fresh MicroVM from the Lambda-managed base image
3. Executes Dockerfile instructions
4. Launches application via ENTRYPOINT/CMD
5. Waits for initialization (signalled by /ready hook)
6. Captures snapshot of disk and memory state

Image enters `CREATED` state. Each image can run multiple independent MicroVMs.

## MicroVM sizing

Lambda MicroVMs uses a **baseline-peak model**. You configure baseline compute resources.
During peak activity, MicroVM scales vertically up to **4x the baseline**. You pay baseline
rate while running; only pay for active use above baseline, billed per second.

**You set baseline via the `memory` parameter when creating the MicroVM image.**
vCPU scales proportionally with memory (2 GB = 1 vCPU). Default baseline: 2 GB / 1 vCPU.

### Available sizes

| Baseline | Peak | Max Disk Space |
|----------|------|----------------|
| 0.5 GB memory, 0.25 vCPU | 2 GB memory, 1 vCPU | 8 GB |
| 1 GB memory, 0.5 vCPU | 4 GB memory, 2 vCPU | 8 GB |
| 2 GB memory, 1 vCPU (default) | 8 GB memory, 4 vCPU | 8 GB |
| 4 GB memory, 2 vCPU | 16 GB memory, 8 vCPU | 16 GB |
| 8 GB memory, 4 vCPU | 32 GB memory, 16 vCPU | 32 GB |

## MicroVM base images

Lambda-managed base images provide Amazon Linux 2023 + service components. Periodically
updated for security patches. Default: latest version applied on create/update.

Override with `base-image-version` parameter.

### Deprecation lifecycle

- `AVAILABLE` — current, recommended
- `DEPRECATED` (60 days) — newer exists, can still build/run
- `EXPIRING` (30 days) — cannot create new images, existing can run
- `EXPIRED` — cannot build or run, must rebuild
- `RECALLED` — immediately unavailable (critical security, rare)

### APIs

```bash
aws lambda-microvms list-managed-microvm-images
aws lambda-microvms list-managed-microvm-image-versions \
  --image-identifier arn:aws:lambda:us-east-1:aws:microvm-image:al2023-1
```

## MicroVM image build hooks

| Hook | Path | Details | Status Codes | Timeout |
|------|------|---------|--------------|---------|
| /ready | `/aws/lambda-microvms/runtime/v1/ready` | Signals app ready to be snapshotted | 503: retry, 200: snapshot | 1–3600s |
| /validate | `/aws/lambda-microvms/runtime/v1/validate` | Confirms app works when resumed | 503: retry, 200: pass | 1–3600s |

Note: /validate hook can also optimize startup time by running mock payloads.

## Updating a MicroVM image

```bash
aws lambda-microvms update-microvm-image \
  --image-identifier arn:aws:lambda:us-east-1:123456789012:microvm-image:my-image \
  --code-artifact uri=s3://my-bucket/deployments/app-v2.zip \
  --base-image-arn arn:aws:lambda:us-east-1:aws:microvm-image:al2023-1 \
  --build-role-arn arn:aws:iam::123456789012:role/MicrovmBuildRole \
  --description "Updated with v2 application code"
```

`--base-image-arn` and `--build-role-arn` are required on every update call.

## Image states

- **Image state** — overall lifecycle (CREATING, CREATED, UPDATING, FAILED, DELETING)
- **Version state** — build progress of specific version (PENDING, IN_PROGRESS, SUCCESSFUL, FAILED)
- **Version activation** — whether a version is active for new MicroVMs
