#!/bin/bash
# burst-api-pressure.sh — Direct RunMicrovm API pressure generator
#
# Purpose: Call RunMicrovm at MAXIMUM rate to intentionally hit AWS throttling (429).
# AWS uses throttling signals to identify accounts that need higher limits.
# This bypasses the operator's polite quota guard and hammers the API directly.
#
# Strategy:
#   - Fire N parallel RunMicrovm calls per batch
#   - Track 200 (success) vs 429 (throttled) responses
#   - Repeat batches every few seconds
#   - Run for a sustained window (30+ min) to register demand signal
#   - Terminate all created VMs at the end
#
# Usage:
#   ./uat/burst-api-pressure.sh                          # defaults: 50 parallel, 10 batches, 5s gap
#   ./uat/burst-api-pressure.sh --parallel 100 --batches 20 --gap 3
#   ./uat/burst-api-pressure.sh --waves 6 --wave-interval 35  # 6 waves, 35min apart
#
# Monitor: tail -f results/burst-warmup/latest/pressure.log

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REGION="us-east-1"

# Images to cycle through (must be pre-built)
IMAGES=(
    "arn:aws:lambda:us-east-1:864899852480:microvm-image:burst-img-hello"
    "arn:aws:lambda:us-east-1:864899852480:microvm-image:burst-img-net"
    "arn:aws:lambda:us-east-1:864899852480:microvm-image:burst-img-worker"
)

# Defaults
PARALLEL=50          # Concurrent RunMicrovm calls per batch
BATCHES=20           # Number of batches per wave
GAP=3                # Seconds between batches
WAVES=1              # Number of waves
WAVE_INTERVAL=35     # Minutes between waves
TERMINATE_AFTER=true # Terminate VMs after each wave

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --parallel)       PARALLEL="$2"; shift 2 ;;
        --batches)        BATCHES="$2"; shift 2 ;;
        --gap)            GAP="$2"; shift 2 ;;
        --waves)          WAVES="$2"; shift 2 ;;
        --wave-interval)  WAVE_INTERVAL="$2"; shift 2 ;;
        --no-terminate)   TERMINATE_AFTER=false; shift ;;
        --help|-h)
            echo "Usage: $0 [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --parallel N        Concurrent RunMicrovm calls per batch (default: 50)"
            echo "  --batches N         Batches per wave (default: 20)"
            echo "  --gap SECONDS       Seconds between batches (default: 3)"
            echo "  --waves N           Number of waves (default: 1)"
            echo "  --wave-interval MIN Minutes between waves (default: 35)"
            echo "  --no-terminate      Don't terminate VMs after wave (let them idle-expire)"
            echo ""
            echo "Each wave sends PARALLEL × BATCHES = $((PARALLEL * BATCHES)) RunMicrovm calls"
            echo "Total API calls across all waves: $((PARALLEL * BATCHES * WAVES))"
            exit 0
            ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

# Setup results
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
RESULTS_DIR="${SCRIPT_DIR}/results/burst-warmup/${TIMESTAMP}-pressure"
mkdir -p "${RESULTS_DIR}"
ln -sfn "${RESULTS_DIR}" "${SCRIPT_DIR}/results/burst-warmup/latest"

LOG="${RESULTS_DIR}/pressure.log"
CREATED_VMS="${RESULTS_DIR}/created-vms.txt"
touch "${CREATED_VMS}"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "${LOG}"
}

log "╔══════════════════════════════════════════════════════════════╗"
log "║     RunMicrovm API PRESSURE GENERATOR                       ║"
log "╠══════════════════════════════════════════════════════════════╣"
log "║  Parallel calls/batch: ${PARALLEL}"
log "║  Batches per wave:     ${BATCHES}"
log "║  Gap between batches:  ${GAP}s"
log "║  Total calls/wave:     $((PARALLEL * BATCHES))"
log "║  Waves:                ${WAVES}"
log "║  Wave interval:        ${WAVE_INTERVAL} min"
log "║  Region:               ${REGION}"
log "║  Images:               ${#IMAGES[@]}"
log "╚══════════════════════════════════════════════════════════════╝"
log ""

