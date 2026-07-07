*** Settings ***
Documentation    UAT: MicroVMClass Guide
Resource         ../resources/common.resource
Resource         ../resources/variables.robot
Resource         ../resources/cluster_setup.resource
Suite Setup      Run Keywords    Verify Cluster Ready    AND    Create Class Resources
Suite Teardown   Cleanup Class Resources
Force Tags       class

*** Variables ***
${CLASS_VM}            class-vm-${RUN_ID}
${CLASS_VM_OVERRIDE}   class-vm-ovr-${RUN_ID}
${CLASS_NAME}          uat-class-${RUN_ID}
${RUN_ID}              ${EMPTY}

*** Test Cases ***
CLASS-01 MicroVMClass Created
    [Tags]    smoke
    ${result}=    Run Process    kubectl    get    microvmclass    ${CLASS_NAME}    -n    ${NAMESPACE}
    Should Be Equal As Integers    ${result.rc}    0

CLASS-02 VM Inherits Class Values
    Wait For VM Running    ${CLASS_VM}
    ${idle}=    Kubectl Get JsonPath    microvm    ${CLASS_VM}    {.spec.maxIdleDurationSeconds}
    Should Be Equal    ${idle}    60

CLASS-03 Spec Shows All Inherited Values
    ${auto}=    Kubectl Get JsonPath    microvm    ${CLASS_VM}    {.spec.autoResumeEnabled}
    Should Be Equal    ${auto}    true
    ${suspended}=    Kubectl Get JsonPath    microvm    ${CLASS_VM}    {.spec.suspendedDurationSeconds}
    Should Be Equal    ${suspended}    300
    ${max}=    Kubectl Get JsonPath    microvm    ${CLASS_VM}    {.spec.maximumDurationSeconds}
    Should Be Equal    ${max}    3600

CLASS-04 User Override Takes Precedence
    Wait For VM Running    ${CLASS_VM_OVERRIDE}
    ${idle}=    Kubectl Get JsonPath    microvm    ${CLASS_VM_OVERRIDE}    {.spec.maxIdleDurationSeconds}
    Should Be Equal    ${idle}    900

CLASS-05 Kubectl Get Lists Class
    ${result}=    Run Process    kubectl    get    microvmclasses    -n    ${NAMESPACE}
    Should Contain    ${result.stdout}    ${CLASS_NAME}

CLASS-06 Non-Existent Class Rejected
    Set Suite Variable    ${NAME}    bad-class-vm
    Set Suite Variable    ${IMAGE_REF}    ${SHARED_IMAGE}
    Set Suite Variable    ${CLASS_NAME}    does-not-exist
    ${output}=    Apply Template Expect Failure    microvm-class/vm-bad-class.yaml
    Should Contain    ${output}    not found

*** Keywords ***
Create Class Resources
    ${id}=    Evaluate    __import__('time').strftime('%H%M%S')
    Set Suite Variable    ${RUN_ID}    ${id}
    Set Suite Variable    ${CLASS_VM}    class-vm-${id}
    Set Suite Variable    ${CLASS_VM_OVERRIDE}    class-vm-ovr-${id}
    Set Suite Variable    ${CLASS_NAME}    uat-class-${id}
    Ensure Shared Image Ready
    # Class
    Set Suite Variable    ${NAME}    ${CLASS_NAME}
    Set Suite Variable    ${MAX_IDLE}    60
    Set Suite Variable    ${SUSPENDED_DURATION}    300
    Set Suite Variable    ${AUTO_RESUME}    true
    Set Suite Variable    ${MAX_DURATION}    3600
    Set Suite Variable    ${DESCRIPTION}    UAT test class
    Apply Template    microvm-class/class.yaml
    # VM with class
    Set Suite Variable    ${NAME}    ${CLASS_VM}
    Set Suite Variable    ${IMAGE_REF}    ${SHARED_IMAGE}
    Set Suite Variable    ${CLASS_NAME}    ${CLASS_NAME}
    Apply Template    microvm-class/vm-with-class.yaml
    # VM with override
    Set Suite Variable    ${NAME}    ${CLASS_VM_OVERRIDE}
    Set Suite Variable    ${IMAGE_REF}    ${SHARED_IMAGE}
    Set Suite Variable    ${CLASS_NAME}    ${CLASS_NAME}
    Set Suite Variable    ${MAX_IDLE}    900
    Apply Template    microvm-class/vm-with-class-override.yaml

Cleanup Class Resources
    Run Keyword And Ignore Error    Kubectl Delete Force    microvm    ${CLASS_VM}
    Run Keyword And Ignore Error    Kubectl Delete Force    microvm    ${CLASS_VM_OVERRIDE}
    Run Keyword And Ignore Error    Run Process    kubectl    delete    microvmclass    ${CLASS_NAME}    -n    ${NAMESPACE}    --timeout\=30s
