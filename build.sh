#!/usr/bin/env bash
# build.sh — Full CIP SuperBuild with automated mid-build patches.
#
# Tested on: Ubuntu 24.04 / WSL2, GCC 15.2.0, cmake 3.31.10 (pip), Python 3.14.x
#
# Usage:
#   bash build.sh [--build-dir /path/to/build] [--jobs N]
#
# Environment overrides:
#   CIP_BUILD_DIR   where to put the build tree  (default: $HOME/cip_build)
#   CIP_SRC_DIR     path to this repo root        (default: auto-detected)
#   BUILD_JOBS      make parallelism              (default: 4)
#
# The script runs make three times with patches applied between passes:
#   Pass 1 → fails at VTK ExodusII duplicate symbol → apply ExodusII patch
#   Pass 2 → fails at ITK VNL compiler version check → apply VNL patch
#   Pass 3 → completes the full build
#
# After the superbuild, ITK-tools v0.3.3 is built against the superbuild ITK.

set -euo pipefail

# ── Resolve paths ─────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
: "${CIP_SRC_DIR:=$SCRIPT_DIR}"
: "${CIP_BUILD_DIR:=$HOME/cip_build}"
: "${BUILD_JOBS:=4}"

# ── CLI parsing ───────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --build-dir) CIP_BUILD_DIR="$2"; shift 2 ;;
        --jobs)      BUILD_JOBS="$2";    shift 2 ;;
        *) echo "Unknown argument: $1" >&2; exit 1 ;;
    esac
done

echo "=================================================="
echo "  CIP SuperBuild"
echo "=================================================="
echo "  Source:    $CIP_SRC_DIR"
echo "  Build dir: $CIP_BUILD_DIR"
echo "  Jobs:      $BUILD_JOBS"
echo ""

# ── Activate venv (provides cmake 3.x) ───────────────────────────────────────
VENV="$CIP_SRC_DIR/vessel_pipeline/venv"
if [ ! -f "$VENV/bin/activate" ]; then
    echo "ERROR: venv not found at $VENV — run vessel_pipeline/setup.sh first" >&2
    exit 1
fi
source "$VENV/bin/activate"

CMAKE="$VENV/bin/cmake"
if [ ! -x "$CMAKE" ]; then
    echo "ERROR: cmake not found in venv — run vessel_pipeline/setup.sh first" >&2
    exit 1
fi
echo "cmake: $("$CMAKE" --version | head -1)"
echo ""

# ── System deps check ─────────────────────────────────────────────────────────
MISSING_PKGS=()
for pkg in libgl-dev libxt-dev build-essential git; do
    dpkg -s "$pkg" &>/dev/null || MISSING_PKGS+=("$pkg")
done
# libglu-dev was renamed to libglu1-mesa-dev in Ubuntu 24.04; accept either.
if ! dpkg -s libglu1-mesa-dev &>/dev/null && ! dpkg -s libglu-dev &>/dev/null; then
    MISSING_PKGS+=(libglu1-mesa-dev)
