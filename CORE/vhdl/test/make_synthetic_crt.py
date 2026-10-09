#!/usr/bin/env python3
"""Generate synthetic *.crt cartridge images for the testbenches.

The testbenches need a cartridge to parse, but real cartridge dumps are
copyrighted and cannot be committed. These images contain no copyrighted
data - just a valid CRT header, valid CHIP packets and a trivial payload
carrying the CBM80 autostart signature - which is enough to exercise
crt_parser, crt_cacher and sw_cartridge_wrapper.

CRT format reference: https://vice-emu.sourceforge.io/vice_17.html#SEC404

Usage:
    ./make_synthetic_crt.py                      # generic 8K  -> synthetic.crt
    ./make_synthetic_crt.py --type generic16
    ./make_synthetic_crt.py --type ocean --banks 15
    ./make_synthetic_crt.py --type ocean -o /tmp/ocean.crt
"""

import argparse
import struct
import sys

CRT_SIGNATURE = b"C64 CARTRIDGE   "
CRT_HEADER_LEN = 0x40

# Cartridge hardware types, as understood by CORE/vhdl/cartridge.vhd
HW_GENERIC = 0
HW_OCEAN = 5

CHIP_TYPE_ROM = 0

# tb_sw_cartridge_wrapper instantiates avm_rom with G_ADDRESS_SIZE=16 and
# G_DATA_SIZE=16, i.e. its HyperRAM model holds only 128 KiB. A larger image
# is silently truncated by avm_rom's read loop and the parse never completes,
# so refuse to generate one by default.
TB_HYPERRAM_CAPACITY = 2 ** 16 * 2


def chip_packet(data, bank, load_addr):
    """One CHIP packet: 16-byte header followed by the ROM image."""
    packet = b"CHIP"
    packet += struct.pack(">I", 0x10 + len(data))
    packet += struct.pack(">H", CHIP_TYPE_ROM)
    packet += struct.pack(">H", bank)
    packet += struct.pack(">H", load_addr)
    packet += struct.pack(">H", len(data))
    return packet + data


def crt_header(hw_type, exrom, game, name):
    header = CRT_SIGNATURE
    header += struct.pack(">I", CRT_HEADER_LEN)
    header += struct.pack(">H", 0x0100)          # version 1.0
    header += struct.pack(">H", hw_type)
    header += bytes([exrom, game])
    header += b"\x00" * 6                        # reserved
    header += name.encode("ascii")[:32].ljust(32, b"\x00")
    assert len(header) == CRT_HEADER_LEN, len(header)
    return header


def rom_image(size, bank):
    """A ROM bank: CBM80 autostart signature plus a bank-id fingerprint.

    The fingerprint lets a testbench confirm that a read after a bank switch
    actually returned data from the bank it asked for.
    """
    img = bytearray(size)
    img[0:2] = struct.pack("<H", 0x8009)         # cold start vector
    img[2:4] = struct.pack("<H", 0x8009)         # warm start vector
    img[4:9] = b"\xC3\xC2\xCD\x38\x30"           # "CBM80"
    img[9:12] = b"\x60\x60\x60"                  # RTS padding
    img[12] = bank & 0xFF                        # bank fingerprint
    img[13] = (bank >> 8) & 0xFF
    return bytes(img)


def build(kind, banks):
    if kind == "generic8":
        body = chip_packet(rom_image(0x2000, 0), 0, 0x8000)
        # EXROM low (active), GAME high -> 8K cartridge at $8000
        return crt_header(HW_GENERIC, 0x00, 0x01, "SYNTHETIC GENERIC 8K") + body

    if kind == "generic16":
        body = chip_packet(rom_image(0x4000, 0), 0, 0x8000)
        # EXROM low, GAME low -> 16K cartridge at $8000/$A000
        return crt_header(HW_GENERIC, 0x00, 0x00, "SYNTHETIC GENERIC 16K") + body

    if kind == "ocean":
        body = b"".join(
            # Ocean banks 0..15 load at $8000, 16.. at $A000
            chip_packet(rom_image(0x2000, b), b, 0x8000 if b < 16 else 0xA000)
            for b in range(banks)
        )
        return crt_header(HW_OCEAN, 0x00, 0x01, "SYNTHETIC OCEAN") + body

    raise ValueError("unknown type: %s" % kind)


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--type", default="generic8",
                    choices=["generic8", "generic16", "ocean"],
                    help="cartridge layout to generate (default: generic8)")
    ap.add_argument("--banks", type=int, default=15,
                    help="number of 8K banks for --type ocean (default: 15, "
                         "which exceeds the 8-bank BRAM cache and so exercises "
                         "eviction while still fitting the testbench's 128 KiB "
                         "HyperRAM model)")
    ap.add_argument("-o", "--output", default="synthetic.crt",
                    help="output file (default: synthetic.crt)")
    ap.add_argument("--allow-oversize", action="store_true",
                    help="emit an image larger than the testbench's 128 KiB "
                         "HyperRAM model (it will be truncated when loaded)")
    args = ap.parse_args()

    if args.type == "ocean" and not 1 <= args.banks <= 64:
        sys.exit("--banks must be between 1 and 64")

    data = build(args.type, args.banks)

    if len(data) > TB_HYPERRAM_CAPACITY and not args.allow_oversize:
        sys.exit("%d bytes exceeds the testbench HyperRAM model (%d bytes); "
                 "reduce --banks or pass --allow-oversize"
                 % (len(data), TB_HYPERRAM_CAPACITY))

    with open(args.output, "wb") as f:
        f.write(data)
    print("%s: %s, %d bytes" % (args.output, args.type, len(data)))


if __name__ == "__main__":
    main()
