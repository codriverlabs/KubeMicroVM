*** Settings ***
Documentation    UAT: Performance Scale Test — 1000 MicroVMs via ReplicaSet
...
...    Creates a ReplicaSet with 1000 replicas and validates:
...    - Operator handles scale-up without crashing
...    - Rate limiting (RunMicrovm 5/s) is respected by quota guard
...    - All 1000 VMs reach Running within the time budget
...    - Status reporting is accurate (readyReplicas, currentReplicas)
...    - Scale-down and termination completes within bounded time
...    - No operator restarts during the entire test
...
...    Expected behaviour (us-east-1, RunMicrovm rate 5/s):
...    - Creation throughput: ~3-4 VMs/s reaching Running
...    - Time to 1000 Running: ~5-8 minutes (rate-limited creation + boot)
...    - Termination rate: ~10 req/s → full drain in ~2-3 minutes
...
...    This suite is long-running (~15-20 minutes). Tag: performance
...    Run: robot --outputdir results -i performance tests/09_performance_scale.robot
Resource         ../resources/common.resource
Resource         ../resources/variables.robot
Resource         ../resources/cluster_setup.resource
Suite Setup      Run Keywords    Verify Cluster Ready    AND    Setup Performance Test
Suite Teardown   Teardown Performance Test
Force Tags       performance

*** Variables ***
${PERF_RS_NAME}           perf-rs-${RUN_ID}
${PERF_REPLICAS}          1000
# Time budget for all 1000 VMs to reach Running
# At 5/s RunMicrovm rate + boot time ≈ 250s creation + 60s boot buffer = ~5-8 min
${SCALE_UP_TIMEOUT}       900
${SCALE_DOWN_TIMEOUT}     300
${POLL_INTERVAL_SCALE}    10
${RUN_ID}                 ${EMPTY}

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

