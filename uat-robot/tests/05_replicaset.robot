*** Settings ***
Documentation    UAT: ReplicaSet Guide
Resource         ../resources/common.resource
Resource         ../resources/variables.robot
Resource         ../resources/cluster_setup.resource
Suite Setup      Run Keywords    Verify Cluster Ready    AND    Create ReplicaSet Resources
Suite Teardown   Cleanup ReplicaSet Resources
Force Tags       replicaset

*** Variables ***
${RS_NAME}      rs-pool-${RUN_ID}
${RUN_ID}       ${EMPTY}

*** Test Cases ***
RS-01 ReplicaSet Creates 3 MicroVMs
    [Tags]    smoke
    Sleep    15s    Wait for reconciler to create children
    ${result}=    Run Process    kubectl    get    microvms    -n    ${NAMESPACE}    --no-headers
    ${lines}=    Get Line Count    ${result.stdout}
    Should Be True    ${lines} >= 3

RS-02 RS List Shows ReplicaSet
    ${result}=    Microvm CLI    rs    list    -n    ${NAMESPACE}
    Should Contain    ${result.stdout}    ${RS_NAME}
    Should Contain    ${result.stdout}    3

RS-03 Scale Up To 5
    Run Process    kubectl    patch    microvmreplicaset    ${RS_NAME}    -n    ${NAMESPACE}    --type\=merge    -p    {"spec":{"replicas":5}}
    Sleep    20s
    ${result}=    Microvm CLI    rs    list    -n    ${NAMESPACE}
    Should Contain    ${result.stdout}    5

RS-04 Scale Down To 2
    Run Process    kubectl    patch    microvmreplicaset    ${RS_NAME}    -n    ${NAMESPACE}    --type\=merge    -p    {"spec":{"replicas":2}}
    Sleep    20s
    ${result}=    Microvm CLI    rs    list    -n    ${NAMESPACE}
    Should Contain    ${result.stdout}    2

RS-06 Delete ReplicaSet Terminates All VMs
    [Tags]    destructive
    Run Process    kubectl    delete    microvmreplicaset    ${RS_NAME}    -n    ${NAMESPACE}    --timeout\=60s
    Sleep    10s
    ${result}=    Run Process    kubectl    get    microvms    -n    ${NAMESPACE}    --no-headers
    Should Be Empty    ${result.stdout.strip()}

*** Keywords ***
Create ReplicaSet Resources
    ${id}=    Evaluate    __import__('time').strftime('%H%M%S')
    Set Suite Variable    ${RUN_ID}    ${id}
    Set Suite Variable    ${RS_NAME}    rs-pool-${id}
    Ensure Shared Image Ready
    ${yaml}=    Catenate    SEPARATOR=\n
    ...    apiVersion: lambda.aws.amazon.com/v1alpha1
    ...    kind: MicroVMReplicaSet
    ...    metadata:
    ...    ${SPACE}${SPACE}name: ${RS_NAME}
    ...    ${SPACE}${SPACE}namespace: ${NAMESPACE}
    ...    spec:
    ...    ${SPACE}${SPACE}replicas: 3
    ...    ${SPACE}${SPACE}template:
    ...    ${SPACE}${SPACE}${SPACE}${SPACE}imageRef: ${SHARED_IMAGE}
    ...    ${SPACE}${SPACE}${SPACE}${SPACE}maxIdleDurationSeconds: 900
    ...    ${SPACE}${SPACE}${SPACE}${SPACE}suspendedDurationSeconds: 1800
    Kubectl Apply    ${yaml}

Cleanup ReplicaSet Resources
    Run Keyword And Ignore Error    Run Process    kubectl    delete    microvmreplicaset    ${RS_NAME}    -n    ${NAMESPACE}    --timeout\=60s
