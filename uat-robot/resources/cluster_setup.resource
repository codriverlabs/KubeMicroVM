*** Settings ***
Documentation    Shared cluster setup — ensures operator, CRDs, namespace, and S3 fixtures
...              are in place before any UAT suite runs. Each suite imports this as a resource
...              and calls "Verify Cluster Ready" in its Suite Setup.
Library    Process
Library    OperatingSystem
Resource   variables.robot

*** Keywords ***
Verify Cluster Ready
    [Documentation]    Validates that the cluster has operator running, CRDs installed,
    ...    namespace labelled, and S3 test fixtures uploaded. Fails fast if not ready.
    Verify Operator Running
    Verify CRDs Installed
    Verify Namespace Labelled
    Verify S3 Fixtures Uploaded

Verify Operator Running
    ${result}=    Run Process    kubectl    get    deploy    kube-microvm-operator    -n    ${OPERATOR_NS}    -o    jsonpath\={.status.readyReplicas}
    Should Be Equal As Integers    ${result.rc}    0    kubectl failed: ${result.stderr}
    Should Be Equal    ${result.stdout}    1    Operator not running — install with: helm install kube-microvm-operator oci://ghcr.io/plasticity-of-cloud/helm/kube-microvm-operator --version ${CHART_VERSION} --namespace ${OPERATOR_NS} --create-namespace --set app.envs.AWS_REGION=${REGION}

Verify CRDs Installed
    ${result}=    Run Process    kubectl    get    crd    microvms.lambda.aws.amazon.com
    Should Be Equal As Integers    ${result.rc}    0    CRDs not installed — operator Helm chart should install them
    ${result}=    Run Process    kubectl    get    crd    microvmimages.lambda.aws.amazon.com
    Should Be Equal As Integers    ${result.rc}    0    MicroVMImage CRD missing
    ${result}=    Run Process    kubectl    get    crd    microvmclasses.lambda.aws.amazon.com
    Should Be Equal As Integers    ${result.rc}    0    MicroVMClass CRD missing

Verify Namespace Labelled
    ${result}=    Run Process    kubectl    get    namespace    ${NAMESPACE}    -o    jsonpath\={.metadata.labels.lambda\\.aws\\.amazon\\.com/manage-microvms}
    IF    "${result.stdout}" != "true"
        Run Process    kubectl    label    namespace    ${NAMESPACE}    lambda.aws.amazon.com/manage-microvms\=true    --overwrite
        Log    Labelled namespace ${NAMESPACE} for MicroVM management
    END
    # Also ensure injection label
    ${inject}=    Run Process    kubectl    get    namespace    ${NAMESPACE}    -o    jsonpath\={.metadata.labels.lambda\\.microvm\\.auth/inject}
    IF    "${inject.stdout}" != "enabled"
        Run Process    kubectl    label    namespace    ${NAMESPACE}    lambda.microvm.auth/inject\=enabled    --overwrite
    END

Verify S3 Fixtures Uploaded
    ${result}=    Run Process    aws    s3    ls    s3://${S3_BUCKET}/test-fixtures/microvm-hello-node.zip
    IF    ${result.rc} != 0
        Log    Uploading test fixtures to S3...
        Upload Test Fixtures
    END

Upload Test Fixtures
    ${zip_hello}=    Run Process    bash    -c    cd ${CODEBASE_PATH}/test-fixtures/microvm-hello-node && zip -r /tmp/microvm-hello-node.zip .
    Run Process    aws    s3    cp    /tmp/microvm-hello-node.zip    s3://${S3_BUCKET}/test-fixtures/microvm-hello-node.zip
    ${zip_net}=    Run Process    bash    -c    cd ${CODEBASE_PATH}/test-fixtures/microvm-net-test && zip -r /tmp/microvm-net-test.zip .
    Run Process    aws    s3    cp    /tmp/microvm-net-test.zip    s3://${S3_BUCKET}/test-fixtures/microvm-net-test.zip

Setup Cluster If Needed
    [Documentation]    Full setup: installs operator if not present, labels namespace, uploads fixtures.
    ...    Call this for CI/CD environments where cluster may be fresh.
    ${op_check}=    Run Process    kubectl    get    deploy    kube-microvm-operator    -n    ${OPERATOR_NS}
    IF    ${op_check.rc} != 0
        Log    Operator not found — installing...
        Install Operator
    END
    Verify Cluster Ready

Install Operator
    ${result}=    Run Process    helm    install    kube-microvm-operator
    ...    oci://ghcr.io/plasticity-of-cloud/helm/kube-microvm-operator
    ...    --version    ${CHART_VERSION}
    ...    --namespace    ${OPERATOR_NS}
    ...    --create-namespace
    ...    --set    app.envs.AWS_REGION\=${REGION}
    ...    --timeout    4m
    ...    --wait
    Should Be Equal As Integers    ${result.rc}    0    Helm install failed: ${result.stderr}
    Log    Operator installed successfully

Ensure Shared Image Ready
    [Documentation]    Creates the shared MicroVMImage if it doesn't exist, waits for build.
    ...    Called by suites that depend on Quick Start having run first.
    ${result}=    Run Process    kubectl    get    microvmimage    ${SHARED_IMAGE}    -n    ${NAMESPACE}
    IF    ${result.rc} == 0
        # Image CR exists — check if built
        ${state}=    Run Process    kubectl    get    microvmimage    ${SHARED_IMAGE}    -n    ${NAMESPACE}    -o    jsonpath\={.status.imageState}
        IF    "${state.stdout}" == "CREATED"
            Log    Shared image ${SHARED_IMAGE} already built
            RETURN
        END
        # Still building — wait
        Wait For Image Ready    ${SHARED_IMAGE}
    ELSE
        # Image doesn't exist — create it
        Log    Creating shared image ${SHARED_IMAGE}...
        ${yaml}=    Catenate    SEPARATOR=\n
        ...    apiVersion: lambda.aws.amazon.com/v1alpha1
        ...    kind: MicroVMImage
        ...    metadata:
        ...    ${SPACE}${SPACE}name: ${SHARED_IMAGE}
        ...    ${SPACE}${SPACE}namespace: ${NAMESPACE}
        ...    spec:
        ...    ${SPACE}${SPACE}source:
        ...    ${SPACE}${SPACE}${SPACE}${SPACE}s3Bucket: ${S3_BUCKET}
        ...    ${SPACE}${SPACE}${SPACE}${SPACE}s3Key: ${S3_KEY}
        ...    ${SPACE}${SPACE}baseImageArn: "${BASE_IMAGE_ARN}"
        ...    ${SPACE}${SPACE}buildRoleArn: "${BUILD_ROLE_ARN}"
        Kubectl Apply    ${yaml}
        Wait For Image Ready    ${SHARED_IMAGE}
    END
