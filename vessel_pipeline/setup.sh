#!/usr/bin/env bash
# setup.sh — create venv, install Python deps, build Teem.
# Run once from any directory: bash /path/to/vessel_pipeline/setup.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
TEEM_INSTALL="$SCRIPT_DIR/teem_install"
VENV_DIR="$SCRIPT_DIR/venv"

echo "=== Step 1: Python virtual environment ==="
python3 -m venv "$VENV_DIR"
source "$VENV_DIR/bin/activate"
pip install --upgrade pip
pip install -r "$SCRIPT_DIR/requirements.txt"

# Install cmake 3.x via pip (cmake 4.x breaks Slicer/teem CMakeLists.txt CMP0054 policy)
pip install "cmake>=3.27,<4" -q
# Fix the pip cmake wrapper which breaks on some filesystems (WSL2 NTFS paths)
CMAKE_DATA_BIN="$VENV_DIR/lib/python$(python3 -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')/site-packages/cmake/data/bin"
printf '#!/bin/bash\nexec "%s/cmake" "$@"\n' "$CMAKE_DATA_BIN" > "$VENV_DIR/bin/cmake"
chmod +x "$VENV_DIR/bin/cmake"
echo "venv ready at $VENV_DIR"

echo ""
echo "=== Step 2: Teem (unu, puller, gprobe) ==="

# Check if already built
if command -v puller &>/dev/null && command -v gprobe &>/dev/null && command -v unu &>/dev/null; then
    echo "unu/puller/gprobe already on PATH — skipping Teem build."
else
    # Try apt first (Ubuntu/Debian)
    if apt-cache show teem-apps &>/dev/null 2>&1; then
        echo "Attempting apt install teem-apps..."
        sudo apt-get install -y teem-apps libteem2-dev cmake build-essential zlib1g-dev || true
    fi

    if command -v puller &>/dev/null && command -v gprobe &>/dev/null; then
        echo "Teem installed via apt."
    else
        echo "Building Teem from source..."
        sudo apt-get install -y build-essential zlib1g-dev git || true

        TEEM_SRC="$SCRIPT_DIR/teem_src"
        TEEM_BUILD="$SCRIPT_DIR/teem_build"

        if [ ! -d "$TEEM_SRC/.git" ]; then
            git clone --depth 1 https://github.com/Slicer/teem.git "$TEEM_SRC"
        fi

        mkdir -p "$TEEM_BUILD"
        cmake "$TEEM_SRC" \
            -B "$TEEM_BUILD" \
            -DCMAKE_BUILD_TYPE=Release \
            -DCMAKE_INSTALL_PREFIX="$TEEM_INSTALL" \
            -DTeem_BZIP2=OFF \
            -DTeem_PNG=OFF \
            -DTeem_ZLIB=ON \
            -DTeem_FFTW3=OFF \
            -DBUILD_TESTING=OFF

        cmake --build "$TEEM_BUILD" --parallel "$(nproc)"
        cmake --install "$TEEM_BUILD"

        echo ""
        echo "Teem built and installed to $TEEM_INSTALL"
        echo "Add to PATH: export PATH=\"$TEEM_INSTALL/bin:\$PATH\""

        # Write env file
        cat > "$SCRIPT_DIR/env.sh" <<EOF
#!/usr/bin/env bash
export PATH="$TEEM_INSTALL/bin:\$PATH"
source "$VENV_DIR/bin/activate"
EOF
        echo "Source $SCRIPT_DIR/env.sh to activate the environment."
    fi
fi

echo ""
echo "=== Setup complete ==="
echo "Activate with:"
echo "  source $SCRIPT_DIR/env.sh"
echo "  # or manually:"
echo "  source $VENV_DIR/bin/activate"
if [ -d "$TEEM_INSTALL/bin" ]; then
    echo "  export PATH=\"$TEEM_INSTALL/bin:\$PATH\""
fi
