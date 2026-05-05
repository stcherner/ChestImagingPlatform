# ChestImagingPlatform Vessel Analysis Pipeline — Complete Build & Deployment Guide

## Table of Contents

1. Background
2. Pipeline Overview
3. System Requirements
4. Source Code Preparation — Patches
5. Full Build Procedure
6. Python Environment Setup
7. Python Compatibility Patches
8. Environment Configuration
9. Running the Pipeline
10. Output Interpretation
11. Troubleshooting Reference
12. Docker Containerization (Future)

---

## 1. Background

This document records the complete process of building and deploying the ChestImagingPlatform (CIP) vessel analysis pipeline on Ubuntu 24.04 (WSL2). CIP is an open-source library developed by the Applied Chest Imaging Laboratory (ACIL) at Brigham and Women's Hospital, funded by NIH grant R01HL116931. It integrates with 3D Slicer and provides quantitative CT-based imaging biomarkers for pulmonary disease assessment.

The vessel analysis pipeline implements the computational vascular morphometry (CVM) approach described in:

> Estépar RS, Ross JC, Krissian K, Schultz T, Washko GR, Kindlmann GL. "Computational Vascular Morphometry for the Assessment of Pulmonary Vascular Disease Based on Scale-Space Particles." *Proc IEEE Int Symp Biomed Imaging*, 2012; pp. 1479–1482. DOI: 10.1109/ISBI.2012.6235851.

The pipeline uses scale-space particles to extract pulmonary vasculature from CT scans and compute biomarkers based on the interrelation between vessel cross-sectional area (CSA) and blood volume (BV). Key output metrics include BV5 (blood volume in vessels < 5mm² CSA) and BV10 (blood volume in vessels > 10mm² CSA), normalized by total blood volume (TBV), which track vascular remodeling in COPD.

### Repository

- Source: `ChestImagingPlatform-master/` (GitHub release archive)
- Repository analysis document: See companion `ChestImagingPlatform_Analysis.md`

---

## 2. Pipeline Overview

The vessel analysis pipeline consists of six sequential steps:

```
Step 1: ConvertDicom          — DICOM directory → NRRD volume
Step 2: GenerateMedianFilteredImage — 3D median noise reduction
Step 3: GeneratePartialLungLabelMap — Otsu + morphology lung segmentation (C++ ITK)
Step 4: cip_compute_vessel_particles.py — Scale-space particle extraction (calls puller/gprobe)
Step 5: ReadParticlesWriteConnectedParticles — MST-based connected component filtering
Step 6: vasculature_phenotypes.py — KDE-based phenotype computation (BV5, BV10, TBV, etc.)
```

### Original Batch Script

```bash
#!/bin/bash
for d in */; do
    cd $d
    for ct_directory in */; do
        ConvertDicom --dir $ct_directory -o CT.nrrd
        GenerateMedianFilteredImage -i CT.nrrd -o CTFiltered.nrrd
        GeneratePartialLungLabelMap --ict CTFiltered.nrrd -o partialLungLabelMap.nrrd
        python Scripts/cip_compute_vessel_particles.py \
            -i CT.nrrd -l partialLungLabelMap.nrrd -r WholeLung \
            --tmpDir /tmp/CIPtemp -o particles.vtk -s 0.625 --init Threshold
        ReadParticlesWriteConnectedParticles \
            -v particles.vtk_wholeLungVesselParticles.vtk \
            -o connected_vessel_particles.vtk
        python cip_python/phenotypes/vasculature_phenotypes.py \
            -i particles.vtk_wholeLungVesselParticles.vtk \
            --out_csv "${d%/}_vascularPhenotypes.csv" --cid "${d%/}" \
            -t Vessel --out_plot "${d%/}_vascularPhenotypePlot.png"
        cd ..
    done
done
```

### Binary Dependencies by Source

| Binary | Source | Purpose |
|---|---|---|
| ConvertDicom | CIP (C++) | DICOM to NRRD conversion |
| GenerateMedianFilteredImage | CIP (C++) | 3D median filter |
| GeneratePartialLungLabelMap | CIP (C++) | Lung mask generation |
| CropLung | CIP (C++) | Crop CT/labelmap to lung bounding box |
| ExtractChestLabelMap | CIP (C++) | Extract specific chest region from label map |
| GenerateBinaryThinning3D | CIP (C++) | 3D skeletonization |
| ComputeFeatureStrength | CIP (C++) | Frangi/StrainEnergy vesselness (not used with --init Threshold) |
| ReadNRRDsWriteVTK | CIP (C++) | Assemble probed arrays into VTK polydata |
| ReadParticlesWriteConnectedParticles | CIP (C++) | Connected component filtering |
| puller | Teem | Scale-space particle optimizer (core engine) |
| gprobe | Teem | Hessian eigenvalue/eigenvector probing |
| unu | Teem | NRRD array manipulation (crop, resample, arithmetic) |
| pxdistancetransform | ITK-tools | Euclidean distance transform |

