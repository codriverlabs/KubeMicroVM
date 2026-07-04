*** Settings ***
Documentation    UAT: Pod Token Injection Guide
Resource         ../resources/common.resource
Resource         ../resources/variables.robot
Resource         ../resources/cluster_setup.resource
Suite Setup      Run Keywords    Verify Cluster Ready    AND    Create Injection Resources
Suite Teardown   Cleanup Injection Resources
Force Tags       injection

*** Test Cases ***
INJ-01 Namespace Has Injection Label
    ${result}=    Run Process    kubectl    get    namespace    ${NAMESPACE}    -o    jsonpath\={.metadata.labels.lambda\\.microvm\\.auth/inject}
    Should Be Equal    ${result.stdout}    enabled

INJ-02 SA And RBAC Created
    ${result}=    Run Process    kubectl    get    sa    inject-sa    -n    ${NAMESPACE}
    Should Be Equal As Integers    ${result.rc}    0

INJ-03 Annotated Pod Created
    ${result}=    Run Process    kubectl    get    pod    inject-pod    -n    ${NAMESPACE}
    Should Be Equal As Integers    ${result.rc}    0

INJ-04 Sidecar Container Injected
    [Tags]    smoke
    ${containers}=    Kubectl Get JsonPath    pod    inject-pod    {.spec.containers[*].name}
    Should Contain    ${containers}    app
    Should Contain    ${containers}    microvm-auth-agent

INJ-05 Token Volume Present
    ${volumes}=    Kubectl Get JsonPath    pod    inject-pod    {.spec.volumes[*].name}
    Should Contain    ${volumes}    microvm-token

INJ-06 Token Files Written
    Sleep    30s    Wait for agent to fetch token
    ${result}=    Run Process    kubectl    exec    inject-pod    -c    app    -n    ${NAMESPACE}    --    ls    /var/run/microvm/
    Should Contain    ${result.stdout}    auth-token
    Should Contain    ${result.stdout}    endpoint
    Should Contain    ${result.stdout}    expires-at

INJ-07 Auth Token Non-Empty
    ${result}=    Run Process    kubectl    exec    inject-pod    -c    app    -n    ${NAMESPACE}    --    cat    /var/run/microvm/auth-token
    Should Not Be Empty    ${result.stdout}
    Length Should Be Greater Than    ${result.stdout}    100

INJ-08 Token Works To Call MicroVM
    [Tags]    smoke
    ${token}=    Run Process    kubectl    exec    inject-pod    -c    app    -n    ${NAMESPACE}    --    cat    /var/run/microvm/auth-token
    ${endpoint}=    Get MicroVM Endpoint    inject-vm
    ${response}=    Call MicroVM Endpoint    ${endpoint}    ${token.stdout}
    Should Contain    ${response}    "status":"ok"

INJ-09 No RBAC Pod Has Empty Token Directory
    Sleep    20s    Wait for no-RBAC agent to attempt
    ${result}=    Run Process    kubectl    exec    inject-norole-pod    -c    app    -n    ${NAMESPACE}    --    ls    /var/run/microvm/
    Should Be Empty    ${result.stdout.strip()}

*** Keywords ***
Create Injection Resources
    # Image + VM
    Kubectl Apply    apiVersion: lambda.aws.amazon.com/v1alpha1\nkind: MicroVMImage\nmetadata:\n  name: inject-app\n  namespace: ${NAMESPACE}\nspec:\n  source:\n    s3Bucket: ${S3_BUCKET}\n    s3Key: ${S3_KEY}\n  baseImageArn: ${BASE_IMAGE_ARN}\n  buildRoleArn: ${BUILD_ROLE_ARN}
    Wait For Image Ready    inject-app
    Kubectl Apply    apiVersion: lambda.aws.amazon.com/v1alpha1\nkind: MicroVM\nmetadata:\n  name: inject-vm\n  namespace: ${NAMESPACE}\nspec:\n  imageRef: inject-app\n  desiredState: Running\n  maxIdleDurationSeconds: 900\n  suspendedDurationSeconds: 1800
    Wait For VM Running    inject-vm
    # RBAC
    Kubectl Apply    apiVersion: v1\nkind: ServiceAccount\nmetadata:\n  name: inject-sa\n  namespace: ${NAMESPACE}\n---\napiVersion: rbac.authorization.k8s.io/v1\nkind: Role\nmetadata:\n  name: inject-role\n  namespace: ${NAMESPACE}\nrules:\n- apiGroups: ["lambda.aws.amazon.com"]\n  resources: ["microvms/token"]\n  verbs: ["create"]\n  resourceNames: ["inject-vm"]\n---\napiVersion: rbac.authorization.k8s.io/v1\nkind: RoleBinding\nmetadata:\n  name: inject-binding\n  namespace: ${NAMESPACE}\nsubjects:\n- kind: ServiceAccount\n  name: inject-sa\n  namespace: ${NAMESPACE}\nroleRef:\n  kind: Role\n  name: inject-role\n  apiGroup: rbac.authorization.k8s.io
    # Annotated pod (authorized)
    Kubectl Apply    apiVersion: v1\nkind: Pod\nmetadata:\n  name: inject-pod\n  namespace: ${NAMESPACE}\n  annotations:\n    lambda.microvm.auth: inject-vm\nspec:\n  serviceAccountName: inject-sa\n  containers:\n  - name: app\n    image: public.ecr.aws/amazonlinux/amazonlinux:2023\n    command: ["sleep", "3600"]\n  restartPolicy: Never
    # No-RBAC pod
    Kubectl Apply    apiVersion: v1\nkind: ServiceAccount\nmetadata:\n  name: inject-norole-sa\n  namespace: ${NAMESPACE}\n---\napiVersion: v1\nkind: Pod\nmetadata:\n  name: inject-norole-pod\n  namespace: ${NAMESPACE}\n  annotations:\n    lambda.microvm.auth: inject-vm\nspec:\n  serviceAccountName: inject-norole-sa\n  containers:\n  - name: app\n    image: public.ecr.aws/amazonlinux/amazonlinux:2023\n    command: ["sleep", "3600"]\n  restartPolicy: Never
    Run Process    kubectl    wait    --for\=condition\=Ready    pod/inject-pod    pod/inject-norole-pod    -n    ${NAMESPACE}    --timeout\=90s

Cleanup Injection Resources
    Run Keyword And Ignore Error    Run Process    kubectl    delete    pod    inject-pod    inject-norole-pod    -n    ${NAMESPACE}    --force    --grace-period\=0    --timeout\=30s
    Run Keyword And Ignore Error    Run Process    kubectl    delete    sa    inject-sa    inject-norole-sa    -n    ${NAMESPACE}
    Run Keyword And Ignore Error    Run Process    kubectl    delete    role    inject-role    -n    ${NAMESPACE}
    Run Keyword And Ignore Error    Run Process    kubectl    delete    rolebinding    inject-binding    -n    ${NAMESPACE}
    Run Keyword And Ignore Error    Kubectl Delete Force    microvm    inject-vm
    Run Keyword And Ignore Error    Kubectl Delete Force    microvmimage    inject-app

Length Should Be Greater Than
    [Arguments]    ${string}    ${min_length}
    ${length}=    Get Length    ${string}
    Should Be True    ${length} > ${min_length}
