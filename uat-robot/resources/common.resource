*** Settings ***
Library    Process
Library    String
Library    OperatingSystem
Library    Collections

*** Keywords ***
Kubectl Apply
    [Arguments]    ${yaml}
    ${result}=    Run Process    kubectl    apply    -f    -    input=${yaml}    shell=True
    Should Be Equal As Integers    ${result.rc}    0    kubectl apply failed: ${result.stderr}
    RETURN    ${result.stdout}

Kubectl Apply Expect Failure
    [Arguments]    ${yaml}
    ${result}=    Run Process    kubectl    apply    -f    -    input=${yaml}    shell=True
    Should Not Be Equal As Integers    ${result.rc}    0
    RETURN    ${result.stderr}${result.stdout}

Kubectl Get JsonPath
    [Arguments]    ${resource}    ${name}    ${jsonpath}    ${namespace}=${NAMESPACE}
    ${result}=    Run Process    kubectl    get    ${resource}    ${name}    -n    ${namespace}    -o    jsonpath\=${jsonpath}
    RETURN    ${result.stdout}

Kubectl Delete Force
    [Arguments]    ${resource}    ${name}    ${namespace}=${NAMESPACE}
    Run Process    kubectl    patch    ${resource}    ${name}    -n    ${namespace}    --type\=json    -p\=[{"op":"remove","path":"/metadata/finalizers"}]    --request-timeout\=10s
    Run Process    kubectl    delete    ${resource}    ${name}    -n    ${namespace}    --force    --grace-period\=0    --timeout\=30s

Wait For Image Ready
    [Arguments]    ${name}    ${namespace}=${NAMESPACE}    ${timeout}=300
    FOR    ${i}    IN RANGE    ${timeout // 10}
        ${state}=    Kubectl Get JsonPath    microvmimage    ${name}    {.status.imageState}    ${namespace}
        ${vstate}=    Kubectl Get JsonPath    microvmimage    ${name}    {.status.latestVersionState}    ${namespace}
        IF    "${state}" == "CREATED" and "${vstate}" == "SUCCESSFUL"
            RETURN
        END
        Sleep    10s
    END
    Fail    Image ${name} did not reach CREATED/SUCCESSFUL within ${timeout}s

Wait For VM Running
    [Arguments]    ${name}    ${namespace}=${NAMESPACE}    ${timeout}=120
    FOR    ${i}    IN RANGE    ${timeout // 5}
        ${state}=    Kubectl Get JsonPath    microvm    ${name}    {.status.state}    ${namespace}
        IF    "${state}" == "Running"
            RETURN
        END
        Sleep    5s
    END
    Fail    MicroVM ${name} did not reach Running within ${timeout}s

Wait For VM State
    [Arguments]    ${name}    ${expected_state}    ${namespace}=${NAMESPACE}    ${timeout}=180
    FOR    ${i}    IN RANGE    ${timeout // 10}
        ${state}=    Kubectl Get JsonPath    microvm    ${name}    {.status.state}    ${namespace}
        IF    "${state}" == "${expected_state}"
            RETURN
        END
        Sleep    10s
    END
    Fail    MicroVM ${name} did not reach ${expected_state} within ${timeout}s

Get MicroVM Token
    [Arguments]    ${name}    ${namespace}=${NAMESPACE}
    ${result}=    Run Process    microvm    token    --name    ${name}    --direct    -n    ${namespace}
    Should Be Equal As Integers    ${result.rc}    0    Failed to get token: ${result.stderr}
    RETURN    ${result.stdout}

Get MicroVM Endpoint
    [Arguments]    ${name}    ${namespace}=${NAMESPACE}    ${timeout}=60
    FOR    ${i}    IN RANGE    ${timeout // 5}
        ${ep}=    Kubectl Get JsonPath    microvm    ${name}    {.status.endpointUrl}    ${namespace}
        IF    "${ep}" != "PENDING" and "${ep}" != ""
            RETURN    ${ep}
        END
        Sleep    5s
    END
    Fail    Endpoint for ${name} did not resolve within ${timeout}s

Call MicroVM Endpoint
    [Arguments]    ${endpoint}    ${token}    ${path}=/
    ${result}=    Run Process    curl    -sk    -H    X-aws-proxy-auth: ${token}    https://${endpoint}${path}
    Should Be Equal As Integers    ${result.rc}    0    curl failed: ${result.stderr}
    RETURN    ${result.stdout}

Microvm CLI
    [Arguments]    @{args}
    ${result}=    Run Process    microvm    @{args}
    RETURN    ${result}
