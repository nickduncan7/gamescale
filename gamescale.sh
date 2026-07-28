#!/usr/bin/env bash
#
# gamescale — run a game at 1x monitor scale so XWayland hands it the panel's
# real mode instead of an overscaled framebuffer, compensating desktop font and
# cursor size so alt-tabbing stays usable. Restores on exit.
#
# Restoring cannot be owned by anything that dies with the game — the Steam
# flatpak's portal connection dies with the sandbox — so three independent
# layers each suffice: the in-sandbox EXIT trap; a host-side watchdog blocking
# on an flock the game's process holds, which the kernel releases however the
# game dies; and `--restore` at login. State lives on the host filesystem so
# all three layers, and you, see the same file.
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
#   gamescale --doctor          verify every moving part
#   gamescale --install-unit    install the login reconcile service
#   gamescale --version         print the installed version
#
#   Steam launch option:  gamescale %command%
#
# FLAGS
#
#   Wrapper behaviour:
#     -x, --no-scale        env-only: export, exec, touch nothing else
#     -f, --no-font         same as GAMESCALE_NO_FONT=1
#     -s, --scale FACTOR    same as GAMESCALE_SCALE=FACTOR
#
#   Environment shorthands, each DEFINED as an alias of -e. None changes how,
#   or whether, anything is scaled. On stock Valve Proton -w and -n are
#   currently inert (see --doctor); GE-Proton and proton-cachyos honour them.
#   When a name rots, `-e THE_RIGHT_NAME=1` works with no release.
#     -w, --env-wayland     -e PROTON_ENABLE_WAYLAND=1
#     -n, --env-ntsync      -e PROTON_USE_NTSYNC=1
#     -m, --env-mangohud    -e MANGOHUD=1
#     -e, --env KEY=VAL     export KEY=VAL into the launched command; repeatable
#
#   Short flags combine (-wn, -xm). Parsing stops at the first non-flag
#   argument or at --, so both forms work:
#
#     gamescale [flags] %command%
#     gamescale [flags] -- /path/to/game
#
#   The prefix form, PROTON_ENABLE_WAYLAND=1 gamescale %command%, keeps
#   working; nothing here replaces it.
#
# PER-GAME DEFAULTS
#
#   ~/.local/state/gamescale/games.conf:
#
#     1817070 = wn                  # letters are the flag letters above
#     620     = w, MANGOHUD=1       # anything value-carrying is written out
#     22380   = x                   # env-only
#
#   Consulted only when SteamAppId is in the environment AND the command line
#   carries no flags at all; any explicit flag disables the lookup for that
#   launch — all or nothing, never a per-key merge. Precedence for any
#   variable: explicit flags > games.conf > inherited environment. Every
#   export is echoed at launch with its source.
#
#     gamescale --set-game 1817070 wn      write an entry
#     gamescale --set-game 1817070 -       remove one
#     gamescale --status 1817070           what that game would get
#
# ENV
#   GAMESCALE_SCALE     scale while playing        (default: 1)
#   GAMESCALE_NO_FONT   1 to skip font/cursor compensation
#   GAMESCALE_NO_WATCH  1 to skip the host watchdog (trap only)
#   GAMESCALE_DEBUG     1 for verbose logging

set -uo pipefail

# The script is copied to ~/.local/bin, so nothing else on the system records
# which release it came from. Release CI refuses a tag that disagrees.
readonly VERSION="1.7.2"

readonly IFACE_SCHEMA="org.gnome.desktop.interface"
# 12h ceiling. On reaching it the watchdog gives up WITHOUT restoring — a game
# still holding the lock is a game still running. Overridable for tests.
readonly WATCHDOG_TIMEOUT="${GAMESCALE_WATCHDOG_TIMEOUT:-43200}"
GAME_SCALE="${GAMESCALE_SCALE:-1}"

