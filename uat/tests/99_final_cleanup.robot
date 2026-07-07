*** Settings ***
Documentation    Final cleanup — removes shared resources created during UAT.
...              Run this last (or it runs last alphabetically in the tests/ directory).
Resource         ../resources/common.resource
Resource         ../resources/variables.robot
Force Tags       teardown

*** Test Cases ***
Cleanup Shared Image
    [Documentation]    Removes the shared MicroVMImage used across all suites
    Kubectl Delete Force    microvmimage    ${SHARED_IMAGE}
    ${result}=    Run Process    kubectl    get    microvmimage    ${SHARED_IMAGE}    -n    ${NAMESPACE}
    Should Not Be Equal As Integers    ${result.rc}    0    Shared image should be deleted

Verify No Resources Remaining
    [Documentation]    Confirms all UAT resources have been cleaned up
    ${vms}=    Run Process    kubectl    get    microvms    -n    ${NAMESPACE}    --no-headers
    Should Be Empty    ${vms.stdout.strip()}    MicroVMs still exist: ${vms.stdout}
    ${images}=    Run Process    kubectl    get    microvmimages    -n    ${NAMESPACE}    --no-headers
    Should Be Empty    ${images.stdout.strip()}    MicroVMImages still exist: ${images.stdout}
    ${networks}=    Run Process    kubectl    get    microvmnetworks    -n    ${NAMESPACE}    --no-headers
    Should Be Empty    ${networks.stdout.strip()}    MicroVMNetworks still exist: ${networks.stdout}
