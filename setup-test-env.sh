#!/usr/bin/env bash
# setup-test-env.sh — provision S3 bucket + IAM build role + upload test artifact
#
# Run once before testing kubectl microvm image commands.
# Safe to re-run — all resources are idempotent.
#
# Usage:
#   ./setup-test-env.sh
#   ./setup-test-env.sh --region us-east-1
#   ./setup-test-env.sh --bucket my-existing-bucket
#
set -euo pipefail

REGION="us-east-1"
BUCKET=""
ROLE_NAME="KubeMicroVMBuildRole"
FIXTURE_DIR="$(cd "$(dirname "$0")/uat/fixtures/microvm-hello-node" && pwd)"

while [[ $# -gt 0 ]]; do
  case $1 in
    --region)  REGION="$2";  shift ;;
    --bucket)  BUCKET="$2";  shift ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
  shift
done

ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
[[ -n "$BUCKET" ]] || BUCKET="kube-microvm-test-${ACCOUNT}-${REGION}"
S3_KEY="uat/fixtures/microvm-hello-node.zip"

echo "==> Setup KubeMicroVM test environment"
echo "    account : ${ACCOUNT}"
echo "    region  : ${REGION}"
echo "    bucket  : ${BUCKET}"
echo "    role    : ${ROLE_NAME}"
echo ""

# 1. S3 bucket
echo "--- [1] S3 bucket"
if aws s3api head-bucket --bucket "${BUCKET}" 2>/dev/null; then
  echo "    ${BUCKET} already exists"
else
  if [[ "${REGION}" == "us-east-1" ]]; then
    aws s3api create-bucket --bucket "${BUCKET}" --region "${REGION}"
  else
    aws s3api create-bucket --bucket "${BUCKET}" --region "${REGION}" \
      --create-bucket-configuration LocationConstraint="${REGION}"
  fi
  echo "    Created s3://${BUCKET}"
fi

# Block public access
aws s3api put-public-access-block --bucket "${BUCKET}" \
  --public-access-block-configuration "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"

# 2. IAM build role
echo "--- [2] IAM build role"
TRUST_POLICY='{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": { "Service": "lambda.amazonaws.com" },
    "Action": ["sts:AssumeRole", "sts:TagSession"]
  }]
}'

PERMISSIONS_POLICY="{
  \"Version\": \"2012-10-17\",
  \"Statement\": [
    {
      \"Effect\": \"Allow\",
      \"Action\": [\"s3:GetObject\"],
      \"Resource\": \"arn:aws:s3:::${BUCKET}/*\"
    },
    {
      \"Effect\": \"Allow\",
      \"Action\": [\"logs:CreateLogGroup\", \"logs:CreateLogStream\", \"logs:PutLogEvents\"],
      \"Resource\": \"arn:aws:logs:${REGION}:${ACCOUNT}:log-group:/aws/lambda/microvms/*\"
    }
  ]
}"

if aws iam get-role --role-name "${ROLE_NAME}" &>/dev/null; then
  echo "    ${ROLE_NAME} already exists"
  ROLE_ARN=$(aws iam get-role --role-name "${ROLE_NAME}" --query 'Role.Arn' --output text)
else
  ROLE_ARN=$(aws iam create-role \
    --role-name "${ROLE_NAME}" \
    --assume-role-policy-document "${TRUST_POLICY}" \
    --description "Lambda MicroVM image build role - grants S3 read + CloudWatch write" \
    --query 'Role.Arn' --output text)
  echo "    Created ${ROLE_ARN}"
fi

aws iam put-role-policy \
  --role-name "${ROLE_NAME}" \
  --policy-name "KubeMicroVMBuildPolicy" \
  --policy-document "${PERMISSIONS_POLICY}"
echo "    Policy attached"

# 3. Package and upload test artifact
echo "--- [3] Upload test artifact"
TMP_ZIP=$(mktemp /tmp/microvm-test-XXXXX)
(cd "${FIXTURE_DIR}" && zip -j "${TMP_ZIP}.zip" Dockerfile app.js)
TMP_ZIP="${TMP_ZIP}.zip"
aws s3 cp "${TMP_ZIP}" "s3://${BUCKET}/${S3_KEY}" --region "${REGION}"
rm -f "${TMP_ZIP}"
echo "    Uploaded s3://${BUCKET}/${S3_KEY}"

# 4. Print ready-to-use commands
BASE_IMAGE_ARN="arn:aws:lambda:${REGION}:aws:microvm-image:al2023-1"

echo ""
echo "==> Setup complete. Test commands:"
echo ""
echo "  # Create image via kubectl plugin:"
echo "  kubectl microvm image create \\"
echo "    --name hello-node \\"
echo "    --s3-bucket ${BUCKET} \\"
echo "    --s3-key ${S3_KEY} \\"
echo "    --base-image ${BASE_IMAGE_ARN} \\"
echo "    --build-role-arn ${ROLE_ARN} \\"
echo "    --wait"
echo ""
echo "  # Or via AWS CLI directly:"
echo "  aws lambda-microvms create-microvm-image \\"
echo "    --name hello-node-direct \\"
echo "    --code-artifact uri=s3://${BUCKET}/${S3_KEY} \\"
echo "    --base-image-arn ${BASE_IMAGE_ARN} \\"
echo "    --build-role-arn ${ROLE_ARN} \\"
echo "    --region ${REGION}"
echo ""
echo "  Build role ARN: ${ROLE_ARN}"

# Write env file for test-image.sh
cat > "$(dirname "$0")/.test-env" <<ENV
BUCKET="${BUCKET}"
ROLE_ARN="${ROLE_ARN}"
REGION="${REGION}"
S3_KEY="${S3_KEY}"
BASE_IMAGE_ARN="${BASE_IMAGE_ARN}"
ENV
echo "  Env saved to .test-env (used by test-image.sh)"
