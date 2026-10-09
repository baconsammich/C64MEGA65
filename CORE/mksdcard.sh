#!/usr/bin/env bash
##############################################################################
# Build an SD card layout for the C64 for MEGA65 core.
#
# Produces a staging directory you can copy onto a FAT32 SD card, and
# optionally a FAT32 image file as well.
#
# The core needs a valid configuration file at /c64/c64mega65 whose size
# matches OPTM_SIZE in CORE/vhdl/config.vhd: the M2M framework can neither
# create files nor change their length, so the file has to exist up front with
# exactly the right size. This script always regenerates it from config.vhd,
# so it cannot drift out of sync.
#
# Optional ROMs and disk images are copied in if they are found. Nothing
# copyrighted is kept in this repository: point --assets at wherever you keep
# your own ROM and disk files.
#
# Usage:
#   ./mksdcard.sh [options]
#     --out DIR        output directory   (default: $HOME/c64mega65-sdcard)
#     --assets DIR     where to look for ROMs and disk images
#                      (default: $M65_ASSETS, if set)
#     --img [FILE]     also build a FAT32 image (default: <out>.img)
#     --img-size MB    image size in MB   (default: 256)
#     --help
#
# Files picked up from --assets, if present:
#   JiffyDOS_C64.bin      -> c64/jd-c64.bin     (C64 JiffyDOS KERNAL)
#   JiffyDOS_1541-II.bin  -> c64/jd-c1541.bin   (1541 JiffyDOS DOS)
#   1581.rom              -> c64/1581.rom       (C1581 DOS; JiffyDOS_1581.bin
#                                                used only if 1581.rom absent)
#   *.d64 *.d81 *.crt *.prg *.g64 -> c64/
#   MEGA65.ROM and *.M65  -> root (MEGA65 system files)
##############################################################################
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${HOME}/c64mega65-sdcard"
ASSETS="${M65_ASSETS:-}"
MAKE_IMG=0
IMG=""
IMG_SIZE_MB=256

while [ $# -gt 0 ]; do
    case "$1" in
        --out)      OUT="$2"; shift 2 ;;
        --assets)   ASSETS="$2"; shift 2 ;;
        --img)      MAKE_IMG=1
                    if [ $# -ge 2 ] && [[ "$2" != --* ]]; then IMG="$2"; shift 2
                    else shift; fi ;;
        --img-size) IMG_SIZE_MB="$2"; shift 2 ;;
        --help|-h)  sed -n '2,36p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *)          echo "unknown option: $1 (try --help)"; exit 1 ;;
    esac
done

[ -n "$IMG" ] || IMG="${OUT}.img"

echo "repo   : $REPO"
echo "output : $OUT"
echo "assets : ${ASSETS:-<none given>}"
echo

##############################################################################
# Layout
##############################################################################
mkdir -p "$OUT/c64"

##############################################################################
# The configuration file - always regenerated, never copied
##############################################################################
OPTM_SIZE=$(grep "constant OPTM_SIZE" "$REPO/CORE/vhdl/config.vhd" \
            | sed -E 's/.*:= ([0-9]+).*/\1/')
if [ -z "$OPTM_SIZE" ]; then
    echo "ERROR: could not read OPTM_SIZE from CORE/vhdl/config.vhd"; exit 1
fi
python3 -c "
import sys
open(sys.argv[1],'wb').write(b'\xff' * int(sys.argv[2]))
" "$OUT/c64/c64mega65" "$OPTM_SIZE"
echo "config : c64/c64mega65  ($OPTM_SIZE bytes, from OPTM_SIZE)"

##############################################################################
# The core itself, for flashing. Prefers a locally built bitstream over the
# released ones, so a fresh Vivado build is picked up automatically.
##############################################################################
cores=0
newest_built=$(find "$REPO/CORE" -maxdepth 3 -name '*.cor' -newer "$REPO/CORE/vhdl/config.vhd" 2>/dev/null | head -1)
if [ -n "$newest_built" ]; then
    cp "$newest_built" "$OUT/"; cores=1
    echo "core   : $(basename "$newest_built")  (locally built)"
