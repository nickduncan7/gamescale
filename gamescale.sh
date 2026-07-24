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
#
#   Steam launch option:  gamescale %command%
#
# ENV
#   GAMESCALE_SCALE     scale while playing        (default: 1)
#   GAMESCALE_MONITOR   connector override         (default: auto-detect)
#   GAMESCALE_NO_FONT   1 to skip font/cursor compensation
#   GAMESCALE_NO_WATCH  1 to skip the host watchdog (trap only)
#   GAMESCALE_DEBUG     1 for verbose logging

set -uo pipefail

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
# Detection — parses the "Logical monitors:" section of `gdctl show`:
#
#   Logical monitors:
#   └──Logical monitor #1
#      ├──Position: (0, 0)
#      ├──Scale: 1.3333333730697632
#      ├──Primary: yes
#      └──Monitors: (1)
#          └──eDP-1 (Built-in display)
#
# The scale is a full-precision double and is stored and replayed verbatim, so
# gdctl accepts it as a supported value on restore.
# ---------------------------------------------------------------------------

detect_from_gdctl() {
    local out parsed
    out=$(host gdctl show 2>/dev/null) || return 1

    parsed=$(awk '
        /^Logical monitors:/ { section = 1; next }
        !section { next }
        /Logical monitor #/ { n++; in_monitors = 0; next }
        !n { next }
        /Scale:/    { if (match($0, /[0-9]+\.?[0-9]*/))
                          scale[n] = substr($0, RSTART, RLENGTH)
                      next }
        /Primary:/  { if ($0 ~ /yes/) primary = n; next }
        /Monitors:/ { in_monitors = 1; next }
        in_monitors && conn[n] == "" {
            if (match($0, /[A-Za-z]+[-_][0-9]+/))
                conn[n] = substr($0, RSTART, RLENGTH)
            next
        }
        END {
            pick = primary ? primary : 1
            if (conn[pick] == "") exit 1
            print conn[pick] "\t" (scale[pick] == "" ? 1 : scale[pick])
        }
    ' <<<"$out") || return 1

    DET_CONNECTOR="${parsed%%$'\t'*}"
    DET_SCALE="${parsed##*$'\t'}"
    [[ -n "$DET_CONNECTOR" && -n "$DET_SCALE" ]] || return 1
    log "gdctl: $DET_CONNECTOR @ $DET_SCALE"
}

# Fallback: saved config rather than live state.
detect_from_xml() {
    local xml="${HOST_HOME}/.config/monitors.xml" connector scale
    host test -r "$xml" || return 1
    have_host xmllint || return 1

    connector=$(host xmllint --xpath \
        'string((//configuration/logicalmonitor[primary="yes"]/monitor/monitorspec/connector)[1])' \
        "$xml" 2>/dev/null)
    scale=$(host xmllint --xpath \
        'string((//configuration/logicalmonitor[primary="yes"]/scale)[1])' \
        "$xml" 2>/dev/null)

    if [[ -z "$connector" ]]; then
        connector=$(host xmllint --xpath \
            'string((//configuration/logicalmonitor/monitor/monitorspec/connector)[1])' \
            "$xml" 2>/dev/null)
        scale=$(host xmllint --xpath \
            'string((//configuration/logicalmonitor/scale)[1])' \
            "$xml" 2>/dev/null)
    fi

    [[ -n "$connector" && -n "$scale" ]] || return 1
    DET_CONNECTOR="$connector"
    DET_SCALE="$scale"
    log "monitors.xml: $DET_CONNECTOR @ $DET_SCALE"
}

detect() {
    DET_CONNECTOR=""; DET_SCALE=""
    detect_from_gdctl || detect_from_xml || return 1
    [[ -n "${GAMESCALE_MONITOR:-}" ]] && DET_CONNECTOR="$GAMESCALE_MONITOR"
    return 0
}

# ---------------------------------------------------------------------------
# Settings access
# ---------------------------------------------------------------------------

set_scale()   { host gdctl set --logical-monitor --primary --monitor "$1" --scale "$2"; }
get_setting() { host gsettings get "$IFACE_SCHEMA" "$1" 2>/dev/null | tr -d "'"; }
set_setting() { host gsettings set "$IFACE_SCHEMA" "$1" "$2"; }

# ---------------------------------------------------------------------------
# State, written through the portal so it lands on the host filesystem where
# the watchdog, the login unit, and your shell can all reach it.
# ---------------------------------------------------------------------------

state_write() {
    host mkdir -p "$STATE_DIR" 2>/dev/null
    printf 'connector=%s\nscale=%s\ntext_scale=%s\ncursor_size=%s\n' \
        "$1" "$2" "$3" "$4" | host sh -c "umask 077; cat > '$STATE_FILE'"
}

state_read()   { host cat "$STATE_FILE" 2>/dev/null; }
state_exists() { host test -r "$STATE_FILE"; }
state_clear()  { host rm -f "$STATE_FILE"; }

# Idempotent: safe to call from the trap, the watchdog, and the login unit,
# in any order or all at once. First one to finish clears the state.
restore_now() {
    local blob connector="" scale="" text_scale="" cursor_size=""
    blob=$(state_read) || return 1
    [[ -n "$blob" ]] || return 1
    # shellcheck disable=SC1090
    source /dev/stdin <<<"$blob"
    [[ -n "$connector" && -n "$scale" ]] || return 1

    log "restoring $connector @ $scale (text $text_scale, cursor $cursor_size)"
    if ! set_scale "$connector" "$scale"; then
        warn "FAILED to restore scale $scale on $connector — state kept for retry"
        return 1
    fi
    [[ -n "$text_scale"  ]] && set_setting text-scaling-factor "$text_scale"
    [[ -n "$cursor_size" ]] && set_setting cursor-size "$cursor_size"
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

MISSING=()
for cmd in gdctl gsettings; do
    have_host "$cmd" || MISSING+=("$cmd")
done

CAN_WATCH=1
have_host systemd-run || CAN_WATCH=0
command -v flock >/dev/null 2>&1 || CAN_WATCH=0

if [[ "$MODE" == "doctor" ]]; then
    ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; }
    bad()  { printf '  \033[31m✗\033[0m %s\n' "$1"; }
    echo "gamescale doctor"
    echo
    [[ $IN_FLATPAK == 1 ]] && ok "running sandboxed (flatpak-spawn present)" \
                           || ok "running on the host"
    [[ ${#MISSING[@]} -eq 0 ]] && ok "gdctl + gsettings reachable" \
        || bad "unreachable: ${MISSING[*]}  →  needs --talk-name=org.freedesktop.Flatpak"
    host mkdir -p "$STATE_DIR" 2>/dev/null
    if host sh -c "touch '$STATE_DIR/.probe' && rm -f '$STATE_DIR/.probe'" 2>/dev/null; then
        ok "state dir writable: $STATE_DIR"
    else
        bad "state dir NOT writable: $STATE_DIR  →  needs --filesystem=...:create"
    fi
    [[ -w "$STATE_DIR" ]] 2>/dev/null && ok "state dir writable from this side too" \
        || bad "state dir not directly writable here (watchdog lock needs this)"
    [[ $CAN_WATCH == 1 ]] && ok "watchdog available (systemd-run + flock)" \
                          || bad "watchdog unavailable — trap-only, less resilient"
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
    if detect; then ok "detected $DET_CONNECTOR @ $DET_SCALE"
    else bad "detection failed"; fi
    state_exists && bad "stale state present — run --restore" || ok "no stale state"
    exit 0
fi

if [[ ${#MISSING[@]} -gt 0 && "$MODE" != "status" ]]; then
    give_up "cannot reach ${MISSING[*]} on the host (--talk-name=org.freedesktop.Flatpak?)" "$@"
fi

if [[ "$MODE" == "status" ]]; then
    echo "sandboxed:    $([[ $IN_FLATPAK == 1 ]] && echo yes || echo no)"
    if [[ ${#MISSING[@]} -gt 0 ]]; then
        echo "host access:  MISSING ${MISSING[*]}"
        exit 1
    fi
    echo "host access:  ok"
    echo "watchdog:     $([[ $CAN_WATCH == 1 ]] && echo available || echo UNAVAILABLE)"
    echo "state dir:    $STATE_DIR"
    if detect; then
        echo "connector:    $DET_CONNECTOR"
        echo "scale:        $DET_SCALE"
    else
        echo "connector:    DETECTION FAILED"; exit 1
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

if feq "$DET_SCALE" "$GAME_SCALE"; then
    log "already at $GAME_SCALE, nothing to do"
    exec "$@"
fi

ORIG_TEXT_SCALE=$(get_setting text-scaling-factor); : "${ORIG_TEXT_SCALE:=1.0}"
ORIG_CURSOR_SIZE=$(get_setting cursor-size);        : "${ORIG_CURSOR_SIZE:=24}"

host mkdir -p "$STATE_DIR" 2>/dev/null
state_write "$DET_CONNECTOR" "$DET_SCALE" "$ORIG_TEXT_SCALE" "$ORIG_CURSOR_SIZE"

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

if ! set_scale "$DET_CONNECTOR" "$GAME_SCALE"; then
    warn "could not set scale on $DET_CONNECTOR"
    state_clear
    exec "$@"
fi

# Poor man's fractional scaling: the desktop just lost DET_SCALE worth of
# apparent size, so scale text and cursor to match. Title bars and icons won't
# follow — that's a GNOME limitation, not a bug here.
if [[ "${GAMESCALE_NO_FONT:-0}" != "1" ]]; then
    RATIO=$(fdiv "$DET_SCALE" "$GAME_SCALE")
    set_setting text-scaling-factor "$(fmul "$ORIG_TEXT_SCALE" "$RATIO")"
    set_setting cursor-size "$(fround "$(fmul "$ORIG_CURSOR_SIZE" "$RATIO")")"
    log "compensated ${RATIO}x"
fi

# Let mutter settle before the game enumerates outputs.
sleep 1

"$@"