fi
if [ ${#MISSING_PKGS[@]} -gt 0 ]; then
    echo "Missing system packages: ${MISSING_PKGS[*]}"
    echo "Installing..."
    if ! sudo apt-get install -y "${MISSING_PKGS[@]}"; then
        echo "" >&2
        echo "ERROR: Could not install system packages automatically." >&2
        echo "Please run manually and then re-run build.sh:" >&2
        echo "  sudo apt-get install -y ${MISSING_PKGS[*]}" >&2
        exit 1
    fi
fi

# ── CMake configure ───────────────────────────────────────────────────────────
mkdir -p "$CIP_BUILD_DIR"
cd "$CIP_BUILD_DIR"

if [ ! -f "$CIP_BUILD_DIR/CMakeCache.txt" ]; then
    echo "=== Configuring ==="
    "$CMAKE" "$CIP_SRC_DIR" \
        -DCMAKE_BUILD_TYPE=Release \
        -DCIP_SUPERBUILD=ON \
        -DCIP_USE_QT=OFF \
        -DCIP_USE_BOOST=ON \
        -DBUILD_TESTING=OFF \
        -DCIP_VTK_RENDERING_BACKEND=OpenGL2 \
        -DUSE_CYTHON=OFF \
        -DADDITIONAL_C_FLAGS="-fcommon -std=gnu11" \
        -DADDITIONAL_CXX_FLAGS="-fcommon -Wno-template-body" \
        -DCMAKE_CXX_VISIBILITY_PRESET=default \
        -DCMAKE_C_VISIBILITY_PRESET=default \
        -DPYTHON_EXECUTABLE="$VENV/bin/python"
else
    echo "=== CMakeCache.txt exists — skipping configure ==="
fi

# ── Helper: apply a sed patch idempotently ───────────────────────────────────
apply_patch_sed() {
    local file="$1" pattern="$2" replacement="$3" description="$4"
    if grep -qF "$replacement" "$file" 2>/dev/null; then
        echo "  [already patched] $description"
    elif grep -qF "$pattern" "$file" 2>/dev/null; then
        sed -i "s|${pattern}|${replacement}|g" "$file"
        echo "  [patched] $description"
    else
        echo "  [ERROR] patch target not found: $description in $file" >&2
        return 1
    fi
}

# ── Build pass 1: VTK source download + first compilation attempt ─────────────
# Expected failures (applied in the error block below):
#   GCC 10-14: ExodusII duplicate symbol in ex_open_par.c
#   GCC 15+:   vtklibxml2/threads.c K&R pthread declarations conflict with
#              system pthread.h (GCC 15 adopted C23 where foo() = foo(void))
#   GCC 15+:   vtkeigen/Transpositions.h trt.derived() triggers -Wtemplate-body
#              hard error (GCC 15 makes this a compile error, not just a warning)
# All three patches are applied proactively after pass 1 so pass 2 clears them.
echo ""
echo "=== Build pass 1 (expect ExodusII / vtklibxml2 / vtkeigen failure) ==="
set +e
make -j"$BUILD_JOBS" 2>&1 | tee -a "$CIP_BUILD_DIR/build.log"
PASS1_EXIT=${PIPESTATUS[0]}
set -e

if [ "$PASS1_EXIT" -ne 0 ]; then
    PASS1_KNOWN=0

    # ── vtklibxml2 threads.c patch (GCC 15+ C23 compat) ──────────────────────
    LIBXML_FILE="$CIP_BUILD_DIR/VTKv8/ThirdParty/libxml2/vtklibxml2/threads.c"
    if [ -f "$LIBXML_FILE" ]; then
        echo ""
        echo "=== Applying vtklibxml2 patch (GCC 15+ C23 compat) ==="
        if grep -q '__GNUC__ < 15' "$LIBXML_FILE" 2>/dev/null; then
            echo "  [already patched] vtklibxml2 K&R pthread declarations"
        elif grep -q 'pthread_mutex_init ()' "$LIBXML_FILE" 2>/dev/null; then
            # Narrow the GCC version guard so empty-arg K&R declarations are
            # skipped on GCC 15+ where () now means (void) under C23 default.
            sed -i \
                's@#if (__GNUC__ == 3 && __GNUC_MINOR__ >= 3) || (__GNUC__ > 3)@#if ((__GNUC__ == 3 \&\& __GNUC_MINOR__ >= 3) || __GNUC__ > 3) \&\& __GNUC__ < 15@' \
                "$LIBXML_FILE"
            echo "  [patched] vtklibxml2 K&R pthread declarations"
        else
            echo "  [WARNING] vtklibxml2 threads.c does not match expected pattern" >&2
        fi
        PASS1_KNOWN=1
    fi

    # ── ExodusII patch (GCC 10+: duplicate symbol) ────────────────────────────
    EXODUS_FILE="$CIP_BUILD_DIR/VTKv8/ThirdParty/exodusII/vtkexodusII/src/ex_open_par.c"
    if [ -f "$EXODUS_FILE" ]; then
        echo ""
        echo "=== Applying ExodusII patch ==="
        apply_patch_sed "$EXODUS_FILE" \
            "exodus_unused_symbol_dummy_1;" \
            "exodus_unused_symbol_dummy_2;" \
            "ExodusII duplicate symbol rename"
        PASS1_KNOWN=1
    fi

    # ── vtkeigen Transpositions.h patch (GCC 15 -Wtemplate-body) ─────────────
    # GCC 15 made -Wtemplate-body a hard compile error. The operator* friend
    # function calls trt.derived() but GCC 15 cannot resolve derived() on
    # Transpose<TranspositionsBase<Derived>> at template definition time.
    # trt.derived() is semantically identical to trt (same type), so drop it.
    EIGEN_FILE="$CIP_BUILD_DIR/VTKv8/ThirdParty/eigen/vtkeigen/eigen/src/Core/Transpositions.h"
    if [ -f "$EIGEN_FILE" ]; then
        echo ""
        echo "=== Applying vtkeigen Transpositions patch (GCC 15 -Wtemplate-body) ==="
        apply_patch_sed "$EIGEN_FILE" \
            "matrix.derived(), trt.derived());" \
            "matrix.derived(), trt);" \
            "vtkeigen Transpositions.h: drop spurious .derived() on trt"
        PASS1_KNOWN=1
    fi

    # ── VTK octree_node.cxx typo patch (GCC 15 -Wtemplate-body) ──────────────
    # octree_node.cxx line 200 has a typo: _M_chilren (missing 'd').
    # GCC 14 and earlier silently accepted the misspelling inside a template
    # body; GCC 15 makes -Wtemplate-body a hard error when a member lookup
    # fails unconditionally in the template definition.
    OCTREE_FILE="$CIP_BUILD_DIR/VTKv8/Utilities/octree/octree_node.cxx"
    if [ -f "$OCTREE_FILE" ]; then
        echo ""
        echo "=== Applying VTK octree_node.cxx typo patch (GCC 15 -Wtemplate-body) ==="
        apply_patch_sed "$OCTREE_FILE" \
            "this->_M_chilren[child];" \
            "this->_M_children[child];" \
            "octree_node.cxx: fix _M_chilren typo → _M_children"
        PASS1_KNOWN=1
    fi

    if [ "$PASS1_KNOWN" -eq 0 ]; then
        echo "Pass 1 failed before VTK sources were downloaded — unrecognized error." >&2
        echo "Check $CIP_BUILD_DIR/build.log for details." >&2
        exit 1
    fi
else
    echo "Pass 1 succeeded (VTK already built or no patches needed)"
fi

# ── Fix VTK visibility after source download ──────────────────────────────────
# VTK's own CMakeLists.txt forces hidden visibility; the top-level flags do not
# propagate into the ExternalProject. Reconfigure the VTK build directory
# directly so Pass 2 compiles and links with default (visible) symbols.
if [ -d "$CIP_BUILD_DIR/VTKv8-build" ]; then
    echo ""
    echo "=== Configuring VTK with proper symbol visibility and Boost graph modules ==="
    cd "$CIP_BUILD_DIR/VTKv8-build"
    "$CMAKE" . \
        -DCMAKE_CXX_VISIBILITY_PRESET=default \
        -DCMAKE_C_VISIBILITY_PRESET=default \
        -DModule_vtkInfovisBoost=ON \
        -DModule_vtkInfovisBoostGraphAlgorithms=ON
    cd "$CIP_BUILD_DIR"
fi

# ── Build pass 2: expect ITK VNL failure ──────────────────────────────────────
echo ""
echo "=== Build pass 2 (expect VNL failure) ==="
set +e
make -j"$BUILD_JOBS" 2>&1 | tee -a "$CIP_BUILD_DIR/build.log"
PASS2_EXIT=${PIPESTATUS[0]}
set -e

if [ "$PASS2_EXIT" -eq 0 ]; then
    echo "Pass 2 succeeded (no VNL failure needed — may already be patched)"
else
    if ! grep -q "Dunno about this gcc" "$CIP_BUILD_DIR/build.log" 2>/dev/null; then
        echo "Pass 2 failed but NOT with the expected VNL error." >&2
        echo "Check $CIP_BUILD_DIR/build.log for details." >&2
        exit 1
    fi
    echo ""
    echo "=== Applying VNL patch ==="
    VNL_FILE="$CIP_BUILD_DIR/ITKv4/Modules/ThirdParty/VNL/src/vxl/vcl/vcl_compiler.h"
    if [ ! -f "$VNL_FILE" ]; then
        echo "ERROR: $VNL_FILE not found" >&2
        exit 1
    fi
    # Replace the full # else + #  error two-line block with GCC 9+ compatibility.
    # Before: # else\n#  error "Dunno about this gcc"
    # After:  # elif (__GNUC__>=9)\n#  define VCL_GCC_8
    if grep -q 'Dunno about this gcc' "$VNL_FILE"; then
        sed -i -z \
            's/# else\n#  error "Dunno about this gcc"/# elif (__GNUC__>=9)\n#  define VCL_GCC_8/' \
            "$VNL_FILE"
        echo "  [patched] VNL GCC 9+ compatibility"
    else
        echo "  [already patched] VNL GCC version check"
    fi

    # ── ITK spFactor.c patch (GCC 15 C23 K&R compat) ─────────────────────────
    # spFactor.c has local forward declarations using K&R empty-arg style:
    #   RealNumber  FindBiggestInColExclude();   (3 occurrences)
    #   RealNumber  FindLargestInCol();           (1 occurrence)
    # GCC 15 C23 interprets () as (void), which conflicts with the actual
    # definitions that take arguments. The file already has proper static
    # prototypes at the top (lines 81-82), so these locals are redundant.
    SPFACTOR_FILE="$CIP_BUILD_DIR/ITKv4/Modules/ThirdParty/VNL/src/vxl/v3p/netlib/sparse/spFactor.c"
    if [ -f "$SPFACTOR_FILE" ]; then
        echo ""
        echo "=== Applying ITK spFactor.c patch (GCC 15 C23 K&R compat) ==="
        if ! grep -qF 'RealNumber  FindBiggestInColExclude();' "$SPFACTOR_FILE" 2>/dev/null; then
            echo "  [already patched] spFactor.c K&R local declarations"
        else
            sed -i '/^RealNumber  FindBiggestInColExclude();$/d' "$SPFACTOR_FILE"
            sed -i '/^RealNumber  FindLargestInCol();$/d' "$SPFACTOR_FILE"
            echo "  [patched] spFactor.c: removed K&R local forward declarations"
        fi
    fi
fi

# ── Build pass 3: final ────────────────────────────────────────────────────────
echo ""
echo "=== Build pass 3 (final) ==="
set +e
make -j"$BUILD_JOBS" 2>&1 | tee -a "$CIP_BUILD_DIR/build.log"
PASS3_EXIT=${PIPESTATUS[0]}
set -e

if [ "$PASS3_EXIT" -ne 0 ]; then
    # VTK 8.2 has a known parallel link race: core .so files (vtkCommonCore,
    # vtkCommonExecutionModel) sometimes aren't ready when downstream libs
    # (vtkOpenGL, vtkIO, vtkRendering) try to link against them. This produces
    # hundreds of "undefined reference to `vtk..." errors and is not a real
    # compilation failure. Retrying with -j2 serializes the link step enough
    # to avoid the race; all object files are already built so only linking runs.
    if grep -q "undefined reference.*vtk" "$CIP_BUILD_DIR/build.log" 2>/dev/null; then
        echo ""
        echo "=== VTK parallel link race detected — retrying with -j2 ==="
        set +e
        make -j2 2>&1 | tee -a "$CIP_BUILD_DIR/build.log"
        RETRY_EXIT=${PIPESTATUS[0]}
        set -e
        if [ "$RETRY_EXIT" -ne 0 ]; then
            echo "ERROR: -j2 retry also failed. Check $CIP_BUILD_DIR/build.log." >&2
            exit 1
        fi
    else
        echo "ERROR: Pass 3 failed (not a VTK link race). Check $CIP_BUILD_DIR/build.log." >&2
        exit 1
    fi
fi

echo ""
echo "=== CIP SuperBuild complete ==="

# ── ITK-tools v0.3.3 ──────────────────────────────────────────────────────────
echo ""
echo "=== Building ITK-tools v0.3.3 ==="

ITKTOOLS_SRC="$CIP_BUILD_DIR/itktools-src"
ITKTOOLS_BUILD="$CIP_BUILD_DIR/itktools-build"

if [ ! -d "$ITKTOOLS_SRC/.git" ]; then
    git clone https://github.com/ITKTools/ITKTools.git "$ITKTOOLS_SRC"
    git -C "$ITKTOOLS_SRC" checkout v0.3.3
elif [ "$(git -C "$ITKTOOLS_SRC" describe --tags 2>/dev/null)" != "v0.3.3" ]; then
    echo "WARNING: itktools-src is not at v0.3.3 — checking out"
    git -C "$ITKTOOLS_SRC" fetch origin
    git -C "$ITKTOOLS_SRC" checkout v0.3.3
fi

mkdir -p "$ITKTOOLS_BUILD"
"$CMAKE" "$ITKTOOLS_SRC/src" \
    -B "$ITKTOOLS_BUILD" \
    -DCMAKE_BUILD_TYPE=Release \
    -DITK_DIR="$CIP_BUILD_DIR/ITKv4-build"
make -C "$ITKTOOLS_BUILD" pxdistancetransform -j"$BUILD_JOBS" 2>&1 | tee -a "$CIP_BUILD_DIR/itktools_build.log"

echo ""
echo "=== ITK-tools build complete ==="

# ── Python compatibility patches (post-build) ─────────────────────────────────
echo ""
echo "=== Applying Python compatibility patches ==="

CLUSTER_PY="$CIP_BUILD_DIR/CIP-build/cip_python/utils/cluster_particles.py"
if [ -f "$CLUSTER_PY" ]; then
    apply_patch_sed "$CLUSTER_PY" \
        'from sklearn.datasets.samples_generator import make_blobs' \
        'from sklearn.datasets import make_blobs' \
        "sklearn samples_generator → sklearn.datasets (removed in sklearn 1.0)"
else
    echo "  [skip] cluster_particles.py not found (cip_python may not have built)"
fi

echo "=== Python patches complete ==="
echo ""
echo "=================================================="
echo "  Full build finished. Activate environment with:"
echo "    source $CIP_SRC_DIR/vessel_pipeline/env.sh"
echo "=================================================="
