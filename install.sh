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
# To remove all of it:
#
#   ./install.sh --uninstall
#   curl -fsSL .../install.sh | sh -s -- --uninstall
#
# Add --dry-run to either to see every action without taking any. Worth doing
# before the install: it grants a sandbox you care about four permissions.
#
# ENV
#   GAMESCALE_REF          tag to install               (default: latest release)
#   GAMESCALE_BINDIR       install location             (default: ~/.local/bin)
#   GAMESCALE_NO_FLATPAK   1 to skip the Steam overrides
#   GAMESCALE_NO_UNIT      1 to skip the login reconcile unit

set -eu

REPO="proto-cool/gamescale"
STEAM_ID="com.valvesoftware.Steam"
STATE_DIR="$HOME/.local/state/gamescale"

MODE="install"; DRY=0
for arg in "$@"; do
    case "$arg" in
        --uninstall|-u) MODE="uninstall" ;;
        --dry-run|-n)   DRY=1 ;;
        --help|-h)      sed -n '2,30p' "$0" | sed 's/^# \?//'; exit 0 ;;
        *)              printf 'unknown option: %s\n' "$arg" >&2; exit 2 ;;
    esac
done

say()  { printf '\033[1m::\033[0m %s\n' "$*"; }
# Confirmation of something that actually happened — silent during a dry run,
# where act() has already printed what would have happened.
note() { [ "$DRY" = 1 ] || say "$@"; }
warn() { printf '\033[33m!!\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[31mxx\033[0m %s\n' "$*" >&2; exit 1; }

# Every mutation goes through this, so --dry-run can't miss one.
act() {
    if [ "$DRY" = 1 ]; then printf '\033[36m--\033[0m would: %s\n' "$*"; return 0; fi
    "$@"
}

# Where the binary lives. Uninstall has to find an install that used a custom
# GAMESCALE_BINDIR without being told again, so look for it rather than
# assuming: the variable, then PATH, then the read-only grant we gave Steam,
# then the default.
find_bindir() {
    if [ -n "${GAMESCALE_BINDIR:-}" ]; then printf '%s' "$GAMESCALE_BINDIR"; return; fi

    found=$(command -v gamescale 2>/dev/null || true)
    if [ -n "$found" ]; then dirname "$found"; return; fi

    if command -v flatpak >/dev/null 2>&1; then
        granted=$(flatpak override --user --show "$STEAM_ID" 2>/dev/null \
            | sed -n 's/^filesystems=//p' | tr ';' '\n' \
            | sed -n 's/:ro$//p' | head -n 1)
        if [ -n "$granted" ] && [ -e "$granted/gamescale" ]; then
            printf '%s' "$granted"; return
        fi
    fi

    printf '%s' "$HOME/.local/bin"
}

BINDIR=$(find_bindir)
TARGET="$BINDIR/gamescale"
[ "$DRY" = 1 ] && say "dry run — nothing will be changed"

# ---------------------------------------------------------------------------
# Uninstall
#
# Flatpak's negation flags are a trap here. --nofilesystem, --no-talk-name and
# --unset-env do not remove a grant, they record an explicit denial:
#
#   filesystems=!/home/you/.local/bin;    org.freedesktop.Flatpak=none
#   unset-environment=PATH;               PATH=
#
# and that last pair is destructive — Steam's own PATH is set in its manifest,
# so unsetting it doesn't restore the default, it wipes /app/bin and
# /app/utils/bin and takes gamescope and MangoHud out with them.
#
# --reset is the only clean removal, and it removes EVERYTHING, including
# grants that have nothing to do with gamescale. So reset only when the app's
# overrides contain nothing but ours, and otherwise print exactly what to
# remove and leave it alone.
# ---------------------------------------------------------------------------

