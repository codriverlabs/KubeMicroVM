*** Variables ***
${REGION}           us-east-1
${ACCOUNT_ID}       864899852480
${S3_BUCKET}        kube-microvm-test-${ACCOUNT_ID}-${REGION}
${S3_KEY}           test-fixtures/microvm-hello-node.zip
${S3_KEY_NET}       test-fixtures/microvm-net-test.zip
${S3_KEY_BURST}     test-fixtures/microvm-burst-worker.zip
${BASE_IMAGE_ARN}   arn:aws:lambda:${REGION}:aws:microvm-image:al2023-1
${BUILD_ROLE_ARN}   arn:aws:iam::${ACCOUNT_ID}:role/KubeMicroVMBuildRole
${OPERATOR_ROLE}    arn:aws:iam::${ACCOUNT_ID}:role/kube-microvm-operator
${NAMESPACE}        default
${OPERATOR_NS}      kube-microvm
${CHART_VERSION}    1.0.13-rc1
${CODEBASE_PATH}    /home/ubuntu/projects/microvm/KubeMicroVM
${TIMEOUT}          600s
${POLL_INTERVAL}    10s
# Shared image — built once by Quick Start, reused by all suites
${SHARED_IMAGE}     uat-shared-app
