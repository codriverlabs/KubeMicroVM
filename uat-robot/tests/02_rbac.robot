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
    Wait For VM Running    ${RBAC_VM}
    ${endpoint}=    Get MicroVM Endpoint    ${RBAC_VM}
    # Create test pod and call operator token endpoint
    Set Local Variable    ${POD_NAME}    rbac-auth-pod-${RUN_ID}
    Set Local Variable    ${SA_NAME}    rbac-app-sa
    Apply Template    rbac/test-pod.yaml
    ${result}=    Run Process    kubectl    wait    --for\=condition\=Ready    pod/rbac-auth-pod-${RUN_ID}    -n    ${NAMESPACE}    --timeout\=60s
    ${result}=    Run Process    kubectl    exec    rbac-auth-pod-${RUN_ID}    -n    ${NAMESPACE}    --    bash    -c    SA_TOKEN\=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token); curl -sk -X POST -H "Authorization: Bearer $SA_TOKEN" "https://kube-microvm-operator.${OPERATOR_NS}.svc:443/apis/lambda.aws.amazon.com/v1alpha1/namespaces/${NAMESPACE}/microvms/${RBAC_VM}/token"
    Should Contain    ${result.stdout}    authToken
    Should Contain    ${result.stdout}    endpoint

RBAC-06 Authorized SA Rejected For Different VM
    ${result}=    Run Process    kubectl    exec    rbac-auth-pod-${RUN_ID}    -n    ${NAMESPACE}    --    bash    -c    SA_TOKEN\=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token); curl -sk -w "\\nHTTP_%{http_code}" -X POST -H "Authorization: Bearer $SA_TOKEN" "https://kube-microvm-operator.${OPERATOR_NS}.svc:443/apis/lambda.aws.amazon.com/v1alpha1/namespaces/${NAMESPACE}/microvms/other-vm/token"
    Should Contain    ${result.stdout}    HTTP_403

RBAC-07 Unauthorized SA Rejected
    Set Local Variable    ${SA_NAME}    rbac-norole-sa
    Set Local Variable    ${POD_NAME}    rbac-norole-pod-${RUN_ID}
    Apply Template    rbac/norole-sa-pod.yaml
    Run Process    kubectl    wait    --for\=condition\=Ready    pod/rbac-norole-pod-${RUN_ID}    -n    ${NAMESPACE}    --timeout\=60s
    ${result}=    Run Process    kubectl    exec    rbac-norole-pod-${RUN_ID}    -n    ${NAMESPACE}    --    bash    -c    SA_TOKEN\=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token); curl -sk -w "\\nHTTP_%{http_code}" -X POST -H "Authorization: Bearer $SA_TOKEN" "https://kube-microvm-operator.${OPERATOR_NS}.svc:443/apis/lambda.aws.amazon.com/v1alpha1/namespaces/${NAMESPACE}/microvms/${RBAC_VM}/token"
    Should Contain    ${result.stdout}    HTTP_403

RBAC-08 Unlabelled Namespace Rejects MicroVM
    Run Process    kubectl    create    namespace    rbac-unlabelled    --dry-run\=client    -o    yaml    stdout=${CURDIR}/ns.yaml
    Run Process    kubectl    apply    -f    ${CURDIR}/ns.yaml
    Set Local Variable    ${NAME}    should-fail
    Set Local Variable    ${VM_NAMESPACE}    rbac-unlabelled
    Set Local Variable    ${IMAGE_REF}    ${SHARED_IMAGE}
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
    Set Local Variable    ${SA_NAME}    rbac-app-sa
    Set Local Variable    ${ROLE_NAME}    rbac-token-role-${RUN_ID}
    Set Local Variable    ${BINDING_NAME}    rbac-token-binding-${RUN_ID}
    Set Local Variable    ${VM_NAME}    ${RBAC_VM}
    Apply Template    rbac/sa-role-binding.yaml
    # VM
    Set Local Variable    ${NAME}    ${RBAC_VM}
    Set Local Variable    ${IMAGE_REF}    ${SHARED_IMAGE}
    Set Local Variable    ${MAX_IDLE}    900
    Set Local Variable    ${SUSPENDED_DURATION}    1800
    Apply Template    shared/microvm.yaml

Cleanup RBAC Resources
    Run Keyword And Ignore Error    Run Process    kubectl    delete    pod    rbac-auth-pod-${RUN_ID}    rbac-norole-pod-${RUN_ID}    -n    ${NAMESPACE}    --force    --grace-period\=0    --timeout\=30s
    Run Keyword And Ignore Error    Run Process    kubectl    delete    sa    rbac-app-sa    rbac-norole-sa    -n    ${NAMESPACE}
    Run Keyword And Ignore Error    Run Process    kubectl    delete    role    rbac-token-role-${RUN_ID}    -n    ${NAMESPACE}
    Run Keyword And Ignore Error    Run Process    kubectl    delete    rolebinding    rbac-token-binding-${RUN_ID}    -n    ${NAMESPACE}
    Run Keyword And Ignore Error    Kubectl Delete Force    microvm    ${RBAC_VM}
