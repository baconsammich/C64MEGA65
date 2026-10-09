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

print()
if die.bad:
    print("RESULT: %d problem(s) in the menu configuration" % die.bad)
    sys.exit(1)
print("RESULT: menu indices and heap are consistent")
PY
