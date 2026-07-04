*** Settings ***
Documentation    UAT: Pod Token Injection Guide
Resource         ../resources/common.resource
Resource         ../resources/variables.robot
Resource         ../resources/cluster_setup.resource
Suite Setup      Run Keywords    Verify Cluster Ready    AND    Create Injection Resources
Suite Teardown   Cleanup Injection Resources
Force Tags       injection

*** Variables ***
${INJ_VM}       inject-vm-${RUN_ID}
${RUN_ID}       ${EMPTY}

*** Test Cases ***
INJ-01 Namespace Has Injection Label
    ${result}=    Run Process    kubectl    get    namespace    ${NAMESPACE}    -o    jsonpath\={.metadata.labels.lambda\\.microvm\\.auth/inject}
    Should Be Equal    ${result.stdout}    enabled

INJ-02 SA And RBAC Created
    ${result}=    Run Process    kubectl    get    sa    inject-sa-${RUN_ID}    -n    ${NAMESPACE}
    Should Be Equal As Integers    ${result.rc}    0

INJ-03 Annotated Pod Created
    ${result}=    Run Process    kubectl    get    pod    inject-pod-${RUN_ID}    -n    ${NAMESPACE}
    Should Be Equal As Integers    ${result.rc}    0

INJ-04 Sidecar Container Injected
    [Tags]    smoke
    ${containers}=    Kubectl Get JsonPath    pod    inject-pod-${RUN_ID}    {.spec.containers[*].name}
    Should Contain    ${containers}    app
    Should Contain    ${containers}    microvm-auth-agent

INJ-05 Token Volume Present
    ${volumes}=    Kubectl Get JsonPath    pod    inject-pod-${RUN_ID}    {.spec.volumes[*].name}
    Should Contain    ${volumes}    microvm-token

INJ-06 Token Files Written
    Sleep    30s    Wait for agent to fetch token
    ${result}=    Run Process    kubectl    exec    inject-pod-${RUN_ID}    -c    app    -n    ${NAMESPACE}    --    ls    /var/run/microvm/
    Should Contain    ${result.stdout}    auth-token
    Should Contain    ${result.stdout}    endpoint
    Should Contain    ${result.stdout}    expires-at

INJ-07 Auth Token Non-Empty
    ${result}=    Run Process    kubectl    exec    inject-pod-${RUN_ID}    -c    app    -n    ${NAMESPACE}    --    cat    /var/run/microvm/auth-token
    Should Not Be Empty    ${result.stdout}
    Length Should Be Greater Than    ${result.stdout}    100

INJ-08 Token Works To Call MicroVM
    [Tags]    smoke
    ${token}=    Run Process    kubectl    exec    inject-pod-${RUN_ID}    -c    app    -n    ${NAMESPACE}    --    cat    /var/run/microvm/auth-token
    ${endpoint}=    Get MicroVM Endpoint    ${INJ_VM}
    ${response}=    Call MicroVM Endpoint    ${endpoint}    ${token.stdout}
    Should Contain    ${response}    "status":"ok"

INJ-09 No RBAC Pod Has Empty Token Directory
    Sleep    20s    Wait for no-RBAC agent to attempt
    ${result}=    Run Process    kubectl    exec    inject-norole-pod-${RUN_ID}    -c    app    -n    ${NAMESPACE}    --    ls    /var/run/microvm/
    Should Be Empty    ${result.stdout.strip()}

