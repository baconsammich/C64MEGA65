#!/usr/bin/env bash
##############################################################################
# Talk to the C1581 over a simulated IEC bus, using Gideon's own bus-functional
# model as the controller.
#
# tb_c1581_wrapper proves the drive boots and acknowledges ATN. That is not the
# same as working: a drive can answer ATN and still never return a byte, which
# is what "SEARCHING FOR $" and then a hung C64 looks like. This one reads the
# drive's error channel - no disk access, so it isolates "does not talk" from
# "cannot read the disk" - and then loads "$" for real, which needs seek, read
# sector and the HyperRAM DMA.
#
# Needs a real 1581 DOS dump and a *.d81. Those are copyrighted and not in this
# repository, so without them the testbench reports "skipped" and does nothing:
#
#   ROM=~/roms/1581.rom D81=~/roms/some.d81 EXPECT=DISKNAME ./run_tb_c1581_iec.sh
#
# BOOT_MS sets how long the DOS is given before being spoken to (default 150).
# This is a slow simulation - minutes, not seconds.
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
sim/iec_bus_bfm.vhd
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

echo "== running tb_c1581_iec =="
ghdl -a --workdir="$WORKDIR" $GHDL_OPTS -P"$WORKDIR" tb_c1581_iec.vhd \
    >"$WORKDIR/a" 2>&1 || { grep -m5 "error:" "$WORKDIR/a" | sed 's/^/   /'; exit 1; }
ghdl -e --workdir="$WORKDIR" $GHDL_OPTS -P"$WORKDIR" tb_c1581_iec \
    >"$WORKDIR/e2" 2>&1 || { grep -m5 "error:" "$WORKDIR/e2" | sed 's/^/   /'; exit 1; }

# An array, not a string: ROM and D81 paths routinely contain spaces.
GENERICS=()
[ -n "${ROM:-}" ]     && GENERICS+=("-gG_ROM_FILE=$ROM")
[ -n "${D81:-}" ]     && GENERICS+=("-gG_D81_FILE=$D81")
[ -n "${EXPECT:-}" ]  && GENERICS+=("-gG_EXPECT=$EXPECT")
[ -n "${BOOT_MS:-}" ] && GENERICS+=("-gG_BOOT_MS=$BOOT_MS")
[ ${#GENERICS[@]} -gt 0 ] && printf '   with %s\n' "${GENERICS[@]}"

# The testbench ends itself by stopping the clock; --stop-time is a backstop,
# and has to be well clear of G_RUN_MS.
STOP_MS=$(( ${BOOT_MS:-150} + 300 ))
ghdl -r --workdir="$WORKDIR" $GHDL_OPTS -P"$WORKDIR" tb_c1581_iec \
    "${GENERICS[@]}" --stop-time="${STOP_MS}ms" >"$WORKDIR/run" 2>&1
rc=$?

# GHDL prints notes to stderr with a file:line:time prefix; show just the text.
sed -nE 's/^.*\(report (note|warning|error|failure)\): /   /p' "$WORKDIR/run" \
    | grep -v "metavalue detected"

echo
if grep -qE "RESULT: (the C1581 answers over IEC|skipped)" "$WORKDIR/run"; then
    echo "RESULT: no errors"
    exit 0
fi
echo "RESULT: the C1581 IEC testbench failed"
[ "$rc" -eq 0 ] && rc=1
exit "$rc"
