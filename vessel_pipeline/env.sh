#!/usr/bin/env bash
# Resolve this script's directory so all paths are relative to the repo clone location.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# CIP_BUILD_DIR: where the CIP superbuild outputs live.
# Override before sourcing this file if you built in a non-default location:
#   CIP_BUILD_DIR=/my/build/dir source vessel_pipeline/env.sh
: "${CIP_BUILD_DIR:=$HOME/cip_build}"

export CIP_BUILD_DIR
export CIP_PATH="$CIP_BUILD_DIR/CIP-build/bin"
export TEEM_PATH="$CIP_BUILD_DIR/teem-build/bin"
export ITKTOOLS_PATH="$CIP_BUILD_DIR/itktools-build/bin"
export PATH="$CIP_PATH:$TEEM_PATH:$SCRIPT_DIR/teem_install/bin:$PATH"
export PYTHONPATH="$CIP_BUILD_DIR/CIP-build${PYTHONPATH:+:$PYTHONPATH}"
source "$SCRIPT_DIR/venv/bin/activate"
