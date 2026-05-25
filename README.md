ChestImagingPlatform - Vessel Particle Analysis Pipeline
=========================================================

A reproducible WSL2 build of the CIP vessel analysis pipeline for extracting
pulmonary vascular morphometry from chest CT scans via scale-space particle
systems. Outputs VTK particle files with vessel cross-sectional area and blood
volume metrics (BV5, BV10, TBV).

This is a fork of [acil-bwh/ChestImagingPlatform](https://github.com/acil-bwh/ChestImagingPlatform)
with an automated superbuild system, reproducibility fixes, and a batch
processing pipeline for vessel particle extraction. Dependency versions are
pinned exactly (ITK 4.13.1, VTK 8.2.0, Teem e4746083, Boost 1.65.1) and
two required mid-build patches (ExodusII, VNL) are applied automatically so
the build succeeds on modern GCC without manual intervention.


What This Repo Adds
-------------------

| Component | Description |
|-----------|-------------|
| `build.sh` | 3-pass automated superbuild with patches; builds ITK-tools v0.3.3 |
| `vessel_pipeline/setup.sh` | Creates Python venv, installs deps, builds Teem from pinned commit |
| `vessel_pipeline/env.sh` | Sets `PATH`/`PYTHONPATH` for a built environment |
| `vessel_pipeline/run_scan_worker.sh` | Single-scan vessel particle worker |
| `vessel_pipeline/run_vessel_batch.sh` | GNU parallel batch orchestrator |
| `vessel_pipeline/Start-CIPBatch.ps1` | Windows launcher with automatic WSL2 resource tuning |


Prerequisites
-------------

- WSL2 (Ubuntu 24.04+ recommended)
- GCC 13+ (tested on GCC 15.2.0)
- Python 3.11+ with `python3-venv`
- ~16 GB RAM minimum; 32 GB+ recommended for batch processing
- ~20 GB free disk space for the build tree
- `build-essential`, `git`, `python3`, `python3-venv` (setup.sh installs the rest)

Install system dependencies:

```bash
sudo apt-get install -y build-essential git python3 python3-venv \
    libgl-dev libglu-dev libxt-dev
```


Quick Start
-----------

> For the full detailed walkthrough see `CIP_Vessel_Pipeline_Build_Guide.md`.

**Step 1 — Clone and set up the Python environment + Teem:**

```bash
git clone https://github.com/stcherner/ChestImagingPlatform.git
cd ChestImagingPlatform
bash vessel_pipeline/setup.sh
```

`setup.sh` creates `vessel_pipeline/venv/`, installs all Python dependencies,
installs cmake 3.x via pip (cmake 4.x breaks the superbuild), and builds Teem
(`unu`, `puller`, `gprobe`) from the pinned Slicer fork commit.

**Step 2 — Build the CIP superbuild (ITK + VTK + CIP):**

```bash
bash build.sh [--build-dir /path/to/build] [--jobs 4]
```

This runs three `make` passes, applying the ExodusII and VNL patches between
passes 1 and 2. The full build takes 60-120 minutes depending on hardware.
The default build directory is `$HOME/cip_build`.

**Step 3 — Activate the environment:**

```bash
source vessel_pipeline/env.sh
# Override build dir if needed:
CIP_BUILD_DIR=/custom/path source vessel_pipeline/env.sh
```

**Step 4 — Verify the build:**

```bash
puller --version
gprobe --version
python -c "import cip_python; print('CIP Python OK')"
```


Pipeline Usage
--------------

### Single scan

```bash
source vessel_pipeline/env.sh

bash vessel_pipeline/run_scan_worker.sh \
    /path/to/scan/dir \   # must contain CT.nrrd + partialLungLabelMap.nrrd
    /path/to/output/dir \
    WholeLung \           # region: WholeLung, RightLung, LeftLung, etc.
    4                     # CPU cores to use
```

Key flags passed internally to `cip_compute_vessel_particles.py`:

| Flag | Default | Description |
|------|---------|-------------|
| `--vesselness_th` | 0.5 | Vessel enhancement threshold for particle seeding |
| `--init` | `Threshold` | Seed initialization: `Threshold` (HU > -700) or `Frangi` |
| `--perm` | off | Permissive mode — continues past non-fatal errors |
| `-s` | 0.625 | Voxel spacing (mm) |

### Batch processing

**Linux/WSL2:**

```bash
bash vessel_pipeline/run_vessel_batch.sh \
    /path/to/scans \      # directory of per-case subdirectories
    /path/to/runs \       # output root
    4                     # max parallel jobs
```

**Windows (launches WSL2 automatically):**

```powershell
.\vessel_pipeline\Start-CIPBatch.ps1 `
    -ScanDir "C:\Data\scans" `
    -RunDir  "C:\Data\runs" `
    -MaxParallel 3
```

`Start-CIPBatch.ps1` auto-tunes `$HOME/.wslconfig` (memory and CPU limits)
based on detected system resources before launching the batch.

### Output

Each processed scan produces `particles.vtk` in its output directory. The VTK
file contains point data with vessel morphometry attributes including:

- Cross-sectional area (proxy for vessel scale)
- Vesselness score (Frangi filter response)
- Position and orientation in scanner coordinates

These are used to compute blood volume metrics BV5 (vessels <= 5 mm^2),
BV10 (vessels <= 10 mm^2), and total blood volume (TBV).


Configuration
-------------

| Variable | Default | Description |
|----------|---------|-------------|
| `CIP_BUILD_DIR` | `$HOME/cip_build` | Location of the superbuild tree |
| `BUILD_JOBS` | `4` | make parallelism for `build.sh` |
| `CIP_SRC_DIR` | auto-detected | Path to this repository root |

`vessel_pipeline/env.sh` exports `CIP_PATH`, `TEEM_PATH`, `ITKTOOLS_PATH`,
and `PYTHONPATH` based on `CIP_BUILD_DIR`, and activates the Python venv.

For WSL2 memory tuning, `Start-CIPBatch.ps1` writes `$HOME/.wslconfig`
before launching. You can also set it manually:

```ini
# $HOME/.wslconfig
[wsl2]
memory=24GB
processors=8
```


Key Parameters
--------------

**`vesselness_th = 0.5`** (production default) controls the vesselness mask
threshold used to select voxels for particle seeding. Higher values are more
conservative (fewer seeds, fewer particles); lower values are more sensitive.
Calibration sessions also tested 0.38 (higher sensitivity) and 0.58 (more
conservative). Changing this value will affect output VTK reproducibility —
use the same value across all scans in a study.

**`--init Threshold`** seeds particles at voxels where HU > -700 (air
excluded). **`--init Frangi`** uses the Frangi vesselness filter response
instead. `Threshold` is faster and was found to better match reference
particle counts in this pipeline.

**`--perm`** enables permissive mode, which allows the pipeline to continue
past non-fatal per-region errors. Recommended for batch processing.


Pinned Dependencies
-------------------

| Dependency | Version / Commit |
|------------|-----------------|
| ITK | 4.13.1 commit `87f5d83f` |
| VTK | 8.2.0 commit `31dc6a08` |
| Teem | Slicer fork commit `e4746083` |
| Boost | 1.65.1 (tarball) |
| ITK-tools | v0.3.3 |
| cmake | 3.x via pip (`>=3.27,<4`) |
| Python | 3.11+ (tested on 3.14.4) |
| GCC | 13+ (tested on 15.2.0) |

Two patches are applied automatically by `build.sh`:

1. **ExodusII** (`ex_open_par.c`) — renames `exodus_unused_symbol_dummy_1`
   to avoid a duplicate-symbol link error under GCC 10+.
2. **VNL** (`vcl_compiler.h`) — adds a `# elif (__GNUC__>=9)` branch to
   unblock the GCC version check that hard-errors on GCC 9+.


Known Upstream Issues
---------------------

- Several files in `cip_python/` and `Scripts/` contain hardcoded paths from
  the original BWH developers (`/Users/rolaharmouche/`, `/Users/jross/`,
  etc.). These are in upstream code outside `vessel_pipeline/` and do not
  affect the vessel particle pipeline.
- The repository is approximately 85 MB due to upstream `.nrrd` test data
  files committed directly to git. Migration to
  [Git LFS](https://git-lfs.github.com/) is optional; the vessel pipeline
  does not depend on these files.


References
----------

1. San Jose Estepar R, Ross JC, Harmouche R, Onieva J, Diaz AA, Washko GR.
   "Chest Imaging Platform: An Open-Source Library and Workstation for
   Quantitative Chest Imaging." American Thoracic Society International
   Conference, 2015. doi:10.1164/ajrccm-conference.2015.191.1_MeetingAbstracts.A4975

2. Onieva J, Ross J, Harmouche R, Yarmarkovich A, Lee J, Diaz A, Washko GR,
   San Jose Estepar R. "Chest Imaging Platform: an open-source library and
   workstation for quantitative chest imaging." Int J Comput Assist Radiol
   Surg 2016;11 Suppl 1:S40-S41.

3. Estepar RS, Ross JC, Krissian K, Schultz T, Washko GR, Kindlmann GL.
   "Computational Vascular Morphometry for the Assessment of Pulmonary
   Vascular Disease Based on Scale-Space Particles." Proc IEEE Int Symp
   Biomed Imaging, 2012; pp. 1479-1482. doi:10.1109/ISBI.2012.6235851


Acknowledgments and Attribution
--------------------------------

The Chest Imaging Platform was created and is maintained by the
**Applied Chest Imaging Laboratory (ACIL)** at Brigham and Women's Hospital,
Harvard Medical School.

Original upstream repository: https://github.com/acil-bwh/ChestImagingPlatform

Original CIP contributors include (among others):
[@rjosest](https://github.com/rjosest),
[@jcross186](https://github.com/jcross186),
[@jonieva](https://github.com/jonieva),
[@rharmo](https://github.com/rharmo),
[@rsanjoseestepar](https://github.com/rsanjoseestepar),
and others from the ACIL team.

CIP is funded by the National Heart, Lung, And Blood Institute of the
National Institutes of Health under Award Number R01HL116931. The content
is solely the responsibility of the authors and does not necessarily
represent the official views of the National Institutes of Health.


License
-------

All or portions of this licensed product (such portions are the "Software")
have been obtained under license from The Brigham and Women's Hospital, Inc.
and are subject to the following terms and conditions:

This software is distributed under a BSD-style license. See `License.txt`
for the full Chest Imaging Platform Contribution and Software License
Agreement. Key terms:

- Royalty-free, non-exclusive license to use, reproduce, make derivative
  works of, display and distribute the Software.
- Modified versions must be clearly identified as such and must not be
  misrepresented as the original Software.
- The Software has been designed for research purposes only and has not
  been reviewed or approved by the FDA or any other agency. Clinical
  applications are neither recommended nor advised.
- All applicable attributions, copyright notices and licenses must be
  preserved.
