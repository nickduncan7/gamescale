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
LOCK="$FAKEHOME/.local/state/gamescale/lock"
RUNF="$FAKEHOME/.local/state/gamescale/run"
LOG="$WORK/python3.log"

# Records every invocation of the display program, and answers `read` with the
# fixture. The program itself arrives on stdin, so the stub has to consume it or
# the writer gets EPIPE.
# shellcheck source=test/stubs.sh
. "$(cd "$(dirname "$0")" && pwd)/stubs.sh"
make_stubs "$STUBS"

# conns \t scale \t primary \t x \t y \t transform, one per logical monitor.
# HDMI-1 first and non-primary, so nothing can pass by assuming the primary
# comes first or that mutter's order is the layout order.
TWO_MONITORS=$(printf '%s\n' \
    "$(printf 'HDMI-1\t1.3333333730697632\tno\t1920\t0\tnormal')" \
    "$(printf 'eDP-1\t1.3333333730697632\tyes\t0\t0\tnormal')")

PASS=0; FAIL=0

GS_LOG="$WORK/gsettings.log"

run() {  # run MODE-ARGS... ; returns exit status, fills $LOG and $GS_LOG
    : > "$LOG"; : > "$GS_LOG"
    env DETECT_FIXTURE="$TWO_MONITORS" PY_LOG="$LOG" GS_LOG="$GS_LOG" \
        GAMESCALE_NO_WATCH=1 HOME="$FAKEHOME" PATH="$STUBS:$PATH" "$@" \
        >/dev/null 2>&1
}

# run, plus whatever extra environment a case needs, e.g. PY_FAIL_RC=2.
gs() { run bash "$SCRIPT" "$@"; }

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
gs -- true
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
gs --restore
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
    gs --restore
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

# --- the run that wrote the state is identified, without touching the format --
# A watchdog finishing its grace period has to tell the state it was started for
# from the next game's. Keeping that token in a SIBLING file rather than in the
# state means the format older copies parse strictly never changed.
: > "$LOG"; rm -f "$STATE"
env DETECT_FIXTURE="$TWO_MONITORS" PY_LOG="$LOG" GS_LOG="$GS_LOG" \
    GAMESCALE_NO_WATCH=1 HOME="$FAKEHOME" PATH="$STUBS:$PATH" \
    bash "$SCRIPT" -- sh -c "cat '$STATE' > '$WORK/during'; cat '$RUNF' > '$WORK/during.run'; stat -c %a '$STATE' > '$WORK/during.mode'" \
    >/dev/null 2>&1
if grep -qE '^[0-9A-Za-z-]+$' "$WORK/during.run" 2>/dev/null; then
    ok "the run is identified in a sibling file"
else
    bad "no run token was written"
fi
if grep -q '^run=' "$WORK/during" 2>/dev/null; then
    bad "state format left unchanged by the run token"
else
    ok "state format left unchanged by the run token"
fi
# The whole state file, asserted as a literal. Nothing else read one back, and a
# mutant that wrote only the first monitor survived the entire suite — which on
# two monitors means restore switches the other display OFF.
{
    printf 'version=2\ntext_scale=1.0\ncursor_size=24\n'
    printf 'monitor=HDMI-1;1.3333333730697632;no;1920;0;normal\n'
    printf 'monitor=eDP-1;1.3333333730697632;yes;0;0;normal\n'
} > "$WORK/expected"
if diff -q "$WORK/expected" "$WORK/during" >/dev/null 2>&1; then
    ok "state records every monitor, exactly"
else
    bad "state does not match what was detected"
    diff "$WORK/expected" "$WORK/during" 2>&1 | sed 's/^/        /'
fi
# The mode of the live file, not of a copy this test made — the copy would carry
# the test shell's umask and pass or fail for the wrong reason.
if [[ "$(cat "$WORK/during.mode" 2>/dev/null)" == "600" ]]; then
    ok "state is not world-readable"
else
    bad "state mode is $(cat "$WORK/during.mode" 2>/dev/null), want 600"
fi
if [[ -e "$STATE.new" ]]; then
    bad "the write-and-rename temp file was left behind"