if [ "$MODE" = "uninstall" ]; then
    say "removing gamescale ($TARGET)"

    # Before anything else: if a run died and left the display at 1x, this is
    # the last moment the tool that knows how to undo that still exists.
    if [ -x "$TARGET" ] && [ -e "$STATE_DIR/state" ]; then
        say "stale state found — restoring your display first"
        act "$TARGET" --restore || warn "restore failed; check gdctl show"
    fi

    if command -v systemctl >/dev/null 2>&1; then
        if [ "$DRY" = 1 ]; then
            act systemctl --user disable --now gamescale-reconcile.service
        else
            systemctl --user disable --now gamescale-reconcile.service >/dev/null 2>&1 || true
        fi
        act rm -f "$HOME/.config/systemd/user/gamescale-reconcile.service"
        [ "$DRY" = 1 ] || systemctl --user daemon-reload >/dev/null 2>&1 || true
        note "removed gamescale-reconcile.service"
    fi

    if command -v flatpak >/dev/null 2>&1 && flatpak info "$STEAM_ID" >/dev/null 2>&1; then
        overrides=$(flatpak override --user --show "$STEAM_ID" 2>/dev/null || true)
        # Every line we are responsible for. Anything else in there is the
        # user's, and their overrides are not ours to delete.
        foreign=$(printf '%s\n' "$overrides" \
            | grep -v '^\[' \
            | grep -v '^[[:space:]]*$' \
            | grep -v '^filesystems=' \
            | grep -v '^org\.freedesktop\.Flatpak=talk$' \
            | grep -v '^PATH=' || true)
        fs_foreign=$(printf '%s\n' "$overrides" \
            | sed -n 's/^filesystems=//p' | tr ';' '\n' \
            | grep -v '^[[:space:]]*$' \
            | grep -v "^$BINDIR:ro$" \
            | grep -v "^$STATE_DIR:create$" || true)

        if [ -z "$foreign" ] && [ -z "$fs_foreign" ]; then
            act flatpak override --user --reset "$STEAM_ID"
            note "removed Steam overrides"
        else
            warn "Steam has overrides that gamescale did not add:"
            printf '%s\n' "$foreign" "$fs_foreign" | grep -v '^$' | sed 's/^/     /' >&2
            warn "leaving them alone. To remove only gamescale's, edit:"
            warn "  $HOME/.local/share/flatpak/overrides/$STEAM_ID"
            warn "and drop $BINDIR, $STATE_DIR, org.freedesktop.Flatpak and the"
            warn "trailing $BINDIR from PATH. Do NOT use --nofilesystem or"
            warn "--unset-env: they add denials and wipe Steam's PATH."
        fi
    fi

    act rm -f "$TARGET"
    note "removed $TARGET"
    act rm -rf "$STATE_DIR"
    note "removed $STATE_DIR"
    echo
    if [ "$DRY" = 1 ]; then
        say "dry run finished — nothing was changed"
    else
        say "gamescale is gone. Remove 'gamescale' from your Steam launch options."
    fi
    exit 0
fi

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

act mkdir -p "$BINDIR" "$STATE_DIR"
act install -m 755 "$SRC" "$TARGET"
note "installed $TARGET"

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

    act flatpak override --user \
        --filesystem="$BINDIR:ro" \
        --filesystem="$STATE_DIR:create" \
        --talk-name=org.freedesktop.Flatpak \
        --env=PATH="$new_path" \
        "$STEAM_ID" \
        || die "flatpak override failed"

    note "granted Steam: $BINDIR (ro), $STATE_DIR (rw), host portal, PATH"
fi

# ---------------------------------------------------------------------------
# Login reconcile unit
# ---------------------------------------------------------------------------

if [ "${GAMESCALE_NO_UNIT:-0}" = "1" ]; then
    say "skipping login reconcile unit (GAMESCALE_NO_UNIT=1)"
elif ! command -v systemctl >/dev/null 2>&1; then
    say "no systemd — skipping login reconcile unit"
else
    if [ "$DRY" = 1 ]; then
        act "$TARGET" --install-unit
    elif "$TARGET" --install-unit >/dev/null 2>&1; then
        say "installed gamescale-reconcile.service"
    else
        warn "could not install the login reconcile unit (gamescale --install-unit to retry)"
    fi
fi

# ---------------------------------------------------------------------------
# Verify. Doctor exits 0 regardless; the checkmarks are the report.
# ---------------------------------------------------------------------------

echo
if [ "$DRY" = 1 ]; then
    say "dry run finished — nothing was changed"
else
    "$TARGET" --doctor || true
    echo
    say "Steam launch options:  gamescale %command%"
    say "restart Steam for the new permissions to take effect"
fi
