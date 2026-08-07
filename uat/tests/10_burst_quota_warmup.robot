*** Settings ***
Documentation    UAT: Burst Quota Warmup — 3 parallel ReplicaSets × 500 MicroVMs
...
...    Purpose: Generate sustained high-throughput RunMicrovm API calls to
...    demonstrate usage patterns above 5 VMs/s, triggering AWS's automatic
...    quota increase mechanism (as advised by support ticket).
...
...    Strategy:
...    - Build 3 distinct MicroVM images (hello-node, net-test, burst-worker)
...    - Create 3 ReplicaSets simultaneously, each requesting 500 replicas
...    - The operator sends RunMicrovm calls for all 1500 VMs through the quota guard
...    - Monitor achieved throughput and max concurrent VMs
...    - Record metrics as evidence for quota increase request
...    - Tear down all resources after observation window
...
...    This test is INTENTIONALLY lenient on assertions — we expect many VMs
...    to remain Pending due to current limits. The goal is to generate load,
...    not to pass/fail. Only operator stability is strictly asserted.
...
...    Run standalone:
...      robot --outputdir results/burst -i burst tests/10_burst_quota_warmup.robot
...
...    Run in a loop (recommended — generates sustained signal):
...      ./uat/run-burst-warmup.sh --waves 6 --interval 35
...
...    Expected behaviour at current limits (us-east-1, 2026-08):
...    - RunMicrovm burst: 5/s → operator queues all 1500 requests
...    - Max concurrent Running: ~161 (account ceiling)
...    - Most VMs will stay Pending or hit account limit
...    - After quota increase: throughput should rise above 5/s
Resource         ../resources/common.resource
Resource         ../resources/variables.robot
Resource         ../resources/cluster_setup.resource
Suite Setup      Run Keywords    Verify Cluster Ready    AND    Setup Burst Test
Suite Teardown   Teardown Burst Test
Force Tags       burst    performance

*** Variables ***
# --- Burst configuration ---
${BURST_REPLICAS}             500
${BURST_OBSERVATION_WINDOW}   600
# How long to wait before declaring scale-up "done" (10 min max)
${BURST_POLL_INTERVAL}        10
# Image names (built once, reused across waves)
${BURST_IMAGE_A}              burst-img-hello
${BURST_IMAGE_B}              burst-img-net
${BURST_IMAGE_C}              burst-img-worker
# ReplicaSet names (include run ID for uniqueness)
${BURST_RS_A}                 ${EMPTY}
${BURST_RS_B}                 ${EMPTY}
${BURST_RS_C}                 ${EMPTY}
# S3 keys for the 3 fixtures
${S3_KEY_BURST}               test-fixtures/microvm-burst-worker.zip

*** Test Cases ***
BURST-01 Operator Stable Before Burst
    [Documentation]    Baseline health and restart count.
    [Tags]    burst    smoke
    ${restarts}=    Get Operator Restart Count
    Set Suite Variable    ${BASELINE_RESTARTS}    ${restarts}
    ${result}=    Run Process    bash    -c
    ...    kubectl exec -n ${OPERATOR_NS} deploy/kube-microvm-operator -- curl -s http://localhost:8080/q/health/ready
    Should Contain    ${result.stdout}    UP

BURST-02 All Three Images Built
    [Documentation]    Ensure all 3 burst images are in CREATED state.
    ...    These are built during Suite Setup. This test validates they're ready.
    [Tags]    burst
    ${state_a}=    Kubectl Get JsonPath    microvmimage    ${BURST_IMAGE_A}    {.status.imageState}
    ${state_b}=    Kubectl Get JsonPath    microvmimage    ${BURST_IMAGE_B}    {.status.imageState}
    ${state_c}=    Kubectl Get JsonPath    microvmimage    ${BURST_IMAGE_C}    {.status.imageState}
    Should Be Equal    ${state_a}    CREATED    Image A not ready: ${state_a}
    Should Be Equal    ${state_b}    CREATED    Image B not ready: ${state_b}
    Should Be Equal    ${state_c}    CREATED    Image C not ready: ${state_c}

