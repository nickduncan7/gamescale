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
# Installs the script, grants the launchers you name what they need to reach
# the host session, installs the login reconcile unit, and runs --doctor.
# Everything it does is printed and individually reversible; nothing needs root.
#
#   --platform NAME...   which launchers to grant (default: steam)
#   --uninstall          remove everything it installed
#   --dry-run            print every action, take none
#
# Known platform names, and any flatpak app id works too:
#
#   steam     com.valvesoftware.Steam
#   faugus    io.github.Faugus.faugus-launcher
#   lutris    net.lutris.Lutris
#   heroic    com.heroicgameslauncher.hgl
#   bottles   com.usebottles.bottles
#   all       every one of the above that is installed
#
#   ./install.sh --platform steam faugus
#   curl -fsSL .../install.sh | sh -s -- --platform steam faugus
#
# Granting is deliberately explicit. Handing an app portal access to your host
# session is the most consequential thing this script does, so it is never done
# to an app you did not name.
#
# ENV
#   GAMESCALE_REF          tag to install               (default: latest release)
#   GAMESCALE_BINDIR       install location             (default: ~/.local/bin)
#   GAMESCALE_NO_FLATPAK   1 to skip launcher grants entirely
#   GAMESCALE_NO_UNIT      1 to skip the login reconcile unit

set -eu

REPO="proto-cool/gamescale"
STATE_DIR="$HOME/.local/state/gamescale"

# name:app-id — the app id is what everything below actually uses.
KNOWN="steam:com.valvesoftware.Steam \
faugus:io.github.Faugus.faugus-launcher \
lutris:net.lutris.Lutris \
heroic:com.heroicgameslauncher.hgl \
bottles:com.usebottles.bottles"

MODE="install"; DRY=0; PLATFORMS=""

while [ $# -gt 0 ]; do
    case "$1" in
        --uninstall|-u) MODE="uninstall"; shift ;;
        --dry-run|-n)   DRY=1; shift ;;
        --platform|-p)
            shift
            # Consume every following value that isn't another option.
            while [ $# -gt 0 ]; do
                case "$1" in -*) break ;; esac
                PLATFORMS="$PLATFORMS $1"
                shift
            done
            ;;
        --help|-h)      sed -n '2,40p' "$0" | sed 's/^# \?//'; exit 0 ;;
        *)              printf 'unknown option: %s\n' "$1" >&2; exit 2 ;;
    esac
done

say()  { printf '\033[1m::\033[0m %s\n' "$*"; }
note() { [ "$DRY" = 1 ] || say "$@"; }
warn() { printf '\033[33m!!\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[31mxx\033[0m %s\n' "$*" >&2; exit 1; }

# Every mutation goes through this, so --dry-run can't miss one.
act() {
    if [ "$DRY" = 1 ]; then printf '\033[36m--\033[0m would: %s\n' "$*"; return 0; fi
    "$@"
}

known_ids()   { for p in $KNOWN; do printf '%s ' "${p#*:}"; done; }
name_for()    { for p in $KNOWN; do [ "${p#*:}" = "$1" ] && { printf '%s' "${p%%:*}"; return; }; done
                printf '%s' "$1"; }

# A name from the table, or any app id (anything containing a dot).
resolve_platform() {
    case "$1" in *.*) printf '%s' "$1"; return 0 ;; esac
    for p in $KNOWN; do
        [ "${p%%:*}" = "$1" ] && { printf '%s' "${p#*:}"; return 0; }
    done
    return 1
}

installed() { command -v flatpak >/dev/null 2>&1 && flatpak info "$1" >/dev/null 2>&1; }

APPS=""
[ -n "$PLATFORMS" ] || PLATFORMS="steam"
case " $PLATFORMS " in
    *" all "*)
        PLATFORMS=""
        for id in $(known_ids); do installed "$id" && PLATFORMS="$PLATFORMS $(name_for "$id")"; done
        [ -n "$PLATFORMS" ] || warn "no known launchers installed"
        ;;
esac
for p in $PLATFORMS; do
    id=$(resolve_platform "$p") \
        || die "unknown platform '$p' — known: $(for k in $KNOWN; do printf '%s ' "${k%%:*}"; done)or a flatpak app id"
    APPS="$APPS $id"
done