# Absolute path to this script. The watchdog and the login unit re-invoke it
# from the host; granted directories mount at the same absolute path inside
# the sandbox, so one resolved path is valid on both sides.
SELF="$0"
[[ "$SELF" == */* ]] || SELF=$(command -v -- "$SELF" 2>/dev/null || printf '%s' "$SELF")
SELF=$(readlink -f -- "$SELF" 2>/dev/null || printf '%s' "$SELF")
readonly SELF

log()  { [[ "${GAMESCALE_DEBUG:-0}" == "1" ]] && echo "gamescale: $*" >&2; return 0; }
warn() { echo "gamescale: $*" >&2; }

# One definition of "well formed" per shape, shared by every parser.
is_number()    { [[ "$1" =~ ^[0-9]+(\.[0-9]+)?$ ]]; }
is_integer()   { [[ "$1" =~ ^[0-9]+$ ]]; }
is_token()     { [[ "$1" =~ ^[0-9A-Za-z-]+$ ]]; }
# Permissive enough for eDP-1, DP-2 and HDMI-A-1; strict enough that nothing
# reaching the display program carries whitespace, quotes or metacharacters.
is_connector() { [[ "$1" =~ ^[A-Za-z0-9]+([-_][A-Za-z0-9]+)*$ ]]; }
# POSIX variable name. VAL is deliberately unconstrained — passed through byte
# for byte — but the name is exported, so it has to be a name.
is_env_key()   { [[ "$1" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; }

trim() {
    local s="$1"
    s="${s#"${s%%[![:space:]]*}"}"
    printf '%s' "${s%"${s##*[![:space:]]}"}"
}

# ---------------------------------------------------------------------------
# Mode parsing first — bail-out behaviour depends on whether there's a game to
# hand off to, so nothing below may exit before we know the mode.
# ---------------------------------------------------------------------------

MODE="run"
STATUS_APPID=""
SET_GAME_APPID=""
SET_GAME_ENTRY=""
case "${1:-}" in
    --status)       MODE="status";   shift
                    if [[ $# -gt 0 ]]; then STATUS_APPID="$1"; shift; fi ;;
    --restore)      MODE="restore";  shift ;;
    --watchdog)     MODE="watchdog"; shift ;;
    --doctor)       MODE="doctor";   shift ;;
    --install-unit) MODE="install";  shift ;;
    --set-game)     MODE="setgame";  shift
                    SET_GAME_APPID="${1:-}"; [[ $# -gt 0 ]] && shift
                    SET_GAME_ENTRY="${1:-}"; [[ $# -gt 0 ]] && shift ;;
    # Answered before any dependency check, so it works on a broken install.
    --version|-V)   printf 'gamescale %s\n' "$VERSION"; exit 0 ;;
    --help|-h)      awk 'NR > 1 { if ($0 !~ /^#/) exit; sub(/^# ?/, ""); print }' \
                        "$SELF"; exit 0 ;;
esac

# ---------------------------------------------------------------------------
# Run-mode flags. Everything the parser learns lands in the same places the
# games.conf parser fills; flags fill them first and disable the lookup.
# ---------------------------------------------------------------------------

NO_SCALE=0
NO_FONT=0; [[ "${GAMESCALE_NO_FONT:-0}" == "1" ]] && NO_FONT=1
# Whether the command line said anything at all. This, not the individual
# flags, is what turns the games.conf lookup off.
EXPLICIT=0
# Set when -x is paired with a scale option; warned about once after parsing.
SAW_SCALE_OPT=0
USAGE_ERROR=0

# Parallel arrays: the variable, its value, and the flag or file that asked
# for it — every export is echoed with its origin.
ENV_KEYS=(); ENV_VALS=(); ENV_SRCS=()

# Records KEY=VAL from SOURCE. Last writer wins.
add_env() {  # add_env KEY=VAL SOURCE
    local pair="$1" src="$2" key val i
    key="${pair%%=*}"
    if [[ "$pair" != *=* ]] || ! is_env_key "$key"; then
        # A usage error, and usage errors do not fail a game launch.
        warn "not a valid KEY=VAL assignment: $pair"
        USAGE_ERROR=1
        return 1
    fi
    val="${pair#*=}"
    for ((i = 0; i < ${#ENV_KEYS[@]}; i++)); do
        if [[ "${ENV_KEYS[i]}" == "$key" ]]; then
            ENV_VALS[i]="$val"; ENV_SRCS[i]="$src"; return 0
        fi
    done
    ENV_KEYS+=("$key"); ENV_VALS+=("$val"); ENV_SRCS+=("$src")
}

# The expansion table: the only place a variable name is written down, read by
# the flag parser, the games.conf parser, --doctor and --status. These names
# rot — Proton renames variables and flips defaults — and when a row goes
# stale the user's recovery is `-e CORRECT_NAME=1`, no release needed, which
# is why the letters are defined as -e aliases rather than as features.
declare -A LETTER_EXPANDS=(
    # GE-Proton and proton-cachyos ship winewayland.drv and honour this; stock
    # Valve Proton ships no wayland driver, so there -w changes nothing.
    [w]="PROTON_ENABLE_WAYLAND=1"
    # Inert on stock Proton 11: ntsync is on by default there and only
    # PROTON_NO_NTSYNC exists. Kept as the enabling spelling older Proton and
    # the GE builds take.
    [n]="PROTON_USE_NTSYNC=1"
    # MangoHud's own switch, works on every build.
    [m]="MANGOHUD=1"
)

letter_env() {  # letter_env LETTER  ->  KEY=VAL on stdout, or 1
    [[ -n "${LETTER_EXPANDS[$1]:-}" ]] || return 1
    printf '%s' "${LETTER_EXPANDS[$1]}"
}

is_letter() { [[ "$1" == [wnmxf] ]]; }

apply_letter() {  # apply_letter LETTER SOURCE
    local pair
    case "$1" in
        x) NO_SCALE=1 ;;
        f) NO_FONT=1; SAW_SCALE_OPT=1 ;;
        *) pair=$(letter_env "$1") || return 1
           add_env "$pair" "$2" ;;
    esac
}

# Number of leading arguments the flag parser consumed, for the caller to shift.
FLAGS_CONSUMED=0

parse_flags() {
    local n=0 arg letters i ch value
    while [[ $# -gt 0 ]]; do
        arg="$1"
        case "$arg" in
            --) n=$((n + 1)); break ;;
            --no-scale)   NO_SCALE=1; EXPLICIT=1 ;;
            --no-font)    NO_FONT=1; SAW_SCALE_OPT=1; EXPLICIT=1 ;;
            --scale)      SAW_SCALE_OPT=1; EXPLICIT=1
                          if [[ $# -ge 2 ]]; then
                              GAME_SCALE="$2"; n=$((n + 1)); shift
                          else
                              warn "--scale needs a value"; USAGE_ERROR=1
                          fi ;;
            --scale=*)    GAME_SCALE="${arg#*=}"; SAW_SCALE_OPT=1; EXPLICIT=1 ;;
            --env-wayland)  apply_letter w --env-wayland;  EXPLICIT=1 ;;
            --env-ntsync)   apply_letter n --env-ntsync;   EXPLICIT=1 ;;
            --env-mangohud) apply_letter m --env-mangohud; EXPLICIT=1 ;;
            --env)        EXPLICIT=1
                          if [[ $# -ge 2 ]]; then
                              add_env "$2" --env; n=$((n + 1)); shift
                          else
                              warn "--env needs KEY=VAL"; USAGE_ERROR=1
                          fi ;;
            --env=*)      add_env "${arg#*=}" --env; EXPLICIT=1 ;;
            # A long flag we don't know is a typo, not a game.
            --*)          warn "unknown option: $arg"; warn "try --help"
                          FLAGS_CONSUMED=-1; return 0 ;;
            # A short cluster: -wn is -w -n, and the two value-taking letters
            # take the rest of the cluster or the next argument, so -s1.5,
            # -s 1.5, -ws1.5 and -e FOO=1 all parse.
            -?*)          letters="${arg#-}"
                          for ((i = 0; i < ${#letters}; i++)); do
                              ch="${letters:i:1}"
                              EXPLICIT=1
                              case "$ch" in
                                  s|e) value="${letters:i+1}"
                                       if [[ -z "$value" ]]; then
                                           if [[ $# -ge 2 ]]; then
                                               value="$2"; n=$((n + 1)); shift
                                           else
                                               warn "-$ch needs a value"
                                               USAGE_ERROR=1
                                               break
                                           fi
                                       fi
                                       if [[ "$ch" == s ]]; then
                                           GAME_SCALE="$value"; SAW_SCALE_OPT=1
                                       else
                                           add_env "$value" -e
                                       fi
                                       i=${#letters} ;;
                                  *) if is_letter "$ch"; then
                                         apply_letter "$ch" "-$ch"
                                     else
                                         warn "unknown option: -$ch"
                                         warn "try --help"
                                         FLAGS_CONSUMED=-1; return 0
                                     fi ;;
                              esac
                          done ;;
            # The first non-flag argument is the command. A lone "-" is a
            # command name, not a flag.
            *)            break ;;
        esac
        n=$((n + 1)); shift
    done
    FLAGS_CONSUMED=$n
}

if [[ "$MODE" == "run" ]]; then
    parse_flags "$@"
    # An unknown flag is unrecoverable: we can't know whether it takes a
    # value, so we can't know which of the remaining arguments is the game.
    if [[ $FLAGS_CONSUMED -lt 0 ]]; then
        exit 2
    fi
    shift "$FLAGS_CONSUMED"
    # Every other flag error still launches the game: a typo in a launch
    # options box must not be the reason a title won't start.
    if [[ $USAGE_ERROR == 1 ]]; then
        warn "usage error; launching unmodified"
        [[ $# -gt 0 ]] && exec "$@"
        exit 2
    fi
    if [[ $NO_SCALE == 1 && $SAW_SCALE_OPT == 1 ]]; then
        warn "-x is env-only, so -s/-f configure a scale change that will not"
        warn "happen; proceeding env-only"
    fi
fi

# Give up on scaling but still start the game, if there is one.
give_up() {
    local msg="$1"; shift
    warn "$msg"
    # Drop the lock first, so a run that gave up doesn't hold the next launch
    # off for the lifetime of the game it is about to exec.
    [[ "${HAVE_LOCK:-0}" == 1 ]] && exec 9>&-
    [[ "$MODE" == "run" && $# -gt 0 ]] && exec "$@"
    exit 1
}

# ---------------------------------------------------------------------------
# Host plumbing. Inside the Steam flatpak, gdctl/gsettings/systemd-run all
# live on the host and need the org.freedesktop.Flatpak portal to reach.
# ---------------------------------------------------------------------------

# Overridable purely so tests can drive the sandboxed branch.
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

host()      { "${HOST[@]}" "$@"; }
# shellcheck disable=SC2016  # "$1" expands in the host-side sh, not here
have_host() { host sh -c 'command -v -- "$1" >/dev/null 2>&1' sh "$1"; }

# Host-side $HOME, deliberately unexpanded here: granted directories mount at
# the same absolute path inside the sandbox, so one value serves both sides.
# shellcheck disable=SC2016
HOST_HOME=$(host sh -c 'printf "%s" "$HOME"' 2>/dev/null)
[[ -n "$HOST_HOME" ]] || HOST_HOME="$HOME"

readonly STATE_DIR="${HOST_HOME}/.local/state/gamescale"
readonly STATE_FILE="${STATE_DIR}/state"
readonly LOCK_FILE="${STATE_DIR}/lock"
# The run token lives beside the state, not inside it: older copies parse the
# state format strictly, and --install-unit bakes an absolute path, so an old
# script can meet a new state file. A sibling file is invisible to it.
readonly RUN_FILE="${STATE_DIR}/run"
readonly GAMES_FILE="${STATE_DIR}/games.conf"
readonly LASTRUN_PREFIX="${STATE_DIR}/lastrun-"

# Overridable so --doctor's ntsync branch is reachable from a test.
readonly NTSYNC_DEV="${GAMESCALE_NTSYNC_DEV:-/dev/ntsync}"

# Float helpers — awk, not bc, because awk is always present.
fmul()   { awk -v a="$1" -v b="$2" 'BEGIN { printf "%.6g", a * b }'; }
fdiv()   { awk -v a="$1" -v b="$2" 'BEGIN { printf "%.6g", a / b }'; }
fround() { awk -v a="$1" 'BEGIN { printf "%d", (a < 0 ? a - 0.5 : a + 0.5) }'; }
feq()    { awk -v a="$1" -v b="$2" 'BEGIN { exit !(a - b < 1e-9 && b - a < 1e-9) }'; }

# ---------------------------------------------------------------------------
# Detection and application, over org.gnome.Mutter.DisplayConfig — the
# interface gdctl itself wraps, but years older than the gdctl CLI, so this
# runs on GNOME releases that never shipped it.
#
# EVERY logical monitor is captured, not just the primary: the XWayland scale
# factor is global and only drops to 1 when every monitor is at 1.0. Scaling
# the primary alone keeps the factor at 2 and costs MORE pixels than doing
# nothing. And a configuration replaces the whole layout, so a monitor left
# out of it is a monitor switched off — everything detected must be replayed.
#
# Scales are stored and replayed verbatim: Python's repr of a double is its
# shortest round-tripping form, so 1.3333333730697632 survives without any
# number ever being parsed out of text.
# ---------------------------------------------------------------------------

# Parallel arrays, one entry per logical monitor. MON_CONNS holds a
# comma-separated list because a mirrored logical monitor drives several.
MON_CONNS=(); MON_SCALE=(); MON_PRIM=(); MON_X=(); MON_Y=(); MON_TRANSFORM=()

# Everything that touches the display goes through this one program, run on
# the host. Records are the shape the state file uses:
#
#   <connectors>;<scale>;<primary>;<x>;<y>;<transform>
#
#   display_config read                 print one TSV record per logical monitor
#   display_config verify [--pack] REC  would mutter accept this?
#   display_config apply  [--pack] REC  verify, then apply
#
# --pack ignores the x/y in the records and lays the monitors out edge to edge
# (what applying needs: at a new scale the old coordinates no longer tile).
# Without it coordinates are used as given (what restoring needs).
#
# Exit status: 0 applied, 2 mutter rejected the configuration, 1 anything else.
#
# The body between <<'PY' and PY is extracted verbatim by test/detect_test.py
# and run against synthetic replies. Keep the markers on their own lines.
display_config() {
    host python3 - "$@" <<'PY'
import sys

import gi

gi.require_version("Gio", "2.0")
from gi.repository import GLib, Gio

# gdctl's numeric -> CLI spelling, copied from its Transform.enum_names table.
# 6 and 7 are NOT in the order the names suggest: gdctl calls 6 flipped-270
# and 7 flipped-180, the reverse of mutter's own enum order. The state file
# stores these names, so this spelling is what has to survive a round trip;
# the intuitive order would silently rotate two configurations wrongly.
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

# Transforms whose logical size is the mode's with width and height swapped —
# gdctl's set, in the numbering above: 6 swaps and 7 does not, the same 6/7
# ordering as the name table.
SWAPPED = {1, 3, 5, 6}

# ApplyMonitorsConfig methods, and the layout mode in which a logical
# monitor's size is its mode divided by its scale.
VERIFY, TEMPORARY = 0, 1
LOGICAL_LAYOUT_MODE = 1

# gdctl accepts a scale within this of a supported one and silently
# substitutes the supported value; mutter itself rejects an unsupported scale
# outright. Same tolerance, but the substitution is logged.
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
        # A transform the state file cannot carry could not be put back.
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
    # At scale 1 this is the mode itself, so the common case cannot round.
    scale = record["scale"]
    return round(width / scale), round(height / scale)


def pack(records, modes, layout_mode):
    """Lay the monitors out edge to edge, preserving their existing order.

    Monitors sharing an x coordinate are a vertical stack; anything else is
    treated as a row. mutter requires logical monitors to tile exactly, so
    this is the arithmetic gdctl's --right-of would otherwise do.
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
    # Verify first either way, so nothing moves on a config mutter refuses.
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

# Records for the current MON_* arrays into RECORDS, optionally overriding
# every scale.
records() {  # records [SCALE]
    local i scale
    RECORDS=()
    for ((i = 0; i < ${#MON_CONNS[@]}; i++)); do
        scale="${1:-${MON_SCALE[i]}}"
        RECORDS+=("${MON_CONNS[i]};$scale;${MON_PRIM[i]};${MON_X[i]};${MON_Y[i]};${MON_TRANSFORM[i]}")
    done
}

# The primary monitor's scale drives the font/cursor compensation.
primary_index() {
    local i
    for ((i = 0; i < ${#MON_PRIM[@]}; i++)); do
        [[ "${MON_PRIM[i]}" == "yes" ]] && { echo "$i"; return 0; }
    done
    echo 0
}

get_setting() { host gsettings get "$IFACE_SCHEMA" "$1" 2>/dev/null | tr -d "'"; }
set_setting() { host gsettings set "$IFACE_SCHEMA" "$1" "$2"; }

# Apply the records in RECORDS. Verified before applied, inside
# display_config; returns 2 when mutter refuses, which callers treat as
# "leave the display alone".
#
#   apply_records          replay coordinates as recorded  (restore)
#   apply_records --pack   lay them out edge to edge       (apply)
apply_records() {
    display_config apply "$@" "${RECORDS[@]}" 2>/dev/null
}

# ---------------------------------------------------------------------------
# State, on the host filesystem where the watchdog, the login unit, and your
# shell can all reach it.
# ---------------------------------------------------------------------------

# Written to a sibling and renamed, so a reader sees either the whole old
# state or the whole new one. A truncated state file fails every restore
# layer identically and strands the desktop at 1x.
# shellcheck disable=SC2016  # "$1" expands in the host-side sh, not here
state_write() {
    local text_scale="$1" cursor_size="$2" run="$3" i
    host mkdir -p "$STATE_DIR" 2>/dev/null
    printf '%s\n' "$run" \
        | host sh -c 'umask 077; cat > "$1"' sh "$RUN_FILE" || return 1
    {
        printf 'version=2\ntext_scale=%s\ncursor_size=%s\n' \
            "$text_scale" "$cursor_size"
        for ((i = 0; i < ${#MON_CONNS[@]}; i++)); do
            printf 'monitor=%s;%s;%s;%s;%s;%s\n' \
                "${MON_CONNS[i]}" "${MON_SCALE[i]}" "${MON_PRIM[i]}" \
                "${MON_X[i]}" "${MON_Y[i]}" "${MON_TRANSFORM[i]}"
        done
    } | host sh -c 'umask 077; cat > "$1.new" && mv -f "$1.new" "$1"' \
             sh "$STATE_FILE"
}

state_read()   { host cat "$STATE_FILE" 2>/dev/null; }
state_exists() { host test -r "$STATE_FILE"; }
state_clear()  { host rm -f "$STATE_FILE" "$RUN_FILE"; }
run_owner()    { host cat "$RUN_FILE" 2>/dev/null; }

# Strict key=value parse — deliberately NOT `source`. The state directory is
# writable by the sandboxed app we launch, and restore_now() also runs on the
# host from the login unit, so this file is untrusted input. Unknown keys and
# malformed values fail closed: a state file we don't fully understand is one
# we shouldn't replay onto a display.
#
# Assigns into the caller's locals (bash dynamic scope); leaves them untouched
# on failure. One `monitor=` line per logical monitor:
#   monitor=<connectors>;<scale>;<primary>;<x>;<y>;<transform>
parse_monitor_record() {
    local -a f conns
    local conn
    IFS=';' read -ra f <<<"$1"
    [[ ${#f[@]} -eq 6 ]] || return 1

    IFS=',' read -ra conns <<<"${f[0]}"
    [[ ${#conns[@]} -gt 0 ]] || return 1
    for conn in "${conns[@]}"; do
        is_connector "$conn" || return 1
        # A connector may drive exactly one logical monitor; a duplicate is a
        # configuration mutter always refuses, so replaying it retries forever.
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
            # Written by 1.4.0 only; accepted so its state files still
            # restore. The token lives in a sibling file now.
            run)         is_token     "$value"                        || return 1 ;;
            *) return 1 ;;
        esac
    done <<<"$blob"

    [[ ${#MON_CONNS[@]} -gt 0 ]]
}

# Idempotent: safe to call from the trap, the watchdog, and the login unit,
# in any order or all at once. Drops saved monitors that aren't currently
# connected — an unplugged display would otherwise make the saved layout
# unreplayable forever.
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
        # Per connector, not per record: a mirrored logical monitor lists
        # several, and a configuration is refused if ANY of them is absent, so
        # testing only the first re-sends the record that was just rejected.
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
    # A partial restore keeps the state: clearing it here would make the
    # compensated font size the next run's "original", compounding per launch.
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
# games.conf — per-game defaults:
#
#   <appid> = <item>[, <item>...]
#
# where an item is a string of flag letters (wnmxf) or a literal KEY=VAL.
# Parsed, never sourced, for the same reason the state file is: the directory
# is writable by the sandboxed app being launched. A malformed line is warned
# about by line number and skipped. An unknown but well-formed KEY=VAL is NOT
# malformed — that is the escape hatch for variables invented after this
# release.
# ---------------------------------------------------------------------------

# Filled by parse_entry, consumed by apply_entry. Two steps so validation is
# all-or-nothing: a line whose third item is bad must not half-apply its
# first two.
ENTRY_LETTERS=""
ENTRY_PAIRS=()
PARSE_ERROR=""

parse_entry() {  # parse_entry ENTRY   ->  0, or 1 with PARSE_ERROR set
    local entry="$1" item i ch
    local -a items
    ENTRY_LETTERS=""; ENTRY_PAIRS=(); PARSE_ERROR=""
    IFS=',' read -ra items <<<"$entry"
    for item in "${items[@]}"; do
        item=$(trim "$item")
        [[ -n "$item" ]] || { PARSE_ERROR="empty item"; return 1; }
        if [[ "$item" == *=* ]]; then
            if ! is_env_key "${item%%=*}"; then
                PARSE_ERROR="not a valid variable name: ${item%%=*}"
                return 1
            fi
            ENTRY_PAIRS+=("$item")
        else
            for ((i = 0; i < ${#item}; i++)); do
                ch="${item:i:1}"
                if ! is_letter "$ch"; then
                    PARSE_ERROR="unknown flag letter: $ch"
                    return 1
                fi
                ENTRY_LETTERS+="$ch"
            done
        fi
    done
    [[ -n "$ENTRY_LETTERS" || ${#ENTRY_PAIRS[@]} -gt 0 ]] || {
        PARSE_ERROR="empty entry"; return 1; }
}

apply_entry() {  # apply_entry SOURCE   — the entry last parsed
    local src="$1" i pair
    for ((i = 0; i < ${#ENTRY_LETTERS}; i++)); do
        apply_letter "${ENTRY_LETTERS:i:1}" "$src"
    done
    for pair in "${ENTRY_PAIRS[@]}"; do
        add_env "$pair" "$src"
    done
}

# Walks games.conf, calling CALLBACK appid entry lineno for every well-formed
# line. One parser used by the launch path, --status, --doctor and --set-game.
games_each() {  # games_each CALLBACK
    local cb="$1" blob line n=0 appid entry
    blob=$(host cat "$GAMES_FILE" 2>/dev/null) || return 0
    [[ -n "$blob" ]] || return 0
    while IFS= read -r line; do
        n=$((n + 1))
        # A '#' comments out the rest of the line only at the start of one or
        # after whitespace, so a value may still contain one.
        line="${line%%[[:space:]]#*}"
        line=$(trim "$line")
        [[ -n "$line" && "$line" != \#* ]] || continue
        if [[ "$line" != *=* ]]; then
            warn "$GAMES_FILE:$n: no '=' in \"$line\" — skipping"
            continue
        fi
        appid=$(trim "${line%%=*}")
        entry=$(trim "${line#*=}")
        if ! is_integer "$appid"; then
            warn "$GAMES_FILE:$n: \"$appid\" is not an appid — skipping"
            continue
        fi
        if ! parse_entry "$entry"; then
            warn "$GAMES_FILE:$n: $PARSE_ERROR — skipping"
            continue
        fi
        "$cb" "$appid" "$entry" "$n"
    done <<<"$blob"
}

# ---------------------------------------------------------------------------
# Resolving the environment. Precedence — explicit flags > games.conf >
# inherited environment — is decided by construction: flags fill ENV_* first
# and set EXPLICIT, which stops the config being consulted at all; inherited
# variables are last by virtue of being what `export` overwrites.
# ---------------------------------------------------------------------------

# Which appid the config matched, for the source labels.
CONFIG_APPID=""
CONFIG_ENTRY=""

config_match() {  # a games_each callback
    [[ "$1" == "$LOOKUP_APPID" ]] || return 0
    CONFIG_APPID="$1"; CONFIG_ENTRY="$2"
    apply_entry games.conf
}

# Fills ENV_*/NO_* from games.conf when the command line said nothing.
resolve_env() {  # resolve_env [APPID]
    LOOKUP_APPID="${1:-${SteamAppId:-}}"
    [[ $EXPLICIT == 0 && -n "$LOOKUP_APPID" ]] || return 0
    games_each config_match
}

src_echo() { case "$1" in games.conf) printf 'games.conf:%s' "$CONFIG_APPID" ;;
                          *) printf '%s' "$1" ;; esac; }
