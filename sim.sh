#!/usr/bin/env bash
# Copyright 2025 GradeBuilder SL
# SPDX-License-Identifier: Apache-2.0

# sim.sh — Cormorant HW behavioral simulation wrapper
#
# Usage:
#   ./sim.sh [-ip-repo DIR]
#
# Options:
#   -ip-repo DIR  the kernels' IP repository (the parent repo's build/ip_repo_kv260);
#                 overrides the path stored in the Vivado project file
#
# Vivado: the one on PATH (source <Xilinx>/2025.2/settings64.sh first), else
# VIVADO_SETTINGS (that settings64.sh) is sourced.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VIVADO_SETTINGS="${VIVADO_SETTINGS:-}"

if ! command -v vivado &>/dev/null; then
    if [[ ! -f "$VIVADO_SETTINGS" ]]; then
        echo "ERROR: vivado is not on PATH${VIVADO_SETTINGS:+ and $VIVADO_SETTINGS does not exist}:" >&2
        echo "  source <Xilinx>/2025.2/settings64.sh first, or set VIVADO_SETTINGS to it." >&2
        exit 1
    fi
    # shellcheck source=/dev/null
    source "$VIVADO_SETTINGS"
fi

echo "Using Vivado: $(command -v vivado)"

TCLARGS=()
if [[ $# -gt 0 ]]; then
    TCLARGS=(-tclargs "$@")
fi

vivado -mode batch \
       -source "$SCRIPT_DIR/scripts/sim.tcl" \
       -nojournal \
       -nolog \
       "${TCLARGS[@]}"
