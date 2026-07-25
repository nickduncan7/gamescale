#!/usr/bin/env bash
#
# Installer tests.
#
# install.sh was linted but never run until 1.4.0, and two bugs shipped through
# that gap: piped to sh it installed any gamescale.sh from the current directory,
# skipping the checksum, and --help printed a sed error. CI now smoke-tests it,
# but a smoke test only proves it exits 0. This asserts what it actually does.
#
# The grant argv is the thing worth pinning: the script's own header calls
# granting a launcher portal access the most consequential thing it does. A
# dropped --talk-name means gamescale can never restore a display; an extra app
# in that list is a security regression.
#
# Everything runs against stubbed flatpak/systemctl/curl and a scratch HOME.
# Nothing touches the real system.
#
#   ./test/install_test.sh

set -uo pipefail

INSTALLER="$(cd "$(dirname "$0")/.." && pwd)/install.sh"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

STUBS="$WORK/bin"; FAKEHOME="$WORK/home"; BINDIR="$WORK/home/bin"
mkdir -p "$STUBS" "$FAKEHOME" "$BINDIR"
FLATPAK_LOG="$WORK/flatpak.log"
SERVE="$WORK/serve"; mkdir -p "$SERVE"
INST="$WORK/inst"; mkdir -p "$INST"
cp "$INSTALLER" "$INST/install.sh"

# Records every flatpak call and answers the queries the installer makes.
# INSTALLED lists the app ids that exist; OVERRIDES is what --show returns.
cat > "$STUBS/flatpak" <<'STUB'
#!/bin/sh
echo "$*" >> "$FLATPAK_LOG"
case "$1" in
    info)
        for app; do :; done   # the id is the last argument
        case " ${INSTALLED:-} " in
            *" $app "*)
                if [ "$app" = "${HOME_ACCESS_APP:-}" ]; then
                    echo "filesystems=home"
                else
                    echo "filesystems=xdg-run/pipewire"
                fi
                exit 0 ;;
            *) exit 1 ;;
        esac ;;
    override)
        for arg in "$@"; do
            [ "$arg" = "--show" ] && { printf '%s\n' "${OVERRIDES:-}"; exit 0; }
        done
        exit 0 ;;
    run) printf '%s' "${SANDBOX_PATH:-/app/bin:/app/utils/bin:/usr/bin}"; exit 0 ;;
esac
exit 0
STUB

cat > "$STUBS/systemctl" <<'STUB'
#!/bin/sh
exit 0
STUB

# Serves files out of $SERVE, so the download-and-verify path can be driven
# without a network.
cat > "$STUBS/curl" <<'STUB'
#!/bin/sh
out=""; url=""
while [ $# -gt 0 ]; do
    case "$1" in
        -o) out="$2"; shift 2 ;;
        -*) shift ;;
        *)  url="$1"; shift ;;
    esac
done
name=$(basename "$url")
[ -f "$SERVE/$name" ] || exit 22
cat "$SERVE/$name" > "$out"
exit 0
STUB

chmod +x "$STUBS/flatpak" "$STUBS/systemctl" "$STUBS/curl"

