#!/usr/bin/env bash
# run_pipeline.sh — end-to-end vessel particle pipeline
#
# Usage:
#   bash run_pipeline.sh -i /path/to/dicom_dir -o /path/to/output_dir [options]
#
# Required:
#   -i DIR       Input DICOM directory
#   -o DIR       Output directory
#
# Options:
#   -c ID        Case ID prefix (default: "case")
#   -r REGIONS   Comma-separated lung regions (default: WholeLung)
#   --median     Apply median filter to CT before processing
#   --connect    Run connected particles (MST) after particle extraction
#   --dist FLOAT Distance threshold for connected particles (default: 2.0)
#   --voxel SZ   Isotropic voxel size in mm for resampling (default: 0.625)
#   --maxscale S Max particle scale (default: 6.0)
#   --seedTh TH  Hessian seed threshold (default: -70)
#   --liveTh TH  Hessian live threshold (default: -95)
#   --init MODE  Initialization mode: Threshold|Frangi (default: Threshold)
#   -h           Show this help

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Activate venv
if [ -f "$SCRIPT_DIR/venv/bin/activate" ]; then
    source "$SCRIPT_DIR/venv/bin/activate"
else
    echo "ERROR: venv not found. Run setup.sh first." >&2
    exit 1
fi

# Add Teem to PATH if locally built
if [ -d "$SCRIPT_DIR/teem_install/bin" ]; then
    export PATH="$SCRIPT_DIR/teem_install/bin:$PATH"
fi

# Defaults
CASE_ID="case"
REGIONS="WholeLung"
MEDIAN=false
CONNECT=false
DIST_THRESH=2.0
VOXEL_SIZE=0.625
MAX_SCALE=6.0
SEED_THRESH=-70     # Hessian feature-strength seed threshold (NOT an HU value)
LIVE_THRESH=-95     # Hessian feature-strength live threshold (NOT an HU value)
INIT_MODE="Threshold"
IN_DIR=""
OUT_DIR=""

# Parse args
while [[ $# -gt 0 ]]; do
    case "$1" in
        -i)        IN_DIR="$2";         shift 2 ;;
        -o)        OUT_DIR="$2";        shift 2 ;;
        -c)        CASE_ID="$2";        shift 2 ;;
        -r)        REGIONS="$2";        shift 2 ;;
        --median)  MEDIAN=true;         shift   ;;
        --connect) CONNECT=true;        shift   ;;
        --dist)    DIST_THRESH="$2";    shift 2 ;;
        --voxel)   VOXEL_SIZE="$2";     shift 2 ;;
        --maxscale) MAX_SCALE="$2";     shift 2 ;;
        --seedTh)  SEED_THRESH="$2";    shift 2 ;;
        --liveTh)  LIVE_THRESH="$2";    shift 2 ;;
        --init)    INIT_MODE="$2";      shift 2 ;;
        -h|--help)
            sed -n '3,23p' "$0" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

if [ -z "$IN_DIR" ] || [ -z "$OUT_DIR" ]; then
    echo "ERROR: -i and -o are required." >&2
    exit 1
fi

mkdir -p "$OUT_DIR"

CT_NRRD="$OUT_DIR/${CASE_ID}_ct.nrrd"
LM_NRRD="$OUT_DIR/${CASE_ID}_partialLungLabelMap.nrrd"
OUT_PREFIX="$OUT_DIR/$CASE_ID"
CT_INPUT="$CT_NRRD"

echo "========================================================"
echo " Vessel Particle Pipeline"
echo " Case:    $CASE_ID"
echo " Regions: $REGIONS"
echo " Input:   $IN_DIR"
echo " Output:  $OUT_DIR"
echo " Init:    $INIT_MODE"
echo "========================================================"

# Step 1: DICOM → nrrd
echo ""
echo "[1/5] Converting DICOM to nrrd..."
python3 "$SCRIPT_DIR/convert_dicom.py" -i "$IN_DIR" -o "$CT_NRRD"

# Step 2 (optional): median filter
if $MEDIAN; then
    CT_MED="$OUT_DIR/${CASE_ID}_ct_median.nrrd"
    echo ""
    echo "[2/5] Applying median filter..."
    python3 "$SCRIPT_DIR/median_filter.py" -i "$CT_NRRD" -o "$CT_MED"
    CT_INPUT="$CT_MED"
else
    echo ""
    echo "[2/5] Skipping median filter (use --median to enable)."
fi

# Step 3: lung label map
echo ""
echo "[3/5] Generating partial lung label map..."
python3 "$SCRIPT_DIR/generate_lung_mask.py" -i "$CT_INPUT" -o "$LM_NRRD"

# Step 4: vessel particles (3-pass puller + gprobe + VTK assembly)
echo ""
echo "[4/5] Running vessel particle pipeline..."
python3 "$SCRIPT_DIR/vessel_particles.py" \
    -i "$CT_INPUT" \
    -l "$LM_NRRD" \
    -o "$OUT_PREFIX" \
    --tmpDir "$OUT_DIR/tmp" \
    -r "$REGIONS" \
    --seedTh "$SEED_THRESH" \
    --liveTh "$LIVE_THRESH" \
    -s "$VOXEL_SIZE" \
    --maxscale "$MAX_SCALE" \
    --init "$INIT_MODE"

# Derive output VTK path (first region only; format: prefix_<regionTag>VesselParticles.vtk)
FIRST_REGION="${REGIONS%%,*}"
RTAG="${FIRST_REGION,}"   # lowercase first char (bash 4+)
PARTICLES_VTK="${OUT_PREFIX}_${RTAG}VesselParticles.vtk"

# Step 5 (optional): MST connected particles
if $CONNECT; then
    CONNECTED_VTK="${OUT_PREFIX}_${RTAG}VesselParticles_connected.vtk"
    echo ""
    echo "[5/5] Computing connected particles (MST, dist=${DIST_THRESH}mm)..."
    python3 "$SCRIPT_DIR/connected_particles.py" \
        -i "$PARTICLES_VTK" \
        -o "$CONNECTED_VTK" \
        --dist "$DIST_THRESH"
    FINAL_VTK="$CONNECTED_VTK"
else
    echo ""
    echo "[5/5] Skipping connected particles (use --connect to enable)."
    FINAL_VTK="$PARTICLES_VTK"
fi

echo ""
echo "========================================================"
echo " DONE"
echo " Particles: $FINAL_VTK"
echo " Label map: $LM_NRRD"
echo "========================================================"
