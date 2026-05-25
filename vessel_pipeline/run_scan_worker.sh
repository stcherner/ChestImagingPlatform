#!/usr/bin/env bash
# run_scan_worker.sh — CIP vessel pipeline worker for one scan
# Usage: run_scan_worker.sh <nii_path> <output_dir>
#            --runs N --cores N --region REGION --cleanup none|light|all
#            [--stage-to /path]
set -euo pipefail

# ── Standalone mode: source env.sh if CIP_PATH not exported ──────────────────
if [ -z "${CIP_PATH:-}" ]; then
    WORKER_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    source "$WORKER_SCRIPT_DIR/env.sh"
fi

PIPELINE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/Scripts/cip_compute_vessel_particles.py"
# CIP_BUILD_DIR is exported by env.sh; fall back to default if called standalone without env.sh
: "${CIP_BUILD_DIR:=$HOME/cip_build}"
PHENO_SCRIPT="$CIP_BUILD_DIR/CIP-build/cip_python/phenotypes/vasculature_phenotypes.py"

# ── CLI parsing ───────────────────────────────────────────────────────────────
NII_PATH="${1:?Usage: $0 <nii_path> <output_dir> --runs N --cores N --region R --cleanup X}"
OUTPUT_DIR="${2:?}"
shift 2

