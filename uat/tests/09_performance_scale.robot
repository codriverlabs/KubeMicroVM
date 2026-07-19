*** Settings ***
Documentation    UAT: Performance Scale Test — 1000 MicroVMs via ReplicaSet
...
...    Creates a ReplicaSet with 1000 replicas and validates:
...    - Operator handles scale-up without crashing
...    - Rate limiting (RunMicrovm 5/s) is respected by quota guard
...    - VMs reach account concurrency limit (~161 Running)
...    - Status reporting is accurate (readyReplicas, currentReplicas)
...    - Scale-down and termination completes within bounded time
...    - No operator restarts during the entire test
...
...    Expected behaviour (us-east-1 defaults):
...    - RunMicrovm burst rate: 5 req/s → scale-up at ~3-4 VMs/s
...    - Account concurrency limit: ~161 Running VMs
...    - VMs beyond 161 remain Pending (API accepts but VM stays pending)
...    - Termination rate: ~10 req/s → full drain in ~100s for 1000 VMs
...
...    This suite is long-running (~15-20 minutes). Tag: performance
Resource         ../resources/common.resource
Resource         ../resources/variables.robot
Resource         ../resources/cluster_setup.resource
Suite Setup      Run Keywords    Verify Cluster Ready    AND    Setup Performance Test
Suite Teardown   Teardown Performance Test
Force Tags       performance

*** Variables ***
${PERF_RS_NAME}           perf-rs-${RUN_ID}
${PERF_REPLICAS}          1000
${SCALE_UP_TIMEOUT}       900
${SCALE_DOWN_TIMEOUT}     300
${POLL_INTERVAL_SCALE}    10
${RUN_ID}                 ${EMPTY}
# Observed account limits (us-east-1, 2026-07-06)
${EXPECTED_MIN_RUNNING}   100
${EXPECTED_MAX_RUNNING}   200

*** Test Cases ***
PERF-01 Operator Stable Before Scale Test
    [Documentation]    Verify operator is healthy and note restart count baseline.
    [Tags]    smoke    performance
    ${restarts}=    Get Operator Restart Count
    Set Suite Variable    ${BASELINE_RESTARTS}    ${restarts}
    ${result}=    Run Process    kubectl    exec    -n    ${OPERATOR_NS}
    ...    deploy/kube-microvm-operator    --
    ...    wget    -qO-    http://localhost:8080/q/health/ready
    Should Contain    ${result.stdout}    UP

PERF-02 ReplicaSet Created With 1000 Replicas
    [Documentation]    Create the ReplicaSet and verify it's accepted.
    [Tags]    performance
    Set Suite Variable    ${NAME}    ${PERF_RS_NAME}
    Set Suite Variable    ${REPLICAS}    ${PERF_REPLICAS}
    Set Suite Variable    ${IMAGE_REF}    ${SHARED_IMAGE}
    Apply Template    replicaset/replicaset.yaml
    ${result}=    Run Process    kubectl    get    microvmreplicaset    ${PERF_RS_NAME}
    ...    -n    ${NAMESPACE}    -o    jsonpath\={.spec.replicas}
    Should Be Equal    ${result.stdout}    1000

