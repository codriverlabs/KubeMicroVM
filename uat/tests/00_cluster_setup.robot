*** Settings ***
Documentation    Cluster prerequisite validation — run this first to verify your cluster
...              is ready for UAT. If any test fails, follow the error message to fix.
Resource         ../resources/common.resource
Resource         ../resources/variables.robot
Resource         ../resources/cluster_setup.resource
Force Tags       setup    smoke

*** Test Cases ***
Operator Is Deployed And Running
    [Tags]    critical
    Verify Operator Running

CRDs Are Installed
    [Tags]    critical
    Verify CRDs Installed

Namespace Is Labelled For MicroVMs
    Verify Namespace Labelled

S3 Test Fixtures Are Uploaded
    Verify S3 Fixtures Uploaded

Operator Can Reach AWS API
    [Documentation]    Verifies the operator can call the Lambda MicroVMs API
    ...    by checking operator logs for successful reconciliation (no connection errors).
    ${result}=    Run Process    kubectl    logs    -n    ${OPERATOR_NS}    deploy/kube-microvm-operator    --tail\=5
    Should Not Contain    ${result.stdout}    UnknownHostException
    Should Not Contain    ${result.stdout}    connection timed out
    Should Not Contain    ${result.stdout}    SSLHandshakeException

Webhook Endpoints Are Active
    ${result}=    Run Process    kubectl    get    validatingwebhookconfiguration    kube-microvm-operator-validating
    Should Be Equal As Integers    ${result.rc}    0    Validating webhook not found
    ${result}=    Run Process    kubectl    get    mutatingwebhookconfiguration    kube-microvm-operator-mutating
    Should Be Equal As Integers    ${result.rc}    0    Mutating webhook not found

Pod Identity Association Exists
    [Documentation]    Verifies that EKS Pod Identity is configured for the operator SA.
    ...    The cluster name is resolved from the current kubeconfig context.
    ...    If Pod Identity is missing, run:
    ...    install_kube_microvm.sh --cluster <name> --region <region> --iam
    ${ctx}=    Run Process    kubectl    config    current-context
    # Extract cluster name from ARN (arn:aws:eks:region:account:cluster/NAME) or use as-is
    ${cluster_name}=    Evaluate    '${ctx.stdout}'.split('/')[-1]
    Should Not Be Empty    ${cluster_name}    Could not determine cluster name from kubeconfig context
    ${result}=    Run Process    aws    eks    list-pod-identity-associations
    ...    --cluster-name    ${cluster_name}
    ...    --namespace    ${OPERATOR_NS}
    ...    --service-account    kube-microvm-operator
    ...    --query    associations[0].associationId
    ...    --output    text
    Should Not Be Empty    ${result.stdout}    Pod Identity association missing for kube-microvm-operator SA in ${OPERATOR_NS}\n\nFix: install_kube_microvm.sh --cluster ${cluster_name} --iam
    Should Not Contain    ${result.stdout}    None    Pod Identity association missing for kube-microvm-operator SA\n\nFix: install_kube_microvm.sh --cluster ${cluster_name} --iam
