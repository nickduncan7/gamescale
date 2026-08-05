#!/usr/bin/env bash
#
# Environment passthrough, per-game defaults, and env-only mode.
#
# Everything v1.6.0 added, driven through the real script with the shared stubs
# on PATH. Nothing here touches a display.
#
# Three properties are worth more than the rest, because they are the ones a
# plausible refactor breaks silently:
#
#   - a usage error still launches the game. A typo in a Steam launch options
#     box must never be the reason a title won't start, and the person who
#     typed it has no terminal to read an error in.
#   - the all-or-nothing config rule. Any explicit flag disables the games.conf
#     lookup entirely. A per-key merge is the obvious "improvement" and there is
#     no version of it anyone can state in one sentence.
#   - -x takes no lock. An env-only launch is not an owner of the display, so it
#     must neither block nor be blocked by a scaled launch of another game.
#
#   ./test/env_test.sh

set -uo pipefail

SCRIPT="$(cd "$(dirname "$0")/.." && pwd)/gamescale.sh"
WORK=$(mktemp -d)
trap 'pkill -9 -f "$WORK" 2>/dev/null; rm -rf "$WORK"' EXIT

STUBS="$WORK/bin"; FAKEHOME="$WORK/home"
mkdir -p "$STUBS" "$FAKEHOME/.local/state/gamescale"
GSDIR="$FAKEHOME/.local/state/gamescale"
STATE="$GSDIR/state"
LOCK="$GSDIR/lock"
GAMES="$GSDIR/games.conf"
LOG="$WORK/python3.log"
GS_LOG="$WORK/gsettings.log"

# shellcheck source=test/stubs.sh
. "$(cd "$(dirname "$0")" && pwd)/stubs.sh"
make_stubs "$STUBS"

FIXTURE=$(printf 'eDP-1\t1.3333333730697632\tyes\t0\t0\tnormal')