---

## 3. System Requirements

### Host System

- Ubuntu 24.04 LTS (tested on WSL2 on Windows 11)
- 16 CPU cores (build uses `-j4` to avoid WSL memory pressure)
- 10+ GB free disk space for build artifacts
- Internet access for downloading source tarballs

### System Packages (require sudo)

```bash
sudo apt-get update && sudo apt-get install -y \
    build-essential git python3 python3-venv python3-pip \
    libgl-dev libglu-dev libxt-dev zlib1g-dev
```

All six packages are required:

| Package | Why |
|---|---|
| build-essential | GCC 13, make |
| git | ITK-tools clone |
| python3, python3-venv, python3-pip | Python environment |
| libgl-dev, libglu-dev | VTK OpenGL2 rendering backend |
| libxt-dev | VTK X11 Xt library |
| zlib1g-dev | Compression (zlib) |

---

## 4. Source Code Preparation — Patches

The CIP source was written for older compilers (GCC 4-8), older Python (2.7), and older libraries. The following patches are required before building with modern toolchains.

### 4.1 SuperBuild Download URLs (S3 → Official Mirrors)

The ACIL S3 bucket (`s3.amazonaws.com/acil/external_deps/`) returns 403 Forbidden. Additionally, git clone operations are unreliable in WSL. All dependency downloads are converted to direct tarball URLs.

**File: `SuperBuild/External_Boost.cmake` (line 36)**

```cmake
# BEFORE
set(${proj}_URL https://s3.amazonaws.com/acil/external_deps/boost_1_65_1.tar.gz)

# AFTER
set(${proj}_URL https://archives.boost.io/release/1.65.1/source/boost_1_65_1.tar.gz)
```

MD5 checksum `ee64fd29a3fe42232c6ac3c419e523cf` remains unchanged.

**File: `SuperBuild/External_zlib.cmake`**

```cmake
# BEFORE
GIT_REPOSITORY "${git_protocol}://github.com/commontk/zlib.git"
GIT_TAG "66a753054b356da85e1838a081aa94287226823e"

# AFTER
URL "https://github.com/commontk/zlib/archive/66a753054b356da85e1838a081aa94287226823e.tar.gz"
```

**File: `SuperBuild/External_SlicerExecutionModel.cmake`**

```cmake
# BEFORE
GIT_REPOSITORY "${git_protocol}://github.com/Slicer/SlicerExecutionModel.git"
GIT_TAG "61bb14d57ff45c8de0f506e23b6ec982fcdf0da2"

# AFTER
URL "https://github.com/Slicer/SlicerExecutionModel/archive/61bb14d57ff45c8de0f506e23b6ec982fcdf0da2.tar.gz"
```

**File: `SuperBuild/External_teem.cmake`**

```cmake
# BEFORE
GIT_REPOSITORY "${git_protocol}://github.com/Slicer/teem"
GIT_TAG e4746083c0e1dc0c137124c41eca5d23adf73bfa

# AFTER
URL "https://github.com/Slicer/teem/archive/e4746083c0e1dc0c137124c41eca5d23adf73bfa.tar.gz"
```

**File: `SuperBuild/External_ITKv4.cmake`**

```cmake
# BEFORE
GIT_REPOSITORY ${ITKv4_REPOSITORY}
GIT_TAG ${ITKv4_GIT_TAG}

# AFTER (inside the if/else for USE_ITK_4.10)
if (USE_ITK_4.10)
  set(ITKv4_URL "https://github.com/Slicer/ITK/archive/16df9b689856....tar.gz")
else()
  set(ITKv4_URL "https://github.com/Slicer/ITK/archive/87f5d83f1592....tar.gz")
endif()
# ... later in ExternalProject_Add:
URL ${ITKv4_URL}
```

**File: `SuperBuild/External_VTKv8.cmake`**

```cmake
# BEFORE
GIT_REPOSITORY "${git_protocol}://${CIP_VTKv8_GIT_REPOSITORY}"
GIT_TAG ${CIP_VTKv8_GIT_TAG}

# AFTER
URL "https://github.com/Slicer/VTK/archive/${CIP_VTKv8_GIT_TAG}.tar.gz"
```

