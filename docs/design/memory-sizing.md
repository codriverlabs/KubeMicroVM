# Design: MicroVM Memory Sizing

## Status

**Proposed** — document first, implement on `feature/memory-sizing` branch.

## Motivation

AWS Lambda MicroVMs support configurable memory/vCPU sizing at the **image level**.
Memory determines the baseline compute allocation, with vCPU scaling proportionally
(2 GB = 1 vCPU). During peak activity, MicroVMs burst to 4x baseline automatically.

This is a core feature that should be exposed in the `MicroVMImage` CRD spec. Currently
our operator passes no `resources` parameter to the `create-microvm-image` API, so all
images default to 2048 MiB / 1 vCPU.

## AWS API

The `--resources` parameter is set at **image creation time** (not run time):

```bash
aws lambda-microvms create-microvm-image \
  --name my-image \
  --code-artifact uri=s3://bucket/app.zip \
  --base-image-arn arn:aws:lambda:us-east-1:aws:microvm-image:al2023-1 \
  --build-role-arn arn:aws:iam::123456789012:role/BuildRole \
  --resources '[{"minimumMemoryInMiB": 4096}]'
```

- CLI parameter: `--resources` (list, max 1 item)
- Field: `minimumMemoryInMiB` (integer, required within the resource object)
- `run-microvm` has NO memory/resource parameter — sizing is per-image only
- `update-microvm-image` does NOT accept `--resources` — memory is immutable after creation

### Available sizes (baseline-peak model)

| Baseline | Peak (4x burst) | Max Disk | Bandwidth |
|----------|-----------------|----------|-----------|
| 512 MiB / 0.25 vCPU | 2048 MiB / 1 vCPU | 8 GB | 8 Mbps |
| 1024 MiB / 0.5 vCPU | 4096 MiB / 2 vCPU | 8 GB | 16 Mbps |
| 2048 MiB / 1 vCPU **(default)** | 8192 MiB / 4 vCPU | 8 GB | 32 Mbps |
| 4096 MiB / 2 vCPU | 16384 MiB / 8 vCPU | 16 GB | 64 Mbps |
| 8192 MiB / 4 vCPU | 32768 MiB / 16 vCPU | 32 GB | 128 Mbps |

Valid values: 512, 1024, 2048, 4096, 8192 (MiB).

---

## Design

### CRD field: `MicroVMImageSpec.memorySizeMiB`

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
  memorySizeMiB: 4096    # optional — omit for AWS default (2048)
```

### Field specification

| Aspect | Value | Reasoning |
|--------|-------|-----------|
| **Name** | `memorySizeMiB` | Matches AWS unit (MiB), unambiguous. AWS field is `minimumMemoryInMiB`. |
| **Type** | Integer | Direct pass-through to AWS API |
| **Required** | No | AWS defaults to 2048 when omitted |
| **CRD default** | None | See "Default strategy" below |
| **Validation** | Webhook | Allowed: 512, 1024, 2048, 4096, 8192 |
| **Immutable** | Yes (after first build) | AWS doesn't allow changing memory on update |

### Default strategy: Option A (chosen)

**Do not set a default in the CRD schema.** If the user omits `memorySizeMiB`:

1. Operator does NOT pass `--resources` to the `create-microvm-image` API call
2. AWS applies its own server-side default (currently 2048 MiB / 1 vCPU)
3. Status field reflects what AWS returned (the effective size)

**Why Option A:**
- If AWS changes the default in the future, we automatically follow
- No coupling between our CRD schema and AWS's server-side defaults
- Less risk of drift between what the CRD says and what AWS does
- Simpler validation: null = don't send, non-null = validate + send

**Rejected alternative (Option B):** Set `default: 2048` in CRD schema. This makes the
field always non-null after admission, coupling us to AWS's current default. If AWS
changes the default, all existing CRs would still have 2048 baked in.

### Data flow

```
User YAML: memorySizeMiB: 4096  (or omitted)
    │
    ▼
Validating Webhook
    │  - If set: reject unless value ∈ {512, 1024, 2048, 4096, 8192}
    │  - If null: allow (AWS default applies)
    │  - On UPDATE: reject if changed from non-null (immutable)
    │
    ▼
MicroVMImageReconciler (CREATE path)
    │  - If memorySizeMiB != null:
    │      request.resources([Resource.builder().minimumMemoryInMiB(value).build()])
    │  - If null: don't set resources on request (AWS default)
    │
    ▼
AWS API: create-microvm-image
    │
    ▼
