#!/usr/bin/env python3
"""Monitor detection tests.

Extracts the python reader embedded in gamescale.sh and runs it against
synthetic GetCurrentState replies, so what is under test is the shipped reader
rather than a copy of it. The replies are real GLib.Variants of mutter's exact
signature, so getting that signature wrong fails here instead of at runtime.

No display, no session bus, no stub binary on PATH.

  ./test/detect_test.py
"""

import contextlib
import io
import pathlib
import sys

import gi

gi.require_version("Gio", "2.0")
gi.require_version("GLib", "2.0")
from gi.repository import GLib, Gio  # noqa: E402

SCRIPT = pathlib.Path(__file__).resolve().parent.parent / "gamescale.sh"

# org.gnome.Mutter.DisplayConfig.GetCurrentState's reply:
#   (serial, monitors, logical_monitors, properties)
REPLY = "(ua((ssss)a(siiddada{sv})a{sv})a(iiduba(ssss)a{sv})a{sv})"


def reader_source():
    """The body of the <<'PY' heredoc in gamescale.sh, verbatim."""
    text = SCRIPT.read_text()
    opener = "<<'PY'\n"
    start = text.index(opener) + len(opener)
    end = text.index("\nPY\n", start)
    return text[start:end]


BODY = compile(reader_source(), "gamescale.sh:detect", "exec")


class FakeProxy:
    def __init__(self, reply):
        self._reply = reply

    def call_sync(self, **_kwargs):
        if isinstance(self._reply, Exception):
            raise self._reply
        return self._reply


def run_reader(reply):
    """Run the extracted reader against one reply; return (lines, exit_code)."""
    class StubProxy:
        @staticmethod
        def new_for_bus_sync(**_kwargs):
            if isinstance(reply, Exception):
                raise reply
            return FakeProxy(reply)

    saved = Gio.DBusProxy
    Gio.DBusProxy = StubProxy
    out = io.StringIO()
    code = 0
    try:
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(io.StringIO()):
            exec(BODY, {"__name__": "__main__"})
    except SystemExit as exc:
        code = exc.code or 0
    finally:
        Gio.DBusProxy = saved
    return out.getvalue().splitlines(), code


def state(logical, serial=1):
    return GLib.Variant(REPLY, (serial, [], logical, {}))


def spec(connector):
    # (connector, vendor, product, serial) — only the connector is used, since
    # that is what gdctl set --monitor takes.
    return (connector, "Vendor", 'Product 27" wide', "SN123")


PASS = 0
FAIL = 0


def check(name, reply, expected_lines, expected_code=0):
    global PASS, FAIL
    lines, code = run_reader(reply)
    if lines == expected_lines and code == expected_code:
        print(f"  \033[32mok\033[0m   {name}")
        PASS += 1
    else:
        print(f"  \033[31mFAIL\033[0m {name}")
        print(f"         expected {expected_lines} rc={expected_code}")
        print(f"         got      {lines} rc={code}")
        FAIL += 1


print("monitor detection")
print()

# The scale must survive as the exact double mutter reported: gdctl only accepts
# a scale its modes support, and a rounded one is rejected on the restore path.
check(
    "laptop panel, fractional scale",
    state([(0, 0, 1.3333333730697632, 0, True, [spec("eDP-1")], {})]),
    ["eDP-1\t1.3333333730697632\tyes\t0\t0\tnormal"],
)

# Every logical monitor is captured, in mutter's order, whichever is primary:
# XWayland's factor is global, and a monitor left out of a gdctl config is a
# monitor switched off.
check(
    "two monitors, non-first primary",
    state([
        (1920, 0, 1.5, 0, False, [spec("HDMI-A-1")], {}),
        (0, 0, 1.5, 0, True, [spec("eDP-1")], {}),
    ]),
    [
        "HDMI-A-1\t1.5\tno\t1920\t0\tnormal",
        "eDP-1\t1.5\tyes\t0\t0\tnormal",
    ],
)

