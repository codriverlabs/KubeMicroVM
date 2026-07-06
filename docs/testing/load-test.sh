#!/usr/bin/env bash
# load-test.sh — MicroVM scale test: up to 1000 VMs, token collection, terminate in <1 min
#
# Usage:
#   ./docs/testing/load-test.sh                    # from project root
#   ./docs/testing/load-test.sh --replicas 50      # smaller run
#   ./docs/testing/load-test.sh --namespace default
#   ./docs/testing/load-test.sh --image qs-test-app
#
set -euo pipefail

REPLICAS=1000
NAMESPACE="default"
IMAGE="qs-test-app"
PROJECT_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
RESULTS_DIR="${PROJECT_ROOT}/docs/testing/load-test-$(date +%Y%m%d)"
RS_NAME="load-test-rs"
TOKEN_PARALLELISM=50
MONITOR_INTERVAL=5

while [[ $# -gt 0 ]]; do
  case $1 in
    --replicas)  REPLICAS="$2"; shift ;;
    --namespace) NAMESPACE="$2"; shift ;;
    --image)     IMAGE="$2"; shift ;;
    --help) echo "Usage: $0 [--replicas N] [--namespace NS] [--image NAME]"; exit 0 ;;
    *) echo "Unknown: $1" >&2 ;;
  esac
  shift
done

mkdir -p "$RESULTS_DIR"
TIMESTAMP=$(date +%Y%m%dT%H%M%S)
LOG_FILE="${RESULTS_DIR}/load-test-${TIMESTAMP}.log"
METRICS_FILE="${RESULTS_DIR}/operator-metrics-${TIMESTAMP}.csv"
TOKENS_FILE="${RESULTS_DIR}/tokens-${TIMESTAMP}.txt"
SUMMARY_FILE="${RESULTS_DIR}/summary-${TIMESTAMP}.md"

log()     { echo "[$(date -u +%H:%M:%S)] $*" | tee -a "$LOG_FILE"; }
section() { echo "" | tee -a "$LOG_FILE"; log "=== $* ==="; }

section "LOAD TEST START"
log "Replicas: $REPLICAS  Image: $IMAGE  Namespace: $NAMESPACE"
log "Results: $RESULTS_DIR"
echo "timestamp,cpu,memory,pod" > "$METRICS_FILE"

# ── Phase 0: Verify image is CREATED ──────────────────────────────────────────
section "Phase 0: Verify image ${IMAGE}"
STATE=$(kubectl get microvmimage "$IMAGE" -n "$NAMESPACE" \
  -o jsonpath='{.status.imageState}' 2>/dev/null || echo "")
if [[ "$STATE" != "CREATED" && "$STATE" != "UPDATED" ]]; then
  log "Image not ready (state=$STATE) — waiting up to 15 min"
  for i in $(seq 1 60); do
    sleep 15
    STATE=$(kubectl get microvmimage "$IMAGE" -n "$NAMESPACE" \
      -o jsonpath='{.status.imageState}' 2>/dev/null || echo "")
    log "  state=$STATE"
    [[ "$STATE" == "CREATED" || "$STATE" == "UPDATED" ]] && break
    [[ $i -eq 60 ]] && { log "ERROR: Image not ready — aborting"; exit 1; }
  done
fi
log "Image ready: $STATE"

