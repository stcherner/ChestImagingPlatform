# CIP Resource-Aware Batch Processing System — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a three-file system (PowerShell launcher + Bash orchestrator + Bash worker) that runs the CIP vessel particle pipeline in parallel across multiple participants on any Windows/WSL2 machine, with automatic resource allocation and memory safety.

**Architecture:** A PowerShell launcher probes Windows resources and configures WSL2; a Bash orchestrator manages parallel job dispatch (GNU parallel or PID loop) with a memory watchdog; a Bash worker runs one scan end-to-end with idempotent preprocessing, V-stack reuse across runs, and graceful failure handling. All paths are absolute; shell variables are passed to Python via environment variables.

**Tech Stack:** Bash 5, PowerShell 5.1+, Python 3 (SimpleITK, vtk), CIP C++ tools (`GenerateMedianFilteredImage`, `GeneratePartialLungLabelMap`, `ReadParticlesWriteConnectedParticles`), teem puller (via `cip_compute_vessel_particles.py`), GNU parallel (optional).

**Spec:** `vessel_pipeline/docs/2026-05-21-cip-batch-design.md`

---

## File Map

| Action | Path |
|--------|------|
| Modify | `Scripts/cip_compute_vessel_particles.py` — add `--perm` flag |
| Create | `vessel_pipeline/run_scan_worker.sh` — per-scan worker |
| Create | `vessel_pipeline/run_vessel_batch.sh` — orchestrator |
| Create | `/mnt/c/Users/tcher/Desktop/Start-CIPBatch.ps1` — PowerShell launcher |

---

## Task 1: Add `--perm` flag to pipeline script

**Files:**
- Modify: `~/cip_source/ChestImagingPlatform-master/Scripts/cip_compute_vessel_particles.py`

This is a pre-condition for all worker runs. The `_permissive` attribute is defined in the `chest_particles.py` base class; setting it to `True` appends `-usa true` to the teem puller vol params. The patch touches three locations in the script.

- [ ] **Step 1: Add `permissive` parameter to `VesselParticlesPipeline.__init__`**

In `cip_compute_vessel_particles.py`, modify line 25 (the `__init__` signature) to add `permissive=False` at the end:

```python
# Line 23-25: change
def __init__(self,ct_file_name,pl_file_name,regions,tmp_dir,output_prefix,init_method='Frangi',
             vessel_mask=None,resampling_method='Linear',lth=-95,sth=-70,voxel_size=0,min_scale=0.7,max_scale=4,
             vesselness_th=0.38,crop=None,rate=1,multires=False,justparticles=False,clean_cache=True):
# to:
def __init__(self,ct_file_name,pl_file_name,regions,tmp_dir,output_prefix,init_method='Frangi',
             vessel_mask=None,resampling_method='Linear',lth=-95,sth=-70,voxel_size=0,min_scale=0.7,max_scale=4,
             vesselness_th=0.38,crop=None,rate=1,multires=False,justparticles=False,clean_cache=True,
             permissive=False):
```

Add `self._permissive = permissive` after line 50 (`self._clean_cache=clean_cache`):

```python
        self._clean_cache=clean_cache
        self._permissive=permissive   # <-- add this line
        self._vessel_mask=vessel_mask
```

- [ ] **Step 2: Wire `_permissive` onto the `VesselParticles` instance**

In `execute()`, after line 264 (`particlesGenerator._clean_tmp_dir=self._clean_cache`), add:

```python
                particlesGenerator._clean_tmp_dir=self._clean_cache
                particlesGenerator._permissive=self._permissive   # <-- add this line
```

- [ ] **Step 3: Add `--perm` argparse argument and pass to constructor**

After line 305 (`parser.add_argument("--cleanCache", ...)`), add:

```python
    parser.add_argument("--perm", dest="permissive", action="store_true", default=False)
```

On line 326-328, add `permissive=op.permissive` as a keyword argument to the constructor call:

```python
    vp = VesselParticlesPipeline(op.ct_file_name,op.pl_file_name,regions,op.tmp_dir,op.output_prefix,op.init_method,
                               op.vessel_mask, op.resampling_method, op.lth,op.sth,op.voxel_size,op.min_scale,
                               op.max_scale,op.vesselness_th,crop,op.rate,op.multires,op.justparticles,op.clean_cache,
                               permissive=op.permissive)
```

- [ ] **Step 4: Verify the flag appears in --help**

```bash
cd ~/cip_source/ChestImagingPlatform-master
source vessel_pipeline/env.sh
python Scripts/cip_compute_vessel_particles.py --help | grep perm
```

Expected output:
```
  --perm
```

- [ ] **Step 5: Commit**

```bash
cd ~/cip_source/ChestImagingPlatform-master
git -c user.email="ThomasShelby47735@gmail.com" -c user.name="Sam Tcherner" \
  add Scripts/cip_compute_vessel_particles.py
git -c user.email="ThomasShelby47735@gmail.com" -c user.name="Sam Tcherner" \
  commit -m "feat: add --perm flag to cip_compute_vessel_particles.py

Sets _permissive=True on VesselParticles, enabling -usa true in the
teem puller. Matches reference pipeline behaviour."
```

---

## Task 2: Worker — skeleton, CLI parsing, standalone env

**Files:**
- Create: `~/cip_source/ChestImagingPlatform-master/vessel_pipeline/run_scan_worker.sh`

- [ ] **Step 1: Create the file with shebang, strict mode, and CLI parsing**

```bash
cat > ~/cip_source/ChestImagingPlatform-master/vessel_pipeline/run_scan_worker.sh << 'SCRIPT'
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

PIPELINE="$(dirname "$(dirname "$(command -v GenerateMedianFilteredImage)")")"
PIPELINE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/Scripts/cip_compute_vessel_particles.py"
PHENO_SCRIPT="$HOME/cip_build/CIP-build/cip_python/phenotypes/vasculature_phenotypes.py"

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
        --runs)     RUNS="$2";    shift 2 ;;
        --cores)    CORES="$2";   shift 2 ;;
        --region)   REGION="$2";  shift 2 ;;
        --cleanup)  CLEANUP="$2"; shift 2 ;;
        --stage-to) STAGE_TO="$2"; shift 2 ;;
        *) echo "Unknown argument: $1" >&2; exit 1 ;;
    esac
done

# Validate cleanup value
case "$CLEANUP" in
    none|light|all) ;;
    *) echo "ERROR: --cleanup must be none|light|all, got: $CLEANUP" >&2; exit 1 ;;
esac
SCRIPT
chmod +x ~/cip_source/ChestImagingPlatform-master/vessel_pipeline/run_scan_worker.sh
```

- [ ] **Step 2: Verify CLI parsing catches bad args**

```bash
bash ~/cip_source/ChestImagingPlatform-master/vessel_pipeline/run_scan_worker.sh \
    /some/file.nii.gz /some/out --runs 2 --cores 4 --region WholeLung --cleanup bad 2>&1 | head -3
```

Expected output contains:
```
ERROR: --cleanup must be none|light|all, got: bad
```

---

## Task 3: Worker — binary pre-check

**Files:**
- Modify: `vessel_pipeline/run_scan_worker.sh`

Append to the script after the CLI parsing block.

- [ ] **Step 1: Append binary pre-check function and call**

```bash
cat >> ~/cip_source/ChestImagingPlatform-master/vessel_pipeline/run_scan_worker.sh << 'BLOCK'

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
BLOCK
```

- [ ] **Step 2: Verify pre-check passes with current environment**

```bash
source ~/cip_source/ChestImagingPlatform-master/vessel_pipeline/env.sh
bash ~/cip_source/ChestImagingPlatform-master/vessel_pipeline/run_scan_worker.sh \
    /tmp/test.nii.gz /tmp/test_out \
    --runs 1 --cores 4 --region WholeLung --cleanup light 2>&1 | head -5
```

