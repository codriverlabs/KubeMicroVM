*** Settings ***
Documentation    UAT: ReplicaSet Guide
Resource         ../resources/common.resource
Resource         ../resources/variables.robot
Suite Setup      Create ReplicaSet Resources
Suite Teardown   Cleanup ReplicaSet Resources
Force Tags       replicaset

*** Test Cases ***
RS-01 ReplicaSet Creates 3 MicroVMs
    [Tags]    smoke
    Sleep    15s    Wait for reconciler to create children
    ${result}=    Run Process    kubectl    get    microvms    -n    ${NAMESPACE}    --no-headers
    ${lines}=    Get Line Count    ${result.stdout}
    Should Be True    ${lines} >= 3

RS-02 RS List Shows ReplicaSet
    ${result}=    Microvm CLI    rs    list    -n    ${NAMESPACE}
    Should Contain    ${result.stdout}    rs-pool
    Should Contain    ${result.stdout}    3

RS-03 Scale Up To 5
    Run Process    kubectl    patch    microvmreplicaset    rs-pool    -n    ${NAMESPACE}    --type\=merge    -p    {"spec":{"replicas":5}}
    Sleep    20s
    ${result}=    Microvm CLI    rs    list    -n    ${NAMESPACE}
    Should Contain    ${result.stdout}    5

RS-04 Scale Down To 2
    Run Process    kubectl    patch    microvmreplicaset    rs-pool    -n    ${NAMESPACE}    --type\=merge    -p    {"spec":{"replicas":2}}
    Sleep    20s
    ${result}=    Microvm CLI    rs    list    -n    ${NAMESPACE}
    Should Contain    ${result.stdout}    2

RS-06 Delete ReplicaSet Terminates All VMs
    [Tags]    destructive
    Run Process    kubectl    delete    microvmreplicaset    rs-pool    -n    ${NAMESPACE}    --timeout\=60s
    Sleep    10s
    ${result}=    Run Process    kubectl    get    microvms    -n    ${NAMESPACE}    --no-headers
    Should Be Empty    ${result.stdout.strip()}

*** Keywords ***
Create ReplicaSet Resources
    Kubectl Apply    apiVersion: lambda.aws.amazon.com/v1alpha1\nkind: MicroVMImage\nmetadata:\n  name: rs-app\n  namespace: ${NAMESPACE}\nspec:\n  source:\n    s3Bucket: ${S3_BUCKET}\n    s3Key: ${S3_KEY}\n  baseImageArn: ${BASE_IMAGE_ARN}\n  buildRoleArn: ${BUILD_ROLE_ARN}
    Wait For Image Ready    rs-app
    Kubectl Apply    apiVersion: lambda.aws.amazon.com/v1alpha1\nkind: MicroVMReplicaSet\nmetadata:\n  name: rs-pool\n  namespace: ${NAMESPACE}\nspec:\n  replicas: 3\n  template:\n    imageRef: rs-app\n    maxIdleDurationSeconds: 900\n    suspendedDurationSeconds: 1800

Cleanup ReplicaSet Resources
    Run Keyword And Ignore Error    Run Process    kubectl    delete    microvmreplicaset    rs-pool    -n    ${NAMESPACE}    --timeout\=60s
    Run Keyword And Ignore Error    Kubectl Delete Force    microvmimage    rs-app
