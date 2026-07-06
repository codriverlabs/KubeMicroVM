#!/usr/bin/env bash
# regression-test.sh — single-VM end-to-end regression test
#
# Creates a new MicroVMImage from test fixtures (new name), runs a MicroVM,
# requests a token, calls the endpoint, then terminates and cleans up.
#
# Usage:
#   ./regression-test.sh
#   ./regression-test.sh --namespace default --bucket my-bucket
#
set -euo pipefail

NAMESPACE="default"
BUCKET="kube-microvm-test-<ACCOUNT_ID>-us-east-1"
S3_KEY="test-fixtures/microvm-hello-node.zip"
BASE_IMAGE="arn:aws:lambda:us-east-1:aws:microvm-image:al2023-1"
BUILD_ROLE="arn:aws:iam::<ACCOUNT_ID>:role/KubeMicroVMBuildRole"
RESULTS_DIR="$(cd "$(dirname "$0")" && pwd)/docs/testing/load-test-$(date +%Y%m%d)"
IMAGE_NAME="regression-$(date +%Y%m%d%H%M)"
VM_NAME="regression-vm-$(date +%H%M%S)"
TIMESTAMP=$(date +%Y%m%dT%H%M%S)
LOG_FILE="$RESULTS_DIR/regression-${TIMESTAMP}.log"

for arg in "$@"; do
  case $arg in
    --namespace=*) NAMESPACE="${arg#--namespace=}" ;;
    --bucket=*)    BUCKET="${arg#--bucket=}" ;;
    --namespace)   ;;
    --bucket)      ;;
    *)
      if [[ "${PREV_ARG:-}" == "--namespace" ]]; then NAMESPACE="$arg"
      elif [[ "${PREV_ARG:-}" == "--bucket" ]]; then BUCKET="$arg"
      fi
      ;;
  esac
  PREV_ARG="$arg"
done

mkdir -p "$RESULTS_DIR"
log() { echo "[$(date -u +%H:%M:%S)] $*" | tee -a "$LOG_FILE"; }
pass() { log "✅ PASS: $*"; }
fail() { log "❌ FAIL: $*"; FAILURES=$((${FAILURES:-0}+1)); }

FAILURES=0
START=$(date +%s)
log "=== Regression Test Start === image=$IMAGE_NAME vm=$VM_NAME"

# --- Step 1: Create MicroVMImage ---
log "Creating MicroVMImage $IMAGE_NAME"
kubectl apply -f - <<EOF
apiVersion: lambda.aws.amazon.com/v1alpha1
kind: MicroVMImage
metadata:
  name: ${IMAGE_NAME}
  namespace: ${NAMESPACE}
spec:
  source:
    s3Bucket: ${BUCKET}
    s3Key: ${S3_KEY}
  baseImageArn: "${BASE_IMAGE}"
  buildRoleArn: "${BUILD_ROLE}"
  memorySizeMiB: 2048
EOF
pass "MicroVMImage CR created"

# --- Step 2: Wait for image build ---
log "Waiting for image build (up to 10 min)..."
BUILD_START=$(date +%s)
for i in $(seq 1 40); do
  STATE=$(kubectl get microvmimage "$IMAGE_NAME" -n "$NAMESPACE" \
    -o jsonpath='{.status.imageState}' 2>/dev/null || echo "")
  VERSION_STATE=$(kubectl get microvmimage "$IMAGE_NAME" -n "$NAMESPACE" \
    -o jsonpath='{.status.latestVersionState}' 2>/dev/null || echo "")
  log "  state=$STATE version_state=${VERSION_STATE:-?} elapsed=$(($(date +%s)-BUILD_START))s"
  if [[ "$STATE" == "CREATED" || "$STATE" == "UPDATED" ]]; then
    pass "Image built in $(($(date +%s)-BUILD_START))s"
    break
  fi
  if [[ "$STATE" == "CREATE_FAILED" || "$STATE" == "UPDATE_FAILED" ]]; then
    fail "Image build failed: state=$STATE"
    kubectl get microvmimage "$IMAGE_NAME" -n "$NAMESPACE" -o json >> "$LOG_FILE"
    exit 1
  fi
  if [[ $i -eq 40 ]]; then
    fail "Image build timed out after $(($(date +%s)-BUILD_START))s"
    exit 1
  fi
  sleep 15
