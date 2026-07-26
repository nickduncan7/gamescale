# gamescale

[![ci](https://github.com/proto-cool/gamescale/actions/workflows/ci.yml/badge.svg)](https://github.com/proto-cool/gamescale/actions/workflows/ci.yml)

Run a game at 1× monitor scale so XWayland hands it your panel's real mode
instead of an overscaled framebuffer — then put your desktop back when it exits.

GNOME/Mutter on Wayland. Works with Flatpak Steam and other Flatpak launchers.

> **Built with [Claude](https://claude.ai) by Anthropic.** AI makes mistakes,
> and this one changes your display configuration — read the script before you
> run it. It isn't unvalidated, though: the numbers below were measured on a
> Lenovo Legion Pro 7i (2560×1600 at 133%) running Fedora Silverblue 44, GNOME
> 50.3 and Flatpak Steam, and CI runs shellcheck plus seven test suites — 310
> assertions — on every push, covering what is read from mutter, the exact
> configuration written back, the state file, restore-after-SIGKILL, the
> sandboxed branch, the flag and config parsers, and the installer's grants. Those suites were themselves
> checked by injecting regressions and confirming they fail. Other GNOME versions
> and other hardware are less certain; issues welcome.

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

This is a workaround, and it should have an end date. There are **two exits, and
neither has arrived**:

1. **[mutter#478](https://gitlab.gnome.org/GNOME/mutter/-/work_items/478)** —
   *Fractional Scaling Known issues and TODO*, still open — whose list includes
   "XWayland clients: support clients with native scaling in unscaled screen".
   That item landing *and working* retires the whole tool.
2. **Proton rebased on Wine ≥ 11.12**, with fractional scaling actually
   engaging. That one retires the scale flip game by game rather than all at
   once: a title that no longer needs it becomes a one-letter `x` entry in
   `games.conf` — env-only, no display touched — while the environment
   passthrough around it stays useful. Today this is further off than it looks,
   since stock Proton ships [no wayland driver at all](#wayland).

Either way, deleting this repo is the intended outcome.

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

### Wayland

Short version: on stock Valve Proton there is currently **no wayland path to
try**, and asking for one costs you nothing and gains you nothing.

Measured on GNOME 50.3 at 133%, borderless fullscreen: a game launched with
`PROTON_ENABLE_WAYLAND=1` reports **3840×2400** in-game — the same number, and
the same 2.25× render cost, as plain XWayland at factor 2. Setting the variable
changed nothing at all.

The reason is duller than it first looked, and worth writing down because the
obvious explanation is wrong. It is tempting to conclude that winewayland ran
and, lacking `wp_fractional_scale_v1`, took mutter's integer `wl_output` scale —
arriving at the same 2.25× by a different route. That is not what happened.
**Stock Proton ships no wayland driver at all.** Checked 2026-07-26 across every
build Steam offers here:

| build | display drivers shipped |
|---|---|
| `proton-11.0-1` | `winex11.drv` only |
| `experimental-11.0-20260713` | `winex11.drv` only |
| `hotfix-20260710` | `winex11.drv` only |

No `winewayland.drv`, no `winewayland.so`, and the string `winewayland` appears
in no binary in any of the three. So there was never a wayland driver to fall
back *from*: the game was an X11 client from the first frame, and
`PROTON_ENABLE_WAYLAND` was read by nothing. `PROTON_ENABLE_WAYLAND` is a
**GE-Proton and proton-cachyos** variable — those builds do ship the driver.

Because the fallback is silent either way, the only honest check is to ask who
is holding an X11 connection:

```sh
flatpak run --command=xlsclients com.valvesoftware.Steam
```

If your game is in that list, it is an X11 client and gamescale's scale flip is
still what's doing the work. And note that a wayland game would have **the same
problem anyway** — the resolution it's handed is the compositor's logical size
either way. `-w` is environment passthrough, not a rendering mode; it does not
change how, or whether, gamescale scales anything.

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
| `GAMESCALE_REF=v1.5.0` | pin a version |
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

**Be clear about what the third one costs.**
`--talk-name=org.freedesktop.Flatpak` is what `flatpak-spawn --host` rides on,
and it lets the app ask the portal to run arbitrary commands *outside* the
sandbox. That is not a narrow capability: it effectively ends the launcher's
isolation from your host session, for the launcher and for anything it runs,
including games and their shader compilers. The `:ro` and `:create` filesystem
grants are reachable through it too, so read them as tidiness, not containment.
This is the price of reaching `gsettings` and mutter from inside a sandbox, and
it is the most consequential thing the installer does. If that trade isn't one
you want, run your games unsandboxed — gamescale needs no grants at all outside
Flatpak — or skip this grant and accept that games launch unmodified.

`--env=PATH` *replaces* the sandbox PATH rather than extending it, so `--doctor`
checks the stock entries are still there. Restart the launcher afterwards.

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
| `--status [appid]` | detected monitors and scales, font/cursor, stale state; with an appid, what that game would get |
| `--doctor` | full dependency and permission check |
| `--restore` | put the display back from a stranded state file |
| `--set-game <appid> <entry>` | write a `games.conf` entry (`-` removes it) |
| `--install-unit` | install the login reconcile service |
| `--version`, `-V` | which release this is |
| `--help`, `-h` | the full commentary from the top of the script |

| | |
|---|---|
| `GAMESCALE_SCALE` | scale while playing (default `1`) |
| `GAMESCALE_NO_FONT` | `1` to skip font/cursor compensation |
| `GAMESCALE_NO_WATCH` | `1` to skip the host watchdog (trap only) |
| `GAMESCALE_DEBUG` | `1` for verbose logging |

### Flags

Two categories, and the difference between them is the whole point. The first
configures **gamescale**. The second configures the **environment of the game**,
and nothing in it changes how — or whether — anything is scaled.

Wrapper behaviour:

| | | |
|---|---|---|
| `-x` | `--no-scale` | env-only: export, exec, touch nothing else |
| `-f` | `--no-font` | same as `GAMESCALE_NO_FONT=1` |
| `-s FACTOR` | `--scale FACTOR` | same as `GAMESCALE_SCALE=FACTOR` |

Environment shorthands, each *defined as* an alias of `-e`:

| | | |
|---|---|---|
| `-w` | `--env-wayland` | `-e PROTON_ENABLE_WAYLAND=1` |
| `-n` | `--env-ntsync` | `-e PROTON_USE_NTSYNC=1` |
| `-m` | `--env-mangohud` | `-e MANGOHUD=1` |
| `-e KEY=VAL` | `--env KEY=VAL` | export `KEY=VAL` into the game. Repeatable. |

The long names carry `--env-` deliberately: `--wayland` would read as a
gamescale rendering mode, which it is not.

Short flags combine (`-wn`, `-xm`). Parsing stops at the first non-flag argument
or at `--`, so both `gamescale [flags] %command%` and `gamescale [flags] --
/path/to/game` work. The prefix form is fully supported and is still the
simplest thing that works:

```sh
PROTON_ENABLE_WAYLAND=1 gamescale %command%
```

`KEY` must be a normal variable name; anything else is a usage error that
**still launches the game**. `VAL` is passed through byte for byte — but Steam's
launch-options field makes values containing spaces genuinely miserable to
quote, and that's Steam's problem, not one this can fix. Put those in
`games.conf`.

#### These names rot — and two of them are already inert

Proton renames variables, flips defaults, and the forks disagree with upstream.
As of 2026-07-26, on **stock Valve Proton**:

- `-w` does nothing — no Proton build ships a wayland driver ([above](#wayland)).
  It is correct for GE-Proton and proton-cachyos.
- `-n` does nothing — ntsync is **on by default**, and the only variable that
  exists is the negative one. `-e PROTON_NO_NTSYNC=1` turns it *off*, which is
  the toggle that still does something.
- `-m` works everywhere; `MANGOHUD` is MangoHud's own variable, not Proton's.

A rotted shorthand is a nasty failure mode: the export succeeds, so the log says
it worked, and the game just behaves as if you'd set nothing. Two things guard
against that. **`--doctor` prints the expansion table** with the stock-Proton
caveats above. And **`-e` is the recovery** — the letters are only convenience
over it, so when a name rots, `-e THE_RIGHT_NAME=1` works immediately with no
release and no waiting. There is exactly one table, at the top of
`gamescale.sh`; the tests pin its contents so a silent change fails CI.

### Per-game defaults

So that every title can use the same launch options string — `gamescale
%command%` — forever, and the per-game decisions live in one file instead of in
Steam's UI, thirty dialogs deep.

`~/.local/state/gamescale/games.conf`:

```
# comments and blank lines ignored
1817070 = wn                        # Halo: Campaign Evolved
620     = w, MANGOHUD=1             # letters are sugar; full KEY=VAL accepted
22380   = x                         # env-only
```

Left side is a numeric appid. Right side is a comma-separated list where each
item is either a string of flag letters (`w n m x f` — the same letters, meaning
the same things) or a literal `KEY=VAL`. Anything carrying a value is written
out in full, which is why the format needs no escaping rule. A `#` starts a
comment at the start of a line or after whitespace, so a value can still contain
one.

A malformed line is reported by line number and **skipped**, not fatal. An
unknown but well-formed `KEY=VAL` is *not* malformed — that's the escape hatch
working, and it's what lets a variable invented after this release still be
used.

```sh
gamescale --set-game 1817070 wn          # create or replace
gamescale --set-game 620 w,MANGOHUD=1
gamescale --set-game 1817070 -           # remove
gamescale --status 1817070               # what that game would get
```

`--set-game` validates with the same parser the launch path uses, rewrites the
file atomically, and preserves your comments, blank lines and unrelated
entries verbatim. It adds `# <game name>` to new entries when it can read the
name out of `appmanifest_<appid>.acf`; failing to resolve one is silent.

### Precedence

**explicit flags > `games.conf` > inherited environment.**

The config is consulted only when `SteamAppId` is present *and* the command line
carries no flags at all. **Any** explicit flag — either category — turns the
lookup off entirely for that launch. All or nothing, never a per-key merge:
a merge has no rule anyone can state in one sentence, and this one you can hold
in your head at the launch-options box.

That gives you the override idiom. `-e KEY=0` is how you win an argument with
your own config file for a single launch:

```sh
gamescale -e PROTON_ENABLE_WAYLAND=0 %command%
```

Every export is echoed at launch, one line each, naming where it came from —
because with three config surfaces, "I set a flag and nothing happened" is
otherwise unanswerable after the fact:

```
gamescale: exporting PROTON_ENABLE_WAYLAND=1 (-w)
gamescale: exporting MANGOHUD=1 (games.conf:1817070)
```

And an export that disagrees with a variable already in your environment says
so. Equal values are not a conflict, and nothing is ever blocked:

```
gamescale: games.conf(1817070) overrides inherited PROTON_ENABLE_WAYLAND=0 -> 1
```

The last launch is also recorded in `~/.local/state/gamescale/lastrun-<appid>`,
which `--status` reads back. It is informational only — nothing restores from
it, there is one per game, and each is overwritten in place.

### `-x`, env-only

`-x` exports the variables, execs the game, and touches **nothing** else: no
display read, no display write, no font or cursor change, no state file, no
lock, no watchdog, no contact with the restore machinery at all.

The lock is the part that matters. An `-x` launch is not an owner of the
display, so the [one-game-at-a-time](#how-it-survives-things) rule doesn't reach
it in either direction — it neither blocks a scaled launch nor waits on one.
That isn't a nicety. When one of the two exits below arrives, configs will
mass-set `x` per game, and a one-at-a-time constraint on launches that change
nothing would be a pure regression inherited from the release that removed the
need for it.

Combining `-x` with `-s` or `-f` warns — they configure a scale change that will
now never happen — and proceeds env-only.

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

Two limits on the watchdog worth knowing, because both are deliberate:

- **It gives up after 12 hours** rather than living forever. Reaching that
  ceiling means the game is *still running*, so it exits without touching
  anything — restoring there would revert the desktop under a live game and
  delete the record the real exit depends on. The trap and the login unit still
  cover you. `GAMESCALE_WATCHDOG_TIMEOUT` changes the ceiling.
- **It only acts on the state its own run wrote.** Each run tags the state file
  with an id and passes it to its watchdog. Without that, a watchdog finishing
  its grace period could restore the *next* game's state — reverting a game that
  had just started and deleting its record.

**One game at a time.** Two games mean two owners of one display, so whoever
holds the lock owns it: a second launch that finds the lock taken says so and
runs your game unmodified rather than reverting the first one's display and
deleting its state.

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

# what the game actually renders at; the least ambiguous check there is.
# MANGOHUD_CONFIG only configures it — MANGOHUD=1 is what turns it on (or use
# Steam's MangoHud toggle). As a Steam launch option, not a terminal command:
MANGOHUD=1 MANGOHUD_CONFIG=fps,resolution gamescale %command%

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

- GNOME on Wayland with fractional scaling on
- `python3` with PyGObject (`python3-gi` on Debian/Ubuntu, `python3-gobject-base`
  on Fedora) — this is what talks to mutter
- `flock` and `systemd-run` for the watchdog — optional, degrades to trap-only

**Which GNOME versions.** Tested on 50.3, which is the only version any of this
has run on. 48 and 49 are expected to work and reports are welcome. Since 1.4.0
nothing here needs `gdctl`, so there is no longer a reason it *couldn't* work on
46 and 47 — the D-Bus interface it uses predates the CLI by years — but that is
untested, so the honest answer is "try it and tell me". `--doctor` will say
whether the pieces are reachable before you launch anything.

## How the display configuration is read and written

Both directions go to mutter over `org.gnome.Mutter.DisplayConfig`:
`GetCurrentState` to read, `ApplyMonitorsConfig` to write. Position, scale,
transform, primary and connectors are typed values, and nothing is parsed out of
text.

Reading used to scrape `gdctl show`, which is output meant for humans: no
stability contract, drawn with box glyphs, connector names recovered by anchoring
past them. A GNOME release that reflowed that tree would have broken detection
silently — and silently is the problem, because gamescale fails safe, so a broken
parser looks like a game that launched fine and stayed blurry.

Writing directly means owning two things `gdctl` did: choosing a mode id per
monitor (always the one you are already on), and computing logical positions,
because the D-Bus call takes absolute coordinates and has no `--right-of`. Two
notes on that arithmetic, since it can only be wrong in ways mutter refuses:

- Every configuration is **verified before it is applied**, so getting it wrong
  costs a refused config and an unmodified game launch, not your layout.
- At 1× a logical monitor *is* its mode, so the default path does no division and
  cannot round. Only a fractional `GAMESCALE_SCALE` reaches that arithmetic.

One trap worth naming: `gdctl` numbers transforms in an order its own names don't
suggest — 6 is `flipped-270` and 7 is `flipped-180`, the reverse of mutter's enum
order — and the width/height swap follows the same numbering. Formatting the raw
value the obvious way would rotate two of the eight configurations wrongly.

If reading fails for any reason, the game launches unmodified. Restoring doesn't
depend on it at all: `--restore` replays the state file and never re-reads the
display, so a broken reader can decline to scale you but can't strand you at 1×.

## Development

```sh
shellcheck -S style gamescale.sh install.sh test/*.sh
./test/detect_test.py      # reading, against synthetic mutter replies
./test/apply_test.py       # the exact configuration written back to mutter
./test/state_test.sh       # state file, records, and the give-up paths
./test/watchdog_test.sh    # restore after SIGKILL, and no restore before it
./test/sandbox_test.sh     # the flatpak-spawn branch, and --doctor
./test/env_test.sh         # flags, games.conf, precedence, -x, --set-game
./test/install_test.sh     # the grant argv, checksums, uninstall decisions
```

No display is touched by any of them. The Python suites extract the display
program out of `gamescale.sh` and run it against real `GLib.Variant`s of
GetCurrentState's signature, so the shipped code is what's under test, a wrong
signature fails there rather than at runtime, and `apply_test.py` can assert the
exact payload — including that every configuration is verified before it is
applied, and that nothing is applied when verification fails.

The shell suites share `test/stubs.sh`, which stubs `python3`, `gsettings`,
`systemd-run` and `flatpak-spawn` on `PATH` and drives the real script end to
end. Those stubs can be made to **fail** — that is the point. A mutation battery
found fifteen injected regressions surviving the whole suite, all for the same
reason: with stubs that always succeed, no error branch is reachable. So the
stubs now refuse configurations naming a disconnected monitor the way mutter
does, can fail a specific `gsettings` key, and can return any exit status, which
is what lets the give-up paths, the partial-restore branch and the
font/cursor compensation be asserted at all.

`watchdog_test.sh` takes about 25 seconds: it kills a fake game with `SIGKILL` so
the trap never runs, then asserts the watchdog restored anyway — and that it does
*not* restore while the game is alive, after timing out, or for a run that isn't
its own. `sandbox_test.sh` fakes `/.flatpak-info` via `GAMESCALE_FLATPAK_INFO`,
which exists solely so the branch every Flatpak user takes is reachable from a
test; it asserts every host command goes out through `flatpak-spawn`.