# Where the binary lives. Uninstall has to find an install that used a custom
# GAMESCALE_BINDIR without being told again, so look for it rather than
# assuming: the variable, then PATH, then a read-only grant we gave a launcher,
# then the default.
find_bindir() {
    if [ -n "${GAMESCALE_BINDIR:-}" ]; then printf '%s' "$GAMESCALE_BINDIR"; return; fi

    found=$(command -v gamescale 2>/dev/null || true)
    if [ -n "$found" ]; then dirname "$found"; return; fi

    if command -v flatpak >/dev/null 2>&1; then
        for id in $(known_ids); do
            granted=$(flatpak override --user --show "$id" 2>/dev/null \
                | sed -n 's/^filesystems=//p' | tr ';' '\n' \
                | sed -n 's/:ro$//p' | head -n 1)
            if [ -n "$granted" ] && [ -e "$granted/gamescale" ]; then
                printf '%s' "$granted"; return
            fi
        done
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
# and that last pair is destructive — an app's PATH is set in its manifest, so
# unsetting it doesn't restore a default, it drops /app/bin and /app/utils/bin.
# (gamescope and MangoHud survive that: launchers add their Vulkan extension
# directories themselves at startup, independent of PATH.)
#
# --reset is the only clean removal, and it removes EVERYTHING, including
# grants that have nothing to do with gamescale. So reset only when an app's
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

    # Clean every known launcher, not just the ones named: you should not have
    # to remember which you granted months ago.
    if command -v flatpak >/dev/null 2>&1; then
        for id in $(known_ids) $APPS; do
            installed "$id" || continue
            overrides=$(flatpak override --user --show "$id" 2>/dev/null || true)
            [ -n "$overrides" ] || continue

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
                act flatpak override --user --reset "$id"
                note "removed $(name_for "$id") overrides"
            else
                warn "$(name_for "$id") has overrides that gamescale did not add:"
                printf '%s\n' "$foreign" "$fs_foreign" | grep -v '^$' | sed 's/^/     /' >&2
                warn "leaving them alone. To remove only gamescale's, edit:"
                warn "  $HOME/.local/share/flatpak/overrides/$id"
                warn "and drop $BINDIR, $STATE_DIR, org.freedesktop.Flatpak and the"
                warn "trailing $BINDIR from PATH. Do NOT use --nofilesystem or"
                warn "--unset-env: they add denials and wipe the app's PATH."
            fi
        done
    fi

    act rm -f "$TARGET"
    note "removed $TARGET"
    act rm -rf "$STATE_DIR"
    note "removed $STATE_DIR"
    echo
    if [ "$DRY" = 1 ]; then
        say "dry run finished — nothing was changed"
    else
        say "gamescale is gone. Remove it from your launch options."
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
# Launcher grants. Up to four: read the script, share state, reach the host
# session, resolve the bare name. An app with home access already covers the
# first two, so it only needs the last two. --user overrides apply to
# system-installed apps too, so this never needs root.
# ---------------------------------------------------------------------------

app_has_home() {
    flatpak info --show-permissions "$1" 2>/dev/null \
        | sed -n 's/^filesystems=//p' | tr ';' '\n' \
        | grep -qE '^(home|host)$'
}

grant_app() {
    app="$1"

    # Read the app's live sandbox PATH rather than assuming it — every launcher
    # has a different one, and --env=PATH replaces the value outright. Starting
    # from whatever the app ships today is the only way to avoid pinning a
    # stale one, and it keeps re-running idempotent.
    sandbox_path=$(flatpak run --command=sh "$app" -c 'printf %s "$PATH"' 2>/dev/null) || sandbox_path=""
    if [ -z "$sandbox_path" ]; then
        sandbox_path="/app/bin:/app/utils/bin:/usr/bin"
        warn "could not read $(name_for "$app")'s sandbox PATH; assuming $sandbox_path"
    fi

    case ":$sandbox_path:" in
        *":$BINDIR:"*) new_path="$sandbox_path" ;;
        *)             new_path="$sandbox_path:$BINDIR" ;;
    esac

    if app_has_home "$app"; then
        act flatpak override --user \
            --talk-name=org.freedesktop.Flatpak \
            --env=PATH="$new_path" \
            "$app" || die "flatpak override failed for $app"
        note "granted $(name_for "$app"): host portal, PATH (already had home access)"
    else
        act flatpak override --user \
            --filesystem="$BINDIR:ro" \
            --filesystem="$STATE_DIR:create" \
            --talk-name=org.freedesktop.Flatpak \
            --env=PATH="$new_path" \
            "$app" || die "flatpak override failed for $app"
        note "granted $(name_for "$app"): $BINDIR (ro), $STATE_DIR (rw), host portal, PATH"
    fi
}

if [ "${GAMESCALE_NO_FLATPAK:-0}" = "1" ]; then
    say "skipping launcher grants (GAMESCALE_NO_FLATPAK=1)"
elif ! command -v flatpak >/dev/null 2>&1; then
    say "no flatpak on this system — skipping launcher grants"
else
    for id in $APPS; do
        if installed "$id"; then
            grant_app "$id"
        else
            say "$(name_for "$id") is not installed — skipping"
        fi
    done

    # Name what else is here, but never grant it unasked.
    others=""
    for id in $(known_ids); do
        case " $APPS " in *" $id "*) continue ;; esac
        installed "$id" && others="$others $(name_for "$id")"
    done
    if [ -n "$others" ]; then
        say "also installed, not granted:$others"
        say "  to include:  ./install.sh --platform$( for p in $PLATFORMS; do printf ' %s' "$p"; done)$others"
    fi
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
# Verify. Doctor exits non-zero if a check failed; the checkmarks are the report.
# ---------------------------------------------------------------------------

echo
if [ "$DRY" = 1 ]; then
    say "dry run finished — nothing was changed"
else
    "$TARGET" --doctor || true
    echo
    for id in $APPS; do
        case "$id" in
            com.valvesoftware.Steam)
                say "Steam launch options:  gamescale %command%" ;;
            *)
                say "$(name_for "$id"): set gamescale as the wrapper/prefix for your game" ;;
        esac
    done
    say "restart the launchers above for the new permissions to take effect"
fi
