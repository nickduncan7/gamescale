#!/usr/bin/env bash
#
# Sandboxed-branch and --doctor tests.
#
# Inside a Flatpak, every command that touches the session has to go out through
# `flatpak-spawn --host`. Nothing tested that, because the branch is chosen by
# the presence of /.flatpak-info and there was no way to fake it — so the one
# code path every Flatpak user takes was the one path no suite could reach. A
# command added without routing it through host() works perfectly on the
# developer's desktop and never comes back inside the sandbox.
#
# GAMESCALE_FLATPAK_INFO exists for this, and for nothing else.
#
#   ./test/sandbox_test.sh

set -uo pipefail

SCRIPT="$(cd "$(dirname "$0")/.." && pwd)/gamescale.sh"
WORK=$(mktemp -d)
trap 'pkill -9 -f "$WORK" 2>/dev/null; rm -rf "$WORK"' EXIT

STUBS="$WORK/bin"; FAKEHOME="$WORK/home"
mkdir -p "$STUBS" "$FAKEHOME/.local/state/gamescale"
STATE="$FAKEHOME/.local/state/gamescale/state"
LOG="$WORK/python3.log"
GS_LOG="$WORK/gsettings.log"
SPAWN_LOG="$WORK/spawn.log"
FAKE_INFO="$WORK/flatpak-info"
: > "$FAKE_INFO"

# shellcheck source=test/stubs.sh
. "$(cd "$(dirname "$0")" && pwd)/stubs.sh"
make_stubs "$STUBS"

FIXTURE=$(printf 'eDP-1\t1.3333333730697632\tyes\t0\t0\tnormal')

