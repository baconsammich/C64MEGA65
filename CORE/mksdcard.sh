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
#
# Staged for doc/cmd_devices.md but NOT read by the core - there is no RAMLink,
# CMD HD, CMD FD or SuperCPU in the design yet:
#   ramlink201.bin        -> c64/ramlink.rom
#   ramlink.rl            -> c64/ramlink.img
#   CMD HD BOOTROM v280.bin           -> c64/cmdhd.rom
#   CMD FD 4000 ROM from COREi64.bin  -> c64/cmdfd.rom
#   scpu.rom              -> c64/scpu.rom
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

    # CMD devices. None of these is read by the core yet - there is no RAMLink,
    # CMD HD, CMD FD or SuperCPU in the design - so they are staged for the work
    # described in doc/cmd_devices.md, not because anything loads them. They are
    # copied under the names that document uses so the eventual
    # C_CRTROMS_AUTO entries have something stable to point at.
    echo "cmd    :"
    # RAMLink ROM v2.01, 64 KB. The copy inside
    # scpu_ramlink_sdcard_files_with_ROM.zip as SCPU/ramlink.rom is byte for
    # byte the same file.
    if   [ -f "$ASSETS/ramlink201.bin" ]; then
        copy_if "$ASSETS/ramlink201.bin"  "$OUT/c64/ramlink.rom" "c64/ramlink.rom   (RAMLink ROM v2.01)"
    else
        copy_if "$ASSETS/ramlink.rom"     "$OUT/c64/ramlink.rom" "c64/ramlink.rom   (RAMLink ROM)"
    fi
    # RAMLink battery-backed RAM. Prefer the 8 MB .rl; the 16 MB variant in the
    # zip is the same thing with more RAM fitted.
    if   [ -f "$ASSETS/ramlink.rl" ]; then
        copy_if "$ASSETS/ramlink.rl"      "$OUT/c64/ramlink.img" "c64/ramlink.img   (RAMLink RAM, 8 MB)"
    else
        copy_if "$ASSETS/ramlink.img"     "$OUT/c64/ramlink.img" "c64/ramlink.img   (RAMLink RAM)"
    fi
    copy_if "$ASSETS/CMD HD BOOTROM v280.bin" "$OUT/c64/cmdhd.rom" "c64/cmdhd.rom     (CMD HD boot ROM v2.80)"
    copy_if "$ASSETS/CMD FD 4000 ROM from COREi64.bin" "$OUT/c64/cmdfd.rom" "c64/cmdfd.rom     (CMD FD-4000 ROM)"
    copy_if "$ASSETS/scpu.rom"            "$OUT/c64/scpu.rom"    "c64/scpu.rom      (SuperCPU 64 ROM, 128 KB)"

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
#
# The image is MBR-partitioned, the way a real SD card is. The core mounts the
# card through FAT32$MOUNT_SD (M2M/QNICE/monitor/fat32_library.asm), which
# reads LBA 0, checks for the 0xAA55 signature and then looks for a partition
# of type 0x0B or 0x0C in the table at offset 0x01BE.
#
# A bare "mformat ... ::" image does in fact mount: mtools leaves a partition
# entry of type 0x0C at 0x01BE whose start LBA is 0, which points the library
# back at the boot sector it just read. That works, but it is a quirk rather
# than a layout, and it is not what the MEGA65 hypervisor expects to find when
# it looks for cores. So write a normal MBR with partition 1 at the 1 MiB
# boundary and format inside it using mtools "@@offset" syntax.
##############################################################################
if [ "$MAKE_IMG" -eq 1 ]; then
    if ! command -v mformat >/dev/null || ! command -v mcopy >/dev/null; then
        echo
        echo "WARNING: mtools (mformat/mcopy) not found - image not built."
        echo "         The staging directory in $OUT is still complete."
    else
        echo
        echo "image  : building $IMG (${IMG_SIZE_MB} MB, FAT32, MBR-partitioned)"
        rm -f "$IMG"
        dd if=/dev/zero of="$IMG" bs=1M count="$IMG_SIZE_MB" status=none

        # Partition 1 starts at the conventional 1 MiB boundary and fills the
        # image. Type 0x0C is "FAT32 with LBA".
        PART_START=2048                                  # in 512-byte sectors
        PART_SECTORS=$(( IMG_SIZE_MB * 2048 - PART_START ))
        python3 - "$IMG" "$PART_START" "$PART_SECTORS" <<'EOPY'
