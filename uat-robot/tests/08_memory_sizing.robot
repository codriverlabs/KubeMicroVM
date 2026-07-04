*** Settings ***
Documentation    UAT: Memory Sizing Guide
Resource         ../resources/common.resource
Resource         ../resources/variables.robot
Resource         ../resources/cluster_setup.resource
Suite Setup      Run Keywords    Verify Cluster Ready    AND    Create Memory Resources
Suite Teardown   Cleanup Memory Resources
Force Tags       memory

*** Variables ***
${RUN_ID}       ${EMPTY}
${MEM_4096}     ${EMPTY}
${MEM_DEFAULT}  ${EMPTY}
${MEM_VM}       ${EMPTY}

*** Test Cases ***
MEM-01 Image With 4096 MiB Shows Correct Status
    [Tags]    smoke
    Wait For Image Ready    ${MEM_4096}
    ${memory}=    Kubectl Get JsonPath    microvmimage    ${MEM_4096}    {.status.memorySizeMiB}
    Should Be Equal    ${memory}    4096
    ${profile}=    Kubectl Get JsonPath    microvmimage    ${MEM_4096}    {.status.computeProfile}
    Should Contain    ${profile}    4096 MiB
    Should Contain    ${profile}    2.0 vCPU

MEM-02 Image Without MemorySizeMiB Defaults To 2048
    Wait For Image Ready    ${MEM_DEFAULT}
    ${memory}=    Kubectl Get JsonPath    microvmimage    ${MEM_DEFAULT}    {.status.memorySizeMiB}
    Should Be Equal    ${memory}    2048

MEM-03 Invalid MemorySizeMiB Rejected
    ${invalid_yaml}=    Catenate    SEPARATOR=\n
    ...    apiVersion: lambda.aws.amazon.com/v1alpha1
    ...    kind: MicroVMImage
    ...    metadata:
    ...    ${SPACE}${SPACE}name: mem-invalid-${RUN_ID}
    ...    ${SPACE}${SPACE}namespace: ${NAMESPACE}
    ...    spec:
    ...    ${SPACE}${SPACE}source:
    ...    ${SPACE}${SPACE}${SPACE}${SPACE}s3Bucket: ${S3_BUCKET}
    ...    ${SPACE}${SPACE}${SPACE}${SPACE}s3Key: ${S3_KEY}
    ...    ${SPACE}${SPACE}baseImageArn: ${BASE_IMAGE_ARN}
    ...    ${SPACE}${SPACE}buildRoleArn: ${BUILD_ROLE_ARN}
    ...    ${SPACE}${SPACE}memorySizeMiB: 999
    ${output}=    Kubectl Apply Expect Failure    ${invalid_yaml}
    Should Contain    ${output}    must be one of

MEM-04 MemorySizeMiB Immutable On Update
    ${result}=    Run Process    kubectl    patch    microvmimage    ${MEM_4096}    -n    ${NAMESPACE}    --type\=merge    -p    {"spec":{"memorySizeMiB":8192}}
    Should Not Be Equal As Integers    ${result.rc}    0
    Should Contain    ${result.stderr}${result.stdout}    immutable

MEM-05 CLI Describe Shows Memory
    ${result}=    Microvm CLI    image    describe    ${MEM_4096}    -n    ${NAMESPACE}
    Should Contain    ${result.stdout}    Memory:
    Should Contain    ${result.stdout}    4096 MiB
    Should Contain    ${result.stdout}    Compute:

MEM-07 Run VM From 4096 MiB Image
    [Tags]    smoke
    Wait For Image Ready    ${MEM_4096}
    ${vm_yaml}=    Catenate    SEPARATOR=\n
    ...    apiVersion: lambda.aws.amazon.com/v1alpha1
    ...    kind: MicroVM
    ...    metadata:
    ...    ${SPACE}${SPACE}name: ${MEM_VM}
    ...    ${SPACE}${SPACE}namespace: ${NAMESPACE}
    ...    spec:
    ...    ${SPACE}${SPACE}imageRef: ${MEM_4096}
    ...    ${SPACE}${SPACE}desiredState: Running
    ...    ${SPACE}${SPACE}maxIdleDurationSeconds: 900
    ...    ${SPACE}${SPACE}suspendedDurationSeconds: 1800
    Kubectl Apply    ${vm_yaml}
    Wait For VM Running    ${MEM_VM}
    ${endpoint}=    Get MicroVM Endpoint    ${MEM_VM}
    ${token}=    Get MicroVM Token    ${MEM_VM}
    ${response}=    Call MicroVM Endpoint    ${endpoint}    ${token}
    Should Contain    ${response}    "status":"ok"

*** Keywords ***
Create Memory Resources
    ${id}=    Evaluate    __import__('time').strftime('%H%M%S')
    Set Suite Variable    ${RUN_ID}    ${id}
    Set Suite Variable    ${MEM_4096}    mem-4096-${id}
    Set Suite Variable    ${MEM_DEFAULT}    mem-default-${id}
    Set Suite Variable    ${MEM_VM}    mem-vm-${id}
    # Image with explicit memorySizeMiB: 4096
    ${img_4096_yaml}=    Catenate    SEPARATOR=\n
    ...    apiVersion: lambda.aws.amazon.com/v1alpha1
    ...    kind: MicroVMImage
    ...    metadata:
    ...    ${SPACE}${SPACE}name: ${MEM_4096}
    ...    ${SPACE}${SPACE}namespace: ${NAMESPACE}
    ...    spec:
    ...    ${SPACE}${SPACE}source:
    ...    ${SPACE}${SPACE}${SPACE}${SPACE}s3Bucket: ${S3_BUCKET}
    ...    ${SPACE}${SPACE}${SPACE}${SPACE}s3Key: ${S3_KEY}
    ...    ${SPACE}${SPACE}baseImageArn: ${BASE_IMAGE_ARN}
    ...    ${SPACE}${SPACE}buildRoleArn: ${BUILD_ROLE_ARN}
    ...    ${SPACE}${SPACE}memorySizeMiB: 4096
    Kubectl Apply    ${img_4096_yaml}
    # Image without memorySizeMiB (defaults to 2048)
    ${img_default_yaml}=    Catenate    SEPARATOR=\n
    ...    apiVersion: lambda.aws.amazon.com/v1alpha1
    ...    kind: MicroVMImage
    ...    metadata:
    ...    ${SPACE}${SPACE}name: ${MEM_DEFAULT}
    ...    ${SPACE}${SPACE}namespace: ${NAMESPACE}
    ...    spec:
    ...    ${SPACE}${SPACE}source:
    ...    ${SPACE}${SPACE}${SPACE}${SPACE}s3Bucket: ${S3_BUCKET}
    ...    ${SPACE}${SPACE}${SPACE}${SPACE}s3Key: ${S3_KEY}
    ...    ${SPACE}${SPACE}baseImageArn: ${BASE_IMAGE_ARN}
    ...    ${SPACE}${SPACE}buildRoleArn: ${BUILD_ROLE_ARN}
    Kubectl Apply    ${img_default_yaml}

Cleanup Memory Resources
    Run Keyword And Ignore Error    Kubectl Delete Force    microvm    ${MEM_VM}
    Run Keyword And Ignore Error    Kubectl Delete Force    microvmimage    ${MEM_4096}
    Run Keyword And Ignore Error    Kubectl Delete Force    microvmimage    ${MEM_DEFAULT}