Expected: script proceeds past pre-check (may fail later on missing NII file — that's fine at this stage).

- [ ] **Step 3: Verify pre-check catches missing binary**

```bash
(PATH=/usr/bin bash ~/cip_source/ChestImagingPlatform-master/vessel_pipeline/run_scan_worker.sh \
    /tmp/test.nii.gz /tmp/out \
    --runs 1 --cores 4 --region WholeLung --cleanup light 2>&1) | grep "binary not found"
```

Expected: lines listing `GenerateMedianFilteredImage`, `GeneratePartialLungLabelMap`, `ReadParticlesWriteConnectedParticles`.

---

## Task 4: Worker — CASE_ID derivation and preprocessing phase

**Files:**
- Modify: `vessel_pipeline/run_scan_worker.sh`

- [ ] **Step 1: Append CASE_ID derivation and preprocessing function**

```bash
cat >> ~/cip_source/ChestImagingPlatform-master/vessel_pipeline/run_scan_worker.sh << 'BLOCK'

# ── CASE_ID and directory setup ───────────────────────────────────────────────
CASE_ID=$(basename "$NII_PATH" .nii.gz | tr ' ()' '_-_' | tr -d "'\"")
CASEDIR="$OUTPUT_DIR/$CASE_ID"
TMPDIR_SHARED="$CASEDIR/tmp"
mkdir -p "$CASEDIR" "$TMPDIR_SHARED"

echo "[$(date '+%H:%M:%S')] START $CASE_ID (runs=$RUNS cores=$CORES region=$REGION cleanup=$CLEANUP)"

# ── Preprocessing (idempotent, atomic writes) ─────────────────────────────────
preprocess() {
    # Step 1: NIfTI -> NRRD (cast to int16)
    if [ ! -f "$CASEDIR/CT.nrrd" ]; then
        echo "[$(date '+%H:%M:%S')] $CASE_ID preprocessing: NIfTI -> NRRD"
        NII_IN="$NII_PATH" NRRD_OUT="$CASEDIR/CT.tmp.nrrd" \
        python -c "
import os, SimpleITK as sitk
img = sitk.ReadImage(os.environ['NII_IN'])
img = sitk.Cast(img, sitk.sitkInt16)
sitk.WriteImage(img, os.environ['NRRD_OUT'])
sz = img.GetSize(); sp = img.GetSpacing()
print(f'  size={sz} spacing=({sp[0]:.4f},{sp[1]:.4f},{sp[2]:.4f})')
"
        mv "$CASEDIR/CT.tmp.nrrd" "$CASEDIR/CT.nrrd"
    else
        echo "[$(date '+%H:%M:%S')] $CASE_ID CT.nrrd exists, skipping"
    fi

    # Step 2: Median filter
    if [ ! -f "$CASEDIR/CTFiltered.nrrd" ]; then
        echo "[$(date '+%H:%M:%S')] $CASE_ID preprocessing: median filter"
        GenerateMedianFilteredImage \
            -i "$CASEDIR/CT.nrrd" \
            -o "$CASEDIR/CTFiltered.tmp.nrrd" 2>&1 | tail -2
        mv "$CASEDIR/CTFiltered.tmp.nrrd" "$CASEDIR/CTFiltered.nrrd"
    else
        echo "[$(date '+%H:%M:%S')] $CASE_ID CTFiltered.nrrd exists, skipping"
    fi

    # Step 3: Label map (from filtered CT)
    if [ ! -f "$CASEDIR/partialLungLabelMap.nrrd" ]; then
        echo "[$(date '+%H:%M:%S')] $CASE_ID preprocessing: label map"
        GeneratePartialLungLabelMap \
            --ict "$CASEDIR/CTFiltered.nrrd" \
            -o "$CASEDIR/partialLungLabelMap.tmp.nrrd" 2>&1 | tail -2
        mv "$CASEDIR/partialLungLabelMap.tmp.nrrd" "$CASEDIR/partialLungLabelMap.nrrd"
    else
        echo "[$(date '+%H:%M:%S')] $CASE_ID partialLungLabelMap.nrrd exists, skipping"
    fi
}

preprocess
BLOCK
```

- [ ] **Step 2: Smoke-test preprocessing on a real scan**

Use the first available NIfTI in the dry run directory:

```bash
NII=$(ls /mnt/c/Users/tcher/Desktop/dry/*.nii.gz 2>/dev/null | head -1)
source ~/cip_source/ChestImagingPlatform-master/vessel_pipeline/env.sh
bash ~/cip_source/ChestImagingPlatform-master/vessel_pipeline/run_scan_worker.sh \
    "$NII" /tmp/worker_test \
    --runs 1 --cores 4 --region WholeLung --cleanup light 2>&1 | head -20
```

Expected: three preprocessing lines ending with "skipping" or "done", then script continues.

- [ ] **Step 3: Verify idempotency — re-run skips all steps**

```bash
bash ~/cip_source/ChestImagingPlatform-master/vessel_pipeline/run_scan_worker.sh \
    "$NII" /tmp/worker_test \
    --runs 1 --cores 4 --region WholeLung --cleanup light 2>&1 | grep "skipping"
```

Expected: three "skipping" lines (CT.nrrd, CTFiltered.nrrd, partialLungLabelMap.nrrd).

- [ ] **Step 4: Verify atomic write — no half-written files on interrupt**

```bash
ls /tmp/worker_test/$(basename "$NII" .nii.gz | tr ' ()' '_-_' | tr -d "'\"")/
```

Expected: `CT.nrrd`, `CTFiltered.nrrd`, `partialLungLabelMap.nrrd`, `tmp/` — no `.tmp.nrrd` files.

---

## Task 5: Worker — extraction loop (disk check, vessel extraction, connected particles)

**Files:**
- Modify: `vessel_pipeline/run_scan_worker.sh`

- [ ] **Step 1: Append extraction loop with disk check, vessel extraction, and connected particles**

```bash
cat >> ~/cip_source/ChestImagingPlatform-master/vessel_pipeline/run_scan_worker.sh << 'BLOCK'

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

    # 1. Disk space check
    AVAIL_KB=$(df --output=avail "$CASEDIR" | tail -1 | tr -d ' ')
    if [ "$AVAIL_KB" -lt 6291456 ]; then
        echo "SKIP $CASE_ID run$RUN_NUM — $(( AVAIL_KB / 1048576 )) GiB free, need 6 GiB"
        RUN_FAILED=1; continue
    fi

    # 2. Vessel extraction (90-min timeout)
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
        echo "TIMEOUT $CASE_ID run$RUN_NUM — exceeded 90 min"; RUN_FAILED=1; continue
    elif [ $EXIT_CODE -ne 0 ]; then
        echo "FAILED $CASE_ID run$RUN_NUM — pipeline exit $EXIT_CODE"; RUN_FAILED=1; continue
    fi

    if [ ! -f "$PARTICLE_VTK" ]; then
        echo "FAILED $CASE_ID run$RUN_NUM — VTK not found: $PARTICLE_VTK"
        RUN_FAILED=1; continue
    fi

    # 3. Connected particles
    echo "[$(date '+%H:%M:%S')] $CASE_ID run$RUN_NUM: connected particles"
    ReadParticlesWriteConnectedParticles \
        -v "$PARTICLE_VTK" \
        -o "$CONNECTED_VTK" 2>&1 | tail -2
    if [ $? -ne 0 ] || [ ! -f "$CONNECTED_VTK" ]; then
        echo "FAILED $CASE_ID run$RUN_NUM — ReadParticlesWriteConnectedParticles failed"
        RUN_FAILED=1; continue
    fi
BLOCK
```

Note: the `done` closing the for-loop will be appended in the next task.

- [ ] **Step 2: Verify extraction runs on a real scan (single run)**

This will take ~10-15 minutes. Run in background and tail the output:

```bash
NII=$(ls /mnt/c/Users/tcher/Desktop/dry/*.nii.gz 2>/dev/null | head -1)
source ~/cip_source/ChestImagingPlatform-master/vessel_pipeline/env.sh
bash ~/cip_source/ChestImagingPlatform-master/vessel_pipeline/run_scan_worker.sh \
    "$NII" /tmp/worker_test2 \
    --runs 1 --cores 4 --region WholeLung --cleanup light 2>&1 &
WPID=$!
echo "Worker PID: $WPID"
```

Monitor with:
```bash
tail -f /tmp/worker_test2/*/run1/run.log 2>/dev/null || \
    ps aux | grep run_scan_worker | grep -v grep
```

When complete, verify:
```bash
ls -la /tmp/worker_test2/*/run1/*.vtk 2>/dev/null
```

Expected: `particles.vtk_wholeLungVesselParticles.vtk` and `connected_vessel_particles.vtk` both present.

---

## Task 6: Worker — phenotype computation, cleanup, staging, summary line

**Files:**
- Modify: `vessel_pipeline/run_scan_worker.sh`

- [ ] **Step 1: Append phenotype computation, per-run cleanup, staging, and summary into the extraction loop**

```bash
cat >> ~/cip_source/ChestImagingPlatform-master/vessel_pipeline/run_scan_worker.sh << 'BLOCK'

    # 4. Phenotype computation (CLI, fallback to Python API)
    CSV_OUT="$RUN_DIR/${CASE_ID}_vascularPhenotypes.csv"
    PNG_OUT="$RUN_DIR/${CASE_ID}_vascularPhenotypePlot.png"
    echo "[$(date '+%H:%M:%S')] $CASE_ID run$RUN_NUM: phenotypes"

    PYTHONPATH="$HOME/cip_build/CIP-build" \
    python "$PHENO_SCRIPT" \
        -i "$PARTICLE_VTK" \
        --out_csv "$CSV_OUT" \
        --cid "$CASE_ID" \
        -t Vessel \
        --out_plot "$PNG_OUT" 2>/dev/null
    PHENO_EXIT=$?

    if [ $PHENO_EXIT -ne 0 ]; then
        echo "  phenotype CLI failed (exit $PHENO_EXIT) — trying API fallback"
        PHENO_IN="$PARTICLE_VTK" PHENO_CSV="$CSV_OUT" PHENO_PNG="$PNG_OUT" \
        PHENO_CID="$CASE_ID" \
        PYTHONPATH="$HOME/cip_build/CIP-build" python - <<'PYEOF'
import os, sys, vtk, numpy as np
sys.path.insert(0, os.environ['HOME'] + '/cip_build/CIP-build')
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
    fi

    [ $PHENO_EXIT -ne 0 ] && \
        echo "WARNING $CASE_ID run$RUN_NUM — phenotype failed (non-fatal)"

    # 5. Per-run probe file cleanup (always)
    rm -f "$TMPDIR_SHARED"/pass*.nrrd \
          "$TMPDIR_SHARED"/heval*.nrrd \
          "$TMPDIR_SHARED"/hevec*.nrrd \
          "$TMPDIR_SHARED"/hmode.nrrd \
          "$TMPDIR_SHARED"/hess.nrrd \
          "$TMPDIR_SHARED"/val.nrrd

    # 6. Artifact validation and Windows staging
    ARTIFACTS=("$PARTICLE_VTK" "$CONNECTED_VTK")
    [ -f "$CSV_OUT" ] && ARTIFACTS+=("$CSV_OUT")
    [ -f "$PNG_OUT" ] && ARTIFACTS+=("$PNG_OUT")

    for f in "$PARTICLE_VTK" "$CONNECTED_VTK"; do
        [ -f "$f" ] || echo "WARNING $CASE_ID run$RUN_NUM — missing: $(basename "$f")"
    done

    if [ -n "$STAGE_TO" ]; then
        DEST="$STAGE_TO/$CASE_ID/run${RUN_NUM}"
        if mkdir -p "$DEST" 2>/dev/null; then
            cp "${ARTIFACTS[@]}" "$DEST/" 2>/dev/null \
                && echo "  staged -> $DEST" \
                || echo "  WARNING: staging copy failed (Windows mount issue?)"
        else
            echo "  WARNING: cannot create $DEST (Windows mount unavailable?)"
        fi
    fi

    # 7. Summary line
    PARTICLE_COUNT=$(PARTICLE_VTK_PATH="$PARTICLE_VTK" python -c "
import os, vtk
r = vtk.vtkPolyDataReader()
r.SetFileName(os.environ['PARTICLE_VTK_PATH']); r.Update()
print(r.GetOutput().GetNumberOfPoints())")
    ELAPSED=$(( $(date +%s) - RUN_START ))
    echo "DONE $CASE_ID run${RUN_NUM} $PARTICLE_COUNT ${ELAPSED}s"

done  # end extraction loop
BLOCK
```

- [ ] **Step 2: Verify DONE line appears after a completed run**

After the extraction run from Task 5 completes (or using the existing dry-run outputs):

```bash
source ~/cip_source/ChestImagingPlatform-master/vessel_pipeline/env.sh
NII=$(ls /mnt/c/Users/tcher/Desktop/dry/*.nii.gz | head -1)
bash ~/cip_source/ChestImagingPlatform-master/vessel_pipeline/run_scan_worker.sh \
    "$NII" /tmp/worker_test2 \
    --runs 1 --cores 4 --region WholeLung --cleanup light 2>&1 | grep "^DONE"
```

Expected output format:
```
DONE ROB0003-007-V2_-_HYPERVENT_ run1 63645 761s
```

- [ ] **Step 3: Verify CSV and PNG exist**

```bash
find /tmp/worker_test2 -name "*.csv" -o -name "*.png" | sort
```

Expected: one CSV and one PNG per run directory.

---

## Task 7: Worker — post-loop cleanup and exit code

**Files:**
- Modify: `vessel_pipeline/run_scan_worker.sh`

**Design note — `light` policy:** The code keeps V-*.nrrd and only deletes `mask.nrrd`. This is the correct behavior per our design discussion — V-stack is the expensive reusable artifact (~10 min, ~2 GiB); mask.nrrd is regenerable from CTFiltered.nrrd in seconds. The spec's cleanup policy table incorrectly listed V-*.nrrd as deleted by `light`. The code below is authoritative. Step 5 (commit) includes a patch to the spec table.

- [ ] **Step 0: Patch spec cleanup table to match code**

```bash
sed -i 's/| `light` | pass\/heval\/hevec\/hmode\/hess\/val | V-\*.nrrd, mask.nrrd |/| `light` | pass\/heval\/hevec\/hmode\/hess\/val | mask.nrrd only (V-stack kept for re-extraction) |/' \
    ~/cip_source/ChestImagingPlatform-master/vessel_pipeline/docs/2026-05-21-cip-batch-design.md
grep "light" ~/cip_source/ChestImagingPlatform-master/vessel_pipeline/docs/2026-05-21-cip-batch-design.md | grep -A1 "Policy"
```

- [ ] **Step 1: Append post-loop cleanup and final exit**

```bash
cat >> ~/cip_source/ChestImagingPlatform-master/vessel_pipeline/run_scan_worker.sh << 'BLOCK'

# ── Post-loop cleanup ─────────────────────────────────────────────────────────
case "$CLEANUP" in
    light) rm -f "$TMPDIR_SHARED"/mask.nrrd ;;
    all)   rm -rf "$TMPDIR_SHARED" ;;
    none)  ;;
esac

echo "[$(date '+%H:%M:%S')] FINISH $CASE_ID — exit $([ $RUN_FAILED -eq 0 ] && echo 0 || echo 1)"
exit $RUN_FAILED
BLOCK
```

- [ ] **Step 2: Verify `--cleanup light` keeps V-stack but removes mask.nrrd**

Run 2 passes on a scan that already has preprocessing done:

```bash
source ~/cip_source/ChestImagingPlatform-master/vessel_pipeline/env.sh
NII=$(ls /mnt/c/Users/tcher/Desktop/dry/*.nii.gz | head -1)
bash ~/cip_source/ChestImagingPlatform-master/vessel_pipeline/run_scan_worker.sh \
    "$NII" /tmp/worker_cleanup_test \
    --runs 2 --cores 4 --region WholeLung --cleanup light 2>&1 | tail -5
```

Then check tmp/:
```bash
CASE_ID=$(basename "$NII" .nii.gz | tr ' ()' '_-_' | tr -d "'\"")
ls /tmp/worker_cleanup_test/$CASE_ID/tmp/ 2>/dev/null
```

Expected: `V-*-010.nrrd` files present, `mask.nrrd` absent, `featureMap.nrrd` present if generated.

- [ ] **Step 3: Verify `--cleanup all` removes entire tmp/**

```bash
source ~/cip_source/ChestImagingPlatform-master/vessel_pipeline/env.sh
NII=$(ls /mnt/c/Users/tcher/Desktop/dry/*.nii.gz | head -1)
bash ~/cip_source/ChestImagingPlatform-master/vessel_pipeline/run_scan_worker.sh \
    "$NII" /tmp/worker_all_test \
    --runs 1 --cores 4 --region WholeLung --cleanup all 2>&1 | tail -3
CASE_ID=$(basename "$NII" .nii.gz | tr ' ()' '_-_' | tr -d "'\"")
[ -d /tmp/worker_all_test/$CASE_ID/tmp ] && echo "FAIL: tmp still exists" || echo "PASS: tmp deleted"
```

- [ ] **Step 4: Verify exit code is non-zero on preprocessing failure**

```bash
bash ~/cip_source/ChestImagingPlatform-master/vessel_pipeline/run_scan_worker.sh \
    /nonexistent/scan.nii.gz /tmp/fail_test \
    --runs 1 --cores 4 --region WholeLung --cleanup light 2>&1
echo "Exit code: $?"
```

Expected: exit code 1 with an error message about the missing file.

- [ ] **Step 5: Commit the complete worker**

```bash
cd ~/cip_source/ChestImagingPlatform-master
git -c user.email="ThomasShelby47735@gmail.com" -c user.name="Sam Tcherner" \
  add vessel_pipeline/run_scan_worker.sh
git -c user.email="ThomasShelby47735@gmail.com" -c user.name="Sam Tcherner" \
  commit -m "feat: add run_scan_worker.sh

Per-scan worker: binary pre-check, idempotent preprocessing (NIfTI->NRRD,
median filter, label map), N extraction runs with shared V-stack tmpDir,
90-min timeout, connected particles, phenotypes (CLI + API fallback),
per-run probe cleanup, artifact validation, Windows staging, DONE summary line."
```

---

## Task 8: Orchestrator — skeleton, env setup, CLI, startup checks

**Files:**
- Create: `~/cip_source/ChestImagingPlatform-master/vessel_pipeline/run_vessel_batch.sh`

- [ ] **Step 1: Create orchestrator with header, env, CLI, and startup checks**

```bash
cat > ~/cip_source/ChestImagingPlatform-master/vessel_pipeline/run_vessel_batch.sh << 'SCRIPT'
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
        --parallel)     MAX_PARALLEL="$2"; shift 2 ;;
        --cores-per-job) CORES="$2";       shift 2 ;;
        --runs)         RUNS="$2";         shift 2 ;;
        --region)       REGION="$2";       shift 2 ;;
        --cleanup)      CLEANUP="$2";      shift 2 ;;
        --stage-to)     STAGE_TO="$2";     shift 2 ;;
        --output-base)  OUTPUT_BASE="$2";  shift 2 ;;
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
mapfile -t NII_FILES < <(find "$DATA_DIR" -name "*.nii.gz" -type f | sort)
if [ ${#NII_FILES[@]} -eq 0 ]; then
    echo "ERROR: no .nii.gz files found in $DATA_DIR" >&2; exit 1
fi

# Collision detection
declare -A CASE_ID_MAP
COLLISIONS=()
for NII in "${NII_FILES[@]}"; do
    CID=$(basename "$NII" .nii.gz | tr ' ()' '_-_' | tr -d "'\"")
    if [ -n "${CASE_ID_MAP[$CID]+x}" ]; then
        COLLISIONS+=("$CID: '${CASE_ID_MAP[$CID]}' and '$NII'")
    fi
    CASE_ID_MAP[$CID]="$NII"
done
if [ ${#COLLISIONS[@]} -gt 0 ]; then
    echo "ERROR: CASE_ID collisions detected:" >&2
    printf '  %s\n' "${COLLISIONS[@]}" >&2
    exit 1
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
SCRIPT
chmod +x ~/cip_source/ChestImagingPlatform-master/vessel_pipeline/run_vessel_batch.sh
```

- [ ] **Step 2: Verify startup checks**

```bash
source ~/cip_source/ChestImagingPlatform-master/vessel_pipeline/env.sh
bash ~/cip_source/ChestImagingPlatform-master/vessel_pipeline/run_vessel_batch.sh \
    /mnt/c/Users/tcher/Desktop/dry \
    --parallel 2 --cores-per-job 4 --runs 1 2>&1 | head -25
```

Expected: prints the plan header with scan count, estimated time; does not launch anything yet.

- [ ] **Step 3: Verify collision detection**

```bash
mkdir -p /tmp/collision_test
touch "/tmp/collision_test/ROB0003 (HYPERVENT).nii.gz"
touch "/tmp/collision_test/ROB0003_(HYPERVENT).nii.gz"
bash ~/cip_source/ChestImagingPlatform-master/vessel_pipeline/run_vessel_batch.sh \
    /tmp/collision_test --parallel 1 --cores-per-job 4 2>&1 | grep "collision"
rm -rf /tmp/collision_test
```

Expected: "ERROR: CASE_ID collisions detected:" with the conflicting filenames.

---

## Task 9: Orchestrator — memory watchdog

**Files:**
- Modify: `vessel_pipeline/run_vessel_batch.sh`

- [ ] **Step 1: Append watchdog function and start/stop infrastructure**

```bash
cat >> ~/cip_source/ChestImagingPlatform-master/vessel_pipeline/run_vessel_batch.sh << 'BLOCK'

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
BLOCK
```

- [ ] **Step 2: Verify watchdog starts and creates log**

```bash
source ~/cip_source/ChestImagingPlatform-master/vessel_pipeline/env.sh
bash ~/cip_source/ChestImagingPlatform-master/vessel_pipeline/run_vessel_batch.sh \
    /mnt/c/Users/tcher/Desktop/dry \
    --parallel 1 --cores-per-job 4 --runs 1 2>&1 &
BPID=$!
sleep 8
kill $BPID 2>/dev/null; wait $BPID 2>/dev/null
ls ~/cip_build/runs/batch_*/logs/memory_watchdog.log 2>/dev/null | tail -1 | xargs head -3
```

Expected: watchdog log contains the startup line with memory thresholds.

---

## Task 10: Orchestrator — `run_one_job()`, TSV dispatch, PID loop

**Files:**
- Modify: `vessel_pipeline/run_vessel_batch.sh`

- [ ] **Step 1: Append `run_one_job()` and build the job TSV**

```bash
cat >> ~/cip_source/ChestImagingPlatform-master/vessel_pipeline/run_vessel_batch.sh << 'BLOCK'

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
    PID_TO_CASE=()
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
                    [ $EXIT -ne 0 ] && FAILED_CASES+=("${PID_TO_CASE[$pid]:-PID$pid}")
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
        [ $EXIT -ne 0 ] && FAILED_CASES+=("${PID_TO_CASE[$pid]:-PID$pid}")
    done
fi
BLOCK
```

- [ ] **Step 2: Verify job TSV is built correctly (dry check)**

```bash
source ~/cip_source/ChestImagingPlatform-master/vessel_pipeline/env.sh
# Run just far enough to create the TSV, then kill
timeout 5 bash ~/cip_source/ChestImagingPlatform-master/vessel_pipeline/run_vessel_batch.sh \
    /mnt/c/Users/tcher/Desktop/dry \
    --parallel 1 --cores-per-job 4 --runs 1 2>&1 || true
LATEST=$(ls -dt ~/cip_build/runs/batch_* 2>/dev/null | head -1)
[ -f "$LATEST/job_args.tsv" ] && cat "$LATEST/job_args.tsv" | head -3 \
    || echo "No TSV found yet"
```

Expected: tab-separated lines with NII path, output dir, 1, 4, WholeLung, light, (empty).

- [ ] **Step 3: Verify CIP_PATH exports through the run_one_job → worker chain**

The orchestrator exports `CIP_PATH` on line 658. The worker checks `if [ -z "${CIP_PATH:-}" ]` before sourcing env.sh. Verify the export arrives in the worker:

```bash
source ~/cip_source/ChestImagingPlatform-master/vessel_pipeline/env.sh
# Simulate what run_one_job does: call the worker with CIP_PATH exported
export CIP_PATH
bash ~/cip_source/ChestImagingPlatform-master/vessel_pipeline/run_scan_worker.sh \
    /nonexistent.nii.gz /tmp/env_test \
    --runs 1 --cores 4 --cleanup light 2>&1 | grep -E "source|env.sh|CIP_PATH|pre-check|binary not found" | head -5
```

Expected: worker reaches the binary pre-check (not the env.sh sourcing block) because `CIP_PATH` is already set. If "source" or "env.sh" appears before "pre-check", the guard is broken.

GNU parallel inherits exported variables from the calling shell, so this export chain also applies when dispatching via `parallel`. No additional action needed if the above passes.

---

## Task 11: Orchestrator — aggregate summary

**Files:**
- Modify: `vessel_pipeline/run_vessel_batch.sh`

- [ ] **Step 1: Append aggregate summary block**

```bash
cat >> ~/cip_source/ChestImagingPlatform-master/vessel_pipeline/run_vessel_batch.sh << 'BLOCK'

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
CSV_COUNT=$(ls "$SUMMARY_DIR"/*.csv 2>/dev/null | wc -l)
echo ""
echo "Phenotype CSVs collected: $CSV_COUNT -> $SUMMARY_DIR"

# Watchdog events
WARN_COUNT=$(grep -c "WARNING\|CRITICAL" "$WATCHDOG_LOG" 2>/dev/null || echo 0)
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
BLOCK
```

- [ ] **Step 2: Commit the complete orchestrator**

```bash
cd ~/cip_source/ChestImagingPlatform-master
git -c user.email="ThomasShelby47735@gmail.com" -c user.name="Sam Tcherner" \
  add vessel_pipeline/run_vessel_batch.sh
git -c user.email="ThomasShelby47735@gmail.com" -c user.name="Sam Tcherner" \
  commit -m "feat: add run_vessel_batch.sh

Orchestrator: env setup, CLI, memory pre-flight, collision detection,
watchdog (warn 20%/crit 10% MemAvailable), run_one_job() shared interface,
TSV + GNU parallel dispatch with PID loop fallback (10s stagger),
aggregate particle count table + phenotype CSV collection."
```

---

## Task 12: PowerShell launcher — resource probe and allocation math

**Files:**
- Create: `/mnt/c/Users/tcher/Desktop/Start-CIPBatch.ps1`

- [ ] **Step 1: Create the file with header, param block, and resource probe**

```powershell
# Write to Windows desktop
$content = @'
<#
.SYNOPSIS
    Resource-aware CIP vessel pipeline batch launcher for WSL2.
.PARAMETER DataDir
    Path to directory containing .nii.gz participant scans.
.PARAMETER ReserveRAM_GB
    RAM in GB to keep for Windows. Default: 4.
.PARAMETER ReserveCores
    CPU cores to keep for Windows. Default: 2.
.PARAMETER RunsPerParticipant
    Extraction runs per scan (for stochasticity measurement). Default: 1.
.PARAMETER Region
    CIP lung region. Default: WholeLung.
.PARAMETER DryRun
    Print config without making any changes or launching.
.PARAMETER ForceParallel
    Override auto-calculated parallelism.
.PARAMETER Cleanup
    Cleanup policy: none|light|all. Default: light.
.EXAMPLE
    .\Start-CIPBatch.ps1 -DataDir "C:\Users\tcher\Desktop\dry"
    .\Start-CIPBatch.ps1 -DataDir "C:\Users\tcher\Desktop\dry" -DryRun
    .\Start-CIPBatch.ps1 -DataDir "C:\Users\tcher\Desktop\dry" -RunsPerParticipant 2 -ReserveRAM_GB 6
#>
param(
    [Parameter(Mandatory=$true)][string]$DataDir,
    [int]$ReserveRAM_GB   = 4,
    [int]$ReserveCores    = 2,
    [int]$RunsPerParticipant = 1,
    [string]$Region       = "WholeLung",
    [switch]$DryRun,
    [int]$ForceParallel   = 0,
    [string]$Cleanup      = "light"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  CIP Vessel Pipeline — Resource Probe  " -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

# ── Resource probe ────────────────────────────────────────────────────────────
$totalRAM_GB   = [math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB, 1)
$availRAM_GB   = [math]::Round((Get-CimInstance Win32_OperatingSystem).FreePhysicalMemory / 1MB, 1)
$cpuInfo       = Get-CimInstance Win32_Processor
$totalCores    = ($cpuInfo | Measure-Object -Property NumberOfCores          -Sum).Sum
$totalLogical  = ($cpuInfo | Measure-Object -Property NumberOfLogicalProcessors -Sum).Sum
$cpuUsage      = try {
    [math]::Round((Get-Counter '\Processor(_Total)\% Processor Time' -SampleInterval 1 -MaxSamples 1 `
        -ErrorAction SilentlyContinue).CounterSamples[0].CookedValue, 1)
} catch { 0 }

# GPU/ML hog detection
$gpuHogs = Get-Process -ErrorAction SilentlyContinue |
    Where-Object { $_.ProcessName -match 'llama|ollama|cuda|python' -and
                   $_.WorkingSet64 -gt 1GB }
$gpuHogRAM_GB = 0
if ($gpuHogs) {
    $gpuHogRAM_GB = [math]::Round(($gpuHogs | Measure-Object -Property WorkingSet64 -Sum).Sum / 1GB, 1)
}

# Current WSL2 RAM usage
$wslProcs = Get-Process -Name "vmmem*" -ErrorAction SilentlyContinue
$wslCurrentRAM_GB = 0
if ($wslProcs) {
    $wslCurrentRAM_GB = [math]::Round(($wslProcs | Measure-Object -Property WorkingSet64 -Sum).Sum / 1GB, 1)
}

Write-Host "System Resources:" -ForegroundColor Yellow
Write-Host "  Total RAM:        $totalRAM_GB GB"
Write-Host "  Available RAM:    $availRAM_GB GB"
Write-Host "  CPU cores:        $totalCores physical / $totalLogical logical"
Write-Host "  CPU usage:        $cpuUsage%"
Write-Host "  WSL2 current:     $wslCurrentRAM_GB GB"
if ($gpuHogRAM_GB -gt 0) {
    Write-Host "  GPU/ML processes: $gpuHogRAM_GB GB" -ForegroundColor Red
}
Write-Host ""

# ── Allocation math ───────────────────────────────────────────────────────────
$wslRAM_GB   = [math]::Max([math]::Floor($totalRAM_GB - $ReserveRAM_GB - $gpuHogRAM_GB), 4)
$wslSwap_GB  = [math]::Max([math]::Floor($wslRAM_GB / 2), 2)
$wslCores    = [math]::Max($totalLogical - $ReserveCores, 2)

$maxByRAM    = [math]::Floor(($wslRAM_GB - 2) / 4)
$maxByCPU    = [math]::Floor($wslCores / 4)
$maxParallel = [math]::Max([math]::Min($maxByRAM, $maxByCPU), 1)
$coresPerJob = [math]::Max([math]::Floor($wslCores / $maxParallel), 1)

if ($ForceParallel -gt 0) {
    $maxParallel = $ForceParallel
    Write-Host "  *** Parallelism forced to $ForceParallel ***" -ForegroundColor Red
}

if ($gpuHogRAM_GB -gt 1) {
    $maxWithoutHogs = [math]::Floor(($wslRAM_GB + $gpuHogRAM_GB - 2) / 4)
    Write-Host "WARNING: GPU/ML processes use $gpuHogRAM_GB GB." -ForegroundColor Red
    Write-Host "  Without them: $maxWithoutHogs parallel jobs possible." -ForegroundColor Red
    Write-Host ""
}

$participants = (Get-ChildItem -Path $DataDir -Filter "*.nii.gz" -Recurse -ErrorAction SilentlyContinue).Count
$totalRuns    = $participants * $RunsPerParticipant
$estHours     = [math]::Round($totalRuns / $maxParallel * 40 / 60, 1)

Write-Host "Allocation Plan:" -ForegroundColor Yellow
Write-Host "  WSL2 RAM:         $wslRAM_GB GB  (reserve $ReserveRAM_GB GB for Windows)"
Write-Host "  WSL2 swap:        $wslSwap_GB GB"
Write-Host "  WSL2 cores:       $wslCores  (reserve $ReserveCores for Windows)"
Write-Host "  Max parallel:     $maxParallel"
Write-Host "  Cores per job:    $coresPerJob"
Write-Host "  Scans found:      $participants"
Write-Host "  Runs/scan:        $RunsPerParticipant"
Write-Host "  Total runs:       $totalRuns"
Write-Host "  Est. time:        ~$estHours hrs"
Write-Host ""
'@
$content | Out-File -FilePath "/mnt/c/Users/tcher/Desktop/Start-CIPBatch.ps1" -Encoding utf8
```

Note: since we are on WSL2, write the file via bash by echoing to the Windows path. The PowerShell content above should be written to the file; in practice, create it from WSL using:

```bash
cat > /mnt/c/Users/tcher/Desktop/Start-CIPBatch.ps1 << 'EOF'
# [paste entire PowerShell content above here]
EOF
```

The actual file creation is done in Step 2 using a Python heredoc to avoid bash quoting issues with the PowerShell content.

- [ ] **Step 2: Write Start-CIPBatch.ps1 to Windows desktop**

```bash
python3 - << 'PYEOF'
content = r"""
<#
.SYNOPSIS
    Resource-aware CIP vessel pipeline batch launcher for WSL2.
.PARAMETER DataDir
    Path to directory containing .nii.gz participant scans.
.PARAMETER ReserveRAM_GB
    RAM in GB to keep for Windows. Default: 4.
.PARAMETER ReserveCores
    CPU cores to keep for Windows. Default: 2.
.PARAMETER RunsPerParticipant
    Extraction runs per scan. Default: 1.
.PARAMETER Region
    CIP lung region. Default: WholeLung.
.PARAMETER DryRun
    Print config without making changes or launching.
.PARAMETER ForceParallel
    Override auto-calculated parallelism.
.PARAMETER Cleanup
    Cleanup policy: none|light|all. Default: light.
.EXAMPLE
    .\Start-CIPBatch.ps1 -DataDir "C:\Users\tcher\Desktop\dry"
    .\Start-CIPBatch.ps1 -DataDir "C:\Users\tcher\Desktop\dry" -DryRun
    .\Start-CIPBatch.ps1 -DataDir "C:\Users\tcher\Desktop\dry" -RunsPerParticipant 2
#>
param(
    [Parameter(Mandatory=$true)][string]$DataDir,
    [int]$ReserveRAM_GB      = 4,
    [int]$ReserveCores       = 2,
    [int]$RunsPerParticipant = 1,
    [string]$Region          = "WholeLung",
    [switch]$DryRun,
    [int]$ForceParallel      = 0,
    [string]$Cleanup         = "light"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  CIP Vessel Pipeline - Resource Probe  " -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

# Resource probe
$totalRAM_GB  = [math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB, 1)
$availRAM_GB  = [math]::Round((Get-CimInstance Win32_OperatingSystem).FreePhysicalMemory / 1MB, 1)
$cpuInfo      = Get-CimInstance Win32_Processor
$totalCores   = ($cpuInfo | Measure-Object -Property NumberOfCores -Sum).Sum
$totalLogical = ($cpuInfo | Measure-Object -Property NumberOfLogicalProcessors -Sum).Sum
$cpuUsage = try {
    [math]::Round((Get-Counter '\Processor(_Total)\% Processor Time' -SampleInterval 1 -MaxSamples 1 `
        -ErrorAction SilentlyContinue).CounterSamples[0].CookedValue, 1)
} catch { 0 }

$gpuHogs = Get-Process -ErrorAction SilentlyContinue |
    Where-Object { $_.ProcessName -match 'llama|ollama|cuda|python' -and $_.WorkingSet64 -gt 1GB }
$gpuHogRAM_GB = 0
if ($gpuHogs) {
    $gpuHogRAM_GB = [math]::Round(($gpuHogs | Measure-Object -Property WorkingSet64 -Sum).Sum / 1GB, 1)
}
$wslProcs = Get-Process -Name "vmmem*" -ErrorAction SilentlyContinue
$wslCurrentRAM_GB = 0
if ($wslProcs) {
    $wslCurrentRAM_GB = [math]::Round(($wslProcs | Measure-Object -Property WorkingSet64 -Sum).Sum / 1GB, 1)
}

Write-Host "System Resources:" -ForegroundColor Yellow
Write-Host "  Total RAM:        $totalRAM_GB GB"
Write-Host "  Available RAM:    $availRAM_GB GB"
Write-Host "  CPU cores:        $totalCores physical / $totalLogical logical"
Write-Host "  CPU usage:        $cpuUsage%"
Write-Host "  WSL2 current:     $wslCurrentRAM_GB GB"
if ($gpuHogRAM_GB -gt 0) {
    Write-Host "  GPU/ML processes: $gpuHogRAM_GB GB" -ForegroundColor Red
}
Write-Host ""

# Allocation math
$wslRAM_GB   = [math]::Max([math]::Floor($totalRAM_GB - $ReserveRAM_GB - $gpuHogRAM_GB), 4)
$wslSwap_GB  = [math]::Max([math]::Floor($wslRAM_GB / 2), 2)
$wslCores    = [math]::Max($totalLogical - $ReserveCores, 2)
$maxByRAM    = [math]::Floor(($wslRAM_GB - 2) / 4)
$maxByCPU    = [math]::Floor($wslCores / 4)
$maxParallel = [math]::Max([math]::Min($maxByRAM, $maxByCPU), 1)
$coresPerJob = [math]::Max([math]::Floor($wslCores / $maxParallel), 1)

if ($ForceParallel -gt 0) {
    $maxParallel = $ForceParallel
    Write-Host "  *** Parallelism forced to $ForceParallel ***" -ForegroundColor Red
}
if ($gpuHogRAM_GB -gt 1) {
    $maxWithoutHogs = [math]::Floor(($wslRAM_GB + $gpuHogRAM_GB - 2) / 4)
    Write-Host "WARNING: GPU/ML processes use $gpuHogRAM_GB GB." -ForegroundColor Red
    Write-Host "  Without them: $maxWithoutHogs parallel jobs possible." -ForegroundColor Red
    Write-Host ""
}
$participants = (Get-ChildItem -Path $DataDir -Filter "*.nii.gz" -Recurse -ErrorAction SilentlyContinue).Count
$totalRuns    = $participants * $RunsPerParticipant
$estHours     = [math]::Round($totalRuns / $maxParallel * 40 / 60, 1)

Write-Host "Allocation Plan:" -ForegroundColor Yellow
Write-Host "  WSL2 RAM:         $wslRAM_GB GB  (reserve $ReserveRAM_GB GB for Windows)"
Write-Host "  WSL2 swap:        $wslSwap_GB GB"
Write-Host "  WSL2 cores:       $wslCores  (reserve $ReserveCores for Windows)"
Write-Host "  Max parallel:     $maxParallel"
Write-Host "  Cores per job:    $coresPerJob"
Write-Host "  Scans found:      $participants"
Write-Host "  Runs/scan:        $RunsPerParticipant"
Write-Host "  Total runs:       $totalRuns"
Write-Host "  Est. time:        ~$estHours hrs"
Write-Host ""
"""
with open('/mnt/c/Users/tcher/Desktop/Start-CIPBatch.ps1', 'w', encoding='utf-8') as f:
    f.write(content.lstrip())
print("Written resource probe section")
PYEOF
```

---

## Task 13: PowerShell launcher — `.wslconfig` handling, WSL path conversion, invocation

**Files:**
- Modify: `/mnt/c/Users/tcher/Desktop/Start-CIPBatch.ps1`

- [ ] **Step 1: Verify Task 12 output is complete before appending**

```bash
[ -f /mnt/c/Users/tcher/Desktop/Start-CIPBatch.ps1 ] || \
    { echo "ERROR: Start-CIPBatch.ps1 missing — complete Task 12 first"; exit 1; }
grep -q "Allocation Plan" /mnt/c/Users/tcher/Desktop/Start-CIPBatch.ps1 || \
    { echo "ERROR: Task 12 output incomplete (missing Allocation Plan section)"; exit 1; }
echo "Task 12 verified OK — $(wc -l < /mnt/c/Users/tcher/Desktop/Start-CIPBatch.ps1) lines"
```

Expected: "Task 12 verified OK — 98 lines" (approximately).

- [ ] **Step 2: Append `.wslconfig` handling and WSL restart logic (atomic write)**

```bash
python3 - << 'PYEOF'
import shutil, os
PS1 = '/mnt/c/Users/tcher/Desktop/Start-CIPBatch.ps1'
TMP = PS1 + '.tmp'
shutil.copy2(PS1, TMP)   # seed temp with existing content

append_content = r"""
# .wslconfig handling
$wslConfigPath = "$env:USERPROFILE\.wslconfig"
$wslConfigContent = "[wsl2]`nmemory=${wslRAM_GB}GB`nswap=${wslSwap_GB}GB`nprocessors=$wslCores`nlocalhostForwarding=true"

Write-Host "WSL2 config ($wslConfigPath):" -ForegroundColor Yellow
Write-Host $wslConfigContent
Write-Host ""

if ($DryRun) {
    Write-Host "=== DRY RUN - no changes made ===" -ForegroundColor Magenta
    exit 0
}

$needsRestart = $false
$currentConfig = if (Test-Path $wslConfigPath) { Get-Content $wslConfigPath -Raw } else { "" }
if ($currentConfig.Trim() -ne $wslConfigContent.Trim()) {
    if (Test-Path $wslConfigPath) {
        Copy-Item $wslConfigPath "$wslConfigPath.bak" -Force
        Write-Host "  Backed up existing .wslconfig to .wslconfig.bak"
    }
    $wslConfigContent | Out-File -FilePath $wslConfigPath -Encoding utf8 -NoNewline
    Write-Host "  Written new .wslconfig" -ForegroundColor Green
    $needsRestart = $true
} else {
    Write-Host ".wslconfig already matches - no restart needed." -ForegroundColor Green
}

if ($needsRestart) {
    $confirm = Read-Host "WSL2 needs restart for new memory settings. Restart now? (y/n) - batch proceeds either way, watchdog handles memory pressure"
    if ($confirm -eq 'y') {
        Write-Host "Restarting WSL2..."
        wsl --shutdown
        Start-Sleep -Seconds 3
        Write-Host "WSL2 restarted." -ForegroundColor Green
    } else {
        # Check current WSL RAM and degrade if insufficient
        $wslMemLine = (wsl free -m 2>$null) | Where-Object { $_ -match '^Mem:' } | Select-Object -First 1
        if ($wslMemLine) {
            $currentWSLRAM_GB = [math]::Floor([int]($wslMemLine -split '\s+')[1] / 1024)
        } else {
            $currentWSLRAM_GB = $wslCurrentRAM_GB
        }
        if ($currentWSLRAM_GB -ge $wslRAM_GB) {
            Write-Host "Current WSL RAM: ${currentWSLRAM_GB}GB - sufficient, proceeding normally." -ForegroundColor Green
        } else {
            $degradedParallel = [math]::Max([math]::Floor($currentWSLRAM_GB / 4), 1)
            Write-Host "WARNING: Current WSL RAM: ${currentWSLRAM_GB}GB, need ${wslRAM_GB}GB for $maxParallel parallel jobs." -ForegroundColor Yellow
            Write-Host "  Proceeding with $degradedParallel parallel job(s) instead." -ForegroundColor Yellow
            $maxParallel = $degradedParallel
            $coresPerJob = [math]::Max([math]::Floor($wslCores / $maxParallel), 1)
        }
    }
}

# WSL path conversion: C:\Users\tcher\Desktop\dry -> /mnt/c/Users/tcher/Desktop/dry
function ConvertTo-WslPath([string]$winPath) {
    $p = $winPath -replace '\\', '/'
    if ($p -match '^([A-Za-z]):(.*)') {
        return '/mnt/' + $Matches[1].ToLower() + $Matches[2]
    }
    return $p
}

$wslDataDir     = ConvertTo-WslPath $DataDir
$wslDesktopPath = ConvertTo-WslPath "$env:USERPROFILE\Desktop"

Write-Host ""
Write-Host "Launching batch in WSL2..." -ForegroundColor Green
Write-Host "  Data:     $wslDataDir"
Write-Host "  Parallel: $maxParallel"
Write-Host "  Cores:    $coresPerJob"
Write-Host "  Runs:     $RunsPerParticipant"
Write-Host "  Region:   $Region"
Write-Host ""

$orchestrator = "~/cip_source/ChestImagingPlatform-master/vessel_pipeline/run_vessel_batch.sh"
$wslArgs = @($orchestrator, $wslDataDir,
    "--parallel", "$maxParallel", "--cores-per-job", "$coresPerJob",
    "--runs", "$RunsPerParticipant", "--region", "$Region",
    "--cleanup", "$Cleanup",
    "--stage-to", "$wslDesktopPath/vessel_particles")

wsl bash @wslArgs

Write-Host ""
Write-Host "Batch complete." -ForegroundColor Green

# Offer to restore .wslconfig
if ($needsRestart -and (Test-Path "$wslConfigPath.bak")) {
    $restore = Read-Host "Restore previous .wslconfig? (y/n)"
    if ($restore -eq 'y') {
        Copy-Item "$wslConfigPath.bak" $wslConfigPath -Force
        Write-Host "Restored .wslconfig. Restart WSL2 to apply." -ForegroundColor Yellow
    }
}
"""
with open(TMP, 'a', encoding='utf-8') as f:
    f.write(append_content)
os.replace(TMP, PS1)   # atomic rename — original preserved if write fails
print("Appended .wslconfig + invocation section")
PYEOF
```

- [ ] **Step 3: Verify the complete file exists and has all sections**

```bash
wc -l /mnt/c/Users/tcher/Desktop/Start-CIPBatch.ps1
grep -n "param\|wslconfig\|ConvertTo-WslPath\|wsl bash\|DryRun" \
    /mnt/c/Users/tcher/Desktop/Start-CIPBatch.ps1
```

Expected: file is ~160+ lines; grep shows all key sections present.

- [ ] **Step 4: Test DryRun from PowerShell (run in Windows PowerShell terminal)**

```powershell
# Run this in a Windows PowerShell window, not in WSL:
cd C:\Users\tcher\Desktop
.\Start-CIPBatch.ps1 -DataDir "C:\Users\tcher\Desktop\dry" -DryRun
```

Expected output includes:
- System Resources section with real RAM/CPU numbers
- Allocation Plan with wslRAM, maxParallel, coresPerJob
- "DRY RUN" message
- No changes to `.wslconfig`

- [ ] **Step 5: Commit everything**

```bash
cd ~/cip_source/ChestImagingPlatform-master
git -c user.email="ThomasShelby47735@gmail.com" -c user.name="Sam Tcherner" \
  add vessel_pipeline/docs/
git -c user.email="ThomasShelby47735@gmail.com" -c user.name="Sam Tcherner" \
  commit -m "feat: add Start-CIPBatch.ps1

PowerShell launcher: WMI resource probe (RAM/CPU/GPU hogs), WSL2 allocation
math, .wslconfig write + prompted restart with graceful RAM-check degradation
on decline, WSL path conversion, wsl bash invocation of run_vessel_batch.sh
with --stage-to Desktop/vessel_particles."
```

---

## Task 14: Integration smoke test

**Files:** Read-only verification — no code changes.

- [ ] **Step 1: Syntax check both Bash scripts**

```bash
bash -n ~/cip_source/ChestImagingPlatform-master/vessel_pipeline/run_scan_worker.sh && echo "worker: OK"
bash -n ~/cip_source/ChestImagingPlatform-master/vessel_pipeline/run_vessel_batch.sh && echo "orchestrator: OK"
```

Expected: both print "OK" with no errors.

- [ ] **Step 2: Run a single-scan batch via the orchestrator**

Copy one scan to a temp directory so the orchestrator processes only that scan (passing the whole dry/ directory would run all scans sequentially):

```bash
source ~/cip_source/ChestImagingPlatform-master/vessel_pipeline/env.sh
NII=$(ls /mnt/c/Users/tcher/Desktop/dry/*.nii.gz | head -1)
SMOKE_DATA=$(mktemp -d /tmp/smoke_data.XXXXX)
cp "$NII" "$SMOKE_DATA/"
OUTBASE=$(mktemp -d ~/cip_build/runs/smoke_test.XXXXX)

bash ~/cip_source/ChestImagingPlatform-master/vessel_pipeline/run_vessel_batch.sh \
    "$SMOKE_DATA" \
    --parallel 1 --cores-per-job 4 --runs 1 --cleanup light \
    --output-base "$OUTBASE" 2>&1 | tee "$OUTBASE/smoke.log"
```

This will take ~15-20 minutes. Monitor:
```bash
tail -f "$OUTBASE"/logs/*.log
```

- [ ] **Step 3: Verify outputs**

After completion:

```bash
# Check particle count table appeared
grep "^DONE" "$OUTBASE"/logs/*.log

# Check connected VTK exists
find "$OUTBASE" -name "connected_vessel_particles.vtk" | head -3

# Check phenotype CSV in summary
ls "$OUTBASE/summary/"

# Check V-stack survived (light cleanup)
find "$OUTBASE" -name "V-*.nrrd" | head -3

# Check watchdog log
head -5 "$OUTBASE/logs/memory_watchdog.log"
```

Expected:
- `DONE <CASE_ID> run1 <N> <elapsed>s` in the log
- `connected_vessel_particles.vtk` present
- At least one CSV in summary/
- `V-*-010.nrrd` files present in tmp/
- Watchdog startup line in log

- [ ] **Step 4: Run two-parallel batch with two scans**

```bash
source ~/cip_source/ChestImagingPlatform-master/vessel_pipeline/env.sh
OUTBASE=$(mktemp -d ~/cip_build/runs/parallel_test.XXXXX)

bash ~/cip_source/ChestImagingPlatform-master/vessel_pipeline/run_vessel_batch.sh \
    /mnt/c/Users/tcher/Desktop/dry \
    --parallel 2 --cores-per-job 4 --runs 1 --cleanup light \
    --output-base "$OUTBASE" 2>&1 | tee "$OUTBASE/parallel.log"
```

Verify:
```bash
grep "^DONE" "$OUTBASE"/logs/*.log | wc -l
```

Expected: count equals the number of scans in the dry/ directory.

- [ ] **Step 5: Final commit with test evidence**

```bash
cd ~/cip_source/ChestImagingPlatform-master
git -c user.email="ThomasShelby47735@gmail.com" -c user.name="Sam Tcherner" \
  commit --allow-empty -m "test: smoke test CIP batch system

Single-scan and two-parallel integration tests passed.
Verified: preprocessing idempotency, V-stack reuse, DONE line format,
connected VTK, phenotype CSV, watchdog startup, light cleanup policy."
```

---

## Self-Review: Spec Coverage Check

| Spec requirement | Task |
|-----------------|------|
| `--perm` patch to pipeline script | Task 1 |
| Worker standalone mode (env.sh if CIP_PATH unset) | Task 2 |
| Binary pre-check incl. `--perm`/`--init` flags | Task 3 |
| CASE_ID derivation (`tr ' ()' '_-_'`) | Task 4 |
| Idempotent preprocessing, atomic .tmp writes | Task 4 |
| Disk check (6 GiB threshold) | Task 5 |
| Vessel extraction, 90-min timeout, REGION_LOWER VTK path | Task 5 |
| Connected particles, exit-code checked | Task 5 |
| Phenotypes: CLI primary, API fallback, non-fatal failure | Task 6 |
| Per-run probe cleanup (always) | Task 6 |
| Artifact validation before staging | Task 6 |
| Windows staging (non-fatal copy failures) | Task 6 |
| DONE summary line | Task 6 |
| Post-loop cleanup: light/all/none | Task 7 |
| Non-zero exit on any failed run | Task 7 |
| Orchestrator: env.sh once, exports | Task 8 |
| Collision detection | Task 8 |
| Pre-flight memory check + parallel reduction | Task 8 |
| Watchdog: warn 20%, crit 10%, SIGTERM largest CIP process | Task 9 |
| `run_one_job()` shared interface, log redirect | Task 10 |
| TSV dispatch + GNU parallel `--colsep` | Task 10 |
| PID loop fallback with 10s stagger | Task 10 |
| Aggregate summary, particle table, phenotype CSV collect | Task 11 |
| Failed case list with log paths | Task 11 |
| PS: resource probe (RAM/CPU/GPU hogs) | Task 12 |
| PS: allocation math | Task 12 |
| PS: .wslconfig write + backup + prompted restart | Task 13 |
| PS: graceful RAM-check degradation on restart decline | Task 13 |
| PS: WSL path conversion | Task 13 |
| PS: conditional `--stage-to` | Task 13 |
| PS: `-DryRun` mode | Task 13 |
| Integration: syntax check, single-scan, two-parallel | Task 14 |