*** Keywords ***
Create Injection Resources
    ${id}=    Evaluate    __import__('time').strftime('%H%M%S')
    Set Suite Variable    ${RUN_ID}    ${id}
    Set Suite Variable    ${INJ_VM}    inject-vm-${id}
    Ensure Shared Image Ready
    # VM
    ${vm_yaml}=    Catenate    SEPARATOR=\n
    ...    apiVersion: lambda.aws.amazon.com/v1alpha1
    ...    kind: MicroVM
    ...    metadata:
    ...    ${SPACE}${SPACE}name: ${INJ_VM}
    ...    ${SPACE}${SPACE}namespace: ${NAMESPACE}
    ...    spec:
    ...    ${SPACE}${SPACE}imageRef: ${SHARED_IMAGE}
    ...    ${SPACE}${SPACE}desiredState: Running
    ...    ${SPACE}${SPACE}maxIdleDurationSeconds: 900
    ...    ${SPACE}${SPACE}suspendedDurationSeconds: 1800
    Kubectl Apply    ${vm_yaml}
    Wait For VM Running    ${INJ_VM}
    # RBAC
    ${rbac_yaml}=    Catenate    SEPARATOR=\n
    ...    apiVersion: v1
    ...    kind: ServiceAccount
    ...    metadata:
    ...    ${SPACE}${SPACE}name: inject-sa-${RUN_ID}
    ...    ${SPACE}${SPACE}namespace: ${NAMESPACE}
    ...    ---
    ...    apiVersion: rbac.authorization.k8s.io/v1
    ...    kind: Role
    ...    metadata:
    ...    ${SPACE}${SPACE}name: inject-role-${RUN_ID}
    ...    ${SPACE}${SPACE}namespace: ${NAMESPACE}
    ...    rules:
    ...    - apiGroups: ["lambda.aws.amazon.com"]
    ...    ${SPACE}${SPACE}resources: ["microvms/token"]
    ...    ${SPACE}${SPACE}verbs: ["create"]
    ...    ${SPACE}${SPACE}resourceNames: ["${INJ_VM}"]
    ...    ---
    ...    apiVersion: rbac.authorization.k8s.io/v1
    ...    kind: RoleBinding
    ...    metadata:
    ...    ${SPACE}${SPACE}name: inject-binding-${RUN_ID}
    ...    ${SPACE}${SPACE}namespace: ${NAMESPACE}
    ...    subjects:
    ...    - kind: ServiceAccount
    ...    ${SPACE}${SPACE}name: inject-sa-${RUN_ID}
    ...    ${SPACE}${SPACE}namespace: ${NAMESPACE}
    ...    roleRef:
    ...    ${SPACE}${SPACE}kind: Role
    ...    ${SPACE}${SPACE}name: inject-role-${RUN_ID}
    ...    ${SPACE}${SPACE}apiGroup: rbac.authorization.k8s.io
    Kubectl Apply    ${rbac_yaml}
    # Annotated pod (authorized)
    ${pod_yaml}=    Catenate    SEPARATOR=\n
    ...    apiVersion: v1
    ...    kind: Pod
    ...    metadata:
    ...    ${SPACE}${SPACE}name: inject-pod-${RUN_ID}
    ...    ${SPACE}${SPACE}namespace: ${NAMESPACE}
    ...    ${SPACE}${SPACE}annotations:
    ...    ${SPACE}${SPACE}${SPACE}${SPACE}lambda.microvm.auth: ${INJ_VM}
    ...    spec:
    ...    ${SPACE}${SPACE}serviceAccountName: inject-sa-${RUN_ID}
    ...    ${SPACE}${SPACE}containers:
    ...    ${SPACE}${SPACE}- name: app
    ...    ${SPACE}${SPACE}${SPACE}${SPACE}image: public.ecr.aws/amazonlinux/amazonlinux:2023
    ...    ${SPACE}${SPACE}${SPACE}${SPACE}command: ["sleep", "3600"]
    ...    ${SPACE}${SPACE}restartPolicy: Never
    Kubectl Apply    ${pod_yaml}
    # No-RBAC pod
    ${norole_yaml}=    Catenate    SEPARATOR=\n
    ...    apiVersion: v1
    ...    kind: ServiceAccount
    ...    metadata:
    ...    ${SPACE}${SPACE}name: inject-norole-sa-${RUN_ID}
    ...    ${SPACE}${SPACE}namespace: ${NAMESPACE}
    ...    ---
    ...    apiVersion: v1
    ...    kind: Pod
    ...    metadata:
    ...    ${SPACE}${SPACE}name: inject-norole-pod-${RUN_ID}
    ...    ${SPACE}${SPACE}namespace: ${NAMESPACE}
    ...    ${SPACE}${SPACE}annotations:
    ...    ${SPACE}${SPACE}${SPACE}${SPACE}lambda.microvm.auth: ${INJ_VM}
    ...    spec:
    ...    ${SPACE}${SPACE}serviceAccountName: inject-norole-sa-${RUN_ID}
    ...    ${SPACE}${SPACE}containers:
    ...    ${SPACE}${SPACE}- name: app
    ...    ${SPACE}${SPACE}${SPACE}${SPACE}image: public.ecr.aws/amazonlinux/amazonlinux:2023
    ...    ${SPACE}${SPACE}${SPACE}${SPACE}command: ["sleep", "3600"]
    ...    ${SPACE}${SPACE}restartPolicy: Never
    Kubectl Apply    ${norole_yaml}
    Run Process    kubectl    wait    --for\=condition\=Ready    pod/inject-pod-${RUN_ID}    pod/inject-norole-pod-${RUN_ID}    -n    ${NAMESPACE}    --timeout\=90s

Cleanup Injection Resources
    Run Keyword And Ignore Error    Run Process    kubectl    delete    pod    inject-pod-${RUN_ID}    inject-norole-pod-${RUN_ID}    -n    ${NAMESPACE}    --force    --grace-period\=0    --timeout\=30s
    Run Keyword And Ignore Error    Run Process    kubectl    delete    sa    inject-sa-${RUN_ID}    inject-norole-sa-${RUN_ID}    -n    ${NAMESPACE}
    Run Keyword And Ignore Error    Run Process    kubectl    delete    role    inject-role-${RUN_ID}    -n    ${NAMESPACE}
    Run Keyword And Ignore Error    Run Process    kubectl    delete    rolebinding    inject-binding-${RUN_ID}    -n    ${NAMESPACE}
    Run Keyword And Ignore Error    Kubectl Delete Force    microvm    ${INJ_VM}

Length Should Be Greater Than
    [Arguments]    ${string}    ${min_length}
    ${length}=    Get Length    ${string}
    Should Be True    ${length} > ${min_length}
