#!/usr/bin/env python3
"""Monitor detection tests — what gamescale reads back out of mutter.

Runs the display program extracted from gamescale.sh against synthetic
GetCurrentState replies. See harness.py. No display, no session bus, no stubs
on PATH.

  ./test/detect_test.py
"""

import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))

import harness as h  # noqa: E402

t = h.Suite("monitor detection")


def read(logical_monitors, monitors=None):
    return h.run(["read"], h.reply(monitors or [h.monitor("eDP-1")],
                                   logical_monitors))


# The scale must survive as the exact double mutter reported. gdctl was loose
# about this — it snapped anything within 0.1 to a supported value — but mutter
# takes what it is given, so an inexact scale on the restore path is either
# refused or silently a different scale than the one you were on.
r = read([h.logical("eDP-1", scale=1.3333333730697632)])
t.equal("laptop panel, fractional scale", r.lines,
        ["eDP-1\t1.3333333730697632\tyes\t0\t0\tnormal"])

# Every logical monitor is captured, in mutter's order, whichever is primary:
# XWayland's factor is global, and a monitor left out of a configuration is a
# monitor switched off.
r = read([h.logical("HDMI-A-1", scale=1.5, primary=False, x=1920),
          h.logical("eDP-1", scale=1.5)],
         [h.monitor("HDMI-A-1"), h.monitor("eDP-1")])
t.equal("two monitors, non-first primary", r.lines,
        ["HDMI-A-1\t1.5\tno\t1920\t0\tnormal",
         "eDP-1\t1.5\tyes\t0\t0\tnormal"])

r = read([h.logical("eDP-1"),
          h.logical("HDMI-1", primary=False, x=1920),
          h.logical("DP-2", primary=False, x=3840)],
         [h.monitor("eDP-1"), h.monitor("HDMI-1"), h.monitor("DP-2")])
t.equal("three monitors keep their order", r.lines,
        ["eDP-1\t1.0\tyes\t0\t0\tnormal",
         "HDMI-1\t1.0\tno\t1920\t0\tnormal",
         "DP-2\t1.0\tno\t3840\t0\tnormal"])

# A mirrored logical monitor drives several connectors at once; dropping the
# second would switch that output off.
r = read([h.logical(["eDP-1", "HDMI-1"])],
         [h.monitor("eDP-1"), h.monitor("HDMI-1")])
t.equal("mirrored pair", r.lines, ["eDP-1,HDMI-1\t1.0\tyes\t0\t0\tnormal"])

r = read([h.logical("DP-2", scale=2.0, primary=False, x=-1920, y=-200)],
         [h.monitor("DP-2")])
t.equal("negative position, display left of primary", r.lines,
        ["DP-2\t2.0\tno\t-1920\t-200\tnormal"])

# The v1.0.1 regression came from recovering connector names out of drawn text.
# Nothing parses a name now, but assert the multi-part ones arrive whole.
for connector in ("HDMI-A-1", "DVI-D-1", "HDMI-A-10", "DP_1", "VGA-1"):
    r = read([h.logical(connector)], [h.monitor(connector)])
    t.equal(f"connector {connector} survives intact", r.lines,
            [f"{connector}\t1.0\tyes\t0\t0\tnormal"])

# A product name is arbitrary user-visible text — one of this author's monitors
# reports 'RTK 16"'. It shares a structure with the fields we do read, which is
# exactly what made scraping drawn output a trap.
r = read([h.logical("eDP-1")],
         [h.monitor("eDP-1", product='Bob\'s 27" wide, cheap')])
t.equal("a hostile product name cannot leak into a record", r.lines,
        ["eDP-1\t1.0\tyes\t0\t0\tnormal"])

# gdctl numbers these in an order its own names do not suggest: 6 is
# flipped-270 and 7 is flipped-180. The state file stores these names, so this
# is the spelling that has to round-trip. Assuming mutter's enum order instead
# would rotate two of the eight configurations wrongly on restore, and only for
# the few people using them.
for value, name in ((0, "normal"), (1, "90"), (2, "180"), (3, "270"),
                    (4, "flipped"), (5, "flipped-90"),
                    (6, "flipped-270"), (7, "flipped-180")):
    r = read([h.logical("eDP-1", transform=value)])
    t.equal(f"transform {value} is {name}", r.lines,
            [f"eDP-1\t1.0\tyes\t0\t0\t{name}"])

# Declining is the correct answer to anything that could not be put back. The
# caller treats a non-zero exit as "could not determine monitor/scale" and
# launches the game unmodified.
r = read([h.logical("eDP-1", transform=99)])
t.equal("unknown transform is refused, not guessed", (r.lines, r.code), ([], 1))

r = read([h.logical("eDP-1"), h.logical("HDMI-1", primary=False, transform=99)])
t.equal("one unspellable transform voids the whole layout", r.code, 1)

r = h.run(["read"], RuntimeError("no session bus"))
t.equal("unreachable mutter is refused", (r.lines, r.code), ([], 1))

r = read([])
t.equal("no monitors yields nothing to apply", (r.lines, r.code), ([], 0))

# Reading must never move anything.
r = read([h.logical("eDP-1")])
t.equal("reading applies no configuration", r.applied, [])

t.done()
