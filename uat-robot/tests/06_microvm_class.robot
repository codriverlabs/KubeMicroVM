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
    ${vm_yaml}=    Catenate    SEPARATOR=\n
    ...    apiVersion: lambda.aws.amazon.com/v1alpha1
    ...    kind: MicroVM
    ...    metadata:
    ...    ${SPACE}${SPACE}name: bad-class-vm
    ...    ${SPACE}${SPACE}namespace: ${NAMESPACE}
    ...    spec:
    ...    ${SPACE}${SPACE}imageRef: ${SHARED_IMAGE}
    ...    ${SPACE}${SPACE}className: does-not-exist
    ...    ${SPACE}${SPACE}desiredState: Running
    ${output}=    Kubectl Apply Expect Failure    ${vm_yaml}
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
    ${class_yaml}=    Catenate    SEPARATOR=\n
    ...    apiVersion: lambda.aws.amazon.com/v1alpha1
    ...    kind: MicroVMClass
    ...    metadata:
    ...    ${SPACE}${SPACE}name: ${CLASS_NAME}
    ...    ${SPACE}${SPACE}namespace: ${NAMESPACE}
    ...    spec:
    ...    ${SPACE}${SPACE}maxIdleDurationSeconds: 60
    ...    ${SPACE}${SPACE}suspendedDurationSeconds: 300
    ...    ${SPACE}${SPACE}autoResumeEnabled: true
    ...    ${SPACE}${SPACE}maximumDurationSeconds: 3600
    ...    ${SPACE}${SPACE}description: "UAT test class"
    Kubectl Apply    ${class_yaml}
    # VM with class
    ${vm_yaml}=    Catenate    SEPARATOR=\n
    ...    apiVersion: lambda.aws.amazon.com/v1alpha1
    ...    kind: MicroVM
    ...    metadata:
    ...    ${SPACE}${SPACE}name: ${CLASS_VM}
    ...    ${SPACE}${SPACE}namespace: ${NAMESPACE}
    ...    spec:
    ...    ${SPACE}${SPACE}imageRef: ${SHARED_IMAGE}
    ...    ${SPACE}${SPACE}className: ${CLASS_NAME}
    ...    ${SPACE}${SPACE}desiredState: Running
    Kubectl Apply    ${vm_yaml}
    # VM with override
    ${override_yaml}=    Catenate    SEPARATOR=\n
    ...    apiVersion: lambda.aws.amazon.com/v1alpha1
    ...    kind: MicroVM
    ...    metadata:
    ...    ${SPACE}${SPACE}name: ${CLASS_VM_OVERRIDE}
    ...    ${SPACE}${SPACE}namespace: ${NAMESPACE}
    ...    spec:
    ...    ${SPACE}${SPACE}imageRef: ${SHARED_IMAGE}
    ...    ${SPACE}${SPACE}className: ${CLASS_NAME}
    ...    ${SPACE}${SPACE}maxIdleDurationSeconds: 900
    ...    ${SPACE}${SPACE}desiredState: Running
    Kubectl Apply    ${override_yaml}

Cleanup Class Resources
    Run Keyword And Ignore Error    Kubectl Delete Force    microvm    ${CLASS_VM}
    Run Keyword And Ignore Error    Kubectl Delete Force    microvm    ${CLASS_VM_OVERRIDE}
    Run Keyword And Ignore Error    Run Process    kubectl    delete    microvmclass    ${CLASS_NAME}    -n    ${NAMESPACE}    --timeout\=30s