### 4.2 Disable CIPPython (Python 2.7 Miniconda)

The CIPPython target downloads and installs Python 2.7 via Miniconda, which fails on modern systems and is unnecessary since we use our own Python 3.12 venv.

**File: `SuperBuild.cmake` (line 268)**

```cmake
# BEFORE
set(CIP_PYTHON_INSTALL ON CACHE BOOL "Install Python components of CIP")

# AFTER
set(CIP_PYTHON_INSTALL OFF CACHE BOOL "Install Python components of CIP")
```

When OFF, the build uses `FIND_PACKAGE(PythonInterp REQUIRED)` to find the system Python, and the CIPPython external project becomes a no-op.

### 4.3 VTK ExodusII Duplicate Symbol (GCC 10+)

GCC 10+ defaults to `-fno-common`, which makes duplicate global symbol definitions a linker error. Two ExodusII source files define the same dummy symbol.

**File: `~/cip_build/VTKv8/ThirdParty/exodusII/vtkexodusII/src/ex_open_par.c` (line 477)**

```c
// BEFORE
const char exodus_unused_symbol_dummy_1;

// AFTER
const char exodus_unused_symbol_dummy_2;
```

Note: This file is in the downloaded source at `~/cip_build/VTKv8/`, not in the CIP repo itself. The patch must be applied after VTK is downloaded during the first build attempt, then the build is resumed.

### 4.4 ITK VNL Compiler Version Check (GCC 9+)

ITK v4.13's VNL library only recognizes GCC up to version 8 and errors on newer versions.

**File: `~/cip_build/ITKv4/Modules/ThirdParty/VNL/src/vxl/vcl/vcl_compiler.h` (lines 100-101)**

```c
// BEFORE
# else
#  error "Dunno about this gcc"

// AFTER
# elif (__GNUC__>=9)
#  define VCL_GCC_8
```

This tells VNL to treat GCC 9+ the same as GCC 8 (backward compatible for the features VNL uses).

---

## 5. Full Build Procedure

### 5.1 CIP SuperBuild

```bash
# Create build directory on native Linux filesystem (NOT /mnt/c/)
mkdir -p ~/cip_build && cd ~/cip_build

# Source the Python venv (provides cmake via pip)
source /path/to/ChestImagingPlatform-master/vessel_pipeline/venv/bin/activate

# Configure
cmake /path/to/ChestImagingPlatform-master \
    -DCMAKE_BUILD_TYPE=Release \
    -DCIP_SUPERBUILD=ON \
    -DCIP_USE_QT=OFF \
    -DBUILD_TESTING=OFF \
    -DCIP_VTK_RENDERING_BACKEND=OpenGL2 \
    -DCMAKE_C_FLAGS="-fcommon" \
    -DCMAKE_CXX_FLAGS="-fcommon"

# Build (use -j4, not -j$(nproc), to avoid WSL memory exhaustion)
make -j4 2>&1 | tee ~/cip_build/build.log
```

**Important notes:**

- Build on native Linux filesystem (`~/cip_build/`), not on `/mnt/c/`. Cross-filesystem I/O is 5-10x slower and can freeze WSL.
- The source repo can remain on `/mnt/c/` — only the build output needs to be on ext4.
- The `-fcommon` flags restore old GCC behavior for duplicate symbol definitions in Boost/VTK.
- Build time: approximately 60-90 minutes on a modern 16-core machine at `-j4`.

**Build order:**

```
zlib → Boost 1.65.1 → VTK v8 → ITK v4.13 → SlicerExecutionModel → Teem → CIP
```

**Mid-build patches (required during first build):**

The VTK ExodusII fix (Section 4.3) and ITK VNL fix (Section 4.4) must be applied after their respective source tarballs are downloaded and extracted. The typical workflow is:

1. Run `make -j4` — it will fail at VTK with the ExodusII linker error
2. Apply the ExodusII patch to `~/cip_build/VTKv8/ThirdParty/exodusII/vtkexodusII/src/ex_open_par.c`
3. Run `make -j4` again — it will fail at ITK with the VNL compiler error
4. Apply the VNL patch to `~/cip_build/ITKv4/Modules/ThirdParty/VNL/src/vxl/vcl/vcl_compiler.h`
5. Run `make -j4` again — it should complete

### 5.2 ITK-tools (pxdistancetransform)

ITK-tools is a separate project that provides `pxdistancetransform`. It uses the ITK we already built.