PASS=0; FAIL=0
ok()  { printf '  \033[32mok\033[0m   %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL + 1)); }

install_sh() {  # install_sh ARGS... ; env comes from the caller
    : > "$FLATPAK_LOG"
    # -u, not just assignment: an ambient GAMESCALE_NO_FLATPAK=1 turns off the
    # grants this suite asserts, and a CI step that set it for other reasons is
    # exactly how that happened.
    env -u GAMESCALE_NO_FLATPAK -u GAMESCALE_REF -u GAMESCALE_NO_VERIFY \
        HOME="$FAKEHOME" GAMESCALE_BINDIR="$BINDIR" PATH="$STUBS:/usr/bin:/bin" \
        FLATPAK_LOG="$FLATPAK_LOG" INSTALLED="${INSTALLED:-}" \
        HOME_ACCESS_APP="${HOME_ACCESS_APP:-}" OVERRIDES="${OVERRIDES:-}" \
        SANDBOX_PATH="${SANDBOX_PATH:-}" SERVE="$SERVE" \
        GAMESCALE_NO_UNIT=1 \
        sh "$INST/install.sh" "$@" 2>&1
}

granted() { grep '^override' "$FLATPAK_LOG"; }

# A served "release", valid by default. The checksum cases rewrite SHA256SUMS.
printf '#!/bin/sh\n# GAMESCALE_SCALE\necho hello\n' > "$SERVE/gamescale.sh"
cp "$INSTALLER" "$SERVE/install.sh"
REAL_SUM=$(sha256sum "$SERVE/gamescale.sh" | cut -d' ' -f1)
printf '%s  gamescale.sh\n' "$REAL_SUM" > "$SERVE/SHA256SUMS"

echo "installer"
echo

# --- the grant argv, for exactly the apps named ------------------------------
INSTALLED="com.valvesoftware.Steam io.github.Faugus.faugus-launcher net.lutris.Lutris"
out=$(install_sh --platform steam)

if granted | grep -q -- "--talk-name=org.freedesktop.Flatpak"; then
    ok "grants portal access, without which nothing can be restored"
else
    bad "no --talk-name grant"; printf '        %s\n' "$(granted)"
fi
if granted | grep -q -- "--filesystem=$BINDIR:ro"; then
    ok "grants the script read-only"
else
    bad "no read-only bindir grant"; printf '        %s\n' "$(granted)"
fi
if granted | grep -q -- "--filesystem=$FAKEHOME/.local/state/gamescale:create"; then
    ok "grants the shared state directory"
else
    bad "no state dir grant"; printf '        %s\n' "$(granted)"
fi
if granted | grep -q -- "--env=PATH=.*:$BINDIR"; then
    ok "extends the sandbox PATH rather than replacing it"
else
    bad "PATH grant does not end in the bindir"; printf '        %s\n' "$(granted)"
fi
if granted | grep -q 'com.valvesoftware.Steam'; then
    ok "grants the app that was asked for"
else
    bad "Steam was not granted"
fi
# Consent is per app. A script noticing an app is installed is not permission.
for other in io.github.Faugus.faugus-launcher net.lutris.Lutris; do
    if granted | grep -q "$other"; then
        bad "granted $other without being asked"
        printf '        %s\n' "$(granted)"
    else
        ok "$(basename "$other") installed but not granted"
    fi
done
if [[ "$out" == *"also installed, not granted"* ]]; then
    ok "names the launchers it left alone"
else
    bad "did not mention the other launchers"
fi

# An app that already has home access needs neither filesystem grant.
HOME_ACCESS_APP="io.github.Faugus.faugus-launcher"
out=$(install_sh --platform faugus)
if granted | grep -q 'faugus'; then
    if granted | grep -q -- "--filesystem="; then
        bad "gave filesystem grants to an app with home access"
        printf '        %s\n' "$(granted)"
    else
        ok "an app with home access gets no filesystem grants"
    fi
else
    bad "faugus was not granted at all"
fi
HOME_ACCESS_APP=""

# --- --dry-run changes nothing ------------------------------------------------
# It prints every action and takes none. It used to start each launcher's sandbox
# to read its PATH, which is both an action and a slow one.
rm -f "$BINDIR/gamescale"
out=$(install_sh --dry-run --platform steam)
if [[ -n "$(granted)" ]]; then
    bad "--dry-run executed an override"; printf '        %s\n' "$(granted)"
else
    ok "--dry-run executes no override"
fi
if grep -q '^run ' "$FLATPAK_LOG"; then
    bad "--dry-run started a launcher's sandbox"
else
    ok "--dry-run does not start a sandbox"
fi
if [[ ! -e "$BINDIR/gamescale" ]]; then
    ok "--dry-run installs nothing"
else
    bad "--dry-run installed the script"
fi
if [[ "$out" == *"would:"* ]]; then
    ok "--dry-run says what it would do"
else
    bad "--dry-run printed no actions"
fi

# --- the sandbox PATH is read, never assumed ---------------------------------
# Every launcher's PATH differs; replacing it with a guess is what breaks the
# stock entries the app needs.
SANDBOX_PATH="/app/bin:/app/utils/bin:/usr/bin:/usr/lib/extensions/vulkan/MangoHud/bin"
out=$(install_sh --platform steam)
if granted | grep -q -- "--env=PATH=/app/bin:/app/utils/bin:/usr/bin:/usr/lib/extensions/vulkan/MangoHud/bin:$BINDIR"; then
    ok "the app's own PATH is preserved and extended"
else
    bad "the app's PATH was not preserved"; printf '        %s\n' "$(granted)"
fi
# Re-running must not append the bindir twice.
out=$(install_sh --platform steam)
path_value=$(granted | tr ' ' '\n' | sed -n 's/^--env=PATH=//p')
if [[ "$(printf '%s' "$path_value" | grep -o -- "$BINDIR" | wc -l)" == "1" ]]; then
    ok "re-running does not append the bindir twice"
else
    bad "the bindir appears $(printf '%s' "$path_value" | grep -o -- "$BINDIR" | wc -l) times in PATH"
    printf '        %s\n' "$path_value"
fi
SANDBOX_PATH=""

# --- denials are never used --------------------------------------------------
# --nofilesystem and --unset-env record explicit DENIALS rather than removing a
# grant, and --unset-env=PATH wipes the app's own PATH.
out=$(install_sh --uninstall)
if grep -qE -- '--nofilesystem|--unset-env|--no-talk-name' "$FLATPAK_LOG"; then
    bad "uninstall used a denial flag"; printf '        %s\n' "$(cat "$FLATPAK_LOG")"
else
    ok "uninstall never uses denial flags"
fi

# --- reset only what we granted ----------------------------------------------
# An app carrying only the user's own overrides must be left alone: --reset
# removes everything, and gamescale never granted it anything.
INSTALLED="com.valvesoftware.Steam"
OVERRIDES="[Environment]
PATH=/app/bin:/opt/mytools/bin"
out=$(install_sh --uninstall)
if granted | grep -q -- '--reset'; then
    bad "reset an app gamescale never granted anything"
    printf '        overrides were: %s\n' "$OVERRIDES"
else
    ok "leaves an app we never granted alone"
fi

# Ours and only ours: reset is correct here.
OVERRIDES="[Context]
filesystems=$FAKEHOME/.local/state/gamescale:create;$BINDIR:ro;

[Session Bus Policy]
org.freedesktop.Flatpak=talk

[Environment]
PATH=/app/bin:/app/utils/bin:/usr/bin:$BINDIR"
out=$(install_sh --uninstall)
if granted | grep -q -- '--reset'; then
    ok "resets an app carrying only our grants"
else
    bad "did not reset an app carrying only our grants"
    printf '        %s\n' "$(granted)"
fi

# Ours plus something foreign: warn, don't reset.
OVERRIDES="[Context]
filesystems=$BINDIR:ro;/media/games:ro;

[Session Bus Policy]
org.freedesktop.Flatpak=talk"
out=$(install_sh --uninstall)
if granted | grep -q -- '--reset'; then
    bad "reset an app with foreign overrides"
else
    ok "warns instead of resetting when foreign overrides exist"
fi
if [[ "$out" == *"/media/games"* ]]; then
    ok "names the foreign override it refused to touch"
else
    bad "did not name the foreign override"
fi
OVERRIDES=""

# --- checksums fail closed ---------------------------------------------------
# The installed script is what runs with portal access, so a mismatch must stop
# the install rather than warn about it.
rm -f "$BINDIR/gamescale"
out=$(install_sh)
if [[ -x "$BINDIR/gamescale" ]]; then
    ok "a matching checksum installs"
else
    bad "a matching checksum did not install"; printf '%s\n' "$out" | sed 's/^/        /'
fi

printf '%s  gamescale.sh\n' "${REAL_SUM//[0-9a-f]/0}" > "$SERVE/SHA256SUMS"
rm -f "$BINDIR/gamescale"
out=$(install_sh); rc=$?
if [[ ! -e "$BINDIR/gamescale" ]]; then
    ok "a mismatching checksum installs nothing"
else
    bad "installed despite a checksum mismatch"
fi
if [[ $rc -ne 0 && "$out" == *"MISMATCH"* ]]; then
    ok "a mismatching checksum fails loudly"
else
    bad "a mismatch was not reported"; printf '%s\n' "$out" | sed 's/^/        /'
fi

rm -f "$SERVE/SHA256SUMS" "$BINDIR/gamescale"
out=$(install_sh); rc=$?
if [[ ! -e "$BINDIR/gamescale" && $rc -ne 0 ]]; then
    ok "a missing SHA256SUMS installs nothing"
else
    bad "installed with no checksums published"
fi
if [[ "$out" == *"GAMESCALE_NO_VERIFY=1"* ]]; then
    ok "says how to proceed deliberately"
else
    bad "did not mention the override"
fi

# A cwd containing a gamescale.sh must NOT be treated as a checkout when the
# installer arrives on stdin — that path skips the download and the checksum.
mkdir -p "$WORK/cwd"
printf '#!/bin/sh\n# GAMESCALE_SCALE\necho pwned\n' > "$WORK/cwd/gamescale.sh"
printf '%s  gamescale.sh\n' "$REAL_SUM" > "$SERVE/SHA256SUMS"
rm -f "$BINDIR/gamescale"
out=$(cd "$WORK/cwd" && env HOME="$FAKEHOME" GAMESCALE_BINDIR="$BINDIR" \
    PATH="$STUBS:/usr/bin:/bin" FLATPAK_LOG="$FLATPAK_LOG" SERVE="$SERVE" \
    GAMESCALE_NO_UNIT=1 GAMESCALE_NO_FLATPAK=1 sh < "$INSTALLER" 2>&1)
if [[ "$out" == *"checksum verified"* ]]; then
    ok "piped: downloads and verifies instead of trusting the cwd"
else
    bad "piped: took a script from the current directory"
    printf '%s\n' "$out" | sed 's/^/        /'
fi
if grep -q pwned "$BINDIR/gamescale" 2>/dev/null; then
    bad "piped: installed the cwd's script"
else
    ok "piped: the cwd's script was not installed"
fi

# --- uninstall restores a stranded display before removing the tool ----------
# The last moment the thing that knows how to undo 1x still exists.
cat > "$BINDIR/gamescale" <<EOF
#!/bin/sh
echo "\$*" >> "$WORK/restore.log"
EOF
chmod +x "$BINDIR/gamescale"
mkdir -p "$FAKEHOME/.local/state/gamescale"
printf 'version=2\nmonitor=eDP-1;1.5;yes;0;0;normal\n' > "$FAKEHOME/.local/state/gamescale/state"
: > "$WORK/restore.log"
INSTALLED=""
out=$(install_sh --uninstall)
if grep -q -- '--restore' "$WORK/restore.log"; then
    ok "uninstall restores a stale display first"
else
    bad "uninstall removed the tool without restoring"
fi
if [[ ! -e "$BINDIR/gamescale" ]]; then
    ok "uninstall removes the binary"
else
    bad "uninstall left the binary behind"
fi

echo
echo "  $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
