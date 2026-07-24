#!/bin/sh
#
# gamescale installer.
#
#   curl -fsSL https://raw.githubusercontent.com/proto-cool/gamescale/main/install.sh | sh
#
# or, from a checkout:
#
#   ./install.sh
#
# Installs the script, grants Flatpak Steam the four things it needs, installs
# the login reconcile unit, and runs --doctor. Everything it does is printed and
# individually reversible; nothing needs root.
#
# ENV
#   GAMESCALE_REF          tag to install               (default: latest release)
#   GAMESCALE_BINDIR       install location             (default: ~/.local/bin)
#   GAMESCALE_NO_FLATPAK   1 to skip the Steam overrides
#   GAMESCALE_NO_UNIT      1 to skip the login reconcile unit

set -eu

REPO="proto-cool/gamescale"
STEAM_ID="com.valvesoftware.Steam"
BINDIR="${GAMESCALE_BINDIR:-$HOME/.local/bin}"
STATE_DIR="$HOME/.local/state/gamescale"
TARGET="$BINDIR/gamescale"

say()  { printf '\033[1m::\033[0m %s\n' "$*"; }
warn() { printf '\033[33m!!\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[31mxx\033[0m %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Source. A checkout next to this installer wins, so cloning and running works
# offline and installs exactly what you can see.
# ---------------------------------------------------------------------------

SRC=""
CLEANUP=""
# shellcheck disable=SC2086
trap 'if [ -n "$CLEANUP" ]; then rm -f $CLEANUP; fi' EXIT INT TERM

self_dir=$(CDPATH= cd -- "$(dirname -- "$0")" 2>/dev/null && pwd) || self_dir=""
if [ -n "$self_dir" ] && [ -r "$self_dir/gamescale.sh" ]; then
    SRC="$self_dir/gamescale.sh"
    say "installing from checkout: $SRC"
else
    ref="${GAMESCALE_REF:-}"
    if [ -n "$ref" ]; then
        url="https://github.com/$REPO/releases/download/$ref/gamescale.sh"
    else
        url="https://github.com/$REPO/releases/latest/download/gamescale.sh"
    fi

    command -v curl >/dev/null 2>&1 || die "curl is required to download gamescale"
    SRC=$(mktemp) || die "could not create a temporary file"
    CLEANUP="$SRC"
    say "downloading ${ref:-latest release}"
    curl -fsSL "$url" -o "$SRC" \
        || die "download failed: $url (is there a release with gamescale.sh attached?)"
fi

# Guard against installing a 404 page or a truncated transfer as an executable.
[ -s "$SRC" ] || die "downloaded file is empty"
head -n 1 "$SRC" | grep -q '^#!' || die "downloaded file is not a script"
grep -q 'GAMESCALE_SCALE' "$SRC" || die "downloaded file does not look like gamescale"

# ---------------------------------------------------------------------------
# Install
# ---------------------------------------------------------------------------

mkdir -p "$BINDIR" "$STATE_DIR"
install -m 755 "$SRC" "$TARGET"
say "installed $TARGET"

case ":$PATH:" in
    *":$BINDIR:"*) ;;
    *) warn "$BINDIR is not on your PATH — add it, or invoke gamescale by full path" ;;
esac

# ---------------------------------------------------------------------------
# Flatpak Steam. Four grants: read the script, share state, reach the host
# session, resolve the bare name. --user overrides apply to system-installed
# apps too, so this never needs root.
# ---------------------------------------------------------------------------

if [ "${GAMESCALE_NO_FLATPAK:-0}" = "1" ]; then
    say "skipping Flatpak Steam overrides (GAMESCALE_NO_FLATPAK=1)"
elif ! command -v flatpak >/dev/null 2>&1; then
    say "no flatpak on this system — skipping Steam overrides"
elif ! flatpak info "$STEAM_ID" >/dev/null 2>&1; then
    say "Flatpak Steam is not installed — skipping Steam overrides"
    say "if you install it later, re-run this script"
else
    # Read the live sandbox PATH rather than assuming it. --env=PATH replaces
    # the value outright, so starting from whatever Steam ships today is the
    # only way to avoid pinning a stale one — and re-running stays idempotent.
    sandbox_path=$(flatpak run --command=sh "$STEAM_ID" -c 'printf %s "$PATH"' 2>/dev/null) || sandbox_path=""
    if [ -z "$sandbox_path" ]; then
        sandbox_path="/app/bin:/app/utils/bin:/usr/bin"
        warn "could not read Steam's sandbox PATH; assuming $sandbox_path"
    fi

    case ":$sandbox_path:" in
        *":$BINDIR:"*) new_path="$sandbox_path" ;;
        *)             new_path="$sandbox_path:$BINDIR" ;;
    esac

    flatpak override --user \
        --filesystem="$BINDIR:ro" \
        --filesystem="$STATE_DIR:create" \
        --talk-name=org.freedesktop.Flatpak \
        --env=PATH="$new_path" \
        "$STEAM_ID" \
        || die "flatpak override failed"

    say "granted Steam: $BINDIR (ro), $STATE_DIR (rw), host portal, PATH"
fi

# ---------------------------------------------------------------------------
# Login reconcile unit
# ---------------------------------------------------------------------------

if [ "${GAMESCALE_NO_UNIT:-0}" = "1" ]; then
    say "skipping login reconcile unit (GAMESCALE_NO_UNIT=1)"
elif ! command -v systemctl >/dev/null 2>&1; then
    say "no systemd — skipping login reconcile unit"
else
    "$TARGET" --install-unit >/dev/null 2>&1 \
        && say "installed gamescale-reconcile.service" \
        || warn "could not install the login reconcile unit (gamescale --install-unit to retry)"
fi

# ---------------------------------------------------------------------------
# Verify. Doctor exits 0 regardless; the checkmarks are the report.
# ---------------------------------------------------------------------------

echo
"$TARGET" --doctor || true
echo
say "Steam launch options:  gamescale %command%"
say "restart Steam for the new permissions to take effect"