```bash
cd ~/cip_build

# Clone (this is small, git clone is fine)
git clone https://github.com/ITKTools/ITKTools.git itktools-src

# Checkout ITK4-compatible version
cd itktools-src
git checkout v0.3.3
cd ..

# Build — CMakeLists.txt is in src/ subdirectory
mkdir itktools-build && cd itktools-build
cmake ~/cip_build/itktools-src/src \
    -DCMAKE_BUILD_TYPE=Release \
    -DITK_DIR=~/cip_build/ITKv4-build
make -j4
```

Note: The full ITK-tools build may fail on some targets (e.g., `pxgaussianimagefilter` has C++17 `throw()` issues). This is fine — `pxdistancetransform` builds early and successfully. Verify:

```bash
ls ~/cip_build/itktools-build/bin/pxdistancetransform
```

### 5.3 Verify All Binaries

```bash
echo "=== CIP Tools ==="
for tool in ConvertDicom GenerateMedianFilteredImage GeneratePartialLungLabelMap \
            ReadParticlesWriteConnectedParticles CropLung ExtractChestLabelMap \
            GenerateBinaryThinning3D ReadNRRDsWriteVTK ComputeFeatureStrength; do
    [ -f ~/cip_build/CIP-build/bin/$tool ] && echo "OK: $tool" || echo "MISSING: $tool"
done

echo "=== Teem ==="
for tool in puller gprobe unu; do
    [ -f ~/cip_build/teem-build/bin/$tool ] && echo "OK: $tool" || echo "MISSING: $tool"
done

echo "=== ITK-tools ==="
[ -f ~/cip_build/itktools-build/bin/pxdistancetransform ] && echo "OK: pxdistancetransform" || echo "MISSING: pxdistancetransform"
```

Expected output: all OK.

---

## 6. Python Environment Setup

### 6.1 Create Virtual Environment

```bash
cd /path/to/ChestImagingPlatform-master
python3 -m venv ./vessel_pipeline/venv
source ./vessel_pipeline/venv/bin/activate
pip install --upgrade pip
```

### 6.2 Install All Python Dependencies

```bash
pip install cmake setuptools cython \
    SimpleITK numpy scipy pandas scikit-learn vtk matplotlib \
    scikit-image networkx pynrrd h5py \
    pydicom lxml nibabel nipype future requests gitpython
```

### 6.3 Verify Imports

```bash
python -c "
import SimpleITK, numpy, scipy, pandas, sklearn, vtk, matplotlib
import skimage, networkx, nrrd, h5py, pydicom, lxml, nibabel, future
print('All imports OK')
"
```

---

## 7. Python Compatibility Patches

The CIP Python code was written for Python 2.7 and older library versions. The following patches are required for Python 3.12 with modern package versions.

### 7.1 `xrange` → `range`

**File: `Scripts/cip_compute_vessel_particles.py`**

```bash
sed -i 's/xrange/range/g' Scripts/cip_compute_vessel_particles.py
```

### 7.2 NRRD Header Binary Read

**File: `Scripts/cip_compute_vessel_particles.py` (line 60)**

```python
# BEFORE
header=nrrd.read_header(open(self._ct_file_name))

# AFTER
header=nrrd.read_header(open(self._ct_file_name, 'rb'))
```

### 7.3 scikit-learn API Change

**File: `cip_python/utils/cluster_particles.py` (line 6)**

```python
# BEFORE
from sklearn.datasets.samples_generator import make_blobs

# AFTER
from sklearn.datasets import make_blobs
```

### 7.4 `scipy.integrate.quadrature` Removed

`quadrature` was removed from scipy. Replaced with a `quad`-based wrapper that preserves the original calling convention. Applied to two files.

**Files: `cip_python/phenotypes/vasculature_phenotypes.py` and `cip_python/phenotypes/vasculature.py`**

```python
# BEFORE
from scipy.integrate import quadrature

# AFTER
from scipy.integrate import quad
import numpy as np
def quadrature(func, a, b, args=None, maxiter=50, **kwargs):
    def _scalar_func(x, *a):
        val = func(x, *a)
        return float(np.squeeze(val))
    if args is not None:
        result, error = quad(_scalar_func, a, b, args=(args,), limit=maxiter)
    else:
        result, error = quad(_scalar_func, a, b, args=(), limit=maxiter)
    return result, error
```

Key details of this wrapper:

- `args=(args,)` wraps the args list as a single tuple element because the original `quadrature` passed args as a list directly, while `quad` unpacks the args tuple
- `np.squeeze(val)` handles scipy KDE's `evaluate()` which returns arrays even for scalar input
- `limit=maxiter` maps the iteration control parameter between the two APIs

### 7.5 `DataFrame.append` Removed in Pandas 2.0

**File: `cip_python/phenotypes/phenotypes.py` (line 240)**

