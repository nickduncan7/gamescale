#!/usr/bin/env bash
#
# Watchdog resilience tests — the claim the whole design rests on: a game that
# dies without running the trap still gets the display back.
#
# Drives the real script end to end with python3, gsettings and systemd-run
# stubbed on PATH, so the watchdog under test is the shipped one, started the
# way the shipped code starts it. Nothing touches a real display.
#
# The two assertions that matter are opposites, and both are load-bearing:
#
#   - while the game is alive, the watchdog must NOT restore. Restoring
#     mid-game is worse than having no watchdog at all.
#   - once the game is gone — SIGKILLed, no trap, no clean exit — it MUST
#     restore, without any cooperation from the process that died.
#
#   ./test/watchdog_test.sh

set -uo pipefail

SCRIPT="$(cd "$(dirname "$0")/.." && pwd)/gamescale.sh"
# Exported because the fake game, which gamescale launches, writes its
# started-marker there.
WORK=$(mktemp -d); export WORK

STUBS="$WORK/bin"
mkdir -p "$STUBS"
LOG="$WORK/python3.log"
RUNLOG="$WORK/systemd-run.log"
FAKEHOME=""; STATE=""; LOCK=""; CASE=0

# Every case gets its own HOME, so it gets its own state file and its own lock.
# Sharing them would make the cases race: a watchdog left over from the
# previous case holds the lock through its 2s grace period, and a gamescale
# starting inside that window can't take it, so it correctly falls back to
# trap-only — and the next case would be testing the fallback by accident.
fresh_home() {
    CASE=$((CASE + 1))
    FAKEHOME="$WORK/home$CASE"
    STATE="$FAKEHOME/.local/state/gamescale/state"
    LOCK="$FAKEHOME/.local/state/gamescale/lock"
    RUNF="$FAKEHOME/.local/state/gamescale/run"
    mkdir -p "$FAKEHOME/.local/state/gamescale"
    : > "$LOG"; : > "$RUNLOG"
}

# Kill anything still holding the lock, or the trap's rm blocks on nothing and
# a stray watchdog outlives the test run.
cleanup() { pkill -9 -f "$WORK" 2>/dev/null; rm -rf "$WORK"; }
trap cleanup EXIT

# shellcheck source=test/stubs.sh
. "$(cd "$(dirname "$0")" && pwd)/stubs.sh"
make_stubs "$STUBS"

FIXTURE=$(printf 'eDP-1\t1.3333333730697632\tyes\t0\t0\tnormal')

PASS=0; FAIL=0
ok()  { printf '  \033[32mok\033[0m   %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL + 1));
        printf '        display log: %s\n' "$(tr '\n' '|' < "$LOG")"; }

gamescale() {
    DETECT_FIXTURE="$FIXTURE" PY_LOG="$LOG" SYSTEMD_RUN_LOG="$RUNLOG" \
    HOME="$FAKEHOME" PATH="$STUBS:$PATH" \
        bash "$SCRIPT" "$@"
}

# The restore is recognisable by the saved scale coming back; applying only
# ever sends scale 1.
restored() { grep -q -- 'eDP-1;1.3333333730697632;yes' "$LOG"; }

game_started() { [[ -f "$WORK/game.started" ]]; }

# Bounded wait on a predicate, because the watchdog sleeps 2s to give the trap
# first crack at it and a fixed sleep here would either be flaky or slow.
wait_for() {
    local deadline=$((SECONDS + ${2:-15}))
    while ((SECONDS < deadline)); do "$1" && return 0; sleep 0.2; done
    return 1
}

need() {
    command -v "$1" >/dev/null 2>&1 && return 0
    echo "  SKIP: $1 not available" >&2
    exit 0
}
need flock
need setsid
need pkill

echo "watchdog resilience"
echo

# --- the watchdog restores after a SIGKILL, with no trap involvement ---------
#
# The fake game kills the wrapper first, so gamescale dies by SIGKILL with its
# EXIT trap unrun — the sandbox-teardown case, where the in-sandbox trap has no
# session bus left to restore over. Then it exits, releasing the last reference
# to the inherited lock descriptor.
fresh_home

