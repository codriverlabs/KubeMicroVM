*** Settings ***
Documentation    UAT: Drift Detection & Auto-Suspend Guide
Resource         ../resources/common.resource
Resource         ../resources/variables.robot
Resource         ../resources/cluster_setup.resource
Suite Setup      Run Keywords    Verify Cluster Ready    AND    Create Drift Resources
Suite Teardown   Cleanup Drift Resources
Force Tags       drift

*** Test Cases ***
DRIFT-01 External Termination Detected
    [Tags]    destructive    smoke
    ${vm_id}=    Kubectl Get JsonPath    microvm    drift-vm    {.status.microVmId}
    Run Process    aws    lambda-microvms    terminate-microvm    --microvm-identifier    ${vm_id}
    Wait For VM State    drift-vm    Pending    timeout=120
    Log    Drift detected — VM transitioned to Pending

DRIFT-02 Operator Re-Creates VM With New ID
    Wait For VM Running    drift-vm    timeout=120
    ${new_id}=    Kubectl Get JsonPath    microvm    drift-vm    {.status.microVmId}
    Log    New VM ID: ${new_id}
    Should Not Be Empty    ${new_id}

AUTO-01 VM Suspends After Idle Duration
    [Tags]    smoke
    Sleep    90s    Wait for 60s idle + reconcile cycle
    ${state}=    Kubectl Get JsonPath    microvm    drift-vm    {.status.state}
    IF    "${state}" != "Suspended"
        Sleep    60s    Extra wait for suspend
        ${state}=    Kubectl Get JsonPath    microvm    drift-vm    {.status.state}
    END
    Should Be Equal    ${state}    Suspended

AUTO-02 Auto-Resume On Traffic
    ${endpoint}=    Get MicroVM Endpoint    drift-vm
    ${token}=    Get MicroVM Token    drift-vm
    ${response}=    Call MicroVM Endpoint    ${endpoint}    ${token}
    Should Contain    ${response}    "status":"ok"
    Sleep    60s    Wait for operator to update status
    ${state}=    Kubectl Get JsonPath    microvm    drift-vm    {.status.state}
    Should Be Equal    ${state}    Running

AUTO-03 Operator Does Not Fight Idle Policy
    ${result}=    Run Process    kubectl    logs    -n    ${OPERATOR_NS}    deploy/kube-microvm-operator    --tail\=30
    ${resume_lines}=    Get Lines Containing String    ${result.stdout}    RESUME
    ${drift_lines}=    Get Lines Containing String    ${resume_lines}    drift-vm
    Should Be Empty    ${drift_lines}    Operator should not issue spurious RESUME calls

*** Keywords ***
Create Drift Resources
    Kubectl Apply    apiVersion: lambda.aws.amazon.com/v1alpha1\nkind: MicroVMImage\nmetadata:\n  name: drift-app\n  namespace: ${NAMESPACE}\nspec:\n  source:\n    s3Bucket: ${S3_BUCKET}\n    s3Key: ${S3_KEY}\n  baseImageArn: ${BASE_IMAGE_ARN}\n  buildRoleArn: ${BUILD_ROLE_ARN}
    Wait For Image Ready    drift-app
    Kubectl Apply    apiVersion: lambda.aws.amazon.com/v1alpha1\nkind: MicroVM\nmetadata:\n  name: drift-vm\n  namespace: ${NAMESPACE}\nspec:\n  imageRef: drift-app\n  desiredState: Running\n  maxIdleDurationSeconds: 60\n  suspendedDurationSeconds: 300\n  autoResumeEnabled: true
    Wait For VM Running    drift-vm

Cleanup Drift Resources
    Run Keyword And Ignore Error    Kubectl Delete Force    microvm    drift-vm
    Run Keyword And Ignore Error    Kubectl Delete Force    microvmimage    drift-app
