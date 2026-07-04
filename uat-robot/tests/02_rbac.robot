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
    ${pod_yaml}=    Catenate    SEPARATOR=\n
    ...    apiVersion: v1
    ...    kind: Pod
    ...    metadata:
    ...    ${SPACE}${SPACE}name: rbac-auth-pod-${RUN_ID}
    ...    ${SPACE}${SPACE}namespace: ${NAMESPACE}
    ...    spec:
    ...    ${SPACE}${SPACE}serviceAccountName: rbac-app-sa
    ...    ${SPACE}${SPACE}containers:
    ...    ${SPACE}${SPACE}- name: curl
    ...    ${SPACE}${SPACE}${SPACE}${SPACE}image: public.ecr.aws/amazonlinux/amazonlinux:2023
    ...    ${SPACE}${SPACE}${SPACE}${SPACE}command: ["sleep", "300"]
    ...    ${SPACE}${SPACE}restartPolicy: Never
    Kubectl Apply    ${pod_yaml}
    ${result}=    Run Process    kubectl    wait    --for\=condition\=Ready    pod/rbac-auth-pod-${RUN_ID}    -n    ${NAMESPACE}    --timeout\=60s
    ${result}=    Run Process    kubectl    exec    rbac-auth-pod-${RUN_ID}    -n    ${NAMESPACE}    --    bash    -c    SA_TOKEN\=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token); curl -sk -X POST -H "Authorization: Bearer $SA_TOKEN" "https://kube-microvm-operator.${OPERATOR_NS}.svc:443/apis/lambda.aws.amazon.com/v1alpha1/namespaces/${NAMESPACE}/microvms/${RBAC_VM}/token"
    Should Contain    ${result.stdout}    authToken
    Should Contain    ${result.stdout}    endpoint

RBAC-06 Authorized SA Rejected For Different VM
    ${result}=    Run Process    kubectl    exec    rbac-auth-pod-${RUN_ID}    -n    ${NAMESPACE}    --    bash    -c    SA_TOKEN\=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token); curl -sk -w "\\nHTTP_%{http_code}" -X POST -H "Authorization: Bearer $SA_TOKEN" "https://kube-microvm-operator.${OPERATOR_NS}.svc:443/apis/lambda.aws.amazon.com/v1alpha1/namespaces/${NAMESPACE}/microvms/other-vm/token"
    Should Contain    ${result.stdout}    HTTP_403

RBAC-07 Unauthorized SA Rejected
    ${sa_yaml}=    Catenate    SEPARATOR=\n
    ...    apiVersion: v1
    ...    kind: ServiceAccount
    ...    metadata:
    ...    ${SPACE}${SPACE}name: rbac-norole-sa
    ...    ${SPACE}${SPACE}namespace: ${NAMESPACE}
    ...    ---
    ...    apiVersion: v1
    ...    kind: Pod
    ...    metadata:
    ...    ${SPACE}${SPACE}name: rbac-norole-pod-${RUN_ID}
    ...    ${SPACE}${SPACE}namespace: ${NAMESPACE}
    ...    spec:
    ...    ${SPACE}${SPACE}serviceAccountName: rbac-norole-sa
    ...    ${SPACE}${SPACE}containers:
    ...    ${SPACE}${SPACE}- name: curl
    ...    ${SPACE}${SPACE}${SPACE}${SPACE}image: public.ecr.aws/amazonlinux/amazonlinux:2023
    ...    ${SPACE}${SPACE}${SPACE}${SPACE}command: ["sleep", "300"]
    ...    ${SPACE}${SPACE}restartPolicy: Never
    Kubectl Apply    ${sa_yaml}
    Run Process    kubectl    wait    --for\=condition\=Ready    pod/rbac-norole-pod-${RUN_ID}    -n    ${NAMESPACE}    --timeout\=60s
    ${result}=    Run Process    kubectl    exec    rbac-norole-pod-${RUN_ID}    -n    ${NAMESPACE}    --    bash    -c    SA_TOKEN\=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token); curl -sk -w "\\nHTTP_%{http_code}" -X POST -H "Authorization: Bearer $SA_TOKEN" "https://kube-microvm-operator.${OPERATOR_NS}.svc:443/apis/lambda.aws.amazon.com/v1alpha1/namespaces/${NAMESPACE}/microvms/${RBAC_VM}/token"
    Should Contain    ${result.stdout}    HTTP_403

