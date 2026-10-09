#!/usr/bin/env bash
##############################################################################
# Elaborate every VHDL entity in the tree with GHDL and fail on a regression.
#
# This is a cheap standards-conformance gate. GHDL enforces parts of the VHDL
# LRM that Vivado lets slide - case-statement coverage, aggregate ambiguity,
# locally-static requirements - so it catches a class of defect that a
# successful Vivado build does not. Elaborating (rather than just analysing)
# each entity also type-checks its whole dependency tree.
#
# It is NOT a substitute for synthesis: it never checks timing or resources.
#
# CORE/vhdl/1581 is excluded - both the vendored sources and our glue in
# 1581/glue need --std=93 -fsynopsys -frelaxed, so the whole subsystem has its
# own gate in analyze_1581.sh.
#
# Usage: ./analyze_all.sh
#
# Honours the same overrides as the Makefile:
#   C65C02_DIR   external github.com/MJoergen/65c02 checkout
#   XPM_TOP_DIR  external github.com/fransschreuder/xpm_vhdl checkout
##############################################################################
set -uo pipefail

cd "$(dirname "$0")"
REPO=../../..
WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT

C65C02_DIR=${C65C02_DIR:-../../../../65c02}
XPM_TOP_DIR=${XPM_TOP_DIR:-$HOME/xpm_vhdl}

command -v ghdl >/dev/null || { echo "ERROR: ghdl not found in PATH."; exit 1; }
[ -d "$XPM_TOP_DIR" ] || { echo "ERROR: XPM_TOP_DIR=$XPM_TOP_DIR missing."; exit 1; }

##############################################################################
# Sources GHDL cannot read. Skipped on purpose, not failures.
##############################################################################
# These instantiate Xilinx (unisim) or Altera (altera_mf) primitives, for
# which GHDL has no models. Vivado synthesises them normally.
cat > "$WORKDIR/skip.txt" <<'EOF'
CORE/C64_MiSTerMEGA65/rtl/c1530.vhd
CORE/C64_MiSTerMEGA65/rtl/pll.vhd
CORE/vhdl/clk.vhd
M2M/vhdl/clk_m2m.vhd
M2M/vhdl/controllers/HDMI/serialiser_10to1_selectio.vhd
M2M/vhdl/controllers/HDMI/video_out_clock.vhd
M2M/vhdl/controllers/M65/audio.vhd
M2M/vhdl/controllers/M65/max10.vhdl
M2M/vhdl/controllers/hyperram/hyperram_rx.vhd
M2M/vhdl/controllers/hyperram/hyperram_tx.vhd
EOF

##############################################################################
# Entities that cannot elaborate under GHDL, with the reason.
#
# Keep this list in sync: the gate fails if an entity NOT listed here breaks,
# and warns if a listed entity starts passing (meaning the list is stale).
##############################################################################
cat > "$WORKDIR/expected_fail.txt" <<'EOF'
clk                         needs unisim (MMCM/PLL primitives)
clk_m2m                     needs unisim
audio                       needs unisim
max10                       needs unisim
hyperram_rx                 needs unisim
hyperram_tx                 needs unisim
video_out_clock             needs unisim
serialiser_10to1_selectio   needs unisim
hyperram                    instantiates hyperram_rx/tx (unisim)
framework                   instantiates clk_m2m + video_out_clock (unisim)
MEGA65_Core                 instantiates clk (unisim)
mega65_r3                   top level: unisim + Verilog
mega65_r4                   top level: unisim + Verilog
mega65_r5                   top level: unisim + Verilog
mega65_r6                   top level: unisim + Verilog
analog_pipeline             instantiates csync.sv (SystemVerilog)
main                        instantiates iec_drive.sv (SystemVerilog)
QNICE                       rest of the QNICE submodule is not imported
qnice_wrapper               instantiates QNICE
digital_pipeline            instantiates serialiser (unisim) + integer/natural port bounds
av_pipeline                 integer actual vs natural range port (see doc/developer.md)
vdrives                     VDNUM-derived formals are not locally static (see doc/developer.md)
EOF

##############################################################################
# Build the xpm support library
##############################################################################
##############################################################################
# The C1581 subsystem must exist first, because main.vhd instantiates it from
# its own library. Its sources need different GHDL settings (see
# analyze_1581.sh), so they are built here into c1581_lib within the same
# workdir rather than joining the design library. Same --std as the rest, or
# the library would be invisible to the elaboration below.
##############################################################################
echo "== building c1581_lib =="
c1581_ok=0
while read -r f; do
    [ -z "$f" ] && continue
    if ghdl -a --workdir="$WORKDIR" --work=c1581_lib --std=08 -fsynopsys -frelaxed \
            "../1581/$f" 2>"$WORKDIR/e"; then
        c1581_ok=$((c1581_ok + 1))
    else
        echo "FAIL (c1581_lib): $f"; grep -m3 "error:" "$WORKDIR/e"; exit 1
    fi
