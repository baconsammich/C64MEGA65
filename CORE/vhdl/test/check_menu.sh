#!/usr/bin/env bash
##############################################################################
# Check that the on-screen menu in config.vhd and the C_MENU_* constants in
# mega65.vhd still agree.
#
# Those constants are absolute indices into the menu, so inserting or removing
# a single menu line silently shifts every index below it. Nothing in the build
# catches that: the design synthesises, closes timing and boots, and then the
# core simply acts on the wrong menu item. It cost one flash cycle to find -
# adding a *.d81 entry near the top of the menu moved the Kernal selection by
# one, so choosing "Standard" loaded the Games System KERNAL instead.
#
# Checks:
#   1. OPTM_SIZE equals the number of menu entries and the number of entries
#      in OPTM_GROUPS. The framework reads OPTM_SIZE to size the config file,
#      so a mismatch also corrupts saved settings.
#   2. Every C_MENU_* index is within the menu.
#   3. Every C_MENU_* index points at a selectable entry, not at a separator
#      (OPTM_G_LINE) or a heading (OPTM_G_HEADLINE). This is what actually
#      catches an off-by-one, because a shifted index usually lands on one.
#   4. MENU_HEAP_SIZE is large enough for the OPTM_HEAP the options menu
#      carves out of it. The menu needs OPTM_DX words per "%s" filename slot -
#      one per virtual drive, per submenu and per manually loadable ROM, plus
#      one scratch slot - and the firmware only discovers a shortfall when the
#      user opens the menu, reporting "Heap corruption: Hint: OPTM_HEAP_SIZE".
#      The menu structure itself is built at runtime so its exact size is not
#      known here; this checks the part that can be computed and leaves a
#      margin.
#   5. The menu items carrying OPTM_G_LOAD_ROM line up with C_CRTROMS_MAN in
#      globals.vhd. The framework identifies a manually loadable ROM by
#      *counting* those menu items (CRTROM_M_NO in M2M/rom/crts-and-roms.asm),
#      so the n-th such item must match the n-th entry of C_CRTROMS_MAN. Get it
#      wrong and every item loads its file into the next entry's buffer - the
#      file browser still lists and still loads, so nothing fails loudly.
#   6. The C1581 HyperRAM windows in globals.vhd are laid out consistently.
#      Everything the drive asks for leaves through one c1581_mem_bridge, which
#      adds the drive's window base to every request, so the DOS ROM has to sit
#      inside the drive's own 8-window block and the *.d81 has to start above
#      it. main.vhd range-constrains the constants it derives from these, but
#      GHDL only reports that when elaborating main - which is on the
#      expected-failure list here, because main instantiates SystemVerilog. So
#      the check lives here, where it actually runs.
#
# Usage: ./check_menu.sh
##############################################################################
set -uo pipefail

cd "$(dirname "$0")"

python3 - "$@" <<'PY'
import re, sys

cfg = open('../config.vhd', encoding='utf-8').read()
m65 = open('../mega65.vhd', encoding='utf-8').read()

def die(msg):
    print("   %s" % msg)
    die.bad += 1
die.bad = 0

# ---- the menu text, one entry per newline ---------------------------------
items_src = re.search(r'constant OPTM_ITEMS\s+: string :=(.*?);\n', cfg, re.S).group(1)
entries = []
for lit in re.findall(r'"((?:[^"\\]|\\.)*)"', items_src):
    parts = lit.split('\\n')
    entries.extend(seg.strip() for seg in parts[:-1])

# ---- OPTM_GROUPS, one entry per menu line ---------------------------------
grp_src = re.search(r'constant OPTM_GROUPS\s+: OPTM_GTYPE := \((.*?)\);\n', cfg, re.S).group(1)
groups = [g.strip() for g in grp_src.split(',') if g.strip()]

size = int(re.search(r'constant OPTM_SIZE\s+: natural := (\d+)', cfg).group(1))

print("== menu consistency ==")
print("   OPTM_SIZE=%d  entries=%d  groups=%d" % (size, len(entries), len(groups)))
if not (size == len(entries) == len(groups)):
    die("OPTM_SIZE, OPTM_ITEMS and OPTM_GROUPS disagree")

# ---- every C_MENU_* must point at something selectable --------------------
consts = sorted(
    ((n, int(v)) for n, v in
     re.findall(r'constant (C_MENU_[A-Z_0-9]+)\s+: natural := (\d+);', m65)),
    key=lambda kv: kv[1])
print("   %d C_MENU_* constants" % len(consts))

for name, idx in consts:
    if idx >= len(entries):
        die("%s = %d is past the end of the menu (%d entries)" % (name, idx, len(entries)))
        continue
    grp = groups[idx] if idx < len(groups) else ''
    text = entries[idx]
    if 'OPTM_G_LINE' in grp:
        die("%s = %d points at a separator, not a menu item" % (name, idx))
    elif 'OPTM_G_HEADLINE' in grp:
        die("%s = %d points at the heading %r" % (name, idx, text))
    elif not text:
        die("%s = %d points at a blank entry" % (name, idx))