cat > "$WORK/game" <<'GAME'
#!/bin/sh
echo started > "$WORK/game.started"
kill -9 "$PPID"
sleep 0.3
GAME
chmod +x "$WORK/game"

gamescale -- "$WORK/game" >/dev/null 2>&1

if wait_for game_started 10; then
    ok "game launched"
else
    bad "game never launched"
fi

if grep -q -- 'eDP-1;1;yes' "$LOG"; then
    ok "applied 1x before launching"
else
    bad "never applied 1x"
fi

if grep -q -- '--watchdog' "$RUNLOG"; then
    ok "watchdog started through systemd-run"
else
    bad "watchdog was never started"
fi

# The wrapper is gone and never ran its trap; only the watchdog can do this.
if wait_for restored 15; then
    ok "restored after SIGKILL, without the trap"
else
    bad "NOT restored after SIGKILL — the watchdog did not fire"
fi

if [[ -f "$STATE" ]]; then
    bad "state cleared after the watchdog restored"
else
    ok "state cleared after the watchdog restored"
fi

# --- the watchdog does NOT restore while the game is alive -------------------
#
# Same setup, but the lock holder stays up. A watchdog that wakes here would
# yank the desktop back to fractional scaling mid-game, which the README calls
# out as worse than not running one. Waits past the watchdog's 2s grace period.
fresh_home

gamescale -- sleep 8 >/dev/null 2>&1 &
runner=$!

sleep 5
if restored; then
    bad "watchdog restored while the game was still running"
else
    ok "no restore while the game holds the lock"
fi
if [[ -f "$STATE" ]]; then
    ok "state kept while the game runs"
else
    bad "state cleared while the game was still running"
fi

# Let it exit normally: the trap should handle this one, and quickly.
wait "$runner" 2>/dev/null
if wait_for restored 10; then
    ok "restored on normal exit"
else
    bad "NOT restored on normal exit"
fi

# --- a stranded state file is reconciled on the next launch ------------------
#
# Covers the login unit's job without needing systemd: --restore is what it
# runs. A state file that survives means the desktop is sitting at 1x.
fresh_home
cat > "$STATE" <<'EOF'
version=2
text_scale=1.0
cursor_size=24
monitor=eDP-1;1.5;yes;0;0;normal
EOF
gamescale --restore >/dev/null 2>&1
if grep -q -- 'eDP-1;1.5;yes' "$LOG"; then
    ok "--restore replays a stranded state file"
else
    bad "--restore did not replay the stranded state"
fi

# --- the lock is actually held, not just created ----------------------------
# The README tells you to check this by hand; check it here too.
fresh_home
gamescale -- sleep 6 >/dev/null 2>&1 &
runner=$!
sleep 2
if flock -n "$LOCK" -c true 2>/dev/null; then
    bad "lock was free while a game was running"
else
    ok "lock is held for the lifetime of the launch chain"
fi
kill -9 "$runner" 2>/dev/null
wait "$runner" 2>/dev/null

# --- a watchdog only acts on the state its own run wrote --------------------
#
# Quit game A: its trap restores and clears state, and A's watchdog wakes and
# enters its 2s grace period. Launch game B inside that window and B writes its
# own state. Without a run token the waking watchdog sees a state file, assumes
# it is A's, and restores it — reverting B's display mid-launch and deleting the
# record B depends on. A silent, total failure.
fresh_home
cat > "$STATE" <<'EOF'
version=2
text_scale=1.0
cursor_size=24
monitor=eDP-1;1.5;yes;0;0;normal
EOF
echo run-B > "$RUNF"
DETECT_FIXTURE="$FIXTURE" PY_LOG="$LOG" HOME="$FAKEHOME" PATH="$STUBS:$PATH" \
    bash "$SCRIPT" --watchdog run-A >/dev/null 2>&1
