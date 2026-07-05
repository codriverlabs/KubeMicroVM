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
    Set Suite Variable    ${NAME}    ${NET_IMG}
    Apply Template    networking/net-image.yaml
    Wait For Image Ready    ${NET_IMG}
    # Internet egress VM
    Set Suite Variable    ${NAME}    ${NET_INTERNET}
    Set Suite Variable    ${IMAGE_REF}    ${NET_IMG}
    Apply Template    networking/vm-internet-egress.yaml
    # Default egress VM (no explicit egress connectors)
    Set Suite Variable    ${NAME}    ${NET_DEFAULT}
    Set Suite Variable    ${IMAGE_REF}    ${NET_IMG}
    Apply Template    networking/vm-default-egress.yaml
    # VPC network connector
    Set Suite Variable    ${NAME}    ${NET_VPC_NET}
    Apply Template    networking/microvm-network.yaml
    # VPC egress VM
    Set Suite Variable    ${NAME}    ${NET_VPC_VM}
    Set Suite Variable    ${IMAGE_REF}    ${NET_IMG}
    Set Suite Variable    ${NETWORK_REF}    ${NET_VPC_NET}
    Apply Template    networking/vm-vpc-egress.yaml

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