RUNS=1
CORES=4
REGION="WholeLung"
CLEANUP="light"
STAGE_TO=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --runs)     [[ $# -ge 2 ]] || { echo "ERROR: --runs requires a value" >&2; exit 1; }; RUNS="$2";    shift 2 ;;
        --cores)    [[ $# -ge 2 ]] || { echo "ERROR: --cores requires a value" >&2; exit 1; }; CORES="$2";   shift 2 ;;
        --region)   [[ $# -ge 2 ]] || { echo "ERROR: --region requires a value" >&2; exit 1; }; REGION="$2";  shift 2 ;;
        --cleanup)  [[ $# -ge 2 ]] || { echo "ERROR: --cleanup requires a value" >&2; exit 1; }; CLEANUP="$2"; shift 2 ;;
        --stage-to) [[ $# -ge 2 ]] || { echo "ERROR: --stage-to requires a value" >&2; exit 1; }; STAGE_TO="$2"; shift 2 ;;
        *) echo "Unknown argument: $1" >&2; exit 1 ;;
    esac
done

# Validate numeric args
[[ "$RUNS" =~ ^[1-9][0-9]*$ ]] || { echo "ERROR: --runs must be a positive integer, got: $RUNS" >&2; exit 1; }
[[ "$CORES" =~ ^[1-9][0-9]*$ ]] || { echo "ERROR: --cores must be a positive integer, got: $CORES" >&2; exit 1; }

# Validate cleanup value
case "$CLEANUP" in
    none|light|all) ;;
    *) echo "ERROR: --cleanup must be none|light|all, got: $CLEANUP" >&2; exit 1 ;;
esac

# ── Binary pre-check ──────────────────────────────────────────────────────────
MISSING=()
for bin in GenerateMedianFilteredImage GeneratePartialLungLabelMap \
           ReadParticlesWriteConnectedParticles; do
    command -v "$bin" > /dev/null 2>&1 || MISSING+=("binary not found: $bin")
done

[ -f "$PIPELINE" ] || MISSING+=("pipeline script not found: $PIPELINE")

if [ -f "$PIPELINE" ]; then
    python "$PIPELINE" --help 2>&1 | grep -q -- '--perm' || MISSING+=(
        "--perm flag missing from $(basename "$PIPELINE")"
        "  Fix: add parser.add_argument('--perm', dest='permissive', action='store_true', default=False)"
        "       and particlesGenerator._permissive = self._permissive in execute()"
    )
    python "$PIPELINE" --help 2>&1 | grep -q -- '--init' || \
        MISSING+=("--init flag missing from pipeline script")
fi

if [ ${#MISSING[@]} -gt 0 ]; then
    echo "ERROR: pre-check failed:" >&2
    printf '  %s\n' "${MISSING[@]}" >&2
    exit 1
fi

# ── CASE_ID and directory setup ───────────────────────────────────────────────
CASE_ID=$(basename "$NII_PATH" .nii.gz | tr ' ()' '_-_' | tr -d "'\"")
# OUTPUT_DIR already includes CASE_ID (set by orchestrator as $OUTPUT_BASE/$CID
# or by a standalone caller as $BASE/$CASE_ID). Do NOT append CASE_ID again.
CASEDIR="$OUTPUT_DIR"
TMPDIR_SHARED="$CASEDIR/tmp"
if [[ "$CASEDIR" == /mnt/c/* ]] && ! mountpoint -q /mnt/c; then
    echo "ERROR: /mnt/c is not mounted" >&2; exit 1
fi
mkdir -p "$CASEDIR" "$TMPDIR_SHARED"

cleanup_tmp_on_exit() {
    cleanup_run_probe_files 2>/dev/null || true
    rm -f "$CASEDIR"/*.tmp.nrrd 2>/dev/null || true
    case "$CLEANUP" in
        light) rm -f "$TMPDIR_SHARED"/mask.nrrd 2>/dev/null || true ;;
        all)   rm -rf "$TMPDIR_SHARED" 2>/dev/null || true ;;
    esac
}
trap cleanup_tmp_on_exit EXIT

echo "[$(date '+%H:%M:%S')] START $CASE_ID (runs=$RUNS cores=$CORES region=$REGION cleanup=$CLEANUP)"

cleanup_run_probe_files() {
    rm -f "$TMPDIR_SHARED"/pass*.nrrd \
          "$TMPDIR_SHARED"/heval*.nrrd \
          "$TMPDIR_SHARED"/hevec*.nrrd \
          "$TMPDIR_SHARED"/hmode.nrrd \
          "$TMPDIR_SHARED"/hess.nrrd \
          "$TMPDIR_SHARED"/val.nrrd
}

# ── Preprocessing (idempotent, atomic writes) ─────────────────────────────────
preprocess() {
    # Step 1: NIfTI -> NRRD (cast to int16)
    if [ ! -s "$CASEDIR/CT.nrrd" ]; then
        echo "[$(date '+%H:%M:%S')] $CASE_ID preprocessing: NIfTI -> NRRD"
        CT_TMP=$(mktemp "$CASEDIR/CT.XXXXXX.tmp.nrrd")
        NII_IN="$NII_PATH" NRRD_OUT="$CT_TMP" \
        python -c "
import os, SimpleITK as sitk
img = sitk.ReadImage(os.environ['NII_IN'])
img = sitk.Cast(img, sitk.sitkInt16)
sitk.WriteImage(img, os.environ['NRRD_OUT'])
sz = img.GetSize(); sp = img.GetSpacing()
print(f'  size={sz} spacing=({sp[0]:.4f},{sp[1]:.4f},{sp[2]:.4f})')
"
        mv "$CT_TMP" "$CASEDIR/CT.nrrd"
    else
        echo "[$(date '+%H:%M:%S')] $CASE_ID CT.nrrd exists, skipping"
    fi

    # Step 2: Median filter
    if [ ! -s "$CASEDIR/CTFiltered.nrrd" ]; then
        echo "[$(date '+%H:%M:%S')] $CASE_ID preprocessing: median filter"
        CTF_TMP=$(mktemp "$CASEDIR/CTFiltered.XXXXXX.tmp.nrrd")
        GenerateMedianFilteredImage \
            -i "$CASEDIR/CT.nrrd" \
            -o "$CTF_TMP" 2>&1 | tail -2
        mv "$CTF_TMP" "$CASEDIR/CTFiltered.nrrd"
    else
        echo "[$(date '+%H:%M:%S')] $CASE_ID CTFiltered.nrrd exists, skipping"
    fi

    # Step 3: Label map (from filtered CT)
    if [ ! -s "$CASEDIR/partialLungLabelMap.nrrd" ]; then
        echo "[$(date '+%H:%M:%S')] $CASE_ID preprocessing: label map"
        LM_TMP=$(mktemp "$CASEDIR/partialLungLabelMap.XXXXXX.tmp.nrrd")
        GeneratePartialLungLabelMap \
            --ict "$CASEDIR/CTFiltered.nrrd" \
            -o "$LM_TMP" 2>&1 | tail -2
        mv "$LM_TMP" "$CASEDIR/partialLungLabelMap.nrrd"
    else
        echo "[$(date '+%H:%M:%S')] $CASE_ID partialLungLabelMap.nrrd exists, skipping"
    fi
}

preprocess

# ── Extraction loop ───────────────────────────────────────────────────────────
RUN_FAILED=0
# REGION_LOWER lowercases only the first character: WholeLung -> wholeLung, RightLung -> rightLung.
# The pipeline produces VTK filenames as particles.vtk_<regionLower>VesselParticles.vtk.
# awk tolower() is POSIX-portable; \L is Vim/Perl-only and fails silently in GNU sed.
REGION_LOWER="$(echo "$REGION" | awk '{print tolower(substr($0,1,1)) substr($0,2)}')"

for RUN_NUM in $(seq 1 "$RUNS"); do
    RUN_DIR="$CASEDIR/run${RUN_NUM}"
    mkdir -p "$RUN_DIR"
    PARTICLE_VTK="$RUN_DIR/particles.vtk_${REGION_LOWER}VesselParticles.vtk"
    CONNECTED_VTK="$RUN_DIR/connected_vessel_particles.vtk"
    RUN_START=$(date +%s)

    # Skip if both outputs already exist and are non-empty
    if [ -s "$PARTICLE_VTK" ] && [ -s "$CONNECTED_VTK" ]; then
        echo "[$(date '+%H:%M:%S')] $CASE_ID run$RUN_NUM already complete, skipping"
        continue
    fi

    # 1. Disk space check
    AVAIL_KB=$(df --output=avail "$CASEDIR" | tail -1 | tr -d ' ')
    if [ "$AVAIL_KB" -lt 6291456 ]; then
        echo "SKIP $CASE_ID run$RUN_NUM — $(( AVAIL_KB / 1048576 )) GiB free, need 6 GiB"
        cleanup_run_probe_files
        RUN_FAILED=1; continue
    fi

    # 2. Vessel extraction (90-min timeout)
    # vesselness_th=0.38: production default chosen for higher sensitivity.
    # Calibration also tested 0.58 (more conservative). The argparse default in
    # cip_compute_vessel_particles.py was 0.50 (stale) and has been updated to 0.38.
    echo "[$(date '+%H:%M:%S')] $CASE_ID run$RUN_NUM: vessel extraction"
    set +e  # capture exit code manually; pipefail would exit before we can read PIPESTATUS
    ITK_GLOBAL_DEFAULT_NUMBER_OF_THREADS=$CORES \
    OMP_NUM_THREADS=$CORES \
    timeout 5400 python "$PIPELINE" \
        -i  "$CASEDIR/CT.nrrd" \
        -l  "$CASEDIR/partialLungLabelMap.nrrd" \
        --tmpDir "$TMPDIR_SHARED" \
        -o  "$RUN_DIR/particles.vtk" \
        -r  "$REGION" \
        -s  0.625 \
        --init Threshold \
        --perm \
        --vesselness_th 0.38 \
        2>&1 | grep -v "^$" | tail -5
    EXIT_CODE=${PIPESTATUS[0]}
    set -e

    if   [ $EXIT_CODE -eq 124 ]; then
        echo "TIMEOUT $CASE_ID run$RUN_NUM — exceeded 90 min"; cleanup_run_probe_files; RUN_FAILED=1; continue
    elif [ $EXIT_CODE -ne 0 ]; then
        echo "FAILED $CASE_ID run$RUN_NUM — pipeline exit $EXIT_CODE"; cleanup_run_probe_files; RUN_FAILED=1; continue
    fi

    if [ ! -f "$PARTICLE_VTK" ]; then
        echo "FAILED $CASE_ID run$RUN_NUM — VTK not found: $PARTICLE_VTK"
        cleanup_run_probe_files
        RUN_FAILED=1; continue
    fi

    # 3. Connected particles
    echo "[$(date '+%H:%M:%S')] $CASE_ID run$RUN_NUM: connected particles"
    set +e
    ReadParticlesWriteConnectedParticles \
        -v "$PARTICLE_VTK" \
        -o "$CONNECTED_VTK" 2>&1 | tail -2
    CONNECTED_EXIT=${PIPESTATUS[0]}
    set -e
    if [ $CONNECTED_EXIT -ne 0 ] || [ ! -f "$CONNECTED_VTK" ]; then
        echo "FAILED $CASE_ID run$RUN_NUM — ReadParticlesWriteConnectedParticles failed"
        cleanup_run_probe_files
        RUN_FAILED=1; continue
    fi

    # 4. Phenotype computation (CLI, fallback to Python API)
    CSV_OUT="$RUN_DIR/${CASE_ID}_vascularPhenotypes.csv"
    PNG_OUT="$RUN_DIR/${CASE_ID}_vascularPhenotypePlot.png"
    echo "[$(date '+%H:%M:%S')] $CASE_ID run$RUN_NUM: phenotypes"

    set +e
    PYTHONPATH="$CIP_BUILD_DIR/CIP-build" \
    python "$PHENO_SCRIPT" \
        -i "$PARTICLE_VTK" \
        --out_csv "$CSV_OUT" \
        --cid "$CASE_ID" \
        -t Vessel \
        --out_plot "$PNG_OUT" 2>/dev/null
    PHENO_EXIT=$?
    set -e

    if [ $PHENO_EXIT -ne 0 ]; then
        echo "  phenotype CLI failed (exit $PHENO_EXIT) — trying API fallback"
        set +e
        PHENO_IN="$PARTICLE_VTK" PHENO_CSV="$CSV_OUT" PHENO_PNG="$PNG_OUT" \
        PHENO_CID="$CASE_ID" PHENO_CIPBUILD="$CIP_BUILD_DIR/CIP-build" \
        PYTHONPATH="$CIP_BUILD_DIR/CIP-build" python - <<'PYEOF'
import os, sys, vtk, numpy as np
sys.path.insert(0, os.environ['PHENO_CIPBUILD'])
from cip_python.phenotypes.vasculature_phenotypes import VasculaturePhenotypes
r = vtk.vtkPolyDataReader()
r.SetFileName(os.environ['PHENO_IN']); r.Update()
vp = VasculaturePhenotypes(chest_regions=['WildCard'], pairs=None)
result = vp.execute(r.GetOutput(), os.environ['PHENO_CID'],
                    spacing=np.array([0.625, 0.625, 0.625]))
if isinstance(result, tuple):
    df = result[0]; fig = result[1] if len(result) > 1 else None
else:
    df = result; fig = None
df.to_csv(os.environ['PHENO_CSV'], index=False)
if fig is not None:
    fig.savefig(os.environ['PHENO_PNG'], dpi=180)
print('phenotype API fallback OK: ' + str(len(df)) + ' rows')
PYEOF
        PHENO_EXIT=$?
        set -e
    fi

    [ $PHENO_EXIT -ne 0 ] && \
        echo "WARNING $CASE_ID run$RUN_NUM — phenotype failed (non-fatal)"

    # 5. Per-run probe file cleanup (always)
    cleanup_run_probe_files

    # 6. Artifact validation and Windows staging
    ARTIFACTS=("$PARTICLE_VTK" "$CONNECTED_VTK")
    [ -f "$CSV_OUT" ] && ARTIFACTS+=("$CSV_OUT")
    [ -f "$PNG_OUT" ] && ARTIFACTS+=("$PNG_OUT")

    for f in "$PARTICLE_VTK" "$CONNECTED_VTK"; do
        [ -f "$f" ] || echo "WARNING $CASE_ID run$RUN_NUM — missing: $(basename "$f")"
    done

    if [ -n "$STAGE_TO" ]; then
        DEST="$STAGE_TO/$CASE_ID/run${RUN_NUM}"
        if [[ "$DEST" == /mnt/c/* ]] && ! mountpoint -q /mnt/c; then
            echo "  WARNING: cannot create $DEST (/mnt/c is not mounted)"
        elif mkdir -p "$DEST" 2>/dev/null; then
            cp "${ARTIFACTS[@]}" "$DEST/" 2>/dev/null \
                && echo "  staged -> $DEST" \
                || echo "  WARNING: staging copy failed (Windows mount issue?)"
        else
            echo "  WARNING: cannot create $DEST (Windows mount unavailable?)"
        fi
    fi

    # 7. Summary line
    set +e
    PARTICLE_COUNT=$(PARTICLE_VTK_PATH="$PARTICLE_VTK" python -c "
import os, vtk
r = vtk.vtkPolyDataReader()
r.SetFileName(os.environ['PARTICLE_VTK_PATH']); r.Update()
print(r.GetOutput().GetNumberOfPoints())")
    PC_EXIT=$?
    set -e
    [ $PC_EXIT -ne 0 ] && PARTICLE_COUNT="unknown"
    ELAPSED=$(( $(date +%s) - RUN_START ))
    echo "DONE $CASE_ID run${RUN_NUM} $PARTICLE_COUNT ${ELAPSED}s"

done  # end extraction loop

# ── Post-loop cleanup ─────────────────────────────────────────────────────────
case "$CLEANUP" in
    light) rm -f "$TMPDIR_SHARED"/mask.nrrd ;;
    all)   rm -rf "$TMPDIR_SHARED" ;;
    none)  ;;
esac

echo "[$(date '+%H:%M:%S')] FINISH $CASE_ID — exit $([ $RUN_FAILED -eq 0 ] && echo 0 || echo 1)"
exit $RUN_FAILED