else
    # Fall back to the newest released set in bin/
    latest=$(ls -d "$REPO"/bin/Version* 2>/dev/null | sort -V | tail -1)
    if [ -n "$latest" ]; then
        for f in "$latest"/*.cor; do
            [ -e "$f" ] || continue
            cp "$f" "$OUT/"; cores=$((cores+1))
        done
        echo "cores  : $cores from $(basename "$latest")  (released)"
    fi
fi
[ "$cores" -eq 0 ] && echo "cores  : none found - build a bitstream, or check bin/"

##############################################################################
# Optional assets
##############################################################################
copy_if () {  # copy_if <src> <dst> <label>
    if [ -f "$1" ]; then cp "$1" "$2"; echo "       + $3"; fi
}

if [ -n "$ASSETS" ] && [ -d "$ASSETS" ]; then
    echo "roms   :"
    # JiffyDOS: the core looks for these exact names (see CORE/vhdl/globals.vhd)
    copy_if "$ASSETS/JiffyDOS_C64.bin"     "$OUT/c64/jd-c64.bin"   "c64/jd-c64.bin   (JiffyDOS C64)"
    copy_if "$ASSETS/JiffyDOS_1541-II.bin" "$OUT/c64/jd-c1541.bin" "c64/jd-c1541.bin (JiffyDOS 1541)"
    # The C1581 fetches its DOS out of HyperRAM, loaded from this file at boot.
    # Prefer the stock DOS; fall back to a JiffyDOS 1581 image if that is all
    # there is. Both land on the same filename, so pick one rather than letting
    # the second silently overwrite the first.
    if [ -f "$ASSETS/1581.rom" ]; then
        copy_if "$ASSETS/1581.rom"          "$OUT/c64/1581.rom"     "c64/1581.rom     (C1581 DOS)"
    else
        copy_if "$ASSETS/JiffyDOS_1581.bin" "$OUT/c64/1581.rom"     "c64/1581.rom     (JiffyDOS 1581)"
    fi

    echo "disks  :"
    n=0
    while IFS= read -r -d '' f; do
        cp "$f" "$OUT/c64/"; n=$((n+1))
    done < <(find "$ASSETS" -maxdepth 1 -type f \
                \( -iname '*.d64' -o -iname '*.d81' -o -iname '*.g64' \
                   -o -iname '*.crt' -o -iname '*.prg' \) -print0 2>/dev/null)
    echo "       + $n disk/cartridge/program file(s) -> c64/"

    # MEGA65 system files, if a core release was unpacked into the assets dir
    m65=$(find "$ASSETS" -type d -name 'sdcard-files' 2>/dev/null | head -1)
    if [ -n "$m65" ]; then
        cp "$m65"/* "$OUT/" 2>/dev/null || true
        echo "mega65 : $(ls "$m65" | wc -l) system file(s) from sdcard-files/"
    fi
else
    echo "roms   : skipped (no --assets directory)"
fi

##############################################################################
# Optional FAT32 image
##############################################################################
if [ "$MAKE_IMG" -eq 1 ]; then
    if ! command -v mformat >/dev/null || ! command -v mcopy >/dev/null; then
        echo
        echo "WARNING: mtools (mformat/mcopy) not found - image not built."
        echo "         The staging directory in $OUT is still complete."
    else
        echo
        echo "image  : building $IMG (${IMG_SIZE_MB} MB, FAT32)"
        rm -f "$IMG"
        dd if=/dev/zero of="$IMG" bs=1M count="$IMG_SIZE_MB" status=none
        # -F forces FAT32, which is what the MEGA65 expects
        mformat -i "$IMG" -F -v C64MEGA65 ::
        ( cd "$OUT" && for e in *; do
              [ -e "$e" ] || continue
              mcopy -i "$IMG" -s -o "$e" ::/ ;
          done )
        echo "       + $(du -h "$IMG" | cut -f1) written"
    fi
fi

##############################################################################
echo
echo "RESULT: SD card staged in $OUT"
find "$OUT" -type f | sed "s|$OUT|  .|" | sort | head -40
total=$(find "$OUT" -type f | wc -l)
[ "$total" -gt 40 ] && echo "  ... and $((total - 40)) more file(s)"
