# gamescale

Run a game at 1× monitor scale so XWayland hands it your panel's real mode
instead of an overscaled framebuffer — then put your desktop back when it exits.

Written for GNOME/Mutter on Wayland. Works with Flatpak Steam.

> **Built with [Claude](https://claude.ai) by Anthropic.** AI makes mistakes,
> and this one changes your display configuration — read the script before you
> run it. That said, it isn't unvalidated: every claim in this README was
> measured on the hardware it was written for, a Lenovo Legion Pro 7i
> (2560×1600 at 133%) running Fedora Silverblue 44 with GNOME 50.3 and Flatpak
> Steam, including the multi-monitor numbers below, and the repo has tests that
> stub `gdctl` and assert on the exact configuration it would apply. Behaviour
> on other GNOME versions, other compositors, or hardware I couldn't test is
> less certain — issues welcome.

---

## The problem

Under GNOME fractional scaling, XWayland is given an **integer** scale factor
applied to your *logical* resolution. On a 2560×1600 panel at 133% scale:

| | |
|---|---|
| Panel (physical) | 2560×1600 |
| Logical | 1920×1200 |
| XWayland factor `1` | reports **1920×1200** → game renders small, gets stretched up (blurry, cheap) |
| XWayland factor `2` | reports **3840×2400** → game renders 2.25× your panel's pixels (sharp, expensive) |

Neither is 2560×1600. Games with borderless-fullscreen-only display options —
no resolution picker, they just take whatever the desktop reports — have no way
to opt out. You either eat a 2.25× render cost or you play a blurry upscale.

`xwayland-scaling-factor` is a **single global value** with no per-app or
per-window override. Per-application X11 scaling doesn't exist on any
compositor; X11 has one screen with one geometry. KWin exposes a "legacy apps
apply scaling themselves" mode that GNOME lacks, but it's equally global.

**Scale 1.0 is the only configuration where XWayland is handed 2560×1600.**
That's what this does, for the lifetime of one process.

Fixing this by turning off fractional scaling permanently means a tiny desktop.
So gamescale also scales your font and cursor by the inverse factor while the
game runs — poor man's fractional scaling — and reverts both on exit.

### Multiple monitors

The XWayland factor is **global**. It only drops to 1 once *every* logical
monitor is at 1.0 — scaling just the one you play on doesn't help, and is
actively worse. Measured on a 2560×1600 panel at 133% with a second display
attached, reading `Screen 0` from inside the Steam sandbox:

| Configuration | Framebuffer | Factor | Cost vs native |
|---|---|---|---|
| both at 133% (no gamescale) | 3840×2400 | 2 | 2.25× |
| primary 100%, secondary 133% | **5120×3200** | 2 | **4×** |
| primary 133%, secondary 100% | 3840×2400 | 2 | 2.25× |
| both at 100% | 2560×1600 | 1 | 1× |

Row 2 is what gamescale did before v1.1.0: the factor stays at 2, but now
multiplies a full-resolution logical size, so the game renders 78% *more*
pixels than if you'd never run it. Since v1.1.0 every monitor is set to 1×
together, and the whole layout — scales, positions, transforms, which display
was primary — is saved and replayed on exit.

### What about `xwayland-native-scaling`?

GNOME 48+ ships an experimental feature aimed at this:

```sh
gsettings set org.gnome.mutter experimental-features "['xwayland-native-scaling']"
```

Tried on GNOME 50.3, 2560×1600 at 133%: still blurry. With fractional scaling
on, the game appears to render at logical pixels and get upscaled — the same
result as XWayland factor `1`, reached by a different route. That's an
observation, not a mechanism; the pixels were visibly soft and 1× scaling
looked better.

If it works on your hardware, use it — it would be a better fix than this repo.
Please open an issue saying so.

## What it does not do

- **Not a gamescope replacement.** No nested compositor, no upscaling, no
  frame limiting. It changes one display setting and changes it back.
- **Not per-application, and not per-monitor.** The scope is *temporal*, not
  spatial. While the game runs, *every* display is at 1× — it has to be, see
  below. Alt-tabbing shows a smaller desktop with compensated text — better
  than raw 1×, not identical to your normal setup.
- **Doesn't fix title bars, icons, or panel spacing.** Only text and cursor
  scale. GNOME has no knob for the rest.
- **Can't help a game that ignores what it's told.** Some games won't offer
  your panel's native mode no matter what the desktop reports. This changes
  what XWayland says; a game still has to listen.

---

## Install

```sh
curl -fsSL https://raw.githubusercontent.com/proto-cool/gamescale/main/install.sh | sh
```

Installs to `~/.local/bin/gamescale`, applies the Flatpak Steam grants below,
installs the login reconcile unit, and runs `--doctor`. It prints every action,
needs no root, and is safe to re-run. `GAMESCALE_NO_FLATPAK=1` or
`GAMESCALE_NO_UNIT=1` to opt out of either half; `GAMESCALE_REF=v1.0.0` to pin
a version.

If you'd rather not pipe a URL into a shell — reasonable, given this script
asks for portal access to your session — clone and read it first:

```sh
git clone https://github.com/proto-cool/gamescale && cd gamescale
./install.sh          # installs the gamescale.sh sitting next to it
```

Or do it by hand:

```sh
mkdir -p ~/.local/bin ~/.local/state/gamescale
install -m 755 gamescale.sh ~/.local/bin/gamescale
```

`~/.local/bin` is on `$PATH` on most distributions, so `gamescale` is now a
command. The script finds its own path, so the installed name is yours to
choose.

### Flatpak Steam

The installer does all of this for you; it's spelled out because you should
know what you granted.

The sandbox can't see your script, can't reach the host session, can't write
shared state, and can't resolve the name without four grants:

```sh
flatpak override --user \
    --filesystem="$HOME/.local/bin:ro" \
    --filesystem="$HOME/.local/state/gamescale:create" \
    --talk-name=org.freedesktop.Flatpak \
    --env=PATH="/app/bin:/app/utils/bin:/usr/bin:$HOME/.local/bin" \
    com.valvesoftware.Steam
```

`--talk-name=org.freedesktop.Flatpak` is what `flatpak-spawn --host` rides on.
Without it the script detects the sandbox, finds it can't reach `gdctl`, and
passes your game through unmodified.

`--env=PATH` is what lets the launch option be a bare `gamescale` instead of an
absolute path — the sandbox PATH is `/app/bin:/app/utils/bin:/usr/bin` and has
no notion of your home directory. Note that it *replaces* the sandbox PATH
rather than extending it, so if a future Steam release adds a directory you
won't get it; `--doctor` checks the stock entries are still present and tells
you to re-apply if not. Skip this grant if you'd rather paste the full path.

Restart Steam after any of these.

### Uninstall

```sh
./install.sh --uninstall            # or: curl -fsSL .../install.sh | sh -s -- --uninstall
```

Add `--dry-run` to either the install or the uninstall to print every action
without taking any — worth doing before an install that grants a sandbox you
care about four permissions.

The uninstaller finds a custom `GAMESCALE_BINDIR` install without being told
again: it checks the variable, then `PATH`, then the read-only grant given to
Steam.

Restores your display first if a run died and left it at 1×, then removes the
binary, the state directory, the systemd unit, and the Steam overrides.

It will **not** touch Steam overrides you added yourself. `flatpak override
--reset` is the only clean removal and it removes everything, so if there's
anything in there that isn't gamescale's, the uninstaller prints what to drop
and leaves the file alone. Don't reach for `--nofilesystem` or `--unset-env` to
do it by hand: those record explicit *denials* rather than removing a grant,
and `--unset-env=PATH` wipes Steam's own `PATH`, losing `/app/bin` and
`/app/utils/bin`. (gamescope and MangoHud survive that — Steam's launcher adds
their Vulkan extension directories itself at startup, independent of `PATH`.)

### Login reconcile service

Covers the case where the machine goes down mid-game:

```sh
gamescale --install-unit
```

### Verify

```sh
gamescale --doctor
```

Checks each moving part separately — portal reachability, `gdctl`,
`gsettings`, state-dir writability from both sides, `systemd-run`, `flock`,
monitor detection, stale state. When something breaks later, this tells you
*which* link, instead of a generic failure.

From inside the sandbox specifically:

```sh
flatpak run --command=gamescale com.valvesoftware.Steam --doctor
```

---

## Use

Steam launch options — bare name if you applied the `--env=PATH` grant above,
otherwise the absolute path (Steam won't expand `~`):

```
gamescale %command%
```

Anywhere else:

```sh
gamescale -- /path/to/game
```

### Commands

| | |
|---|---|
| `--status` | detected monitors and scales, font/cursor, stale state |
| `--doctor` | full dependency and permission check |
| `--restore` | put the display back from a stranded state file |
| `--install-unit` | install the login reconcile service |
| `--watchdog` | internal; started by systemd, not by you |

### Environment

| | |
|---|---|
| `GAMESCALE_SCALE` | scale while playing (default `1`) |
| `GAMESCALE_MONITOR` | ignored since v1.1.0 — every monitor has to reach 1× |
| `GAMESCALE_NO_FONT` | `1` to skip font/cursor compensation |
| `GAMESCALE_NO_WATCH` | `1` to skip the host watchdog (trap only) |
| `GAMESCALE_DEBUG` | `1` for verbose logging |

---

## How it survives things

Restoring **cannot** be owned by anything that dies with the game. Under
Flatpak Steam, the portal connection dies with the sandbox — a trap firing
inside a collapsing sandbox has no session bus left to talk to. Ctrl+C on Steam
reproduces this every time:

```
Can't find bus: Could not connect: Connection refused
gamescale: FAILED to restore scale 1.3333333730697632 on eDP-1
```

So there are three independent layers. Any one is sufficient.

**1. In-sandbox trap.** Fast path for normal exit. Cheap, and usually the one
that runs.

**2. Host-side watchdog.** Before launching, the script takes an `flock` on a
file in the shared state directory and starts a watchdog through
`systemd-run --user`. The watchdog blocks trying to acquire that same lock. FD 9
is inherited across fork and exec, so every process in the game's tree holds it,
and the kernel releases it only when the last one is gone — normal exit,
`SIGKILL`, segfault, OOM kill, Ctrl+C on Steam, all identical. The watchdog then
wakes on the host, where D-Bus is still alive, and restores. No polling, no
heartbeat, no timeout race. systemd owns the watchdog, so it outlives the
sandbox that spawned it.

**3. Login reconcile.** A user unit runs `--restore` on session start, covering
a hard reboot or a killed watchdog.

Plus two safety properties:

- **Self-healing on next launch.** Leftover state is restored *before* detection
  runs, so a stranded 1× is never recorded as your "original" scale.
- **Idempotent restore.** All three layers can fire in any order or
  simultaneously. First one to succeed clears the state; the rest no-op.

State lives on the host filesystem, not in the sandbox's private runtime dir,
so the watchdog, the login unit, and your shell all see the same file.

### Implementation notes

- Scale is stored and replayed at **full precision**
  (`1.3333333730697632`, not `1.333`). `gdctl` only accepts a scale its modes
  actually support, and echoing back the exact double it reported avoids a
  rejection on the restore path — the one failure you'd least want.
- Detection prefers `gdctl show` (live state), falling back to
  `monitors.xml` (saved config) for setups that have never opened the Displays
  panel. Every logical monitor is captured, not just the primary one.
- `gdctl set` **replaces** the whole configuration — a monitor left out of the
  command is a monitor switched off. So every generated config lists every
  monitor, and is checked with `gdctl set --verify` before being applied. If
  verification fails, the game launches unmodified rather than gambling with
  your display arrangement.
- Restoring replays exact saved coordinates. Applying can't: at 1× each logical
  monitor grows, so the old coordinates would overlap and be rejected. It
  rebuilds the arrangement relationally (`--right-of` / `--below`) in the
  original left-to-right or top-to-bottom order and lets mutter do the layout.
- If a display is unplugged mid-game, the saved layout no longer applies. The
  restore path falls back to replaying only the monitors still connected,
  promoting a new primary if that one went away — a state file that can never
  be applied would mean a desktop permanently stuck at 1×.
- If anything is unavailable, the game still launches, unmodified. A failed
  scale flip should never mean a failed game launch.
- The state file is written to a sibling and renamed, so a reader sees the
  whole old state or the whole new one — never a truncated scale. A partial
  write here is worse than no state at all: `gdctl` rejects the bad value,
  every restore layer fails identically, and the retry logic keeps you at 1×.
- It is parsed as strict `key=value`, never sourced. The state directory is
  writable by the sandboxed app being launched, and `--restore` runs on the
  host from the login unit — sourcing it there would execute its contents
  outside the sandbox at every session start. Unknown keys and malformed
  values fail closed.

---

## Verifying it actually works

The script running without errors and the game getting the right resolution are
different claims. Check the game's own video settings — the display resolution
should read your panel's native mode, not the overscaled one.

For a claim that doesn't depend on a game's settings dialog, ask XWayland
directly from inside the Steam sandbox, which is exactly the one a game sees:

```sh
flatpak run --command=xrandr com.valvesoftware.Steam | grep '^Screen'
```

On a 2560×1600 panel at 133% this reports `current 3840 x 2400` — the
overscaled framebuffer. Under `gamescale` it should read `2560 x 1600`. This is
also the quickest way to check whether the problem in this README is one you
actually have.

Then test the lock, because it's the load-bearing part. While a game is
running:

```sh
flock -n ~/.local/state/gamescale/lock -c true   # must FAIL
```

If that *succeeds*, the lock isn't being held through Steam's launch chain and
the watchdog may restore mid-game — worse than no watchdog at all. Set
`GAMESCALE_NO_WATCH=1` and open an issue.

And check the watchdog is actually up:

```sh
systemctl --user list-units 'gamescale-*'
```

---

## Recovering by hand

If your desktop is stuck at 1×:

```sh
gamescale --restore
```

If the state file is gone too, set it directly:

```sh
gdctl set --logical-monitor --primary --monitor eDP-1 --scale 1.3333333730697632
gsettings reset org.gnome.desktop.interface text-scaling-factor
gsettings reset org.gnome.desktop.interface cursor-size
```

`gdctl show` will tell you your connector name and current scale.

---

## Requirements

- GNOME 48+ on Wayland (`gdctl` ships with Mutter)
- `flock` (util-linux) and `systemd-run` for the watchdog — optional; without
  them it degrades to trap-only
- `xmllint` for the `monitors.xml` fallback — optional
