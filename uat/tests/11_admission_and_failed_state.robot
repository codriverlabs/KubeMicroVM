*** Settings ***
Documentation    UAT: Admission Validation & Failed State Behaviour
...
...    Validates two bug fixes on a live cluster:
...    - #59: Webhook rejects MicroVMs with missing/invalid idle policy at admission time
...    - #58: A permanently refused creation stays in Failed (no infinite retry loop)
...
...    Run: robot --outputdir results -i admission tests/11_admission_and_failed_state.robot
Resource         ../resources/common.resource
Resource         ../resources/variables.robot
Resource         ../resources/cluster_setup.resource
Suite Setup      Run Keywords    Verify Cluster Ready    AND    Setup Admission Tests
Suite Teardown   Cleanup Admission Tests
Force Tags       admission

*** Variables ***
${ADM_RUN_ID}        ${EMPTY}

*** Test Cases ***
# ─── Issue #59: Webhook rejects invalid idle policy ─────────────────────────

ADM-01 Missing Idle Policy Without ClassName Is Rejected
    [Documentation]    A MicroVM with no className and no maxIdleDurationSeconds/suspendedDurationSeconds
    ...    must be rejected at admission time with a clear error message.
    ...    Verifies fix for issue #59.
    [Tags]    admission    webhook
    Set Suite Variable    ${NAME}    adm-no-idle-${ADM_RUN_ID}
    Set Suite Variable    ${IMAGE_REF}    ${SHARED_IMAGE}
    ${output}=    Apply Template Expect Failure    admission/vm-no-idle-policy.yaml
    Should Contain    ${output}    maxIdleDurationSeconds
    Should Contain    ${output}    suspendedDurationSeconds

ADM-02 Idle Duration Below Minimum Is Rejected
    [Documentation]    maxIdleDurationSeconds must be >= 60 (AWS minimum).
    ...    A value of 30 should be rejected at admission.
    [Tags]    admission    webhook
    Set Suite Variable    ${NAME}    adm-low-idle-${ADM_RUN_ID}
    Set Suite Variable    ${IMAGE_REF}    ${SHARED_IMAGE}
    ${output}=    Apply Template Expect Failure    admission/vm-idle-below-minimum.yaml
    Should Contain    ${output}    >= 60

ADM-03 Maximum Duration Above 28800 Is Rejected
    [Documentation]    maximumDurationSeconds must be between 1 and 28800.
    ...    A value of 50000 should be rejected at admission.
    [Tags]    admission    webhook
    Set Suite Variable    ${NAME}    adm-max-dur-${ADM_RUN_ID}
    Set Suite Variable    ${IMAGE_REF}    ${SHARED_IMAGE}
    ${output}=    Apply Template Expect Failure    admission/vm-max-duration-exceeded.yaml
    Should Contain    ${output}    between 1 and 28800

ADM-04 ClassName Bypasses Idle Policy Requirement
    [Documentation]    A MicroVM with a valid className but no inline idle policy
    ...    should be accepted at admission (class provides the defaults).
    [Tags]    admission    webhook
    Set Suite Variable    ${NAME}    adm-test-class
    Apply Template    admission/test-class.yaml
    # Now apply the VM with className — should pass admission
    Set Suite Variable    ${NAME}    adm-class-${ADM_RUN_ID}
    Set Suite Variable    ${IMAGE_REF}    ${SHARED_IMAGE}
    Set Suite Variable    ${CLASS_NAME}    adm-test-class
    Apply Template    admission/vm-with-classname.yaml
    # Verify it was accepted (CR exists)
    ${result}=    Run Process    kubectl    get    microvm    adm-class-${ADM_RUN_ID}    -n    ${NAMESPACE}
    Should Be Equal As Integers    ${result.rc}    0    MicroVM should have been admitted

