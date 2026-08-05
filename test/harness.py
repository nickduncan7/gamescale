"""Shared rig for testing the display program embedded in gamescale.sh.

The program is extracted out of the script and run against synthetic
GetCurrentState replies, so what the suites exercise is the shipped code rather
than a copy of it. Replies are real GLib.Variants of mutter's exact signature,
so a signature mistake fails in the tests instead of at runtime.

Nothing here touches a display, a session bus, or PATH.
"""

import contextlib
import io
import pathlib
import sys

# Without PyGObject installed, `import gi` still succeeds — something else owns
# the name as an empty namespace package — and the failure surfaces as a bare
# AttributeError on require_version, which reads like a harness bug rather than
# a missing dependency. Say what is actually wrong.
import gi

if not hasattr(gi, "require_version"):
    sys.exit(
        "PyGObject is missing: `import gi` resolved to "
        f"{getattr(gi, '__file__', None)!r}, not the real module.\n"
        "  Fedora: sudo dnf install python3-gobject\n"
        "  Debian: sudo apt install python3-gi gir1.2-glib-2.0"
    )

gi.require_version("Gio", "2.0")
gi.require_version("GLib", "2.0")
from gi.repository import GLib, Gio  # noqa: E402

SCRIPT = pathlib.Path(__file__).resolve().parent.parent / "gamescale.sh"

# GetCurrentState's reply: (serial, monitors, logical_monitors, properties)
REPLY = "(ua((ssss)a(siiddada{sv})a{sv})a(iiduba(ssss)a{sv})a{sv})"

# What ApplyMonitorsConfig takes, for decoding what the program sent.
REQUEST = "(uua(iiduba(ssa{sv}))a{sv})"

VERIFY, TEMPORARY, PERSISTENT = 0, 1, 2


def program_source():
    """The body of the <<'PY' heredoc in gamescale.sh, verbatim."""
    text = SCRIPT.read_text()
    opener = "<<'PY'\n"
    start = text.index(opener) + len(opener)
    end = text.index("\nPY\n", start)
    return text[start:end]


PROGRAM = compile(program_source(), "gamescale.sh:display_config", "exec")


def spec(connector, product="Product"):
    return (connector, "Vendor", product, "SN123")


def mode(mode_id="2560x1600@60.000", width=2560, height=1600,
         scales=(1.0, 1.25, 1.3333333730697632, 1.6666666269302368, 2.0),
         current=True, preferred=True):
    props = {}
    if current:
        props["is-current"] = GLib.Variant("b", True)
    if preferred:
        props["is-preferred"] = GLib.Variant("b", True)
    return (mode_id, width, height, 60.0, 1.0, list(scales), props)


def monitor(connector, modes=None, product="Product"):
    return (spec(connector, product), modes or [mode()], {})


def logical(connectors, scale=1.0, transform=0, primary=True, x=0, y=0):
    if isinstance(connectors, str):
        connectors = [connectors]
    return (x, y, scale, transform, primary, [spec(c) for c in connectors], {})


def reply(monitors, logical_monitors, serial=7, properties=None):
    props = {"layout-mode": GLib.Variant("u", 1),
             "supports-changing-layout-mode": GLib.Variant("b", True)}
    if properties is not None:
        props = properties
    return GLib.Variant(REPLY, (serial, monitors, logical_monitors, props))


class Result:
    def __init__(self, out, err, code, applied):
        self.lines = out.splitlines()
        self.stderr = err
        self.code = code
        # One entry per ApplyMonitorsConfig call, in order:
        # {"serial", "method", "logical", "properties"}
        self.applied = applied

    @property
    def methods(self):
        return [call["method"] for call in self.applied]


def run(argv, state, reject_call=None):
    """Run the program with argv, answering GetCurrentState with `state`.

    reject_call: 1-based index of the ApplyMonitorsConfig call that should raise,
    standing in for mutter refusing a configuration.
    """
    applied = []

    class FakeProxy:
        def call_sync(self, **kwargs):
            name = kwargs["method_name"]
            if name == "GetCurrentState":
                if isinstance(state, Exception):
                    raise state
                return state
            if name == "ApplyMonitorsConfig":
                serial, method, logical_monitors, properties = \
                    kwargs["parameters"].unpack()
                applied.append({"serial": serial, "method": method,
                                "logical": logical_monitors,
                                "properties": properties})
                if reject_call is not None and len(applied) == reject_call:
                    raise RuntimeError("mutter said no")
                return None
            raise AssertionError("unexpected method %s" % name)

    class StubProxyClass:
        @staticmethod
        def new_for_bus_sync(**_kwargs):
            if isinstance(state, Exception):
                raise state
            return FakeProxy()

    saved_proxy, saved_argv = Gio.DBusProxy, sys.argv
    Gio.DBusProxy = StubProxyClass
    sys.argv = ["display_config"] + list(argv)
    out, err, code = io.StringIO(), io.StringIO(), 0
    try:
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            exec(PROGRAM, {"__name__": "__main__"})
    except SystemExit as exc:
        code = exc.code or 0
    finally:
        Gio.DBusProxy, sys.argv = saved_proxy, saved_argv
    return Result(out.getvalue(), err.getvalue(), code, applied)


class Suite:
    def __init__(self, title):
        self.passed = 0
        self.failed = 0
        print(title)
        print()

    def check(self, name, condition, detail=""):
        if condition:
            print(f"  \033[32mok\033[0m   {name}")
            self.passed += 1
        else:
            print(f"  \033[31mFAIL\033[0m {name}")
            if detail:
                for line in str(detail).splitlines():
                    print(f"         {line}")
            self.failed += 1

    def equal(self, name, got, expected):
        self.check(name, got == expected,
                   f"expected {expected!r}\ngot      {got!r}")

    def done(self):
        print()
        print(f"  {self.passed} passed, {self.failed} failed")
        sys.exit(0 if self.failed == 0 else 1)
