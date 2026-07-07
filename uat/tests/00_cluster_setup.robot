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
    ${result}=    Run Process    aws    eks    list-pod-identity-associations
    ...    --cluster-name    ecp-us1
    ...    --namespace    ${OPERATOR_NS}
    ...    --service-account    kube-microvm-operator
    Should Contain    ${result.stdout}    podidentityassociation
