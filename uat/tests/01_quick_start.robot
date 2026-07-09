*** Settings ***
Documentation    UAT: Quick Start Guide — prerequisite for all other suites.
...              Builds the shared image used by subsequent guides.
Resource         ../resources/common.resource
Resource         ../resources/variables.robot
Resource         ../resources/cluster_setup.resource
Suite Setup      Run Keywords    Verify Cluster Ready    AND    Create Quick Start Resources
Suite Teardown   Cleanup Quick Start Resources
Force Tags       quick-start

*** Variables ***
${QS_VM}       qs-vm-${RUN_ID}
${RUN_ID}      ${EMPTY}

*** Test Cases ***
QS-00 Installer Download And Checksum Verification
    [Documentation]    Validates Step 1: download installer from release, verify SHA256, confirm executable
    [Tags]    smoke
    ${dl}=    Run Process    curl    -fsSL
    ...    https://github.com/plasticity-of-cloud/KubeMicroVM/releases/latest/download/install_kube_microvm.sh
    ...    -o    /tmp/uat-check-installer.sh
    Should Be Equal As Integers    ${dl.rc}    0    Failed to download installer script
    ${sha}=    Run Process    curl    -fsSL
    ...    https://github.com/plasticity-of-cloud/KubeMicroVM/releases/latest/download/install_kube_microvm.sh.sha256
    ...    -o    /tmp/uat-check-installer-raw.sha256
    Should Be Equal As Integers    ${sha.rc}    0    Failed to download checksum file
    # Normalize sha256 file: replace any leading path with just the filename we downloaded
    ${normalize}=    Run Process    python3    -c
    ...    import re; open('/tmp/uat-check-installer.sha256','w').write(re.sub(r'  .+install_kube_microvm\\.sh', '  uat-check-installer.sh', open('/tmp/uat-check-installer-raw.sha256').read()))
    ${verify}=    Run Process    sha256sum    -c    uat-check-installer.sha256    cwd=/tmp
    Should Be Equal As Integers    ${verify.rc}    0    Checksum verification failed: ${verify.stdout}
    # Confirm script is parseable and shows help
    Run Process    chmod    +x    /tmp/uat-check-installer.sh
    ${help}=    Run Process    /tmp/uat-check-installer.sh    --help
    Should Be Equal As Integers    ${help.rc}    0    Script failed to run --help
    Should Contain    ${help.stdout}    --cluster
    Should Contain    ${help.stdout}    --region

QS-01 Operator Running
    [Tags]    smoke
    ${result}=    Run Process    kubectl    get    pods    -n    ${OPERATOR_NS}    -l    app.kubernetes.io/name\=kube-microvm-operator    -o    jsonpath\={.items[0].status.phase}
    Should Be Equal    ${result.stdout}    Running

QS-02 Namespace Labelled For MicroVMs
    ${result}=    Run Process    kubectl    get    namespace    ${NAMESPACE}    -o    jsonpath\={.metadata.labels.lambda\\.aws\\.amazon\\.com/manage-microvms}
    Should Be Equal    ${result.stdout}    true

QS-03 MicroVMImage Created And Built
    [Documentation]    Builds the shared image used by all subsequent suites
    Wait For Image Ready    ${SHARED_IMAGE}

QS-04 MicroVM Created And Running
    Create MicroVM    ${QS_VM}    ${SHARED_IMAGE}
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

QS-08 Teardown Delete VM
    [Documentation]    Follows the guide's graceful teardown for the VM (image kept for other suites)
    ${result}=    Run Process    kubectl    patch    microvm    ${QS_VM}    -n    ${NAMESPACE}    --type\=merge    -p    {"spec":{"desiredState":"Terminated"}}
    Should Be Equal As Integers    ${result.rc}    0
    Sleep    10s    Wait for termination
    ${result}=    Run Process    kubectl    delete    microvm    ${QS_VM}    -n    ${NAMESPACE}    --timeout\=60s
    Should Be Equal As Integers    ${result.rc}    0

*** Keywords ***
Create Quick Start Resources
    ${id}=    Evaluate    __import__('time').strftime('%H%M%S')
    Set Suite Variable    ${RUN_ID}    ${id}
    Set Suite Variable    ${QS_VM}    qs-vm-${id}
    # Create shared image (idempotent — skips if already built)
    Ensure Shared Image Ready

Create MicroVM
    [Arguments]    ${name}    ${image_ref}
    Set Suite Variable    ${NAME}    ${name}
    Set Suite Variable    ${IMAGE_REF}    ${image_ref}
    Set Suite Variable    ${MAX_IDLE}    900
    Set Suite Variable    ${SUSPENDED_DURATION}    1800
    Apply Template    shared/microvm.yaml

Cleanup Quick Start Resources
    # Only delete the VM — shared image is kept for other suites
    Run Keyword And Ignore Error    Kubectl Delete Force    microvm    ${QS_VM}