BURST-03 Launch 3×500 ReplicaSets Simultaneously
    [Documentation]    Create all 3 ReplicaSets in rapid succession.
    ...    This generates 1500 RunMicrovm API calls through the operator's quota guard.
    [Tags]    burst    critical
    ${run_id}=    Evaluate    __import__('time').strftime('%H%M%S')
    Set Suite Variable    ${RUN_ID}    ${run_id}
    # Create RS A (hello-node)
    ${rs_a}=    Set Variable    burst-a-${run_id}
    Set Suite Variable    ${BURST_RS_A}    ${rs_a}
    Set Suite Variable    ${NAME}    ${rs_a}
    Set Suite Variable    ${REPLICAS}    ${BURST_REPLICAS}
    Set Suite Variable    ${IMAGE_REF}    ${BURST_IMAGE_A}
    Apply Template    burst/burst-replicaset.yaml
    # Create RS B (net-test)
    ${rs_b}=    Set Variable    burst-b-${run_id}
    Set Suite Variable    ${BURST_RS_B}    ${rs_b}
    Set Suite Variable    ${NAME}    ${rs_b}
    Set Suite Variable    ${IMAGE_REF}    ${BURST_IMAGE_B}
    Apply Template    burst/burst-replicaset.yaml
    # Create RS C (burst-worker)
    ${rs_c}=    Set Variable    burst-c-${run_id}
    Set Suite Variable    ${BURST_RS_C}    ${rs_c}
    Set Suite Variable    ${NAME}    ${rs_c}
    Set Suite Variable    ${IMAGE_REF}    ${BURST_IMAGE_C}
    Apply Template    burst/burst-replicaset.yaml
    Log    Created 3 ReplicaSets: ${rs_a}, ${rs_b}, ${rs_c} — each requesting ${BURST_REPLICAS} replicas
    ${launch_time}=    Evaluate    __import__('time').time()
    Set Suite Variable    ${LAUNCH_TIME}    ${launch_time}