```python
# BEFORE
self._df = self._df.append(tmp, ignore_index=True)

# AFTER
self._df = pd.concat([self._df, pd.DataFrame([tmp])], ignore_index=True)
```

The `pd.DataFrame([tmp])` wrapper is needed because `tmp` is a dict, and `pd.concat` (unlike the old `append`) does not accept raw dicts.

### 7.6 Apply All Patches Script

For convenience, here is a script that applies all Python patches at once:

```bash
#!/bin/bash
# apply_python_patches.sh
# Run from the ChestImagingPlatform-master root directory

REPO=$(pwd)

# 7.1 xrange
sed -i 's/xrange/range/g' "$REPO/Scripts/cip_compute_vessel_particles.py"

# 7.2 NRRD binary read
sed -i "s/nrrd.read_header(open(self._ct_file_name))/nrrd.read_header(open(self._ct_file_name, 'rb'))/" \
    "$REPO/Scripts/cip_compute_vessel_particles.py"

# 7.3 sklearn API
sed -i 's/from sklearn.datasets.samples_generator import make_blobs/from sklearn.datasets import make_blobs/' \
    "$REPO/cip_python/utils/cluster_particles.py"

# 7.4 scipy quadrature (two files)
python3 -c "
for f in [
    '$REPO/cip_python/phenotypes/vasculature_phenotypes.py',
    '$REPO/cip_python/phenotypes/vasculature.py'
]:
    txt = open(f).read()
    txt = txt.replace(
        'from scipy.integrate import quadrature',
        '''from scipy.integrate import quad
import numpy as np
def quadrature(func, a, b, args=None, maxiter=50, **kwargs):
    def _scalar_func(x, *a):
        val = func(x, *a)
        return float(np.squeeze(val))
    if args is not None:
        result, error = quad(_scalar_func, a, b, args=(args,), limit=maxiter)
    else:
        result, error = quad(_scalar_func, a, b, args=(), limit=maxiter)
    return result, error''')
    open(f, 'w').write(txt)
    print(f'Patched {f}')
"

# 7.5 pandas append
sed -i 's/self._df = self._df.append(tmp, ignore_index=True)/self._df = pd.concat([self._df, pd.DataFrame([tmp])], ignore_index=True)/' \
    "$REPO/cip_python/phenotypes/phenotypes.py"

# Clear cached bytecode
find "$REPO/cip_python" -name "__pycache__" -type d -exec rm -rf {} + 2>/dev/null

echo "All Python patches applied."
```

---

## 8. Environment Configuration

### 8.1 Environment Variables

Create an `env.sh` file that sets all required paths:

```bash
#!/bin/bash
# env.sh — source this before running the pipeline

# Paths — adjust these to your installation
export CIP_REPO="/path/to/ChestImagingPlatform-master"
export CIP_BUILD="$HOME/cip_build"

# Activate Python venv
source "$CIP_REPO/vessel_pipeline/venv/bin/activate"

# CIP C++ tools
export CIP_PATH="$CIP_BUILD/CIP-build/bin"

# Teem (puller, gprobe, unu)
export TEEM_PATH="$CIP_BUILD/teem-build/bin"

# ITK-tools (pxdistancetransform)
export ITKTOOLS_PATH="$CIP_BUILD/itktools-build/bin"

# Add all to PATH
export PATH="$CIP_PATH:$TEEM_PATH:$ITKTOOLS_PATH:$PATH"

# CIP Python modules
export PYTHONPATH="$CIP_REPO:$PYTHONPATH"
```

### 8.2 Usage

```bash
source env.sh
```

### 8.3 Verify

```bash
# C++ tools
which ConvertDicom GeneratePartialLungLabelMap puller gprobe pxdistancetransform

# Python
python -c "from cip_python.particles.vessel_particles import VesselParticles; print('CIP Python OK')"
```

---

## 9. Running the Pipeline

### 9.1 Single Subject — Step by Step

