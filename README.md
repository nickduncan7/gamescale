# gamescale

[![ci](https://github.com/proto-cool/gamescale/actions/workflows/ci.yml/badge.svg)](https://github.com/proto-cool/gamescale/actions/workflows/ci.yml)

Run a game at 1× monitor scale so XWayland hands it your panel's real mode
instead of an overscaled framebuffer — then put your desktop back when it exits.

GNOME/Mutter on Wayland. Works with Flatpak Steam and other Flatpak launchers.

> **Built with [Claude](https://claude.ai) by Anthropic.** AI makes mistakes,
> and this one changes your display configuration — read the script before you
> run it. It isn't unvalidated, though: the numbers below were measured on a
> Lenovo Legion Pro 7i (2560×1600 at 133%) running Fedora Silverblue 44, GNOME
> 50.3 and Flatpak Steam, and CI runs shellcheck plus three test suites — 41
> assertions over the parser, the state format, and the restore-after-SIGKILL
> path — on every push. Other GNOME versions and other hardware are less
> certain; issues welcome.

## The problem

Under GNOME fractional scaling, XWayland gets an **integer** scale factor
applied to your *logical* resolution. On a 2560×1600 panel at 133%:

| | |
|---|---|
| Panel (physical) | 2560×1600 |
| Logical | 1920×1200 |
| XWayland factor `1` | reports **1920×1200** → renders small, stretched up (blurry, cheap) |
| XWayland factor `2` | reports **3840×2400** → renders 2.25× your panel's pixels (sharp, expensive) |

Neither is 2560×1600. Games with borderless-fullscreen-only display options take
whatever the desktop reports and have no way to opt out, so you eat a 2.25×
render cost or play a blurry upscale. `xwayland-scaling-factor` is a single
global value with no per-app override, and per-application X11 scaling doesn't
exist on any compositor — X11 has one screen with one geometry.

**Scale 1.0 is the only configuration where XWayland is handed 2560×1600.**
That's what this does, for the lifetime of one process. Since a permanently
unscaled desktop is a tiny desktop, it also scales font and cursor by the
inverse factor while the game runs, and reverts both on exit.

This is a workaround, and it should have an end date. Upstream tracks the gaps in
[mutter#478](https://gitlab.gnome.org/GNOME/mutter/-/work_items/478) —
*Fractional Scaling Known issues and TODO*, still open — whose list includes
"XWayland clients: support clients with native scaling in unscaled screen". That
item landing and working is the thing to watch: it makes this repo unnecessary,
and deleting it then is the intended outcome.

### Multiple monitors

The XWayland factor only drops to 1 once *every* logical monitor is at 1.0.
Scaling just the one you play on is actively worse:

| Configuration | Framebuffer | Factor | Cost vs native |
|---|---|---|---|
| both at 133% (no gamescale) | 3840×2400 | 2 | 2.25× |
| primary 100%, secondary 133% | **5120×3200** | 2 | **4×** |
| primary 133%, secondary 100% | 3840×2400 | 2 | 2.25× |
| both at 100% | 2560×1600 | 1 | 1× |

Row 2 is what gamescale did before v1.1.0 — 78% *more* pixels than never
running it. Since v1.1.0 every monitor moves to 1× together, and the whole
layout (scales, positions, transforms, which display was primary) is saved and
replayed on exit.

### Two things that don't work

- **Restoring the desktop once the game has started.** Wine tracks RandR events
  and rebuilds its monitor list, so the game follows the screen straight back to
  the overscaled framebuffer. Measured on Halo Campaign Evolved under Proton 11:
  MangoHud's readout went 2560×1600 → 3840×2400 the moment scale was restored.
  Framerate didn't change and it still looked sharp — at factor 2 it always
  does, the cost is pixels, not visible quality. So testing this by eye or by
  FPS on a GPU with headroom reports success when it has failed.
- **`xwayland-native-scaling`.** GNOME 48+ ships this experimental feature aimed
  at the same problem, and it's the mutter#478 item above. On GNOME 50.3 at 133%
  it was still blurry — same result as factor `1`, reached another way. If it
  works on your hardware, use it instead and please open an issue saying so:
  that's a better fix than this repo.

## What it does not do

- **Not a gamescope replacement.** No nested compositor, no upscaling, no frame
  limiting. It changes one display setting and changes it back.
- **Not per-application or per-monitor.** The scope is *temporal*. While the
  game runs, every display is at 1× — it has to be. Alt-tabbing shows a smaller
  desktop with compensated text.
- **Doesn't fix title bars, icons, or panel spacing.** Only text and cursor
  scale; GNOME has no knob for the rest.
- **Can't help a game that ignores what it's told.** This changes what XWayland
  reports; a game still has to listen.

## Install

```sh
curl -fsSL https://raw.githubusercontent.com/proto-cool/gamescale/main/install.sh | sh
```

Installs to `~/.local/bin/gamescale`, grants Flatpak Steam what it needs,
installs the login reconcile unit, and runs `--doctor`. It prints every action,
needs no root, and is safe to re-run. Downloads are checked against the
`SHA256SUMS` published with the release and refused if they don't match.

| | |
|---|---|
| `--platform NAME...` | which launchers to grant (default `steam`) |
| `--dry-run` | print every action, take none |
| `--uninstall` | remove everything it installed |
| `GAMESCALE_REF=v1.2.0` | pin a version |
| `GAMESCALE_BINDIR=...` | install somewhere else |
| `GAMESCALE_NO_FLATPAK=1` | skip launcher grants |
| `GAMESCALE_NO_UNIT=1` | skip the login reconcile unit |
| `GAMESCALE_NO_VERIFY=1` | install without checking the checksum |

Rather not pipe a URL into a shell? Reasonable — this script asks for portal
access to your session. Clone and read it first; a checkout next to the
installer wins over any download:

```sh
git clone https://github.com/proto-cool/gamescale && cd gamescale
./install.sh --dry-run     # then without it
```

### Other launchers

| name | app id |
|---|---|
| `steam` | `com.valvesoftware.Steam` |
| `faugus` | `io.github.Faugus.faugus-launcher` |
| `lutris` | `net.lutris.Lutris` |
| `heroic` | `com.heroicgameslauncher.hgl` |
| `bottles` | `com.usebottles.bottles` |
| `all` | every one of the above that is installed |

Any Flatpak app id works too: `./install.sh --platform steam faugus`. Grants are
computed from each app's own live sandbox `PATH`, which differs per launcher. An
app that already has `home` access (Faugus does, Steam doesn't) needs fewer of
them. The installer names other launchers it finds but never grants to one you
didn't ask for — handing an app portal access to your session shouldn't happen
because a script noticed it was installed.

### What gets granted, and why

```sh
flatpak override --user \
    --filesystem="$HOME/.local/bin:ro" \
    --filesystem="$HOME/.local/state/gamescale:create" \
    --talk-name=org.freedesktop.Flatpak \
    --env=PATH="/app/bin:/app/utils/bin:/usr/bin:$HOME/.local/bin" \
    com.valvesoftware.Steam
```

The sandbox otherwise can't see the script, can't write shared state, can't
reach the host session, and can't resolve the bare name.
`--talk-name=org.freedesktop.Flatpak` is what `flatpak-spawn --host` rides on;
without it the script passes your game through unmodified. `--env=PATH`
*replaces* the sandbox PATH rather than extending it, so `--doctor` checks the
stock entries are still there. Restart the launcher afterwards.

Uninstalling won't touch overrides you added yourself: `flatpak override
--reset` is the only clean removal and it removes everything, so if there's
anything foreign in there the uninstaller prints what to drop and leaves the
file alone. Don't reach for `--nofilesystem` or `--unset-env` by hand — those
record explicit *denials*, and `--unset-env=PATH` wipes the app's own `PATH`.

## Use

Steam launch options (bare name if you applied the `--env=PATH` grant,
otherwise an absolute path — Steam won't expand `~`):

```
gamescale %command%
```

Anywhere else: `gamescale -- /path/to/game`.

| | |
|---|---|
| `--status` | detected monitors and scales, font/cursor, stale state |
| `--doctor` | full dependency and permission check |
| `--restore` | put the display back from a stranded state file |
| `--install-unit` | install the login reconcile service |
| `--version` | which release this is |

| | |
|---|---|
| `GAMESCALE_SCALE` | scale while playing (default `1`) |
| `GAMESCALE_NO_FONT` | `1` to skip font/cursor compensation |
| `GAMESCALE_NO_WATCH` | `1` to skip the host watchdog (trap only) |
| `GAMESCALE_DEBUG` | `1` for verbose logging |

## How it survives things

Restoring **cannot** be owned by anything that dies with the game: under
Flatpak Steam the portal connection dies with the sandbox, so a trap firing
inside a collapsing sandbox has no session bus left to talk to. Ctrl+C on Steam
reproduces it every time. So there are three independent layers, any one of
which is sufficient.

1. **In-sandbox trap** — fast path for normal exit, usually the one that runs.
2. **Host-side watchdog** — before launching, the script takes an `flock` and
   starts a watchdog via `systemd-run --user` that blocks on the same lock. The
   kernel releases it when the holder dies for *any* reason — exit, `SIGKILL`,
   segfault, OOM, Ctrl+C on Steam — and the watchdog then wakes on the host,
   where D-Bus is still alive. No polling, no heartbeat. systemd owns it, so it
   outlives the sandbox.
3. **Login reconcile** — a user unit runs `--restore` at session start, covering
   a hard reboot or a killed watchdog.

The descriptor isn't inherited by the game itself: under pressure-vessel the
game is started through the portal by `steam-runtime-launch-client`, so it isn't
a descendant of the wrapper. `lsof` on the lock shows the wrapper and the
watchdog, never `reaper` or `bwrap`. What the lock tracks is the wrapper, which
blocks until the chain exits.

Four invariants make that safe to rely on:

- **Restore is idempotent.** All three layers may fire in any order; the first
  to succeed clears the state, the rest no-op. A *partial* restore keeps the
  state file so another layer retries.
- **Leftover state is restored before detection.** A stranded 1× can never be
  recorded as your original scale.
- **A failed scale flip never means a failed game launch.** Every config is
  checked with `gdctl set --verify` first, and anything unavailable means the
  game launches unmodified.
- **State is parsed, never sourced,** and written atomically. The state
  directory is writable by the sandboxed app, and `--restore` runs on the host
  from the login unit. Unknown keys and malformed values fail closed.

`gamescale.sh` documents the rest inline — why scales are replayed at full
precision, why applying is relational but restoring is absolute, and what
happens if you unplug a display mid-game.

## Verifying it actually works

The script running without errors and the game getting the right resolution are
different claims.

```sh
# what XWayland reports to the game — 2560x1600 under gamescale, not 3840x2400
flatpak run --command=xrandr com.valvesoftware.Steam | grep '^Screen'

# what the game actually renders at; the least ambiguous check there is
MANGOHUD_CONFIG=fps,resolution gamescale %command%

# the lock is load-bearing: 1 means held, which is what you want.
# check the exit code, not the output — flock -n prints nothing either way
flock -n ~/.local/state/gamescale/lock -c true; echo $?

lsof ~/.local/state/gamescale/lock          # who holds it
systemctl --user list-units 'gamescale-*'   # is the watchdog up

# --doctor from inside the sandbox, which is where things actually break
flatpak run --command=gamescale com.valvesoftware.Steam --doctor
```

If that `flock` prints `0` while a game is running, the lock isn't being held
through the launch chain and the watchdog could restore mid-game — worse than no
watchdog. Set `GAMESCALE_NO_WATCH=1` and open an issue.

## If your desktop is stuck at 1×

```sh
gamescale --restore
```

If the state file is gone too, set it by hand (`gdctl show` gives you the
connector name and scale):

```sh
gdctl set --logical-monitor --primary --monitor eDP-1 --scale 1.3333333730697632
gsettings reset org.gnome.desktop.interface text-scaling-factor
gsettings reset org.gnome.desktop.interface cursor-size
```

## Requirements

- GNOME 48+ on Wayland (`gdctl` ships with Mutter)
- `flock` and `systemd-run` for the watchdog — optional, degrades to trap-only
- `xmllint` for the `monitors.xml` fallback — optional

## Development

```sh
shellcheck -S style gamescale.sh install.sh test/*.sh
./test/detect_test.sh      # gdctl output parsing, connector-name edge cases
./test/state_test.sh       # state format, and the exact config gdctl is sent
./test/watchdog_test.sh    # restore after SIGKILL, and no restore before it
```

The suites stub `gdctl`, `gsettings` and `systemd-run` on `PATH` and drive the
real script end to end, so what's under test is the shipped code. No display is
touched. `test/watchdog_test.sh` takes about 15 seconds; it kills a fake game
with `SIGKILL` so the trap never runs, then asserts the watchdog restored
anyway.
