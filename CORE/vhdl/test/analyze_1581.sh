#!/usr/bin/env bash
##############################################################################
# Analyse and elaborate the vendored C1581 (CORE/vhdl/1581) with GHDL.
#
# This gets its own script rather than joining analyze_all.sh because the
# sources need different GHDL settings from the rest of the tree:
#
#   --std=93     one simulation-only package uses "default" as an identifier,
#                which VHDL-2008 made a reserved word
#   -fsynopsys   cpu6502.vhd uses the non-standard std_logic_unsigned package
#   -frelaxed    assorted VHDL-93-era relaxations
#
# Being all VHDL, this drive can be analysed, elaborated and simulated here -
# unlike the MiSTer C1581, whose FDC is Verilog and so cannot be reached by
# GHDL at all. It is also single-clock, which is what makes it viable on the
# MEGA65; see doc/cmd_devices.md.
#
# Usage: ./analyze_1581.sh
##############################################################################
set -uo pipefail

cd "$(dirname "$0")"
SRC=../1581
WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT

command -v ghdl >/dev/null || { echo "ERROR: ghdl not found in PATH."; exit 1; }
[ -d "$SRC" ] || { echo "ERROR: $SRC missing."; exit 1; }

# The subsystem gets its own library: Gideon's 6502 and QNICE both
# define an entity called "alu", which collide in a single library.
GHDL_OPTS="--std=93 -fsynopsys -frelaxed --work=c1581_lib"

# Analysis order matters: packages first, then leaves, then the top. GHDL has
# no automatic ordering for a plain -a sequence.
FILES="
sim/tl_string_util_pkg.vhd
sim/file_io_pkg.vhd
busses/io_bus_pkg.vhd
busses/mem_bus_pkg.vhd
cpu6502/pkg_6502_defs.vhd
cpu6502/pkg_6502_decode.vhd
drive/c1541_pkg.vhd
drive/cia_pkg.vhd
cpu6502/alu.vhd
cpu6502/bit_cpx_cpy.vhd
cpu6502/shifter.vhd
cpu6502/implied.vhd
cpu6502/data_oper.vhd
cpu6502/proc_control.vhd
cpu6502/proc_interrupt.vhd
cpu6502/proc_registers.vhd
cpu6502/proc_core.vhd
cpu6502/cpu6502.vhd
busses/io_bus_splitter.vhd
busses/io_dummy.vhd
busses/mem_bus_arbiter_pri.vhd
busses/mem_to_mem32.vhd
busses/sync_fifo.vhd
drive/cia_timer.vhd
drive/cia_registers.vhd
drive/stepper.vhd
drive/floppy_sound.vhd
drive/drive_registers.vhd
drive/c1541_timing.vhd
drive/wd177x.vhd
drive/cpu_part_1581.vhd
drive/c1581_drive.vhd
glue/c1581_mem_bridge.vhd
glue/c1581_disk_server.vhd
glue/c1581_wrapper.vhd
"

echo "== analysing the vendored C1581 =="
ok=0
fail=0
for f in $FILES; do
    if ghdl -a --workdir="$WORKDIR" $GHDL_OPTS "$SRC/$f" 2>"$WORKDIR/e"; then
        ok=$((ok + 1))
    else
        echo "   FAIL $f"
        grep -m3 "error:" "$WORKDIR/e" | sed 's/^/      /'
        fail=$((fail + 1))
    fi
done
echo "   analysed $ok file(s), $fail failed"
[ "$fail" -ne 0 ] && { echo; echo "RESULT: analysis failed"; exit 1; }

##############################################################################
# Elaborating type-checks the whole hierarchy below the drive.
##############################################################################
echo "== elaborating c1581_wrapper (drive + disk server + memory bridge) =="
if ! ghdl -m --workdir="$WORKDIR" $GHDL_OPTS c1581_wrapper >"$WORKDIR/el" 2>&1; then
    echo "   FAIL"
    grep -m8 "error:" "$WORKDIR/el" | sed 's/^/      /'
    echo
    echo "RESULT: elaboration failed"
    exit 1
fi
errs=$(grep -c "error:" "$WORKDIR/el" || true)
if [ "$errs" -ne 0 ]; then
    grep -m8 "error:" "$WORKDIR/el" | sed 's/^/      /'
    echo
    echo "RESULT: $errs elaboration error(s)"
    exit 1
fi
echo "   c1581_wrapper elaborates cleanly"

echo
echo "RESULT: no errors"