# ---- MENU_HEAP_SIZE vs what the options menu needs ------------------------
asm = open('../../m2m-rom/m2m-rom.asm', encoding='utf-8').read()
glb = open('../globals.vhd', encoding='utf-8').read()
heap = int(re.search(r'MENU_HEAP_SIZE\s+\.EQU\s+(\d+)', asm).group(1))
dx   = int(re.search(r'constant OPTM_DX\s+: natural := (\d+)', cfg).group(1))
vd   = int(re.search(r'constant C_VDNUM\s+: natural := (\d+)', glb).group(1))
man  = int(re.search(r'constant C_CRTROMS_MAN_NUM\s+: natural := (\d+)', glb).group(1))
submenus = grp_src.count('OPTM_G_SUBMENU') // 2      # each submenu opens and closes

# OPTM_HEAP: OPTM_DX words per "%s" filename slot - one per virtual drive, per
# submenu and per manually loadable ROM, plus one scratch slot. This formula is
# options.asm's own, just above its OPTM_HEAP_SIZE check.
slots  = vd + submenus + man + 1
demand = dx * slots

# The menu structure is assembled at runtime so its size is not literally
# known here. 14.6 words per entry is measured: a 99-entry menu with
# C_CRTROMS_MAN_NUM=3 overran a 1664-word heap by exactly 22, which puts the
# structure at 1436 words, and the same constant correctly predicts that the
# previous 98-entry/2-ROM configuration fitted with 18 words to spare. If this
# estimate and reality ever diverge, the firmware logs the true figures to the
# serial terminal via LOG_HEAP1 and LOG_HEAP2.
WORDS_PER_ENTRY = 14.6
MARGIN = 16

structure = int(WORDS_PER_ENTRY * size + 0.5)
needed    = structure + demand

print()
print("== options menu heap ==")
print("   slots  : %d drives + %d submenus + %d ROMs + 1 scratch = %d, x OPTM_DX %d = %d words"
      % (vd, submenus, man, slots, dx, demand))
print("   struct : %d entries x ~%.1f = ~%d words (measured)" % (size, WORDS_PER_ENTRY, structure))
print("   total  : ~%d of MENU_HEAP_SIZE %d  (%d spare)" % (needed, heap, heap - needed))

if needed > heap:
    die("MENU_HEAP_SIZE %d is about %d words too small - the firmware will stop "
        "with \"Heap corruption: Hint: OPTM_HEAP_SIZE\" when the menu is opened. "
        "Raise it in CORE/m2m-rom/m2m-rom.asm and reduce HEAP_SIZE by the same "
        "amount." % (heap, needed - heap))
elif heap - needed < MARGIN:
    die("MENU_HEAP_SIZE %d leaves only %d words spare, under the %d-word margin - "
        "raise it in CORE/m2m-rom/m2m-rom.asm" % (heap, heap - needed, MARGIN))

# ---- OPTM_G_LOAD_ROM menu order vs C_CRTROMS_MAN ---------------------------
# The expected globals.vhd symbol for each kind of loadable item, keyed by the
# first word of the menu text. Add a line here when you add a loadable ROM
# item. Keying on the first word rather than the whole label leaves room for a
# suffix like the " (9)" that says which IEC device the C1581 answers on.
ROM_ITEM_SYMBOL = {
    'D81': 'C_HMAP_1581_IMG',
    'PRG': 'C_DEV_C64_PRG',
    'CRT': 'C_DEV_C64_CRT',
}

# menu items carrying OPTM_G_LOAD_ROM, in menu order
load_rom_items = [(i, entries[i]) for i, g in enumerate(groups)
                  if 'OPTM_G_LOAD_ROM' in g]

# C_CRTROMS_MAN, in array order: entries are (type, device-or-window) pairs,
# terminated by x"EEEE"
man_src = re.search(r'constant C_CRTROMS_MAN\s+: crtrom_buf_array :=\s*\((.*?)\);\n',
                    glb, re.S).group(1)
man_src = re.sub(r'--[^\n]*', '', man_src)                   # strip comments
man_toks = [t.strip() for t in man_src.split(',') if t.strip()]
man_toks = [t for t in man_toks if 'EEEE' not in t]
man_pairs = list(zip(man_toks[0::2], man_toks[1::2]))

print()
print("== loadable ROM order ==")
print("   %d OPTM_G_LOAD_ROM menu item(s), C_CRTROMS_MAN_NUM=%d, %d array entr(ies)"
      % (len(load_rom_items), man, len(man_pairs)))

if len(load_rom_items) != man:
    die("%d menu items carry OPTM_G_LOAD_ROM but C_CRTROMS_MAN_NUM is %d"
        % (len(load_rom_items), man))