else
    ok "no temp file left behind"
fi

# --- a second run does not touch the first one's display ------------------
# Two games at once means two owners of one display. Refusing is the only safe
# answer: the alternative reverted the running game and deleted its state.
: > "$LOG"; rm -f "$STATE"
env DETECT_FIXTURE="$TWO_MONITORS" PY_LOG="$LOG" GS_LOG="$GS_LOG" \
    GAMESCALE_NO_WATCH=1 HOME="$FAKEHOME" PATH="$STUBS:$PATH" \
    setsid bash "$SCRIPT" -- sleep 60 >/dev/null 2>&1 &
first=$!

# Wait for the lock to actually be taken rather than sleeping and hoping. A
# fixed sleep here made the whole case a race: on a slow runner the second run
# won the lock and the test failed for a tool that was behaving correctly.
held=0
for _ in $(seq 1 100); do
    if ! flock -n "$LOCK" -c true 2>/dev/null; then held=1; break; fi
    sleep 0.1
done
if [[ $held == 1 ]]; then
    ok "first run takes the lock before scaling"
else
    bad "first run never took the lock"
fi

SECOND_LOG="$WORK/second.log"; : > "$SECOND_LOG"
second_out=$(env DETECT_FIXTURE="$TWO_MONITORS" PY_LOG="$SECOND_LOG" GS_LOG="$GS_LOG" \
    GAMESCALE_NO_WATCH=1 HOME="$FAKEHOME" PATH="$STUBS:$PATH" \
    bash "$SCRIPT" -- true 2>&1)
if grep -qE '^- (apply|verify)' "$SECOND_LOG"; then
    bad "second run left the first one's display alone"
    printf '        sent: %s\n' "$(cat "$SECOND_LOG")"
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
# Kill the whole group, not just the wrapper: the game inherits the lock fd, so
# an orphaned `sleep` keeps holding it and every later case gets refused. That is
# the fd inheritance the watchdog depends on, seen from the other side.
kill -9 -- "-$first" 2>/dev/null; wait "$first" 2>/dev/null
for _ in $(seq 1 100); do
    flock -n "$LOCK" -c true 2>/dev/null && break
    sleep 0.1
done

# --- font and cursor compensation, in both directions ----------------------
# Half of what the user actually sees, and nothing observed it: mutants that
# never restored the font, that inverted the ratio so text SHRANK, and that
# ignored GAMESCALE_NO_FONT all survived the whole suite.
: > "$LOG"; : > "$GS_LOG"; rm -f "$STATE"
gs -- true
if grep -q 'set org.gnome.desktop.interface text-scaling-factor 1.33333' "$GS_LOG"; then
    ok "font scaled up by the inverse of the primary's scale"
else
    bad "font not compensated"; printf '        gsettings: %s\n' "$(tr '\n' '|' < "$GS_LOG")"
fi
if grep -q 'set org.gnome.desktop.interface cursor-size 32' "$GS_LOG"; then
    ok "cursor scaled with it"
else
    bad "cursor not compensated"; printf '        gsettings: %s\n' "$(tr '\n' '|' < "$GS_LOG")"
fi
# 1.0 and 24 are what the stub reports as the originals, so seeing them set is
# the restore. A mutant that inverted the ratio also fails the checks above.
if grep -q 'set org.gnome.desktop.interface text-scaling-factor 1.0$' "$GS_LOG" \
   && grep -q 'set org.gnome.desktop.interface cursor-size 24$' "$GS_LOG"; then
    ok "font and cursor put back on exit"
else
    bad "font and cursor not restored"; printf '        gsettings: %s\n' "$(tr '\n' '|' < "$GS_LOG")"
fi

: > "$LOG"; : > "$GS_LOG"; rm -f "$STATE"
run env GAMESCALE_NO_FONT=1 bash "$SCRIPT" -- true
# The contract is that the font is never SCALED, not that gsettings is never
# called: restore still writes back the values read at startup, which with this
# flag set are the values already there. Idempotent, and correct if the flag is
# toggled between a launch and its restore.
if grep -qE 'set .*(text-scaling-factor 1\.33|cursor-size 32)' "$GS_LOG"; then
    bad "GAMESCALE_NO_FONT=1 still compensated the font"
    printf '        gsettings: %s\n' "$(tr '\n' '|' < "$GS_LOG")"
