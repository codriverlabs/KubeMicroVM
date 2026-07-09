*** Settings ***
Library    Process
Library    String
Library    OperatingSystem
Library    Collections

*** Variables ***
${TEMPLATES}    ${CURDIR}/../templates

*** Keywords ***
Apply Template
    [Documentation]    Reads a YAML template file, resolves Robot Framework variables, and applies via kubectl.
    ...    Variables must be set via Set Suite Variable or Set Test Variable before calling.
    [Arguments]    ${template_path}
    ${content}=    Get File    ${TEMPLATES}/${template_path}
    ${resolved}=    Replace Variables    ${content}
    Kubectl Apply    ${resolved}

Apply Template Expect Failure
    [Documentation]    Reads a YAML template, resolves variables, applies and expects rejection.
    [Arguments]    ${template_path}
    ${content}=    Get File    ${TEMPLATES}/${template_path}
    ${resolved}=    Replace Variables    ${content}
    ${output}=    Kubectl Apply Expect Failure    ${resolved}
    RETURN    ${output}

Kubectl Apply
    [Arguments]    ${yaml}
    ${tmpfile}=    Set Variable    /tmp/robot-kubectl-apply.yaml
    Create File    ${tmpfile}    ${yaml}
    ${result}=    Run Process    kubectl    apply    -f    ${tmpfile}
    Remove File    ${tmpfile}
    Should Be Equal As Integers    ${result.rc}    0    kubectl apply failed: ${result.stderr}
    RETURN    ${result.stdout}

Kubectl Apply File
    [Arguments]    ${filepath}
    ${result}=    Run Process    kubectl    apply    -f    ${filepath}
    Should Be Equal As Integers    ${result.rc}    0    kubectl apply failed: ${result.stderr}
    RETURN    ${result.stdout}

Kubectl Apply Expect Failure
    [Arguments]    ${yaml}
    ${tmpfile}=    Set Variable    /tmp/robot-kubectl-apply.yaml
    Create File    ${tmpfile}    ${yaml}
    ${result}=    Run Process    kubectl    apply    -f    ${tmpfile}
    Remove File    ${tmpfile}
    Should Not Be Equal As Integers    ${result.rc}    0
    RETURN    ${result.stderr}${result.stdout}

Kubectl Apply File Expect Failure
    [Arguments]    ${filepath}
    ${result}=    Run Process    kubectl    apply    -f    ${filepath}
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
    [Arguments]    ${name}    ${namespace}=${NAMESPACE}    ${timeout}=600
    FOR    ${i}    IN RANGE    ${{int($timeout) // 10}}
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
    FOR    ${i}    IN RANGE    ${{int($timeout) // 5}}
        ${state}=    Kubectl Get JsonPath    microvm    ${name}    {.status.state}    ${namespace}
        IF    "${state}" == "Running"
            RETURN
        END
        Sleep    5s
    END
    Fail    MicroVM ${name} did not reach Running within ${timeout}s

Wait For VM State
    [Arguments]    ${name}    ${expected_state}    ${namespace}=${NAMESPACE}    ${timeout}=180
    FOR    ${i}    IN RANGE    ${{int($timeout) // 10}}
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
    FOR    ${i}    IN RANGE    ${{int($timeout) // 5}}
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

Exec In Pod
    [Documentation]    Execute a bash command inside a pod and return the result.
    [Arguments]    ${pod_name}    ${command}    ${namespace}=${NAMESPACE}
    ${result}=    Run Process    kubectl    exec    ${pod_name}    -n    ${namespace}    --    bash    -c    ${command}
    RETURN    ${result}

Get Token From Pod
    [Documentation]    Call operator token endpoint from inside a pod using its SA token.
    [Arguments]    ${pod_name}    ${vm_name}    ${namespace}=${NAMESPACE}
    ${operator_url}=    Set Variable    https://kube-microvm-operator.${OPERATOR_NS}.svc:443
    ${token_path}=    Set Variable    /apis/lambda.aws.amazon.com/v1alpha1/namespaces/${namespace}/microvms/${vm_name}/token
    ${result}=    Run Process    bash    -c    kubectl exec ${pod_name} -n ${namespace} -- bash -c 'curl -sk -X POST -H "Authorization: Bearer $(cat /var/run/secrets/kubernetes.io/serviceaccount/token)" "${operator_url}${token_path}"'
    RETURN    ${result}