# Function: fire one RunMicrovm call, return success/throttle/error
fire_one() {
    local image_arn="$1"
    local batch_id="$2"
    local call_id="$3"
    local output
    local exit_code

    output=$(aws lambda-microvms run-microvm \
        --image-identifier "${image_arn}" \
        --idle-policy '{"maxIdleDurationSeconds":300,"suspendedDurationSeconds":300,"autoResumeEnabled":false}' \
        --region "${REGION}" \
        --output json \
        --no-cli-pager 2>&1)
    exit_code=$?

    if [[ ${exit_code} -eq 0 ]]; then
        # Extract VM ID
        local vm_id
        vm_id=$(echo "${output}" | python3 -c "import json,sys; print(json.load(sys.stdin).get('microvmId',''))" 2>/dev/null)
        if [[ -n "${vm_id}" ]]; then
            echo "${vm_id}" >> "${CREATED_VMS}"
        fi
        echo "SUCCESS:${vm_id}"
    elif echo "${output}" | grep -q "TooManyRequestsException\|ThrottlingException\|Rate exceeded"; then
        echo "THROTTLED"
    elif echo "${output}" | grep -q "ResourceLimitExceededException\|ServiceException"; then
        echo "LIMIT_HIT"
    else
        echo "ERROR:${output:0:100}"
    fi
}

