# <img src="extension/icons/gamescale.svg" width="32" alt=""> gamescale

[![ci](https://github.com/arclight-digital/gamescale/actions/workflows/ci.yml/badge.svg)](https://github.com/arclight-digital/gamescale/actions/workflows/ci.yml)

Run a game at 1× monitor scale so XWayland hands it your panel's real mode
instead of an overscaled framebuffer — then put your desktop back when it
exits. GNOME/Mutter on Wayland; works with Flatpak Steam and other Flatpak
launchers.

> Built with [Claude](https://claude.ai). This changes your display
> configuration — read the script before you run it. CI runs shellcheck and
> eight test suites on every push.

## Why

Under GNOME fractional scaling, XWayland gets an integer scale applied to your
*logical* resolution. On a 2560×1600 panel at 133%:

| | |
|---|---|
| Panel (physical) | 2560×1600 |
| Logical | 1920×1200 |
| XWayland factor `1` | reports **1920×1200** — blurry upscale |
| XWayland factor `2` | reports **3840×2400** — 2.25× render cost |

Neither is 2560×1600, and borderless-fullscreen-only games take whatever the
desktop reports. Scale 1.0 is the only configuration where XWayland is handed
the real mode, so gamescale sets it for the lifetime of one process,
compensates font and cursor size so the desktop stays usable, and reverts on
exit — surviving crashes and SIGKILL via a watchdog, a state file, and a login
reconcile unit.

## Install

```sh
curl -fsSL https://raw.githubusercontent.com/arclight-digital/gamescale/main/install.sh | sh
```

Or from a checkout: `./install.sh` (a checkout also installs the top-bar
indicator extension). Installs to `~/.local/bin/gamescale`, grants the
launchers you name what they need, installs the login reconcile unit, runs
`--doctor`. Re-runnable; downloads are checksum-verified; `--uninstall`
removes everything.

Upgrading from 1.x: the extension's uuid changed to `gamescale@arclight.digital`,
which the shell treats as a different extension rather than a newer one.
Installing from a checkout removes the old one and puts the new one in its
place — log out and back in to pick it up. The piped installer ships no
extension at all, so it leaves the old one alone and tells you it is stale.

| | |
|---|---|
| `--platform NAME...` | launchers to grant: `steam` (default) `faugus` `lutris` `heroic` `bottles` `all`, or a Flatpak app id |
| `--dry-run` | print every action, take none |
| `--uninstall` | remove everything it installed |
| `GAMESCALE_REF` | pin a release tag |
| `GAMESCALE_BINDIR` | install location (default `~/.local/bin`) |
| `GAMESCALE_NO_FLATPAK` / `NO_UNIT` / `NO_EXTENSION` / `NO_VERIFY` | `1` to skip that part |

The launcher grant includes `--talk-name=org.freedesktop.Flatpak`, which lets
the app run commands on the host — it effectively ends that launcher's sandbox
isolation. That is the price of reaching mutter from inside Flatpak; if you
don't want it, skip the grant and games launch unmodified.

## Use

Steam launch options:

```
gamescale %command%
```

Anywhere else: `gamescale -- /path/to/game`.

Wrapper flags:

| | | |
|---|---|---|
| `-x` | `--no-scale` | env-only: export, exec, touch nothing else |
| `-f` | `--no-font` | skip font/cursor compensation |
| `-s FACTOR` | `--scale FACTOR` | scale while playing (default `1`) |

Environment shorthands (aliases of `-e`; combine as `-wn`):

| | | |
|---|---|---|
| `-w` | `--env-wayland` | `-e PROTON_ENABLE_WAYLAND=1` |
| `-n` | `--env-ntsync` | `-e PROTON_USE_NTSYNC=1` |
| `-m` | `--env-mangohud` | `-e MANGOHUD=1` |
| `-e KEY=VAL` | `--env KEY=VAL` | export into the game; repeatable |

These names rot as Proton evolves (on stock Valve Proton `-w` and `-n` are
currently inert); `--doctor` prints the expansion table with caveats, and `-e`
with the right name always works.

Modes:

| | |
|---|---|
| `--status [appid]` | monitors, scales, stale state; with appid, what that game gets |
| `--doctor` | dependency and permission check |
| `--restore` | put the display back from a stranded state file |
| `--set-game <appid> <entry>` | write a `games.conf` entry (`-` removes) |
| `--install-unit` | install the login reconcile service |
| `--help` | full commentary from the top of the script |

Env: `GAMESCALE_SCALE`, `GAMESCALE_NO_FONT=1`, `GAMESCALE_NO_WATCH=1`,
`GAMESCALE_DEBUG=1`.

Per-game defaults in `~/.local/state/gamescale/games.conf`, so every title can
keep the same launch options string:

```
1817070 = wn                # flag letters
620     = w, MANGOHUD=1     # or literal KEY=VAL
```

Precedence: explicit flags > `games.conf` > inherited environment. Any
explicit flag disables the config lookup for that launch; every export is
echoed at launch with its origin.

## The indicator extension

Installed from a checkout: a top-bar icon while a run is active, a menu
listing what will be restored, "Restore now", and a red icon if the run died
without restoring. It keeps the px-sized shell chrome (dash, alt-tab,
notification and OSD icons) at its apparent size, and hides the accessibility
icon when gamescale's font compensation is the only reason it lit up.

## If your desktop is stuck at 1×

```sh
gamescale --restore
```

## Requirements

- GNOME on Wayland with fractional scaling on — tested on 50.3, expected to
  work on 48/49, `--doctor` will tell you
- `python3` with PyGObject (talks to mutter over D-Bus)
- `flock` and `systemd-run` for the watchdog — optional, degrades to trap-only