import struct, sys
img, start, count = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
mbr = bytearray(512)
# 0x80 = bootable. The CHS fields are set to the "use LBA instead" sentinel,
# which is what every tool does for a partition beyond the CHS limit.
entry = struct.pack('<B3sB3sII',
                    0x80, b'\xfe\xff\xff', 0x0C, b'\xfe\xff\xff',
                    start, count)
mbr[0x1BE:0x1BE + 16] = entry
mbr[0x1FE:0x200] = b'\x55\xaa'
with open(img, 'r+b') as f:
    f.write(mbr)
EOPY

        # mtools reaches inside the partition via "@@<byte offset>"
        MDRIVE="${IMG}@@$(( PART_START * 512 ))"
        # -F forces FAT32; -T sizes the filesystem to the partition
        mformat -i "$MDRIVE" -F -T "$PART_SECTORS" -v C64MEGA65 ::
        ( cd "$OUT" && for e in *; do
              [ -e "$e" ] || continue
              mcopy -i "$MDRIVE" -s -o "$e" ::/ ;
          done )
        echo "       + $(du -h "$IMG" | cut -f1) written, partition 1 at sector $PART_START"

        # Prove the core would be able to mount it: signature and type byte
        python3 - "$IMG" <<'EOPY'
import sys
with open(sys.argv[1], 'rb') as f:
    mbr = f.read(512)
sig  = mbr[0x1FE:0x200]
ptype = mbr[0x1BE + 4]
ok = sig == b'\x55\xaa' and ptype in (0x0B, 0x0C)
print("       + MBR check: signature %s, partition type 0x%02X -> %s"
      % (sig.hex(), ptype, "mountable" if ok else "NOT MOUNTABLE"))
sys.exit(0 if ok else 1)
EOPY
    fi
fi

##############################################################################
# Is the card actually ready to run the C1581?
#
# Both of these live on the card and are fetched at runtime, so a card that is
# missing them gives no error - the core boots, the menu opens, and the D81
# file browser simply has nothing to list. That is not obvious from the core,
# so say it here.
##############################################################################
echo
echo "C1581 readiness:"
if [ -f "$OUT/c64/1581.rom" ]; then
    echo "  OK      c64/1581.rom present ($(stat -c%s "$OUT/c64/1581.rom") bytes)"
else
    echo "  MISSING c64/1581.rom - the drive stays switched off without its DOS."
    echo "          Put a 1581 DOS dump named 1581.rom (or JiffyDOS_1581.bin)"
    echo "          into the --assets directory and re-run."
fi
nd81=$(find "$OUT/c64" -maxdepth 1 -iname '*.d81' 2>/dev/null | wc -l)
if [ "$nd81" -gt 0 ]; then
    echo "  OK      $nd81 *.d81 image(s) in c64/ for the D81 menu item to list"
else
    echo "  MISSING no *.d81 images in c64/ - the D81 file browser will be empty."
fi

##############################################################################
echo
echo "RESULT: SD card staged in $OUT"
find "$OUT" -type f | sed "s|$OUT|  .|" | sort | head -40
total=$(find "$OUT" -type f | wc -l)
[ "$total" -gt 40 ] && echo "  ... and $((total - 40)) more file(s)"

cat <<EOTXT

To put this on the MEGA65:
  * Either write the .img to the card (if one was built above), which replaces
    everything on it, or
  * copy the *contents* of $OUT
    onto the card, keeping the layout - in particular the c64/ subdirectory.
    Copying only the .cor is not enough: the ROMs and disk images are read off
    the card at runtime, out of /c64.
EOTXT