src_warn() { case "$1" in games.conf) printf 'games.conf(%s)' "$CONFIG_APPID" ;;
                          *) printf '%s' "$1" ;; esac; }

# Every export is echoed, one line each, naming its source — with three
# config surfaces, "I set a flag and nothing happened" is otherwise
# unanswerable after the fact.
export_env() {
    local i key val src
    for ((i = 0; i < ${#ENV_KEYS[@]}; i++)); do
        key="${ENV_KEYS[i]}"; val="${ENV_VALS[i]}"; src="${ENV_SRCS[i]}"
        # Agreement is not conflict: warn only when the value changes.
        if [[ -n "${!key+set}" && "${!key}" != "$val" ]]; then
            warn "$(src_warn "$src") overrides inherited $key=${!key} -> $val"
        fi
        warn "exporting $key=$val ($(src_echo "$src"))"
        export "${key}=${val}"
    done
}

# ---------------------------------------------------------------------------
# The last-run record, one per appid, overwritten in place. Informational
# only — nothing restores from it; it exists so --status can answer "what did
# that launch actually export". Parsed, never sourced, because it lives in
# the same sandbox-writable directory as the state file.
# ---------------------------------------------------------------------------

lastrun_file() {  # lastrun_file [APPID]
    printf '%s%s' "$LASTRUN_PREFIX" "${1:-cmdline}"
}

# shellcheck disable=SC2016  # "$1" expands in the host-side sh, not here
lastrun_write() {  # lastrun_write SOURCE
    local src="$1" file i
    file=$(lastrun_file "${SteamAppId:-}")
    {
        printf 'timestamp=%s\nsource=%s\n' \
            "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$src"
        for ((i = 0; i < ${#ENV_KEYS[@]}; i++)); do
            printf 'env=%s=%s\n' "${ENV_KEYS[i]}" "${ENV_VALS[i]}"
        done
    } | host sh -c 'umask 077; cat > "$1.new" && mv -f "$1.new" "$1"' sh "$file"
}

# Assigns lr_timestamp/lr_source/lr_env into the caller's locals. A known key
# with a malformed value fails; unknown keys are ignored — nothing restores
# from this record.
lastrun_parse() {  # lastrun_parse APPID-OR-EMPTY
    local blob line key value
    blob=$(host cat "$(lastrun_file "$1")" 2>/dev/null) || return 1
    [[ -n "$blob" ]] || return 1
    lr_timestamp=""; lr_source=""; lr_env=()
    while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        key="${line%%=*}"; value="${line#*=}"
        [[ "$key" != "$line" ]] || return 1
        case "$key" in
            timestamp) [[ "$value" =~ ^[0-9T:Z-]+$ ]] || return 1
                       lr_timestamp="$value" ;;
            source)    [[ "$value" =~ ^(flags|games\.conf|none)$ ]] || return 1
                       lr_source="$value" ;;
            env)       is_env_key "${value%%=*}" || return 1
                       [[ "$value" == *=* ]] || return 1
                       lr_env+=("$value") ;;
            *) ;;
        esac
    done <<<"$blob"
    [[ -n "$lr_source" ]]
}

# Which surface decided this launch, for the record and for --status.
env_source() {
    if [[ $EXPLICIT == 1 ]]; then printf 'flags'
    elif [[ -n "$CONFIG_APPID" ]]; then printf 'games.conf'
    else printf 'none'; fi
}

# ---------------------------------------------------------------------------
# Game names, a nicety and never a requirement. appmanifest_<appid>.acf is
# Valve's and is opened read-only; failure to resolve a name is silent.
# ---------------------------------------------------------------------------

# The steamapps directories to look in: the Flatpak path, the native path, and
# whatever libraryfolders.vdf names, if that file yields its "path" values to
# a one-line awk. If it doesn't, skip it rather than grow a VDF parser.
# shellcheck disable=SC2016  # $4 belongs to the host-side awk, not the shell
steamapps_dirs() {
    local base dir
    local -a roots=(
        "${HOST_HOME}/.var/app/com.valvesoftware.Steam/.local/share/Steam"
        "${HOST_HOME}/.local/share/Steam"
        "${HOST_HOME}/.steam/steam"
    )
    for base in "${roots[@]}"; do
        printf '%s/steamapps\n' "$base"
        while IFS= read -r dir; do
            [[ -n "$dir" ]] && printf '%s/steamapps\n' "$dir"
        done < <(host awk -F'"' '/^\t\t"path"/ { print $4 }' \
                     "$base/steamapps/libraryfolders.vdf" 2>/dev/null)
    done
}

# shellcheck disable=SC2016  # $4 belongs to the host-side awk, not the shell
game_name() {  # game_name APPID  ->  name on stdout, or 1
    local appid="$1" dir name
    is_integer "$appid" || return 1
    while IFS= read -r dir; do
        name=$(host awk -F'"' '/^\t"name"/ { print $4; exit }' \
                   "$dir/appmanifest_$appid.acf" 2>/dev/null)
        [[ -n "$name" ]] && { printf '%s' "$name"; return 0; }
    done < <(steamapps_dirs)
    return 1
}

# ---------------------------------------------------------------------------
# Modes that don't need the full dependency set
# ---------------------------------------------------------------------------

if [[ "$MODE" == "install" ]]; then
    unit_dir="${HOST_HOME}/.config/systemd/user"
    host mkdir -p "$unit_dir"
    # shellcheck disable=SC2016  # "$1" expands in the host-side sh, not here
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
        | host sh -c 'cat > "$1"' sh "$unit_dir/gamescale-reconcile.service"
    host systemctl --user daemon-reload
    host systemctl --user enable gamescale-reconcile.service
    echo "installed and enabled gamescale-reconcile.service"
    exit 0
fi

# --set-game — the only writer of games.conf. It validates with the same
# parser the launch path uses, and the rewrite is line-oriented rather than
# regenerated: comments, blank lines, alignment and entries for other games
# survive verbatim, including lines this parser thinks are malformed.
if [[ "$MODE" == "setgame" ]]; then
    if ! is_integer "$SET_GAME_APPID"; then
        warn "usage: gamescale --set-game <appid> <entry|->"
        warn "e.g.   gamescale --set-game 1817070 wn"
        exit 2
    fi
    if [[ -z "$SET_GAME_ENTRY" ]]; then
        warn "usage: gamescale --set-game <appid> <entry|->"
        warn "'-' removes the entry"
        exit 2
    fi
    REMOVING=0
    if [[ "$SET_GAME_ENTRY" == "-" ]]; then
        REMOVING=1
    elif ! parse_entry "$SET_GAME_ENTRY"; then
        warn "$PARSE_ERROR"
        warn "entries are flag letters (wnmxf) and KEY=VAL, comma separated"
        exit 2
    fi

    host mkdir -p "$STATE_DIR" 2>/dev/null
    OLD=$(host cat "$GAMES_FILE" 2>/dev/null)
    NEW=""; REPLACED=0
    while IFS= read -r line; do
        bare="${line%%[[:space:]]#*}"
        bare=$(trim "$bare")
        if [[ "$bare" == *=* ]] && [[ "$(trim "${bare%%=*}")" == "$SET_GAME_APPID" ]]; then
            REPLACED=1
            [[ $REMOVING == 1 ]] && continue
            # Keep whatever comment was on the line — usually the game's name.
            comment=""
            [[ "$line" == *[[:space:]]#* ]] && comment="  #${line#*#}"
            NEW+="$SET_GAME_APPID = $SET_GAME_ENTRY$comment"$'\n'
            continue
        fi
        NEW+="$line"$'\n'
    done <<<"$OLD"
    if [[ $REPLACED == 0 ]]; then
        if [[ $REMOVING == 1 ]]; then
            warn "no entry for $SET_GAME_APPID"
            exit 1
        fi
        NAME=$(game_name "$SET_GAME_APPID") || NAME=""
        NEW+="$SET_GAME_APPID = $SET_GAME_ENTRY${NAME:+  # $NAME}"$'\n'
    fi
    # `while read <<<""` yields one empty line for an empty file; drop the
    # leading blank rather than growing one on every write.
    [[ -z "$OLD" ]] && NEW="${NEW#$'\n'}"
    # shellcheck disable=SC2016  # "$1" expands in the host-side sh, not here
    if ! printf '%s' "$NEW" | host sh -c \
            'umask 077; cat > "$1.new" && mv -f "$1.new" "$1"' sh "$GAMES_FILE"; then
        warn "could not write $GAMES_FILE"
        exit 1
    fi
    if [[ $REMOVING == 1 ]]; then
        echo "removed $SET_GAME_APPID from $GAMES_FILE"
    else
        echo "$SET_GAME_APPID = $SET_GAME_ENTRY"
    fi
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

# The watchdog runs ON THE HOST (systemd started it), so HOST is empty here.
# It blocks on the lock the game process holds; the kernel drops that lock
# when the process dies, however it dies.
if [[ "$MODE" == "watchdog" ]]; then
    WATCH_RUN="${1:-}"
    log "watchdog for run ${WATCH_RUN:-unknown} waiting on $LOCK_FILE"
    exec 9>>"$LOCK_FILE" || exit 1
    if ! flock -w "$WATCHDOG_TIMEOUT" -x 9; then
        # The game outlived the ceiling — it is STILL RUNNING. Restoring here
        # would yank the desktop back under it and clear the state the real
        # exit needs. The trap and the login unit still cover it.
        warn "watchdog gave up after ${WATCHDOG_TIMEOUT}s with the game still"
        warn "running; leaving the display and the state file alone"
        exit 1
    fi
    # Small grace period so the in-sandbox trap gets first crack at it.
    sleep 2
    if state_exists; then
        # During the grace period the next game may have started and written
        # its own state; act only on state this watchdog was started for.
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

# python3 talks to mutter over D-Bus; gsettings carries the font/cursor
# compensation. gdctl is deliberately NOT required: it only arrived in Mutter
# 48, while the D-Bus interface it wraps is years older.
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
    # A second line about the SAME failure; must not touch the count.
    more() { printf '    %s\n' "$1"; }
    # Worth knowing but not a broken install; never touches DOCTOR_BAD.
    huh()  { printf '  \033[33m!\033[0m %s\n' "$1"; }
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
    # shellcheck disable=SC2016  # "$1" expands in the host-side sh, not here
    if host sh -c 'touch "$1/.probe" && rm -f "$1/.probe"' sh "$STATE_DIR" 2>/dev/null; then
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
    # Bare-name invocation rides on an --env=PATH override, which REPLACES the
    # sandbox PATH — a Steam update adding a directory would be dropped.
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
        # Ask mutter whether the configuration this would apply is acceptable
        # — the only check that exercises the arithmetic, and every monitor
        # has to reach 1x before XWayland's global factor drops.
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
    # ntsync: -n exports PROTON_USE_NTSYNC=1 whatever the kernel thinks, and
    # Proton then ignores it in silence — a failure the export echo cannot
    # explain, because the export did happen.
    KVER=$(host uname -r 2>/dev/null)
    KMAJ="${KVER%%.*}"; KMIN="${KVER#*.}"; KMIN="${KMIN%%.*}"
    if ! host test -e "$NTSYNC_DEV"; then
        huh "$NTSYNC_DEV absent — -n exports the variable, Proton ignores it"
        more "needs a kernel with ntsync built and the module loaded"
    elif ! is_integer "${KMAJ:-}" || ! is_integer "${KMIN:-}"; then
        huh "$NTSYNC_DEV present; could not read a kernel version to check"
    elif [[ $KMAJ -lt 6 || ($KMAJ -eq 6 && $KMIN -lt 14) ]]; then
        huh "$NTSYNC_DEV present but kernel $KVER is below 6.14"
        more "the pre-6.14 interface is not the one Proton uses"
    else
        # "The kernel side is fine", not "-n works": on stock Proton the
        # variable -n sets is read by nothing.
        ok "ntsync usable by the kernel ($NTSYNC_DEV, kernel $KVER)"
    fi
    # wayland: winewayland falls back to XWayland silently, so nothing
    # observable from outside the game says which one engaged.
    huh "-w cannot be checked from here: Proton falls back to XWayland silently"
    more "and a wayland game has the SAME resolution problem"
    more "confirm with: flatpak run --command=xlsclients com.valvesoftware.Steam"
    # A rotted letter exports perfectly and does nothing; showing the
    # expansions is what lets a user aim suspicion at the table.
    printf '    shorthand expansions (aliases of -e; see --help):\n'
    for letter in w n m; do
        printf '      -%s  %s\n' "$letter" "${LETTER_EXPANDS[$letter]}"
    done
    more "on stock Valve Proton -w and -n are inert; if a letter does nothing,"
    more "use -e with the name your build documents"
    # games.conf, through the same parser the launch path uses.
    if host test -r "$GAMES_FILE"; then
        # Both streams captured in one parse: the callback marks accepted
        # entries on stdout, the parser complains on stderr.
        # shellcheck disable=SC2317,SC2329  # called by name from games_each
        doctor_line() { printf 'entry %s\n' "$1"; }
        GAMES_OUT=$(games_each doctor_line 2>&1)
        GAMES_SEEN=$(printf '%s\n' "$GAMES_OUT" | grep -c '^entry ')
        GAMES_WARNINGS=$(printf '%s\n' "$GAMES_OUT" | grep -v '^entry ')
        if [[ -n "$GAMES_WARNINGS" ]]; then
            bad "games.conf has lines that will be skipped:"
            while IFS= read -r line; do more "${line#gamescale: }"; done \
                <<<"$GAMES_WARNINGS"
        else
            ok "games.conf parses ($GAMES_SEEN entr$([[ $GAMES_SEEN == 1 ]] && echo y || echo ies))"
        fi
    else
        ok "no games.conf (per-game defaults unused)"
    fi
    # Installing is four independent steps; a run that died halfway leaves
    # some checks green and some red. Re-running the installer is idempotent.
    if [[ $DOCTOR_BAD -gt 0 ]]; then
        echo
        echo "  $DOCTOR_BAD check(s) failed. The installer is idempotent — re-running it"
        echo "  fixes everything above except a stale state file:"
        echo "    curl -fsSL https://raw.githubusercontent.com/proto-cool/gamescale/main/install.sh | sh"
        exit 1
    fi
    exit 0
fi

# ---------------------------------------------------------------------------
# The environment, resolved and exported before anything touches the display
# and ahead of the dependency check: an env-only launch needs no gsettings,
# no python3 and no mutter, so it must not be refused for lacking them.
# ---------------------------------------------------------------------------

if [[ "$MODE" == "run" ]]; then
    [[ $# -gt 0 ]] || { warn "no command given"; exit 2; }
    resolve_env
    export_env
    [[ ${#ENV_KEYS[@]} -gt 0 ]] && lastrun_write "$(env_source)"
fi

# -x: export, exec, touch nothing else — including the lock. An -x launch is
# not an owner of the display, so the one-game-at-a-time rule must not apply
# to it in either direction: it neither blocks a scaled launch nor waits on
# one.
if [[ "$MODE" == "run" && $NO_SCALE == 1 ]]; then
    log "env-only (-x): not touching the display"
    exec "$@"
fi

if [[ ${#MISSING[@]} -gt 0 && "$MODE" != "status" ]]; then
    give_up "cannot reach ${MISSING[*]} on the host (--talk-name=org.freedesktop.Flatpak?)" "$@"
fi

if [[ "$MODE" == "status" ]]; then
    STATUS_RC=0
    if [[ -n "$STATUS_APPID" ]] && ! is_integer "$STATUS_APPID"; then
        warn "--status takes an appid, not \"$STATUS_APPID\""
        exit 2
    fi
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
        echo "monitor:      DETECTION FAILED"; STATUS_RC=1
    fi
    echo "text scaling: $(get_setting text-scaling-factor)"
    echo "cursor size:  $(get_setting cursor-size)"
    state_exists && echo "stale state:  yes — run --restore"

    if host test -r "$GAMES_FILE"; then
        echo
        echo "games.conf:   $GAMES_FILE"
        # shellcheck disable=SC2317,SC2329  # called by name from games_each
        status_line() {
            printf '  %-10s %-32s %s\n' "$1" "$(game_name "$1" || echo '-')" "$2"
        }
        games_each status_line
    fi

    # The per-game view: what this appid would get, and what it got last time.
    VIEW_APPID="${STATUS_APPID:-${SteamAppId:-}}"
    if [[ -n "$VIEW_APPID" ]]; then
        # Second parse of the same file; the table above already reported its
        # complaints by line number, so they are silenced here.
        resolve_env "$VIEW_APPID" 2>/dev/null
        echo
        echo "game:         $VIEW_APPID $(game_name "$VIEW_APPID" || echo '(name not resolved)')"
        echo "entry:        ${CONFIG_ENTRY:-none}"
        echo "no-scale:     $([[ $NO_SCALE == 1 ]] && echo 'yes — env only' || echo no)"
        echo "no-font:      $([[ $NO_FONT == 1 ]] && echo yes || echo no)"
        if [[ ${#ENV_KEYS[@]} -eq 0 ]]; then
            echo "exports:      none"
        else
            for ((i = 0; i < ${#ENV_KEYS[@]}; i++)); do
                printf 'export:       %s=%s (%s)\n' \
                    "${ENV_KEYS[i]}" "${ENV_VALS[i]}" "$(src_echo "${ENV_SRCS[i]}")"
            done
        fi
        lr_timestamp=""; lr_source=""; lr_env=()
        if lastrun_parse "$VIEW_APPID"; then
            echo "last run:     $lr_timestamp (from $lr_source)"
            for pair in "${lr_env[@]}"; do
                echo "last export:  $pair"
            done
        elif host test -e "$(lastrun_file "$VIEW_APPID")"; then
            echo "last run:     record present but not understood — ignoring it"
        else
            echo "last run:     no record"
        fi
    fi
    exit "$STATUS_RC"
fi

# ---------------------------------------------------------------------------
# Run mode
# ---------------------------------------------------------------------------

# Identifies this run in the run file and the watchdog's unit name, so a
# watchdog left over from the previous game cannot act on this run's state.
# $$ alone repeats: the sandbox's PID namespace restarts low.
RUN_ID="$$-${RANDOM}${RANDOM}"

# The lock comes first, before the state file is touched. It is the handle
# the watchdog waits on and the guard against two runs fighting over one
# display. The short wait absorbs the previous watchdog's grace period. FD 9
# is inherited by the game, and the kernel holds the lock until every process
# holding that descriptor is gone.
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
# detecting, so 1x is never recorded as the "original".
if state_exists; then
    warn "state left over from a previous run; restoring before starting"
    # restore_now also fails when the scale came back but the font did not —
    # and then the sizes in gsettings are a previous run's COMPENSATED values,
    # which must not be recorded as this run's originals.
    if ! restore_now; then
        give_up "leftover restore failed; not scaling, because the current font and cursor sizes may be a previous run's compensated values" "$@"
    fi
fi

detect || give_up "could not determine monitor/scale" "$@"

# "Already done" means ALL of them: XWayland's factor only drops to 1 once
# every logical monitor is at 1x, and a partial job costs more pixels than
# never having run.
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
# and this file is the only record of where it was.
if ! state_write "$ORIG_TEXT_SCALE" "$ORIG_CURSOR_SIZE" "$RUN_ID"; then
    give_up "could not write $STATE_FILE; not scaling, because nothing would know how to put your display back" "$@"
fi

# Layer 2. The lock is already held, so there is no window in which the
# watchdog could acquire it and restore immediately.
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
# and icons won't follow — a GNOME limitation, not a bug here.
if [[ $NO_FONT == 0 ]]; then
    RATIO=$(fdiv "$ORIG_SCALE" "$GAME_SCALE")
    set_setting text-scaling-factor "$(fmul "$ORIG_TEXT_SCALE" "$RATIO")"
    set_setting cursor-size "$(fround "$(fmul "$ORIG_CURSOR_SIZE" "$RATIO")")"
    log "compensated ${RATIO}x"
fi

# Let mutter settle before the game enumerates outputs.
sleep 1

"$@"
