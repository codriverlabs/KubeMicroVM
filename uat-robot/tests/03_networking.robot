*** Settings ***
Documentation    UAT: Networking Guide
Resource         ../resources/common.resource
Resource         ../resources/variables.robot
Resource         ../resources/cluster_setup.resource
Suite Setup      Run Keywords    Verify Cluster Ready    AND    Create Networking Resources
Suite Teardown   Cleanup Networking Resources
Force Tags       networking

*** Variables ***
${SUBNET_1}     subnet-0fdc8b729163e12a7
${SUBNET_2}     subnet-0bde13101743f4751
${SG_ID}        sg-01032cc226cb1615d
${RUN_ID}       ${EMPTY}
${NET_IMG}      ${EMPTY}
${NET_INTERNET}    ${EMPTY}
${NET_DEFAULT}     ${EMPTY}
${NET_VPC_VM}      ${EMPTY}
${NET_VPC_NET}     ${EMPTY}

*** Test Cases ***
NET-01 Internet Egress Connects To Public Internet
    [Tags]    smoke
    Wait For VM Running    ${NET_INTERNET}
    ${endpoint}=    Get MicroVM Endpoint    ${NET_INTERNET}
    ${token}=    Get MicroVM Token    ${NET_INTERNET}
    ${response}=    Call MicroVM Endpoint    ${endpoint}    ${token}    /fetch?url=https://checkip.amazonaws.com/
    Should Contain    ${response}    "status":200

NET-02 Default Egress Has Internet Access
    Wait For VM Running    ${NET_DEFAULT}
    ${endpoint}=    Get MicroVM Endpoint    ${NET_DEFAULT}
    ${token}=    Get MicroVM Token    ${NET_DEFAULT}
    ${response}=    Call MicroVM Endpoint    ${endpoint}    ${token}    /fetch?url=https://checkip.amazonaws.com/
    Should Contain    ${response}    "status":200

NET-03 MicroVMNetwork Becomes Active
    Wait For Network Active    ${NET_VPC_NET}

NET-04 VPC Egress VM Connects
    Wait For VM Running    ${NET_VPC_VM}
    ${endpoint}=    Get MicroVM Endpoint    ${NET_VPC_VM}
    ${token}=    Get MicroVM Token    ${NET_VPC_VM}
    ${response}=    Call MicroVM Endpoint    ${endpoint}    ${token}    /fetch?url=https://checkip.amazonaws.com/
    Should Contain    ${response}    "status":200

NET-05 Network List Shows Connector
    ${result}=    Microvm CLI    network    list    -n    ${NAMESPACE}
    Should Contain    ${result.stdout}    ${NET_VPC_NET}
    Should Contain    ${result.stdout}    ACTIVE