done < <(sed -n '/^FILES="/,/^"$/p' ./analyze_1581.sh | sed '1d;$d')
echo "   $c1581_ok files in c1581_lib"

echo "== analysing xpm models =="
xpm_count=0
while read -r f; do
    [ -z "$f" ] && continue
    if ! ghdl -a --workdir="$WORKDIR" --work=xpm --std=08 "$f" 2>"$WORKDIR/e"; then
        echo "FAIL (xpm): $f"; cat "$WORKDIR/e"; exit 1
    fi
    xpm_count=$((xpm_count + 1))
done < <(grep -oE '\$\{XPM_TOP_DIR\}/[^ ]*\.vhd' Makefile | sed "s|\${XPM_TOP_DIR}|$XPM_TOP_DIR|")
echo "   $xpm_count xpm files OK"

##############################################################################
# Import the design
##############################################################################
# Only tools.vhd is taken from the QNICE submodule (it holds package
# qnice_tools, needed by globals.vhd). The rest of QNICE is deliberately left
# out: it ships mutually exclusive ISE/Vivado and sim/synth variants of the
# same units, which collide in a single library, and two files use
# VHDL-87-only syntax that GHDL rejects under --std=08.
TO_IMPORT=()
skipped=0
while read -r f; do
    if grep -qxF "$f" "$WORKDIR/skip.txt"; then
        skipped=$((skipped + 1))
    else
        TO_IMPORT+=("$REPO/$f")
    fi
done < <(cd "$REPO" && find CORE/vhdl M2M/vhdl CORE/C64_MiSTerMEGA65 \
            -path CORE/vhdl/1581 -prune -o \
            \( -name '*.vhd' -o -name '*.vhdl' \) -print | sort)

TO_IMPORT+=("$REPO/M2M/QNICE/vhdl/tools.vhd")

# The 65C02 model is optional: without it core_sim and the testbenches cannot
# elaborate, so they get added to the expected-failure list instead.
if [ -d "$C65C02_DIR/src" ]; then
    while read -r f; do TO_IMPORT+=("$f"); done < <(find "$C65C02_DIR/src" -name '*.vhd' | sort)
else
    echo "   note: C65C02_DIR=$C65C02_DIR not found, skipping CPU-dependent units"
    printf '%s\n' \
        "core_sim                    C65C02_DIR not available" \
        "tb_sw_cartridge_wrapper     C65C02_DIR not available" \
        "tb_reu                      C65C02_DIR not available" \
        >> "$WORKDIR/expected_fail.txt"
fi

echo "== importing ${#TO_IMPORT[@]} files ($skipped vendor files skipped) =="
ghdl -i --workdir="$WORKDIR" --work=work --std=08 "${TO_IMPORT[@]}" 2>"$WORKDIR/imp"
if grep -q "error:" "$WORKDIR/imp"; then
    echo "FAIL: import (syntax) errors"; grep "error:" "$WORKDIR/imp"; exit 1
fi

##############################################################################
# Elaborate every entity
##############################################################################
mapfile -t ENTITIES < <(
    cd "$REPO" && grep -rhoE "^entity [a-zA-Z0-9_]+ is" CORE/vhdl M2M/vhdl \
        --include=*.vhd --include=*.vhdl --exclude-dir=1581 \
        | awk '{print $2}' | sort -u
)

echo "== elaborating ${#ENTITIES[@]} entities =="
unexpected=()
fixed=()
clean=0
for e in "${ENTITIES[@]}"; do
    timeout 120 ghdl -m --workdir="$WORKDIR" -P"$WORKDIR" --std=08 \
        -fexplicit -fsynopsys "$e" >"$WORKDIR/$e.log" 2>&1
    expected=$(awk -v e="$e" '$1==e {$1=""; sub(/^ +/,""); print; exit}' "$WORKDIR/expected_fail.txt")
    if grep -q "error:" "$WORKDIR/$e.log"; then
        if [ -z "$expected" ]; then
            unexpected+=("$e")
            echo "   UNEXPECTED FAIL: $e"
            grep "error:" "$WORKDIR/$e.log" | head -4 | sed 's/^/      /'
        fi
    else
        clean=$((clean + 1))
        [ -n "$expected" ] && fixed+=("$e")
    fi
done

echo
echo "   $clean of ${#ENTITIES[@]} entities elaborated cleanly"

if [ ${#fixed[@]} -ne 0 ]; then
    echo
    echo "   NOTE: these are on the expected-failure list but now pass."
    echo "   Please remove them from expected_fail in $(basename "$0"):"
    printf '      %s\n' "${fixed[@]}"
fi

if [ ${#unexpected[@]} -ne 0 ]; then
    echo
    echo "RESULT: ${#unexpected[@]} entity/entities regressed: ${unexpected[*]}"
    exit 1
fi

echo
echo "RESULT: no regressions"
