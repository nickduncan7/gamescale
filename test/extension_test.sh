#!/usr/bin/env bash
#
# Extension sanity checks.
#
# The extension only runs inside gnome-shell, so behavior can't be tested
# here — what can be pinned is everything that would make it fail to load at
# all: malformed metadata, a uuid the installer disagrees with, a JS syntax
# error, a missing icon. Each of those would otherwise surface only as a
# silently absent indicator after the next login.
#
#   ./test/extension_test.sh

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
EXT="$ROOT/extension"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

PASS=0; FAIL=0
ok()  { printf '  \033[32mok\033[0m   %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL + 1)); }

echo "extension"
echo

# --- metadata ----------------------------------------------------------------
if uuid=$(python3 -c '
import json, sys
m = json.load(open(sys.argv[1]))
for key in ("uuid", "name", "description", "url", "shell-version"):
    assert m[key], key
assert isinstance(m["shell-version"], list) and m["shell-version"]
print(m["uuid"])' "$EXT/metadata.json" 2>&1); then
    ok "metadata.json is valid and complete"
else
    bad "metadata.json: $uuid"; uuid=""
fi

# The installer enables by uuid; a mismatch installs an extension the shell
# will never load.
if [[ -n "$uuid" ]] && grep -q "^EXT_UUID=\"$uuid\"\$" "$ROOT/install.sh"; then
    ok "install.sh agrees on the uuid ($uuid)"
else
    bad "install.sh EXT_UUID does not match metadata.json"
fi

# --- the JS parses as a module -----------------------------------------------
# node treats .mjs as an ES module, which is what gnome-shell loads. gjs can't
# do this standalone: it resolves the resource:/// imports at load, which only
# exist inside the shell.
if command -v node >/dev/null 2>&1; then
    cp "$EXT/extension.js" "$WORK/extension.mjs"
    if out=$(node --check "$WORK/extension.mjs" 2>&1); then
        ok "extension.js parses as an ES module"
    else
        bad "extension.js has a syntax error"; printf '%s\n' "$out" | sed 's/^/        /'
    fi
else
    echo "  skip node not available — extension.js not syntax-checked"
fi

# --- the icon the code loads exists ------------------------------------------
icon=$(sed -n 's|.*icons/\([a-z-]*\.svg\).*|\1|p' "$EXT/extension.js" | head -n 1)
if [[ -n "$icon" && -r "$EXT/icons/$icon" ]]; then
    ok "icon referenced by the code exists ($icon)"
else
    bad "extension.js references icons/${icon:-<none found>} which is missing"
fi
if [[ "$icon" == *-symbolic.svg ]]; then
    ok "icon is named -symbolic, so the shell recolors it"
else
    bad "icon is not named -symbolic.svg"
fi

# --- every style class the code toggles is defined ---------------------------
missing=""
while IFS= read -r class; do
    grep -q "\.$class\b" "$EXT/stylesheet.css" || missing="$missing $class"
done < <(sed -n "s/.*add_style_class_name('\([a-z-]*\)').*/\1/p" "$EXT/extension.js" \
         | grep -v '^system-' | sort -u)
if [[ -z "$missing" ]]; then
    ok "style classes used by the code exist in stylesheet.css"
else
    bad "stylesheet.css is missing:$missing"
fi

echo
echo "  $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