if grep -q -- 'eDP-1;1.5;yes' "$LOG"; then
    bad "watchdog restored another run's state"
else
    ok "watchdog leaves another run's state alone"
fi
if [[ -f "$STATE" ]]; then
    ok "watchdog keeps another run's state file"
else
    bad "watchdog deleted another run's state file"
fi

# The same watchdog, for the run that actually wrote the file, must still act.
fresh_home
cat > "$STATE" <<'EOF'
version=2
text_scale=1.0
cursor_size=24
monitor=eDP-1;1.5;yes;0;0;normal
EOF
echo run-A > "$RUNF"
DETECT_FIXTURE="$FIXTURE" PY_LOG="$LOG" HOME="$FAKEHOME" PATH="$STUBS:$PATH" \
    bash "$SCRIPT" --watchdog run-A >/dev/null 2>&1
if grep -q -- 'eDP-1;1.5;yes' "$LOG"; then
    ok "watchdog restores its own run's state"
else
    bad "watchdog ignored its own run's state"
fi

# A 1.4.0 state file carried the token inside itself. It must still restore, and
# the key must not be mistaken for corruption.
fresh_home
cat > "$STATE" <<'EOF'
version=2
text_scale=1.0
cursor_size=24
run=run-Z
monitor=eDP-1;1.5;yes;0;0;normal
EOF
DETECT_FIXTURE="$FIXTURE" PY_LOG="$LOG" HOME="$FAKEHOME" PATH="$STUBS:$PATH" \
    bash "$SCRIPT" --watchdog run-A >/dev/null 2>&1
if grep -q -- 'eDP-1;1.5;yes' "$LOG"; then
    ok "a 1.4.0 state file still restores"
else
    bad "a 1.4.0 state file was refused"
fi

# A state file with no token at all still gets restored, rather than being
# stranded because it cannot prove ownership.
fresh_home
cat > "$STATE" <<'EOF'
version=2
text_scale=1.0
cursor_size=24
monitor=eDP-1;1.5;yes;0;0;normal
EOF
DETECT_FIXTURE="$FIXTURE" PY_LOG="$LOG" HOME="$FAKEHOME" PATH="$STUBS:$PATH" \
    bash "$SCRIPT" --watchdog run-A >/dev/null 2>&1
if grep -q -- 'eDP-1;1.5;yes' "$LOG"; then
    ok "an untagged state file is still restored"
else
    bad "an untagged state file was stranded"
fi

# --- timing out means the game is STILL RUNNING, so do not restore ----------
# The ceiling exists so the unit cannot live forever. Restoring on the way out
# would yank the desktop out from under a game that is still going, and clear
# the state so the real exit had nothing left to put back.
fresh_home
cat > "$STATE" <<'EOF'
version=2
text_scale=1.0
cursor_size=24
monitor=eDP-1;1.5;yes;0;0;normal
EOF
echo run-A > "$RUNF"
# Something else holds the lock for longer than the watchdog will wait.
flock -x "$LOCK" -c 'sleep 6' &
holder=$!
sleep 0.5
DETECT_FIXTURE="$FIXTURE" PY_LOG="$LOG" HOME="$FAKEHOME" PATH="$STUBS:$PATH" \
GAMESCALE_WATCHDOG_TIMEOUT=1 \
    bash "$SCRIPT" --watchdog run-A >/dev/null 2>&1
rc=$?
if [[ $rc -ne 0 ]]; then
    ok "watchdog that timed out reports failure"
else
    bad "watchdog that timed out claimed success"
fi
if grep -q -- 'eDP-1;1.5;yes' "$LOG"; then
    bad "watchdog restored while the game still held the lock"
else
    ok "watchdog does not restore after timing out"
fi
if [[ -f "$STATE" ]]; then
    ok "watchdog keeps the state after timing out"
else
    bad "watchdog cleared the state after timing out"
fi
kill -9 "$holder" 2>/dev/null; wait "$holder" 2>/dev/null

echo
echo "  $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
