# CIP Resource-Aware Batch Processing System — Design Spec

**Date:** 2026-05-21
**Status:** Approved (rev 3 — Codex audit applied)

---

## Overview

A two-layer system for running the CIP vessel particle pipeline in parallel across multiple participants on any Windows/WSL2 machine. A PowerShell launcher probes and configures host resources; a Bash orchestrator manages parallel job dispatch and memory safety; a Bash worker handles one scan end-to-end.

---

## File Layout

```
/mnt/c/Users/tcher/Desktop/Start-CIPBatch.ps1
~/cip_source/ChestImagingPlatform-master/vessel_pipeline/
    run_vessel_batch.sh       # orchestrator
    run_scan_worker.sh        # per-scan worker
    env.sh                    # existing, unchanged
    docs/
        2026-05-21-cip-batch-design.md
```

---

## Known Pre-conditions

**`--perm` flag is absent from the production pipeline script** (`Scripts/cip_compute_vessel_particles.py`). This flag adds `-usa true` to the teem puller, allowing particles to move outside the lung mask — confirmed parameter from the reference pipeline. The implementation plan's first step is to add it:

```python
# In Scripts/cip_compute_vessel_particles.py, in the argparse block:
parser.add_argument("--perm", dest="permissive", action="store_true", default=False)
# In VesselParticles call: pass permissive=args.permissive
```

The worker's pre-check verifies this flag is present before dispatching any runs (see Section 3).

---

## Data Flow

```
Start-CIPBatch.ps1
  probes RAM / CPU / GPU processes
  writes ~/.wslconfig (prompts restart; degrades gracefully on decline)
  wsl bash run_vessel_batch.sh <data_dir> \
      --parallel N --cores-per-job M --runs N --region WholeLung \
      --cleanup light [--stage-to /mnt/c/.../Desktop/vessel_particles]

run_vessel_batch.sh
  sources env.sh once; exports PATH/PYTHONPATH/CIP_PATH/TEEM_PATH
  discovers *.nii.gz in data_dir
  checks for GNU parallel; falls back to PID loop
  pre-flight memory check; reduces --parallel if needed
  starts memory watchdog (background)
  dispatches run_scan_worker.sh via run_one_job() into slots (10s stagger)
  waits for all workers; prints aggregate table + phenotype summary
  stops watchdog

run_scan_worker.sh <nii> <output_dir> --runs N --cores N --region R
                   --cleanup X [--stage-to path]
  sources env.sh if CIP_PATH not already exported (standalone mode)
  binary pre-check (including --perm and --init Threshold flag verification)
  derive CASE_ID from filename
  preprocess once (idempotent, atomic .tmp rename)
  for each run:
    disk space check (skip run if <6 GiB free)
    vessel extraction (90-minute timeout)
    connected particle filter (exit-code checked)
    phenotype computation (CLI with Python API fallback; exit-code checked)
    per-run probe file cleanup
    validate artifacts before staging
    Windows staging (if --stage-to, non-fatal copy failures only)
  post-loop V-stack cleanup per policy
  exits non-zero on any failed run
```

---

## Output Structure

```
~/cip_build/runs/batch_<TIMESTAMP>/
  <CASE_ID>/
    CT.nrrd
    CTFiltered.nrrd
    partialLungLabelMap.nrrd
    tmp/
      V-*-010.nrrd        # kept by none and light; deleted only by all
      featureMap.nrrd     # kept by none and light (if generated); deleted only by all
      mask.nrrd           # deleted by light and all; kept by none
      pass*.nrrd          # run-specific probe files; always deleted after each run
      heval*.nrrd, hevec*.nrrd, hmode.nrrd, hess.nrrd, val.nrrd  # same
    run1/
      particles.vtk_wholeLungVesselParticles.vtk
      connected_vessel_particles.vtk
      <CASE_ID>_vascularPhenotypes.csv
      <CASE_ID>_vascularPhenotypePlot.png
    run2/ ...
  logs/
    <CASE_ID>.log
    memory_watchdog.log
  summary/
    *_vascularPhenotypes.csv
```

**Key:** `--tmpDir` is the absolute case-level `$CASEDIR/tmp/` path for all runs of a scan. The V-stack (V-*.nrrd, ~2 GiB, computed from CT) is reused across runs — runs 2+ skip the ~10-minute scale-space blur recomputation.

