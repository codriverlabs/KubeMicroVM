# x86_64 Lambda MicroVM image support

## Motivation

AWS Lambda MicroVMs now support `X86_64` in addition to the existing `ARM_64`
CPU architecture. The target architecture is selected when a MicroVM image is
created or updated. The selected base image version and every prebuilt binary
in the code artifact must support the selected architecture.

KubeMicroVM cannot currently request an architecture: `MicroVMImageSpec` has no
architecture field, and `MicroVMImageClient` does not send `cpuConfigurations`
to AWS. The repository is pinned to AWS SDK for Java `2.57.7`; that SDK's
`Architecture` enum does not include `X86_64`. AWS SDK for Java `2.57.11` does.

## Design

1. Upgrade the AWS SDK BOM and explicitly declared Lambda MicroVM SDK client to
   `2.57.11` as one aligned SDK version.
2. Add an optional `architecture` field to `MicroVMImageSpec`. Accepted values
   are `ARM_64` and `X86_64`. Omission preserves AWS's `ARM_64` default.
3. Add admission validation for the two supported values and expose the field
   in the generated CRD and user documentation.
4. Pass the selected value as
   `cpuConfigurations: [{architecture: <value>}]` for both image creation and
   image updates. AWS supports architecture changes as a new image version.
5. Update the vendored AWS API schema reference and tests to cover default,
   `ARM_64`, and `X86_64` image requests and image updates.
6. Add `--architecture` to `microvm image create` and display each managed base
   image version's `supportedCpuConfigurations` in
   `microvm image base-images --arn`.

## Compatibility and operational behavior

Existing `MicroVMImage` resources omit `architecture`, so their behavior
remains unchanged and they continue to build for `ARM_64`. A user changing an
existing image to `X86_64` triggers a new image version build. The selected
base image version must advertise `X86_64` support through
`ListManagedMicrovmImageVersions`; otherwise AWS rejects the build.

## Testing

- Verify the AWS SDK `Architecture` enum contains both `ARM_64` and `X86_64`.
- Verify create and update requests include the requested CPU configuration.
- Verify omission does not send a CPU configuration and preserves AWS's
  default behavior.
- Run the repository compile, integration-test, and native-build checks before
  pushing code changes.
- Run `uat/tests/12_cpu_architecture.robot` against an EKS cluster using a
  release-candidate chart that contains this feature before marking support as
  production-supported.
