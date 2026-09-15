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

# ─── ARN Collision Prevention (#microvmimage-arn-collision-prevention) ────────

ADM-08 Duplicate Named MicroVMImage Rejected By Webhook
    [Documentation]    Creating a MicroVMImage with the same metadata.name as one that already
    ...    exists in a different namespace must be rejected by the validating webhook with a
    ...    clear error message naming the owning namespace.
    ...
    ...    AWS Lambda MicroVM image ARNs are account+region-global and keyed purely on name.
    ...    Two CRs with the same name in different namespaces silently alias to the same AWS
    ...    resource. The webhook blocks this at creation time (Layer 1).
    ...
    ...    Verifies docs/design/image-arn-collision-prevention.md Layer 1.
    [Tags]    admission    webhook    arn-collision
    # Ensure the shared image exists — don't rely on a prior suite having created it.
    # Ensures Shared Image Ready is idempotent (no-op if image is already Ready).
    Ensure Shared Image Ready
    ${collision_ns}=    Set Variable    adm-collision-${ADM_RUN_ID}
    ${ns_yaml}=    Catenate    SEPARATOR=\n
    ...    apiVersion: v1
    ...    kind: Namespace
    ...    metadata:
    ...    \ \ name: ${collision_ns}
    ...    \ \ labels:
    ...    \ \ \ \ lambda.aws.amazon.com/manage-microvms: "true"
    Kubectl Apply    ${ns_yaml}
    # Wait for namespace to become Active before applying resources into it
    FOR    ${i}    IN RANGE    10
        ${ns_phase}=    Run Process    kubectl    get    namespace    ${collision_ns}    -o    jsonpath\={.status.phase}
        IF    "${ns_phase.stdout}" == "Active"    BREAK
        Sleep    2s
    END
    Set Test Variable    ${ADM_COLLISION_NS}    ${collision_ns}
    Set Test Variable    ${ADM_COLLISION_NAME}    ${SHARED_IMAGE}
    ${output}=    Apply Template Expect Failure    admission/image-arn-collision.yaml
    Should Contain    ${output}    ${NAMESPACE}
    ...    ADM-08: error must name the namespace that owns the colliding image
    Should Contain    ${output}    ${SHARED_IMAGE}
    ...    ADM-08: error must include the image name
    [Teardown]    Run Process    kubectl    delete    namespace    ${collision_ns}    --ignore-not-found    --timeout\=30s

ADM-09 Delete Blocked By Running VMs Emits Warning Event
    [Documentation]    When deleting a MicroVMImage that still has running MicroVMs, the
    ...    reconciler must emit a Kubernetes Warning event with reason 'DeleteBlocked' and set
    ...    a human-readable status message — not loop silently forever (Layer 2).
    ...
    ...    NOTE: This test provisions a real AWS MicroVM. It may take 2–3 minutes.
    ...
    ...    Verifies docs/design/image-arn-collision-prevention.md Layer 2.
    [Tags]    admission    reconciler    arn-collision
    ${img_name}=    Set Variable    adm-del-block-${ADM_RUN_ID}
    ${vm_name}=     Set Variable    adm-del-block-vm-${ADM_RUN_ID}
    ${image_yaml}=    Catenate    SEPARATOR=\n
    ...    apiVersion: lambda.aws.amazon.com/v1alpha1
    ...    kind: MicroVMImage
    ...    metadata:
    ...    \ \ name: ${img_name}
    ...    \ \ namespace: ${NAMESPACE}
    ...    spec:
    ...    \ \ source:
    ...    \ \ \ \ s3Bucket: ${S3_BUCKET}
    ...    \ \ \ \ s3Key: ${S3_KEY}
    ...    \ \ baseImageArn: ${BASE_IMAGE_ARN}
    ...    \ \ buildRoleArn: ${BUILD_ROLE_ARN}
    Kubectl Apply    ${image_yaml}
    Wait For Image Ready    ${img_name}    ${NAMESPACE}    600
    ${vm_yaml}=    Catenate    SEPARATOR=\n
    ...    apiVersion: lambda.aws.amazon.com/v1alpha1
    ...    kind: MicroVM
    ...    metadata:
    ...    \ \ name: ${vm_name}
    ...    \ \ namespace: ${NAMESPACE}
    ...    spec:
    ...    \ \ imageRef: ${img_name}
    ...    \ \ desiredState: Running
    ...    \ \ maxIdleDurationSeconds: 900
    ...    \ \ suspendedDurationSeconds: 1800
    Kubectl Apply    ${vm_yaml}
    Wait For VM State    ${vm_name}    Running    timeout=300
    # Delete the image while the VM is still Running — reconciler must block and emit event
    Run Process    kubectl    delete    microvmimage    ${img_name}    -n    ${NAMESPACE}    --wait\=false    --timeout\=10s
    Sleep    30s    Allow reconciler to detect block and emit event
    ${events}=    Run Process    kubectl    get    events    -n    ${NAMESPACE}
    ...    --field-selector    reason\=DeleteBlocked    -o    jsonpath\={.items[*].message}
    Should Not Be Empty    ${events.stdout}
    ...    ADM-09: expected a DeleteBlocked Warning event on the image
    Should Contain    ${events.stdout}    ${img_name}
    ...    ADM-09: DeleteBlocked event must reference the blocked image
    [Teardown]    Cleanup ADM09    ${vm_name}    ${img_name}

*** Keywords ***
Setup Admission Tests
    ${id}=    Evaluate    __import__('time').strftime('%H%M%S')
    Set Suite Variable    ${ADM_RUN_ID}    ${id}
    Ensure Shared Image Ready

Cleanup ADM09
    [Documentation]    Teardown for ADM-09: terminate the VM then force-remove the blocked image.
    [Arguments]    ${vm_name}    ${img_name}
    Run Process    kubectl    delete    microvm    ${vm_name}    -n    ${NAMESPACE}    --ignore-not-found    --timeout\=60s
    Run Process    kubectl    patch    microvmimage    ${img_name}    -n    ${NAMESPACE}
    ...    --type\=json    -p    [{"op":"remove","path":"/metadata/finalizers"}]    --ignore-not-found
    Run Process    kubectl    delete    microvmimage    ${img_name}    -n    ${NAMESPACE}
    ...    --ignore-not-found    --force    --grace-period\=0

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
    # ADM-09 resources are cleaned up by that test's [Teardown]; belt-and-braces here
    Run Process    kubectl    delete    microvm    adm-del-block-vm-${ADM_RUN_ID}    -n    ${NAMESPACE}
    ...    --ignore-not-found    --timeout\=30s
    Run Process    kubectl    patch    microvmimage    adm-del-block-${ADM_RUN_ID}    -n    ${NAMESPACE}
    ...    --type\=json    -p    [{"op":"remove","path":"/metadata/finalizers"}]    --ignore-not-found
    Run Process    kubectl    delete    microvmimage    adm-del-block-${ADM_RUN_ID}    -n    ${NAMESPACE}
    ...    --ignore-not-found    --force    --grace-period\=0
    # Delete MicroVMClass
    Run Process    kubectl    delete    microvmclass    adm-test-class    -n    ${NAMESPACE}    --timeout\=30s
    ...    --ignore-not-found
    # ADM-08 collision namespace (inline [Teardown] handles it, belt-and-braces)
    Run Process    kubectl    delete    namespace    adm-collision-${ADM_RUN_ID}
    ...    --ignore-not-found    --timeout\=30s
