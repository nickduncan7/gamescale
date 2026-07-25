#!/usr/bin/env bash
#
# State format and record-building tests.
#
# Stubs python3 so every call to the display program is recorded instead of run,
# then asserts on the exact records the script would have handed it. Nothing
# touches a real display. This is the part worth testing hardest: a
# configuration replaces the whole layout, so a monitor missing from the records
# is a monitor switched off.
#
# What the program does WITH those records — the packing arithmetic, mode
# selection, verify-before-apply, the D-Bus payload — is tested against real
# mutter replies in apply_test.py and detect_test.py. What is under test here is
# everything on the shell side: the arrays, the state file, and the records
# built from them.
#
#   ./test/state_test.sh

set -uo pipefail

SCRIPT="$(cd "$(dirname "$0")/.." && pwd)/gamescale.sh"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

STUBS="$WORK/bin"; FAKEHOME="$WORK/home"
mkdir -p "$STUBS" "$FAKEHOME/.local/state/gamescale"
STATE="$FAKEHOME/.local/state/gamescale/state"
LOG="$WORK/python3.log"

# Records every invocation of the display program, and answers `read` with the
# fixture. The program itself arrives on stdin, so the stub has to consume it or
# the writer gets EPIPE.
# Stands in for the display program, and rejects what mutter would reject: a
# configuration naming a connector that is not present. That is what makes the
# unplugged-monitor fallback testable — without it every apply "succeeds" and
# the retry path is never entered.
cat > "$STUBS/python3" <<'STUB'
#!/bin/sh
cat >/dev/null
echo "$*" >> "$PY_LOG"
[ "${1:-}" = "-" ] && shift
cmd="${1:-read}"
if [ "$cmd" = "read" ]; then
    printf '%s\n' "$DETECT_FIXTURE"
    exit 0
fi
shift
present=" $(printf '%s\n' "$DETECT_FIXTURE" | cut -f1 | tr ',' ' ' | tr '\n' ' ') "
for rec in "$@"; do
    case "$rec" in --*) continue ;; esac
    for conn in $(printf '%s' "$rec" | cut -d';' -f1 | tr ',' ' '); do
        case "$present" in
            *" $conn "*) ;;
            *) exit 2 ;;
        esac
    done
done
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

chmod +x "$STUBS/gsettings" "$STUBS/python3"

# conns \t scale \t primary \t x \t y \t transform, one per logical monitor.
# HDMI-1 first and non-primary, so nothing can pass by assuming the primary
# comes first or that mutter's order is the layout order.
TWO_MONITORS=$(printf '%s\n' \
    "$(printf 'HDMI-1\t1.3333333730697632\tno\t1920\t0\tnormal')" \
    "$(printf 'eDP-1\t1.3333333730697632\tyes\t0\t0\tnormal')")

PASS=0; FAIL=0

run() {  # run MODE-ARGS... ; returns exit status, fills $LOG
    : > "$LOG"
    DETECT_FIXTURE="$TWO_MONITORS" PY_LOG="$LOG" \
    GAMESCALE_NO_WATCH=1 HOME="$FAKEHOME" PATH="$STUBS:$PATH" \
        bash "$SCRIPT" "$@" >/dev/null 2>&1
}

# What was handed to the display program, minus the `read` calls. A full run
# logs two: the 1x apply on the way in, and the restore on the way out.
applied() { grep -E '^- (apply|verify)' "$LOG"; }
packed()  { applied | grep -- '--pack'; }

ok()   { printf '  \033[32mok\033[0m   %s\n' "$1"; PASS=$((PASS + 1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL + 1)); }
want() { if applied | grep -q -- "$2"; then ok "$1"; else
             bad "$1"; printf '        log: %s\n' "$(cat "$LOG")"; fi }
wantnot() { if applied | grep -q -- "$2"; then
             bad "$1"; printf '        log: %s\n' "$(cat "$LOG")"; else ok "$1"; fi }

echo "state format and generated configuration"
echo

# --- apply: every monitor goes to 1x -------------------------------------
# The whole point of v1.1.0. Scaling only the primary leaves XWayland's global
# factor at 2 and costs MORE pixels than not running at all.
run -- true
want "apply: primary at 1x"                 "eDP-1;1;yes;"
want "apply: secondary at 1x too"           "HDMI-1;1;no;"
want "apply: laid out afresh, not replayed" "apply --pack"
# The scale being replaced is the whole point; the saved one belongs only in the
# restore call, which the same run also logs.
if packed | grep -q '1.3333333730697632'; then
    bad "apply: saved scale not reused"
    printf '        sent: %s\n' "$(packed)"
else
    ok "apply: saved scale not reused"
fi

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
    "eDP-1;1.3333333730697632;yes;0;0;normal"
want "restore: secondary replayed too" \
    "HDMI-1;1.3333333730697632;no;1920;0;normal"
wantnot "restore: coordinates replayed, not repacked" "--pack"
if [[ -f "$STATE" ]]; then
    bad "restore: state cleared on success"
else
    ok "restore: state cleared on success"
fi

