#!/bin/bash
# run-burst-warmup.sh — Repeated burst scale test to warm up AWS quota
#
# Purpose: Run the burst quota warmup test in a loop, generating sustained
# RunMicrovm API pressure every N minutes. This demonstrates consistent
# high-throughput demand to trigger AWS's automatic quota increase.
#
# Usage:
#   ./uat/run-burst-warmup.sh                    # 6 waves, 35 min apart
#   ./uat/run-burst-warmup.sh --waves 10         # 10 waves
#   ./uat/run-burst-warmup.sh --interval 40      # 40 min between waves
#   ./uat/run-burst-warmup.sh --waves 12 --interval 30  # 12 waves, 30 min apart
#
# Each wave:
#   1. Creates 3 ReplicaSets × 500 = 1500 RunMicrovm API calls
#   2. Observes for ~10 minutes (recording throughput + max concurrent)
#   3. Drains all VMs
#   4. Waits until the next interval
#
# Results stored in: uat/results/burst-warmup/<timestamp>/wave-N/
#
# Monitor progress:
#   tail -f uat/results/burst-warmup/latest/progress.log

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UAT_DIR="${SCRIPT_DIR}"
PROJECT_DIR="$(dirname "$UAT_DIR")"

# Defaults
WAVES=6
INTERVAL_MINUTES=35

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --waves)    WAVES="$2"; shift 2 ;;
        --interval) INTERVAL_MINUTES="$2"; shift 2 ;;
        --help|-h)
            echo "Usage: $0 [--waves N] [--interval MINUTES]"
            echo ""
            echo "Options:"
            echo "  --waves N        Number of burst waves to run (default: 6)"
            echo "  --interval MIN   Minutes between wave starts (default: 35)"
            echo ""
            echo "Total runtime: ~$((WAVES * INTERVAL_MINUTES)) minutes"
            exit 0
            ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

# Setup results directory
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
RESULTS_DIR="${UAT_DIR}/results/burst-warmup/${TIMESTAMP}"
mkdir -p "${RESULTS_DIR}"
# Symlink for easy access
ln -sfn "${RESULTS_DIR}" "${UAT_DIR}/results/burst-warmup/latest"

PROGRESS_LOG="${RESULTS_DIR}/progress.log"

log() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $*"
    echo "$msg" | tee -a "${PROGRESS_LOG}"
}

log "╔══════════════════════════════════════════════════════════════╗"
log "║        BURST QUOTA WARMUP — SUSTAINED LOAD GENERATOR        ║"
log "╠══════════════════════════════════════════════════════════════╣"
log "║  Waves:         ${WAVES}"
log "║  Interval:      ${INTERVAL_MINUTES} minutes"
log "║  Total runtime: ~$((WAVES * INTERVAL_MINUTES)) minutes"
log "║  Results:       ${RESULTS_DIR}"
log "║  Started:       $(date)"
log "╚══════════════════════════════════════════════════════════════╝"
log ""