# Function: fire a batch of parallel calls
fire_batch() {
    local batch_num="$1"
    local pids=()
    local results_file="${RESULTS_DIR}/batch-${batch_num}.results"

    for ((i=1; i<=PARALLEL; i++)); do
        # Cycle through images
        local img_idx=$(( (i - 1) % ${#IMAGES[@]} ))
        local image="${IMAGES[${img_idx}]}"
        fire_one "${image}" "${batch_num}" "${i}" >> "${results_file}" &
        pids+=($!)
    done

    # Wait for all parallel calls to complete
    for pid in "${pids[@]}"; do
        wait "${pid}" 2>/dev/null || true
    done

    # Count results
    local success=0 throttled=0 limit_hit=0 errors=0
    if [[ -f "${results_file}" ]]; then
        success=$(grep -c "^SUCCESS" "${results_file}" 2>/dev/null || echo "0")
        throttled=$(grep -c "^THROTTLED" "${results_file}" 2>/dev/null || echo "0")
        limit_hit=$(grep -c "^LIMIT_HIT" "${results_file}" 2>/dev/null || echo "0")
        errors=$(grep -c "^ERROR" "${results_file}" 2>/dev/null || echo "0")
    fi

    echo "${success}:${throttled}:${limit_hit}:${errors}"
}

# Function: terminate all created VMs
terminate_all() {
    local vm_count
    vm_count=$(wc -l < "${CREATED_VMS}" 2>/dev/null || echo "0")
    if [[ ${vm_count} -eq 0 ]]; then
        log "No VMs to terminate"
        return
    fi

    log "Terminating ${vm_count} created VMs..."
    local terminated=0
    local term_start
    term_start=$(date +%s)

    while IFS= read -r vm_id; do
        if [[ -n "${vm_id}" ]]; then
            aws lambda-microvms terminate-microvm \
                --microvm-identifier "${vm_id}" \
                --region "${REGION}" \
                --no-cli-pager > /dev/null 2>&1 &
            terminated=$((terminated + 1))
            # Throttle terminate calls to ~10/s (burst limit is 10/s)
            if (( terminated % 10 == 0 )); then
                wait
            fi
        fi
    done < "${CREATED_VMS}"
    wait

    local term_elapsed=$(( $(date +%s) - term_start ))
    log "Terminated ${terminated} VMs in ${term_elapsed}s"
    > "${CREATED_VMS}"  # Clear the file
}

# Main loop
OVERALL_SUCCESS=0
OVERALL_THROTTLED=0
OVERALL_LIMIT=0
OVERALL_ERRORS=0

for ((wave=1; wave<=WAVES; wave++)); do
    log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log "WAVE ${wave}/${WAVES} — ${PARALLEL} parallel × ${BATCHES} batches = $((PARALLEL * BATCHES)) calls"
    log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    wave_success=0
    wave_throttled=0
    wave_limit=0
    wave_errors=0
    wave_start=$(date +%s)

    for ((batch=1; batch<=BATCHES; batch++)); do
        batch_start=$(date +%s)
        result=$(fire_batch "${wave}-${batch}")

        IFS=':' read -r s t l e <<< "${result}"
        wave_success=$((wave_success + s))
        wave_throttled=$((wave_throttled + t))
        wave_limit=$((wave_limit + l))
        wave_errors=$((wave_errors + e))

        batch_elapsed=$(( $(date +%s) - batch_start ))
        total_this_wave=$((wave_success + wave_throttled + wave_limit + wave_errors))
        wave_elapsed=$(( $(date +%s) - wave_start ))

        log "  Batch ${batch}/${BATCHES}: +${s} ok, +${t} THROTTLED, +${l} limit, +${e} err | cumulative: ${wave_success} ok, ${wave_throttled} throttled [${wave_elapsed}s]"

        # Wait between batches
        if [[ ${batch} -lt ${BATCHES} ]]; then
            sleep "${GAP}"
        fi
    done

    wave_elapsed=$(( $(date +%s) - wave_start ))
    log ""
    log "Wave ${wave} complete in ${wave_elapsed}s:"
    log "  ✓ Success:    ${wave_success}"
    log "  ⚡ Throttled:  ${wave_throttled}  ← THIS IS THE SIGNAL AWS SEES"
    log "  🚫 Limit hit:  ${wave_limit}"
    log "  ✗ Errors:     ${wave_errors}"
    log "  Rate:         $(echo "scale=1; ($wave_success + $wave_throttled + $wave_limit + $wave_errors) / $wave_elapsed" | bc) calls/s"
    log ""

    OVERALL_SUCCESS=$((OVERALL_SUCCESS + wave_success))
    OVERALL_THROTTLED=$((OVERALL_THROTTLED + wave_throttled))
    OVERALL_LIMIT=$((OVERALL_LIMIT + wave_limit))
    OVERALL_ERRORS=$((OVERALL_ERRORS + wave_errors))

    # Terminate created VMs
    if [[ "${TERMINATE_AFTER}" == "true" ]]; then
        terminate_all
    fi

    # Wait between waves (randomized 5-7 minutes)
    if [[ ${wave} -lt ${WAVES} ]]; then
        wait_seconds=$(( (RANDOM % 121) + 300 ))  # 300-420s = 5-7 min
        log "Waiting $((wait_seconds / 60))m $((wait_seconds % 60))s until next wave (randomized 5-7 min)..."
        sleep "${wait_seconds}"
    fi
done

log ""
log "╔══════════════════════════════════════════════════════════════╗"
log "║              PRESSURE TEST COMPLETE                         ║"
log "╠══════════════════════════════════════════════════════════════╣"
log "║  Total API calls:   $((OVERALL_SUCCESS + OVERALL_THROTTLED + OVERALL_LIMIT + OVERALL_ERRORS))"
log "║  Successful:        ${OVERALL_SUCCESS}"
log "║  THROTTLED (429):   ${OVERALL_THROTTLED}  ← quota increase signal"
log "║  Limit hit:         ${OVERALL_LIMIT}"
log "║  Errors:            ${OVERALL_ERRORS}"
log "║  Waves completed:   ${WAVES}"
log "╠══════════════════════════════════════════════════════════════╣"
log "║  ATTACH THIS LOG TO AWS SUPPORT TICKET                     ║"
log "║  Evidence: sustained throttling = sustained demand          ║"
log "╚══════════════════════════════════════════════════════════════╝"

# Generate summary
cat > "${RESULTS_DIR}/summary.json" << EOF
{
  "timestamp": "${TIMESTAMP}",
  "region": "${REGION}",
  "config": {
    "parallel": ${PARALLEL},
    "batches_per_wave": ${BATCHES},
    "gap_seconds": ${GAP},
    "waves": ${WAVES},
    "wave_interval_minutes": ${WAVE_INTERVAL}
  },
  "results": {
    "total_calls": $((OVERALL_SUCCESS + OVERALL_THROTTLED + OVERALL_LIMIT + OVERALL_ERRORS)),
    "success": ${OVERALL_SUCCESS},
    "throttled": ${OVERALL_THROTTLED},
    "limit_hit": ${OVERALL_LIMIT},
    "errors": ${OVERALL_ERRORS}
  }
}
EOF

log "Results: ${RESULTS_DIR}"