*** Keywords ***
Create Networking Resources
    ${id}=    Evaluate    __import__('time').strftime('%H%M%S')
    Set Suite Variable    ${RUN_ID}    ${id}
    Set Suite Variable    ${NET_IMG}    net-img-${id}
    Set Suite Variable    ${NET_INTERNET}    net-internet-${id}
    Set Suite Variable    ${NET_DEFAULT}    net-default-${id}
    Set Suite Variable    ${NET_VPC_VM}    net-vpc-${id}
    Set Suite Variable    ${NET_VPC_NET}    net-vpc-${id}
    # Build networking test image (uses net-test app with /fetch endpoint)
    ${img_yaml}=    Catenate    SEPARATOR=\n
    ...    apiVersion: lambda.aws.amazon.com/v1alpha1
    ...    kind: MicroVMImage
    ...    metadata:
    ...    ${SPACE}${SPACE}name: ${NET_IMG}
    ...    ${SPACE}${SPACE}namespace: ${NAMESPACE}
    ...    spec:
    ...    ${SPACE}${SPACE}source:
    ...    ${SPACE}${SPACE}${SPACE}${SPACE}s3Bucket: ${S3_BUCKET}
    ...    ${SPACE}${SPACE}${SPACE}${SPACE}s3Key: ${S3_KEY_NET}
    ...    ${SPACE}${SPACE}baseImageArn: ${BASE_IMAGE_ARN}
    ...    ${SPACE}${SPACE}buildRoleArn: ${BUILD_ROLE_ARN}
    Kubectl Apply    ${img_yaml}
    Wait For Image Ready    ${NET_IMG}
    # Internet egress VM
    ${internet_yaml}=    Catenate    SEPARATOR=\n
    ...    apiVersion: lambda.aws.amazon.com/v1alpha1
    ...    kind: MicroVM
    ...    metadata:
    ...    ${SPACE}${SPACE}name: ${NET_INTERNET}
    ...    ${SPACE}${SPACE}namespace: ${NAMESPACE}
    ...    spec:
    ...    ${SPACE}${SPACE}imageRef: ${NET_IMG}
    ...    ${SPACE}${SPACE}desiredState: Running
    ...    ${SPACE}${SPACE}maxIdleDurationSeconds: 900
    ...    ${SPACE}${SPACE}suspendedDurationSeconds: 1800
    ...    ${SPACE}${SPACE}ingressNetworkConnectors:
    ...    ${SPACE}${SPACE}${SPACE}${SPACE}- "arn:aws:lambda:${REGION}:aws:network-connector:aws-network-connector:ALL_INGRESS"
    ...    ${SPACE}${SPACE}egressNetworkConnectors:
    ...    ${SPACE}${SPACE}${SPACE}${SPACE}- "arn:aws:lambda:${REGION}:aws:network-connector:aws-network-connector:INTERNET_EGRESS"
    Kubectl Apply    ${internet_yaml}
    # Default egress VM (no explicit egress connectors)
    ${default_yaml}=    Catenate    SEPARATOR=\n
    ...    apiVersion: lambda.aws.amazon.com/v1alpha1
    ...    kind: MicroVM
    ...    metadata:
    ...    ${SPACE}${SPACE}name: ${NET_DEFAULT}
    ...    ${SPACE}${SPACE}namespace: ${NAMESPACE}
    ...    spec:
    ...    ${SPACE}${SPACE}imageRef: ${NET_IMG}
    ...    ${SPACE}${SPACE}desiredState: Running
    ...    ${SPACE}${SPACE}maxIdleDurationSeconds: 900
    ...    ${SPACE}${SPACE}suspendedDurationSeconds: 1800
    ...    ${SPACE}${SPACE}ingressNetworkConnectors:
    ...    ${SPACE}${SPACE}${SPACE}${SPACE}- "arn:aws:lambda:${REGION}:aws:network-connector:aws-network-connector:ALL_INGRESS"
    Kubectl Apply    ${default_yaml}
    # VPC network connector
    ${network_yaml}=    Catenate    SEPARATOR=\n
    ...    apiVersion: lambda.aws.amazon.com/v1alpha1
    ...    kind: MicroVMNetwork
    ...    metadata:
    ...    ${SPACE}${SPACE}name: ${NET_VPC_NET}
    ...    ${SPACE}${SPACE}namespace: ${NAMESPACE}
    ...    spec:
    ...    ${SPACE}${SPACE}subnetIds:
    ...    ${SPACE}${SPACE}${SPACE}${SPACE}- ${SUBNET_1}
    ...    ${SPACE}${SPACE}${SPACE}${SPACE}- ${SUBNET_2}
    ...    ${SPACE}${SPACE}securityGroupIds:
    ...    ${SPACE}${SPACE}${SPACE}${SPACE}- ${SG_ID}
    ...    ${SPACE}${SPACE}operatorRoleArn: ${OPERATOR_ROLE}
    Kubectl Apply    ${network_yaml}
    # VPC egress VM
    ${vpc_yaml}=    Catenate    SEPARATOR=\n
    ...    apiVersion: lambda.aws.amazon.com/v1alpha1
    ...    kind: MicroVM
    ...    metadata:
    ...    ${SPACE}${SPACE}name: ${NET_VPC_VM}
    ...    ${SPACE}${SPACE}namespace: ${NAMESPACE}
    ...    spec:
    ...    ${SPACE}${SPACE}imageRef: ${NET_IMG}
    ...    ${SPACE}${SPACE}desiredState: Running
    ...    ${SPACE}${SPACE}maxIdleDurationSeconds: 900
    ...    ${SPACE}${SPACE}suspendedDurationSeconds: 1800
    ...    ${SPACE}${SPACE}networkRef: ${NET_VPC_NET}
    ...    ${SPACE}${SPACE}ingressNetworkConnectors:
    ...    ${SPACE}${SPACE}${SPACE}${SPACE}- "arn:aws:lambda:${REGION}:aws:network-connector:aws-network-connector:ALL_INGRESS"
    Kubectl Apply    ${vpc_yaml}

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
    Run Keyword And Ignore Error    Kubectl Delete Force    microvm    ${NET_INTERNET}
    Run Keyword And Ignore Error    Kubectl Delete Force    microvm    ${NET_DEFAULT}
    Run Keyword And Ignore Error    Kubectl Delete Force    microvm    ${NET_VPC_VM}
    Run Keyword And Ignore Error    Kubectl Delete Force    microvmnetwork    ${NET_VPC_NET}
    Run Keyword And Ignore Error    Kubectl Delete Force    microvmimage    ${NET_IMG}
