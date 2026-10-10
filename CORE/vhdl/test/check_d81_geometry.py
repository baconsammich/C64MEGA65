#!/usr/bin/env python3
"""Check the C1581 disk server's sector addressing against the .d81 layout.

c1581_disk_server.vhd turns a WD177x request - physical cylinder, side,
physical sector - into a byte offset into the *.d81 in HyperRAM:

    offset = (((track * 2) + side) * C_SECTORS_TRACK + (sector - 1)) * C_SECTOR_LEN

Nothing else checks that. A wrong constant or a missing "- 1" still reads and
still writes; it just reads the wrong sector, which looks like a corrupt disk
rather than like a bug. The drive is also not reachable by any testbench here,
since its image lives in HyperRAM and arrives over the Shell's ROM loader.

So check the arithmetic directly, against the two things it has to agree with:

  1. itself - the map has to be a bijection onto the image, every sector
     landing on a distinct offset and the offsets tiling the file exactly, with
     no hole and no overlap.
  2. the .d81 format - a *.d81 is 80 logical tracks of 40 logical sectors of
     256 bytes, in logical order. The 1581 puts logical sectors 0..19 of
     logical track t on side 0 of physical cylinder t-1 and 20..39 on side 1,
     two 256-byte logical sectors per 512-byte physical sector. The physical
     map therefore has to produce the same offsets as the logical one.

Both constants are read out of the VHDL rather than written out again here, so
this fails if someone edits them.

Usage: ./check_d81_geometry.py [image.d81 ...]

With an image argument it also checks that the offset the formula computes for
logical track 40 sector 0 really does land on that image's 1581 header - which
is what ties the arithmetic to a real file rather than to another formula.
"""
import re
import sys

SRC = '../1581/glue/c1581_disk_server.vhd'

TRACKS      = 80          # physical cylinders
SIDES       = 2
LOG_SECTORS = 40          # logical sectors per logical track
LOG_LEN     = 256         # logical sector size
D81_SIZE    = TRACKS * LOG_SECTORS * LOG_LEN      # 819200


def vhdl_natural(src, name):
    m = re.search(r'constant\s+%s\s*:\s*natural\s*:=\s*(\d+)\s*;' % name, src)
    if not m:
        sys.exit("ERROR: could not find constant %s in %s" % (name, SRC))
    return int(m.group(1))


def main():
    src = open(SRC, encoding='utf-8').read()
    sector_len    = vhdl_natural(src, 'C_SECTOR_LEN')
    sectors_track = vhdl_natural(src, 'C_SECTORS_TRACK')

    print("== C1581 sector addressing ==")
    print("   from %s: C_SECTOR_LEN=%d  C_SECTORS_TRACK=%d"
          % (SRC, sector_len, sectors_track))

    def offset(track, side, sector):
        """The formula, transcribed from the VHDL."""
        return (((track * 2) + side) * sectors_track + (sector - 1)) * sector_len

    bad = 0

    # ---- 1. the physical map tiles the image exactly ----------------------
    seen = {}
    for t in range(TRACKS):
        for s in range(SIDES):
            for p in range(1, sectors_track + 1):
                o = offset(t, s, p)
                if o in seen:
                    print("   cylinder %d side %d sector %d collides with %r at %d"
                          % (t, s, p, seen[o], o))
                    bad += 1
                seen[o] = (t, s, p)

    expected = TRACKS * SIDES * sectors_track
    covered  = expected * sector_len
    print("   %d sectors of %d bytes = %d bytes" % (len(seen), sector_len, covered))
    if len(seen) != expected:
        print("   expected %d distinct sectors, got %d" % (expected, len(seen)))
        bad += 1
    if covered != D81_SIZE:
        print("   covers %d bytes but a *.d81 is %d - the geometry does not "
              "match the format" % (covered, D81_SIZE))
        bad += 1
    if sorted(seen) != list(range(0, covered, sector_len)):
        print("   the offsets do not tile the image: there is a hole or an overlap")
        bad += 1

    # ---- 2. physical map agrees with the logical .d81 layout --------------
    mismatches = 0
    for lt in range(1, TRACKS + 1):                 # logical track, 1-based
        for ls in range(LOG_SECTORS):               # logical sector, 0-based
            logical = ((lt - 1) * LOG_SECTORS + ls) * LOG_LEN
            cyl     = lt - 1
            side    = 0 if ls < LOG_SECTORS // 2 else 1
            half    = ls % (LOG_SECTORS // 2)       # 0..19 within the side
            phys    = offset(cyl, side, half // 2 + 1) + (half % 2) * LOG_LEN
            if phys != logical:
                if mismatches < 3:
                    print("   logical t%d/s%d: .d81 says %d, formula says %d"
                          % (lt, ls, logical, phys))
                mismatches += 1
    if mismatches:
        print("   %d of %d logical sectors land in the wrong place"
              % (mismatches, TRACKS * LOG_SECTORS))
        bad += 1
    else:
        print("   all %d logical sectors agree with the .d81 layout"
              % (TRACKS * LOG_SECTORS))

    # ---- 3. optional: against a real image -------------------------------
    for path in sys.argv[1:]:
        try:
            data = open(path, 'rb').read()
        except OSError as e:
            print("   %s: %s" % (path, e))
            bad += 1
            continue
        if len(data) < D81_SIZE:
            print("   %s is %d bytes, too short for a *.d81" % (path, len(data)))
            bad += 1
            continue
        # The 1581 header/BAM is logical track 40, sector 0
        o = offset(39, 0, 1)
        hdr = data[o:o + LOG_LEN]
        fmt = chr(hdr[2]) if 32 <= hdr[2] < 127 else '?'
        name = bytes(c if 32 <= c < 127 else 32
                     for c in hdr[0x04:0x14]).decode().strip()
        ok = fmt == 'D'
        print("   %-32s offset %d -> fmt=%r name=%r  %s"
              % (path.rsplit('/', 1)[-1], o, fmt, name,
                 "ok" if ok else "NOT a 1581 header"))
        if not ok:
            bad += 1

    print()
    if bad:
        print("RESULT: %d problem(s) in the C1581 sector addressing" % bad)
        return 1
    print("RESULT: sector addressing is consistent")
    return 0


if __name__ == '__main__':
    sys.exit(main())
