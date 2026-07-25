#!/usr/bin/env bash
#
# gamescale — run a game at 1x monitor scale so XWayland hands it the panel's
# real mode instead of an overscaled framebuffer, compensating desktop font and
# cursor size so alt-tabbing stays usable. Restores on exit.
#
# RESILIENCE MODEL
#
#   Restoring cannot be owned by anything that dies with the game, because the
#   Steam flatpak's portal connection dies with it — a trap firing inside a
#   collapsing sandbox has no session bus left to talk to. So there are three
#   independent layers, any one of which is sufficient:
#
#     1. In-sandbox trap        — fast path, normal exit
#     2. Host-side watchdog     — holds an flock the game process owns. The
#                                 kernel releases that lock when the process
#                                 dies for ANY reason (exit, SIGKILL, crash,
#                                 OOM, Ctrl+C on Steam). The watchdog then
#                                 acquires it and restores. systemd owns the
#                                 watchdog, so it outlives the sandbox.
#     3. Login reconcile        — `--restore` on session start, covering a
#                                 hard reboot or a killed watchdog.
#
#   State lives on the host filesystem so all three layers, and you from a
#   terminal, can see the same file.
#
# SETUP
#
#   mkdir -p ~/.local/bin ~/.local/state/gamescale
#   cp gamescale.sh ~/.local/bin/gamescale && chmod +x ~/.local/bin/gamescale
#
#   flatpak override --user \
#       --filesystem="$HOME/.local/bin:ro" \
#       --filesystem="$HOME/.local/state/gamescale:create" \
#       --talk-name=org.freedesktop.Flatpak \
#       --env=PATH="/app/bin:/app/utils/bin:/usr/bin:$HOME/.local/bin" \
#       com.valvesoftware.Steam
#
#   The --env=PATH grant is what makes the launch option a bare name; the
#   sandbox PATH does not include ~/.local/bin by default. It REPLACES the
#   sandbox PATH, so --doctor checks the stock entries are still present.
#
#   gamescale --doctor          verify every moving part
#   gamescale --install-unit    install the login reconcile service
#   gamescale --version         print the installed version
#
#   Steam launch option:  gamescale %command%
#
# ENV
#   GAMESCALE_SCALE     scale while playing        (default: 1)
#   GAMESCALE_NO_FONT   1 to skip font/cursor compensation
#   GAMESCALE_NO_WATCH  1 to skip the host watchdog (trap only)
#   GAMESCALE_DEBUG     1 for verbose logging

set -uo pipefail

# Reported by --version, --status and --doctor, because a bug report about
# display behaviour is unactionable without it: the script is copied to
# ~/.local/bin, so nothing else on the system records which release it came
# from. Release CI refuses to publish a tag that disagrees with this.
readonly VERSION="1.5.0"

readonly IFACE_SCHEMA="org.gnome.desktop.interface"
# 12h ceiling. On reaching it the watchdog gives up WITHOUT restoring, because
# a game still holding the lock is a game still running. Overridable so the
# give-up path is testable in seconds rather than half a day.
readonly WATCHDOG_TIMEOUT="${GAMESCALE_WATCHDOG_TIMEOUT:-43200}"
GAME_SCALE="${GAMESCALE_SCALE:-1}"

