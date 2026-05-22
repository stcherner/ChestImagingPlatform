# CIP Resource-Aware Batch Processing System — Design Spec

**Date:** 2026-05-21
**Status:** Approved

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
```

---

## Data Flow

```
Start-CIPBatch.ps1
  probes RAM / CPU / GPU processes
  writes ~/.wslconfig (prompts restart; degrades gracefully on decline)
  wsl bash run_vessel_batch.sh <data_dir> \
      --parallel N --cores-per-job M --runs N \
      --cleanup light --stage-to /mnt/c/.../Desktop/vessel_particles

run_vessel_batch.sh
  discovers *.nii.gz in data_dir
  checks for GNU parallel; falls back to PID loop
  pre-flight memory check; reduces --parallel if needed
  starts memory watchdog (background)
  dispatches run_scan_worker.sh into parallel slots (10s stagger)
  waits for all workers; prints aggregate table + phenotype summary
  stops watchdog

run_scan_worker.sh <nii> <output_dir> --runs N --cores N --cleanup X [--stage-to path]
  binary pre-check
  preprocess once (idempotent, atomic .tmp rename)
  for each run:
    disk space check (skip if <6GB free)
    vessel extraction
    connected particle filter
    phenotype computation
    per-run probe file cleanup
    Windows staging (if --stage-to)
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
      V-*-010.nrrd        # kept by light and none; deleted by all
      featureMap.nrrd     # kept by light and none (if present)
      mask.nrrd           # deleted after all runs
      pass*.nrrd          # run-specific; always deleted after each run
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

**Key:** `--tmpDir` points to the case-level `tmp/` for all runs. The V-stack (V-*.nrrd, ~2GB, computed from CT) is reused across runs — run 2+ skip the ~10-minute scale-space blur recomputation.

---

## Section 1: PowerShell Launcher (`Start-CIPBatch.ps1`)

### Parameters
```powershell
-DataDir <string>          # required; path to *.nii.gz directory
-ReserveRAM_GB <int>       # default 4
-ReserveCores <int>        # default 2
-RunsPerParticipant <int>  # default 1
-DryRun <switch>           # print config only
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
   - If `currentWSLRAM_GB >= wslRAM_GB`: "current allocation sufficient, proceeding normally."
   - If insufficient: `maxParallel = max(floor(currentWSLRAM_GB / 4), 1)`; print "Current WSL RAM: XGB, need YGB for N parallel jobs — proceeding with Z parallel job(s) instead."

### WSL Path Conversion
`C:\Users\tcher\Desktop\dry` → `/mnt/c/Users/tcher/Desktop/dry`

### Invocation
```powershell
wsl bash ~/cip_source/ChestImagingPlatform-master/vessel_pipeline/run_vessel_batch.sh "$wslDataDir" `
    --parallel $maxParallel --cores-per-job $coresPerJob `
    --runs $RunsPerParticipant --cleanup $Cleanup `
    --stage-to "$wslDesktopPath/vessel_particles"
```
`--stage-to` is always passed from the PowerShell launcher; omitted when calling the orchestrator directly from bash.

---

## Section 2: Bash Orchestrator (`run_vessel_batch.sh`)

### CLI
```
run_vessel_batch.sh <data_dir>
    --parallel N
    --cores-per-job N
    --runs N              (default 1)
    --cleanup none|light|all  (default light)
    [--stage-to /path]
    [--output-base /path] (default ~/cip_build/runs/batch_<timestamp>)
```

### Startup Sequence
1. **Dependency check:** test for `parallel`. Print install command if missing; set dispatch flag.
2. **Pre-flight memory check:** `MemAvailable` from `/proc/meminfo`. If `availMB < parallel * 4000`, reduce `--parallel` to `floor(availMB / 4000)`, min 1. Print warning.
3. **Scan discovery:** `find "$DATA_DIR" -name "*.nii.gz" -type f | sort`. Exit 1 if empty.
4. **Print plan:** scan count, parallel slots, estimated time.

### Watchdog
Background loop, always starts regardless of `.wslconfig` state:
- Every 5s: read `MemAvailable` and `SwapFree` from `/proc/meminfo`.
- At 20% MemAvailable: log WARNING.
- At 10% MemAvailable: log CRITICAL; send SIGTERM to the largest-RSS process matching `puller|python.*cip_compute|ComputeFeatureStrength|GeneratePartialLungLabelMap`. Killing the Python parent cascades to puller child.
- Writes to `$OUTPUT_BASE/logs/memory_watchdog.log`.
- Stopped on EXIT trap.

### Dispatch
Build job list: `(nii_path, output_dir, runs, cores, cleanup, stage_path)`.

**With GNU parallel:**
```bash
printf '%s\n' "${job_args[@]}" | parallel -j "$MAX_PARALLEL" --delay 10 \
    bash run_scan_worker.sh {1} {2} --runs {3} --cores {4} --cleanup {5} --stage-to {6}
```

**PID loop fallback:**
```bash
# Launch up to MAX_PARALLEL workers; 10s stagger between launches
# Poll PIDs every 5s; collect exit codes; refill slots as workers finish
```

### Aggregate Summary
After all workers finish:
- Parse `DONE <CASE_ID> run<N> <count> <elapsed>` lines from worker stdout (captured in logs).
- Print particle count table.
- `find $OUTPUT_BASE -name '*_vascularPhenotypes.csv' -exec cp {} $OUTPUT_BASE/summary/ \;`
- Print watchdog event count from log.
- Print failed runs list with log paths.

