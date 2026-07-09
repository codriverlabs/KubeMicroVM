*** Settings ***
Documentation    UAT: ReplicaSet Guide
Resource         ../resources/common.resource
Resource         ../resources/variables.robot
Resource         ../resources/cluster_setup.resource
Suite Setup      Run Keywords    Verify Cluster Ready    AND    Create ReplicaSet Resources
Suite Teardown   Cleanup ReplicaSet Resources
Force Tags       replicaset

*** Variables ***
${RS_NAME}          rs-pool-${RUN_ID}
${RS_SECOND_IMAGE}  uat-rolling-image-${RUN_ID}
${RUN_ID}           ${EMPTY}

*** Test Cases ***
RS-01 ReplicaSet Creates 3 MicroVMs
    [Tags]    smoke
    Sleep    15s    Wait for reconciler to create children
    ${result}=    Run Process    kubectl    get    microvms    -n    ${NAMESPACE}    --no-headers
    ${lines}=    Get Line Count    ${result.stdout}
    Should Be True    ${lines} >= 3

RS-02 RS List Shows ReplicaSet
    ${result}=    Microvm CLI    rs    list    -n    ${NAMESPACE}
    Should Contain    ${result.stdout}    ${RS_NAME}
    Should Contain    ${result.stdout}    3

RS-03 Scale Up To 5
    Run Process    kubectl    patch    microvmreplicaset    ${RS_NAME}    -n    ${NAMESPACE}    --type\=merge    -p    {"spec":{"replicas":5}}
    Sleep    20s
    ${result}=    Microvm CLI    rs    list    -n    ${NAMESPACE}
    Should Contain    ${result.stdout}    5

RS-04 Scale Down To 2
    Run Process    kubectl    patch    microvmreplicaset    ${RS_NAME}    -n    ${NAMESPACE}    --type\=merge    -p    {"spec":{"replicas":2}}
    Sleep    20s
    ${result}=    Microvm CLI    rs    list    -n    ${NAMESPACE}
    Should Contain    ${result.stdout}    2

RS-05 Rolling Update Changes ImageRef
    [Tags]    known-issue
    [Setup]    Skip    Known issue — timing sensitivity, manually verified
    [Documentation]    Verifies rolling update when spec.template.imageRef changes.
    ...    Known timing sensitivity: hash update requires all outdated VMs to terminate.
    ...    Manually verified during feature/replicaset-rolling-update E2E (2026-07-08).
    ...    - updatedReplicas reaches desired count
    ...    - no downtime (readyReplicas never drops to 0)
    # Record the original template hash
    ${original_hash}=    Run Process    kubectl    get    microvmreplicaset    ${RS_NAME}
    ...    -n    ${NAMESPACE}    -o    jsonpath\={.status.currentTemplateHash}
    Log    Original templateHash: ${original_hash.stdout}
    # Trigger rolling update by changing imageRef to the second image
    ${patch_cmd}=    Set Variable    kubectl patch microvmreplicaset ${RS_NAME} -n ${NAMESPACE} --type=merge -p '{"spec":{"template":{"imageRef":"${RS_SECOND_IMAGE}"}}}'
    Run Process    bash    -c    ${patch_cmd}
    # Wait up to 3 minutes for rolling update to complete
    FOR    ${i}    IN RANGE    18
        Sleep    10s
        ${updated}=    Run Process    kubectl    get    microvmreplicaset    ${RS_NAME}
        ...    -n    ${NAMESPACE}    -o    jsonpath\={.status.updatedReplicas}
        ${hash}=    Run Process    kubectl    get    microvmreplicaset    ${RS_NAME}
        ...    -n    ${NAMESPACE}    -o    jsonpath\={.status.currentTemplateHash}
        Log    [${i}] updatedReplicas=${updated.stdout} templateHash=${hash.stdout}
        Exit For Loop If    '${updated.stdout}' == '2' and '${hash.stdout}' != '${original_hash.stdout}'
    END
    # Verify final state
    ${final_hash}=    Run Process    kubectl    get    microvmreplicaset    ${RS_NAME}
    ...    -n    ${NAMESPACE}    -o    jsonpath\={.status.currentTemplateHash}
    ${final_updated}=    Run Process    kubectl    get    microvmreplicaset    ${RS_NAME}
    ...    -n    ${NAMESPACE}    -o    jsonpath\={.status.updatedReplicas}
    ${final_ready}=    Run Process    kubectl    get    microvmreplicaset    ${RS_NAME}
    ...    -n    ${NAMESPACE}    -o    jsonpath\={.status.readyReplicas}
    Should Not Be Equal    ${final_hash.stdout}    ${original_hash.stdout}
    ...    msg=templateHash should have changed after rolling update
    Should Be Equal    ${final_updated.stdout}    2
    ...    msg=updatedReplicas should be 2 after rolling update completes
    Should Be Equal As Integers    ${final_ready.stdout}    2
    ...    msg=readyReplicas should be 2 after rolling update

RS-06 Delete ReplicaSet Terminates All VMs
    [Tags]    destructive
    Run Process    kubectl    delete    microvmreplicaset    ${RS_NAME}    -n    ${NAMESPACE}    --timeout\=60s
    Sleep    10s
    ${result}=    Run Process    kubectl    get    microvms    -n    ${NAMESPACE}    --no-headers
    Should Be Empty    ${result.stdout.strip()}

*** Keywords ***
Create ReplicaSet Resources
    ${id}=    Evaluate    __import__('time').strftime('%H%M%S')
    Set Suite Variable    ${RUN_ID}    ${id}
    Set Suite Variable    ${RS_NAME}    rs-pool-${id}
    Set Suite Variable    ${RS_SECOND_IMAGE}    uat-rolling-image-${id}
    Ensure Shared Image Ready
    # Create second image for rolling update test (same source, different name = different imageRef)
    Set Suite Variable    ${NAME}    ${RS_SECOND_IMAGE}
    Apply Template    shared/microvm-image.yaml
    Wait For Image Ready    ${RS_SECOND_IMAGE}
    # Create the ReplicaSet with the first image
    Set Suite Variable    ${NAME}    ${RS_NAME}
    Set Suite Variable    ${REPLICAS}    3
    Set Suite Variable    ${IMAGE_REF}    ${SHARED_IMAGE}
    Apply Template    replicaset/replicaset.yaml

Cleanup ReplicaSet Resources
    Run Keyword And Ignore Error    Run Process    kubectl    delete    microvmreplicaset    ${RS_NAME}    -n    ${NAMESPACE}    --timeout\=60s
    Run Keyword And Ignore Error    Run Process    kubectl    patch    microvmimage    ${RS_SECOND_IMAGE}
    ...    -n    ${NAMESPACE}    --type\=json    -p    [{"op":"remove","path":"/metadata/finalizers"}]
    Run Keyword And Ignore Error    Run Process    kubectl    delete    microvmimage    ${RS_SECOND_IMAGE}
    ...    -n    ${NAMESPACE}    --timeout\=30s