# Absolute path to this script. The watchdog and the login unit both re-invoke
# it from the host, so a bare "$0" from a PATH lookup is not enough. Granted
# directories are mounted at the same absolute path inside the sandbox, so one
# resolved path is valid on both sides.
SELF="$0"
[[ "$SELF" == */* ]] || SELF=$(command -v -- "$SELF" 2>/dev/null || printf '%s' "$SELF")
SELF=$(readlink -f -- "$SELF" 2>/dev/null || printf '%s' "$SELF")
readonly SELF

log()  { [[ "${GAMESCALE_DEBUG:-0}" == "1" ]] && echo "gamescale: $*" >&2; return 0; }
warn() { echo "gamescale: $*" >&2; }

# ---------------------------------------------------------------------------
# Mode parsing first — bail-out behaviour depends on whether there's a game to
# hand off to, so nothing below may exit before we know the mode.
# ---------------------------------------------------------------------------

MODE="run"
case "${1:-}" in
    --status)       MODE="status";   shift ;;
    --restore)      MODE="restore";  shift ;;
    --watchdog)     MODE="watchdog"; shift ;;
    --doctor)       MODE="doctor";   shift ;;
    --install-unit) MODE="install";  shift ;;
    # Answered before any dependency check, so it works on a broken install.
    --version|-V)   printf 'gamescale %s\n' "$VERSION"; exit 0 ;;
    --help|-h)      awk 'NR > 1 { if ($0 !~ /^#/) exit; sub(/^# ?/, ""); print }' \
                        "$SELF"; exit 0 ;;
    --)             shift ;;
    # Anything else flag-shaped is a typo, not a game. Falling through to run
    # mode would flick the display to 1x and then fail to exec it.
    -*)             warn "unknown option: $1"; warn "try --help"; exit 2 ;;
esac

# Give up on scaling but still start the game, if there is one. Never exec a
# leftover flag.
give_up() {
    local msg="$1"; shift
    warn "$msg"
    # Drop the lock first if we took one, so a run that gave up doesn't hold the
    # next launch off for the lifetime of the game it is about to exec.
    [[ "${HAVE_LOCK:-0}" == 1 ]] && exec 9>&-
    [[ "$MODE" == "run" && $# -gt 0 ]] && exec "$@"
    exit 1
}

# ---------------------------------------------------------------------------
# Host plumbing. Inside the Steam flatpak, gdctl/gsettings/systemd-run all live
# on the host and need the org.freedesktop.Flatpak portal to reach.
# ---------------------------------------------------------------------------

# Overridable purely so tests can drive the sandboxed branch; nothing else has a
# reason to move it. Untested, this was the only code path no suite could reach —
# and it is the path every Flatpak user takes.
readonly FLATPAK_INFO="${GAMESCALE_FLATPAK_INFO:-/.flatpak-info}"

IN_FLATPAK=0
HOST=()
if [[ -f "$FLATPAK_INFO" ]]; then
    IN_FLATPAK=1
    if command -v flatpak-spawn >/dev/null 2>&1; then
        HOST=(flatpak-spawn --host)
    else
        give_up "inside flatpak but flatpak-spawn is missing" "$@"
    fi
fi

host()         { "${HOST[@]}" "$@"; }
have_host()    { host sh -c "command -v $1 >/dev/null 2>&1"; }
host_capture() { host sh -c "$1" 2>/dev/null; }

# Absolute paths are identical inside and outside the sandbox for granted
# directories, so resolve the host's HOME once and use it on both sides.
# $HOME is deliberately unexpanded: it is evaluated on the host side.
# shellcheck disable=SC2016
HOST_HOME=$(host_capture 'printf "%s" "$HOME"')
[[ -n "$HOST_HOME" ]] || HOST_HOME="$HOME"

readonly STATE_DIR="${HOST_HOME}/.local/state/gamescale"
readonly STATE_FILE="${STATE_DIR}/state"
readonly LOCK_FILE="${STATE_DIR}/lock"
# The run token lives beside the state rather than inside it. Putting it in the
# state file changed a format that older copies parse strictly, and a 1.3.0
# script meeting a 1.4.0 state file refused it and left the display at 1x — a
# reachable state, since --install-unit bakes an absolute path and reinstalling
# elsewhere leaves the login unit pointing at the old script. A sibling file is
# invisible to every parser, past and future.
readonly RUN_FILE="${STATE_DIR}/run"

# ---------------------------------------------------------------------------
# Float helpers — awk, not bc, because awk is always present.
# ---------------------------------------------------------------------------

fmul()   { awk -v a="$1" -v b="$2" 'BEGIN { printf "%.6g", a * b }'; }
fdiv()   { awk -v a="$1" -v b="$2" 'BEGIN { printf "%.6g", a / b }'; }
fround() { awk -v a="$1" 'BEGIN { printf "%d", (a < 0 ? a - 0.5 : a + 0.5) }'; }
feq()    { awk -v a="$1" -v b="$2" 'BEGIN { exit !(a - b < 1e-9 && b - a < 1e-9) }'; }

# ---------------------------------------------------------------------------
# Detection — asks mutter directly, over
# org.gnome.Mutter.DisplayConfig.GetCurrentState.
#
# This used to scrape the "Logical monitors:" tree out of `gdctl show` with awk.
# That output is meant for humans: it has no stability contract, it is drawn
# with box glyphs, and a connector name had to be recovered by anchoring past
# them (an unanchored match found "A-1" inside "HDMI-A-1", which gdctl then
# rejected as an unknown monitor — the v1.0.1 regression). A GNOME release that
# reflows that tree breaks detection silently.
#
# GetCurrentState is the interface gdctl itself calls, and it hands over the
# same fields as typed values: position, scale as a double, transform as an
# enum, primary as a bool, and every connector driven by each logical monitor.
# No new dependency comes with it — gdctl IS a python3 + PyGObject script, so
# wherever gdctl exists so do both.
#
# Applying goes the same way, through ApplyMonitorsConfig. That means owning two
# things gdctl would otherwise do: choosing a mode id per monitor, and computing
# logical positions, since the D-Bus call takes absolute coordinates and has no
# equivalent of --right-of. Both are verified before they are applied.
#
# Not needing gdctl is the point: it arrived in Mutter 48, while this interface is
# years older, so this runs on GNOME releases that never shipped the CLI.
#
# EVERY logical monitor is captured, not just the primary one, because the
# XWayland scale factor is global: it only drops to 1 when every monitor is at
# 1.0. Scaling the primary alone leaves the factor at 2 and applies it to a
# full-resolution logical size, which costs MORE pixels than doing nothing
# (measured: 5120x3200 vs 3840x2400 on a 2560x1600 panel).
#
# A configuration replaces the whole layout, so a monitor left out of it is a
# monitor switched off. Everything detected here must be replayed.
#
# Scales are full-precision doubles, stored and replayed verbatim. Python's repr
# of a double is its shortest round-tripping form, so 1.3333333730697632 survives
# without any number ever being parsed out of text.
#
# Measured, not assumed: gdctl is looser than that on input — it accepted 1.33
# and even 1.7 on this panel, rejecting only 3.7, past the largest supported
# scale. So replaying verbatim is not what keeps a restore from being refused;
# it is what keeps you from being handed a neighbouring scale instead of the one
# you were on, and it costs nothing to be exact.
# ---------------------------------------------------------------------------

# Parallel arrays, one entry per logical monitor. MON_CONNS holds a
# comma-separated list because a mirrored logical monitor drives several.
MON_CONNS=(); MON_SCALE=(); MON_PRIM=(); MON_X=(); MON_Y=(); MON_TRANSFORM=()

# Everything that touches the display goes through this one program, run on the
# host. Records are the same shape the state file uses, so what is read, what is
# stored and what is applied are one format:
#
#   <connectors>;<scale>;<primary>;<x>;<y>;<transform>
#
#   display_config read                 print one TSV record per logical monitor
#   display_config verify [--pack] REC  would mutter accept this?
#   display_config apply  [--pack] REC  verify, then apply
#
# --pack ignores the x/y in the records and lays the monitors out edge to edge in
# their existing order, which is what applying needs: at a new scale every
# logical monitor changes size, so the old coordinates no longer tile. Without
# it the coordinates are used as given, which is what restoring needs.
#
# Exit status: 0 applied, 2 mutter rejected the configuration, 1 anything else.
#
# The body between <<'PY' and PY is extracted verbatim by test/detect_test.py
# and run against synthetic replies, so what is under test is this program and
# not a copy of it. Keep the markers on their own lines.
display_config() {
    host python3 - "$@" <<'PY'
import sys

import gi

gi.require_version("Gio", "2.0")
from gi.repository import GLib, Gio

# gdctl's numeric -> CLI spelling, copied from its Transform.enum_names table.
# 6 and 7 are NOT in the order the names suggest: gdctl calls 6 flipped-270 and
# 7 flipped-180, the reverse of mutter's own FLIPPED_180/FLIPPED_270 enum order.
# The state file stores these names, so this is the spelling that has to survive
# a round trip. Taking the intuitive order instead would silently rotate two of
# the eight configurations wrongly on restore.
TRANSFORM = {
    0: "normal",
    1: "90",
    2: "180",
    3: "270",
    4: "flipped",
    5: "flipped-90",
    6: "flipped-270",
    7: "flipped-180",
}
BY_NAME = {name: value for value, name in TRANSFORM.items()}

# Transforms whose logical size is the mode's, with width and height swapped.
# gdctl's set is {90, 270, 90-flipped, 270-flipped}, which in the numbering above
# is 1, 3, 5 and 6 — so 6 swaps and 7 does not, the same 6/7 ordering as the name
# table. Reading it off the intuitive order gets two rotations wrong.
SWAPPED = {1, 3, 5, 6}

# ApplyMonitorsConfig methods, and the layout mode in which a logical monitor's
# size is its mode divided by its scale.
VERIFY, TEMPORARY = 0, 1
LOGICAL_LAYOUT_MODE = 1

# gdctl accepts a scale within this of a supported one and quietly substitutes
# the supported value (its find_closest_scale). mutter itself does not: it takes
# what it is given and rejects an unsupported scale. Keeping the same tolerance
# means GAMESCALE_SCALE=1.7 goes on working, but the substitution is logged
# rather than silent — a program being handed a number should not change it
# without saying so.
SCALE_TOLERANCE = 0.1


def fail(message, code=1):
    print("gamescale: %s" % message, file=sys.stderr)
    raise SystemExit(code)


def connect():
    try:
        return Gio.DBusProxy.new_for_bus_sync(
            bus_type=Gio.BusType.SESSION,
            flags=Gio.DBusProxyFlags.NONE,
            info=None,
            name="org.gnome.Mutter.DisplayConfig",
            object_path="/org/gnome/Mutter/DisplayConfig",
            interface_name="org.gnome.Mutter.DisplayConfig",
            cancellable=None,
        )
    except Exception as exc:
        fail("cannot reach mutter: %s" % exc)


def current_state(proxy):
    try:
        reply = proxy.call_sync(
            method_name="GetCurrentState",
            parameters=None,
            flags=Gio.DBusCallFlags.NO_AUTO_START,
            timeout_msec=-1,
            cancellable=None,
        )
    except Exception as exc:
        fail("cannot read display state: %s" % exc)
    return reply.unpack()


def transform_name(value):
    name = TRANSFORM.get(value)
    if name is None:
        # A transform with no name is one the state file cannot carry, so the
        # layout could not be put back. Refuse to take it apart.
        fail("unknown transform %r" % value)
    return name


def emit(logical):
    for x, y, scale, transform, primary, monitors, _props in logical:
        print(
            "\t".join(
                [
                    ",".join(m[0] for m in monitors),
                    repr(scale),
                    "yes" if primary else "no",
                    str(x),
                    str(y),
                    transform_name(transform),
                ]
            )
        )


def modes_by_connector(monitors):
    """connector -> the mode to keep using, and the scales it supports."""
    found = {}
    for spec, modes, _props in monitors:
        current = preferred = None
        for mode in modes:
            if mode[6].get("is-current"):
                current = mode
            if mode[6].get("is-preferred"):
                preferred = mode
        mode = current or preferred
        if mode is None:
            continue
        found[spec[0]] = {"id": mode[0], "size": (mode[1], mode[2]),
                          "scales": list(mode[5])}
    return found


def parse_record(text):
    parts = text.split(";")
    if len(parts) != 6:
        fail("malformed record %r" % text)
    connectors, scale, primary, x, y, transform = parts
    if transform not in BY_NAME:
        fail("unknown transform %r" % transform)
    try:
        return {
            "connectors": connectors.split(","),
            "scale": float(scale),
            "primary": primary == "yes",
            "x": int(x),
            "y": int(y),
            "transform": BY_NAME[transform],
        }
    except ValueError:
        fail("malformed record %r" % text)


def snap_scale(scale, supported):
    """The supported scale to use, which mutter will accept as given."""
    best = None
    for candidate in supported:
        distance = abs(scale - candidate)
        if distance > SCALE_TOLERANCE:
            continue
        if best is None or distance < best[1]:
            best = (candidate, distance)
    if best is None:
        fail("scale %s is not supported by this monitor" % scale, 2)
    if best[0] != scale:
        print("gamescale: scale %s -> %r, the nearest supported"
              % (scale, best[0]), file=sys.stderr)
    return best[0]


def logical_size(record, mode, layout_mode):
    width, height = mode["size"]
    if record["transform"] in SWAPPED:
        width, height = height, width
    if layout_mode != LOGICAL_LAYOUT_MODE:
        return width, height
    # At scale 1 this is the mode itself, so the common case does no arithmetic
    # and cannot round. Only a fractional GAMESCALE_SCALE reaches the division.
    scale = record["scale"]
    return round(width / scale), round(height / scale)


def pack(records, modes, layout_mode):
    """Lay the monitors out edge to edge, preserving their existing order.

    Monitors sharing an x coordinate are a vertical stack; anything else is
    treated as a row. mutter requires logical monitors to tile exactly, so this
    is the arithmetic gdctl's --right-of would otherwise do.
    """
    vertical = len({r["x"] for r in records}) == 1
    ordered = sorted(records, key=lambda r: r["y"] if vertical else r["x"])
    offset = 0
    for record in ordered:
        mode = modes[record["connectors"][0]]
        width, height = logical_size(record, mode, layout_mode)
        record["x"], record["y"] = (0, offset) if vertical else (offset, 0)
        offset += height if vertical else width
    return ordered


def apply(proxy, serial, monitors, properties, records, method):
    modes = modes_by_connector(monitors)
    for record in records:
        for connector in record["connectors"]:
            if connector not in modes:
                fail("monitor %s is not connected" % connector, 2)
        record["scale"] = snap_scale(
            record["scale"], modes[record["connectors"][0]]["scales"]
        )

    layout_mode = properties.get("layout-mode", LOGICAL_LAYOUT_MODE)
    if "--pack" in sys.argv:
        records = pack(records, modes, layout_mode)

    logical = [
        (
            record["x"],
            record["y"],
            record["scale"],
            record["transform"],
            record["primary"],
            [(c, modes[c]["id"], {}) for c in record["connectors"]],
        )
        for record in records
    ]

    config_properties = {}
    if properties.get("supports-changing-layout-mode"):
        config_properties["layout-mode"] = GLib.Variant("u", layout_mode)

    try:
        proxy.call_sync(
            method_name="ApplyMonitorsConfig",
            parameters=GLib.Variant(
                "(uua(iiduba(ssa{sv}))a{sv})",
                (serial, method, logical, config_properties),
            ),
            flags=Gio.DBusCallFlags.NO_AUTO_START,
            timeout_msec=-1,
            cancellable=None,
        )
    except Exception as exc:
        # Includes a stale serial, which means the displays changed under us.
        fail("mutter rejected the configuration: %s" % exc, 2)


command = sys.argv[1] if len(sys.argv) > 1 else "read"
records = [parse_record(a) for a in sys.argv[2:] if not a.startswith("--")]

proxy = connect()
serial, monitors, logical, properties = current_state(proxy)

if command == "read":
    emit(logical)
elif command in ("verify", "apply"):
    if not records:
        fail("nothing to apply")
    # Verify first either way: it turns "we might strand your display" into a
    # question answered before anything moves.
    apply(proxy, serial, monitors, properties, records, VERIFY)
    if command == "apply":
        apply(proxy, serial, monitors, properties, records, TEMPORARY)
else:
    fail("unknown command %r" % command)
PY
}

detect() {
    local out
    out=$(display_config read) || return 1

    MON_CONNS=(); MON_SCALE=(); MON_PRIM=(); MON_X=(); MON_Y=(); MON_TRANSFORM=()
    while IFS=$'\t' read -r conns scale prim x y transform; do
        [[ -n "$conns" ]] || continue
        MON_CONNS+=("$conns");   MON_SCALE+=("$scale")
        MON_PRIM+=("$prim");     MON_X+=("$x")
        MON_Y+=("$y");           MON_TRANSFORM+=("$transform")
    done <<<"$out"

    [[ ${#MON_CONNS[@]} -gt 0 ]] || return 1
    local i
    for ((i = 0; i < ${#MON_CONNS[@]}; i++)); do
        log "mutter: ${MON_CONNS[i]} @ ${MON_SCALE[i]} (${MON_X[i]},${MON_Y[i]}) primary=${MON_PRIM[i]}"
    done
}

# Records for the current MON_* arrays into RECORDS, optionally overriding every
# scale. One format for reading, storing and applying.
records() {  # records [SCALE]
    local i scale
    RECORDS=()
    for ((i = 0; i < ${#MON_CONNS[@]}; i++)); do
        scale="${1:-${MON_SCALE[i]}}"
        RECORDS+=("${MON_CONNS[i]};$scale;${MON_PRIM[i]};${MON_X[i]};${MON_Y[i]};${MON_TRANSFORM[i]}")
    done
}

# The primary monitor's scale drives the font/cursor compensation, since that's
# the display you'll be reading the desktop on.
primary_index() {
    local i
    for ((i = 0; i < ${#MON_PRIM[@]}; i++)); do
        [[ "${MON_PRIM[i]}" == "yes" ]] && { echo "$i"; return 0; }
    done
    echo 0
}

# ---------------------------------------------------------------------------
# Settings access
# ---------------------------------------------------------------------------

get_setting() { host gsettings get "$IFACE_SCHEMA" "$1" 2>/dev/null | tr -d "'"; }
set_setting() { host gsettings set "$IFACE_SCHEMA" "$1" "$2"; }

# Apply the records in RECORDS. Every configuration is verified before it is
# applied, inside display_config, so a rejection costs nothing. Returns 2 when
# mutter refuses the configuration, which callers treat as "leave the display
# alone" rather than as a failure to report.
#
#   apply_records          replay coordinates as recorded  (restore)
#   apply_records --pack   lay them out edge to edge       (apply)
apply_records() {
    display_config apply "$@" "${RECORDS[@]}" 2>/dev/null
}

# ---------------------------------------------------------------------------
# State, written through the portal so it lands on the host filesystem where
# the watchdog, the login unit, and your shell can all reach it.
# ---------------------------------------------------------------------------

# Written to a sibling and renamed. Rename is atomic within a filesystem, so a
# reader sees either the whole old state or the whole new one — never a
# half-flushed line. Worth the extra syscall: a plain redirect is truncated by
# exactly the events this tool exists to survive (OOM kill, sandbox teardown,
# power loss), and a state file holding a truncated scale is worse than none.
# mutter rejects the bad value, every restore layer fails identically, and the
# retry logic then keeps you stranded at 1x instead of recovering.
state_write() {
    local text_scale="$1" cursor_size="$2" run="$3" i
    host mkdir -p "$STATE_DIR" 2>/dev/null
    printf '%s\n' "$run" | host sh -c "umask 077; cat > '$RUN_FILE'" || return 1
    {
        printf 'version=2\ntext_scale=%s\ncursor_size=%s\n' \
            "$text_scale" "$cursor_size"
        for ((i = 0; i < ${#MON_CONNS[@]}; i++)); do
            printf 'monitor=%s;%s;%s;%s;%s;%s\n' \
                "${MON_CONNS[i]}" "${MON_SCALE[i]}" "${MON_PRIM[i]}" \
                "${MON_X[i]}" "${MON_Y[i]}" "${MON_TRANSFORM[i]}"
        done
    } | host sh -c "umask 077; cat > '$STATE_FILE.new' \
                    && mv -f '$STATE_FILE.new' '$STATE_FILE'"
}

state_read()   { host cat "$STATE_FILE" 2>/dev/null; }
state_exists() { host test -r "$STATE_FILE"; }
state_clear()  { host rm -f "$STATE_FILE" "$RUN_FILE"; }
run_owner()    { host cat "$RUN_FILE" 2>/dev/null; }

is_number()    { [[ "$1" =~ ^[0-9]+(\.[0-9]+)?$ ]]; }
is_integer()   { [[ "$1" =~ ^[0-9]+$ ]]; }
is_token()     { [[ "$1" =~ ^[0-9A-Za-z-]+$ ]]; }
# Permissive enough for eDP-1, DP-2 and HDMI-A-1; strict enough that nothing
# reaching the display program can carry whitespace, quotes or metacharacters.
is_connector() { [[ "$1" =~ ^[A-Za-z0-9]+([-_][A-Za-z0-9]+)*$ ]]; }

# Strict key=value parse — deliberately NOT `source`. The state directory is
# writable by the sandboxed app we launch, and restore_now() also runs on the
# host from the login unit, where sourcing that file would execute its contents
# outside the sandbox at every session start. Unknown keys and malformed values
# fail closed rather than being ignored: a state file we don't fully understand
# is one we shouldn't replay onto your display.
#
# Assigns into the caller's locals (bash dynamic scope); leaves them untouched
# on failure.
#
# One `monitor=` line per logical monitor:
#   monitor=<connectors>;<scale>;<primary>;<x>;<y>;<transform>
# with connectors comma-separated for a mirrored logical monitor.
parse_monitor_record() {
    local -a f conns
    local conn
    IFS=';' read -ra f <<<"$1"
    [[ ${#f[@]} -eq 6 ]] || return 1

    IFS=',' read -ra conns <<<"${f[0]}"
    [[ ${#conns[@]} -gt 0 ]] || return 1
    for conn in "${conns[@]}"; do
        is_connector "$conn" || return 1
        # A connector may drive exactly one logical monitor. A duplicate — within
        # a record or across them — is a configuration mutter will always refuse,
        # so replaying it means retrying forever and never getting the desktop
        # back. Refusing it here leaves the file for a human instead.
        [[ "$SEEN_CONNS" == *" $conn "* ]] && return 1
        SEEN_CONNS="$SEEN_CONNS$conn "
    done

    is_number "${f[1]}" || return 1
    [[ "${f[2]}" == "yes" || "${f[2]}" == "no" ]] || return 1
    [[ "${f[3]}" =~ ^-?[0-9]+$ && "${f[4]}" =~ ^-?[0-9]+$ ]] || return 1
    [[ "${f[5]}" =~ ^(normal|90|180|270|flipped|flipped-90|flipped-180|flipped-270)$ ]] || return 1

    MON_CONNS+=("${f[0]}");  MON_SCALE+=("${f[1]}")
    MON_PRIM+=("${f[2]}");   MON_X+=("${f[3]}")
    MON_Y+=("${f[4]}");      MON_TRANSFORM+=("${f[5]}")
}

state_parse() {
    local blob line key value
    blob=$(state_read) || return 1
    [[ -n "$blob" ]] || return 1

    MON_CONNS=(); MON_SCALE=(); MON_PRIM=(); MON_X=(); MON_Y=(); MON_TRANSFORM=()
    text_scale=""; cursor_size=""
    SEEN_CONNS=" "

    while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        key="${line%%=*}"
        value="${line#*=}"
        [[ "$key" != "$line" ]] || return 1
        case "$key" in
            version)     [[ "$value" == "2" ]] || return 1 ;;
            monitor)     parse_monitor_record "$value" || return 1 ;;
            text_scale)  is_number    "$value" && text_scale="$value"  || return 1 ;;
            cursor_size) is_integer   "$value" && cursor_size="$value" || return 1 ;;
            # Which run wrote this. The watchdog compares it against its own
            # before restoring, so a watchdog still finishing its grace period
            # cannot act on the NEXT game's state file.
            # Written by 1.4.0 only. Accepted so its state files still restore;
            # the token lives in a sibling file now.
            run)         is_token     "$value"                        || return 1 ;;
            *) return 1 ;;
        esac
    done <<<"$blob"

    [[ ${#MON_CONNS[@]} -gt 0 ]]
}

# Idempotent: safe to call from the trap, the watchdog, and the login unit,
# in any order or all at once. First one to finish clears the state.
# Drops saved monitors that aren't currently connected and lets mutter place
# what's left. Unplugging a display while the game runs would otherwise make
# the saved layout unreplayable, and a state file that can never be applied is
# a desktop permanently stuck at 1x.
restore_survivors() {
    local -a s_conns=("${MON_CONNS[@]}")     s_scale=("${MON_SCALE[@]}") \
             s_prim=("${MON_PRIM[@]}")       s_x=("${MON_X[@]}") \
             s_y=("${MON_Y[@]}")             s_tr=("${MON_TRANSFORM[@]}")
    local present i conn kept has_primary=0
    local -a conns

    detect || return 1
    present=" ${MON_CONNS[*]//,/ } "

    MON_CONNS=(); MON_SCALE=(); MON_PRIM=(); MON_X=(); MON_Y=(); MON_TRANSFORM=()
    for ((i = 0; i < ${#s_conns[@]}; i++)); do
        # Per connector, not per record. A mirrored logical monitor lists
        # several, and a configuration is refused if ANY of them is absent — so
        # testing only the first kept sending back the very record that had just
        # been rejected, failing identically on every retry and leaving the
        # desktop at 1x for good.
        IFS=',' read -ra conns <<<"${s_conns[i]}"
        kept=""
        for conn in "${conns[@]}"; do
            if [[ "$present" == *" $conn "* ]]; then
                kept="${kept:+$kept,}$conn"
            else
                log "dropping absent $conn"
            fi
        done
        [[ -n "$kept" ]] || continue
        MON_CONNS+=("$kept");         MON_SCALE+=("${s_scale[i]}")
        MON_PRIM+=("${s_prim[i]}");   MON_X+=("${s_x[i]}")
        MON_Y+=("${s_y[i]}");         MON_TRANSFORM+=("${s_tr[i]}")
        [[ "${s_prim[i]}" == "yes" ]] && has_primary=1
    done

    [[ ${#MON_CONNS[@]} -gt 0 ]] || return 1
    [[ $has_primary == 1 ]] || MON_PRIM[0]="yes"

    # Repacked, not replayed: the saved coordinates assumed a monitor that is
    # no longer there, so they no longer tile.
    records
    apply_records --pack
}

restore_now() {
    local text_scale="" cursor_size=""
    state_exists || return 1
    if ! state_parse; then
        warn "state at $STATE_FILE is malformed — refusing to replay it"
        warn "recover by hand in Settings > Displays, or with gdctl if you"
        warn "have it:  gdctl set --logical-monitor --primary \\"
        warn "              --monitor <connector> --scale <scale>"
        return 1
    fi

    log "restoring ${#MON_CONNS[@]} monitor(s) (text $text_scale, cursor $cursor_size)"
    records
    if ! apply_records; then
        log "saved layout was rejected; retrying with connected monitors only"
        if ! restore_survivors; then
            warn "FAILED to restore display configuration — state kept for retry"
            return 1
        fi
    fi
    # Clearing state after a partial restore is how a compensated font size
    # becomes the next run's "original": the scale comes back, the font
    # silently doesn't, the state file is deleted, and nothing remembers what
    # the pristine value was. Keep the state and let another layer retry.
    local failed=0
    [[ -n "$text_scale"  ]] && { set_setting text-scaling-factor "$text_scale" || failed=1; }
    [[ -n "$cursor_size" ]] && { set_setting cursor-size "$cursor_size"        || failed=1; }
    if [[ $failed == 1 ]]; then
        warn "restored scale but not font/cursor — state kept for retry"
        return 1
    fi

    state_clear
    return 0
}

# ---------------------------------------------------------------------------
# Modes that don't need the full dependency set
# ---------------------------------------------------------------------------

if [[ "$MODE" == "install" ]]; then
    unit_dir="${HOST_HOME}/.config/systemd/user"
    host mkdir -p "$unit_dir"
    printf '%s\n' \
        '[Unit]' \
        'Description=Restore display scale left over by gamescale' \
        'After=graphical-session.target' \
        'PartOf=graphical-session.target' \
        '' \
        '[Service]' \
        'Type=oneshot' \
        "ExecStart=${SELF} --restore" \
        'SuccessExitStatus=0 1' \
        '' \
        '[Install]' \
        'WantedBy=graphical-session.target' \
        | host sh -c "cat > '$unit_dir/gamescale-reconcile.service'"
    host systemctl --user daemon-reload
    host systemctl --user enable gamescale-reconcile.service
    echo "installed and enabled gamescale-reconcile.service"
    exit 0
fi

if [[ "$MODE" == "restore" ]]; then
    if ! state_exists; then
        warn "no saved state at $STATE_FILE — nothing to restore."
        warn "If your display is still wrong, set it in Settings > Displays;"
        warn "gamescale has no record of what it was."
        exit 1
    fi
    restore_now && echo "restored" && exit 0
    exit 1
fi

# The watchdog runs ON THE HOST (systemd started it), so HOST is empty here and
# every helper above talks directly to the session. It blocks on the lock the
# game process holds; the kernel drops that lock when the process dies, however
# it dies. Acquiring it means the game is gone.
if [[ "$MODE" == "watchdog" ]]; then
    WATCH_RUN="${1:-}"
    log "watchdog for run ${WATCH_RUN:-unknown} waiting on $LOCK_FILE"
    exec 9>>"$LOCK_FILE" || exit 1
    if ! flock -w "$WATCHDOG_TIMEOUT" -x 9; then
        # The game outlived the ceiling — it is STILL RUNNING. Restoring here
        # would yank the desktop back under it, which is the one thing this
        # whole design exists to avoid, and would clear the state so the real
        # exit had nothing left to put back. Give up instead; the trap and the
        # login unit still cover it.
        warn "watchdog gave up after ${WATCHDOG_TIMEOUT}s with the game still"
        warn "running; leaving the display and the state file alone"
        exit 1
    fi
    # Small grace period so the in-sandbox trap gets first crack at it.
    sleep 2
    if state_exists; then
        # The lock is free and a state file exists — but during the grace period
        # above, the next game may already have started and written its own.
        # Restoring that one would revert a running game and delete the record
        # it depends on, so act only on state this watchdog was started for.
        owner=$(run_owner)
        if [[ -n "$WATCH_RUN" && -n "$owner" && "$owner" != "$WATCH_RUN" ]]; then
            log "state belongs to run $owner, not $WATCH_RUN; leaving it alone"
            exit 0
        fi
        warn "game exited without restoring; watchdog cleaning up"
        restore_now
    else
        log "state already cleared, nothing to do"
    fi
    exit 0
fi

# ---------------------------------------------------------------------------
# Dependency checks (run/status/doctor)
# ---------------------------------------------------------------------------

# python3 reads and applies the display configuration over D-Bus; gsettings
# carries the font/cursor compensation. gdctl is deliberately NOT required: it
# only arrived in Mutter 48, while the D-Bus interface it wraps is years older,
# so not needing it is what lets this run on GNOME releases that never shipped
# it.
MISSING=()
for cmd in gsettings python3; do
    have_host "$cmd" || MISSING+=("$cmd")
done

CAN_WATCH=1
have_host systemd-run || CAN_WATCH=0
command -v flock >/dev/null 2>&1 || CAN_WATCH=0

if [[ "$MODE" == "doctor" ]]; then
    DOCTOR_BAD=0
    ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; }
    bad()  { printf '  \033[31m✗\033[0m %s\n' "$1"; DOCTOR_BAD=$((DOCTOR_BAD + 1)); }
    # A second line about the SAME failure. Calling bad() twice inflated the
    # count, and the count is what the exit status and the summary report.
    more() { printf '    %s\n' "$1"; }
    echo "gamescale $VERSION doctor"
    echo
    if [[ $IN_FLATPAK == 1 ]]; then
        ok "running sandboxed (flatpak-spawn present)"
    else
        ok "running on the host"
    fi
    if [[ ${#MISSING[@]} -eq 0 ]]; then
        ok "gsettings + python3 reachable"
    else
        bad "unreachable: ${MISSING[*]}  →  needs --talk-name=org.freedesktop.Flatpak"
    fi
    # A python3 without PyGObject passes `command -v` and then fails at the
    # first import, so check the import rather than the interpreter.
    if host python3 -c 'import gi; gi.require_version("Gio", "2.0")' 2>/dev/null; then
        ok "PyGObject present (reads mutter's display state)"
    else
        bad "python3 cannot import gi  →  install python3-gobject-base"
    fi
    host mkdir -p "$STATE_DIR" 2>/dev/null
    if host sh -c "touch '$STATE_DIR/.probe' && rm -f '$STATE_DIR/.probe'" 2>/dev/null; then
        ok "state dir writable: $STATE_DIR"
    else
        bad "state dir NOT writable: $STATE_DIR  →  needs --filesystem=...:create"
    fi
    if [[ -w "$STATE_DIR" ]]; then
        ok "state dir writable from this side too"
    else
        bad "state dir not directly writable here (watchdog lock needs this)"
    fi
    if [[ $CAN_WATCH == 1 ]]; then
        ok "watchdog available (systemd-run + flock)"
    else
        bad "watchdog unavailable — trap-only, less resilient"
    fi
    # Bare-name invocation from the Steam launch options box rides on an
    # --env=PATH override, which REPLACES the sandbox PATH rather than
    # extending it — so a Steam update that adds a directory would be dropped.
    if [[ $IN_FLATPAK == 1 ]]; then
        case ":$PATH:" in
            *":${SELF%/*}:"*) ok "on the sandbox PATH — 'gamescale %command%' works" ;;
            *) bad "${SELF%/*} not on sandbox PATH  →  needs --env=PATH=...:\$HOME/.local/bin" ;;
        esac
        for d in /app/bin /app/utils/bin /usr/bin; do
            case ":$PATH:" in
                *":$d:"*) ;;
                *) bad "sandbox PATH lost $d — stale --env=PATH override, re-apply it" ;;
            esac
        done
    fi
    if detect; then
        for ((i = 0; i < ${#MON_CONNS[@]}; i++)); do
            ok "detected ${MON_CONNS[i]} @ ${MON_SCALE[i]}$([[ ${MON_PRIM[i]} == yes ]] && echo ' (primary)')"
        done
        # Ask mutter whether the configuration this would apply is acceptable,
        # which is the only check here that exercises the arithmetic. Every
        # monitor has to reach 1x before XWayland's global integer factor drops,
        # so a second display is not a detail that can be skipped either.
        records "$GAME_SCALE"
        if display_config verify --pack "${RECORDS[@]}" 2>/dev/null; then
            ok "the ${GAME_SCALE}x layout for ${#MON_CONNS[@]} monitor(s) verifies"
        else
            bad "mutter rejects the ${GAME_SCALE}x layout for ${#MON_CONNS[@]} monitor(s)"
            more "games will launch unmodified rather than risk your layout"
        fi
    else
        bad "detection failed"
    fi
    if state_exists; then
        bad "stale state present — run --restore"
    else
        ok "no stale state"
    fi
    # Installing is four independent steps and nothing makes them atomic, so a
    # run that died halfway leaves exactly this: some checks green, some red.
    # Re-running the installer is idempotent and fixes every one of them.
    if [[ $DOCTOR_BAD -gt 0 ]]; then
        echo
        echo "  $DOCTOR_BAD check(s) failed. The installer is idempotent — re-running it"
        echo "  fixes everything above except a stale state file:"
        echo "    curl -fsSL https://raw.githubusercontent.com/proto-cool/gamescale/main/install.sh | sh"
        exit 1
    fi
    exit 0
fi

if [[ ${#MISSING[@]} -gt 0 && "$MODE" != "status" ]]; then
    give_up "cannot reach ${MISSING[*]} on the host (--talk-name=org.freedesktop.Flatpak?)" "$@"
fi

if [[ "$MODE" == "status" ]]; then
    echo "version:      $VERSION"
    echo "sandboxed:    $([[ $IN_FLATPAK == 1 ]] && echo yes || echo no)"
    if [[ ${#MISSING[@]} -gt 0 ]]; then
        echo "host access:  MISSING ${MISSING[*]}"
        exit 1
    fi
    echo "host access:  ok"
    echo "watchdog:     $([[ $CAN_WATCH == 1 ]] && echo available || echo UNAVAILABLE)"
    echo "state dir:    $STATE_DIR"
    if detect; then
        for ((i = 0; i < ${#MON_CONNS[@]}; i++)); do
            printf 'monitor:      %-12s scale %-20s %s%s\n' \
                "${MON_CONNS[i]}" "${MON_SCALE[i]}" \
                "at (${MON_X[i]},${MON_Y[i]})" \
                "$([[ ${MON_PRIM[i]} == yes ]] && echo ' primary')"
        done
    else
        echo "monitor:      DETECTION FAILED"; exit 1
    fi
    echo "text scaling: $(get_setting text-scaling-factor)"
    echo "cursor size:  $(get_setting cursor-size)"
    state_exists && echo "stale state:  yes — run --restore"
    exit 0
fi

# ---------------------------------------------------------------------------
# Run mode
# ---------------------------------------------------------------------------

[[ $# -gt 0 ]] || { warn "no command given"; exit 2; }

# Identifies this run in the state file and in the watchdog's unit name. The
# watchdog checks it before restoring, so a watchdog left over from the previous
# game cannot act on this run's state — and two runs cannot collide on a unit
# name, which $$ alone did, since the sandbox's PID namespace restarts low.
RUN_ID="$$-${RANDOM}${RANDOM}"

# The lock comes first, before the state file is touched. It is both the handle
# the watchdog waits on and the guard against two runs fighting over one
# display: whoever holds it owns the display state until it exits. The short
# wait absorbs the previous watchdog's grace period rather than failing during
# it. FD 9 is inherited by the game, and the kernel holds the lock until every
# process holding that descriptor is gone.
HAVE_LOCK=0
host mkdir -p "$STATE_DIR" 2>/dev/null
if command -v flock >/dev/null 2>&1; then
    if exec 9>>"$LOCK_FILE" && flock -w 5 -x 9; then
        HAVE_LOCK=1
    else
        give_up "another gamescale holds $LOCK_FILE; launching unmodified rather than taking its display out from under it" "$@"
    fi
fi

# Leftover state means something died without restoring. Put it back before
# detecting, so we never record 1x as the "original" and strand you there.
if state_exists; then
    warn "state left over from a previous run; restoring before starting"
    # Not a warning to shrug off. restore_now also returns non-zero when the
    # scale came back but the font and cursor did not, and the values sitting in
    # gsettings right now would then be a previous run's COMPENSATED sizes.
    # Recording those as this run's original compounds them on every launch.
    if ! restore_now; then
        give_up "leftover restore failed; not scaling, because the current font and cursor sizes may be a previous run's compensated values" "$@"
    fi
fi

detect || give_up "could not determine monitor/scale" "$@"

# XWayland's scale factor is global: it only drops to 1 once EVERY logical
# monitor is at 1x. Leaving one at a fractional scale keeps the factor at 2 and
# then applies it to a full-resolution logical size, which costs more pixels
# than never having run — so "already done" means all of them, not just the one
# you play on.
ALREADY=1
for scale in "${MON_SCALE[@]}"; do
    feq "$scale" "$GAME_SCALE" || { ALREADY=0; break; }
done
if [[ $ALREADY == 1 ]]; then
    log "every monitor already at $GAME_SCALE, nothing to do"
    [[ $HAVE_LOCK == 1 ]] && exec 9>&-
    exec "$@"
fi

PRIMARY=$(primary_index)
ORIG_SCALE="${MON_SCALE[PRIMARY]}"
ORIG_TEXT_SCALE=$(get_setting text-scaling-factor); : "${ORIG_TEXT_SCALE:=1.0}"
ORIG_CURSOR_SIZE=$(get_setting cursor-size);        : "${ORIG_CURSOR_SIZE:=24}"

# The one write whose failure would strand you: the display is about to move,
# and this file is the only record of where it was. Everything else here fails
# closed, so this cannot be the one path that shrugs.
if ! state_write "$ORIG_TEXT_SCALE" "$ORIG_CURSOR_SIZE" "$RUN_ID"; then
    give_up "could not write $STATE_FILE; not scaling, because nothing would know how to put your display back" "$@"
fi

# Layer 2. The lock is already held from above, which is what makes this safe:
# there is no window in which the watchdog could acquire it and restore
# immediately.
if [[ "${GAMESCALE_NO_WATCH:-0}" != "1" && $CAN_WATCH == 1 && $HAVE_LOCK == 1 ]]; then
    if host systemd-run --user --collect --quiet \
            --unit="gamescale-watchdog-$RUN_ID" \
            "$SELF" --watchdog "$RUN_ID"; then
        log "watchdog started"
    else
        warn "could not start watchdog; falling back to trap-only"
    fi
fi

# Layer 1.
cleanup() {
    trap - EXIT INT TERM
    restore_now
}
trap cleanup EXIT INT TERM

records "$GAME_SCALE"
apply_records --pack; APPLY_RC=$?
if [[ $APPLY_RC -ne 0 ]]; then
    if [[ $APPLY_RC == 2 ]]; then
        warn "mutter rejected the ${GAME_SCALE}x layout for ${#MON_CONNS[@]} monitor(s);"
        warn "launching unmodified rather than risking your display arrangement"
    else
        warn "could not apply the ${GAME_SCALE}x layout"
    fi
    state_clear
    exec "$@"
fi

# Poor man's fractional scaling: the desktop just lost the primary monitor's
# scale worth of apparent size, so scale text and cursor to match. Title bars
# and icons won't follow — that's a GNOME limitation, not a bug here.
if [[ "${GAMESCALE_NO_FONT:-0}" != "1" ]]; then
    RATIO=$(fdiv "$ORIG_SCALE" "$GAME_SCALE")
    set_setting text-scaling-factor "$(fmul "$ORIG_TEXT_SCALE" "$RATIO")"
    set_setting cursor-size "$(fround "$(fmul "$ORIG_CURSOR_SIZE" "$RATIO")")"
    log "compensated ${RATIO}x"
fi

# Let mutter settle before the game enumerates outputs.
sleep 1

"$@"
