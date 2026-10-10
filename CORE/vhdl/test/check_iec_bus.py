#!/usr/bin/env python3
"""Check that the IEC bus in main.vhd is wired as a wired-AND node.

IEC CLK and DATA are open-collector: one shared wire per line that any device
can pull low. The core models that with an AND, so every participant has to be
fed the AND of what all the *other* participants drive. Miss a term and the
result is silent - the devices still work against whoever they can hear. The
C1581 was fed "c64_iec_clk_in", which despite the name is the C1541's output
rather than what the C64 drives, so it mounted disk images happily and never
answered a single command from the computer.

The signal naming is the whole trap, so it is spelled out here rather than
inferred: PARTICIPANTS maps each device to the signals it drives and to the
port-map formal through which it listens. Add a device to the bus and this
table has to grow with it - which is the point.

Usage: ./check_iec_bus.py
"""
import os
import re
import sys

# Resolve relative to this script, not the caller's cwd, so the gate
# works from anywhere - the shell gates do the same with a cd.
SRC = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                   '../main.vhd')

# device -> (what it drives for CLK, for DATA, the formal it listens on)
PARTICIPANTS = {
    'C64 core':    ('c64_iec_clk_out', 'c64_iec_data_out', 'iec_clk_i'),
    'C1541':       ('c64_iec_clk_in',  'c64_iec_data_in',  'iec_clk_i'),
    'C1581':       ('c1581_iec_clk_o', 'c1581_iec_data_o', 'iec_clk_i'),
    # The physical IEC port on the MEGA65. It only ever listens through the
    # core, so it has no formal of its own, but it does drive the lines.
    'hardware port': ('hw_iec_clk_n_in', 'hw_iec_data_n_in', None),
}

# Which input expression belongs to which device, in source order. All three
# use the same formal names, so they are told apart by position.
ORDER = ['C64 core', 'C1541', 'C1581']


def main():
    src = open(SRC, encoding='utf-8').read()
    bad = 0

    print("== IEC wired-AND bus ==")

    for line, idx in (('clk', 0), ('data', 1)):
        formal = 'iec_%s_i' % line
        # port-map associations: "iec_clk_i => <expr>," possibly padded
        exprs = re.findall(r'\b%s\s*=>\s*([^,\n]+)' % formal, src)
        if len(exprs) != len(ORDER):
            print("   found %d '%s' associations, expected %d (%s)"
                  % (len(exprs), formal, len(ORDER), ', '.join(ORDER)))
            bad += 1
            continue

        drivers = {name: sigs[idx] for name, sigs in PARTICIPANTS.items()}

        for who, expr in zip(ORDER, exprs):
            seen = set(re.findall(r'[A-Za-z_][A-Za-z_0-9]*', expr)) - {'and', 'not'}
            want = {s for name, s in drivers.items() if name != who}
            missing = want - seen
            extra   = seen - want - {drivers[who]}
            label = "%s %s" % (who, line.upper())
            if missing or extra:
                bad += 1
                print("   %-18s %s" % (label, expr.strip()))
                for m in sorted(missing):
                    owner = next(n for n, s in drivers.items() if s == m)
                    print("        MISSING %s (driven by the %s) - this device "
                          "cannot see it pull the line low" % (m, owner))
                for e in sorted(extra):
                    print("        UNEXPECTED %s" % e)
            else:
                print("   %-18s OK  (%s)" % (label, expr.strip()))

    print()
    if bad:
        print("RESULT: %d problem(s) in the IEC bus wiring" % bad)
        return 1
    print("RESULT: every device sees every other device")
    return 0


if __name__ == '__main__':
    sys.exit(main())
