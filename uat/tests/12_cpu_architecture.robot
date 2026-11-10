*** Settings ***
Documentation    UAT: CPU Architecture Guide
Resource         ../resources/common.resource
Resource         ../resources/variables.robot
Resource         ../resources/cluster_setup.resource
Suite Setup      Run Keywords    Verify Cluster Ready    AND    Create CPU Architecture Resources
Suite Teardown   Cleanup CPU Architecture Resources
Force Tags       cpu-architecture

*** Variables ***
${RUN_ID}       ${EMPTY}
${CPU_IMAGE}    ${EMPTY}
${CPU_VM}       ${EMPTY}
${CPU_INVALID}  ${EMPTY}

*** Test Cases ***
CPU-01 X86_64 Image Builds Successfully
    [Tags]    smoke
    [Documentation]    Builds an image with spec.architecture set to X86_64.
    Wait For Image Ready    ${CPU_IMAGE}
    ${state}=    Kubectl Get JsonPath    microvmimage    ${CPU_IMAGE}    {.status.imageState}
    Should Be Equal    ${state}    CREATED

CPU-02 Invalid Architecture Is Rejected
    [Documentation]    Admission must reject values other than ARM_64 and X86_64.
    Set Suite Variable    ${NAME}    ${CPU_INVALID}
    ${output}=    Apply Template Expect Failure    cpu-architecture/image-invalid-architecture.yaml
    Should Contain    ${output}    spec.architecture must be one of

CPU-03 X86_64 Image Runs A MicroVM And Serves Its Endpoint
    [Tags]    smoke    m80-endpoint-auth
    [Documentation]    Verifies a MicroVM built from an X86_64 image reaches Running,
    ...    returns a direct auth token, and serves the fixture health endpoint.
    Set Suite Variable    ${NAME}    ${CPU_VM}
    Set Suite Variable    ${IMAGE_REF}    ${CPU_IMAGE}
    Set Suite Variable    ${MAX_IDLE}    900
    Set Suite Variable    ${SUSPENDED_DURATION}    1800
    Apply Template    shared/microvm.yaml
    Wait For VM Running    ${CPU_VM}
    ${endpoint}=    Get MicroVM Endpoint    ${CPU_VM}
    ${token}=    Get MicroVM Token    ${CPU_VM}
    ${response}=    Call MicroVM Endpoint    ${endpoint}    ${token}
    Should Contain    ${response}    "status":"ok"

CPU-04 Changing Architecture Builds A New Image Version
    [Documentation]    Changing spec.architecture to ARM_64 requests an updated image version.
    ${previous_version}=    Kubectl Get JsonPath    microvmimage    ${CPU_IMAGE}    {.status.latestVersion}
    ${result}=    Run Process    kubectl    patch    microvmimage    ${CPU_IMAGE}    -n    ${NAMESPACE}    --type\=merge    -p    {"spec":{"architecture":"ARM_64"}}    --request-timeout\=10s
    Should Be Equal As Integers    ${result.rc}    0    Architecture update failed: ${result.stderr}
    Wait For Image Ready    ${CPU_IMAGE}
    ${current_version}=    Kubectl Get JsonPath    microvmimage    ${CPU_IMAGE}    {.status.latestVersion}
    Should Not Be Equal    ${current_version}    ${previous_version}

*** Keywords ***
Create CPU Architecture Resources
    ${id}=    Evaluate    __import__('time').strftime('%H%M%S')
    Set Suite Variable    ${RUN_ID}    ${id}
    Set Suite Variable    ${CPU_IMAGE}    cpu-x86-${id}
    Set Suite Variable    ${CPU_VM}    cpu-x86-vm-${id}
    Set Suite Variable    ${CPU_INVALID}    cpu-invalid-${id}
    Set Suite Variable    ${NAME}    ${CPU_IMAGE}
    Apply Template    cpu-architecture/image-x86-64.yaml

Cleanup CPU Architecture Resources
    ${terminate}=    Run Process    kubectl    patch    microvm    ${CPU_VM}    -n    ${NAMESPACE}    --type\=merge    -p    {"spec":{"desiredState":"Terminated"}}    --request-timeout\=10s
    Run Keyword And Ignore Error    Should Be Equal As Integers    ${terminate.rc}    0
    Run Keyword And Ignore Error    Kubectl Delete Force    microvm    ${CPU_VM}
    Run Keyword And Ignore Error    Kubectl Delete Force    microvmimage    ${CPU_IMAGE}
    Run Keyword And Ignore Error    Kubectl Delete Force    microvmimage    ${CPU_INVALID}
