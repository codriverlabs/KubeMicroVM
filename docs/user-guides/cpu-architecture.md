# User Guide: CPU Architecture

Lambda MicroVM images support two CPU architectures:

| Value | Platform |
|-------|----------|
| `ARM_64` | AWS Graviton (ARM64) |
| `X86_64` | x86-64 |

You select the architecture on `MicroVMImage`. Each MicroVM launched from an
image version uses the architecture selected when that version was built.

> **Important:** The Lambda-managed base image version, every `FROM` image in
your Dockerfile, and all prebuilt binaries in your source artifact must match
the selected architecture. AWS rejects a build if its selected base image
version does not support that architecture.

## Choose an architecture

Use `ARM_64` when your application and its dependencies support ARM64. This
preserves the existing KubeMicroVM behavior.

Use `X86_64` when your application includes x86-64-only native libraries,
prebuilt executables, or Docker image layers. Do not select `X86_64` merely
because the Kubernetes node or the local development machine is x86-64. The
architecture is for the AWS Lambda MicroVM image, not the operator pod or the
`microvm` CLI binary.

## Check base-image compatibility

Before selecting an architecture, inspect the Lambda-managed base image version
that you intend to use. AWS exposes its supported CPU configurations through
`ListManagedMicrovmImageVersions`.

KubeMicroVM surfaces this information through the CLI:

```bash
microvm image base-images --arn <BASE_IMAGE_ARN>
```

Select a base image version that lists the desired architecture. Pin a known
compatible base-image version when reproducible builds are required.

## Create an x86-64 image

Set `spec.architecture` to `X86_64`:

```yaml
apiVersion: lambda.aws.amazon.com/v1alpha1
kind: MicroVMImage
metadata:
  name: x86-agent
  namespace: default
spec:
  source:
    s3Bucket: my-bucket
    s3Key: microvm/x86-agent.zip
  baseImageArn: "arn:aws:lambda:us-east-1:aws:microvm-image:al2023-1"
  buildRoleArn: "arn:aws:iam::123456789012:role/KubeMicroVMBuildRole"
  architecture: X86_64
```

Build and watch the image as usual:

```bash
kubectl apply -f x86-agent.yaml
microvm image describe x86-agent
```

## ARM64 default and explicit selection

If `spec.architecture` is omitted, KubeMicroVM does not send a CPU
configuration and AWS builds for its default architecture, `ARM_64`.

You can state the existing default explicitly:

```yaml
spec:
  architecture: ARM_64
```

`ARM_64` and `X86_64` are the only accepted values. The validating webhook
rejects other values before the operator calls AWS.

## Change the architecture of an image

Updating `spec.architecture` requests a new MicroVM image version. It does not
modify a snapshot that already exists. Existing MicroVMs continue to run from
the image version selected at their launch. After the new version builds and
is activated, newly launched MicroVMs use the active version.

```bash
kubectl patch microvmimage x86-agent -n default --type=merge \
  -p '{"spec":{"architecture":"ARM_64"}}'
```

Ensure that the source artifact and base image both support the new
architecture before applying this change. If AWS rejects the architecture, the
new image version reports the build failure in `status.latestVersionState` and
`status.latestVersionStateReason`; the previously active version remains
available.

## Architecture is independent of operator packaging

The KubeMicroVM operator, auth-agent, and CLI publish their own container and
binary architectures. Those installation artifacts do not determine the
architecture of a Lambda MicroVM image. A Linux/ARM64 operator pod can build
and manage an `X86_64` MicroVM image, and vice versa.

## See also

- [Memory Sizing](memory-sizing.md)
- [Quick Start](quick-start.md)
- [AWS Lambda MicroVM CPU configuration](https://docs.aws.amazon.com/lambda/latest/microvm-api/API_CpuConfiguration.html)