if len(man_pairs) != man:
    die("C_CRTROMS_MAN holds %d entries but C_CRTROMS_MAN_NUM is %d"
        % (len(man_pairs), man))

def item_kind(text):
    label = text.split(':')[0].strip()        # " D81 (9):%s" -> "D81 (9)"
    return label.split()[0].upper() if label.split() else ''

for slot, (idx, text) in enumerate(load_rom_items):
    kind = item_kind(text)
    want = ROM_ITEM_SYMBOL.get(kind)
    got  = man_pairs[slot][1] if slot < len(man_pairs) else '<missing>'
    print("   slot %d  menu[%d] %-22r -> %s" % (slot, idx, text, got))
    if want is None:
        die("menu item %r at index %d carries OPTM_G_LOAD_ROM but is not in "
            "ROM_ITEM_SYMBOL - add it to check_menu.sh" % (text, idx))
    elif want != got:
        die("menu item %r is loadable ROM slot %d, but C_CRTROMS_MAN slot %d is "
            "%s, not %s - reorder C_CRTROMS_MAN in globals.vhd to match the menu"
            % (text, slot, slot, got, want))

# the firmware hard-codes the slot of the *.d81 entry to publish its load flag
m = re.search(r'C64_CRTROM_MAN_D81\s+\.EQU\s+(0x[0-9A-Fa-f]+|\d+)', asm)
if m:
    asm_slot = int(m.group(1), 0)
    d81_slot = next((s for s, (_, t) in enumerate(load_rom_items)
                     if item_kind(t) == 'D81'), None)
    print("   C64_CRTROM_MAN_D81 = %d (m2m-rom.asm), D81 is slot %s"
          % (asm_slot, d81_slot))
    if d81_slot is None:
        die("C64_CRTROM_MAN_D81 is defined but no D81 menu item carries "
            "OPTM_G_LOAD_ROM")
    elif asm_slot != d81_slot:
        die("C64_CRTROM_MAN_D81 is %d but the D81 item is loadable ROM slot %d "
            "- the core would be told the wrong mount status. Fix it in "
            "CORE/m2m-rom/m2m-rom.asm" % (asm_slot, d81_slot))

# ---- C1581 HyperRAM window layout ----------------------------------------
def hmap(name):
    m = re.search(r'constant %s\s+: std_logic_vector\(15 downto 0\) := x"([0-9A-Fa-f]+)"' % name, glb)
    return int(m.group(1), 16) if m else None

mem, rom, img = hmap('C_HMAP_1581_MEM'), hmap('C_HMAP_1581_ROM'), hmap('C_HMAP_1581_IMG')

if None not in (mem, rom, img):
    WIN_BYTES   = 8192          # a 4k window is 4096 *words*
    DRIVE_WINS  = 8             # the drive's own address space is 64 KB
    D81_BYTES   = 819200        # 80 tracks x 2 sides x 10 sectors x 512
    D81_WINS    = -(-D81_BYTES // WIN_BYTES)
    HYPERRAM_WINS = 1024        # 8 MB
    img_offs    = (img - mem) * WIN_BYTES

    print()
    print("== C1581 HyperRAM windows ==")
    print("   drive RAM/ROM 0x%03X..0x%03X   DOS ROM 0x%03X   image 0x%03X..0x%03X (%d windows)"
          % (mem, mem + DRIVE_WINS - 1, rom, img, img + D81_WINS - 1, D81_WINS))
    print("   image offset as the drive sees it: 0x%06X" % img_offs)

    if not (mem <= rom < mem + DRIVE_WINS):
        die("C_HMAP_1581_ROM 0x%03X is outside the drive's own block "
            "0x%03X..0x%03X - the drive fetches its DOS through the same memory "
            "bridge, so the ROM has to be inside the window that bridge offsets "
            "by" % (rom, mem, mem + DRIVE_WINS - 1))
    if img < mem + DRIVE_WINS:
        die("C_HMAP_1581_IMG 0x%03X overlaps the drive's own 64 KB "
            "(0x%03X..0x%03X) - the image has to start above it"
            % (img, mem, mem + DRIVE_WINS - 1))
    elif img_offs > 0xFFFFFF:
        die("the image sits 0x%06X above the drive window, which does not fit "
            "the 24-bit WD177x transfer_addr register" % img_offs)
    if img + D81_WINS > HYPERRAM_WINS:
        die("the image needs windows 0x%03X..0x%03X but HyperRAM only has "
            "0x000..0x%03X - the top would wrap onto the framework's frame "
            "buffers" % (img, img + D81_WINS - 1, HYPERRAM_WINS - 1))

print()
if die.bad:
    print("RESULT: %d problem(s) in the menu configuration" % die.bad)
    sys.exit(1)
print("RESULT: menu indices and heap are consistent")
PY
