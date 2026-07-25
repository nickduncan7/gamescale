#!/usr/bin/env python3
"""Applying tests — what gamescale actually asks mutter to do.

Asserts on the exact ApplyMonitorsConfig payload, which is the whole reason for
talking to mutter directly: the previous suite could only grep a stringified
gdctl command line. Nothing here touches a display.

The arithmetic under test used to be gdctl's. gdctl is a CLI for people, so it
does things a program does not need — snapping a scale someone typed, placing
monitors relative to each other — and going direct means owning the parts mutter
genuinely requires: a mode id per monitor, and logical monitors that tile exactly.

  ./test/apply_test.py
"""

import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))

import harness as h  # noqa: E402

t = h.Suite("applying")

ONE = [h.monitor("eDP-1")]
TWO = [h.monitor("eDP-1"), h.monitor("HDMI-1")]

# --- verify always runs, and applying stops if it fails ---------------------
# The gate that makes duplicating mutter's layout rules survivable: a
# configuration we got wrong is refused before anything moves.

r = h.run(["apply", "eDP-1;1;yes;0;0;normal"], h.reply(ONE, [h.logical("eDP-1")]))
t.equal("verify runs before apply", r.methods, [h.VERIFY, h.TEMPORARY])
t.equal("applied, not persisted", r.methods[-1], h.TEMPORARY)
t.equal("exit 0", r.code, 0)

r = h.run(["apply", "eDP-1;1;yes;0;0;normal"],
          h.reply(ONE, [h.logical("eDP-1")]), reject_call=1)
t.equal("verify refused -> nothing applied", r.methods, [h.VERIFY])
t.equal("verify refused -> exit 2", r.code, 2)

r = h.run(["verify", "eDP-1;1;yes;0;0;normal"], h.reply(ONE, [h.logical("eDP-1")]))
t.equal("verify alone never applies", r.methods, [h.VERIFY])

# --- the serial is mutter's, so a display change under us is caught --------
r = h.run(["apply", "eDP-1;1;yes;0;0;normal"],
          h.reply(ONE, [h.logical("eDP-1")], serial=41))
t.equal("serial is replayed from GetCurrentState",
        [c["serial"] for c in r.applied], [41, 41])

# --- what one monitor at 1x looks like on the wire -------------------------
r = h.run(["apply", "--pack", "eDP-1;1;yes;0;0;normal"],
          h.reply(ONE, [h.logical("eDP-1", scale=1.3333333730697632)]))
t.equal("logical monitor payload",
        r.applied[-1]["logical"],
        [(0, 0, 1.0, 0, True, [("eDP-1", "2560x1600@60.000", {})])])

# --- packing: the arithmetic gdctl's --right-of used to do ------------------
# At 1x a logical monitor is its mode, so the common case cannot round.
r = h.run(["apply", "--pack", "eDP-1;1;yes;0;0;normal", "HDMI-1;1;no;1920;0;normal"],
          h.reply(TWO, [h.logical("eDP-1"), h.logical("HDMI-1", primary=False, x=1920)]))
t.equal("two monitors tile edge to edge at 1x",
        [(m[0], m[1]) for m in r.applied[-1]["logical"]], [(0, 0), (2560, 0)])

# Order follows the existing layout, not the order records happen to arrive in.
r = h.run(["apply", "--pack", "HDMI-1;1;no;1920;0;normal", "eDP-1;1;yes;0;0;normal"],
          h.reply(TWO, [h.logical("HDMI-1", primary=False, x=1920), h.logical("eDP-1")]))
t.equal("leftmost monitor lands at x=0",
        [(m[5][0][0], m[0]) for m in r.applied[-1]["logical"]],
        [("eDP-1", 0), ("HDMI-1", 2560)])

# Monitors sharing an x are a vertical stack, so they pack downward.
r = h.run(["apply", "--pack", "eDP-1;1;yes;0;0;normal", "HDMI-1;1;no;0;1200;normal"],
          h.reply(TWO, [h.logical("eDP-1"), h.logical("HDMI-1", primary=False, y=1200)]))
