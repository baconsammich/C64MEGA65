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

print()
if die.bad:
    print("RESULT: %d problem(s) - the C_MENU_* indices and the menu disagree" % die.bad)
    sys.exit(1)
print("RESULT: menu and C_MENU_* indices agree")
PY