---

## CASE_ID Derivation

Defined once, used consistently by both orchestrator and worker:

```bash
CASE_ID=$(basename "$NII_PATH" .nii.gz | tr ' ()' '_-_' | tr -d "'\"")
```

Example: `ROB0003-001-V2 (HYPERVENT).nii.gz` → `ROB0003-001-V2_-_HYPERVENT_`

Both orchestrator and worker derive CASE_ID using this exact rule so directory names always agree.

**Collision detection:** During scan discovery, the orchestrator checks for CASE_ID collisions across all discovered NIfTI files and exits with a clear error listing the conflicting filenames if any two files produce the same CASE_ID.

---

## Section 1: PowerShell Launcher (`Start-CIPBatch.ps1`)

### Parameters
```powershell
-DataDir <string>          # required; path to *.nii.gz directory
-ReserveRAM_GB <int>       # default 4
-ReserveCores <int>        # default 2
-RunsPerParticipant <int>  # default 1
-Region <string>           # default WholeLung; passed through to worker
-DryRun <switch>           # print config only, no changes
-ForceParallel <int>       # override auto-calculated parallelism
-Cleanup <string>          # none|light|all; default light
```

### Resource Probe
- Total RAM: `Win32_ComputerSystem.TotalPhysicalMemory`
- Free RAM: `Win32_OperatingSystem.FreePhysicalMemory`
- CPU: `Win32_Processor` — physical cores + logical processors
- CPU usage: `Get-Counter '\Processor(_Total)\% Processor Time'`
- GPU/ML hogs: processes matching `llama|ollama|cuda|python` with WorkingSet >1GB; RAM deducted from budget with warning: "without them: N parallel jobs possible"
- Current WSL RAM: `vmmem*` process WorkingSet

### Allocation Math
```
wslRAM    = floor(totalRAM - reserveRAM - gpuHogRAM), min 4GB
wslSwap   = max(floor(wslRAM / 2), 2GB)
wslCores  = logicalCores - reserveCores, min 2
maxByRAM  = floor((wslRAM - 2) / 4)   # 4GB/job, 2GB WSL headroom
maxByCPU  = floor(wslCores / 4)        # 4 cores/job sweet spot
maxParallel = max(min(maxByRAM, maxByCPU), 1)
coresPerJob = floor(wslCores / maxParallel)
```

### .wslconfig Handling
1. Compute config string.
2. Compare to existing `~/.wslconfig`.
3. If different: back up to `.wslconfig.bak`, write new config.
4. Prompt: *"WSL2 needs to restart to apply new memory settings. Restart now? (y/n) — batch proceeds either way, watchdog handles memory pressure."*
5. **If yes:** `wsl --shutdown`, 3s sleep.
6. **If no:** `wsl free -m` to get current WSL MemTotal.
   - If `currentWSLRAM_GB >= wslRAM_GB`: print "current allocation sufficient, proceeding normally."
   - If insufficient: `maxParallel = max(floor(currentWSLRAM_GB / 4), 1)`; print "Current WSL RAM: XGB, need YGB for N parallel jobs — proceeding with Z parallel job(s) instead."

### WSL Path Conversion
`C:\Users\tcher\Desktop\dry` → `/mnt/c/users/tcher/desktop/dry`

Drive letter is lowercased; backslashes replaced with forward slashes; `C:` → `/mnt/c`.

### Invocation
```powershell
$stageArg = "--stage-to `"$wslDesktopPath/vessel_particles`""
wsl bash ~/cip_source/ChestImagingPlatform-master/vessel_pipeline/run_vessel_batch.sh `
    "$wslDataDir" `
    --parallel $maxParallel --cores-per-job $coresPerJob `
    --runs $RunsPerParticipant --region $Region `
    --cleanup $Cleanup $stageArg
```

`--stage-to` is always included by the PowerShell launcher (which knows the Windows path). When calling `run_vessel_batch.sh` directly from bash without staging, simply omit `--stage-to`.

---

## Section 2: Bash Orchestrator (`run_vessel_batch.sh`)

### Environment Setup
The orchestrator sources `env.sh` once at startup and explicitly exports the key variables:

```bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/env.sh"
export PATH CIP_PATH TEEM_PATH ITKTOOLS_PATH PYTHONPATH
```

Worker subprocesses inherit these exports. Workers source `env.sh` themselves only when running in standalone mode (see Section 3).

### CLI
```
run_vessel_batch.sh <data_dir>
    --parallel N
    --cores-per-job N
    --runs N                   (default 1)
    --region REGION            (default WholeLung)
    --cleanup none|light|all   (default light)
    [--stage-to /path]
    [--output-base /path]      (default ~/cip_build/runs/batch_<timestamp>)
