*** Settings ***
Documentation    UAT: MicroVMClass Guide
Resource         ../resources/common.resource
Resource         ../resources/variables.robot
Suite Setup      Create Class Resources
Suite Teardown   Cleanup Class Resources
Force Tags       class

*** Test Cases ***
CLASS-01 MicroVMClass Created
    [Tags]    smoke
    ${result}=    Run Process    kubectl    get    microvmclass    uat-class    -n    ${NAMESPACE}
    Should Be Equal As Integers    ${result.rc}    0

CLASS-02 VM Inherits Class Values
    Wait For VM Running    class-vm
    ${idle}=    Kubectl Get JsonPath    microvm    class-vm    {.spec.maxIdleDurationSeconds}
    Should Be Equal    ${idle}    60

CLASS-03 Spec Shows All Inherited Values
    ${auto}=    Kubectl Get JsonPath    microvm    class-vm    {.spec.autoResumeEnabled}
    Should Be Equal    ${auto}    true
    ${suspended}=    Kubectl Get JsonPath    microvm    class-vm    {.spec.suspendedDurationSeconds}
    Should Be Equal    ${suspended}    300
    ${max}=    Kubectl Get JsonPath    microvm    class-vm    {.spec.maximumDurationSeconds}
    Should Be Equal    ${max}    3600

CLASS-04 User Override Takes Precedence
    Wait For VM Running    class-vm-override
    ${idle}=    Kubectl Get JsonPath    microvm    class-vm-override    {.spec.maxIdleDurationSeconds}
    Should Be Equal    ${idle}    900

CLASS-05 Kubectl Get Lists Class
    ${result}=    Run Process    kubectl    get    microvmclasses    -n    ${NAMESPACE}
    Should Contain    ${result.stdout}    uat-class

CLASS-06 Non-Existent Class Rejected
    ${output}=    Kubectl Apply Expect Failure    apiVersion: lambda.aws.amazon.com/v1alpha1\nkind: MicroVM\nmetadata:\n  name: bad-class-vm\n  namespace: ${NAMESPACE}\nspec:\n  imageRef: class-app\n  className: does-not-exist\n  desiredState: Running
    Should Contain    ${output}    not found

*** Keywords ***
Create Class Resources
    # Image
    Kubectl Apply    apiVersion: lambda.aws.amazon.com/v1alpha1\nkind: MicroVMImage\nmetadata:\n  name: class-app\n  namespace: ${NAMESPACE}\nspec:\n  source:\n    s3Bucket: ${S3_BUCKET}\n    s3Key: ${S3_KEY}\n  baseImageArn: ${BASE_IMAGE_ARN}\n  buildRoleArn: ${BUILD_ROLE_ARN}
    Wait For Image Ready    class-app
    # Class
    Kubectl Apply    apiVersion: lambda.aws.amazon.com/v1alpha1\nkind: MicroVMClass\nmetadata:\n  name: uat-class\n  namespace: ${NAMESPACE}\nspec:\n  maxIdleDurationSeconds: 60\n  suspendedDurationSeconds: 300\n  autoResumeEnabled: true\n  maximumDurationSeconds: 3600\n  description: "UAT test class"
    # VM with class
    Kubectl Apply    apiVersion: lambda.aws.amazon.com/v1alpha1\nkind: MicroVM\nmetadata:\n  name: class-vm\n  namespace: ${NAMESPACE}\nspec:\n  imageRef: class-app\n  className: uat-class\n  desiredState: Running
    # VM with override
    Kubectl Apply    apiVersion: lambda.aws.amazon.com/v1alpha1\nkind: MicroVM\nmetadata:\n  name: class-vm-override\n  namespace: ${NAMESPACE}\nspec:\n  imageRef: class-app\n  className: uat-class\n  maxIdleDurationSeconds: 900\n  desiredState: Running

Cleanup Class Resources
    Run Keyword And Ignore Error    Kubectl Delete Force    microvm    class-vm
    Run Keyword And Ignore Error    Kubectl Delete Force    microvm    class-vm-override
    Run Keyword And Ignore Error    Run Process    kubectl    delete    microvmclass    uat-class    -n    ${NAMESPACE}    --timeout\=30s
    Run Keyword And Ignore Error    Kubectl Delete Force    microvmimage    class-app
