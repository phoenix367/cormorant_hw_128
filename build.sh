#!/usr/bin/env bash
# build.sh — Cormorant HW build wrapper
#
# Usage:
#   ./build.sh [synth|impl|all] [-jobs N] [-ip-repo DIR]
#
# Stages:
#   synth   synthesis only
#   impl    implementation + bitstream  (requires completed synthesis)
#   all     synthesis + implementation + bitstream  (default)
#
# Options:
#   -jobs N       parallel jobs passed to Vivado runs (default: 8)
#   -ip-repo DIR  path to the HLS kernel IP repository directory;
#                 overrides the path stored in the Vivado project file
#
# Vivado is sourced from VIVADO_SETTINGS if set, otherwise from the default
# Xilinx install at /mnt/data/xilinx/2025.2/settings64.sh.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VIVADO_SETTINGS="${VIVADO_SETTINGS:-/mnt/data/xilinx/2025.2/settings64.sh}"

# Source Vivado environment if vivado is not already on PATH.
if ! command -v vivado &>/dev/null; then
    if [[ ! -f "$VIVADO_SETTINGS" ]]; then
        echo "ERROR: vivado not found in PATH and settings file not found:" >&2
        echo "  $VIVADO_SETTINGS" >&2
        echo "Set VIVADO_SETTINGS to the correct settings64.sh path." >&2
        exit 1
    fi
    # shellcheck source=/dev/null
    source "$VIVADO_SETTINGS"
fi

echo "Using Vivado: $(command -v vivado)"

# Build tclargs array so each token is a separate element (correct quoting).
TCLARGS=()
if [[ $# -gt 0 ]]; then
    TCLARGS=(-tclargs "$@")
fi

vivado -mode batch \
       -source "$SCRIPT_DIR/scripts/build.tcl" \
       -nojournal \
       -nolog \
       "${TCLARGS[@]}"