```

### Startup Sequence
1. **Dependency check:** `command -v parallel`. Print "Install with: sudo apt install parallel" if missing; set `USE_PARALLEL=0`.
2. **Pre-flight memory check:** Read `MemAvailable` from `/proc/meminfo`. If `availMB < parallel * 4000`, reduce `--parallel` to `floor(availMB / 4000)`, min 1. Print warning.
3. **Scan discovery + collision check:** `find "$DATA_DIR" -name "*.nii.gz" -type f | sort`. Exit 1 if empty. Derive CASE_ID for each file and check for collisions; exit 1 listing colliding filenames if found.
4. **Print plan:** scan count, parallel slots, region, estimated time.

### Shared Job Interface: `run_one_job()`

Both dispatch modes call a single `run_one_job()` function with identical arguments. This ensures logging, exit-code handling, and staging behave identically regardless of dispatch path:

```bash
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
```

Logging contract: all worker stdout and stderr are redirected to `$LOG_DIR/<CASE_ID>.log` by `run_one_job()`. The orchestrator parses log files after completion to build the summary table.

### Watchdog
Background loop — always starts regardless of `.wslconfig` state:
- Every 5s: read `MemAvailable` and `SwapFree` from `/proc/meminfo`.
- At 20% MemAvailable: log WARNING with current values.
- At 10% MemAvailable: log CRITICAL; find the largest-RSS process matching `puller|python.*cip_compute|ComputeFeatureStrength|GeneratePartialLungLabelMap` via `ps aux --sort=-rss`; send SIGTERM. Log PID and process name.
- **Note:** In parallel mode the watchdog kills the globally largest matching process by RSS, which is the most likely OOM source but may not always be the lowest-priority job. This is acceptable for a safety net — the goal is to prevent OOM, not perfect fairness. The killed worker exits non-zero and is logged as failed.
- Writes to `$OUTPUT_BASE/logs/memory_watchdog.log`.
- Stopped via `trap stop_watchdog EXIT`.

### Dispatch

**With GNU parallel (`USE_PARALLEL=1`):**

Build a TSV file of job arguments (tab-separated, one row per job):
```bash
# job_args.tsv: NII_PATH<TAB>CASE_OUT_DIR<TAB>RUNS<TAB>CORES<TAB>REGION<TAB>CLEANUP<TAB>STAGE_TO
# STAGE_TO is empty string if not provided
for NII in "${NII_FILES[@]}"; do
    CASE_ID=$(basename "$NII" .nii.gz | tr ' ()' '_-_' | tr -d "'\"")
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$NII" "$OUTPUT_BASE/$CASE_ID" \
        "$RUNS" "$CORES" "$REGION" "$CLEANUP" "${STAGE_TO:-}" \
        >> "$OUTPUT_BASE/job_args.tsv"
done

parallel --delay 10 -j "$MAX_PARALLEL" --colsep '\t' \
    run_one_job {1} {2} {3} {4} {5} {6} {7} \
    :::: "$OUTPUT_BASE/job_args.tsv"
