*** Settings ***
Documentation    UAT: RBAC Guide
Resource         ../resources/common.resource
Resource         ../resources/variables.robot
Resource         ../resources/cluster_setup.resource
Suite Setup      Run Keywords    Verify Cluster Ready    AND    Create RBAC Resources
Suite Teardown   Cleanup RBAC Resources
Force Tags       rbac

*** Variables ***
${RBAC_VM}       rbac-vm-${RUN_ID}
${RUN_ID}        ${EMPTY}

*** Test Cases ***
RBAC-01 ServiceAccount Created
    ${result}=    Run Process    kubectl    get    sa    rbac-app-sa    -n    ${NAMESPACE}
    Should Be Equal As Integers    ${result.rc}    0

RBAC-02 Role With ResourceNames Created
    ${result}=    Run Process    kubectl    get    role    rbac-token-role-${RUN_ID}    -n    ${NAMESPACE}
    Should Be Equal As Integers    ${result.rc}    0

RBAC-03 RoleBinding Created
    ${result}=    Run Process    kubectl    get    rolebinding    rbac-token-binding-${RUN_ID}    -n    ${NAMESPACE}
    Should Be Equal As Integers    ${result.rc}    0

RBAC-04 Auth Can-I With Subresource
    ${result}=    Run Process    kubectl    auth    can-i    create    microvms    --subresource\=token    --as\=system:serviceaccount:${NAMESPACE}:rbac-app-sa    -n    ${NAMESPACE}
    # With resourceNames, can-i returns "no" — this is expected Kubernetes behavior
    Log    can-i result: ${result.stdout} (expected: no with resourceNames)

RBAC-05 Authorized SA Gets Token Via Operator
    [Tags]    smoke
    [Documentation]    Endpoint propagation can lag VM state transitioning to Running —
    ...    use the longer poll window (90s) rather than Get MicroVM Endpoint's 60s default,
    ...    matching the headroom used in 03_networking.robot for the same race.
    Wait For VM Running    ${RBAC_VM}
    ${endpoint}=    Get MicroVM Endpoint    ${RBAC_VM}    timeout=90
    # Create test pod and call operator token endpoint
    Set Suite Variable    ${POD_NAME}    rbac-auth-pod-${RUN_ID}
    Set Suite Variable    ${SA_NAME}    rbac-app-sa
    Apply Template    rbac/test-pod.yaml
    ${result}=    Run Process    kubectl    wait    --for\=condition\=Ready    pod/rbac-auth-pod-${RUN_ID}    -n    ${NAMESPACE}    --timeout\=60s
    ${result}=    Get Token From Pod    rbac-auth-pod-${RUN_ID}    ${RBAC_VM}
    Should Contain    ${result.stdout}    authToken
    Should Contain    ${result.stdout}    endpoint

RBAC-06 Authorized SA Rejected For Different VM
    ${result}=    Get Token From Pod    rbac-auth-pod-${RUN_ID}    other-vm
    Should Contain    ${result.stdout}    not authorized

RBAC-07 Unauthorized SA Rejected
    Set Suite Variable    ${SA_NAME}    rbac-norole-sa
    Set Suite Variable    ${POD_NAME}    rbac-norole-pod-${RUN_ID}
    Apply Template    rbac/norole-sa-pod.yaml
    Run Process    kubectl    wait    --for\=condition\=Ready    pod/rbac-norole-pod-${RUN_ID}    -n    ${NAMESPACE}    --timeout\=60s
    ${result}=    Get Token From Pod    rbac-norole-pod-${RUN_ID}    ${RBAC_VM}
    Should Contain    ${result.stdout}    not authorized

RBAC-08 Unlabelled Namespace Rejects MicroVM
    [Documentation]    Writes the namespace manifest to a temp file, not ${CURDIR}, so this
    ...    suite doesn't leave a stray ns.yaml behind in the test source tree.
    ${ns_file}=    Set Variable    ${TEMPDIR}/rbac-unlabelled-ns.yaml
    Run Process    kubectl    create    namespace    rbac-unlabelled    --dry-run\=client    -o    yaml    stdout=${ns_file}
    Run Process    kubectl    apply    -f    ${ns_file}
    Remove File    ${ns_file}
    Set Suite Variable    ${NAME}    should-fail
    Set Suite Variable    ${VM_NAMESPACE}    rbac-unlabelled
    Set Suite Variable    ${IMAGE_REF}    ${SHARED_IMAGE}
    ${output}=    Apply Template Expect Failure    rbac/vm-unlabelled-ns.yaml
    Should Contain    ${output}    is not managed
    [Teardown]    Run Process    kubectl    delete    namespace    rbac-unlabelled    --timeout\=30s

*** Keywords ***
Create RBAC Resources
    ${id}=    Evaluate    __import__('time').strftime('%H%M%S')
    Set Suite Variable    ${RUN_ID}    ${id}
    Set Suite Variable    ${RBAC_VM}    rbac-vm-${id}
    Ensure Shared Image Ready
    # RBAC resources
    Set Suite Variable    ${SA_NAME}    rbac-app-sa
    Set Suite Variable    ${ROLE_NAME}    rbac-token-role-${RUN_ID}
    Set Suite Variable    ${BINDING_NAME}    rbac-token-binding-${RUN_ID}
    Set Suite Variable    ${VM_NAME}    ${RBAC_VM}
    Apply Template    rbac/sa-role-binding.yaml
    # VM
    Set Suite Variable    ${NAME}    ${RBAC_VM}
    Set Suite Variable    ${IMAGE_REF}    ${SHARED_IMAGE}
    Set Suite Variable    ${MAX_IDLE}    900
    Set Suite Variable    ${SUSPENDED_DURATION}    1800
    Apply Template    shared/microvm.yaml

Cleanup RBAC Resources
    Run Keyword And Ignore Error    Run Process    kubectl    delete    pod    rbac-auth-pod-${RUN_ID}    rbac-norole-pod-${RUN_ID}    -n    ${NAMESPACE}    --force    --grace-period\=0    --timeout\=30s
    Run Keyword And Ignore Error    Run Process    kubectl    delete    sa    rbac-app-sa    rbac-norole-sa    -n    ${NAMESPACE}
    Run Keyword And Ignore Error    Run Process    kubectl    delete    role    rbac-token-role-${RUN_ID}    -n    ${NAMESPACE}
    Run Keyword And Ignore Error    Run Process    kubectl    delete    rolebinding    rbac-token-binding-${RUN_ID}    -n    ${NAMESPACE}
    Run Keyword And Ignore Error    Kubectl Delete Force    microvm    ${RBAC_VM}
