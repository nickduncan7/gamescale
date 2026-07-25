#!/usr/bin/env bash
#
# State format and gdctl config-building tests.
#
# Stubs gdctl so every `set` is recorded instead of applied, then asserts on
# the exact configuration the script would have sent. Nothing touches a real
# display. This is the part worth testing hardest: gdctl set REPLACES the whole
# configuration, so a monitor missing from a generated command is a monitor
# switched off.
#
#   ./test/state_test.sh

set -uo pipefail

SCRIPT="$(cd "$(dirname "$0")/.." && pwd)/gamescale.sh"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

STUBS="$WORK/bin"; FAKEHOME="$WORK/home"
mkdir -p "$STUBS" "$FAKEHOME/.local/state/gamescale"
STATE="$FAKEHOME/.local/state/gamescale/state"
LOG="$WORK/gdctl.log"

cat > "$STUBS/gdctl" <<'STUB'
#!/bin/sh
if [ "$1" = "show" ]; then printf '%s\n' "$GDCTL_FIXTURE"; exit 0; fi
echo "$*" >> "$GDCTL_LOG"
exit 0
STUB

cat > "$STUBS/gsettings" <<'STUB'
#!/bin/sh
[ "$1" = "set" ] && exit 0
case "$3" in
    text-scaling-factor) echo "1.0" ;;
    cursor-size)         echo "24" ;;
esac
STUB

chmod +x "$STUBS/gdctl" "$STUBS/gsettings"

TWO_MONITORS=$(printf '%s\n' \
    'Logical monitors:' \
    '├──Logical monitor #1' \
    '│  ├──Position: (1920, 0)' \
    '│  ├──Scale: 1.3333333730697632' \
    '│  ├──Transform: normal' \
    '│  ├──Primary: no' \
    '│  └──Monitors: (1)' \
    '│      └──HDMI-1 (RTK 16")' \
    '└──Logical monitor #2' \
    '   ├──Position: (0, 0)' \
    '   ├──Scale: 1.3333333730697632' \
    '   ├──Transform: normal' \
    '   ├──Primary: yes' \
    '   └──Monitors: (1)' \
    '       └──eDP-1 (Built-in display)')

PASS=0; FAIL=0

run() {  # run MODE-ARGS... ; returns exit status, fills $LOG
    : > "$LOG"
    GDCTL_FIXTURE="$TWO_MONITORS" GDCTL_LOG="$LOG" \
    GAMESCALE_NO_WATCH=1 HOME="$FAKEHOME" PATH="$STUBS:$PATH" \
        bash "$SCRIPT" "$@" >/dev/null 2>&1
}

ok()   { printf '  \033[32mok\033[0m   %s\n' "$1"; PASS=$((PASS + 1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL + 1)); }
want() { if grep -q -- "$2" "$LOG"; then ok "$1"; else
             bad "$1"; printf '        log: %s\n' "$(cat "$LOG")"; fi }
wantnot() { if grep -q -- "$2" "$LOG"; then
             bad "$1"; printf '        log: %s\n' "$(cat "$LOG")"; else ok "$1"; fi }

echo "state format and generated configuration"
echo

# --- apply: every monitor goes to 1x -------------------------------------
# The whole point of v1.1.0. Scaling only the primary leaves XWayland's global
# factor at 2 and costs MORE pixels than not running at all.
run -- true
want "apply: verified before applying"      "set --verify"
want "apply: primary at 1x"                 "--primary --monitor eDP-1 --scale 1 "
want "apply: secondary at 1x too"           "--monitor HDMI-1 --scale 1 "
want "apply: layout rebuilt relationally"   "--right-of eDP-1"
wantnot "apply: no stale absolute coords"   "--scale 1 --transform normal --x 1920"

# --- state file written in v2 form ---------------------------------------
# Write a v2 state by hand and check restore replays it exactly.
cat > "$STATE" <<'EOF'
version=2
text_scale=1.0
cursor_size=24
monitor=eDP-1;1.3333333730697632;yes;0;0;normal
monitor=HDMI-1;1.3333333730697632;no;1920;0;normal
EOF
run --restore
want "restore: primary replayed at saved scale" \
    "--primary --monitor eDP-1 --scale 1.3333333730697632"
want "restore: secondary replayed too"      "--monitor HDMI-1 --scale 1.3333333730697632"
want "restore: exact coordinates"           "--x 1920 --y 0"
wantnot "restore: not relational"           "--right-of"
if [[ -f "$STATE" ]]; then
    bad "restore: state cleared on success"
else
    ok "restore: state cleared on success"
fi

# --- malformed input fails closed ----------------------------------------
reject() {
    printf '%b' "$2" > "$STATE"
    run --restore
    if [[ -s "$LOG" ]]; then
        bad "reject $1"; printf '        sent: %s\n' "$(cat "$LOG")"
    elif [[ ! -f "$STATE" ]]; then
        bad "reject $1 (state deleted rather than kept)"
    else
        ok "reject $1"
    fi
}

# Unexpanded on purpose: the point is that the parser never expands it either.
# shellcheck disable=SC2016
reject "command substitution"  'version=2\nmonitor=eDP-1;$(touch /tmp/x);yes;0;0;normal\n'
reject "unknown key"           'version=2\nmonitor=eDP-1;1.5;yes;0;0;normal\nevil=1\n'
# v1's format (1.0.1 and earlier) is no longer understood, and an unreadable
# state file is refused rather than guessed at.
reject "v1 state file"         'connector=eDP-1\nscale=1.5\ntext_scale=1.0\n'
reject "future version"        'version=3\nmonitor=eDP-1;1.5;yes;0;0;normal\n'
reject "too few fields"        'version=2\nmonitor=eDP-1;1.5;yes\n'
reject "bad transform"         'version=2\nmonitor=eDP-1;1.5;yes;0;0;sideways\n'
reject "non-numeric position"  'version=2\nmonitor=eDP-1;1.5;yes;left;0;normal\n'
reject "connector metachars"   'version=2\nmonitor=eDP-1;rm -rf;yes;0;0;normal\n'

echo
echo "  $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
