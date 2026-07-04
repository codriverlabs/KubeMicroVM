*** Settings ***
Documentation    UAT: Quick Start Guide
Resource         ../resources/common.resource
Resource         ../resources/variables.robot
Resource         ../resources/cluster_setup.resource
Suite Setup      Run Keywords    Verify Cluster Ready    AND    Create Quick Start Resources
Suite Teardown   Cleanup Quick Start Resources
Force Tags       quick-start

*** Variables ***
${QS_IMAGE}    qs-img-${RUN_ID}
${QS_VM}       qs-vm-${RUN_ID}
${RUN_ID}      ${EMPTY}

*** Test Cases ***
QS-00 Installer Download And Checksum Verification
    [Documentation]    Validates Step 1: download installer from release + verify SHA256
    [Tags]    smoke
    ${dl}=    Run Process    curl    -fsSL    https://github.com/plasticity-of-cloud/KubeMicroVM/releases/latest/download/install_kube_microvm.sh    -o    /tmp/install_kube_microvm.sh
    Should Be Equal As Integers    ${dl.rc}    0    Failed to download installer script
    ${sha}=    Run Process    curl    -fsSL    https://github.com/plasticity-of-cloud/KubeMicroVM/releases/latest/download/install_kube_microvm.sh.sha256    -o    /tmp/install_kube_microvm.sh.sha256
    Should Be Equal As Integers    ${sha.rc}    0    Failed to download checksum
    ${verify}=    Run Process    sha256sum    -c    /tmp/install_kube_microvm.sh.sha256    cwd=/tmp
    Should Be Equal As Integers    ${verify.rc}    0    Checksum verification failed: ${verify.stdout}

QS-01 Operator Running
    [Tags]    smoke
    ${result}=    Run Process    kubectl    get    pods    -n    ${OPERATOR_NS}    -l    app.kubernetes.io/name\=kube-microvm-operator    -o    jsonpath\={.items[0].status.phase}
    Should Be Equal    ${result.stdout}    Running

QS-02 Namespace Labelled For MicroVMs
    ${result}=    Run Process    kubectl    get    namespace    ${NAMESPACE}    -o    jsonpath\={.metadata.labels.lambda\\.aws\\.amazon\\.com/manage-microvms}
    Should Be Equal    ${result.stdout}    true

QS-03 MicroVMImage Created And Built
    Wait For Image Ready    ${QS_IMAGE}

QS-04 MicroVM Created And Running
    Create MicroVM    ${QS_VM}    ${QS_IMAGE}
    Wait For VM Running    ${QS_VM}

QS-05 MicroVM List Shows VM
    ${result}=    Microvm CLI    list    -n    ${NAMESPACE}
    Should Contain    ${result.stdout}    ${QS_VM}
    Should Contain    ${result.stdout}    Running

QS-06 Token Via Direct Flag
    ${token}=    Get MicroVM Token    ${QS_VM}
    Should Not Be Empty    ${token}
    ${length}=    Get Length    ${token}
    Should Be True    ${length} > 100

QS-07 Curl Endpoint Returns OK
    [Tags]    smoke
    ${endpoint}=    Get MicroVM Endpoint    ${QS_VM}
    ${token}=    Get MicroVM Token    ${QS_VM}
    ${response}=    Call MicroVM Endpoint    ${endpoint}    ${token}
    Should Contain    ${response}    "status":"ok"

QS-08 Teardown Delete VM And Image
    [Documentation]    Follows the guide's teardown: terminate → delete VM → delete image
    # Terminate (as documented in guide)
    ${result}=    Run Process    kubectl    patch    microvm    ${QS_VM}    -n    ${NAMESPACE}    --type\=merge    -p    {"spec":{"desiredState":"Terminated"}}
    Should Be Equal As Integers    ${result.rc}    0
    Sleep    10s    Wait for termination
    # Delete VM
    ${result}=    Run Process    kubectl    delete    microvm    ${QS_VM}    -n    ${NAMESPACE}    --timeout\=60s
    Should Be Equal As Integers    ${result.rc}    0
    # Delete image
    ${result}=    Run Process    kubectl    delete    microvmimage    ${QS_IMAGE}    -n    ${NAMESPACE}    --timeout\=60s
    Should Be Equal As Integers    ${result.rc}    0

*** Keywords ***
Create Quick Start Resources
    ${id}=    Evaluate    __import__('time').strftime('%H%M%S')
    Set Suite Variable    ${RUN_ID}    ${id}
    Set Suite Variable    ${QS_IMAGE}    qs-img-${id}
    Set Suite Variable    ${QS_VM}    qs-vm-${id}
    Create MicroVM Image    ${QS_IMAGE}

Create MicroVM Image
    [Arguments]    ${name}
    ${yaml}=    Catenate    SEPARATOR=\n
    ...    apiVersion: lambda.aws.amazon.com/v1alpha1
    ...    kind: MicroVMImage
    ...    metadata:
    ...    ${SPACE}${SPACE}name: ${name}
    ...    ${SPACE}${SPACE}namespace: ${NAMESPACE}
    ...    spec:
    ...    ${SPACE}${SPACE}source:
    ...    ${SPACE}${SPACE}${SPACE}${SPACE}s3Bucket: ${S3_BUCKET}
    ...    ${SPACE}${SPACE}${SPACE}${SPACE}s3Key: ${S3_KEY}
    ...    ${SPACE}${SPACE}baseImageArn: "${BASE_IMAGE_ARN}"
    ...    ${SPACE}${SPACE}buildRoleArn: "${BUILD_ROLE_ARN}"
    Kubectl Apply    ${yaml}

Create MicroVM
    [Arguments]    ${name}    ${image_ref}
    ${yaml}=    Catenate    SEPARATOR=\n
    ...    apiVersion: lambda.aws.amazon.com/v1alpha1
    ...    kind: MicroVM
    ...    metadata:
    ...    ${SPACE}${SPACE}name: ${name}
    ...    ${SPACE}${SPACE}namespace: ${NAMESPACE}
    ...    spec:
    ...    ${SPACE}${SPACE}imageRef: ${image_ref}
    ...    ${SPACE}${SPACE}desiredState: Running
    ...    ${SPACE}${SPACE}maxIdleDurationSeconds: 900
    ...    ${SPACE}${SPACE}suspendedDurationSeconds: 1800
    Kubectl Apply    ${yaml}

Cleanup Quick Start Resources
    Run Keyword And Ignore Error    Kubectl Delete Force    microvm    ${QS_VM}
    Run Keyword And Ignore Error    Kubectl Delete Force    microvmimage    ${QS_IMAGE}
