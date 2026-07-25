#!/usr/bin/env bash
#
# Watchdog resilience tests — the claim the whole design rests on: a game that
# dies without running the trap still gets the display back.
#
# Drives the real script end to end with gdctl, gsettings and systemd-run
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
LOG="$WORK/gdctl.log"
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
    mkdir -p "$FAKEHOME/.local/state/gamescale"
    : > "$LOG"; : > "$RUNLOG"
}

# Kill anything still holding the lock, or the trap's rm blocks on nothing and
# a stray watchdog outlives the test run.
cleanup() { pkill -9 -f "$WORK" 2>/dev/null; rm -rf "$WORK"; }
trap cleanup EXIT

cat > "$STUBS/gdctl" <<'STUB'
#!/bin/sh
echo "$*" >> "$GDCTL_LOG"
exit 0
STUB

# Stands in for the python reader; detect_test.py covers the real one. Consumes
# stdin because the script pipes the reader source into it.
cat > "$STUBS/python3" <<'STUB'
#!/bin/sh
cat >/dev/null
printf '%s\n' "$DETECT_FIXTURE"
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

# Stands in for systemd's job supervision: drop the flags the real invocation
# passes and run the rest detached, so it survives the process that started it.
# setsid is what makes that true here, the way "systemd owns the unit" makes it
# true in production.
cat > "$STUBS/systemd-run" <<'STUB'
#!/bin/sh
echo "$*" >> "$SYSTEMD_RUN_LOG"
while [ $# -gt 0 ]; do
    case "$1" in
        --user|--collect|--quiet|--unit=*) shift ;;
        *) break ;;
    esac
done
setsid "$@" >/dev/null 2>&1 &
exit 0
STUB

chmod +x "$STUBS/gdctl" "$STUBS/gsettings" "$STUBS/systemd-run" "$STUBS/python3"

FIXTURE=$(printf 'eDP-1\t1.3333333730697632\tyes\t0\t0\tnormal')

PASS=0; FAIL=0
ok()  { printf '  \033[32mok\033[0m   %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL + 1));
        printf '        gdctl log: %s\n' "$(tr '\n' '|' < "$LOG")"; }

gamescale() {
    DETECT_FIXTURE="$FIXTURE" GDCTL_LOG="$LOG" SYSTEMD_RUN_LOG="$RUNLOG" \
    HOME="$FAKEHOME" PATH="$STUBS:$PATH" \
        bash "$SCRIPT" "$@"
}

# The restore is recognisable by the saved scale coming back; applying only
# ever sends --scale 1.
restored() { grep -q -- '--scale 1.3333333730697632' "$LOG"; }

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

if grep -q -- '--scale 1 ' "$LOG"; then
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
if grep -q -- '--scale 1.5' "$LOG"; then
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

echo
echo "  $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
