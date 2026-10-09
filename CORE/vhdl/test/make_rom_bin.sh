#!/usr/bin/env bash
##############################################################################
# core_sim.vhd loads the C64 ROM as a raw binary (std_C64.mif.bin), but the
# C64_MiSTerMEGA65 submodule only ships the Altera *.mif and a *.mif.hex
# (one byte per line, as produced by Quartus' mif2hex). This script derives
# the raw binary from the committed .hex, so no Quartus install is needed.
#
# Usage: ./make_rom_bin.sh [rom-basename ...]        (default: std_C64)
##############################################################################
set -euo pipefail

ROMS_DIR="$(dirname "$0")/../../C64_MiSTerMEGA65/rtl/roms"
[ $# -gt 0 ] && NAMES=("$@") || NAMES=(std_C64)

for name in "${NAMES[@]}"; do
    hex="$ROMS_DIR/$name.mif.hex"
    bin="$ROMS_DIR/$name.mif.bin"

    if [ ! -f "$hex" ]; then
        echo "ERROR: $hex not found."
        echo "Did you run 'git submodule update --init --recursive'?"
        exit 1
    fi

    python3 -c "
import sys
hex_path, bin_path = sys.argv[1], sys.argv[2]
data = bytes(int(l, 16) for l in open(hex_path) if l.strip())
open(bin_path, 'wb').write(data)
print('%s: %d bytes' % (bin_path, len(data)))
" "$hex" "$bin"
done
