#!/usr/bin/env bash
##############################################################################
# Lint the Verilog/SystemVerilog half of the design with Verilator.
#
# GHDL covers the VHDL (see analyze_all.sh) but cannot read Verilog, which
# leaves the ~70 Verilog and SystemVerilog files of the MiSTer core unchecked.
# This closes that gap: Verilator elaborates the module hierarchy and reports
# syntax errors, missing modules, bad parameters and port mismatches.
#
# It is NOT a substitute for synthesis, and it cannot check the mixed-language
# boundaries: T65, iecdrv_via6522, dualport_2clk_ram and the Xilinx XPM macros
# are VHDL or vendor primitives, so Verilator sees them as missing modules.
# Those are listed as expected black boxes below and ignored.
#
# Width warnings are left visible but not fatal: the MiSTer sources carry a
# large number of pre-existing ones, so failing on them would mean failing
# always. Only errors fail the run.
#
# Usage: ./lint_verilog.sh
#
# Set VERILATOR to use a specific binary. A recent Verilator is required:
# 5.020 as packaged by Debian/Ubuntu cannot parse an unpacked array with an
# assignment-pattern initialiser ("wire [4:0] gcr_lut[16] = '{...}"), which
# the MiSTer sources use. 5.053 is known to work.
##############################################################################
set -uo pipefail

cd "$(dirname "$0")"
RTL=../../C64_MiSTerMEGA65/rtl

VERILATOR=${VERILATOR:-verilator}
command -v "$VERILATOR" >/dev/null || { echo "ERROR: $VERILATOR not found."; exit 1; }
echo "   using $("$VERILATOR" --version)"
[ -d "$RTL" ] || { echo "ERROR: $RTL missing - run git submodule update --init."; exit 1; }

# Modules Verilator legitimately cannot find, because they are VHDL or Xilinx
# primitives rather than Verilog. Elaboration still proceeds around them.
EXPECTED_BLACKBOX='T65|iecdrv_via6522|dualport_2clk_ram|xpm_cdc_array_single'

##############################################################################
# iec_drive: the C1541 + C1581 IEC drive hierarchy
##############################################################################
echo "== linting iec_drive (C1541 + C1581) =="
cd "$RTL/iec_drive"
"$VERILATOR" --lint-only -sv --top-module iec_drive \
    -Wno-fatal -Wno-PINMISSING -Wno-IMPLICITSTATIC \
    iec_drive.sv \
    c1541_multi.sv c1541_drv.sv c1541_logic.sv c1541_gcr.sv c1541_track.sv \
    c1541_direct_gcr.sv \
    c1581_multi.sv c1581_drv.sv \
    fdc1772.v floppy.v iecdrv_mos8520.v iecdrv_misc.sv \
    >/tmp/lint_iec.txt 2>&1

real_errors=$(grep -E '^%Error' /tmp/lint_iec.txt \
              | grep -vE "MODMISSING.*($EXPECTED_BLACKBOX)" \
              | grep -vc 'Exiting due to')

blackboxes=$(grep -E '^%Error-MODMISSING' /tmp/lint_iec.txt \
             | sed 's/.*module: //' | tr -d "'" | sort -u | tr '\n' ' ')

warnings=$(grep -cE '^%Warning' /tmp/lint_iec.txt)

echo "   black boxes (expected): $blackboxes"
echo "   pre-existing warnings  : $warnings"

if [ "$real_errors" -ne 0 ]; then
    echo
    echo "   ERRORS:"
    grep -E '^%Error' /tmp/lint_iec.txt \
        | grep -vE "MODMISSING.*($EXPECTED_BLACKBOX)" \
        | grep -v 'Exiting due to' | sed 's/^/      /' | head -20
    echo
    echo "RESULT: $real_errors error(s) in the Verilog sources"
    exit 1
fi

# Confirm the hierarchy really was elaborated, rather than Verilator having
# bailed out early and reported nothing. Only the C1541 is instantiated: the
# C1581 is still commented out in iec_drive.sv because its SD interface has
# not been ported to the MEGA65's two clock domains (see doc/cmd_devices.md),
# so its sources are linted but never appear in the hierarchy.
grep -q "iec_drive\.c1541" /tmp/lint_iec.txt || {
    echo "RESULT: c1541 does not appear in the elaborated hierarchy -"
    echo "        Verilator may have stopped before reaching it."
    exit 1
}
echo "   c1541 present in the elaborated hierarchy"
if grep -q "iec_drive\.c1581" /tmp/lint_iec.txt; then
    echo "   c1581 also present (it has been enabled)"
fi

echo
echo "RESULT: no errors"