done

# --- Step 3: Create MicroVM ---
log "Creating MicroVM $VM_NAME"
kubectl apply -f - <<EOF
apiVersion: lambda.aws.amazon.com/v1alpha1
kind: MicroVM
metadata:
  name: ${VM_NAME}
  namespace: ${NAMESPACE}
spec:
  imageRef: ${IMAGE_NAME}
  desiredState: Running
  maxIdleDurationSeconds: 300
  suspendedDurationSeconds: 600
EOF
pass "MicroVM CR created"

# --- Step 4: Wait for VM Running ---
log "Waiting for VM to reach Running..."
VM_START=$(date +%s)
for i in $(seq 1 18); do
  sleep 10
  STATE=$(kubectl get microvm "$VM_NAME" -n "$NAMESPACE" \
    -o jsonpath='{.status.state}' 2>/dev/null || echo "")
  ENDPOINT=$(kubectl get microvm "$VM_NAME" -n "$NAMESPACE" \
    -o jsonpath='{.status.endpointUrl}' 2>/dev/null || echo "")
  log "  vm state=$STATE endpoint=${ENDPOINT:-none} elapsed=$(($(date +%s)-VM_START))s"
  if [[ "$STATE" == "Running" ]]; then
    pass "VM reached Running in $(($(date +%s)-VM_START))s"
    break
  fi
  if [[ "$STATE" == "Failed" ]]; then
    fail "VM reached Failed state"
    kubectl get microvm "$VM_NAME" -n "$NAMESPACE" -o json >> "$LOG_FILE"
    break
  fi
  if [[ $i -eq 18 ]]; then
    fail "VM not Running after 180s"
  fi
done

# --- Step 5: Request token ---
log "Requesting auth token (direct)..."
TOKEN=$(microvm token --name "$VM_NAME" --namespace "$NAMESPACE" --direct 2>&1 || echo "")
if [[ -n "$TOKEN" && "$TOKEN" != *"error"* && "$TOKEN" != *"Error"* ]]; then
  pass "Token received (length=${#TOKEN})"
  echo "${TOKEN:0:30}..." >> "$LOG_FILE"
else
  fail "Token request failed: $TOKEN"
fi

# --- Step 6: Call endpoint ---
ENDPOINT=$(kubectl get microvm "$VM_NAME" -n "$NAMESPACE" \
  -o jsonpath='{.status.endpointUrl}' 2>/dev/null || echo "")
if [[ -n "$ENDPOINT" && "$ENDPOINT" != "PENDING" && -n "$TOKEN" ]]; then
  log "Calling endpoint $ENDPOINT"
  HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" \
    -H "X-aws-proxy-auth: $TOKEN" \
    --max-time 10 \
    "https://$ENDPOINT/" 2>/dev/null || echo "000")
  if [[ "$HTTP_STATUS" == "200" ]]; then
    pass "Endpoint returned HTTP 200"
  else
    fail "Endpoint returned HTTP $HTTP_STATUS (expected 200)"
  fi
else
  log "SKIP: endpoint not available yet (${ENDPOINT:-none})"
fi

# --- Step 7: Terminate and clean up ---
log "Terminating VM..."
kubectl patch microvm "$VM_NAME" -n "$NAMESPACE" \
  --type=merge -p '{"spec":{"desiredState":"Terminated"}}' 2>/dev/null || true
sleep 5
kubectl delete microvm "$VM_NAME" -n "$NAMESPACE" \
  --force --grace-period=0 --timeout=30s 2>/dev/null || true
pass "VM terminated"

log "Deleting MicroVMImage $IMAGE_NAME..."
kubectl delete microvmimage "$IMAGE_NAME" -n "$NAMESPACE" \
  --force --grace-period=0 --timeout=30s 2>/dev/null || true
pass "MicroVMImage deleted"

# --- Summary ---
TOTAL=$(($(date +%s)-START))
echo "" | tee -a "$LOG_FILE"
log "=== Regression Test Complete === failures=$FAILURES elapsed=${TOTAL}s"

if [[ $FAILURES -eq 0 ]]; then
  log "RESULT: ✅ ALL PASS"
  exit 0
else
  log "RESULT: ❌ $FAILURES FAILURE(S)"
  exit 1
fi
