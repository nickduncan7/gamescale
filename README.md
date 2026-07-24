# gamescale

Run a game at 1× monitor scale so XWayland hands it your panel's real mode
instead of an overscaled framebuffer — then put your desktop back when it exits.

Written for GNOME/Mutter on Wayland. Works with Flatpak Steam.

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

## What it does not do

- **Not a gamescope replacement.** No nested compositor, no upscaling, no
  frame limiting. It changes one display setting and changes it back.
- **Not per-application.** The scope is *temporal*, not spatial. While the game
  runs, your whole desktop is at 1×. Alt-tabbing shows a smaller desktop with
  compensated text — better than raw 1×, not identical to your normal setup.
- **Doesn't fix title bars, icons, or panel spacing.** Only text and cursor
  scale. GNOME has no knob for the rest.

---

## Install

```sh
mkdir -p ~/.local/bin ~/.local/state/gamescale
cp gamescale.sh ~/.local/bin/
chmod +x ~/.local/bin/gamescale.sh
```

### Flatpak Steam

The sandbox can't see your script, can't reach the host session, and can't
write shared state without three grants:

```sh
flatpak override --user \
    --filesystem="$HOME/.local/bin:ro" \
    --filesystem="$HOME/.local/state/gamescale:create" \
    --talk-name=org.freedesktop.Flatpak \
    com.valvesoftware.Steam
```

`--talk-name=org.freedesktop.Flatpak` is what `flatpak-spawn --host` rides on.
Without it the script detects the sandbox, finds it can't reach `gdctl`, and
passes your game through unmodified. Restart Steam after.

### Login reconcile service

Covers the case where the machine goes down mid-game:

```sh
gamescale.sh --install-unit
```

### Verify

```sh
gamescale.sh --doctor
```

Checks each moving part separately — portal reachability, `gdctl`,
`gsettings`, state-dir writability from both sides, `systemd-run`, `flock`,
monitor detection, stale state. When something breaks later, this tells you
*which* link, instead of a generic failure.

From inside the sandbox specifically:

```sh
flatpak run --command="$HOME/.local/bin/gamescale.sh" com.valvesoftware.Steam --doctor
```

---

## Use

Steam launch options (absolute path — Steam won't expand `~`):

```
/home/YOU/.local/bin/gamescale.sh %command%
```

Anywhere else:

```sh
gamescale.sh -- /path/to/game
```

### Commands

| | |
|---|---|
| `--status` | detected connector, scale, font/cursor, stale state |
| `--doctor` | full dependency and permission check |
| `--restore` | put the display back from a stranded state file |
| `--install-unit` | install the login reconcile service |
| `--watchdog` | internal; started by systemd, not by you |

### Environment

| | |
|---|---|
| `GAMESCALE_SCALE` | scale while playing (default `1`) |
| `GAMESCALE_MONITOR` | connector override, e.g. `eDP-1` (default: auto-detect) |
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
  panel. Multi-monitor configs use the logical monitor marked primary.
- If anything is unavailable, the game still launches, unmodified. A failed
  scale flip should never mean a failed game launch.

---

## Verifying it actually works

The script running without errors and the game getting the right resolution are
different claims. Check the game's own video settings — the display resolution
should read your panel's native mode, not the overscaled one.

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
gamescale.sh --restore
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