PASS=0; FAIL=0
ok()  { printf '  \033[32mok\033[0m   %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL + 1)); }

# Runs gamescale and returns its combined output, which is where every export
# echo and every warning lands. The display program's log is reset each time so
# "did this launch touch the display" is answerable per case.
OUT=""
gs() {
    : > "$LOG"; : > "$GS_LOG"
    OUT=$(env DETECT_FIXTURE="$FIXTURE" PY_LOG="$LOG" GS_LOG="$GS_LOG" \
        GAMESCALE_NO_WATCH=1 HOME="$FAKEHOME" PATH="$STUBS:$PATH" \
        bash "$SCRIPT" "$@" 2>&1)
}

# As above, with extra environment for the launch — the inherited half of the
# precedence rules.
gsenv() {  # gsenv KEY=VAL... -- gamescale args...
    local -a pre=()
    while [[ $# -gt 0 && "$1" != "--" ]]; do pre+=("$1"); shift; done
    shift
    : > "$LOG"; : > "$GS_LOG"
    OUT=$(env DETECT_FIXTURE="$FIXTURE" PY_LOG="$LOG" GS_LOG="$GS_LOG" \
        GAMESCALE_NO_WATCH=1 HOME="$FAKEHOME" PATH="$STUBS:$PATH" \
        "${pre[@]}" bash "$SCRIPT" "$@" 2>&1)
}

said()    { if [[ "$OUT" == *"$1"* ]]; then ok "$2"; else
                bad "$2"; printf '        said: %s\n' "$OUT"; fi }
saidnot() { if [[ "$OUT" == *"$1"* ]]; then
                bad "$2"; printf '        said: %s\n' "$OUT"; else ok "$2"; fi }
scaled()  { if grep -q -- '^- apply' "$LOG"; then ok "$1"; else
                bad "$1"; printf '        log: %s\n' "$(cat "$LOG")"; fi }
unscaled() { if grep -q -- '^- ' "$LOG"; then
                bad "$1"; printf '        log: %s\n' "$(cat "$LOG")"; else ok "$1"; fi }

echo "environment passthrough, per-game defaults, and env-only mode"
echo

# --- flag parsing ----------------------------------------------------------
# Each shorthand is DEFINED as an alias of -e, so the assertion is on the exact
# expansion rather than on some flag having had an effect.

gs -w -- true
said "exporting PROTON_ENABLE_WAYLAND=1 (-w)" "-w expands to PROTON_ENABLE_WAYLAND=1"
gs -n -- true
said "exporting PROTON_USE_NTSYNC=1 (-n)" "-n expands to PROTON_USE_NTSYNC=1"
gs -m -- true
said "exporting MANGOHUD=1 (-m)" "-m expands to MANGOHUD=1"

# --- the expansion table ---------------------------------------------------
# These variable names rot: Proton renames them, flips their defaults, and the
# forks disagree with upstream. Two things guard that, and both are asserted
# here rather than trusted.
#
# First, the expansions are pinned as literals below instead of being read out
# of the script. A test that derived them from the table would agree with any
# table, including one a careless edit had changed — and a shorthand quietly
# exporting a different variable is invisible at the launch site, because the
# export still succeeds. It looks exactly like Proton ignoring the flag.
#
# Changing a row is therefore a deliberate two-file edit. That is the point.
declare -A EXPECT_EXPANDS=(
    [w]="PROTON_ENABLE_WAYLAND=1"   # GE-Proton / proton-cachyos; inert on stock
    [n]="PROTON_USE_NTSYNC=1"       # inert on stock Proton 11 — see the table
    [m]="MANGOHUD=1"                # MangoHud's own, works everywhere
)
for letter in w n m; do
    gs "-$letter" -- true
    said "exporting ${EXPECT_EXPANDS[$letter]} (-$letter)" \
        "-$letter still expands to ${EXPECT_EXPANDS[$letter]}"
done

# Second, --help quotes the table, and a quote that has drifted from the code
# is worse than no quote at all: it is documentation that lies. The script's
# header is the help text, so this compares the two directly.
HELP=$(bash "$SCRIPT" --help)
for letter in w n m; do
    if grep -qE -- "-$letter, --env-[a-z-]+ +-e ${EXPECT_EXPANDS[$letter]}$" \
            <<<"$HELP"; then
        ok "--help quotes -$letter's expansion exactly"
    else
        bad "--help has drifted from the table for -$letter"
        printf '        help: %s\n' "$(grep -- "-$letter, --env" <<<"$HELP")"
    fi
done

# The table is only useful if you can see it next to the build you are running,
# which is the one thing that tells you whether to trust it.
gs --doctor
said "shorthand expansions" "--doctor prints the table"
for letter in w n m; do
    said "-$letter  ${EXPECT_EXPANDS[$letter]}" "--doctor shows -$letter's expansion"
done

# Combining is the form people actually type, and splitting a cluster is where
# a rewrite goes wrong: -wn silently doing only -w is invisible at the launch
# site and looks exactly like Proton ignoring the variable.
gs -wn -- true
if [[ "$OUT" == *"PROTON_ENABLE_WAYLAND=1"* && "$OUT" == *"PROTON_USE_NTSYNC=1"* ]]; then
    ok "-wn is -w and -n"
else
    bad "-wn dropped one of its letters"; printf '        said: %s\n' "$OUT"
fi

gs -e FOO=bar -- true
said "exporting FOO=bar (-e)" "-e takes KEY=VAL as the next argument"
gs -eFOO=bar -- true
said "exporting FOO=bar (-e)" "-e takes KEY=VAL attached"
gs --env FOO=bar -- true
said "exporting FOO=bar (--env)" "--env is the long form"
gs --env=FOO=bar -- true
said "exporting FOO=bar (--env)" "--env=KEY=VAL parses"

# A value is passed through byte for byte; only the KEY is validated.
gs -e 'FOO=a=b=c' -- true
said "exporting FOO=a=b=c" "only the first = separates key from value"
gs -e 'FOO=' -- true
said "exporting FOO= " "an empty value is a value"

# Repeating a variable exports it once, with the last value. Exporting twice is
# not possible, so the alternative to last-wins is an arbitrary one.
gs -e FOO=1 -e FOO=2 -- true
if [[ "$(grep -c 'exporting FOO=' <<<"$OUT")" == 1 && "$OUT" == *"exporting FOO=2"* ]]; then
    ok "repeating a variable keeps the last value, once"
else
    bad "repeated -e did not collapse"; printf '        said: %s\n' "$OUT"
fi

# -s is the only value-taking short flag, and it has to work in a cluster too.
gs -s 1.5 -- true
if grep -q 'eDP-1;1.5;' "$LOG"; then ok "-s FACTOR reaches the configuration"; else
    bad "-s FACTOR ignored"; printf '        log: %s\n' "$(cat "$LOG")"; fi
gs -s1.5 -- true
if grep -q 'eDP-1;1.5;' "$LOG"; then ok "-s1.5 attached reaches it too"; else
    bad "-s1.5 ignored"; printf '        log: %s\n' "$(cat "$LOG")"; fi
gs --scale 1.5 -- true
if grep -q 'eDP-1;1.5;' "$LOG"; then ok "--scale FACTOR reaches it"; else
    bad "--scale ignored"; printf '        log: %s\n' "$(cat "$LOG")"; fi
gs -ws1.5 -- true
if grep -q 'eDP-1;1.5;' "$LOG" && [[ "$OUT" == *"PROTON_ENABLE_WAYLAND=1"* ]]; then
    ok "a value-taking letter ends the cluster it is in"
else
    bad "-ws1.5 mis-parsed"; printf '        said: %s\n' "$OUT"; fi

gs -f -- true
if grep -q 'text-scaling-factor 1.33' "$GS_LOG"; then
    bad "-f still compensated the font"
else
    ok "-f is GAMESCALE_NO_FONT=1"
fi
scaled "-f still scales the display"

# Both invocation forms. Steam substitutes %command% with no -- in front of it,
# so parsing has to stop at the first non-flag argument on its own.
gs -w true
said "exporting PROTON_ENABLE_WAYLAND=1" "flags before a bare command parse"
marker="$WORK/ran"; rm -f "$marker"
gs -w -- touch "$marker"
if [[ -f "$marker" ]]; then ok "-- ends flag parsing"; else bad "-- broke the launch"; fi

# A command that is itself flag-shaped, after --. Consuming it would be a
# launch failure with no error anyone would understand.
rm -f "$marker"
# Unexpanded on purpose: the inner shell expands it, and the point is that
# gamescale hands the whole thing through untouched.
# shellcheck disable=SC2016
gs -w -- env "MARK=$marker" sh -c 'touch "$MARK"'
if [[ -f "$marker" ]]; then ok "the command after -- is never re-parsed"; else
    bad "the command after -- was eaten"; printf '        said: %s\n' "$OUT"; fi

# --- usage errors still launch the game ------------------------------------
# The repo invariant, applied to the new surface. A launch options box is not a
# terminal: nobody sees the error, they see a game that will not start.

for badpair in "BAD KEY=1" "1FOO=1" "FOO-BAR=1" "noequalssign"; do
    rm -f "$marker"
    gs -e "$badpair" -- touch "$marker"
    if [[ -f "$marker" ]]; then
        ok "-e '$badpair' is refused but still launches the game"
    else
        bad "-e '$badpair' stopped the game"; printf '        said: %s\n' "$OUT"
    fi
    if [[ "$OUT" == *"not a valid KEY=VAL"* ]]; then
        ok "-e '$badpair' says what was wrong"
    else
        bad "-e '$badpair' was accepted"; printf '        said: %s\n' "$OUT"
    fi
done

rm -f "$marker"
gs -e "BAD KEY=1" -- touch "$marker"
unscaled "a usage error launches unmodified, without touching the display"

# A value-less -e at the end of the line: nothing to consume, still a launch.
gs -w -e
said "needs a value" "a trailing -e says so"

# An unknown flag is the one flag error that does NOT launch, because we cannot
# know whether it takes a value and therefore cannot know which argument is the
# game. This is what --stats did before any of this existed.
rm -f "$marker"
gs --stats -- touch "$marker"
if [[ -f "$marker" ]]; then
    bad "an unknown flag exec'd an argument it had not understood"
else
    ok "an unknown long flag refuses rather than guess"
fi
gs -wq -- true
said "unknown option: -q" "an unknown letter in a cluster is named"

# --- games.conf ------------------------------------------------------------

write_games() { printf '%b' "$1" > "$GAMES"; }

write_games '# per-game defaults\n1817070 = wn                  # Halo\n620     = w, MANGOHUD=1\n22380   = x\n'

gsenv SteamAppId=1817070 -- -- true
if [[ "$OUT" == *"PROTON_ENABLE_WAYLAND=1 (games.conf:1817070)"* \
   && "$OUT" == *"PROTON_USE_NTSYNC=1 (games.conf:1817070)"* ]]; then
    ok "letters in games.conf mean what the flags mean"
else
    bad "the config entry did not take"; printf '        said: %s\n' "$OUT"
fi

gsenv SteamAppId=620 -- -- true
if [[ "$OUT" == *"PROTON_ENABLE_WAYLAND=1 (games.conf:620)"* \
   && "$OUT" == *"MANGOHUD=1 (games.conf:620)"* ]]; then
    ok "letters and KEY=VAL mix in one entry"
else
    bad "the mixed entry did not take"; printf '        said: %s\n' "$OUT"
fi

gsenv SteamAppId=999999 -- -- true
saidnot "exporting" "an appid with no entry exports nothing"

gs -- true
saidnot "exporting" "no SteamAppId means no lookup at all"

# The escape hatch. A variable this release has never heard of is exactly what
# the format exists to carry — the next Proton knob, or a shipped defaults
# database written after this code was.
write_games '4242 = PROTON_SOMETHING_NEW=1\n'
gsenv SteamAppId=4242 -- -- true
said "exporting PROTON_SOMETHING_NEW=1 (games.conf:4242)" \
    "an unknown but well-formed KEY=VAL is not an error"

# Malformed lines: named by line number, skipped, and the rest of the file is
# still read. A config file that stops working entirely because line 3 has a
# typo is a config file people stop trusting.
write_games 'oops    = w\n1817070 = q\n620     = BAD KEY=1\n4242    = \n999     = w,,n\n# comment\n\n730     = w\n'
gsenv SteamAppId=730 -- -- true
for want in "games.conf:1: \"oops\" is not an appid" \
            "games.conf:2: unknown flag letter: q" \
            "games.conf:3: not a valid variable name: BAD KEY" \
            "games.conf:4: empty entry" \
            "games.conf:5: empty item"; do
    if [[ "$OUT" == *"$want"* ]]; then
        ok "malformed line reported: ${want#games.conf:}"
    else
        bad "not reported: $want"; printf '        said: %s\n' "$OUT"
    fi
done
said "exporting PROTON_ENABLE_WAYLAND=1 (games.conf:730)" \
    "a good line after five bad ones is still applied"

# All-or-nothing validation within a line: a third item that is bad must not
# leave the first two applied.
write_games '730 = w, MANGOHUD=1, BAD KEY=1\n'
gsenv SteamAppId=730 -- -- true
saidnot "exporting" "one bad item skips the whole line, not just that item"

# Comments and whitespace.
write_games '  # leading comment\n\n  730   =   w  ,  MANGOHUD=1   # trailing\n'
gsenv SteamAppId=730 -- -- true
if [[ "$OUT" == *"PROTON_ENABLE_WAYLAND=1 (games.conf:730)"* \
   && "$OUT" == *"MANGOHUD=1 (games.conf:730)"* ]]; then
    ok "whitespace and a trailing comment are ignored"
else
    bad "whitespace handling"; printf '        said: %s\n' "$OUT"
fi
saidnot "leading comment" "a full-line comment is not parsed as an entry"

# A '#' only starts a comment at the start of a line or after whitespace, so a
# value can still contain one. Without that rule no colour, tag or fragment can
# ever be written in this file.
write_games '730 = TAG=a#b\n'
gsenv SteamAppId=730 -- -- true
said "exporting TAG=a#b" "a # inside a value is part of the value"

# --- precedence ------------------------------------------------------------
# explicit flags > games.conf > inherited environment.

write_games '730 = w, MANGOHUD=1\n'

gsenv SteamAppId=730 PROTON_ENABLE_WAYLAND=0 -- -- true
said "games.conf(730) overrides inherited PROTON_ENABLE_WAYLAND=0 -> 1" \
    "games.conf beats an inherited variable, and says so"

gsenv SteamAppId=730 PROTON_ENABLE_WAYLAND=1 -- -- true
saidnot "overrides inherited" "an inherited variable that agrees is not a conflict"
said "exporting PROTON_ENABLE_WAYLAND=1" "an agreeing value is still exported"

gsenv PROTON_ENABLE_WAYLAND=0 -- -w -- true
said "-w overrides inherited PROTON_ENABLE_WAYLAND=0 -> 1" \
    "a flag beats an inherited variable, and says so"

# The documented idiom for winning an argument with your own config file.
gsenv SteamAppId=730 -- -e PROTON_ENABLE_WAYLAND=0 -- true
if [[ "$OUT" == *"exporting PROTON_ENABLE_WAYLAND=0 (-e)"* \
   && "$OUT" != *"MANGOHUD"* ]]; then
    ok "-e KEY=0 beats the config, and takes the whole config with it"
else
    bad "-e did not override the config"; printf '        said: %s\n' "$OUT"
fi

# All-or-nothing, stated as its own case: a flag that has nothing to do with
# the config's variables still disables the entire lookup. Any other rule needs
# a per-key merge order nobody can hold in their head.
gsenv SteamAppId=730 -- -e UNRELATED=1 -- true
if [[ "$OUT" == *"exporting UNRELATED=1"* && "$OUT" != *"PROTON_ENABLE_WAYLAND"* ]]; then
    ok "an unrelated flag still disables the config lookup entirely"
else
    bad "the config was merged with the flags"; printf '        said: %s\n' "$OUT"
fi
gsenv SteamAppId=730 -- -f -- true
saidnot "games.conf" "even a wrapper-only flag disables the lookup"

gsenv SteamAppId=730 FOO=inherited -- -- true
saidnot "FOO" "an inherited variable nobody claims is left alone"

# --- -x, env-only mode -----------------------------------------------------

write_games '22380 = x\n4242  = x, MANGOHUD=1\n'
rm -f "$STATE"

gs -x -- true
unscaled "-x reads nothing and applies nothing"
if [[ -f "$STATE" ]]; then bad "-x wrote a state file"; else
    ok "-x writes no state file"; fi
if [[ -s "$GS_LOG" ]]; then
    bad "-x touched gsettings"; printf '        %s\n' "$(tr '\n' '|' < "$GS_LOG")"
else
    ok "-x touches no font or cursor setting"
fi

gsenv SteamAppId=4242 -- -- true
said "exporting MANGOHUD=1 (games.conf:4242)" "x in a config entry still exports"
unscaled "x in a config entry is env-only too"

gs -x -s 1.5 -- true
said "-x is env-only" "-x with -s warns that the scale change will not happen"
unscaled "-x with -s still proceeds env-only"
gs -x -f -- true
said "-x is env-only" "-x with -f warns too"
gs -x -w -- true
saidnot "-x is env-only" "-x with an env shorthand warns about nothing"

# The lock, which is the whole reason -x exists as a mode rather than as a
# shorthand for GAMESCALE_SCALE=<current>. An env-only launch is not an owner
# of the display, so the one-game-at-a-time rule must not reach it.
rm -f "$STATE"
env DETECT_FIXTURE="$FIXTURE" PY_LOG="$WORK/x.log" GS_LOG="$GS_LOG" \
    GAMESCALE_NO_WATCH=1 HOME="$FAKEHOME" PATH="$STUBS:$PATH" \
    setsid bash "$SCRIPT" -x -w -- sleep 30 >/dev/null 2>&1 &
xpid=$!
held=1
for _ in $(seq 1 50); do
    pgrep -f "sleep 30" >/dev/null 2>&1 && break
    sleep 0.1
done
flock -n "$LOCK" -c true 2>/dev/null && held=0
if [[ $held == 0 ]]; then
    ok "an -x launch holds no lock while it runs"
else
    bad "an -x launch took the lock"
fi

# ...and the case that motivates it: a scaled game is running, an -x launch
# arrives. It must not be refused, and it must not disturb the running game.
: > "$LOG"
scaled_out=$(env DETECT_FIXTURE="$FIXTURE" PY_LOG="$WORK/scaled.log" GS_LOG="$GS_LOG" \
    GAMESCALE_NO_WATCH=1 HOME="$FAKEHOME" PATH="$STUBS:$PATH" \
    setsid bash "$SCRIPT" -- sleep 30 2>&1 &
    for _ in $(seq 1 50); do
        flock -n "$LOCK" -c true 2>/dev/null || break
        sleep 0.1
    done
    env DETECT_FIXTURE="$FIXTURE" PY_LOG="$WORK/x2.log" GS_LOG="$GS_LOG" \
        GAMESCALE_NO_WATCH=1 HOME="$FAKEHOME" PATH="$STUBS:$PATH" \
        bash "$SCRIPT" -x -w -- true 2>&1)
if [[ "$scaled_out" == *"exporting PROTON_ENABLE_WAYLAND=1"* \
   && "$scaled_out" != *"another gamescale"* ]]; then
    ok "an -x launch is not refused while a scaled game holds the lock"
else
    bad "-x was blocked by a scaled launch"; printf '        said: %s\n' "$scaled_out"
fi
if [[ -s "$WORK/x2.log" ]]; then
    bad "-x touched the display of the running game"
    printf '        log: %s\n' "$(cat "$WORK/x2.log")"
else
    ok "-x left the running game's display alone"
fi
pkill -9 -f "sleep 30" 2>/dev/null
wait "$xpid" 2>/dev/null
for _ in $(seq 1 50); do
    flock -n "$LOCK" -c true 2>/dev/null && break
    sleep 0.1
done
rm -f "$STATE"

# -x must not need the host at all: it reads no display and sets no gsetting,
# so a missing dependency is not a reason to refuse it.
rm -f "$marker"
NODEPS="$WORK/nodeps"; mkdir -p "$NODEPS"
OUT=$(env GAMESCALE_NO_WATCH=1 HOME="$FAKEHOME" PATH="$NODEPS:/usr/bin:/bin" \
    bash "$SCRIPT" -x -w -- touch "$marker" 2>&1)
if [[ -f "$marker" && "$OUT" == *"exporting PROTON_ENABLE_WAYLAND=1"* ]]; then
    ok "-x works with no gsettings and no python3 on PATH"
else
    bad "-x was refused for lacking dependencies it does not use"
    printf '        said: %s\n' "$OUT"
fi

# --- the last-run record ---------------------------------------------------

rm -f "$GSDIR"/lastrun-*
write_games '730 = w, MANGOHUD=1\n'

gsenv SteamAppId=730 -- -- true
if [[ -f "$GSDIR/lastrun-730" ]]; then
    ok "a launch with an appid writes lastrun-<appid>"
else
    bad "no lastrun record was written"
fi
if grep -q '^source=games.conf$' "$GSDIR/lastrun-730" &&
   grep -q "^env=${EXPECT_EXPANDS[w]}$" "$GSDIR/lastrun-730" &&
   grep -q '^env=MANGOHUD=1$'    "$GSDIR/lastrun-730"; then
    ok "the record names its source and every export"
else
    bad "the record is incomplete"; sed 's/^/        /' "$GSDIR/lastrun-730"
fi

gs -e FOO=1 -- true
if [[ -f "$GSDIR/lastrun-cmdline" ]]; then
    ok "a launch with no appid writes lastrun-cmdline"
else
    bad "no cmdline record"
fi

# One file per appid, overwritten — so it cannot grow without bound, and so
# --status shows the last launch rather than a log to page through.
gsenv SteamAppId=730 -- -e ONLY=THIS -- true
if grep -q '^env=ONLY=THIS$' "$GSDIR/lastrun-730" \
   && ! grep -q 'MANGOHUD' "$GSDIR/lastrun-730" \
   && [[ "$(grep -c '^env=' "$GSDIR/lastrun-730")" == 1 ]]; then
    ok "the record is overwritten, not appended to"
else
    bad "the record accumulated"; sed 's/^/        /' "$GSDIR/lastrun-730"
fi
if [[ "$(stat -c %a "$GSDIR/lastrun-730")" == "600" ]]; then
    ok "the record is not world-readable"
else
    bad "record mode is $(stat -c %a "$GSDIR/lastrun-730"), want 600"
fi

# A launch that exports nothing has nothing to record.
rm -f "$GSDIR/lastrun-999999"
gsenv SteamAppId=999999 -- -- true
if [[ -f "$GSDIR/lastrun-999999" ]]; then
    bad "a launch that exported nothing still wrote a record"
else
    ok "a launch that exports nothing writes no record"
fi

gs --status 730
said "last export:  ONLY=THIS" "--status reads the record back"

# Known keys with bad values are refused; unknown keys are ignored — nothing
# restores from this record, so printing the lines understood is enough.
printf 'timestamp=2026-07-26T00:00:00Z\nsource=flags\nfuture=1\n' \
    > "$GSDIR/lastrun-730"
gs --status 730
said "last run:     2026-07-26T00:00:00Z (from flags)" \
    "unknown keys in the record are ignored"
printf 'timestamp=2026-07-26T00:00:00Z\nsource=nonsense\n' > "$GSDIR/lastrun-730"
gs --status 730
said "not understood" "a known key with a bad value is refused"
# Unexpanded on purpose: the point is that nothing ever expands it.
# shellcheck disable=SC2016
printf 'version=1\nsource=flags\nenv=FOO=$(touch %s/pwned)\n' "$WORK" > "$GSDIR/lastrun-730"
gs --status 730
if [[ -e "$WORK/pwned" ]]; then
    bad "the record was sourced rather than parsed"
else
    ok "the record is parsed, never sourced"
fi
rm -f "$GSDIR"/lastrun-*

# --- --status --------------------------------------------------------------

write_games '# my games\n730 = w, MANGOHUD=1   # a game\n1817070 = x\n'
gs --status
if [[ "$OUT" == *"730"*"w, MANGOHUD=1"* && "$OUT" == *"1817070"*"x"* ]]; then
    ok "--status prints the parsed table"
else
    bad "no table"; printf '%s\n' "$OUT" | sed 's/^/        /'
fi

gs --status 730
said "entry:        w, MANGOHUD=1" "--status <appid> shows the matching entry"
said "export:       PROTON_ENABLE_WAYLAND=1 (games.conf:730)" \
    "--status <appid> shows the effective exports"
said "last run:     no record" "--status says when there is no record"

gs --status 999999
said "entry:        none" "--status on an appid with no entry says none"

gsenv SteamAppId=1817070 -- --status
said "no-scale:     yes" "--status picks up SteamAppId from the environment"

if gs --status notanappid; then
    bad "--status accepted a non-appid"
else
    ok "--status refuses a non-appid"
fi

# --- --set-game ------------------------------------------------------------

STEAMAPPS="$FAKEHOME/.local/share/Steam/steamapps"
mkdir -p "$STEAMAPPS"
printf '"AppState"\n{\n\t"appid"\t\t"1817070"\n\t"name"\t\t"Halo: Campaign Evolved"\n}\n' \
    > "$STEAMAPPS/appmanifest_1817070.acf"

write_games '# keep me\n\n620 = w        # and me\n'
gs --set-game 1817070 wn
if grep -q '^1817070 = wn  # Halo: Campaign Evolved$' "$GAMES"; then
    ok "--set-game creates an entry, named from the appmanifest"
else
    bad "entry not created"; sed 's/^/        /' "$GAMES"
fi
if grep -q '^# keep me$' "$GAMES" && grep -q '^620 = w        # and me$' "$GAMES"; then
    ok "--set-game preserves comments and unrelated lines verbatim"
else
    bad "the rewrite lost something"; sed 's/^/        /' "$GAMES"
fi

gs --set-game 1817070 'w,MANGOHUD=1'
if [[ "$(grep -c '^1817070' "$GAMES")" == 1 ]] \
   && grep -q '^1817070 = w,MANGOHUD=1' "$GAMES"; then
    ok "--set-game replaces rather than duplicates"
else
    bad "replace duplicated the entry"; sed 's/^/        /' "$GAMES"
fi
if grep -q 'Halo: Campaign Evolved' "$GAMES"; then
    ok "replacing keeps the comment already on the line"
else
    bad "replacing dropped the comment"; sed 's/^/        /' "$GAMES"
fi

gs --set-game 4242 w
if grep -q '^4242 = w$' "$GAMES"; then
    ok "an unresolvable name is silent, and the entry is still written"
else
    bad "unresolvable name broke the write"; sed 's/^/        /' "$GAMES"
fi
saidnot "appmanifest" "an unresolvable name says nothing about it"

gs --set-game 1817070 -
if grep -q '^1817070' "$GAMES"; then
    bad "--set-game - did not remove the entry"; sed 's/^/        /' "$GAMES"
else
    ok "--set-game - removes the entry"
fi
if grep -q '^# keep me$' "$GAMES"; then
    ok "removal preserves the rest of the file"
else
    bad "removal took other lines with it"; sed 's/^/        /' "$GAMES"
fi

gs --set-game 999 -
said "no entry for 999" "removing an entry that isn't there says so"

before=$(cat "$GAMES")
gs --set-game 730 'w,BAD KEY=1'
if [[ "$(cat "$GAMES")" == "$before" ]]; then
    ok "an invalid entry is refused and nothing is written"
else
    bad "an invalid entry was written"; sed 's/^/        /' "$GAMES"
fi
said "not a valid variable name" "an invalid entry says why"
gs --set-game notanappid w
said "usage:" "--set-game refuses a non-appid"
gs --set-game 730
said "usage:" "--set-game with no entry refuses"

# The same parser writes and reads, so an entry --set-game accepted is an entry
# that launches. This is the only assertion that ties the two together.
gs --set-game 730 'wn,MANGOHUD=1'
gsenv SteamAppId=730 -- -- true
if [[ "$OUT" == *"PROTON_ENABLE_WAYLAND=1 (games.conf:730)"* \
   && "$OUT" == *"PROTON_USE_NTSYNC=1 (games.conf:730)"* \
   && "$OUT" == *"MANGOHUD=1 (games.conf:730)"* ]]; then
    ok "what --set-game writes is what a launch reads"
else
    bad "written entry did not launch"; printf '        said: %s\n' "$OUT"
fi

# Atomic rewrite. A real kill mid-write is not deterministic enough to assert
# on, so the property is asserted through its two observable consequences: a
# write that fails leaves the previous file whole, and no temporary file is
# ever left behind for the next reader to trip over.
before=$(cat "$GAMES")
mkdir -p "$GAMES.new"
gs --set-game 4242 wnm
rmdir "$GAMES.new" 2>/dev/null
if [[ "$(cat "$GAMES")" == "$before" ]]; then
    ok "a failed write leaves the previous file intact"
else
    bad "a failed write damaged the file"; sed 's/^/        /' "$GAMES"
fi
said "could not write" "a failed write reports itself"
gs --set-game 4242 wnm
if [[ -e "$GAMES.new" ]]; then
    bad "the write-and-rename temp file was left behind"
else
    ok "no temp file left behind"
fi

# --- --doctor --------------------------------------------------------------
# ntsync is a warning, never a failure: an absent /dev/ntsync is a fact about
# your kernel, not a broken install, and the installer's exit status depends on
# doctor not crying wolf.

doctor() {  # doctor EXTRA-ENV...
    OUT=$(env DETECT_FIXTURE="$FIXTURE" PY_LOG="$LOG" GS_LOG="$GS_LOG" \
        HOME="$FAKEHOME" PATH="$STUBS:/usr/bin:/bin" "$@" \
        bash "$SCRIPT" --doctor 2>&1)
    return $?
}

rm -f "$STATE"
NTSYNC="$WORK/ntsync"; : > "$NTSYNC"

doctor GAMESCALE_NTSYNC_DEV="$NTSYNC" FAKE_KVER=6.14.0
rc=$?
said "ntsync usable by the kernel" "doctor confirms a usable ntsync"
if [[ $rc -eq 0 ]]; then ok "a usable ntsync is not a failure"; else
    bad "doctor failed on a healthy ntsync"; fi

doctor GAMESCALE_NTSYNC_DEV="$WORK/absent" FAKE_KVER=6.14.0
rc=$?
said "absent" "doctor names an absent /dev/ntsync"
said "Proton ignores it" "doctor explains what -n will and will not do"
if [[ $rc -eq 0 ]]; then
    ok "an absent ntsync is a warning, not a failure"
else
    bad "an absent ntsync failed the install check"
    printf '%s\n' "$OUT" | grep 'check(s) failed' | sed 's/^/        /'
fi

doctor GAMESCALE_NTSYNC_DEV="$NTSYNC" FAKE_KVER=6.13.9
rc=$?
said "below 6.14" "doctor names a kernel too old for the interface Proton uses"
if [[ $rc -eq 0 ]]; then ok "an old kernel is a warning too"; else
    bad "an old kernel failed the install check"; fi

doctor GAMESCALE_NTSYNC_DEV="$NTSYNC" FAKE_KVER=7.1.4
said "ntsync usable by the kernel" "a kernel past 6.14 is usable, not merely equal to it"

doctor GAMESCALE_NTSYNC_DEV="$NTSYNC"
said "falls back to XWayland silently" "doctor states the wayland caveat"
said "xlsclients" "doctor points at the check that disambiguates it"

# games.conf, through the same parser the launch path uses.
write_games '730 = w\n1817070 = wn\n'
doctor GAMESCALE_NTSYNC_DEV="$NTSYNC"
rc=$?
said "games.conf parses (2 entries)" "doctor counts the entries it understood"
if [[ $rc -eq 0 ]]; then ok "a good games.conf is not a failure"; else
    bad "a good games.conf failed doctor"; fi

# The indicator extension. Every branch stays a warning: doctor's exit status
# gates the installer.
EXTROOT="$WORK/extensions"; mkdir -p "$EXTROOT"
EXT_V2="gamescale@arclight.digital"
EXT_V1="gamescale@proto-cool.github.io"
ext_doctor() { doctor GAMESCALE_NTSYNC_DEV="$NTSYNC" GAMESCALE_EXT_ROOT="$EXTROOT" "$@"; }

ext_doctor
rc=$?
said "no indicator extension" "doctor reports a missing extension"
if [[ $rc -eq 0 ]]; then ok "a missing extension is not a failure"; else
    bad "a missing extension failed doctor"; fi

# Installed but never enabled looks identical to a working install on disk.
mkdir -p "$EXTROOT/$EXT_V2"
ext_doctor
rc=$?
said "installed but not enabled" "doctor spots an extension that was never enabled"
if [[ $rc -eq 0 ]]; then ok "an unenabled extension is a warning, not a failure"; else
    bad "an unenabled extension failed doctor"; fi

ext_doctor GS_EXT_LIST="['$EXT_V2']"
said "installed and enabled" "doctor confirms an enabled extension"

# An absent schema is not the same fact as an empty list.
ext_doctor GS_EXT_LIST=fail
rc=$?
said "cannot tell whether it is enabled" "doctor separates an unreadable list from an empty one"
if [[ "$OUT" != *"installed but not enabled"* ]]; then
    ok "an unreadable list is not reported as disabled"
else
    bad "an unreadable enabled-extensions list was read as disabled"
fi
if [[ $rc -eq 0 ]]; then ok "an unreadable list is a warning, not a failure"; else
    bad "an unreadable list failed doctor"; fi

# What the piped v2 installer leaves behind: it cannot ship a replacement, so
# v1 stays and keeps drawing its own indicator.
mkdir -p "$EXTROOT/$EXT_V1"
ext_doctor GS_EXT_LIST="['$EXT_V2']"
rc=$?
said "v1 extension is still installed" "doctor reports a stranded v1 extension"
said "second indicator" "doctor says why a stranded v1 matters"
if [[ $rc -eq 0 ]]; then ok "a stranded v1 extension is a warning, not a failure"; else
    bad "a stranded v1 extension failed doctor"; fi

rm -rf "${EXTROOT:?}/$EXT_V1" "${EXTROOT:?}/$EXT_V2"

write_games '730 = w\noops = w\n1817070 = q\n'
doctor GAMESCALE_NTSYNC_DEV="$NTSYNC"
rc=$?
said "games.conf has lines that will be skipped" "doctor reports malformed lines"
said "games.conf:2:" "doctor names the line number"
said "games.conf:3: unknown flag letter: q" "doctor names the problem"
if [[ $rc -ne 0 ]]; then
    ok "a malformed games.conf is a failure — it means a game is not configured"
else
    bad "doctor passed a games.conf with lines it will skip"
fi

rm -f "$GAMES"
doctor GAMESCALE_NTSYNC_DEV="$NTSYNC"
rc=$?
said "no games.conf" "doctor says when there is no config at all"
if [[ $rc -eq 0 ]]; then ok "no games.conf is not a failure"; else
    bad "the absence of a config failed doctor"; fi

echo
echo "  $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