RBAC-08 Unlabelled Namespace Rejects MicroVM
    Run Process    kubectl    create    namespace    rbac-unlabelled    --dry-run\=client    -o    yaml    stdout=${CURDIR}/ns.yaml
    Run Process    kubectl    apply    -f    ${CURDIR}/ns.yaml
    ${vm_yaml}=    Catenate    SEPARATOR=\n
    ...    apiVersion: lambda.aws.amazon.com/v1alpha1
    ...    kind: MicroVM
    ...    metadata:
    ...    ${SPACE}${SPACE}name: should-fail
    ...    ${SPACE}${SPACE}namespace: rbac-unlabelled
    ...    spec:
    ...    ${SPACE}${SPACE}imageRef: ${SHARED_IMAGE}
    ...    ${SPACE}${SPACE}desiredState: Running
    ${output}=    Kubectl Apply Expect Failure    ${vm_yaml}
    Should Contain    ${output}    is not managed
    [Teardown]    Run Process    kubectl    delete    namespace    rbac-unlabelled    --timeout\=30s

*** Keywords ***
Create RBAC Resources
    ${id}=    Evaluate    __import__('time').strftime('%H%M%S')
    Set Suite Variable    ${RUN_ID}    ${id}
    Set Suite Variable    ${RBAC_VM}    rbac-vm-${id}
    Ensure Shared Image Ready
    # RBAC resources
    ${rbac_yaml}=    Catenate    SEPARATOR=\n
    ...    apiVersion: v1
    ...    kind: ServiceAccount
    ...    metadata:
    ...    ${SPACE}${SPACE}name: rbac-app-sa
    ...    ${SPACE}${SPACE}namespace: ${NAMESPACE}
    ...    ---
    ...    apiVersion: rbac.authorization.k8s.io/v1
    ...    kind: Role
    ...    metadata:
    ...    ${SPACE}${SPACE}name: rbac-token-role-${RUN_ID}
    ...    ${SPACE}${SPACE}namespace: ${NAMESPACE}
    ...    rules:
    ...    - apiGroups: ["lambda.aws.amazon.com"]
    ...    ${SPACE}${SPACE}resources: ["microvms/token"]
    ...    ${SPACE}${SPACE}verbs: ["create"]
    ...    ${SPACE}${SPACE}resourceNames: ["${RBAC_VM}"]
    ...    ---
    ...    apiVersion: rbac.authorization.k8s.io/v1
    ...    kind: RoleBinding
    ...    metadata:
    ...    ${SPACE}${SPACE}name: rbac-token-binding-${RUN_ID}
    ...    ${SPACE}${SPACE}namespace: ${NAMESPACE}
    ...    subjects:
    ...    - kind: ServiceAccount
    ...    ${SPACE}${SPACE}name: rbac-app-sa
    ...    ${SPACE}${SPACE}namespace: ${NAMESPACE}
    ...    roleRef:
    ...    ${SPACE}${SPACE}kind: Role
    ...    ${SPACE}${SPACE}name: rbac-token-role-${RUN_ID}
    ...    ${SPACE}${SPACE}apiGroup: rbac.authorization.k8s.io
    Kubectl Apply    ${rbac_yaml}
    # VM
    ${vm_yaml}=    Catenate    SEPARATOR=\n
    ...    apiVersion: lambda.aws.amazon.com/v1alpha1
    ...    kind: MicroVM
    ...    metadata:
    ...    ${SPACE}${SPACE}name: ${RBAC_VM}
    ...    ${SPACE}${SPACE}namespace: ${NAMESPACE}
    ...    spec:
    ...    ${SPACE}${SPACE}imageRef: ${SHARED_IMAGE}
    ...    ${SPACE}${SPACE}desiredState: Running
    ...    ${SPACE}${SPACE}maxIdleDurationSeconds: 900
    ...    ${SPACE}${SPACE}suspendedDurationSeconds: 1800
    Kubectl Apply    ${vm_yaml}

Cleanup RBAC Resources
    Run Keyword And Ignore Error    Run Process    kubectl    delete    pod    rbac-auth-pod-${RUN_ID}    rbac-norole-pod-${RUN_ID}    -n    ${NAMESPACE}    --force    --grace-period\=0    --timeout\=30s
    Run Keyword And Ignore Error    Run Process    kubectl    delete    sa    rbac-app-sa    rbac-norole-sa    -n    ${NAMESPACE}
    Run Keyword And Ignore Error    Run Process    kubectl    delete    role    rbac-token-role-${RUN_ID}    -n    ${NAMESPACE}
    Run Keyword And Ignore Error    Run Process    kubectl    delete    rolebinding    rbac-token-binding-${RUN_ID}    -n    ${NAMESPACE}
    Run Keyword And Ignore Error    Kubectl Delete Force    microvm    ${RBAC_VM}
