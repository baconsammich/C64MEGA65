#!/usr/bin/env bash
##############################################################################
# Build the vendored C1581 into c1581_lib and run tb_c1581_wrapper.
#
# The testbench checks the two things about the drive that cannot be checked by
# reading the code and that nothing else here covers:
#
#   1. with no disk mounted it must issue NO HyperRAM requests at all, because
#      its 6502 fetches every instruction out of HyperRAM shared with the video
#      scaler - a drive that runs when it should not looks like the whole
#      machine freezing;
#   2. once mounted, its first fetch must be the 6502 reset vector at the top
#      of its DOS ROM window, and every address must stay inside the window it
#      was given. That is the arithmetic that decides whether the drive finds
#      its DOS at all.
#
# Usage: ./run_tb_c1581.sh
##############################################################################
set -uo pipefail

cd "$(dirname "$0")"
SRC=../1581
WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT

command -v ghdl >/dev/null || { echo "ERROR: ghdl not found in PATH."; exit 1; }

# Same settings as analyze_1581.sh: its own library, because Gideon's 6502 and
# QNICE both define an entity called "alu".
GHDL_OPTS="--std=08 -fsynopsys -frelaxed"
LIB_OPTS="$GHDL_OPTS --work=c1581_lib"

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

echo "== building c1581_lib =="
for f in $FILES; do
    if ! ghdl -a --workdir="$WORKDIR" $LIB_OPTS "$SRC/$f" 2>"$WORKDIR/e"; then
        echo "   FAIL $f"
        grep -m3 "error:" "$WORKDIR/e" | sed 's/^/      /'
        echo; echo "RESULT: analysis failed"; exit 1
    fi
done
echo "   $(echo $FILES | wc -w) files OK"

echo "== running tb_c1581_wrapper =="
ghdl -a --workdir="$WORKDIR" $GHDL_OPTS -P"$WORKDIR" tb_c1581_wrapper.vhd \
    >"$WORKDIR/a" 2>&1 || { grep -m5 "error:" "$WORKDIR/a" | sed 's/^/   /'; exit 1; }
ghdl -e --workdir="$WORKDIR" $GHDL_OPTS -P"$WORKDIR" tb_c1581_wrapper \
    >"$WORKDIR/e2" 2>&1 || { grep -m5 "error:" "$WORKDIR/e2" | sed 's/^/   /'; exit 1; }

# --stop-time is a backstop: the testbench ends itself by stopping the clock.
ghdl -r --workdir="$WORKDIR" $GHDL_OPTS -P"$WORKDIR" tb_c1581_wrapper \
    --stop-time=5ms >"$WORKDIR/run" 2>&1
rc=$?

# GHDL prints notes to stderr with a file:line:time prefix; show just the text.
sed -nE 's/^.*\(report (note|warning|error|failure)\): /   /p' "$WORKDIR/run" \
    | grep -v "metavalue detected"

echo
if grep -q "RESULT: c1581_wrapper behaves as expected" "$WORKDIR/run"; then
    echo "RESULT: no errors"
    exit 0
fi
echo "RESULT: the C1581 testbench failed"
[ "$rc" -eq 0 ] && rc=1
exit "$rc"