ADM-05 Valid Idle Policy Is Accepted
    [Documentation]    A MicroVM with valid idle policy (no className) is accepted.
    ...    Verifies we haven't over-restricted admission.
    [Tags]    admission    webhook    smoke
    Set Suite Variable    ${NAME}    adm-valid-${ADM_RUN_ID}
    Set Suite Variable    ${IMAGE_REF}    ${SHARED_IMAGE}
    Set Suite Variable    ${MAX_IDLE}    900
    Set Suite Variable    ${SUSPENDED_DURATION}    1800
    Apply Template    shared/microvm.yaml
    ${result}=    Run Process    kubectl    get    microvm    adm-valid-${ADM_RUN_ID}    -n    ${NAMESPACE}
    Should Be Equal As Integers    ${result.rc}    0    Valid MicroVM should have been admitted

# ─── Issue #58: Failed state doesn't loop ───────────────────────────────────

ADM-06 Failed Creation Stays In Failed State
    [Documentation]    A MicroVM that references a non-existent image will fail at reconcile.
    ...    After failing, it must stay in Failed state and NOT flap back to Pending.
    ...    Verifies fix for issue #58.
    [Tags]    admission    reconciler    critical
    Set Suite Variable    ${NAME}    adm-bad-img-${ADM_RUN_ID}
    Apply Template    admission/vm-bad-image-ref.yaml
    # Wait for it to reach Failed state
    Wait For VM State    adm-bad-img-${ADM_RUN_ID}    Failed    timeout=60
    # Record the state
    ${state1}=    Kubectl Get JsonPath    microvm    adm-bad-img-${ADM_RUN_ID}    {.status.state}
    Should Be Equal    ${state1}    Failed
    # Wait 30 seconds — verify it stays Failed (not flapping to Pending)
    Sleep    30s
    ${state2}=    Kubectl Get JsonPath    microvm    adm-bad-img-${ADM_RUN_ID}    {.status.state}
    Should Be Equal    ${state2}    Failed    msg=State should remain Failed, not flap to Pending (issue #58)
    # Verify the condition has the failure reason
    ${reason}=    Kubectl Get JsonPath    microvm    adm-bad-img-${ADM_RUN_ID}    {.status.conditions[0].reason}
    Should Not Be Empty    ${reason}
    Log    Failed state stable. Reason: ${reason}

ADM-07 Failed Creation Retries After Spec Change
    [Documentation]    After fixing the spec (correcting the imageRef), the reconciler
    ...    detects the generation bump and retries creation.
    ...    Simulates the real user workflow: edit YAML, re-apply.
    [Tags]    admission    reconciler
    # Re-apply the same CR with a valid imageRef (this bumps metadata.generation)
    Set Suite Variable    ${NAME}    adm-bad-img-${ADM_RUN_ID}
    Set Suite Variable    ${IMAGE_REF}    ${SHARED_IMAGE}
    Set Suite Variable    ${MAX_IDLE}    900
    Set Suite Variable    ${SUSPENDED_DURATION}    1800
    Apply Template    shared/microvm.yaml
    # Wait for it to leave Failed state (retry triggered by generation bump)
    FOR    ${i}    IN RANGE    12
        Sleep    10s
        ${state}=    Kubectl Get JsonPath    microvm    adm-bad-img-${ADM_RUN_ID}    {.status.state}
        IF    "${state}" != "Failed"
            Log    State changed to ${state} after spec fix — retry worked
            Exit For Loop
        END
    END
    Should Not Be Equal    ${state}    Failed
    ...    msg=State should have left Failed after spec change (generation bump triggers retry)

*** Keywords ***
Setup Admission Tests
    ${id}=    Evaluate    __import__('time').strftime('%H%M%S')
    Set Suite Variable    ${ADM_RUN_ID}    ${id}
    Ensure Shared Image Ready

Cleanup Admission Tests
    [Documentation]    Remove all admission test resources.
    # Delete MicroVMs
    FOR    ${suffix}    IN    no-idle    low-idle    max-dur    class    valid    bad-img
        ${name}=    Set Variable    adm-${suffix}-${ADM_RUN_ID}
        ${check}=    Run Process    kubectl    get    microvm    ${name}    -n    ${NAMESPACE}
        IF    ${check.rc} == 0
            Kubectl Delete Force    microvm    ${name}
        END
    END
    # Delete MicroVMClass
    Run Process    kubectl    delete    microvmclass    adm-test-class    -n    ${NAMESPACE}    --timeout\=30s
    ...    --ignore-not-found