```bash
source env.sh
mkdir -p /tmp/cip_test && cd /tmp/cip_test
mkdir -p /tmp/CIPtemp

# Step 1: Convert DICOM to NRRD
ConvertDicom --dir /path/to/dicom/directory -o CT.nrrd

# Step 2: Median filter
GenerateMedianFilteredImage -i CT.nrrd -o CTFiltered.nrrd

# Step 3: Lung mask (real C++ ITK tool)
GeneratePartialLungLabelMap --ict CTFiltered.nrrd -o partialLungLabelMap.nrrd

# Step 4: Vessel particles (~10-30 minutes)
python $CIP_REPO/Scripts/cip_compute_vessel_particles.py \
    -i CT.nrrd \
    -l partialLungLabelMap.nrrd \
    -r WholeLung \
    --tmpDir /tmp/CIPtemp \
    -o particles.vtk \
    -s 0.625 \
    --init Threshold

# Step 5: Connected particles
ReadParticlesWriteConnectedParticles \
    -v particles.vtk_wholeLungVesselParticles.vtk \
    -o connected_vessel_particles.vtk

# Step 6: Phenotype extraction
python $CIP_REPO/cip_python/phenotypes/vasculature_phenotypes.py \
    -i particles.vtk_wholeLungVesselParticles.vtk \
    --out_csv ROB0046_vascularPhenotypes.csv \
    --cid ROB0046 \
    -t Vessel \
    --out_plot ROB0046_vascularPhenotypePlot.png
```

### 9.2 Batch Processing

```bash
#!/bin/bash
source env.sh

INPUT_ROOT="/path/to/subjects"
OUTPUT_ROOT="/path/to/output"

for subject_dir in "$INPUT_ROOT"/*/; do
    subject_id=$(basename "$subject_dir")
    ct_dir="$subject_dir/ct"
    out_dir="$OUTPUT_ROOT/$subject_id"
    tmp_dir="$out_dir/tmp"

    [ ! -d "$ct_dir" ] && echo "SKIP: $subject_id (no ct/ dir)" && continue
    mkdir -p "$out_dir" "$tmp_dir"
    cd "$out_dir"

    echo "=== Processing $subject_id ==="

    ConvertDicom --dir "$ct_dir" -o CT.nrrd
    GenerateMedianFilteredImage -i CT.nrrd -o CTFiltered.nrrd
    GeneratePartialLungLabelMap --ict CTFiltered.nrrd -o partialLungLabelMap.nrrd

    python "$CIP_REPO/Scripts/cip_compute_vessel_particles.py" \
        -i CT.nrrd -l partialLungLabelMap.nrrd -r WholeLung \
        --tmpDir "$tmp_dir" -o particles.vtk -s 0.625 --init Threshold

    ReadParticlesWriteConnectedParticles \
        -v particles.vtk_wholeLungVesselParticles.vtk \
        -o connected_vessel_particles.vtk

    python "$CIP_REPO/cip_python/phenotypes/vasculature_phenotypes.py" \
        -i particles.vtk_wholeLungVesselParticles.vtk \
        --out_csv "${subject_id}_vascularPhenotypes.csv" \
        --cid "$subject_id" \
        -t Vessel \
        --out_plot "${subject_id}_vascularPhenotypePlot.png"

    # Cleanup temp files
    rm -rf "$tmp_dir"

    echo "=== Done: $subject_id ==="
done
```

### 9.3 Key Parameters

| Parameter | Value | Notes |
|---|---|---|
| `-s 0.625` | Voxel size (mm) | Isotropic resampling target; match your CT slice spacing |
| `--init Threshold` | Initialization mode | Threshold at -700 HU; alternatives: Frangi, StrainEnergy, VesselMask |
| `-r WholeLung` | Region | WholeLung, RightLung, LeftLung, or specific lobes |
| `--seedTh -70` | Seed threshold | Hessian feature strength (NOT HU); set by VesselParticles defaults |
| `--liveTh -90` to `-95` | Live threshold | Hessian feature strength; check `vessel_particles.py` for exact default |

### 9.4 Using VIDA Lung Masks (Alternative to Step 3)

If your data includes VIDA segmentations (e.g., `ZUNU_vida-lung.hdr/.img.gz`), you can use those instead of `GeneratePartialLungLabelMap`. A conversion script is needed to map VIDA labels to CIP convention (WHOLELUNG=1, RIGHTLUNG=2, LEFTLUNG=3 in lower 8 bits of uint16).

---

## 10. Output Interpretation

### 10.1 Output Files

| File | Description |
|---|---|
| `CT.nrrd` | Converted CT volume |
| `CTFiltered.nrrd` | Median-filtered CT |
| `partialLungLabelMap.nrrd` | Lung label map (uint16, CIP convention) |
| `particles.vtk_wholeLungVesselParticles.vtk` | VTK polydata with particle positions + Hessian data |
| `connected_vessel_particles.vtk` | Filtered particles (largest connected component) |
| `*_vascularPhenotypes.csv` | Phenotype measurements |
| `*_vascularPhenotypePlot.png` | Blood volume distribution plot |

### 10.2 CSV Columns