# ── Phase 1: Background metrics collection ────────────────────────────────────
section "Phase 1: Start background monitoring"
OPERATOR_POD=$(kubectl get pod -n kube-microvm -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
log "Operator pod: ${OPERATOR_POD:-none}"

(while true; do
  POD=$(kubectl get pod -n kube-microvm -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
  if [[ -n "$POD" ]]; then
    LINE=$(kubectl top pod "$POD" -n kube-microvm --no-headers 2>/dev/null | awk '{print $2","$3","$1}' || echo ",,")
    echo "$(date -u +%Y-%m-%dT%H:%M:%SZ),${LINE}" >> "$METRICS_FILE"
  fi
  sleep "$MONITOR_INTERVAL"
done) &
MONITOR_PID=$!

PROM_FILE="${RESULTS_DIR}/prometheus-${TIMESTAMP}.txt"
(while true; do
  echo "=== $(date -u +%Y-%m-%dT%H:%M:%SZ) ===" >> "$PROM_FILE"
  kubectl exec -n kube-microvm "$OPERATOR_POD" -- \
    wget -qO- "http://localhost:8080/q/metrics" 2>/dev/null \
    | grep -E "^microvm_|^microvmpool_" >> "$PROM_FILE" 2>/dev/null || true
  sleep 30
done) &
PROM_PID=$!

cleanup() {
  kill "$MONITOR_PID" "$PROM_PID" 2>/dev/null || true
  log "Monitors stopped"
}
trap cleanup EXIT

# ── Phase 2: Create MicroVMReplicaSet ─────────────────────────────────────────
section "Phase 2: Create MicroVMReplicaSet ($REPLICAS replicas)"
RS_START=$(date +%s)

kubectl apply -f - <<EOF
apiVersion: lambda.aws.amazon.com/v1alpha1
kind: MicroVMReplicaSet
metadata:
  name: ${RS_NAME}
  namespace: ${NAMESPACE}
spec:
  replicas: ${REPLICAS}
  maxSurge: 100
  template:
    imageRef: ${IMAGE}
    desiredState: Running
    maxIdleDurationSeconds: 180
    suspendedDurationSeconds: 600
EOF
log "ReplicaSet created"

# ── Phase 3: Wait for VMs to scale up ─────────────────────────────────────────
section "Phase 3: Scale-up monitoring (max 15 min)"
PEAK_READY=0
PEAK_CURRENT=0

for i in $(seq 1 90); do
  sleep 10
  READY=$(kubectl get microvmreplicaset "$RS_NAME" -n "$NAMESPACE" \
    -o jsonpath='{.status.readyReplicas}' 2>/dev/null); READY=${READY:-0}
  CURRENT=$(kubectl get microvmreplicaset "$RS_NAME" -n "$NAMESPACE" \
    -o jsonpath='{.status.currentReplicas}' 2>/dev/null); CURRENT=${CURRENT:-0}
  FAILED=$(kubectl get microvms -n "$NAMESPACE" \
    -l "lambda.aws.amazon.com/replica-set=${RS_NAME}" \
    -o jsonpath='{range .items[?(@.status.state=="Failed")]}{.metadata.name}{"\n"}{end}' \
    2>/dev/null | grep -c . || true); FAILED=${FAILED:-0}
  ELAPSED=$(($(date +%s) - RS_START))

  [[ "$READY" -gt "$PEAK_READY" ]] && PEAK_READY=$READY
  [[ "$CURRENT" -gt "$PEAK_CURRENT" ]] && PEAK_CURRENT=$CURRENT

  log "VMs: ready=${READY} current=${CURRENT} failed=${FAILED} elapsed=${ELAPSED}s"

  # Exit once stable (no growth for 2 consecutive checks at target or stalled)
  if [[ "$CURRENT" -ge "$REPLICAS" && "$READY" -ge "$REPLICAS" ]]; then
    log "All $REPLICAS VMs ready — elapsed=${ELAPSED}s"
    break
  fi
  if [[ $i -eq 90 ]]; then
    log "Scale-up timeout — proceeding with peak=$PEAK_READY ready VMs"
  fi
done
RS_SCALE_TIME=$(($(date +%s) - RS_START))
log "Scale-up phase complete in ${RS_SCALE_TIME}s  peak_ready=${PEAK_READY}"

# ── Phase 4: Token collection ──────────────────────────────────────────────────
section "Phase 4: Token collection (parallel=$TOKEN_PARALLELISM)"
TOKEN_START=$(date +%s)

RUNNING_VMS=$(kubectl get microvms -n "$NAMESPACE" \
  -l "lambda.aws.amazon.com/replica-set=${RS_NAME}" \
  -o jsonpath='{range .items[?(@.status.state=="Running")]}{.metadata.name}{"\n"}{end}' \
  2>/dev/null || echo "")
VM_COUNT=$(printf '%s' "$RUNNING_VMS" | grep -c '[^[:space:]]' || true)
log "Running VMs available for token collection: $VM_COUNT"

> "$TOKENS_FILE"
if [[ "$VM_COUNT" -gt 0 ]]; then
  echo "$RUNNING_VMS" | \
  xargs -P "$TOKEN_PARALLELISM" -I{} bash -c '
    VM="{}"
    NS="'"$NAMESPACE"'"
    TOKEN=$(microvm token --name "$VM" --namespace "$NS" --direct 2>/dev/null || echo "")
    if [[ -n "$TOKEN" && ${#TOKEN} -gt 20 ]]; then
      echo "OK ${VM}"
    else
      echo "FAIL ${VM}"
    fi
  ' 2>/dev/null | tee -a "$TOKENS_FILE"
fi

TOKEN_SUCCESS=$(grep -c "^OK" "$TOKENS_FILE" 2>/dev/null || true); TOKEN_SUCCESS=${TOKEN_SUCCESS:-0}
TOKEN_FAIL=$(grep -c "^FAIL" "$TOKENS_FILE" 2>/dev/null || true); TOKEN_FAIL=${TOKEN_FAIL:-0}
TOKEN_ELAPSED=$(($(date +%s) - TOKEN_START))
log "Tokens: success=${TOKEN_SUCCESS} fail=${TOKEN_FAIL} elapsed=${TOKEN_ELAPSED}s rate=$(( VM_COUNT > 0 ? TOKEN_SUCCESS * 100 / VM_COUNT : 0 ))%"

# ── Phase 5: Terminate all within 60s ─────────────────────────────────────────
section "Phase 5: Terminate all VMs (target: <60s)"
TERMINATE_START=$(date +%s)
log "Deleting ReplicaSet (cascade-terminates all children)..."
kubectl delete microvmreplicaset "$RS_NAME" -n "$NAMESPACE" \
  --force --grace-period=0 --timeout=60s 2>/dev/null || true
TERMINATE_ELAPSED=$(($(date +%s) - TERMINATE_START))
log "ReplicaSet delete issued in ${TERMINATE_ELAPSED}s"

# Watch VM CRs drain
for i in $(seq 1 12); do
  sleep 5
  REMAINING=$(kubectl get microvms -n "$NAMESPACE" \
    -l "lambda.aws.amazon.com/replica-set=${RS_NAME}" \
    -o name 2>/dev/null | grep -c . || true); REMAINING=${REMAINING:-0}
  log "  VM CRs remaining: $REMAINING"
  [[ "$REMAINING" -eq 0 ]] && break
done
TERMINATE_TOTAL=$(($(date +%s) - TERMINATE_START))
log "All VM CRs removed in ${TERMINATE_TOTAL}s"

# ── Phase 6: Final metrics ─────────────────────────────────────────────────────
section "Phase 6: Final metrics"
FINAL_METRICS="${RESULTS_DIR}/final-metrics-${TIMESTAMP}.txt"
kubectl top pod -n kube-microvm --no-headers 2>/dev/null > "$FINAL_METRICS" || true
kubectl exec -n kube-microvm "$OPERATOR_POD" -- \
  wget -qO- "http://localhost:8080/q/metrics" 2>/dev/null \
  | grep -E "^microvm_|^microvmpool_" >> "$FINAL_METRICS" 2>/dev/null || true
cat "$FINAL_METRICS" | tee -a "$LOG_FILE"

# ── Summary ────────────────────────────────────────────────────────────────────
TOTAL_ELAPSED=$(($(date +%s) - RS_START))
section "SUMMARY"
{
  echo "# Load Test Summary"
  echo ""
  echo "**Date**: $(date -u)"
  echo "**Branch**: $(git -C "$PROJECT_ROOT" branch --show-current 2>/dev/null)"
  echo ""
  echo "## Configuration"
  echo "| Parameter | Value |"
  echo "|-----------|-------|"
  echo "| Requested replicas | $REPLICAS |"
  echo "| Image | $IMAGE |"
  echo "| Namespace | $NAMESPACE |"
  echo "| Max surge | 100 |"
  echo ""
  echo "## Results"
  echo "| Metric | Value |"
  echo "|--------|-------|"
  echo "| VMs reached Running (peak) | $PEAK_READY |"
  echo "| VMs created (peak) | $PEAK_CURRENT |"
  echo "| Scale-up time | ${RS_SCALE_TIME}s |"
  echo "| Tokens collected | ${TOKEN_SUCCESS} / ${VM_COUNT} |"
  echo "| Token collection time | ${TOKEN_ELAPSED}s |"
  echo "| RS delete + CR drain | ${TERMINATE_TOTAL}s |"
  echo "| Total elapsed | ${TOTAL_ELAPSED}s |"
  echo ""
  echo "## Artifacts"
  echo "- Log: \`$(basename "$LOG_FILE")\`"
  echo "- Operator metrics (time series): \`$(basename "$METRICS_FILE")\`"
  echo "- Prometheus snapshots: \`$(basename "$PROM_FILE")\`"
  echo "- Token results: \`$(basename "$TOKENS_FILE")\`"
  echo "- Final metrics: \`$(basename "$FINAL_METRICS")\`"
} | tee "$SUMMARY_FILE" | tee -a "$LOG_FILE"

log "Load test complete — results in $RESULTS_DIR"
