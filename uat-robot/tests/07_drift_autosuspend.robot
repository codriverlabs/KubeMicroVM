*** Settings ***
Documentation    UAT: Drift Detection & Auto-Suspend Guide
Resource         ../resources/common.resource
Resource         ../resources/variables.robot
Resource         ../resources/cluster_setup.resource
Suite Setup      Run Keywords    Verify Cluster Ready    AND    Create Drift Resources
Suite Teardown   Cleanup Drift Resources
Force Tags       drift

*** Variables ***
${DRIFT_VM}     drift-vm-${RUN_ID}
${RUN_ID}       ${EMPTY}

*** Test Cases ***
DRIFT-01 External Termination Detected
    [Tags]    destructive    smoke
    ${vm_id}=    Kubectl Get JsonPath    microvm    ${DRIFT_VM}    {.status.microVmId}
    Run Process    aws    lambda-microvms    terminate-microvm    --microvm-identifier    ${vm_id}
    Wait For VM State    ${DRIFT_VM}    Pending    timeout=120
    Log    Drift detected — VM transitioned to Pending

DRIFT-02 Operator Re-Creates VM With New ID
    Wait For VM Running    ${DRIFT_VM}    timeout=120
    ${new_id}=    Kubectl Get JsonPath    microvm    ${DRIFT_VM}    {.status.microVmId}
    Log    New VM ID: ${new_id}
    Should Not Be Empty    ${new_id}

AUTO-01 VM Suspends After Idle Duration
    [Tags]    smoke
    Sleep    90s    Wait for 60s idle + reconcile cycle
    ${state}=    Kubectl Get JsonPath    microvm    ${DRIFT_VM}    {.status.state}
    IF    "${state}" != "Suspended"
        Sleep    60s    Extra wait for suspend
        ${state}=    Kubectl Get JsonPath    microvm    ${DRIFT_VM}    {.status.state}
    END
    Should Be Equal    ${state}    Suspended

AUTO-02 Auto-Resume On Traffic
    ${endpoint}=    Get MicroVM Endpoint    ${DRIFT_VM}
    ${token}=    Get MicroVM Token    ${DRIFT_VM}
    ${response}=    Call MicroVM Endpoint    ${endpoint}    ${token}
    Should Contain    ${response}    "status":"ok"
    Sleep    60s    Wait for operator to update status
    ${state}=    Kubectl Get JsonPath    microvm    ${DRIFT_VM}    {.status.state}
    Should Be Equal    ${state}    Running

AUTO-03 Operator Does Not Fight Idle Policy
    ${result}=    Run Process    kubectl    logs    -n    ${OPERATOR_NS}    deploy/kube-microvm-operator    --tail\=30
    ${resume_lines}=    Get Lines Containing String    ${result.stdout}    RESUME
    ${drift_lines}=    Get Lines Containing String    ${resume_lines}    ${DRIFT_VM}
    Should Be Empty    ${drift_lines}    Operator should not issue spurious RESUME calls

*** Keywords ***
Create Drift Resources
    ${id}=    Evaluate    __import__('time').strftime('%H%M%S')
    Set Suite Variable    ${RUN_ID}    ${id}
    Set Suite Variable    ${DRIFT_VM}    drift-vm-${id}
    Ensure Shared Image Ready
    ${yaml}=    Catenate    SEPARATOR=\n
    ...    apiVersion: lambda.aws.amazon.com/v1alpha1
    ...    kind: MicroVM
    ...    metadata:
    ...    ${SPACE}${SPACE}name: ${DRIFT_VM}
    ...    ${SPACE}${SPACE}namespace: ${NAMESPACE}
    ...    spec:
    ...    ${SPACE}${SPACE}imageRef: ${SHARED_IMAGE}
    ...    ${SPACE}${SPACE}desiredState: Running
    ...    ${SPACE}${SPACE}maxIdleDurationSeconds: 60
    ...    ${SPACE}${SPACE}suspendedDurationSeconds: 300
    ...    ${SPACE}${SPACE}autoResumeEnabled: true
    Kubectl Apply    ${yaml}
    Wait For VM Running    ${DRIFT_VM}

Cleanup Drift Resources
    Run Keyword And Ignore Error    Kubectl Delete Force    microvm    ${DRIFT_VM}
