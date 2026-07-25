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
readonly VERSION="1.3.0"

readonly IFACE_SCHEMA="org.gnome.desktop.interface"
readonly WATCHDOG_TIMEOUT=43200   # 12h ceiling; watchdog self-terminates after
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
esac

# Give up on scaling but still start the game, if there is one. Never exec a
# leftover flag.
give_up() {
    local msg="$1"; shift
    warn "$msg"
    [[ "$MODE" == "run" && $# -gt 0 ]] && exec "$@"
    exit 1
}

# ---------------------------------------------------------------------------
# Host plumbing. Inside the Steam flatpak, gdctl/gsettings/systemd-run all live
# on the host and need the org.freedesktop.Flatpak portal to reach.
# ---------------------------------------------------------------------------

IN_FLATPAK=0
HOST=()
if [[ -f /.flatpak-info ]]; then
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
# Applying still goes through `gdctl set`, whose flags ARE a stable contract.
# Doing that over D-Bus as well would mean picking a mode id per monitor out of
# GetCurrentState's mode list and threading the config serial through, which is
# most of what gdctl's 1500 lines are for.
#
# EVERY logical monitor is captured, not just the primary one, because the
# XWayland scale factor is global: it only drops to 1 when every monitor is at
# 1.0. Scaling the primary alone leaves the factor at 2 and applies it to a
# full-resolution logical size, which costs MORE pixels than doing nothing
# (measured: 5120x3200 vs 3840x2400 on a 2560x1600 panel).
#
# gdctl set replaces the whole configuration, so a monitor left out of the
# command is a monitor switched off. Everything detected here must be replayed.
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

# One tab-separated record per logical monitor, in mutter's own order:
#
#   <connectors>\t<scale>\t<primary>\t<x>\t<y>\t<transform>
#
# The body between <<'PY' and PY is extracted verbatim by test/detect_test.py
# and run against synthetic variants, so the reader under test is this one and
# not a copy of it. Keep the markers on their own lines.
detect() {
    local out
    out=$(host python3 - <<'PY'
import sys

import gi

gi.require_version("Gio", "2.0")
from gi.repository import Gio

# gdctl's numeric -> CLI spelling, copied from its Transform.enum_names table.
# 6 and 7 are NOT in the order the names suggest: gdctl calls 6 flipped-270 and
# 7 flipped-180, the reverse of mutter's own FLIPPED_180/FLIPPED_270 enum order.
# These strings are handed straight back to `gdctl set --transform`, so gdctl's
# spelling is the one that matters. Getting it from the intuitive order instead
# would silently rotate two of the eight configurations wrongly on restore.
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

try:
    proxy = Gio.DBusProxy.new_for_bus_sync(
        bus_type=Gio.BusType.SESSION,
        flags=Gio.DBusProxyFlags.NONE,
        info=None,
        name="org.gnome.Mutter.DisplayConfig",
        object_path="/org/gnome/Mutter/DisplayConfig",
        interface_name="org.gnome.Mutter.DisplayConfig",
        cancellable=None,
    )
    state = proxy.call_sync(
        method_name="GetCurrentState",
        parameters=None,
        flags=Gio.DBusCallFlags.NO_AUTO_START,
        timeout_msec=-1,
        cancellable=None,
    )
except Exception as exc:
    print("gamescale: cannot read display state: %s" % exc, file=sys.stderr)
    raise SystemExit(1)

_serial, _monitors, logical, _props = state.unpack()

for x, y, scale, transform, primary, monitors, _mprops in logical:
    transform_name = TRANSFORM.get(transform)
    if transform_name is None:
        # A transform gdctl has no spelling for cannot be replayed through it,
        # and a layout we cannot put back is one we must not take apart.
        print("gamescale: unknown transform %r" % transform, file=sys.stderr)
        raise SystemExit(1)
    print(
        "\t".join(
            [
                ",".join(m[0] for m in monitors),
                repr(scale),
                "yes" if primary else "no",
                str(x),
                str(y),
                transform_name,
            ]
        )
    )
PY
    ) || return 1

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

# The primary monitor's scale drives the font/cursor compensation, since that's
# the display you'll be reading the desktop on.
primary_index() {
    local i
    for ((i = 0; i < ${#MON_PRIM[@]}; i++)); do
        [[ "${MON_PRIM[i]}" == "yes" ]] && { echo "$i"; return 0; }
    done
    echo 0
}

# Monitors sharing an x coordinate are stacked vertically; anything else is
# treated as a horizontal row. Determines which gdctl relation to rebuild the
# layout with.
layout_axis() {
    local i first_x="${MON_X[0]}"
    for ((i = 1; i < ${#MON_X[@]}; i++)); do
        [[ "${MON_X[i]}" == "$first_x" ]] || { echo x; return; }
    done
    echo y
}

# Indices ordered along that axis. Used to rebuild the layout relationally when
# applying, since absolute coordinates stop being valid the moment the scales
# change: at 1x each logical monitor grows, and the old coordinates overlap.
layout_order() {
    local i axis="$1"
    for ((i = 0; i < ${#MON_CONNS[@]}; i++)); do
        if [[ "$axis" == "x" ]]; then echo "${MON_X[i]} $i"; else echo "${MON_Y[i]} $i"; fi
    done | sort -n | awk '{ print $2 }'
}

# ---------------------------------------------------------------------------
# Settings access
# ---------------------------------------------------------------------------

get_setting() { host gsettings get "$IFACE_SCHEMA" "$1" 2>/dev/null | tr -d "'"; }
set_setting() { host gsettings set "$IFACE_SCHEMA" "$1" "$2"; }

# Builds a complete gdctl argument list into GDCTL_ARGS from the MON_* arrays.
# Complete is the operative word: gdctl set replaces the entire configuration,
# so any monitor omitted here is a monitor switched off.
#
#   build_config absolute        replay saved scales at saved coordinates
#   build_config relational SCALE put every monitor at SCALE, let mutter place
#
# Absolute is for restore, where the coordinates are known good. Relational is
# for apply, where they aren't: at 1x every logical monitor grows, so the saved
# coordinates would overlap and mutter would reject the config.
build_config() {
    local mode="$1" forced_scale="${2:-}" i conn scale axis prev=""
    GDCTL_ARGS=()

    local -a order=()
    if [[ "$mode" == "relational" ]]; then
        axis=$(layout_axis)
        mapfile -t order < <(layout_order "$axis")
    else
        for ((i = 0; i < ${#MON_CONNS[@]}; i++)); do order+=("$i"); done
    fi

    for i in "${order[@]}"; do
        scale="${forced_scale:-${MON_SCALE[i]}}"
        GDCTL_ARGS+=(--logical-monitor)
        [[ "${MON_PRIM[i]}" == "yes" ]] && GDCTL_ARGS+=(--primary)
        # A mirrored logical monitor drives several connectors at once.
        local IFS=,
        for conn in ${MON_CONNS[i]}; do GDCTL_ARGS+=(--monitor "$conn"); done
        unset IFS
        GDCTL_ARGS+=(--scale "$scale" --transform "${MON_TRANSFORM[i]}")

        if [[ "$mode" == "absolute" ]]; then
            GDCTL_ARGS+=(--x "${MON_X[i]}" --y "${MON_Y[i]}")
        elif [[ -z "$prev" ]]; then
            GDCTL_ARGS+=(--x 0 --y 0)
        elif [[ "$axis" == "x" ]]; then
            GDCTL_ARGS+=(--right-of "$prev")
        else
            GDCTL_ARGS+=(--below "$prev")
        fi
        prev="${MON_CONNS[i]%%,*}"
    done
}

# gdctl --verify checks a configuration without applying it, which turns "we
# might strand your display layout" into a question we can answer beforehand.
apply_config() {
    host gdctl set --verify "${GDCTL_ARGS[@]}" 2>/dev/null || return 2
    host gdctl set "${GDCTL_ARGS[@]}"
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
# gdctl rejects the bad value, every restore layer fails identically, and the
# retry logic then keeps you stranded at 1x instead of recovering.
state_write() {
    local text_scale="$1" cursor_size="$2" i
    host mkdir -p "$STATE_DIR" 2>/dev/null
    {
        printf 'version=2\ntext_scale=%s\ncursor_size=%s\n' "$text_scale" "$cursor_size"
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
state_clear()  { host rm -f "$STATE_FILE"; }

is_number()    { [[ "$1" =~ ^[0-9]+(\.[0-9]+)?$ ]]; }
is_integer()   { [[ "$1" =~ ^[0-9]+$ ]]; }
# Permissive enough for eDP-1, DP-2 and HDMI-A-1; strict enough that nothing
# reaching gdctl can carry whitespace, quotes or shell metacharacters.
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
    for conn in "${conns[@]}"; do is_connector "$conn" || return 1; done

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
    local present i first has_primary=0

    detect || return 1
    present=" ${MON_CONNS[*]//,/ } "

    MON_CONNS=(); MON_SCALE=(); MON_PRIM=(); MON_X=(); MON_Y=(); MON_TRANSFORM=()
    for ((i = 0; i < ${#s_conns[@]}; i++)); do
        first="${s_conns[i]%%,*}"
        [[ "$present" == *" $first "* ]] || { log "dropping absent $first"; continue; }
        MON_CONNS+=("${s_conns[i]}"); MON_SCALE+=("${s_scale[i]}")
        MON_PRIM+=("${s_prim[i]}");   MON_X+=("${s_x[i]}")
        MON_Y+=("${s_y[i]}");         MON_TRANSFORM+=("${s_tr[i]}")
        [[ "${s_prim[i]}" == "yes" ]] && has_primary=1
    done

    [[ ${#MON_CONNS[@]} -gt 0 ]] || return 1
    [[ $has_primary == 1 ]] || MON_PRIM[0]="yes"

    build_config relational ""
    apply_config
}

restore_now() {
    local text_scale="" cursor_size=""
    state_exists || return 1
    if ! state_parse; then
        warn "state at $STATE_FILE is malformed — refusing to replay it"
        warn "recover by hand with: gdctl set --logical-monitor --primary \\"
        warn "    --monitor <connector> --scale <scale>   (see gdctl show)"
        return 1
    fi

    log "restoring ${#MON_CONNS[@]} monitor(s) (text $text_scale, cursor $cursor_size)"
    build_config absolute
    if ! apply_config; then
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
        log "nothing to restore"
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
    log "watchdog waiting on $LOCK_FILE"
    exec 9>>"$LOCK_FILE" || exit 1
    if ! flock -w "$WATCHDOG_TIMEOUT" -x 9; then
        warn "watchdog timed out after ${WATCHDOG_TIMEOUT}s; restoring anyway"
    fi
    # Small grace period so the in-sandbox trap gets first crack at it.
    sleep 2
    if state_exists; then
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

# python3 reads the display state, gdctl applies it, gsettings carries the
# font/cursor compensation. gdctl is itself a python3 + PyGObject script, so on
# any system that has it all three of these are already present.
MISSING=()
for cmd in gdctl gsettings python3; do
    have_host "$cmd" || MISSING+=("$cmd")
done

CAN_WATCH=1
have_host systemd-run || CAN_WATCH=0
command -v flock >/dev/null 2>&1 || CAN_WATCH=0

if [[ "$MODE" == "doctor" ]]; then
    DOCTOR_BAD=0
    ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; }
    bad()  { printf '  \033[31m✗\033[0m %s\n' "$1"; DOCTOR_BAD=$((DOCTOR_BAD + 1)); }
    echo "gamescale $VERSION doctor"
    echo
    if [[ $IN_FLATPAK == 1 ]]; then
        ok "running sandboxed (flatpak-spawn present)"
    else
        ok "running on the host"
    fi
    if [[ ${#MISSING[@]} -eq 0 ]]; then
        ok "gdctl + gsettings + python3 reachable"
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
        # Every monitor has to reach 1x before XWayland's global integer factor
        # drops, so a second display is not a detail we can ignore.
        if [[ ${#MON_CONNS[@]} -gt 1 ]]; then
            build_config relational "$GAME_SCALE"
            if host gdctl set --verify "${GDCTL_ARGS[@]}" 2>/dev/null; then
                ok "${#MON_CONNS[@]} monitors — the ${GAME_SCALE}x layout verifies"
            else
                bad "${#MON_CONNS[@]} monitors — gdctl rejects the ${GAME_SCALE}x layout;"
                bad "  games will launch unmodified rather than risk your layout"
            fi
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

# Leftover state means something died without restoring. Put it back before
# detecting, so we never record 1x as the "original" and strand you there.
if state_exists; then
    warn "state left over from a previous run; restoring before starting"
    restore_now || warn "leftover restore failed; continuing anyway"
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
    exec "$@"
fi

PRIMARY=$(primary_index)
ORIG_SCALE="${MON_SCALE[PRIMARY]}"
ORIG_TEXT_SCALE=$(get_setting text-scaling-factor); : "${ORIG_TEXT_SCALE:=1.0}"
ORIG_CURSOR_SIZE=$(get_setting cursor-size);        : "${ORIG_CURSOR_SIZE:=24}"

host mkdir -p "$STATE_DIR" 2>/dev/null
state_write "$ORIG_TEXT_SCALE" "$ORIG_CURSOR_SIZE"

# Layer 2. Take the lock BEFORE starting the watchdog, so there's no window
# where the watchdog could acquire it and restore immediately. FD 9 is
# inherited by the game; the kernel holds the lock until every process holding
# that descriptor is gone, which is exactly the lifetime we care about.
if [[ "${GAMESCALE_NO_WATCH:-0}" != "1" && $CAN_WATCH == 1 ]]; then
    if exec 9>>"$LOCK_FILE" && flock -n -x 9; then
        if host systemd-run --user --collect --quiet \
                --unit="gamescale-watchdog-$$" \
                "$SELF" --watchdog; then
            log "watchdog started"
        else
            warn "could not start watchdog; falling back to trap-only"
        fi
    else
        warn "could not take lock at $LOCK_FILE; falling back to trap-only"
    fi
fi

# Layer 1.
cleanup() {
    trap - EXIT INT TERM
    restore_now
}
trap cleanup EXIT INT TERM

build_config relational "$GAME_SCALE"
apply_config; APPLY_RC=$?
if [[ $APPLY_RC -ne 0 ]]; then
    if [[ $APPLY_RC == 2 ]]; then
        warn "gdctl rejected the ${GAME_SCALE}x layout for ${#MON_CONNS[@]} monitor(s);"
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