PERF-03 All 1000 VMs Reach Running
    [Documentation]    Monitor scale-up until all 1000 VMs reach Running.
    ...    Tracks throughput and logs progress every ${POLL_INTERVAL_SCALE}s.
    [Tags]    performance
    ${start_time}=    Evaluate    __import__('time').time()
    ${first_running_time}=    Set Variable    0
    FOR    ${i}    IN RANGE    ${{int(${SCALE_UP_TIMEOUT}) // int(${POLL_INTERVAL_SCALE})}}
        Sleep    ${POLL_INTERVAL_SCALE}s
        ${ready}=    Get RS Field    readyReplicas
        ${current}=    Get RS Field    currentReplicas
        ${elapsed}=    Evaluate    int(__import__('time').time() - ${start_time})
        ${ready_int}=    Safe Int    ${ready}
        ${current_int}=    Safe Int    ${current}
        # Track first Running VM time for throughput calculation
        IF    ${ready_int} > 0 and ${first_running_time} == 0
            ${first_running_time}=    Evaluate    __import__('time').time()
            Set Suite Variable    ${FIRST_RUNNING_TIME}    ${first_running_time}
        END
        # Calculate live throughput
        ${rate}=    Evaluate    round(${ready_int} / max(${elapsed}, 1), 1)
        Log    [${elapsed}s] ready=${ready_int}/1000 current=${current_int} rate=${rate}/s
        IF    ${ready_int} >= 1000
            Exit For Loop
        END
    END
    ${total_elapsed}=    Evaluate    int(__import__('time').time() - ${start_time})
    ${final_rate}=    Evaluate    round(1000 / max(${total_elapsed}, 1), 2)
    Set Suite Variable    ${SCALE_UP_TIME}    ${total_elapsed}
    Set Suite Variable    ${SCALE_UP_RATE}    ${final_rate}
    Log    All 1000 VMs Running in ${total_elapsed}s (effective rate: ${final_rate}/s)
    # Verify all 1000 reached Running
    ${final_ready}=    Get RS Field    readyReplicas
    ${final_ready_int}=    Safe Int    ${final_ready}
    Should Be Equal As Integers    ${final_ready_int}    1000
    ...    msg=Expected 1000 Running VMs but got ${final_ready_int} after ${total_elapsed}s

PERF-04 Status Reports Accurate Counts
    [Documentation]    Verify ReplicaSet status fields are consistent at full scale.
    [Tags]    performance
    ${ready}=    Get RS Field    readyReplicas
    ${current}=    Get RS Field    currentReplicas
    ${desired}=    Get RS Field    replicas    spec
    ${ready_int}=    Safe Int    ${ready}
    ${current_int}=    Safe Int    ${current}
    Should Be Equal As Integers    ${ready_int}    1000
    Should Be Equal As Integers    ${current_int}    1000
    Should Be Equal    ${desired}    1000

PERF-05 No Operator Restarts During Scale-Up
    [Documentation]    Verify the operator pod did not restart under load.
    [Tags]    performance    critical
    ${current_restarts}=    Get Operator Restart Count
    Should Be Equal As Integers    ${current_restarts}    ${BASELINE_RESTARTS}
    ...    msg=Operator restarted during scale-up! Restarts: baseline=${BASELINE_RESTARTS} current=${current_restarts}

PERF-06 Scale Down To Zero
    [Documentation]    Delete the ReplicaSet and measure time to drain all 1000 VM CRs.
    ...    Target: all CRs removed within ${SCALE_DOWN_TIMEOUT}s.
    [Tags]    performance    destructive
    ${start_time}=    Evaluate    __import__('time').time()
    Run Process    kubectl    delete    microvmreplicaset    ${PERF_RS_NAME}
    ...    -n    ${NAMESPACE}    --timeout\=120s
    # Monitor drain progress
    FOR    ${i}    IN RANGE    ${{int(${SCALE_DOWN_TIMEOUT}) // 5}}
        Sleep    5s
        ${result}=    Run Process    kubectl    get    microvms    -n    ${NAMESPACE}
        ...    -l    lambda.aws.amazon.com/replica-set\=${PERF_RS_NAME}    --no-headers
        ${remaining}=    Get Line Count    ${result.stdout}
        ${elapsed}=    Evaluate    int(__import__('time').time() - ${start_time})
        ${terminate_rate}=    Evaluate    round((1000 - ${remaining}) / max(${elapsed}, 1), 1)
        Log    [${elapsed}s] remaining=${remaining}/1000 terminate_rate=${terminate_rate}/s
        IF    ${remaining} == 0
            Exit For Loop
        END
    END
    ${drain_time}=    Evaluate    int(__import__('time').time() - ${start_time})
    Set Suite Variable    ${DRAIN_TIME}    ${drain_time}
    ${drain_rate}=    Evaluate    round(1000 / max(${drain_time}, 1), 2)
    Set Suite Variable    ${DRAIN_RATE}    ${drain_rate}
    Log    All 1000 VMs drained in ${drain_time}s (rate: ${drain_rate}/s)
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
    Log    Scale-up: 1000 Running in ${SCALE_UP_TIME}s (${SCALE_UP_RATE} VMs/s)
    Log    Scale-down: 1000 drained in ${DRAIN_TIME}s (${DRAIN_RATE} VMs/s)
    Log    Operator restarts: 0
    Log    RunMicrovm rate limit: 5/s (pending quota increase)
    Log    ==========================================
    # This test always passes — it's for reporting
    Pass Execution    Summary logged

*** Keywords ***
Setup Performance Test
    ${id}=    Evaluate    __import__('time').strftime('%H%M%S')
    Set Suite Variable    ${RUN_ID}    ${id}
    Set Suite Variable    ${PERF_RS_NAME}    perf-rs-${id}
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
    ${count}=    Safe Int    ${result.stdout}
    RETURN    ${count}

Get RS Field
    [Documentation]    Get a field from the ReplicaSet status (or spec).
    [Arguments]    ${field}    ${section}=status
    ${result}=    Run Process    kubectl    get    microvmreplicaset    ${PERF_RS_NAME}
    ...    -n    ${NAMESPACE}    -o    jsonpath\={.${section}.${field}}
    RETURN    ${result.stdout}

Safe Int
    [Documentation]    Convert string to integer safely, returning 0 for empty/invalid.
    [Arguments]    ${value}
    ${result}=    Evaluate    int('${value}') if '${value}'.strip().lstrip('-').isdigit() else 0
    RETURN    ${result}
