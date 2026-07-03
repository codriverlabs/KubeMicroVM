*** Settings ***
Documentation    UAT: Quick Start Guide
Resource         ../resources/common.resource
Resource         ../resources/variables.robot
Suite Setup      Create Quick Start Resources
Suite Teardown   Cleanup Quick Start Resources
Force Tags       quick-start

*** Test Cases ***
QS-01 Operator Running
    [Tags]    smoke
    ${result}=    Run Process    kubectl    get    pods    -n    ${OPERATOR_NS}    -l    app.kubernetes.io/name\=kube-microvm-operator    -o    jsonpath\={.items[0].status.phase}
    Should Be Equal    ${result.stdout}    Running

QS-02 Namespace Labelled For MicroVMs
    ${result}=    Run Process    kubectl    get    namespace    ${NAMESPACE}    -o    jsonpath\={.metadata.labels.lambda\\.aws\\.amazon\\.com/manage-microvms}
    Should Be Equal    ${result.stdout}    true

QS-03 MicroVMImage Created And Built
    Wait For Image Ready    qs-test-app

QS-04 MicroVM Created And Running
    Kubectl Apply    apiVersion: lambda.aws.amazon.com/v1alpha1\nkind: MicroVM\nmetadata:\n  name: qs-test-vm\n  namespace: ${NAMESPACE}\nspec:\n  imageRef: qs-test-app\n  desiredState: Running\n  maxIdleDurationSeconds: 900\n  suspendedDurationSeconds: 1800
    Wait For VM Running    qs-test-vm

QS-05 MicroVM List Shows VM
    ${result}=    Microvm CLI    list    -n    ${NAMESPACE}
    Should Contain    ${result.stdout}    qs-test-vm
    Should Contain    ${result.stdout}    Running

QS-06 Token Via Direct Flag
    ${token}=    Get MicroVM Token    qs-test-vm
    Should Not Be Empty    ${token}
    Length Should Be Greater Than    ${token}    100

QS-07 Curl Endpoint Returns OK
    [Tags]    smoke
    ${endpoint}=    Get MicroVM Endpoint    qs-test-vm
    ${token}=    Get MicroVM Token    qs-test-vm
    ${response}=    Call MicroVM Endpoint    ${endpoint}    ${token}
    Should Contain    ${response}    "status":"ok"

QS-08 Teardown Delete VM And Image
    Kubectl Delete Force    microvm    qs-test-vm
    ${result}=    Run Process    kubectl    get    microvm    qs-test-vm    -n    ${NAMESPACE}
    Should Not Be Equal As Integers    ${result.rc}    0

*** Keywords ***
Create Quick Start Resources
    Kubectl Apply    apiVersion: lambda.aws.amazon.com/v1alpha1\nkind: MicroVMImage\nmetadata:\n  name: qs-test-app\n  namespace: ${NAMESPACE}\nspec:\n  source:\n    s3Bucket: ${S3_BUCKET}\n    s3Key: ${S3_KEY}\n  baseImageArn: ${BASE_IMAGE_ARN}\n  buildRoleArn: ${BUILD_ROLE_ARN}

Cleanup Quick Start Resources
    Run Keyword And Ignore Error    Kubectl Delete Force    microvm    qs-test-vm
    Run Keyword And Ignore Error    Kubectl Delete Force    microvmimage    qs-test-app

Length Should Be Greater Than
    [Arguments]    ${string}    ${min_length}
    ${length}=    Get Length    ${string}
    Should Be True    ${length} > ${min_length}