MicroVMImageReconciler (status update)
    │  - Set status.memorySizeMiB from AWS response (or from spec if AWS doesn't echo it)
    │  - Set status.computeProfile = "4096 MiB / 2 vCPU (peak: 16384 MiB / 8 vCPU)"
    │
    ▼
Status visible via: kubectl get microvmimage -o wide, microvm image describe
```

### Immutability enforcement

On UPDATE admission:
- If `oldSpec.memorySizeMiB != null` and `newSpec.memorySizeMiB != oldSpec.memorySizeMiB`:
  reject with `"spec.memorySizeMiB is immutable after image creation"`
- Setting from null → value on first update is allowed (in case user forgot on create)
- Changing from value → different value is blocked

---

## Implementation plan

### Code changes

| # | File | Change |
|---|------|--------|
| 1 | `operator-core/.../MicroVMImageSpec.java` | Add `private Integer memorySizeMiB;` + getter/setter |
| 2 | `operator-controller/.../MicroVMImageClient.java` | Pass `resources` to `CreateMicrovmImageRequest` when non-null |
| 3 | `operator-webhook/.../MicroVMValidatingWebhook.java` | Validate allowed values + immutability on UPDATE |
| 4 | `operator-core/.../MicroVMImageStatus.java` | Add `memorySizeMiB`, `computeProfile` fields |
| 5 | `operator-controller/.../MicroVMImageReconciler.java` | Set status.memorySizeMiB after create |
| 6 | `operator-cli/.../ImageDescribeCommand.java` | Show memory + compute profile |
| 7 | CRD (auto-generated) | New field in spec + printer column |

### What NOT to change

- `MicroVMSpec` — memory is NOT a per-VM setting, it's per-image
- `MicroVMClass` — no memory field (class applies to run-time params only)
- `run-microvm` call in `DefaultMicroVMClient` — no memory at run time
- `update-microvm-image` call — memory cannot be changed after creation

---

## Testing

| # | Test | Expected |
|---|------|----------|
| 1 | Create image with `memorySizeMiB: 4096` | AWS receives `resources: [{minimumMemoryInMiB: 4096}]` |
| 2 | Create image without memorySizeMiB | No `resources` sent, AWS uses default 2048 |
| 3 | Create image with `memorySizeMiB: 999` | Webhook rejects: "must be one of: 512, 1024, 2048, 4096, 8192" |
| 4 | Update image changing memorySizeMiB 4096 → 8192 | Webhook rejects: "immutable after creation" |
| 5 | `microvm image describe` | Shows "Memory: 4096 MiB / 2 vCPU (peak: 16384 MiB / 8 vCPU)" |
| 6 | `kubectl get microvmimages` | Printer column shows MEMORY |

---

## Documentation & UAT

### User guide

Add `docs/user-guides/memory-sizing.md` covering:
- What memory sizing controls (baseline compute, vCPU proportional, 4x burst)
- Available sizes table
- How to set it in MicroVMImage spec
- Default behaviour (omit = AWS default 2048 MiB)
- Immutability (cannot change after creation — must create new image)
- How to check current size (`microvm image describe`, `kubectl get microvmimages`)
- Example: choosing the right size for your workload

### UAT

Add test cases to `docs/testing/uat-user-guides.md` under a new **UG-MEM** section:

| # | Step | Expected |
|---|------|----------|
| MEM-01 | Create MicroVMImage with `memorySizeMiB: 4096` | Image created, status shows 4096 MiB |
| MEM-02 | Create MicroVMImage without memorySizeMiB | Image created, status shows 2048 (AWS default) |
| MEM-03 | Create MicroVMImage with `memorySizeMiB: 999` | Webhook rejects |
| MEM-04 | Update existing image changing memorySizeMiB | Webhook rejects (immutable) |
| MEM-05 | `microvm image describe` shows memory/compute profile | "4096 MiB / 2 vCPU" visible |
| MEM-06 | `kubectl get microvmimages` shows MEMORY column | Column populated |
| MEM-07 | Run MicroVM from 4096 MiB image, verify it works | VM runs, endpoint responds |

---

## User-facing example

```yaml
# Small (batch jobs, lightweight agents)
apiVersion: lambda.aws.amazon.com/v1alpha1
kind: MicroVMImage
metadata:
  name: batch-worker
spec:
  source: { s3Bucket: my-bucket, s3Key: worker.zip }
  baseImageArn: "arn:aws:lambda:us-east-1:aws:microvm-image:al2023-1"
  buildRoleArn: "arn:aws:iam::123456789012:role/BuildRole"
  memorySizeMiB: 512    # 0.25 vCPU baseline, bursts to 1 vCPU

---
# Large (data processing, ML inference)
apiVersion: lambda.aws.amazon.com/v1alpha1
kind: MicroVMImage
metadata:
  name: ml-inference
spec:
  source: { s3Bucket: my-bucket, s3Key: model.zip }
  baseImageArn: "arn:aws:lambda:us-east-1:aws:microvm-image:al2023-1"
  buildRoleArn: "arn:aws:iam::123456789012:role/BuildRole"
  memorySizeMiB: 8192   # 4 vCPU baseline, bursts to 16 vCPU
```