```

**PID loop fallback (`USE_PARALLEL=0`):**
```bash
# Build same job list as array of tab-separated strings
# Maintain PIDS array; before each launch wait for a free slot (poll 5s)
# After each launch sleep 10s (stagger)
# On slot freed: call wait $pid; collect exit code; add to FAILED if non-zero
# All launches call run_one_job with the same argument unpacking
```

### Aggregate Summary
After all workers finish:
- Parse `DONE <CASE_ID> run<N> <count> <elapsed_s>` lines from `$LOG_DIR/*.log`.
- Print aligned particle count table.
- `find "$OUTPUT_BASE" -name '*_vascularPhenotypes.csv' -exec cp {} "$OUTPUT_BASE/summary/" \;`
- Print count of WARNING/CRITICAL lines from watchdog log.
- Print failed cases with log paths.

---

## Section 3: Bash Worker (`run_scan_worker.sh`)

### CLI
```
run_scan_worker.sh <nii_path> <output_dir>
    --runs N
    --cores N
    --region REGION
    --cleanup none|light|all
    [--stage-to /path]
```

### Standalone Mode
When invoked directly (not via the orchestrator), required environment variables may not be set. The worker checks at startup:

```bash
if [ -z "$CIP_PATH" ]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    source "$SCRIPT_DIR/env.sh"
fi
```

When invoked via `run_one_job()`, `CIP_PATH` is already exported and this block is skipped.

### Binary Pre-check
Exit 1 with a list of all missing items if any of the following fail:

```bash
# Required binaries
for bin in GenerateMedianFilteredImage GeneratePartialLungLabelMap \
           ReadParticlesWriteConnectedParticles; do
    command -v "$bin" || MISSING+=("$bin")
done

# Pipeline script
[ -f "$PIPELINE" ] || MISSING+=("cip_compute_vessel_particles.py at $PIPELINE")

# --perm flag present in pipeline script
python "$PIPELINE" --help 2>&1 | grep -q -- '--perm' || MISSING+=(
    "--perm flag missing from $(basename "$PIPELINE"). "
    "Add: parser.add_argument('--perm', dest='permissive', action='store_true', default=False)"
    "and wire permissive=args.permissive into VesselParticles()"
)

# --init flag present
python "$PIPELINE" --help 2>&1 | grep -q -- '--init' || MISSING+=("--init flag missing from pipeline script")

[ ${#MISSING[@]} -gt 0 ] && { printf 'ERROR: %s\n' "${MISSING[@]}"; exit 1; }
```

### CASE_ID Derivation
```bash
CASE_ID=$(basename "$NII_PATH" .nii.gz | tr ' ()' '_-_' | tr -d "'\"")
CASEDIR="$OUTPUT_DIR/$CASE_ID"
TMPDIR_SHARED="$CASEDIR/tmp"
mkdir -p "$CASEDIR" "$TMPDIR_SHARED"
```

### Preprocessing Phase (idempotent, runs once per scan)

Uses atomic write: write to `<file>.tmp`, `mv` to `<file>` on success. Skip if final file exists. All paths are absolute. Paths are passed to Python as environment variables to avoid shell quoting issues with special characters in filenames.

1. **NIfTI→NRRD:**
   ```bash
   NII_IN="$NII_PATH" NRRD_OUT="$CASEDIR/CT.tmp.nrrd" \
   python -c "
   import os, SimpleITK as sitk
   img = sitk.ReadImage(os.environ['NII_IN'])
   img = sitk.Cast(img, sitk.sitkInt16)
   sitk.WriteImage(img, os.environ['NRRD_OUT'])
   "
   mv "$CASEDIR/CT.tmp.nrrd" "$CASEDIR/CT.nrrd"
   ```

2. **Median filter:**
   ```bash
   GenerateMedianFilteredImage \
       -i "$CASEDIR/CT.nrrd" \
       -o "$CASEDIR/CTFiltered.tmp.nrrd"
   mv "$CASEDIR/CTFiltered.tmp.nrrd" "$CASEDIR/CTFiltered.nrrd"
   ```

3. **Label map:**
   ```bash
   GeneratePartialLungLabelMap \
       --ict "$CASEDIR/CTFiltered.nrrd" \
       -o "$CASEDIR/partialLungLabelMap.tmp.nrrd"
   mv "$CASEDIR/partialLungLabelMap.tmp.nrrd" "$CASEDIR/partialLungLabelMap.nrrd"
   ```

### Extraction Loop
For `RUN_NUM` in `1..$RUNS`:

**1. Disk space check:**
```bash
AVAIL_KB=$(df --output=avail "$CASEDIR" | tail -1 | tr -d ' ')
if [ "$AVAIL_KB" -lt 6291456 ]; then   # 6 GiB = 6 × 1024² KB
    echo "SKIP $CASE_ID run$RUN_NUM — $(( AVAIL_KB / 1048576 )) GiB free, need 6 GiB"
    RUN_FAILED=1; continue
fi
```

**2. Vessel extraction (90-minute timeout, all paths absolute):**
```bash
RUN_DIR="$CASEDIR/run${RUN_NUM}"
mkdir -p "$RUN_DIR"

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
    --perm
EXIT_CODE=$?

if   [ $EXIT_CODE -eq 124 ]; then
    echo "TIMEOUT $CASE_ID run$RUN_NUM — exceeded 90 min"; RUN_FAILED=1; continue
elif [ $EXIT_CODE -ne 0 ]; then
    echo "FAILED $CASE_ID run$RUN_NUM — exit $EXIT_CODE";  RUN_FAILED=1; continue
fi

# Pipeline appends _${REGION}VesselParticles.vtk to the -o prefix
# Region argument is lowercase internally: WholeLung -> wholeLung
REGION_LOWER="$(echo "$REGION" | sed 's/^\(.\)/\L\1/')"
PARTICLE_VTK="$RUN_DIR/particles.vtk_${REGION_LOWER}VesselParticles.vtk"

if [ ! -f "$PARTICLE_VTK" ]; then
    echo "FAILED $CASE_ID run$RUN_NUM — expected VTK missing: $PARTICLE_VTK"
    RUN_FAILED=1; continue
fi
```

**3. Connected particles (exit-code and output checked):**
```bash
CONNECTED_VTK="$RUN_DIR/connected_vessel_particles.vtk"
ReadParticlesWriteConnectedParticles \
    -v "$PARTICLE_VTK" \
    -o "$CONNECTED_VTK"
if [ $? -ne 0 ] || [ ! -f "$CONNECTED_VTK" ]; then
    echo "FAILED $CASE_ID run$RUN_NUM — ReadParticlesWriteConnectedParticles failed"
    RUN_FAILED=1; continue
fi
```

**4. Phenotype computation (CLI primary, Python API fallback; both exit-code checked):**

The `vasculature_phenotypes.py` script uses `optparse`. Paths passed as environment variables to avoid shell quoting issues.

```bash
PHENO_SCRIPT="$HOME/cip_build/CIP-build/cip_python/phenotypes/vasculature_phenotypes.py"
CSV_OUT="$RUN_DIR/${CASE_ID}_vascularPhenotypes.csv"
PNG_OUT="$RUN_DIR/${CASE_ID}_vascularPhenotypePlot.png"

PYTHONPATH="$HOME/cip_build/CIP-build" \
python "$PHENO_SCRIPT" \
    -i "$PARTICLE_VTK" \
    --out_csv "$CSV_OUT" \
    --cid "$CASE_ID" \
    -t Vessel \
    --out_plot "$PNG_OUT" 2>/dev/null
PHENO_EXIT=$?

if [ $PHENO_EXIT -ne 0 ]; then
    echo "  phenotype CLI failed (exit $PHENO_EXIT) — trying Python API fallback"
    PHENO_IN="$PARTICLE_VTK" PHENO_CSV="$CSV_OUT" PHENO_PNG="$PNG_OUT" \
    PHENO_CID="$CASE_ID" \
    PYTHONPATH="$HOME/cip_build/CIP-build" python - <<'PYEOF'
import os, sys, vtk, numpy as np
sys.path.insert(0, os.environ['HOME'] + '/cip_build/CIP-build')
from cip_python.phenotypes.vasculature_phenotypes import VasculaturePhenotypes
r = vtk.vtkPolyDataReader()
r.SetFileName(os.environ['PHENO_IN']); r.Update()
vp = VasculaturePhenotypes(chest_regions=['WildCard'], pairs=None)
df, fig, _ = vp.execute(r.GetOutput(), os.environ['PHENO_CID'],
                        spacing=np.array([0.625, 0.625, 0.625]))
df.to_csv(os.environ['PHENO_CSV'], index=False)
if fig is not None:
    fig.savefig(os.environ['PHENO_PNG'], dpi=180)
print('phenotype API fallback OK: ' + str(len(df)) + ' rows')
PYEOF
    PHENO_EXIT=$?
fi

if [ $PHENO_EXIT -ne 0 ]; then
    echo "WARNING $CASE_ID run$RUN_NUM — phenotype computation failed (non-fatal)"
    # Phenotype failure does not set RUN_FAILED — particles and connected VTK are still valid
fi
```

**5. Per-run probe file cleanup (always, regardless of policy):**
```bash
rm -f "$TMPDIR_SHARED"/pass*.nrrd \
      "$TMPDIR_SHARED"/heval*.nrrd \
      "$TMPDIR_SHARED"/hevec*.nrrd \
      "$TMPDIR_SHARED"/hmode.nrrd \
      "$TMPDIR_SHARED"/hess.nrrd \
      "$TMPDIR_SHARED"/val.nrrd
```

**6. Artifact validation and Windows staging:**

Validate required artifacts before attempting staging. Staging copy failures are non-fatal; missing artifacts are a warning but do not fail the run (the extraction succeeded):

```bash
ARTIFACTS=("$PARTICLE_VTK" "$CONNECTED_VTK")
[ -f "$CSV_OUT" ] && ARTIFACTS+=("$CSV_OUT")
[ -f "$PNG_OUT" ] && ARTIFACTS+=("$PNG_OUT")

for f in "$PARTICLE_VTK" "$CONNECTED_VTK"; do
    [ -f "$f" ] || echo "WARNING $CASE_ID run$RUN_NUM — expected artifact missing: $(basename $f)"
done

if [ -n "$STAGE_TO" ]; then
    DEST="$STAGE_TO/$CASE_ID/run${RUN_NUM}"
    if mkdir -p "$DEST"; then
        cp "${ARTIFACTS[@]}" "$DEST/" 2>/dev/null \
            && echo "  staged to $DEST" \
            || echo "  WARNING: staging copy failed (Windows mount issue?)"
    else
        echo "  WARNING: cannot create staging dir $DEST (Windows mount unavailable?)"
    fi
fi
```

**7. Summary line to stdout:**
```bash
PARTICLE_COUNT=$(PARTICLE_VTK_PATH="$PARTICLE_VTK" python -c "
import os, vtk
r = vtk.vtkPolyDataReader()
r.SetFileName(os.environ['PARTICLE_VTK_PATH']); r.Update()
print(r.GetOutput().GetNumberOfPoints())")
echo "DONE $CASE_ID run${RUN_NUM} $PARTICLE_COUNT ${ELAPSED_S}s"
```

### Post-loop Cleanup
Applied once after extraction loop exits (whether all runs passed or some failed):

```bash
case "$CLEANUP" in
  light) rm -f "$TMPDIR_SHARED"/mask.nrrd ;;
  all)   rm -rf "$TMPDIR_SHARED" ;;
  none)  ;;
esac
```

### Exit Code
Non-zero if `RUN_FAILED=1` was set by any extraction run, or if preprocessing failed. Orchestrator uses exit code to populate the failed-runs list.

---

## Cleanup Policy Reference

| Policy | Per-run (always) | Post-all-runs |
|--------|-----------------|---------------|
| `none` | pass/heval/hevec/hmode/hess/val | nothing — entire tmp/ preserved |
| `light` | pass/heval/hevec/hmode/hess/val | mask.nrrd only |
| `all` | pass/heval/hevec/hmode/hess/val | entire tmp/ deleted |

Default: `light`. The V-stack (V-*.nrrd) **survives under both `none` and `light`** — it is only deleted under `all`. This is the primary purpose of `light`: keep the expensive reusable artifact, discard the small mask. Per-run probe files are always purged regardless of policy.

---

## Constants Summary

| Constant | Value | Rationale |
|----------|-------|-----------|
| RAM per job | 4 GB | Peak from teem puller scale-space optimization |
| WSL headroom | 2 GB | OS + venv + idle buffers inside WSL |
| Cores per job | 4 | ITK/puller sweet spot; diminishing returns above 4 |
| Windows reserve RAM | 4 GB | OS + Explorer + basic apps |
| Windows reserve cores | 2 | Prevent Windows UI starvation |
| Launch stagger | 10s | Prevents simultaneous GeneratePartialLungLabelMap memory peaks |
| Watchdog interval | 5s | Responsive without thrashing /proc reads |
| Watchdog WARNING | 20% MemAvailable | Early signal before pressure is critical |
| Watchdog CRITICAL | 10% MemAvailable | Kill largest CIP process by RSS |
| Disk check threshold | 6 GiB (6,291,456 KB) | V-stack ~2 GiB + puller intermediates ~3 GiB + 1 GiB headroom |
| Extraction timeout | 5400s (90 min) | Kills hung puller; normal runs finish in 8-18 min |
