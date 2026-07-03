*** Settings ***
Documentation    UAT: RBAC Guide
Resource         ../resources/common.resource
Resource         ../resources/variables.robot
Suite Setup      Create RBAC Resources
Suite Teardown   Cleanup RBAC Resources
Force Tags       rbac

*** Test Cases ***
RBAC-01 ServiceAccount Created
    ${result}=    Run Process    kubectl    get    sa    rbac-app-sa    -n    ${NAMESPACE}
    Should Be Equal As Integers    ${result.rc}    0

RBAC-02 Role With ResourceNames Created
    ${result}=    Run Process    kubectl    get    role    rbac-token-role    -n    ${NAMESPACE}
    Should Be Equal As Integers    ${result.rc}    0

RBAC-03 RoleBinding Created
    ${result}=    Run Process    kubectl    get    rolebinding    rbac-token-binding    -n    ${NAMESPACE}
    Should Be Equal As Integers    ${result.rc}    0

RBAC-04 Auth Can-I With Subresource
    ${result}=    Run Process    kubectl    auth    can-i    create    microvms    --subresource\=token    --as\=system:serviceaccount:${NAMESPACE}:rbac-app-sa    -n    ${NAMESPACE}
    # With resourceNames, can-i returns "no" — this is expected Kubernetes behavior
    Log    can-i result: ${result.stdout} (expected: no with resourceNames)

RBAC-05 Authorized SA Gets Token Via Operator
    [Tags]    smoke
    Wait For VM Running    rbac-vm
    ${endpoint}=    Get MicroVM Endpoint    rbac-vm
    # Create test pod and call operator token endpoint
    Kubectl Apply    apiVersion: v1\nkind: Pod\nmetadata:\n  name: rbac-auth-pod\n  namespace: ${NAMESPACE}\nspec:\n  serviceAccountName: rbac-app-sa\n  containers:\n  - name: curl\n    image: public.ecr.aws/amazonlinux/amazonlinux:2023\n    command: ["sleep", "300"]\n  restartPolicy: Never
    ${result}=    Run Process    kubectl    wait    --for\=condition\=Ready    pod/rbac-auth-pod    -n    ${NAMESPACE}    --timeout\=60s
    ${result}=    Run Process    kubectl    exec    rbac-auth-pod    -n    ${NAMESPACE}    --    bash    -c    SA_TOKEN\=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token); curl -sk -X POST -H "Authorization: Bearer $SA_TOKEN" "https://kube-microvm-operator.${OPERATOR_NS}.svc:443/apis/lambda.aws.amazon.com/v1alpha1/namespaces/${NAMESPACE}/microvms/rbac-vm/token"
    Should Contain    ${result.stdout}    authToken
    Should Contain    ${result.stdout}    endpoint

RBAC-06 Authorized SA Rejected For Different VM
    ${result}=    Run Process    kubectl    exec    rbac-auth-pod    -n    ${NAMESPACE}    --    bash    -c    SA_TOKEN\=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token); curl -sk -w "\\nHTTP_%{http_code}" -X POST -H "Authorization: Bearer $SA_TOKEN" "https://kube-microvm-operator.${OPERATOR_NS}.svc:443/apis/lambda.aws.amazon.com/v1alpha1/namespaces/${NAMESPACE}/microvms/other-vm/token"
    Should Contain    ${result.stdout}    HTTP_403

RBAC-07 Unauthorized SA Rejected
    Kubectl Apply    apiVersion: v1\nkind: ServiceAccount\nmetadata:\n  name: rbac-norole-sa\n  namespace: ${NAMESPACE}\n---\napiVersion: v1\nkind: Pod\nmetadata:\n  name: rbac-norole-pod\n  namespace: ${NAMESPACE}\nspec:\n  serviceAccountName: rbac-norole-sa\n  containers:\n  - name: curl\n    image: public.ecr.aws/amazonlinux/amazonlinux:2023\n    command: ["sleep", "300"]\n  restartPolicy: Never
    Run Process    kubectl    wait    --for\=condition\=Ready    pod/rbac-norole-pod    -n    ${NAMESPACE}    --timeout\=60s
    ${result}=    Run Process    kubectl    exec    rbac-norole-pod    -n    ${NAMESPACE}    --    bash    -c    SA_TOKEN\=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token); curl -sk -w "\\nHTTP_%{http_code}" -X POST -H "Authorization: Bearer $SA_TOKEN" "https://kube-microvm-operator.${OPERATOR_NS}.svc:443/apis/lambda.aws.amazon.com/v1alpha1/namespaces/${NAMESPACE}/microvms/rbac-vm/token"
    Should Contain    ${result.stdout}    HTTP_403

