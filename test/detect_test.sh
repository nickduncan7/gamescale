#!/usr/bin/env bash
#
# Monitor detection tests.
#
# Drives the real script end to end with gdctl and gsettings stubbed out on
# PATH, so what's under test is the shipped parser rather than a copy of it.
# No display is touched: --status only reads.
#
#   ./test/detect_test.sh

set -uo pipefail

SCRIPT="$(cd "$(dirname "$0")/.." && pwd)/gamescale.sh"
STUBS=$(mktemp -d)
trap 'rm -rf "$STUBS"' EXIT

cat > "$STUBS/gdctl" <<'STUB'
#!/bin/sh
[ "${1:-}" = "show" ] || exit 1
printf '%s\n' "$GDCTL_FIXTURE"
STUB

# --status reads two interface settings; neither is under test here.
cat > "$STUBS/gsettings" <<'STUB'
#!/bin/sh
case "$3" in
    text-scaling-factor) echo "1.0" ;;
    cursor-size)         echo "24" ;;
esac
STUB

chmod +x "$STUBS/gdctl" "$STUBS/gsettings"

PASS=0; FAIL=0

# fixture SCALE CONNECTOR... — one logical monitor per connector, laid out
# left to right, first one primary.
fixture() {
    local scale="$1"; shift
    local n=0 x=0
    printf 'Logical monitors:\n'
    for conn in "$@"; do
        n=$((n + 1))
        printf '%s\n' "├──Logical monitor #$n" \
            "│  ├──Position: ($x, 0)" \
            "│  ├──Scale: $scale" \
            "│  ├──Transform: normal" \
            "│  ├──Primary: $([ $n -eq 1 ] && echo yes || echo no)" \
            "│  └──Monitors: (1)" \
            "│      └──$conn (Some Display)"
        x=$((x + 1920))
    done
}

# Renders --status as "connector*" per monitor, * marking primary.
render() {
    GDCTL_FIXTURE="$1" PATH="$STUBS:$PATH" bash "$SCRIPT" --status 2>/dev/null \
        | awk '/^monitor:/ { printf "%s%s ", $2, (/primary/ ? "*" : "") }
               END { print "" }' \
        | sed 's/ *$//'
}

check() {
    local name="$1" expected="$2" got
    got=$(render "$3")
    if [[ "$got" == "$expected" ]]; then
        printf '  \033[32mok\033[0m   %-30s %s\n' "$name" "$got"
        PASS=$((PASS + 1))
    else
        printf '  \033[31mFAIL\033[0m %-30s expected [%s], got [%s]\n' \
            "$name" "$expected" "$got"
        FAIL=$((FAIL + 1))
    fi
}

echo "monitor detection"
echo

# The v1.0.1 regression: an unanchored search matched "A-1" inside "HDMI-A-1",
# so gdctl was handed a monitor that does not exist and every HDMI or DVI
# primary display silently fell through to launching the game unmodified.
check "laptop panel"          "eDP-1*"     "$(fixture 1.3333333730697632 eDP-1)"
check "hdmi, multi-part"      "HDMI-A-1*"  "$(fixture 1.5 HDMI-A-1)"
check "dvi, multi-part"       "DVI-D-1*"   "$(fixture 2.0 DVI-D-1)"
check "displayport"           "DP-2*"      "$(fixture 1.25 DP-2)"
check "vga"                   "VGA-1*"     "$(fixture 1.0 VGA-1)"
check "underscore variant"    "DP_1*"      "$(fixture 1.0 DP_1)"
check "two-digit index"       "HDMI-A-10*" "$(fixture 1.0 HDMI-A-10)"

# Every monitor must be captured, not just the primary: XWayland's scale factor
# is global, and a monitor left out of a gdctl config is a monitor turned off.
check "two monitors"          "eDP-1* HDMI-1"  "$(fixture 1.5 eDP-1 HDMI-1)"
check "three monitors"        "eDP-1* HDMI-1 DP-2" "$(fixture 1.5 eDP-1 HDMI-1 DP-2)"
check "non-first primary"     "HDMI-A-1* eDP-1" "$(fixture 1.5 HDMI-A-1 eDP-1)"

# A mirrored logical monitor drives several connectors at once. Dropping the
# second one would switch that output off.
check "mirrored pair" "eDP-1,HDMI-1*" "$(printf '%s\n' \
    'Logical monitors:' \
    '└──Logical monitor #1' \
    '   ├──Position: (0, 0)' \
    '   ├──Scale: 1.0' \
    '   ├──Transform: normal' \
    '   ├──Primary: yes' \
    '   └──Monitors: (2)' \
    '       ├──eDP-1 (Built-in display)' \
    '       └──HDMI-1 (RTK 16")')"

# Sections after the logical monitor list must not be parsed as monitors.
check "trailing section ignored" "eDP-1*" "$(printf '%s\n' \
    'Logical monitors:' \
    '└──Logical monitor #1' \
    '   ├──Position: (0, 0)' \
    '   ├──Scale: 1.0' \
    '   ├──Transform: normal' \
    '   ├──Primary: yes' \
    '   └──Monitors: (1)' \
    '       └──eDP-1 (Built-in display)' \
    '' \
    'Properties:' \
    '└──Layout mode: physical')"

echo
echo "  $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