t.equal("a vertical stack packs downward",
        [(m[0], m[1]) for m in r.applied[-1]["logical"]], [(0, 0), (0, 1600)])

# The one place rounding can happen: a fractional GAMESCALE_SCALE.
# 2560 / 1.3333333730697632 = 1919.99995... -> 1920, matching gdctl's round().
r = h.run(["apply", "--pack",
           "eDP-1;1.3333333730697632;yes;0;0;normal",
           "HDMI-1;1.3333333730697632;no;1920;0;normal"],
          h.reply(TWO, [h.logical("eDP-1"), h.logical("HDMI-1", primary=False, x=1920)]))
t.equal("fractional scale rounds the logical size like gdctl does",
        [(m[0], m[1]) for m in r.applied[-1]["logical"]], [(0, 0), (1920, 0)])

# --- rotation swaps width and height, and 6/7 are not what they look like ---
# transform_size swaps for {90, 270, 90-flipped, 270-flipped} = 1, 3, 5, 6.
# So 6 swaps and 7 does not. Reading it off the intuitive order gets both wrong.
for transform, name, expect_x in (
    (0, "normal", 2560),
    (1, "90", 1600),
    (2, "180", 2560),
    (3, "270", 1600),
    (4, "flipped", 2560),
    (5, "flipped-90", 1600),
    (6, "flipped-270", 1600),
    (7, "flipped-180", 2560),
):
    r = h.run(["apply", "--pack",
               f"eDP-1;1;yes;0;0;{name}", "HDMI-1;1;no;1920;0;normal"],
              h.reply(TWO, [h.logical("eDP-1", transform=transform),
                            h.logical("HDMI-1", primary=False, x=1920)]))
    got = r.applied[-1]["logical"][1][0] if r.applied else None
    t.equal(f"transform {transform} ({name}) advances x by {expect_x}",
            got, expect_x)

# --- mirroring, primary, and transforms survive the round trip -------------
r = h.run(["apply", "eDP-1,HDMI-1;1;yes;0;0;normal"],
          h.reply(TWO, [h.logical(["eDP-1", "HDMI-1"])]))
t.equal("a mirrored logical monitor keeps both connectors",
        [m[0] for m in r.applied[-1]["logical"][0][5]], ["eDP-1", "HDMI-1"])

r = h.run(["apply", "eDP-1;1;no;0;0;normal", "HDMI-1;1;yes;1920;0;270"],
          h.reply(TWO, [h.logical("eDP-1", primary=False),
                        h.logical("HDMI-1", x=1920)]))
payload = r.applied[-1]["logical"]
t.equal("primary flag follows the record", [m[4] for m in payload], [False, True])
t.equal("transform is sent as its number", [m[3] for m in payload], [0, 3])

# --- without --pack, coordinates are replayed as recorded (the restore path) -
r = h.run(["apply", "eDP-1;1.3333333730697632;yes;0;0;normal",
           "HDMI-1;1.3333333730697632;no;1440;220;normal"],
          h.reply(TWO, [h.logical("eDP-1"), h.logical("HDMI-1", primary=False)]))
t.equal("saved coordinates are replayed untouched",
        [(m[0], m[1]) for m in r.applied[-1]["logical"]], [(0, 0), (1440, 220)])
t.equal("saved scale is replayed untouched",
        [m[2] for m in r.applied[-1]["logical"]],
        [1.3333333730697632, 1.3333333730697632])

# --- mode selection --------------------------------------------------------
# Keep the mode the monitor is on. Nothing here should ever change resolution.
CURRENT_IS_SECOND = [h.monitor("eDP-1", modes=[
    h.mode("2560x1600@240.000", current=False, preferred=True),
    h.mode("2560x1600@60.000", current=True, preferred=False),
])]
r = h.run(["apply", "eDP-1;1;yes;0;0;normal"],
          h.reply(CURRENT_IS_SECOND, [h.logical("eDP-1")]))