RBAC-08 Unlabelled Namespace Rejects MicroVM
    Run Process    kubectl    create    namespace    rbac-unlabelled    --dry-run\=client    -o    yaml    stdout=${CURDIR}/ns.yaml
    Run Process    kubectl    apply    -f    ${CURDIR}/ns.yaml
    ${output}=    Kubectl Apply Expect Failure    apiVersion: lambda.aws.amazon.com/v1alpha1\nkind: MicroVM\nmetadata:\n  name: should-fail\n  namespace: rbac-unlabelled\nspec:\n  imageRef: rbac-test-app\n  desiredState: Running
    Should Contain    ${output}    is not managed
    [Teardown]    Run Process    kubectl    delete    namespace    rbac-unlabelled    --timeout\=30s

*** Keywords ***
Create RBAC Resources
    Kubectl Apply    apiVersion: lambda.aws.amazon.com/v1alpha1\nkind: MicroVMImage\nmetadata:\n  name: rbac-test-app\n  namespace: ${NAMESPACE}\nspec:\n  source:\n    s3Bucket: ${S3_BUCKET}\n    s3Key: ${S3_KEY}\n  baseImageArn: ${BASE_IMAGE_ARN}\n  buildRoleArn: ${BUILD_ROLE_ARN}
    Kubectl Apply    apiVersion: v1\nkind: ServiceAccount\nmetadata:\n  name: rbac-app-sa\n  namespace: ${NAMESPACE}\n---\napiVersion: rbac.authorization.k8s.io/v1\nkind: Role\nmetadata:\n  name: rbac-token-role\n  namespace: ${NAMESPACE}\nrules:\n- apiGroups: ["lambda.aws.amazon.com"]\n  resources: ["microvms/token"]\n  verbs: ["create"]\n  resourceNames: ["rbac-vm"]\n---\napiVersion: rbac.authorization.k8s.io/v1\nkind: RoleBinding\nmetadata:\n  name: rbac-token-binding\n  namespace: ${NAMESPACE}\nsubjects:\n- kind: ServiceAccount\n  name: rbac-app-sa\n  namespace: ${NAMESPACE}\nroleRef:\n  kind: Role\n  name: rbac-token-role\n  apiGroup: rbac.authorization.k8s.io
    Wait For Image Ready    rbac-test-app
    Kubectl Apply    apiVersion: lambda.aws.amazon.com/v1alpha1\nkind: MicroVM\nmetadata:\n  name: rbac-vm\n  namespace: ${NAMESPACE}\nspec:\n  imageRef: rbac-test-app\n  desiredState: Running\n  maxIdleDurationSeconds: 900\n  suspendedDurationSeconds: 1800

Cleanup RBAC Resources
    Run Keyword And Ignore Error    Run Process    kubectl    delete    pod    rbac-auth-pod    rbac-norole-pod    -n    ${NAMESPACE}    --force    --grace-period\=0    --timeout\=30s
    Run Keyword And Ignore Error    Run Process    kubectl    delete    sa    rbac-app-sa    rbac-norole-sa    -n    ${NAMESPACE}
    Run Keyword And Ignore Error    Run Process    kubectl    delete    role    rbac-token-role    -n    ${NAMESPACE}
    Run Keyword And Ignore Error    Run Process    kubectl    delete    rolebinding    rbac-token-binding    -n    ${NAMESPACE}
    Run Keyword And Ignore Error    Kubectl Delete Force    microvm    rbac-vm
    Run Keyword And Ignore Error    Kubectl Delete Force    microvmimage    rbac-test-app