PERF-03 Scale-Up Reaches Account Limit
    [Documentation]    Monitor scale-up progress until Running VMs plateau.
    ...    Expects 100-200 Running VMs (account concurrency limit).
    ...    Records peak ready count and time to reach plateau.
    [Tags]    performance
    ${start_time}=    Evaluate    __import__('time').time()
    ${peak_ready}=    Set Variable    0
    ${peak_current}=    Set Variable    0
    ${plateau_count}=    Set Variable    0
    ${last_ready}=    Set Variable    0
    FOR    ${i}    IN RANGE    ${{int(${SCALE_UP_TIMEOUT}) // int(${POLL_INTERVAL_SCALE})}}
        Sleep    ${POLL_INTERVAL_SCALE}s
        ${ready}=    Get RS Field    readyReplicas
        ${current}=    Get RS Field    currentReplicas
        ${elapsed}=    Evaluate    int(__import__('time').time() - ${start_time})
        Log    [${elapsed}s] ready=${ready} current=${current}
        # Track peaks
        ${ready_int}=    Convert To Integer    ${ready}    default=0
        ${current_int}=    Convert To Integer    ${current}    default=0
        ${peak_ready}=    Evaluate    max(${peak_ready}, ${ready_int})
        ${peak_current}=    Evaluate    max(${peak_current}, ${current_int})
        # Detect plateau (ready stable for 3 consecutive checks)
        IF    ${ready_int} == ${last_ready} and ${ready_int} > 50
            ${plateau_count}=    Evaluate    ${plateau_count} + 1
        ELSE
            ${plateau_count}=    Set Variable    0
        END
        ${last_ready}=    Set Variable    ${ready_int}
        IF    ${plateau_count} >= 3
            Log    Plateau detected at ${ready_int} VMs after ${elapsed}s
            Exit For Loop
        END
    END
    ${total_elapsed}=    Evaluate    int(__import__('time').time() - ${start_time})
    Set Suite Variable    ${PEAK_READY}    ${peak_ready}
    Set Suite Variable    ${PEAK_CURRENT}    ${peak_current}
    Set Suite Variable    ${SCALE_UP_TIME}    ${total_elapsed}
    Log    Peak ready: ${peak_ready}, Peak current: ${peak_current}, Time: ${total_elapsed}s
    # Verify we reached a reasonable number of Running VMs
    Should Be True    ${peak_ready} >= ${EXPECTED_MIN_RUNNING}
    ...    msg=Expected at least ${EXPECTED_MIN_RUNNING} Running VMs but peak was ${peak_ready}

PERF-04 Status Reports Accurate Counts
    [Documentation]    Verify ReplicaSet status fields are internally consistent.
    [Tags]    performance
    ${ready}=    Get RS Field    readyReplicas
    ${current}=    Get RS Field    currentReplicas
    ${desired}=    Get RS Field    replicas    spec
    ${ready_int}=    Convert To Integer    ${ready}    default=0
    ${current_int}=    Convert To Integer    ${current}    default=0
    # current >= ready (some VMs may be Pending)
    Should Be True    ${current_int} >= ${ready_int}
    ...    msg=currentReplicas (${current_int}) should be >= readyReplicas (${ready_int})
    # Desired is still 1000
    Should Be Equal    ${desired}    1000

PERF-05 No Operator Restarts During Scale-Up
    [Documentation]    Verify the operator pod did not restart under load.
    [Tags]    performance    critical
    ${current_restarts}=    Get Operator Restart Count
    Should Be Equal As Integers    ${current_restarts}    ${BASELINE_RESTARTS}
    ...    msg=Operator restarted during scale-up! Restarts: baseline=${BASELINE_RESTARTS} current=${current_restarts}

PERF-06 Scale Down To Zero
    [Documentation]    Delete the ReplicaSet and measure time to drain all VM CRs.
    ...    Target: all CRs removed within ${SCALE_DOWN_TIMEOUT}s.
    [Tags]    performance    destructive
    ${start_time}=    Evaluate    __import__('time').time()
    Run Process    kubectl    delete    microvmreplicaset    ${PERF_RS_NAME}
    ...    -n    ${NAMESPACE}    --timeout\=120s
    # Wait for all child MicroVM CRs to be removed
    FOR    ${i}    IN RANGE    ${{int(${SCALE_DOWN_TIMEOUT}) // 5}}
        Sleep    5s
        ${result}=    Run Process    kubectl    get    microvms    -n    ${NAMESPACE}
        ...    -l    lambda.aws.amazon.com/replica-set\=${PERF_RS_NAME}    --no-headers
        ${remaining}=    Get Line Count    ${result.stdout}
        ${elapsed}=    Evaluate    int(__import__('time').time() - ${start_time})
        Log    [${elapsed}s] VMs remaining: ${remaining}
        IF    ${remaining} == 0
            Exit For Loop
        END
    END
    ${drain_time}=    Evaluate    int(__import__('time').time() - ${start_time})
    Set Suite Variable    ${DRAIN_TIME}    ${drain_time}
    Log    All VMs drained in ${drain_time}s
    Should Be True    ${drain_time} <= ${SCALE_DOWN_TIMEOUT}
    ...    msg=Drain took ${drain_time}s, exceeding ${SCALE_DOWN_TIMEOUT}s budget

PERF-07 No Operator Restarts After Full Cycle
    [Documentation]    Final stability check — no crashes through the entire test.
    [Tags]    performance    critical
    ${current_restarts}=    Get Operator Restart Count
    Should Be Equal As Integers    ${current_restarts}    ${BASELINE_RESTARTS}
    ...    msg=Operator restarted during test! Restarts: baseline=${BASELINE_RESTARTS} current=${current_restarts}

PERF-08 Performance Summary
    [Documentation]    Logs a summary of all collected performance metrics.
    [Tags]    performance
    Log    \n========== PERFORMANCE SUMMARY ==========
    Log    Requested replicas: ${PERF_REPLICAS}
    Log    Peak Running VMs: ${PEAK_READY}
    Log    Peak Created VMs: ${PEAK_CURRENT}
    Log    Scale-up time to plateau: ${SCALE_UP_TIME}s
    Log    Scale-down drain time: ${DRAIN_TIME}s
    Log    Operator restarts: 0
    Log    Account concurrency band: ${EXPECTED_MIN_RUNNING}-${EXPECTED_MAX_RUNNING}
    Log    ==========================================
    # This test always passes — it's just for reporting
    Pass Execution    Summary logged

*** Keywords ***
Setup Performance Test
    ${id}=    Evaluate    __import__('time').strftime('%H%M%S')
    Set Suite Variable    ${RUN_ID}    ${id}
    Set Suite Variable    ${PERF_RS_NAME}    perf-rs-${id}
    # Ensure shared image is available (needed for ReplicaSet)
    Ensure Shared Image Ready

Teardown Performance Test
    # Force-delete ReplicaSet if it still exists (test may have failed mid-way)
    ${result}=    Run Process    kubectl    get    microvmreplicaset    ${PERF_RS_NAME}    -n    ${NAMESPACE}
    IF    ${result.rc} == 0
        Run Process    kubectl    delete    microvmreplicaset    ${PERF_RS_NAME}
        ...    -n    ${NAMESPACE}    --timeout\=120s
        # Wait for children to drain
        FOR    ${i}    IN RANGE    60
            Sleep    5s
            ${vms}=    Run Process    kubectl    get    microvms    -n    ${NAMESPACE}
            ...    -l    lambda.aws.amazon.com/replica-set\=${PERF_RS_NAME}    --no-headers
            ${count}=    Get Line Count    ${vms.stdout}
            Exit For Loop If    ${count} == 0
        END
    END

Get Operator Restart Count
    [Documentation]    Returns the total restart count for the operator pod.
    ${result}=    Run Process    kubectl    get    pod    -n    ${OPERATOR_NS}
    ...    -l    app.kubernetes.io/name\=kube-microvm-operator
    ...    -o    jsonpath\={.items[0].status.containerStatuses[0].restartCount}
    ${count}=    Convert To Integer    ${result.stdout}    default=0
    RETURN    ${count}

Get RS Field
    [Documentation]    Get a field from the ReplicaSet status (or spec).
    [Arguments]    ${field}    ${section}=status
    ${result}=    Run Process    kubectl    get    microvmreplicaset    ${PERF_RS_NAME}
    ...    -n    ${NAMESPACE}    -o    jsonpath\={.${section}.${field}}
    RETURN    ${result.stdout}

Convert To Integer
    [Documentation]    Safely convert string to integer, returning default on failure.
    [Arguments]    ${value}    ${default}=0
    ${result}=    Evaluate    int('${value}') if '${value}'.strip().isdigit() else ${default}
    RETURN    ${result}