# Pre-flight check
log "Pre-flight: verifying operator is running..."
READY=$(kubectl get deploy kube-microvm-operator -n kube-microvm -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
if [[ "${READY}" != "1" ]]; then
    log "ERROR: Operator not running (readyReplicas=${READY}). Deploy first."
    exit 1
fi
log "Pre-flight: operator ready ✓"

# Verify images are built (first wave will build them if needed via Suite Setup)
log ""

TOTAL_VMS_CREATED=0
PEAK_CONCURRENT_OVERALL=0

for ((wave=1; wave<=WAVES; wave++)); do
    WAVE_DIR="${RESULTS_DIR}/wave-${wave}"
    mkdir -p "${WAVE_DIR}"

    log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log "WAVE ${wave}/${WAVES} — starting at $(date '+%H:%M:%S')"
    log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    WAVE_START=$(date +%s)

    # Run the burst test
    cd "${UAT_DIR}"
    robot --outputdir "${WAVE_DIR}" \
          --loglevel INFO \
          --variable RUN_ID:"wave${wave}-$(date +%H%M%S)" \
          -i burst \
          tests/10_burst_quota_warmup.robot \
          2>&1 | tee "${WAVE_DIR}/robot-output.txt" || true

    WAVE_END=$(date +%s)
    WAVE_DURATION=$(( WAVE_END - WAVE_START ))

    # Extract metrics from robot output (best effort)
    MAX_CONCURRENT=$(grep -oP 'max_concurrent=\K[0-9]+' "${WAVE_DIR}/robot-output.txt" 2>/dev/null | tail -1 || echo "?")
    PEAK_RATE=$(grep -oP 'peak_rate=\K[0-9.]+' "${WAVE_DIR}/robot-output.txt" 2>/dev/null | tail -1 || echo "?")

    if [[ "${MAX_CONCURRENT}" =~ ^[0-9]+$ ]] && [[ ${MAX_CONCURRENT} -gt ${PEAK_CONCURRENT_OVERALL} ]]; then
        PEAK_CONCURRENT_OVERALL=${MAX_CONCURRENT}
    fi

    log "Wave ${wave} complete: duration=${WAVE_DURATION}s max_concurrent=${MAX_CONCURRENT} peak_rate=${PEAK_RATE}/s"
    log ""

    # Wait for next interval (unless this is the last wave)
    if [[ ${wave} -lt ${WAVES} ]]; then
        INTERVAL_SECONDS=$((INTERVAL_MINUTES * 60))
        WAIT_REMAINING=$((INTERVAL_SECONDS - WAVE_DURATION))
        if [[ ${WAIT_REMAINING} -gt 0 ]]; then
            log "Waiting ${WAIT_REMAINING}s until next wave (interval=${INTERVAL_MINUTES}min)..."
            log "Next wave at: $(date -d "+${WAIT_REMAINING} seconds" '+%H:%M:%S')"
            sleep "${WAIT_REMAINING}"
        else
            log "Wave took longer than interval — starting next immediately"
        fi
    fi
done

log ""
log "╔══════════════════════════════════════════════════════════════╗"
log "║              BURST WARMUP COMPLETE                          ║"
log "╠══════════════════════════════════════════════════════════════╣"
log "║  Total waves completed:    ${WAVES}"
log "║  Peak concurrent (overall): ${PEAK_CONCURRENT_OVERALL}"
log "║  Results directory:         ${RESULTS_DIR}"
log "║  Finished at:               $(date)"
log "╠══════════════════════════════════════════════════════════════╣"
log "║  NEXT STEPS:                                                ║"
log "║  1. Check results for throughput improvement across waves   ║"
log "║  2. If throughput increased → quota is warming up           ║"
log "║  3. Attach progress.log to AWS support ticket               ║"
log "║  4. Run again in 24h if no improvement observed             ║"
log "╚══════════════════════════════════════════════════════════════╝"

# Generate summary CSV for easy comparison
SUMMARY_CSV="${RESULTS_DIR}/summary.csv"
echo "wave,max_concurrent,peak_rate_vms_per_sec,duration_sec" > "${SUMMARY_CSV}"
for ((w=1; w<=WAVES; w++)); do
    WDIR="${RESULTS_DIR}/wave-${w}"
    if [[ -f "${WDIR}/robot-output.txt" ]]; then
        mc=$(grep -oP 'max_concurrent=\K[0-9]+' "${WDIR}/robot-output.txt" 2>/dev/null | tail -1 || echo "0")
        pr=$(grep -oP 'peak_rate=\K[0-9.]+' "${WDIR}/robot-output.txt" 2>/dev/null | tail -1 || echo "0")
        dur=$(grep -oP 'duration=\K[0-9]+' "${WDIR}/robot-output.txt" 2>/dev/null | tail -1 || echo "0")
        echo "${w},${mc},${pr},${dur}" >> "${SUMMARY_CSV}"
    fi
done
log "Summary CSV: ${SUMMARY_CSV}"
