*** Settings ***
Documentation    UAT: Networking Guide
Resource         ../resources/common.resource
Resource         ../resources/variables.robot
Suite Setup      Create Networking Resources
Suite Teardown   Cleanup Networking Resources
Force Tags       networking

*** Variables ***
${SUBNET_1}     subnet-0fdc8b729163e12a7
${SUBNET_2}     subnet-0bde13101743f4751
${SG_ID}        sg-01032cc226cb1615d

*** Test Cases ***
NET-01 Internet Egress Connects To Public Internet
    [Tags]    smoke
    Wait For VM Running    net-internet-vm
    ${endpoint}=    Get MicroVM Endpoint    net-internet-vm
    ${token}=    Get MicroVM Token    net-internet-vm
    ${response}=    Call MicroVM Endpoint    ${endpoint}    ${token}    /fetch?url=https://checkip.amazonaws.com/
    Should Contain    ${response}    "status":200

NET-02 Default Egress Has Internet Access
    Wait For VM Running    net-default-vm
    ${endpoint}=    Get MicroVM Endpoint    net-default-vm
    ${token}=    Get MicroVM Token    net-default-vm
    ${response}=    Call MicroVM Endpoint    ${endpoint}    ${token}    /fetch?url=https://checkip.amazonaws.com/
    Should Contain    ${response}    "status":200

NET-03 MicroVMNetwork Becomes Active
    Wait For Network Active    net-vpc-egress

NET-04 VPC Egress VM Connects
    Wait For VM Running    net-vpc-vm
    ${endpoint}=    Get MicroVM Endpoint    net-vpc-vm
    ${token}=    Get MicroVM Token    net-vpc-vm
    ${response}=    Call MicroVM Endpoint    ${endpoint}    ${token}    /fetch?url=https://checkip.amazonaws.com/
    Should Contain    ${response}    "status":200

NET-05 Network List Shows Connector
    ${result}=    Microvm CLI    network    list    -n    ${NAMESPACE}
    Should Contain    ${result.stdout}    net-vpc-egress
    Should Contain    ${result.stdout}    ACTIVE

*** Keywords ***
Create Networking Resources
    Kubectl Apply    apiVersion: lambda.aws.amazon.com/v1alpha1\nkind: MicroVMImage\nmetadata:\n  name: net-test-app\n  namespace: ${NAMESPACE}\nspec:\n  source:\n    s3Bucket: ${S3_BUCKET}\n    s3Key: ${S3_KEY_NET}\n  baseImageArn: ${BASE_IMAGE_ARN}\n  buildRoleArn: ${BUILD_ROLE_ARN}
    Wait For Image Ready    net-test-app
    # Internet egress VM
    Kubectl Apply    apiVersion: lambda.aws.amazon.com/v1alpha1\nkind: MicroVM\nmetadata:\n  name: net-internet-vm\n  namespace: ${NAMESPACE}\nspec:\n  imageRef: net-test-app\n  desiredState: Running\n  maxIdleDurationSeconds: 900\n  suspendedDurationSeconds: 1800\n  ingressNetworkConnectors:\n    - "arn:aws:lambda:${REGION}:aws:network-connector:aws-network-connector:ALL_INGRESS"\n  egressNetworkConnectors:\n    - "arn:aws:lambda:${REGION}:aws:network-connector:aws-network-connector:INTERNET_EGRESS"
    # Default egress VM (no explicit connectors)
    Kubectl Apply    apiVersion: lambda.aws.amazon.com/v1alpha1\nkind: MicroVM\nmetadata:\n  name: net-default-vm\n  namespace: ${NAMESPACE}\nspec:\n  imageRef: net-test-app\n  desiredState: Running\n  maxIdleDurationSeconds: 900\n  suspendedDurationSeconds: 1800\n  ingressNetworkConnectors:\n    - "arn:aws:lambda:${REGION}:aws:network-connector:aws-network-connector:ALL_INGRESS"
    # VPC network connector
    Kubectl Apply    apiVersion: lambda.aws.amazon.com/v1alpha1\nkind: MicroVMNetwork\nmetadata:\n  name: net-vpc-egress\n  namespace: ${NAMESPACE}\nspec:\n  subnetIds:\n    - ${SUBNET_1}\n    - ${SUBNET_2}\n  securityGroupIds:\n    - ${SG_ID}\n  operatorRoleArn: ${OPERATOR_ROLE}
    # VPC egress VM
    Kubectl Apply    apiVersion: lambda.aws.amazon.com/v1alpha1\nkind: MicroVM\nmetadata:\n  name: net-vpc-vm\n  namespace: ${NAMESPACE}\nspec:\n  imageRef: net-test-app\n  desiredState: Running\n  maxIdleDurationSeconds: 900\n  suspendedDurationSeconds: 1800\n  networkRef: net-vpc-egress\n  ingressNetworkConnectors:\n    - "arn:aws:lambda:${REGION}:aws:network-connector:aws-network-connector:ALL_INGRESS"

Wait For Network Active
    [Arguments]    ${name}    ${namespace}=${NAMESPACE}    ${timeout}=300
    FOR    ${i}    IN RANGE    ${timeout // 10}
        ${state}=    Kubectl Get JsonPath    microvmnetwork    ${name}    {.status.connectorState}    ${namespace}
        IF    "${state}" == "ACTIVE"
            RETURN
        END
        Sleep    10s
    END
    Fail    MicroVMNetwork ${name} did not reach ACTIVE within ${timeout}s

Cleanup Networking Resources
    Run Keyword And Ignore Error    Kubectl Delete Force    microvm    net-internet-vm
    Run Keyword And Ignore Error    Kubectl Delete Force    microvm    net-default-vm
    Run Keyword And Ignore Error    Kubectl Delete Force    microvm    net-vpc-vm
    Run Keyword And Ignore Error    Kubectl Delete Force    microvmnetwork    net-vpc-egress
    Run Keyword And Ignore Error    Kubectl Delete Force    microvmimage    net-test-app
