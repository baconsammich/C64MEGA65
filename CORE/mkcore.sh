#!/usr/bin/env bash
##############################################################################
# Turn a Vivado bitstream into a MEGA65 .cor file.
#
# Vivado stops at the .bit; the MEGA65 flasher wants a .cor, which is the
# bitstream with a header carrying the core's name and version. There is no
# post-bitstream hook in the .xpr doing this, so it is a separate step - this
# script, so the exact invocation is recorded rather than remembered.
#
# The name and version in the header are what MEGAFLASH shows in the core list,
# and the version is read straight out of CORE/vhdl/config.vhd so it cannot
# disagree with what the core prints on screen.
#
# Needs bit2core from the MEGA65 tools:
#     git clone https://github.com/MEGA65/mega65-tools
#     cd mega65-tools && make bin/bit2core        # or build src/tools/bit2core.c
# Point $BIT2CORE at it, or have it on PATH.
#
# Usage:
#   ./mkcore.sh [REV ...]        # REV is 3, 4, 5 or 6; default: every revision
#                                # that has a built bitstream
##############################################################################
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
BIT2CORE="${BIT2CORE:-$(command -v bit2core || true)}"
CORE_NAME="C64 for MEGA65"

# Core capabilities and flags. "c64cart" is what makes the MEGA65 CORE #0 core
# selection logic auto-start this core when a C64 cartridge is in the expansion
# port - see "Use bit2core" in doc/developer.md. Dropping it silently loses
# cartridge auto-start, with nothing to show that it is gone.
CORE_CAPS="=default,c64cart+c64cart"

if [ -z "$BIT2CORE" ] || [ ! -x "$BIT2CORE" ]; then
    echo "ERROR: bit2core not found. Put it on PATH or set \$BIT2CORE." >&2
    exit 1
fi

# The on-screen version, e.g. "WIP-V5.3-A4", taken from CORENAME. Everything
# after "MEGA65 " is the version.
VERSION=$(sed -nE 's/^constant CORENAME .*"Commodore 64 for MEGA65 (.*)".*/\1/p' \
              "$REPO/CORE/vhdl/config.vhd")
if [ -z "$VERSION" ]; then
    echo "ERROR: could not read the version out of CORE/vhdl/config.vhd" >&2
    exit 1
fi
echo "version: $VERSION  (from CORENAME in config.vhd)"

revs=("$@")
if [ ${#revs[@]} -eq 0 ]; then
    revs=()
    for r in 3 4 5 6; do
        [ -f "$REPO/CORE/CORE-R$r.runs/impl_1/mega65_r$r.bit" ] && revs+=("$r")
    done
    if [ ${#revs[@]} -eq 0 ]; then
        echo "ERROR: no built bitstream found under CORE/CORE-R*.runs/impl_1/" >&2
        exit 1
    fi
fi

for r in "${revs[@]}"; do
    bit="$REPO/CORE/CORE-R$r.runs/impl_1/mega65_r$r.bit"
    cor="$REPO/CORE/CORE-R$r.runs/impl_1/C64MEGA65-$VERSION-R$r.cor"
    if [ ! -f "$bit" ]; then
        echo "R$r: no bitstream at $bit - skipped"
        continue
    fi
    rm -f "$cor"
    "$BIT2CORE" "mega65r$r" "$bit" "$CORE_NAME" "$VERSION" "$cor" "$CORE_CAPS" >/dev/null
    echo "R$r: $(basename "$cor")  ($(stat -c%s "$cor") bytes)"
    # Read the header back, so a silently wrong name or version is visible here
    python3 - "$cor" <<'EOPY'
import sys
d = open(sys.argv[1], 'rb').read(80)
assert d[0:16] == b'MEGA65BITSTREAM0', "not a .cor file: bad magic"
print("     header: name=%r version=%r"
      % (d[16:48].rstrip(b'\0').decode(), d[48:80].rstrip(b'\0').decode()))
EOPY
done
