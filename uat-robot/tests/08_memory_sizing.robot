*** Settings ***
Documentation    UAT: Memory Sizing Guide
Resource         ../resources/common.resource
Resource         ../resources/variables.robot
Suite Setup      Create Memory Resources
Suite Teardown   Cleanup Memory Resources
Force Tags       memory

*** Test Cases ***
MEM-01 Image With 4096 MiB Shows Correct Status
    [Tags]    smoke
    Wait For Image Ready    mem-4096
    ${memory}=    Kubectl Get JsonPath    microvmimage    mem-4096    {.status.memorySizeMiB}
    Should Be Equal    ${memory}    4096
    ${profile}=    Kubectl Get JsonPath    microvmimage    mem-4096    {.status.computeProfile}
    Should Contain    ${profile}    4096 MiB
    Should Contain    ${profile}    2.0 vCPU

MEM-02 Image Without MemorySizeMiB Defaults To 2048
    Wait For Image Ready    mem-default
    ${memory}=    Kubectl Get JsonPath    microvmimage    mem-default    {.status.memorySizeMiB}
    Should Be Equal    ${memory}    2048

MEM-03 Invalid MemorySizeMiB Rejected
    ${output}=    Kubectl Apply Expect Failure    apiVersion: lambda.aws.amazon.com/v1alpha1\nkind: MicroVMImage\nmetadata:\n  name: mem-invalid\n  namespace: ${NAMESPACE}\nspec:\n  source:\n    s3Bucket: ${S3_BUCKET}\n    s3Key: ${S3_KEY}\n  baseImageArn: ${BASE_IMAGE_ARN}\n  buildRoleArn: ${BUILD_ROLE_ARN}\n  memorySizeMiB: 999
    Should Contain    ${output}    must be one of

MEM-04 MemorySizeMiB Immutable On Update
    ${result}=    Run Process    kubectl    patch    microvmimage    mem-4096    -n    ${NAMESPACE}    --type\=merge    -p    {"spec":{"memorySizeMiB":8192}}
    Should Not Be Equal As Integers    ${result.rc}    0
    Should Contain    ${result.stderr}${result.stdout}    immutable

MEM-05 CLI Describe Shows Memory
    ${result}=    Microvm CLI    image    describe    mem-4096    -n    ${NAMESPACE}
    Should Contain    ${result.stdout}    Memory:
    Should Contain    ${result.stdout}    4096 MiB
    Should Contain    ${result.stdout}    Compute:

MEM-07 Run VM From 4096 MiB Image
    [Tags]    smoke
    Wait For Image Ready    mem-4096
    Kubectl Apply    apiVersion: lambda.aws.amazon.com/v1alpha1\nkind: MicroVM\nmetadata:\n  name: mem-vm\n  namespace: ${NAMESPACE}\nspec:\n  imageRef: mem-4096\n  desiredState: Running\n  maxIdleDurationSeconds: 900\n  suspendedDurationSeconds: 1800
    Wait For VM Running    mem-vm
    ${endpoint}=    Get MicroVM Endpoint    mem-vm
    ${token}=    Get MicroVM Token    mem-vm
    ${response}=    Call MicroVM Endpoint    ${endpoint}    ${token}
    Should Contain    ${response}    "status":"ok"

*** Keywords ***
Create Memory Resources
    Kubectl Apply    apiVersion: lambda.aws.amazon.com/v1alpha1\nkind: MicroVMImage\nmetadata:\n  name: mem-4096\n  namespace: ${NAMESPACE}\nspec:\n  source:\n    s3Bucket: ${S3_BUCKET}\n    s3Key: ${S3_KEY}\n  baseImageArn: ${BASE_IMAGE_ARN}\n  buildRoleArn: ${BUILD_ROLE_ARN}\n  memorySizeMiB: 4096
    Kubectl Apply    apiVersion: lambda.aws.amazon.com/v1alpha1\nkind: MicroVMImage\nmetadata:\n  name: mem-default\n  namespace: ${NAMESPACE}\nspec:\n  source:\n    s3Bucket: ${S3_BUCKET}\n    s3Key: ${S3_KEY}\n  baseImageArn: ${BASE_IMAGE_ARN}\n  buildRoleArn: ${BUILD_ROLE_ARN}

Cleanup Memory Resources
    Run Keyword And Ignore Error    Kubectl Delete Force    microvm    mem-vm
    Run Keyword And Ignore Error    Kubectl Delete Force    microvmimage    mem-4096
    Run Keyword And Ignore Error    Kubectl Delete Force    microvmimage    mem-default
