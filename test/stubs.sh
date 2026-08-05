# shellcheck shell=bash
# Shared stubs for the shell suites. Source this, then call make_stubs "$DIR".
#
# Every stub can be made to FAIL, which is the point. With stubs that always
# succeed, the error branches are unreachable from tests, and a mutation battery
# found exactly that: fifteen injected regressions survived the whole suite —
# font and cursor compensation never restored, a failed state write no longer
# aborting, give_up no longer launching the game — because nothing could ever
# make the underlying command say no.
#
# Seams, all via the environment:
#
#   DETECT_FIXTURE   TSV records `read` answers with
#   PY_LOG           file receiving one line per display-program invocation
#   PY_FAIL_RC       exit status for apply/verify (2 = mutter refused)
#   GS_LOG           file receiving one line per gsettings call
#   GS_FAIL_SET      substring of a gsettings key whose `set` must fail
#   GS_EXT_LIST      what `get org.gnome.shell enabled-extensions` returns
#   SPAWN_LOG        file receiving each flatpak-spawn --host invocation
#   SYSTEMD_RUN_LOG  file receiving each systemd-run invocation
#   FAKE_KVER        kernel release `uname -r` reports (default: the real one)

make_stubs() {
    local dir="$1"
    mkdir -p "$dir"

    # The display program. Records what it was asked to do, answers `read` from
    # the fixture, and refuses configurations that name a monitor the fixture
    # does not have — which is what mutter does, and what makes the
    # unplugged-display fallback reachable instead of assumed.
    cat > "$dir/python3" <<'STUB'
#!/bin/sh
echo "$*" >> "$PY_LOG"
# The PyGObject probe: `python3 -c 'import gi; ...'`. Nothing is piped to it, so
# it must not wait on stdin — draining unconditionally hangs the whole suite.
if [ "${1:-}" = "-c" ]; then
    exit "${GI_FAIL_RC:-0}"
fi
# The real invocation is `python3 - <subcommand>`, with the program on stdin.
# Drain it or the writer gets EPIPE.
if [ "${1:-}" = "-" ]; then
    cat >/dev/null
    shift
fi
cmd="${1:-read}"
if [ "$cmd" = "read" ]; then
    printf '%s\n' "$DETECT_FIXTURE"
    exit 0
fi
[ -n "${PY_FAIL_RC:-}" ] && exit "$PY_FAIL_RC"
shift
present=" $(printf '%s\n' "$DETECT_FIXTURE" | cut -f1 | tr ',' ' ' | tr '\n' ' ') "
for rec in "$@"; do
    case "$rec" in --*) continue ;; esac
    for conn in $(printf '%s' "$rec" | cut -d';' -f1 | tr ',' ' '); do
        case "$present" in
            *" $conn "*) ;;
            *) exit 2 ;;
        esac
    done
done
exit 0
STUB

    # Logs every call, so the font and cursor compensation is observable at all,
    # and can be made to fail on one key so the partial-restore branch runs.
    cat > "$dir/gsettings" <<'STUB'
#!/bin/sh
[ -n "${GS_LOG:-}" ] && echo "$*" >> "$GS_LOG"
if [ "$1" = "set" ]; then
    if [ -n "${GS_FAIL_SET:-}" ]; then
        case "$3" in
            *"$GS_FAIL_SET"*) exit 1 ;;
        esac
    fi
    exit 0
fi
case "$3" in
    text-scaling-factor) echo "${GS_TEXT_SCALE:-1.0}" ;;
    cursor-size)         echo "${GS_CURSOR_SIZE:-24}" ;;
    enabled-extensions)
        # gsettings exits 1 on a schema it does not have, which is what a host
        # without gnome-shell looks like. GS_EXT_LIST=fail reproduces it.
        [ "${GS_EXT_LIST:-}" = "fail" ] && exit 1
        echo "${GS_EXT_LIST:-@as []}" ;;
esac
exit 0
STUB

    # Stands in for systemd's job supervision: drop the flags the real
    # invocation passes and run the rest detached, so it outlives its parent the
    # way an owned unit does.
    cat > "$dir/systemd-run" <<'STUB'
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

    # Lets the sandboxed branch be driven on a machine with no sandbox: records
    # what was asked of the host, then runs it, since in these tests the host is
    # this machine.
    cat > "$dir/flatpak-spawn" <<'STUB'
#!/bin/sh
[ "${1:-}" = "--host" ] && shift
[ -n "${SPAWN_LOG:-}" ] && echo "$*" >> "$SPAWN_LOG"
exec "$@"
STUB

    # --doctor decides whether ntsync is the interface Proton wants by kernel
    # version, and a runner's kernel is whatever it is. Defaults to the truth so
    # every other suite is unaffected by its presence on PATH.
    cat > "$dir/uname" <<'STUB'
#!/bin/sh
if [ -n "${FAKE_KVER:-}" ] && [ "${1:-}" = "-r" ]; then
    echo "$FAKE_KVER"
    exit 0
fi
for real in /usr/bin/uname /bin/uname; do
    [ -x "$real" ] && exec "$real" "$@"
done
exit 1
STUB

    chmod +x "$dir/python3" "$dir/gsettings" "$dir/systemd-run" \
             "$dir/flatpak-spawn" "$dir/uname"
}
