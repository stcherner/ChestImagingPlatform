#!/usr/bin/env bash
# run_vessel_batch.sh — CIP vessel pipeline batch orchestrator
# Usage: run_vessel_batch.sh <data_dir>
#            --parallel N --cores-per-job N
#            [--runs N] [--region REGION] [--cleanup none|light|all]
#            [--stage-to /path] [--output-base /path]
set -euo pipefail

# ── Environment (source once; workers inherit exports) ────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/env.sh"
export PATH CIP_PATH TEEM_PATH ITKTOOLS_PATH PYTHONPATH

# ── CLI parsing ───────────────────────────────────────────────────────────────
DATA_DIR="${1:?Usage: $0 <data_dir> --parallel N --cores-per-job N [options]}"
shift

MAX_PARALLEL=1
CORES=4
RUNS=1
REGION="WholeLung"
CLEANUP="light"
STAGE_TO=""
OUTPUT_BASE="$HOME/cip_build/runs/batch_$(date +%Y%m%d_%H%M%S)"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --parallel)      [[ $# -ge 2 ]] || { echo "ERROR: --parallel requires a value" >&2; exit 1; }; MAX_PARALLEL="$2"; shift 2 ;;
        --cores-per-job) [[ $# -ge 2 ]] || { echo "ERROR: --cores-per-job requires a value" >&2; exit 1; }; CORES="$2";       shift 2 ;;
        --runs)          [[ $# -ge 2 ]] || { echo "ERROR: --runs requires a value" >&2; exit 1; }; RUNS="$2";         shift 2 ;;
        --region)        [[ $# -ge 2 ]] || { echo "ERROR: --region requires a value" >&2; exit 1; }; REGION="$2";       shift 2 ;;
        --cleanup)       [[ $# -ge 2 ]] || { echo "ERROR: --cleanup requires a value" >&2; exit 1; }; CLEANUP="$2";      shift 2 ;;
        --stage-to)      [[ $# -ge 2 ]] || { echo "ERROR: --stage-to requires a value" >&2; exit 1; }; STAGE_TO="$2";     shift 2 ;;
        --output-base)   [[ $# -ge 2 ]] || { echo "ERROR: --output-base requires a value" >&2; exit 1; }; OUTPUT_BASE="$2";  shift 2 ;;
        *) echo "Unknown argument: $1" >&2; exit 1 ;;
    esac
done

LOG_DIR="$OUTPUT_BASE/logs"
SUMMARY_DIR="$OUTPUT_BASE/summary"
mkdir -p "$LOG_DIR" "$SUMMARY_DIR"

# ── Dependency check (GNU parallel) ──────────────────────────────────────────
USE_PARALLEL=0
if command -v parallel > /dev/null 2>&1; then
    USE_PARALLEL=1
    echo "GNU parallel detected — using parallel dispatch"
else
    echo "GNU parallel not found — using PID loop fallback"
    echo "  Install with: sudo apt install parallel"
fi

# ── Pre-flight memory check ───────────────────────────────────────────────────
AVAIL_MB=$(awk '/MemAvailable/ {print int($2/1024)}' /proc/meminfo)
NEEDED_MB=$(( MAX_PARALLEL * 4000 ))
if [ "$AVAIL_MB" -lt "$NEEDED_MB" ]; then
    NEW_PARALLEL=$(( AVAIL_MB / 4000 ))
    NEW_PARALLEL=$(( NEW_PARALLEL < 1 ? 1 : NEW_PARALLEL ))
    echo "WARNING: available RAM ${AVAIL_MB}MB < needed ${NEEDED_MB}MB for $MAX_PARALLEL jobs"
    echo "  Reducing --parallel from $MAX_PARALLEL to $NEW_PARALLEL"
    MAX_PARALLEL=$NEW_PARALLEL
fi

# ── Scan discovery + collision check ─────────────────────────────────────────
mapfile -t ALL_NII_FILES < <(find "$DATA_DIR" -name "*.nii.gz" -type f | sort)
if [ ${#ALL_NII_FILES[@]} -eq 0 ]; then
    echo "ERROR: no .nii.gz files found in $DATA_DIR" >&2; exit 1
fi

# Collision detection
declare -A CASE_ID_MAP
COLLISIONS=()
NII_FILES=()
for NII in "${ALL_NII_FILES[@]}"; do
    CID=$(basename "$NII" .nii.gz | tr ' ()' '_-_' | tr -d "'\"")
    if [ -n "${CASE_ID_MAP[$CID]+x}" ]; then
        COLLISIONS+=("$CID: keeping '${CASE_ID_MAP[$CID]}', skipping '$NII'")
        continue
    fi
    CASE_ID_MAP[$CID]="$NII"
    NII_FILES+=("$NII")
done
if [ ${#COLLISIONS[@]} -gt 0 ]; then
    echo "WARNING: CASE_ID collisions detected:" >&2
    printf '  %s\n' "${COLLISIONS[@]}" >&2
fi

TOTAL_RUNS=$(( ${#NII_FILES[@]} * RUNS ))
EST_MIN=$(( ( (TOTAL_RUNS + MAX_PARALLEL - 1) / MAX_PARALLEL) * 40 ))

echo "=========================================="
echo "  CIP Vessel Pipeline Batch"
echo "=========================================="
echo "  Data dir:    $DATA_DIR"
echo "  Scans:       ${#NII_FILES[@]}"
echo "  Runs/scan:   $RUNS"
echo "  Total runs:  $TOTAL_RUNS"
echo "  Parallel:    $MAX_PARALLEL"
echo "  Cores/job:   $CORES"
echo "  Region:      $REGION"
echo "  Cleanup:     $CLEANUP"
echo "  Output:      $OUTPUT_BASE"
echo "  Est. time:   ~${EST_MIN} min"
[ -n "$STAGE_TO" ] && echo "  Stage to:    $STAGE_TO"
echo ""

# ── Memory watchdog ───────────────────────────────────────────────────────────
WATCHDOG_LOG="$LOG_DIR/memory_watchdog.log"
WATCHDOG_PID=""

MEM_TOTAL_KB=$(awk '/MemTotal/ {print $2}' /proc/meminfo)
MEM_WARN_KB=$(( MEM_TOTAL_KB * 20 / 100 ))
MEM_CRIT_KB=$(( MEM_TOTAL_KB * 10 / 100 ))

start_watchdog() {
    (
        echo "[$(date '+%H:%M:%S')] watchdog started total=${MEM_TOTAL_KB}kB warn=${MEM_WARN_KB}kB crit=${MEM_CRIT_KB}kB"
        while true; do
            AVAIL=$(awk '/MemAvailable/ {print $2}' /proc/meminfo)
            SWAP_FREE=$(awk '/SwapFree/ {print $2}' /proc/meminfo)
            TS="[$(date '+%H:%M:%S')]"
            if [ "$AVAIL" -lt "$MEM_CRIT_KB" ]; then
                VICTIM=$(ps aux --sort=-rss 2>/dev/null | \
                    awk '$0 ~ /puller|cip_compute|ComputeFeatureStrength|GeneratePartialLungLabelMap/ && !/awk/ {print $2, $11; exit}')
                echo "$TS CRITICAL avail=${AVAIL}kB swap_free=${SWAP_FREE}kB — killing: $VICTIM"
                VICTIM_PID=$(echo "$VICTIM" | awk '{print $1}')
                [ -n "$VICTIM_PID" ] && kill -TERM "$VICTIM_PID" 2>/dev/null
            elif [ "$AVAIL" -lt "$MEM_WARN_KB" ]; then
                echo "$TS WARNING avail=${AVAIL}kB swap_free=${SWAP_FREE}kB"
            fi
            sleep 5
        done
    ) >> "$WATCHDOG_LOG" 2>&1 &
    WATCHDOG_PID=$!
    echo "Memory watchdog started (PID $WATCHDOG_PID)"
}

stop_watchdog() {
    [ -n "$WATCHDOG_PID" ] && kill "$WATCHDOG_PID" 2>/dev/null || true
    echo "Memory watchdog stopped"
}

trap stop_watchdog EXIT

start_watchdog

# ── Shared job interface ──────────────────────────────────────────────────────
run_one_job() {
    local NII_PATH="$1" CASE_OUT_DIR="$2" RUNS="$3" CORES="$4"
    local REGION="$5" CLEANUP="$6" STAGE_TO="$7"
    local CASE_ID; CASE_ID=$(basename "$NII_PATH" .nii.gz | tr ' ()' '_-_' | tr -d "'\"")
    local LOG_FILE="$LOG_DIR/${CASE_ID}.log"
    local worker_args=(
        "$NII_PATH" "$CASE_OUT_DIR"
        --runs "$RUNS" --cores "$CORES" --region "$REGION" --cleanup "$CLEANUP"
    )
    [ -n "$STAGE_TO" ] && worker_args+=(--stage-to "$STAGE_TO")
    bash "$SCRIPT_DIR/run_scan_worker.sh" "${worker_args[@]}" \
        > "$LOG_FILE" 2>&1
    return $?
}
export -f run_one_job
export SCRIPT_DIR LOG_DIR

# ── Build job TSV ─────────────────────────────────────────────────────────────
JOB_TSV="$OUTPUT_BASE/job_args.tsv"
for NII in "${NII_FILES[@]}"; do
    CID=$(basename "$NII" .nii.gz | tr ' ()' '_-_' | tr -d "'\"")
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$NII" "$OUTPUT_BASE/$CID" \
        "$RUNS" "$CORES" "$REGION" "$CLEANUP" "${STAGE_TO:-}" \
        >> "$JOB_TSV"
done

# ── Dispatch ──────────────────────────────────────────────────────────────────
FAILED_CASES=()

if [ "$USE_PARALLEL" -eq 1 ]; then
    echo "Dispatching with GNU parallel (-j $MAX_PARALLEL, 10s stagger)..."
    parallel --delay 10 -j "$MAX_PARALLEL" --colsep '\t' \
        run_one_job {1} {2} {3} {4} {5} {6} {7} \
        :::: "$JOB_TSV" || true
    # Collect failures from logs
    while IFS=$'\t' read -r NII CASE_OUT _ _ _ _ _; do
        CID=$(basename "$NII" .nii.gz | tr ' ()' '_-_' | tr -d "'\"")
        grep -qE "^FAILED|^TIMEOUT|^SKIP" "$LOG_DIR/${CID}.log" 2>/dev/null && \
            FAILED_CASES+=("$CID")
    done < "$JOB_TSV"
else
    echo "Dispatching with PID loop (-j $MAX_PARALLEL, 10s stagger)..."
    PIDS=()
    declare -A PID_TO_CASE
    JOB_NUM=0

    while IFS=$'\t' read -r NII CASE_OUT R C REG CLEAN ST; do
        # Wait for a free slot
        while [ ${#PIDS[@]} -ge "$MAX_PARALLEL" ]; do
            NEW_PIDS=()
            for i in "${!PIDS[@]}"; do
                pid="${PIDS[$i]}"
                if kill -0 "$pid" 2>/dev/null; then
                    NEW_PIDS+=("$pid")
                else
                    wait "$pid" 2>/dev/null
                    EXIT=$?
                    [ $EXIT -ne 0 ] && [ $EXIT -ne 127 ] && FAILED_CASES+=("${PID_TO_CASE[$pid]:-PID$pid}")
                    unset "PID_TO_CASE[$pid]"
                fi
            done
            if [ ${#NEW_PIDS[@]} -gt 0 ]; then PIDS=("${NEW_PIDS[@]}"); else PIDS=(); fi
            [ ${#PIDS[@]} -ge "$MAX_PARALLEL" ] && sleep 5
        done

        # Launch job
        CID=$(basename "$NII" .nii.gz | tr ' ()' '_-_' | tr -d "'\"")
        JOB_NUM=$(( JOB_NUM + 1 ))
        echo "  Launching job $JOB_NUM: $CID"
        run_one_job "$NII" "$CASE_OUT" "$R" "$C" "$REG" "$CLEAN" "$ST" &
        JPID=$!
        PIDS+=("$JPID")
        PID_TO_CASE[$JPID]="$CID"
        sleep 10  # stagger
    done < "$JOB_TSV"

    # Wait for remaining
    for pid in "${PIDS[@]+${PIDS[@]}}"; do
        wait "$pid" 2>/dev/null
        EXIT=$?
        [ $EXIT -ne 0 ] && [ $EXIT -ne 127 ] && FAILED_CASES+=("${PID_TO_CASE[$pid]:-PID$pid}")
    done
fi

stop_watchdog

# ── Aggregate summary ─────────────────────────────────────────────────────────
echo ""
echo "=========================================="
echo "  Batch Complete"
echo "=========================================="
echo ""
echo "Output: $OUTPUT_BASE"
echo "Scans:  ${#NII_FILES[@]}  Runs/scan: $RUNS  Total: $TOTAL_RUNS"
echo ""

# Particle count table from DONE lines in log files
echo "Particle counts:"
printf "  %-45s  %-5s  %s\n" "Case" "Run" "Particles"
printf "  %-45s  %-5s  %s\n" "-----" "---" "---------"
for LOG in "$LOG_DIR"/*.log; do
    [ -f "$LOG" ] || continue
    while IFS=' ' read -r _ CID RUN COUNT ELAPSED; do
        printf "  %-45s  %-5s  %s  (%s)\n" "$CID" "$RUN" "$COUNT" "$ELAPSED"
    done < <(grep "^DONE " "$LOG" 2>/dev/null)
done

# Collect phenotype CSVs
find "$OUTPUT_BASE" -name '*_vascularPhenotypes.csv' \
    -exec cp {} "$SUMMARY_DIR/" \; 2>/dev/null || true
CSV_COUNT=$(find "$SUMMARY_DIR" -maxdepth 1 -name '*_vascularPhenotypes.csv' | wc -l)
echo ""
echo "Phenotype CSVs collected: $CSV_COUNT -> $SUMMARY_DIR"

# Watchdog events
WARN_COUNT=$(grep -cE "WARNING|CRITICAL" "$WATCHDOG_LOG" 2>/dev/null) || WARN_COUNT=0
echo "Watchdog events: $WARN_COUNT  (see $WATCHDOG_LOG)"

# Failed cases
echo ""
if [ ${#FAILED_CASES[@]} -gt 0 ]; then
    echo "FAILED cases (${#FAILED_CASES[@]}):"
    for C in "${FAILED_CASES[@]}"; do
        echo "  $C  -> $LOG_DIR/${C}.log"
    done
    exit 1
else
    echo "All cases completed successfully."
    exit 0
fi