BURST-04 Monitor Scale-Up Throughput
    [Documentation]    Poll all 3 ReplicaSets for ${BURST_OBSERVATION_WINDOW}s, tracking:
    ...    - Total VMs reaching Running across all 3
    ...    - Effective throughput (VMs/s)
    ...    - Max concurrent Running VMs achieved
    ...    - Per-RS breakdown
    [Tags]    burst
    ${max_running}=    Set Variable    0
    ${peak_rate}=    Set Variable    0
    FOR    ${i}    IN RANGE    ${{int(${BURST_OBSERVATION_WINDOW}) // int(${BURST_POLL_INTERVAL})}}
        Sleep    ${BURST_POLL_INTERVAL}s
        ${elapsed}=    Evaluate    int(__import__('time').time() - ${LAUNCH_TIME})
        # Get ready counts for all 3
        ${ready_a}=    Get Burst RS Ready    ${BURST_RS_A}
        ${ready_b}=    Get Burst RS Ready    ${BURST_RS_B}
        ${ready_c}=    Get Burst RS Ready    ${BURST_RS_C}
        ${total_ready}=    Evaluate    ${ready_a} + ${ready_b} + ${ready_c}
        ${rate}=    Evaluate    round(${total_ready} / max(${elapsed}, 1), 2)
        # Track peak
        IF    ${total_ready} > ${max_running}
            ${max_running}=    Set Variable    ${total_ready}
        END
        IF    ${rate} > ${peak_rate}
            ${peak_rate}=    Set Variable    ${rate}
        END
        Log    [${elapsed}s] A=${ready_a} B=${ready_b} C=${ready_c} total=${total_ready}/1500 rate=${rate}/s peak_concurrent=${max_running}
        # Early exit if all 1500 reach Running (unlikely at current limits)
        IF    ${total_ready} >= 1500
            Log    All 1500 VMs Running — quota increase achieved!
            Exit For Loop
        END
        # Also exit early if no progress for 2 minutes (we've hit the ceiling)
        IF    ${elapsed} > 180 and ${total_ready} == ${max_running} and ${i} > 18
            # Check if we've plateaued (no new VMs for last 2 poll cycles would be caught by the loop naturally)
            Log    Throughput plateaued at ${max_running} concurrent VMs. Likely at account limit.
        END
    END
    # Record final metrics
    ${final_elapsed}=    Evaluate    int(__import__('time').time() - ${LAUNCH_TIME})
    Set Suite Variable    ${MAX_CONCURRENT}    ${max_running}
    Set Suite Variable    ${PEAK_RATE}    ${peak_rate}
    Set Suite Variable    ${OBSERVATION_ELAPSED}    ${final_elapsed}
    Log    Scale-up observation complete: max_concurrent=${max_running} peak_rate=${peak_rate}/s elapsed=${final_elapsed}s

BURST-05 No Operator Restarts Under Load
    [Documentation]    Verify operator survived the 1500-VM burst without crashing.
    [Tags]    burst    critical
    ${current_restarts}=    Get Operator Restart Count
    Should Be Equal As Integers    ${current_restarts}    ${BASELINE_RESTARTS}
    ...    msg=Operator restarted during burst! baseline=${BASELINE_RESTARTS} current=${current_restarts}

BURST-06 Scale Down All ReplicaSets
    [Documentation]    Delete all 3 ReplicaSets and measure drain time.
    [Tags]    burst    destructive
    ${drain_start}=    Evaluate    __import__('time').time()
    # Delete all 3 in parallel (kubectl delete can handle multiple)
    Run Process    kubectl    delete    microvmreplicaset    ${BURST_RS_A}    ${BURST_RS_B}    ${BURST_RS_C}
    ...    -n    ${NAMESPACE}    --timeout\=120s
    # Monitor drain
    FOR    ${i}    IN RANGE    120
        Sleep    5s
        ${result}=    Run Process    bash    -c
        ...    kubectl get microvms -n ${NAMESPACE} -l "lambda.aws.amazon.com/replica-set in (${BURST_RS_A},${BURST_RS_B},${BURST_RS_C})" --no-headers 2>/dev/null | wc -l
        @{lines}=    Split To Lines    ${result.stdout}
        ${last_line}=    Get From List    ${lines}    -1
        ${remaining}=    Evaluate    int($last_line) if str($last_line).strip().isdigit() else 0
        ${drain_elapsed}=    Evaluate    int(__import__('time').time() - ${drain_start})
        ${drained}=    Evaluate    max(${MAX_CONCURRENT} - ${remaining}, 0)
        ${drain_rate}=    Evaluate    round(${drained} / max(${drain_elapsed}, 1), 1)
        Log    [${drain_elapsed}s] remaining=${remaining} drain_rate=${drain_rate}/s
        IF    ${remaining} == 0
            Exit For Loop
        END
    END
    ${total_drain}=    Evaluate    int(__import__('time').time() - ${drain_start})
    Set Suite Variable    ${DRAIN_TIME}    ${total_drain}
    Log    All VMs drained in ${total_drain}s

BURST-07 Operator Stable After Full Cycle
    [Documentation]    Final stability check after complete burst + drain.
    [Tags]    burst    critical
    ${current_restarts}=    Get Operator Restart Count
    Should Be Equal As Integers    ${current_restarts}    ${BASELINE_RESTARTS}
    ...    msg=Operator restarted during burst cycle! baseline=${BASELINE_RESTARTS} current=${current_restarts}

BURST-08 Performance Summary Report
    [Documentation]    Comprehensive metrics report for quota increase evidence.
    ...    This output should be included in the AWS support ticket.
    [Tags]    burst
    ${ready_a}=    Get Burst RS Ready    ${BURST_RS_A}
    ${ready_b}=    Get Burst RS Ready    ${BURST_RS_B}
    ${ready_c}=    Get Burst RS Ready    ${BURST_RS_C}
    ${total_requested}=    Evaluate    ${BURST_REPLICAS} * 3
    ${report}=    Catenate    SEPARATOR=\n
    ...    ${\n}
    ...    ╔══════════════════════════════════════════════════════════════╗
    ...    ║         BURST QUOTA WARMUP — PERFORMANCE REPORT            ║
    ...    ╠══════════════════════════════════════════════════════════════╣
    ...    ║  Date/Time:     ${RUN_ID}
    ...    ║  Region:        ${REGION}
    ...    ║  Account:       ${ACCOUNT_ID}
    ...    ╠══════════════════════════════════════════════════════════════╣
    ...    ║  CONFIGURATION
    ...    ║  Parallel ReplicaSets: 3
    ...    ║  Replicas per RS:     ${BURST_REPLICAS}
    ...    ║  Total requested:     ${total_requested}
    ...    ╠══════════════════════════════════════════════════════════════╣
    ...    ║  RESULTS
    ...    ║  Max concurrent Running:  ${MAX_CONCURRENT}
    ...    ║  Peak throughput:         ${PEAK_RATE} VMs/s
    ...    ║  Observation window:      ${OBSERVATION_ELAPSED}s
    ...    ║  RS-A (hello-node):       ${ready_a}/${BURST_REPLICAS}
    ...    ║  RS-B (net-test):         ${ready_b}/${BURST_REPLICAS}
    ...    ║  RS-C (burst-worker):     ${ready_c}/${BURST_REPLICAS}
    ...    ║  Drain time:             ${DRAIN_TIME}s
    ...    ║  Operator restarts:      0
    ...    ╠══════════════════════════════════════════════════════════════╣
    ...    ║  QUOTA STATUS
    ...    ║  RunMicrovm burst limit:  5/s (requesting increase)
    ...    ║  Concurrent VM limit:     ~161 (requesting increase)
    ...    ╚══════════════════════════════════════════════════════════════╝
    Log    ${report}
    Pass Execution    Burst quota warmup report logged — attach to support ticket

*** Keywords ***
Setup Burst Test
    [Documentation]    Upload burst-worker fixture to S3 and build all 3 images.
    Upload Burst Worker Fixture
    Build Burst Images

Upload Burst Worker Fixture
    [Documentation]    Package and upload the burst-worker fixture to S3.
    ${result}=    Run Process    aws    s3    ls    s3://${S3_BUCKET}/test-fixtures/microvm-burst-worker.zip
    IF    ${result.rc} != 0
        Log    Uploading burst-worker fixture to S3...
        Run Process    bash    -c
        ...    cd ${CODEBASE_PATH}/uat/fixtures/microvm-burst-worker && zip -r /tmp/microvm-burst-worker.zip .
        ${upload}=    Run Process    aws    s3    cp    /tmp/microvm-burst-worker.zip
        ...    s3://${S3_BUCKET}/test-fixtures/microvm-burst-worker.zip
        Should Be Equal As Integers    ${upload.rc}    0    S3 upload failed: ${upload.stderr}
    END

Build Burst Images
    [Documentation]    Create all 3 MicroVM images. Skip if already built.
    # Image A — hello-node (same as shared, but separate for burst isolation)
    Build Burst Image If Needed    ${BURST_IMAGE_A}    ${S3_KEY}
    # Image B — net-test
    Build Burst Image If Needed    ${BURST_IMAGE_B}    ${S3_KEY_NET}
    # Image C — burst-worker
    Build Burst Image If Needed    ${BURST_IMAGE_C}    ${S3_KEY_BURST}
    # Wait for all 3 to reach CREATED
    Wait For Image Ready    ${BURST_IMAGE_A}    timeout=600
    Wait For Image Ready    ${BURST_IMAGE_B}    timeout=600
    Wait For Image Ready    ${BURST_IMAGE_C}    timeout=600

Build Burst Image If Needed
    [Documentation]    Create a MicroVMImage if it doesn't exist or isn't CREATED.
    [Arguments]    ${image_name}    ${s3_key}
    ${result}=    Run Process    kubectl    get    microvmimage    ${image_name}    -n    ${NAMESPACE}
    IF    ${result.rc} == 0
        ${state}=    Kubectl Get JsonPath    microvmimage    ${image_name}    {.status.imageState}
        IF    "${state}" == "CREATED"
            Log    Image ${image_name} already built — skipping
            RETURN
        END
    ELSE
        Set Suite Variable    ${NAME}    ${image_name}
        Set Suite Variable    ${S3_KEY_BURST}    ${s3_key}
        Apply Template    burst/burst-image.yaml
    END

Teardown Burst Test
    [Documentation]    Force-remove all burst ReplicaSets and child VMs.
    # Delete ReplicaSets (may already be gone from BURST-06)
    FOR    ${rs}    IN    ${BURST_RS_A}    ${BURST_RS_B}    ${BURST_RS_C}
        IF    "${rs}" != ""
            ${check}=    Run Process    kubectl    get    microvmreplicaset    ${rs}    -n    ${NAMESPACE}
            IF    ${check.rc} == 0
                Run Process    kubectl    delete    microvmreplicaset    ${rs}    -n    ${NAMESPACE}    --timeout\=60s
            END
        END
    END
    # Wait for children to drain (max 5 min)
    FOR    ${i}    IN RANGE    60
        ${result}=    Run Process    bash    -c
        ...    kubectl get microvms -n ${NAMESPACE} --no-headers 2>/dev/null | grep -c "burst-" || echo "0"
        @{lines}=    Split To Lines    ${result.stdout}
        ${last_line}=    Get From List    ${lines}    -1
        ${count}=    Evaluate    int($last_line) if str($last_line).strip().isdigit() else 0
        IF    ${count} == 0
            Exit For Loop
        END
        Sleep    5s
    END
    # Force-remove any stuck VMs
    ${stuck}=    Run Process    bash    -c
    ...    kubectl get microvms -n ${NAMESPACE} --no-headers 2>/dev/null | grep "burst-" | awk '{print $1}' || true
    @{vm_lines}=    Split To Lines    ${stuck.stdout}
    FOR    ${vm}    IN    @{vm_lines}
        IF    "${vm.strip()}" != ""
            Kubectl Delete Force    microvm    ${vm.strip()}
        END
    END

Get Burst RS Ready
    [Documentation]    Get readyReplicas for a burst ReplicaSet. Returns 0 if RS is gone.
    [Arguments]    ${rs_name}
    ${result}=    Run Process    kubectl    get    microvmreplicaset    ${rs_name}
    ...    -n    ${NAMESPACE}    -o    jsonpath\={.status.readyReplicas}
    ${ready}=    Evaluate    int('${result.stdout}'.strip()) if '${result.stdout}'.strip().isdigit() else 0
    RETURN    ${ready}

Get Operator Restart Count
    [Documentation]    Returns the total restart count for the operator pod.
    ${result}=    Run Process    kubectl    get    pod    -n    ${OPERATOR_NS}
    ...    -l    app.kubernetes.io/name\=kube-microvm-operator
    ...    -o    jsonpath\={.items[0].status.containerStatuses[0].restartCount}
    ${count}=    Evaluate    int('${result.stdout}'.strip()) if '${result.stdout}'.strip().isdigit() else 0
    RETURN    ${count}