else
    ok "GAMESCALE_NO_FONT=1 never compensates the font"
fi
if applied | grep -q -- '--pack'; then
    ok "GAMESCALE_NO_FONT=1 still scales the display"
else
    bad "GAMESCALE_NO_FONT=1 stopped the scaling too"
fi

# --- a non-default GAMESCALE_SCALE is honoured -----------------------------
: > "$LOG"; rm -f "$STATE"
run env GAMESCALE_SCALE=1.5 bash "$SCRIPT" -- true
if packed | grep -q ';1.5;'; then
    ok "GAMESCALE_SCALE reaches the configuration"
else
    bad "GAMESCALE_SCALE ignored"; printf '        sent: %s\n' "$(packed)"
fi

# --- partial restore keeps the state file ----------------------------------
# The hazard the code documents at length: if the scale comes back but the font
# does not, the compensated size is still in gsettings. Clearing state there
# makes it the next run's recorded "original", compounding on every launch.
: > "$LOG"; : > "$GS_LOG"
cat > "$STATE" <<'EOF'
version=2
text_scale=1.0
cursor_size=24
monitor=eDP-1;1.5;yes;0;0;normal
monitor=HDMI-1;1.5;no;1920;0;normal
EOF
run env GS_FAIL_SET=text-scaling-factor bash "$SCRIPT" --restore
rc=$?
if [[ -f "$STATE" ]]; then
    ok "partial restore keeps the state for another layer to retry"
else
    bad "partial restore cleared the state"
fi
if [[ $rc -ne 0 ]]; then
    ok "partial restore reports failure"
else
    bad "partial restore claimed success"
fi

# --- giving up always still launches the game ------------------------------
# A failed scale flip must never be a failed game launch. The mutant that made
# give_up stop exec-ing the game survived every suite, and it turns every
# failure mode into "my game will not start from Steam".
: > "$LOG"; rm -f "$STATE"
marker="$WORK/ran"; rm -f "$marker"
run env PY_FAIL_RC=2 bash "$SCRIPT" -- touch "$marker"
if [[ -f "$marker" ]]; then
    ok "mutter refusing the layout still launches the game"
else
    bad "mutter refusing the layout stopped the game"
fi
if [[ -f "$STATE" ]]; then
    bad "state kept after nothing was applied"
else
    ok "state cleared after nothing was applied"
fi

# A state directory that cannot be written means nothing would know how to put
# the display back, so the display must not move.
: > "$LOG"; rm -f "$STATE"; rm -f "$marker"
chmod 500 "$FAKEHOME/.local/state/gamescale"
run bash "$SCRIPT" -- touch "$marker"
chmod 700 "$FAKEHOME/.local/state/gamescale"
if [[ -f "$marker" ]]; then
    ok "an unwritable state dir still launches the game"
else
    bad "an unwritable state dir stopped the game"
fi
if applied | grep -q -- '--pack'; then
    bad "display moved with nothing recording where it was"
    printf '        sent: %s\n' "$(applied)"
else
    ok "display left alone with nothing recording where it was"
fi

# A leftover state file that will not restore means the font and cursor sizes in
# gsettings may already be a previous run's compensated values.
: > "$LOG"; rm -f "$marker"
cat > "$STATE" <<'EOF'
version=2
text_scale=1.0
cursor_size=24
monitor=DP-9;1.5;yes;0;0;normal
EOF
run bash "$SCRIPT" -- touch "$marker"
if [[ -f "$marker" ]]; then
    ok "an unrestorable leftover still launches the game"
else
    bad "an unrestorable leftover stopped the game"
fi
if packed | grep -q ';1;'; then
    bad "scaled anyway, on top of a failed restore"
    printf '        sent: %s\n' "$(packed)"
else
    ok "does not scale on top of a failed restore"
fi
rm -f "$STATE"

echo
echo "  $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