check(
    "three monitors keep their order",
    state([
        (0, 0, 1.0, 0, True, [spec("eDP-1")], {}),
        (1920, 0, 1.0, 0, False, [spec("HDMI-1")], {}),
        (3840, 0, 1.0, 0, False, [spec("DP-2")], {}),
    ]),
    [
        "eDP-1\t1.0\tyes\t0\t0\tnormal",
        "HDMI-1\t1.0\tno\t1920\t0\tnormal",
        "DP-2\t1.0\tno\t3840\t0\tnormal",
    ],
)

# A mirrored logical monitor drives several connectors at once; dropping the
# second would switch that output off.
check(
    "mirrored pair",
    state([(0, 0, 1.0, 0, True, [spec("eDP-1"), spec("HDMI-1")], {})]),
    ["eDP-1,HDMI-1\t1.0\tyes\t0\t0\tnormal"],
)

check(
    "negative position, display left of primary",
    state([(-1920, -200, 2.0, 0, False, [spec("DP-2")], {})]),
    ["DP-2\t2.0\tno\t-1920\t-200\tnormal"],
)

# The v1.0.1 regression came from recovering connector names out of drawn text.
# Nothing here parses a name, but assert the multi-part ones still arrive whole.
for connector in ("HDMI-A-1", "DVI-D-1", "HDMI-A-10", "DP_1", "VGA-1"):
    check(
        f"connector {connector} survives intact",
        state([(0, 0, 1.0, 0, True, [spec(connector)], {})]),
        [f"{connector}\t1.0\tyes\t0\t0\tnormal"],
    )

check(
    "rotated 90",
    state([(0, 0, 1.0, 1, True, [spec("eDP-1")], {})]),
    ["eDP-1\t1.0\tyes\t0\t0\t90"],
)

# gdctl numbers these in an order its own names do not suggest: 6 is
# flipped-270 and 7 is flipped-180. These strings go straight back to `gdctl set
# --transform`, so gdctl's spelling is the only one that round-trips. Assuming
# mutter's FLIPPED_180/FLIPPED_270 enum order instead would rotate two of the
# eight configurations wrongly on restore, and only for people using them.
check(
    "transform 4 is flipped",
    state([(0, 0, 1.0, 4, True, [spec("eDP-1")], {})]),
    ["eDP-1\t1.0\tyes\t0\t0\tflipped"],
)
check(
    "transform 5 is flipped-90",
    state([(0, 0, 1.0, 5, True, [spec("eDP-1")], {})]),
    ["eDP-1\t1.0\tyes\t0\t0\tflipped-90"],
)
check(
    "transform 6 is flipped-270, not flipped-180",
    state([(0, 0, 1.0, 6, True, [spec("eDP-1")], {})]),
    ["eDP-1\t1.0\tyes\t0\t0\tflipped-270"],
)
check(
    "transform 7 is flipped-180, not flipped-270",
    state([(0, 0, 1.0, 7, True, [spec("eDP-1")], {})]),
    ["eDP-1\t1.0\tyes\t0\t0\tflipped-180"],
)

# Declining is the correct answer to anything we could not put back. The caller
# treats a non-zero exit as "could not determine monitor/scale" and launches the
# game unmodified.
check(
    "unknown transform is refused, not guessed",
    state([(0, 0, 1.0, 99, True, [spec("eDP-1")], {})]),
    [],
    expected_code=1,
)
check(
    "a transform we cannot spell voids the whole layout",
    state([
        (0, 0, 1.0, 0, True, [spec("eDP-1")], {}),
        (1920, 0, 1.0, 99, False, [spec("HDMI-1")], {}),
    ]),
    ["eDP-1\t1.0\tyes\t0\t0\tnormal"],
    expected_code=1,
)
check(
    "unreachable mutter is refused",
    RuntimeError("no session bus"),
    [],
    expected_code=1,
)
check(
    "no monitors at all yields nothing to apply",
    state([]),
    [],
)

print()
print(f"  {PASS} passed, {FAIL} failed")
sys.exit(0 if FAIL == 0 else 1)