PASS=0; FAIL=0
ok()  { printf '  \033[32mok\033[0m   %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL + 1)); }

# doctor inspects the sandbox PATH for the stock entries and for the directory
# the script was invoked from, so a simulated sandbox has to look like one.
SANDBOX_PATH="$STUBS:$(dirname "$SCRIPT"):/app/bin:/app/utils/bin:/usr/bin:/bin"

sandboxed() {  # sandboxed gamescale args...
    : > "$LOG"; : > "$GS_LOG"; : > "$SPAWN_LOG"
    env DETECT_FIXTURE="$FIXTURE" PY_LOG="$LOG" GS_LOG="$GS_LOG" \
        SPAWN_LOG="$SPAWN_LOG" GAMESCALE_FLATPAK_INFO="$FAKE_INFO" \
        GAMESCALE_NO_WATCH=1 HOME="$FAKEHOME" PATH="$SANDBOX_PATH" \
        bash "$SCRIPT" "$@" 2>&1
}

echo "sandboxed branch and doctor"
echo

# --- the sandbox is detected, and everything goes out through the portal -----
out=$(sandboxed --status)
if [[ "$out" == *"sandboxed:    yes"* ]]; then
    ok "the sandbox is detected"
else
    bad "the sandbox was not detected"; printf '        %s\n' "$out"
fi

if [[ -s "$SPAWN_LOG" ]]; then
    ok "commands are routed through flatpak-spawn --host"
else
    bad "nothing went through flatpak-spawn"
fi

# Each of these has to reach the host, and each reached it by a different route:
# a plain command, a `sh -c` capture, and the display program on stdin.
for expected in "printf" "gsettings" "python3"; do
    if grep -q -- "$expected" "$SPAWN_LOG"; then
        ok "$expected reaches the host"
    else
        bad "$expected did not reach the host"
        printf '        spawned: %s\n' "$(tr '\n' '|' < "$SPAWN_LOG")"
    fi
done

# --- a full run inside the sandbox --------------------------------------------
rm -f "$STATE"
sandboxed -- true >/dev/null 2>&1
if grep -q -- 'apply --pack eDP-1;1;yes' "$LOG"; then
    ok "the 1x layout is applied from inside the sandbox"
else
    bad "no configuration was applied"; printf '        %s\n' "$(cat "$LOG")"
fi
if grep -q 'set org.gnome.desktop.interface text-scaling-factor 1.33333' "$GS_LOG"; then
    ok "font compensation reaches the host session"
else
    bad "font was not compensated"; printf '        %s\n' "$(tr '\n' '|' < "$GS_LOG")"
fi
if grep -q -- 'eDP-1;1.3333333730697632;yes' "$LOG"; then
    ok "the display is restored on exit"
else
    bad "the display was not restored"
fi
if [[ -f "$STATE" ]]; then
    bad "state cleared after a sandboxed run"
else
    ok "state cleared after a sandboxed run"
fi

# --- no flatpak-spawn means no way to reach the session ----------------------
# The game still has to start. This used to be unreachable in tests.
rm -f "$STATE"
NOSPAWN="$WORK/nospawn"; mkdir -p "$NOSPAWN"
cp "$STUBS/python3" "$STUBS/gsettings" "$NOSPAWN/"

# The script finds flatpak-spawn with `command -v`, so "missing" has to mean
# missing from PATH — and PATH still has to carry the coreutils the run uses.
# A symlink mirror of /usr/bin with the one binary removed gives both. Naming
# /usr/bin directly here instead passed only on runners that happen not to have
# flatpak installed, and failed on any developer machine that does.
SANE="$WORK/nospawn-bin"; mkdir -p "$SANE"
cp -rs /usr/bin/. "$SANE/" 2>/dev/null || true
rm -f "$SANE/flatpak-spawn"
if PATH="$NOSPAWN:$SANE" command -v flatpak-spawn >/dev/null 2>&1; then
    bad "test setup: flatpak-spawn still reachable, case is meaningless"
fi

marker="$WORK/ran"; rm -f "$marker"
out=$(env DETECT_FIXTURE="$FIXTURE" PY_LOG="$LOG" \
    GAMESCALE_FLATPAK_INFO="$FAKE_INFO" GAMESCALE_NO_WATCH=1 \
    HOME="$FAKEHOME" PATH="$NOSPAWN:$SANE" \
    bash "$SCRIPT" -- touch "$marker" 2>&1)
if [[ -f "$marker" ]]; then
    ok "no flatpak-spawn still launches the game"
else
    bad "no flatpak-spawn stopped the game"; printf '        %s\n' "$out"
fi
if [[ "$out" == *"flatpak-spawn is missing"* ]]; then
    ok "no flatpak-spawn says why"
else
    bad "no flatpak-spawn gave no reason"; printf '        %s\n' "$out"
fi

# --- doctor ------------------------------------------------------------------
# Its exit status is a contract: install.sh runs it as the final verification,
# and the summary it prints tells the user how many things are wrong.
rm -f "$STATE"
out=$(sandboxed --doctor); rc=$?
if [[ $rc -eq 0 ]]; then
    ok "doctor exits 0 when everything is reachable"
else
    bad "doctor exited $rc on a healthy setup"; printf '%s\n' "$out" | sed 's/^/        /'
fi
if [[ "$out" == *"gsettings + python3 reachable"* && "$out" == *"PyGObject present"* ]]; then
    ok "doctor reports the dependencies it actually uses"
else
    bad "doctor did not report its dependencies"
fi
if [[ "$out" == *"layout for 1 monitor(s) verifies"* ]]; then
    ok "doctor verifies the layout it would apply, even on one monitor"
else
    bad "doctor skipped verifying the layout"; printf '%s\n' "$out" | sed 's/^/        /'
fi

# One failure must be reported as one failure. The explanation line used to call
# the failure counter again, so a single rejected layout reported two.
out=$(env DETECT_FIXTURE="$FIXTURE" PY_LOG="$LOG" GS_LOG="$GS_LOG" \
    PY_FAIL_RC=2 HOME="$FAKEHOME" PATH="$STUBS:/usr/bin:/bin" \
    bash "$SCRIPT" --doctor 2>&1); rc=$?
if [[ $rc -ne 0 ]]; then
    ok "doctor fails when mutter refuses the layout"
else
    bad "doctor passed while the layout was refused"
fi
if [[ "$out" == *"1 check(s) failed"* ]]; then
    ok "one problem is counted once"
else
    bad "one problem was miscounted"
    printf '%s\n' "$out" | grep -E 'check\(s\) failed' | sed 's/^/        /'
fi

# A stale state file is a problem doctor must name, since it means the display is
# probably sitting at 1x right now.
cat > "$STATE" <<'EOF'
version=2
text_scale=1.0
cursor_size=24
monitor=eDP-1;1.5;yes;0;0;normal
EOF
out=$(sandboxed --doctor); rc=$?
rm -f "$STATE"
if [[ $rc -ne 0 && "$out" == *"stale state"* ]]; then
    ok "doctor reports a stale state file"
else
    bad "doctor ignored a stale state file"
fi

echo
echo "  $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