t.equal("the current mode is kept, not the preferred one",
        r.applied[-1]["logical"][0][5][0][1], "2560x1600@60.000")

NO_CURRENT = [h.monitor("eDP-1", modes=[
    h.mode("2560x1600@60.000", current=False, preferred=True)])]
r = h.run(["apply", "eDP-1;1;yes;0;0;normal"],
          h.reply(NO_CURRENT, [h.logical("eDP-1")]))
t.equal("with no current mode, the preferred one is used",
        r.applied[-1]["logical"][0][5][0][1], "2560x1600@60.000")

# --- scales: snapped like gdctl, but out loud ------------------------------
r = h.run(["apply", "--pack", "eDP-1;1.7;yes;0;0;normal"],
          h.reply(ONE, [h.logical("eDP-1")]))
t.equal("a near-miss scale is snapped to a supported one",
        r.applied[-1]["logical"][0][2], 1.6666666269302368)
t.check("the substitution is reported, not silent",
        "nearest supported" in r.stderr, r.stderr)

r = h.run(["apply", "--pack", "eDP-1;3.7;yes;0;0;normal"],
          h.reply(ONE, [h.logical("eDP-1")]))
t.equal("an unsupported scale is refused", r.code, 2)
t.equal("an unsupported scale applies nothing", r.applied, [])

# --- refusing is always allowed; guessing never is -------------------------
r = h.run(["apply", "--pack", "DP-9;1;yes;0;0;normal"],
          h.reply(ONE, [h.logical("eDP-1")]))
t.equal("a disconnected monitor is refused", r.code, 2)
t.equal("a disconnected monitor applies nothing", r.applied, [])

r = h.run(["apply", "eDP-1;1;yes;0;0;sideways"], h.reply(ONE, [h.logical("eDP-1")]))
t.equal("an unknown transform name is refused", r.code, 1)
t.equal("an unknown transform applies nothing", r.applied, [])

for bad in ("eDP-1;1;yes;0;0", "eDP-1;x;yes;0;0;normal", "eDP-1;1;yes;a;0;normal"):
    r = h.run(["apply", bad], h.reply(ONE, [h.logical("eDP-1")]))
    t.check(f"malformed record {bad!r} is refused",
            r.code != 0 and not r.applied, f"code={r.code} applied={r.applied}")

r = h.run(["apply"], h.reply(ONE, [h.logical("eDP-1")]))
t.equal("apply with no records does nothing", r.applied, [])
t.equal("apply with no records fails", r.code, 1)

r = h.run(["apply", "eDP-1;1;yes;0;0;normal"], RuntimeError("no session bus"))
t.equal("an unreachable mutter is refused", r.code, 1)

# --- layout mode -----------------------------------------------------------
# Physical layout mode means logical size is the mode itself, undivided.
r = h.run(["apply", "--pack", "eDP-1;2;yes;0;0;normal", "HDMI-1;2;no;1920;0;normal"],
          h.reply(TWO, [h.logical("eDP-1"), h.logical("HDMI-1", primary=False, x=1920)],
                  properties={"layout-mode": h.GLib.Variant("u", 2),
                              "supports-changing-layout-mode":
                                  h.GLib.Variant("b", True)}))
t.equal("physical layout mode does not divide by scale",
        [(m[0], m[1]) for m in r.applied[-1]["logical"]], [(0, 0), (2560, 0)])
t.equal("layout-mode is echoed back when mutter allows changing it",
        r.applied[-1]["properties"].get("layout-mode"), 2)

r = h.run(["apply", "eDP-1;1;yes;0;0;normal"],
          h.reply(ONE, [h.logical("eDP-1")],
                  properties={"layout-mode": h.GLib.Variant("u", 1)}))
t.equal("layout-mode is omitted when mutter does not support changing it",
        r.applied[-1]["properties"], {})

t.done()