---

## Section 3: Bash Worker (`run_scan_worker.sh`)

### CLI
```
run_scan_worker.sh <nii_path> <output_dir>
    --runs N
    --cores N
    --cleanup none|light|all
    [--stage-to /path]
```

Standalone-runnable for debugging a single scan.

### Binary Pre-check
At startup, verify all required executables are on PATH:
`GenerateMedianFilteredImage`, `GeneratePartialLungLabelMap`,
`ReadParticlesWriteConnectedParticles`, `cip_compute_vessel_particles.py`.
Exit 1 with a clear message listing what is missing.

### Preprocessing Phase (idempotent, runs once)
Writes to `$OUTPUT_DIR/<CASE_ID>/`. Uses atomic write: write to `<file>.tmp`, rename to `<file>` on success. Skip step if final file already exists.

1. **NIfTI→NRRD:** venv python + SimpleITK. Cast to int16.
2. **Median filter:** `GenerateMedianFilteredImage -i CT.nrrd -o CTFiltered.nrrd`
3. **Label map:** `GeneratePartialLungLabelMap --ict CTFiltered.nrrd -o partialLungLabelMap.nrrd`

### Extraction Loop
For run in 1..N:

1. **Disk space check:**
   ```bash
   avail_kb=$(df --output=avail "$CASEDIR" | tail -1)
   if [ "$avail_kb" -lt 6291456 ]; then
       echo "SKIP: <CASE_ID> run$N — insufficient disk ($(( avail_kb / 1048576 ))GB free, need 6GB)"
       exit 1
   fi
   ```

2. **Vessel extraction:**
   ```bash
   ITK_GLOBAL_DEFAULT_NUMBER_OF_THREADS=$CORES \
   OMP_NUM_THREADS=$CORES \
   python cip_compute_vessel_particles.py \
       -i CT.nrrd -l partialLungLabelMap.nrrd \
       --tmpDir "$CASEDIR/tmp" \
       -o "$CASEDIR/run${N}/particles.vtk" \
       -s 0.625 --init Threshold --perm -r WholeLung
   ```

3. **Connected particles:**
   ```bash
   ReadParticlesWriteConnectedParticles \
       -v "run${N}/particles.vtk_wholeLungVesselParticles.vtk" \
       -o "run${N}/connected_vessel_particles.vtk"
   ```

4. **Phenotypes:**
   ```bash
   PYTHONPATH=~/cip_build/CIP-build \
   python vasculature_phenotypes.py \
       -i "run${N}/particles.vtk_wholeLungVesselParticles.vtk" \
       --out_csv "run${N}/${CASE_ID}_vascularPhenotypes.csv" \
       --cid "$CASE_ID" -t Vessel \
       --out_plot "run${N}/${CASE_ID}_vascularPhenotypePlot.png"
   ```

5. **Per-run cleanup (always):**
   Delete from `$CASEDIR/tmp/`: `pass*.nrrd`, `heval*.nrrd`, `hevec*.nrrd`, `hmode.nrrd`, `hess.nrrd`, `val.nrrd`.

6. **Windows staging** (if `--stage-to` provided, non-fatal on failure):
   ```bash
   mkdir -p "$STAGE_PATH/$CASE_ID/run${N}"
   cp particles.vtk connected_vessel_particles.vtk *.csv *.png "$STAGE_PATH/$CASE_ID/run${N}/"
   ```

7. **Summary line to stdout:**
   ```
   DONE <CASE_ID> run<N> <particle_count> <elapsed_s>
   ```

### Post-loop Cleanup
Applied once after all runs complete:
- `light` (default): `rm -f "$CASEDIR/tmp"/V-*.nrrd "$CASEDIR/tmp"/mask.nrrd`
- `all`: `rm -rf "$CASEDIR/tmp"`
- `none`: no action

### Exit Code
Non-zero if any extraction run fails (preprocessing failure, disk check skip, or non-zero from a pipeline binary). Orchestrator uses this to populate the failed-runs list.

---

## Cleanup Policy Reference

| Policy | Per-run (always) | Post-all-runs |
|--------|-----------------|---------------|
| `none` | pass/heval/hevec/hmode/hess/val | nothing |
| `light` | pass/heval/hevec/hmode/hess/val | V-*.nrrd, mask.nrrd |
| `all` | pass/heval/hevec/hmode/hess/val | entire tmp/ |

Default: `light`. V-stack survives for parameter iteration; per-run probe files (small, fast to regenerate) always purged.

---

## Constants Summary

| Constant | Value | Rationale |
|----------|-------|-----------|
| RAM per job | 4GB | Peak from teem puller scale-space optimization |
| WSL headroom | 2GB | OS + venv + idle buffers |
| Cores per job | 4 | ITK/puller sweet spot; diminishing returns above 4 |
| Windows reserve RAM | 4GB | OS + Explorer + basic apps |
| Windows reserve cores | 2 | Prevent UI starvation |
| Launch stagger | 10s | Prevents simultaneous GeneratePartialLungLabelMap peaks |
| Watchdog interval | 5s | Responsive without thrashing /proc reads |
| Watchdog WARNING | 20% MemAvailable | Early signal before pressure becomes critical |
| Watchdog CRITICAL | 10% MemAvailable | Kill largest CIP process |
| Disk check threshold | 6GB | V-stack ~2GB + puller intermediates ~3GB + headroom |