| Column | Description |
|---|---|
| CID | Case identifier |
| Region | Chest region (WildCard = all) |
| Type | Vessel |
| TBV | Total intraparenchymal blood volume |
| BV5 | Blood volume in vessels with CSA < 5 mm² |
| BV5_10 | Blood volume in vessels with 5 ≤ CSA < 10 mm² |
| BV10_15 | Blood volume in vessels with 10 ≤ CSA < 15 mm² |
| ... | Continues in 5mm² bins up to BV85_90 |

### 10.3 Expected Ranges

From the 2012 ISBI paper (2,500 COPDGene subjects):

- BV5/TBV: typically 40-60% in healthy subjects; decreases with COPD severity (small vessel pruning)
- BV10+/TBV: typically 20-40%; increases with COPD severity (proximal vessel dilation)
- BV5/TBV and BV10/TBV have an inverse relationship across disease severity
- Total particle count: tens of thousands for a full lung CT

### 10.4 Validated Test Result

Test subject ROB0046 (512×512×649, 0.782×0.782×0.5mm spacing):

- 84,064 vessel particles detected
- TBV: 239,468
- BV5: 119,079 (49.7% of TBV)
- BV5_10: 43,050 (18.0%)
- BV10+: ~77,339 (32.3%)

---

## 11. Troubleshooting Reference

### Build Issues

| Error | Cause | Fix |
|---|---|---|
| `HTTP response code said error 403` on Boost download | ACIL S3 bucket no longer public | Section 4.1: replace URL |
| `No rule to make target CIPPython-installnumpy` | CIPPython tries to build Py2.7 env | Section 4.2: disable CIPPython |
| `multiple definition of exodus_unused_symbol_dummy_1` | GCC 10+ `-fno-common` default | Section 4.3: rename symbol |
| `#error "Dunno about this gcc"` | ITK VNL doesn't recognize GCC 9+ | Section 4.4: extend version check |
| `X11_Xt_LIB could not be found` | Missing libxt-dev | `sudo apt-get install libxt-dev` |
| `No module named 'distutils'` | Python 3.12 removed distutils | `pip install setuptools` |
| `No module named 'Cython'` | CIP Python GCO extension needs Cython | `pip install cython` |
| WSL freezes during build | Too many parallel jobs + cross-fs I/O | Use `-j4` instead of `-j$(nproc)`, build on native Linux fs |
| ITK-tools requires ITK 5 | Latest ITK-tools upgraded to ITK5 | `git checkout v0.3.3` for ITK4 compatibility |
| `dynamic exception specifications` in ITK-tools | C++17 removed `throw()` | Only need `pxdistancetransform`; it builds before the failing target |

### Runtime Issues

| Error | Cause | Fix |
|---|---|---|
| `TEEM_PATH environment variable is not set` | Missing env var | `export TEEM_PATH=~/cip_build/teem-build/bin` |
| `ITKTOOLS_PATH environment variable is not set` | Missing env var | `export ITKTOOLS_PATH=~/cip_build/itktools-build/bin` |
| `command 'python' not found` | Python 3 only has `python3` | Activate the venv |
| `No module named 'pydicom'` | Missing pip package | `pip install pydicom` |
| `No module named 'future'` | Missing pip package | `pip install future` |
| `No module named 'lxml'` | Missing pip package | `pip install lxml` |
| `xrange is not defined` | Python 2 syntax | Section 7.1: sed replace |
| `UnicodeDecodeError` on NRRD read | Text mode on binary file | Section 7.2: add `'rb'` |
| `samples_generator` import error | Old sklearn API | Section 7.3: update import |
| `cannot import name 'quadrature'` | Removed from scipy | Section 7.4: quad wrapper |
| `DataFrame has no attribute 'append'` | Removed in pandas 2.0 | Section 7.5: pd.concat |
| `couldn't fopen` on tmpDir files | tmpDir doesn't exist | `mkdir -p /tmp/CIPtemp` |

---

## 12. Docker Containerization (Future)

Once the pipeline is validated, a Docker image captures the entire environment:

```dockerfile
FROM ubuntu:24.04

RUN apt-get update && apt-get install -y \
    build-essential git python3 python3-venv python3-pip \
    libgl-dev libglu-dev libxt-dev zlib1g-dev && \
    rm -rf /var/lib/apt/lists/*

COPY ChestImagingPlatform-master /opt/cip/src

# Python venv
RUN python3 -m venv /opt/cip/venv && \
    /opt/cip/venv/bin/pip install cmake setuptools cython \
    SimpleITK numpy scipy pandas scikit-learn vtk matplotlib \
    scikit-image networkx pynrrd h5py pydicom lxml nibabel \
    nipype future requests gitpython

# Apply Python patches
RUN cd /opt/cip/src && bash apply_python_patches.sh

# Build CIP (source already has SuperBuild patches applied)
RUN mkdir /opt/cip/build && cd /opt/cip/build && \
    /opt/cip/venv/bin/cmake /opt/cip/src \
    -DCMAKE_BUILD_TYPE=Release -DCIP_SUPERBUILD=ON \
    -DCIP_USE_QT=OFF -DBUILD_TESTING=OFF \
    -DCMAKE_C_FLAGS="-fcommon" -DCMAKE_CXX_FLAGS="-fcommon" && \
    make -j4
# Note: mid-build patches (ExodusII, VNL) must be handled in the Dockerfile
# with intermediate build steps

# Build ITK-tools
RUN cd /opt/cip/build && \
    git clone https://github.com/ITKTools/ITKTools.git itktools-src && \
    cd itktools-src && git checkout v0.3.3 && cd .. && \
    mkdir itktools-build && cd itktools-build && \
    cmake ../itktools-src/src -DCMAKE_BUILD_TYPE=Release \
    -DITK_DIR=/opt/cip/build/ITKv4-build && \
    make pxdistancetransform -j4

# Environment
ENV CIP_PATH=/opt/cip/build/CIP-build/bin
ENV TEEM_PATH=/opt/cip/build/teem-build/bin
ENV ITKTOOLS_PATH=/opt/cip/build/itktools-build/bin
ENV PATH="$CIP_PATH:$TEEM_PATH:$ITKTOOLS_PATH:/opt/cip/venv/bin:$PATH"
ENV PYTHONPATH=/opt/cip/src

ENTRYPOINT ["/opt/cip/src/vessel_pipeline/run_pipeline.sh"]
```

Usage:

```bash
# Build once (~90 min, then cached forever)
docker build -t cip-vessel .

# Run on any data
docker run -v /path/to/data:/data cip-vessel \
    -i /data/dicom -o /data/output -c SUBJECT001

# Save as portable image
docker save cip-vessel | gzip > cip-vessel.tar.gz

# Load on another machine
docker load < cip-vessel.tar.gz
```

---

## Appendix: Directory Structure After Build

```
~/cip_build/                          # Native Linux filesystem
├── Boost-install/                    # Boost 1.65.1 headers + libs
├── VTKv8-build/                      # VTK v8 build
├── ITKv4-build/                      # ITK v4.13 build
├── teem-build/
│   └── bin/
│       ├── puller                    # Scale-space particle optimizer
│       ├── gprobe                    # Volume probing
│       └── unu                       # NRRD array manipulation
├── SlicerExecutionModel-build/
├── CIP-build/
│   └── bin/
│       ├── ConvertDicom
│       ├── GenerateMedianFilteredImage
│       ├── GeneratePartialLungLabelMap
│       ├── CropLung
│       ├── ExtractChestLabelMap
│       ├── GenerateBinaryThinning3D
│       ├── ComputeFeatureStrength
│       ├── ReadNRRDsWriteVTK
│       ├── ReadParticlesWriteConnectedParticles
│       └── [~50 other CIP CLI tools]
└── itktools-build/
    └── bin/
        └── pxdistancetransform

/path/to/ChestImagingPlatform-master/ # Source (can be on /mnt/c/)
├── vessel_pipeline/
│   ├── venv/                         # Python 3.12 virtual environment
│   ├── env.sh                        # Environment setup script
│   ├── setup.sh                      # One-time setup
│   └── run_pipeline.sh               # Pipeline runner
├── Scripts/
│   └── cip_compute_vessel_particles.py  # Main particle script (patched)
├── cip_python/
│   ├── phenotypes/
│   │   ├── vasculature_phenotypes.py    # Phenotype extraction (patched)
│   │   ├── vasculature.py               # (patched)
│   │   └── phenotypes.py               # Base class (patched)
│   ├── particles/
│   │   └── chest_particles.py           # Puller/gprobe orchestration
│   └── utils/
│       └── cluster_particles.py         # (patched)
├── SuperBuild/
│   ├── External_Boost.cmake             # (patched URL)
│   ├── External_zlib.cmake              # (patched: git → tarball)
│   ├── External_ITKv4.cmake             # (patched: git → tarball)
│   ├── External_VTKv8.cmake             # (patched: git → tarball)
│   ├── External_SlicerExecutionModel.cmake # (patched: git → tarball)
│   └── External_teem.cmake              # (patched: git → tarball)
└── SuperBuild.cmake                     # (patched: CIPPython OFF)
```