# --- malformed input fails closed ----------------------------------------
reject() {
    printf '%b' "$2" > "$STATE"
    run --restore
    if [[ -n "$(applied)" ]]; then
        bad "reject $1"; printf '        sent: %s\n' "$(applied)"
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
# A connector can drive only one logical monitor, so mutter refuses these
# forever. Replaying one means retrying forever and never getting the desktop
# back, which is worse than handing it to a human.
reject "duplicate record"      'version=2\nmonitor=eDP-1;1.5;yes;0;0;normal\nmonitor=eDP-1;1.5;no;0;0;normal\n'
reject "connector twice in one record" 'version=2\nmonitor=eDP-1,eDP-1;1.5;yes;0;0;normal\n'
reject "connector in two records" 'version=2\nmonitor=eDP-1,HDMI-1;1.5;yes;0;0;normal\nmonitor=HDMI-1;1.5;no;0;0;normal\n'
reject "bad run token"         'version=2\nmonitor=eDP-1;1.5;yes;0;0;normal\nrun=a b\n'
reject "future version"        'version=3\nmonitor=eDP-1;1.5;yes;0;0;normal\n'
reject "too few fields"        'version=2\nmonitor=eDP-1;1.5;yes\n'
reject "bad transform"         'version=2\nmonitor=eDP-1;1.5;yes;0;0;sideways\n'
reject "non-numeric position"  'version=2\nmonitor=eDP-1;1.5;yes;left;0;normal\n'
reject "connector metachars"   'version=2\nmonitor=eDP-1;rm -rf;yes;0;0;normal\n'

# --- a monitor unplugged mid-game: drop the connector, keep the rest -------
#
# You play mirrored across two panels and one goes away. The saved record names
# both, and a configuration is refused if ANY connector in it is absent — so a
# fallback that tests only the record's first connector re-sends the very record
# that was just rejected, fails identically on every retry, and leaves the
# desktop at 1x for good. All three layers retry, so "for good" is literal.
: > "$LOG"
cat > "$STATE" <<'EOF'
version=2
text_scale=1.0
cursor_size=24
monitor=eDP-1,HDMI-1;1.3333333730697632;yes;0;0;normal
EOF
DETECT_FIXTURE=$(printf 'eDP-1\t1\tyes\t0\t0\tnormal') PY_LOG="$LOG" \
GAMESCALE_NO_WATCH=1 HOME="$FAKEHOME" PATH="$STUBS:$PATH" \
    bash "$SCRIPT" --restore >/dev/null 2>&1
if applied | grep -q -- '--pack eDP-1;1.3333333730697632'; then
    ok "survivor: the absent connector is dropped, the present one replayed"
else
    bad "survivor: never retried with just the connected monitor"
    printf '        sent: %s\n' "$(applied)"
fi
if [[ -f "$STATE" ]]; then
    bad "survivor: state cleared once the display was restored"
else
    ok "survivor: state cleared once the display was restored"
fi

# --- the state file names the run that wrote it ---------------------------
# Without it a watchdog still finishing its grace period cannot tell the state
# it was started for from the next game's, and restores the wrong one.
: > "$LOG"; rm -f "$STATE"
DETECT_FIXTURE="$TWO_MONITORS" PY_LOG="$LOG" GAMESCALE_NO_WATCH=1 \
HOME="$FAKEHOME" PATH="$STUBS:$PATH" \
    bash "$SCRIPT" -- sh -c "cat '$STATE' > '$WORK/during'" >/dev/null 2>&1
if grep -qE '^run=[0-9A-Za-z-]+$' "$WORK/during" 2>/dev/null; then
    ok "state names the run that wrote it"
else
    bad "state has no run token"
    printf '        state was: %s\n' "$(tr '\n' '|' < "$WORK/during" 2>/dev/null)"
fi

# --- a second run does not touch the first one's display ------------------
# Two games at once means two owners of one display. Refusing is the only safe
# answer: the alternative reverted the running game and deleted its state.
: > "$LOG"; rm -f "$STATE"
DETECT_FIXTURE="$TWO_MONITORS" PY_LOG="$LOG" GAMESCALE_NO_WATCH=1 \
HOME="$FAKEHOME" PATH="$STUBS:$PATH" \
    bash "$SCRIPT" -- sleep 6 >/dev/null 2>&1 &
first=$!
sleep 1
: > "$LOG"
second_out=$(DETECT_FIXTURE="$TWO_MONITORS" PY_LOG="$LOG" GAMESCALE_NO_WATCH=1 \
    HOME="$FAKEHOME" PATH="$STUBS:$PATH" \
    bash "$SCRIPT" -- true 2>&1)
if [[ -n "$(applied)" ]]; then
    bad "second run left the first one's display alone"
    printf '        sent: %s\n' "$(applied)"
else
    ok "second run left the first one's display alone"
fi
if [[ "$second_out" == *"another gamescale"* ]]; then
    ok "second run says why it did not scale"
else
    bad "second run gave no reason"
    printf '        said: %s\n' "$second_out"
fi
if [[ -f "$STATE" ]]; then
    ok "second run did not delete the first one's state"
else
    bad "second run deleted the first one's state"
fi
kill -9 "$first" 2>/dev/null; wait "$first" 2>/dev/null

echo
echo "  $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
