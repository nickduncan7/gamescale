# Changelog

Dates are release dates. "Stranding" below means a desktop left at 1× scale,
which is the failure this tool exists not to cause.

## 1.7.1 — 2026-07-26

### Fixed

- **The accessibility icon was never actually suppressed.** The decision ran
  only when the state file appeared and when the monitor layout changed —
  both of which happen before the script raises `text-scaling-factor`, so the
  "is Large Text really what's lit" check always answered no and the icon
  stayed. It now also re-runs whenever an accessibility toggle changes state,
  which is the signal the compensation itself trips. Turning another
  accessibility feature on mid-run now brings the icon back, too, and the
  icon can no longer stay hidden past the end of a run.

## 1.7.0 — 2026-07-26

### Added

- **A top-bar indicator extension.** A gamescale icon while a run is active,
  a menu listing exactly what will be restored, a "Restore now" item that
  reports failure as a notification, a red icon when the run died without
  restoring (state present, lock free), and — when the pre-game text scale
  was 1.0 — suppression of the accessibility icon that the font compensation
  otherwise lights up ("Large Text" is any `text-scaling-factor` above 1.0).
  The suppression additionally requires that no other accessibility feature
  is active and the icon isn't set to always show — an icon the user owns for
  any other reason is never hidden.
  It also keeps the px-sized shell chrome at its apparent size, multiplied by
  the saved-scale/current-scale ratio and undone on restore: dash icons
  (`iconSize` property interception), the alt-tab app switcher (per-popup
  size-fit wrap), overview window-preview app icons, and notification/OSD
  icons via a runtime stylesheet. The em-sized chrome — panel height, status
  icons, all shell text — already follows the script's font compensation.
  Display only: it watches the state file, spawns `gamescale --restore` on
  request, and either side works without the other. Installed by `install.sh`
  from a checkout only, never by the piped download; `GAMESCALE_NO_EXTENSION=1`
  skips it.

## 1.6.0 — 2026-07-26

Per-launch environment passthrough and per-game defaults, so every title can use
the identical launch options string — `gamescale %command%` — forever, with the
per-game decisions living in one config file. Nothing in the restore machinery
changed; this release is additive around it.

### Added

- **Flags, in two categories**, because the distinction is the point. `-x`
  (`--no-scale`), `-f` (`--no-font`) and `-s FACTOR` (`--scale`) configure
  gamescale. `-w`, `-n`, `-m` and `-e KEY=VAL` configure the *environment of the
  game* and change nothing about scaling — each shorthand is literally
  implemented as an `-e` alias. Short flags combine (`-wn`); parsing stops at
  the first non-flag argument or `--`, so both invocation forms work. The prefix
  form `PROTON_ENABLE_WAYLAND=1 gamescale %command%` is untouched and still the
  simplest thing that works.
- **`games.conf`** — `<appid> = <letters and KEY=VAL>`, parsed never sourced, in
  the state directory that is already `:create`-granted, so no new Flatpak
  permissions. Malformed lines are reported by line number and skipped; an
  unknown but well-formed `KEY=VAL` is not an error, which is what lets a
  variable invented after this release still be used.
- **`--set-game <appid> <entry|->`**, validating with the same parser the launch
  path uses, rewriting atomically, and preserving your comments, blank lines and
  unrelated entries verbatim. New entries get `# <game name>` when it can be
  read out of `appmanifest_<appid>.acf`; failing to resolve one is silent.
- **Precedence, stated and visible.** Explicit flags > `games.conf` > inherited
  environment. The config is consulted only when `SteamAppId` is set *and* no
  flag was given: any flag disables the lookup entirely, all-or-nothing rather
  than a per-key merge, because a merge has no rule anyone can state in one
  sentence. Every export is echoed with its source, and an export that disagrees
  with an inherited value warns. Equal values are not a conflict; nothing is
  ever blocked. `-e KEY=0` is the documented way to override your own config for
  one launch.
- **`-x`, env-only mode.** Exports, execs, and touches nothing else — no display
  read or write, no font or cursor change, no state file, **no lock**, no
  watchdog. Not holding the lock is the load-bearing part: an `-x` launch is not
  an owner of the display, so it neither blocks nor is blocked by a scaled
  launch of another game.
- `lastrun-<appid>` records the last launch's source and exports for `--status`.
  Informational only — nothing restores from it, one file per game, overwritten
  in place. Parsed, never sourced (it lives in the same sandbox-writable
  directory as the state file); unknown keys are ignored, since nothing acts
  on the record.
- `--status [appid]` gains the parsed config table and a per-game view; the old
  output is unchanged.
- `--doctor` gains an ntsync check (device plus kernel ≥ 6.14, a **warning**
  rather than a failure — an absent `/dev/ntsync` is a fact about your kernel,
  not a broken install), the wayland caveat, a `games.conf` parse through the
  same parser the launch path uses, and the shorthand expansion table with the
  stock-Proton caveats.
- `test/env_test.sh` — 130 assertions. Total across the suites: 180 to 310.

### Fixed

- **Two of the three shorthands were specified against variable names stock
  Proton does not read, and verifying them first is why they ship annotated
  rather than silently broken.** Checked 2026-07-26 against `proton-11.0-1`,
  `experimental-11.0-20260713` and `hotfix-20260710`:
  - `PROTON_USE_WAYLAND` is not the name; `PROTON_ENABLE_WAYLAND` is, and it is
    a **GE-Proton / proton-cachyos** variable. Stock Proton ships **no wayland
    driver at all** — `winex11.drv` only, no `winewayland.drv`, and the string
    `winewayland` in no binary of any of the three — so on stock Proton there is
    nothing for any spelling to switch on.
  - `PROTON_USE_NTSYNC` is read by nothing. ntsync is **on by default** and the
    only variable present is the negative one, `PROTON_NO_NTSYNC`, so `-n` asks
    for something already true and `-e PROTON_NO_NTSYNC=1` is the toggle that
    still does something.
- This also corrects the record on the wayland measurement: `3840×2400` in-game
  with the variable set was **silent XWayland fallback**, not winewayland
  running without `wp_fractional_scale_v1`. There was no wayland driver to fall
  back from. See the README, which now documents the check that tells them
  apart.

### Changed

- **One expansion table**, at the top of the script, is the only place a
  variable name is written down. These names rot — Proton renames them, flips
  defaults, and the forks disagree with upstream — and a rotted shorthand
  exports perfectly and does nothing, which is a failure the export echo cannot
  explain. So `--doctor` prints the table with the stock-Proton caveats; the
  tests pin the expansions as literals so a silent change fails CI; and `-e`
  remains the recovery that needs no release at all.
- Host-side `sh -c` and awk calls pass paths as positional arguments instead
  of interpolating them into the script text, so a path containing a quote
  cannot break — or inject into — the host-side shell.
- `--status` with a failed display detection now prints the rest of its output
  before exiting non-zero, instead of stopping at that line.

## 1.5.0 — 2026-07-25

Tests and seams. No new features: a mutation battery injected twenty regressions
into 1.4.0 and **fifteen survived the whole suite**, so this release is about
making the suite able to fail.

### Fixed

- `--doctor` counted one problem twice. The second line explaining a failure
  called the failure counter again, so a single rejected layout reported "2
  check(s) failed" — and that count is what the exit status and the summary are
  built on. `--doctor` had no tests at all; it has 6 now.
- The run token is written to a **sibling file** instead of into the state file.
  1.4.0 added a `run=` key while still claiming `version=2`, so a 1.3.0 script
  meeting a 1.4.0 state file refused it and left the display at 1×. That is
  reachable: `--install-unit` bakes an absolute path, so reinstalling elsewhere
  leaves the login unit running the older copy. The state format is now back to
  what 1.3.0 writes, and both older shapes still restore.
- One test of the concurrency guard was racy — it slept a fixed second and
  assumed the first run held the lock, which on a slow runner fails for a tool
  that is behaving correctly. It now polls for the lock.

### Added

- `GAMESCALE_FLATPAK_INFO`, so the sandboxed branch is reachable from a test. It
  is chosen by the presence of `/.flatpak-info`, which meant the one code path
  every Flatpak user takes was the one path no suite could exercise. A command
  added without routing it through `host()` works on the developer's desktop and
  never comes back inside the sandbox.
- `test/stubs.sh`, shared by every shell suite, whose stubs can be made to fail:
  any exit status from the display program, a chosen `gsettings` key that refuses
  to be set, and a logged `flatpak-spawn`. This is what makes the following
  testable at all, and every one of them was a surviving mutant:
  - font and cursor compensation, in both directions, and `GAMESCALE_NO_FONT`
  - the partial-restore branch, where the scale comes back but the font does not
  - every give-up path: a refused layout, an unwritable state directory, and a
    leftover state file that will not restore — all of which must still launch
    the game, and must not scale on top of a failed restore
  - `GAMESCALE_SCALE` reaching the configuration at all
- `test/sandbox_test.sh` — 17 assertions on the sandboxed branch and `--doctor`.
- `test/install_test.sh` — 29 assertions on the installer: the exact grant argv
  (a dropped `--talk-name` means nothing can ever be restored; an extra app is a
  security regression), that an app with `home` access gets no filesystem grants,
  that the sandbox `PATH` is extended rather than replaced and never doubled on
  re-runs, that denial flags are never used, the reset-versus-warn decision on
  three override shapes, that a checksum mismatch installs nothing, that piping
  the installer ignores the working directory, and that `--uninstall` restores a
  stranded display before deleting the tool.
- The state file is now asserted as a literal, including mode 0600. Nothing read
  one back before, and a mutant that recorded only the first monitor survived
  everything — on two monitors that means restore switches the other display off.
- `apply_test.py` asserts that verify checks the *same* payload that gets
  applied. A mutant that packed only on the apply call passed all 44 previous
  assertions, which would have made mutter refuse what verify had just approved.

Assertions: 111 to 180.

## 1.4.0 — 2026-07-25

Reads *and* writes the display configuration over
`org.gnome.Mutter.DisplayConfig` instead of driving the `gdctl` CLI, and fixes
five ways a display could be left wrong.

### Changed

- **`gdctl` is no longer used or required.** Applying goes through
  `ApplyMonitorsConfig`, reading through `GetCurrentState`. Since `gdctl` only
  arrived in Mutter 48 and the interface it wraps is years older, this removes
  the reason gamescale couldn't run on earlier GNOME releases — untested there,
  but no longer excluded by design.
- **`python3` with PyGObject is now required.** It was already needed in practice,
  since `gdctl` is itself a python3 + PyGObject script, but it is now a
  requirement in its own right. `--doctor` checks the import rather than the
  interpreter, because a python3 without PyGObject passes `command -v` and then
  fails at the first import.
- Detection no longer parses `gdctl show`. That output is meant for humans, has
  no stability contract, and a GNOME release reflowing it would have broken
  detection silently.
- The `monitors.xml` fallback and its `xmllint` dependency are gone. It could
  only ever recover a single monitor, by a path that could not apply what it
  found.
- Applying now computes logical positions itself, since the D-Bus call takes
  absolute coordinates and has no equivalent of `--right-of`. Every
  configuration is verified before it is applied, so an arithmetic mistake costs
  a refused configuration and an unmodified game launch.
- A requested scale that isn't exactly supported is still snapped to the nearest
  one within 0.1, matching what `gdctl` did silently — but the substitution is
  now logged.
- State files from 1.0.1 and earlier are no longer read.
- An unknown flag is now an error. `gamescale --stats` used to fall through to
  run mode, flick the display to 1×, and then fail to launch anything.
- `--restore` with no saved state now says so instead of exiting silently.

### Fixed

- **Unplugging one monitor of a mirrored pair could strand you at 1× forever.**
  The unplugged-display fallback tested only the first connector of each saved
  record, so it re-sent the very configuration mutter had just refused, and
  failed identically on every retry — from all three restore layers.
- **Font and cursor sizes could ratchet upward on every launch.** A failed
  leftover restore was downgraded to a warning, after which the compensated
  sizes still in `gsettings` were recorded as the next run's originals and
  compensated again. gamescale now declines to scale in that state.
- **A watchdog could restore the next game's state.** Watchdogs sleep briefly to
  let the in-sandbox trap go first; a game launched inside that window had its
  own state restored and deleted out from under it. Each run now tags its state
  and its watchdog with an id, and a watchdog acts only on its own run's state.
- **The watchdog restored the display after its 12-hour ceiling**, while the game
  was by definition still running. It now gives up without touching anything.
- **Two concurrent games fought over one display.** The second launch reverted
  the first one's display and deleted its state. The lock is now taken before
  any state is touched, and a launch that can't get it runs the game unmodified.
- A failed state-file write no longer proceeds to move the display — nothing
  would have known how to put it back.
- Duplicate connectors in a state file are rejected instead of replayed forever.
- Watchdog unit names use a random id rather than `$$`, which repeats across
  Steam restarts because the sandbox has its own PID namespace.
- `install.sh` piped to `sh` treated any `gamescale.sh` in the current directory
  as the source to install, **skipping the download, the tag, and the checksum
  entirely**. Any writable working directory was enough to substitute the script.
- `install.sh --help` printed nothing but a `sed` error when piped, and
  truncated its own environment-variable table when run locally.
- `install.sh --uninstall` could run `flatpak override --reset` on a launcher
  gamescale had never granted anything, destroying the user's own `PATH` or
  portal overrides. It now requires positive evidence of its own grants.
- `install.sh --dry-run` started every named launcher's sandbox to read its
  `PATH`, despite promising to take no action.

### Added

- `test/apply_test.py` — 44 assertions on the exact `ApplyMonitorsConfig`
  payload: packing arithmetic, mode selection, transform numbering, scale
  snapping, and verify-before-apply.
- CI runs the installer (`--dry-run`, `--uninstall --dry-run`, `--help` both
  piped and local). It was linted but never executed, which is how two of the
  bugs above shipped.
- `GAMESCALE_WATCHDOG_TIMEOUT`, so the watchdog's give-up path is testable in
  seconds.
- This file.

## 1.3.0 — 2026-07-25

- Detection asks mutter over `GetCurrentState` instead of parsing `gdctl show`.
  Applying still went through `gdctl set` in this release.
- `GAMESCALE_MONITOR` removed; it had been inert since 1.1.0.

## 1.2.0 — 2026-07-25

- `--version`, reported by `--status` and `--doctor` too.
- Downloads are verified against a `SHA256SUMS` asset published with each
  release, and refused if they don't match. Releases before 1.2.0 have no such
  asset.
- CI: shellcheck at style severity plus the test suites on every push.
- `test/watchdog_test.sh` — asserts the display comes back after the wrapper is
  `SIGKILL`ed with its trap unrun, and that nothing is restored before then.

## 1.1.0 — 2026-07-24

- Every monitor is set to 1× together, and the whole layout — scales, positions,
  transforms, which display was primary — is saved and replayed on exit.
  Scaling only the primary left XWayland's global factor at 2 and applied it to
  a full-resolution logical size, costing 78% *more* pixels than not running.
- `GAMESCALE_MONITOR` ignored as a result.

## 1.0.1 — 2026-07-24

- Fixed connector names with more than one part (`HDMI-A-1`, `DVI-D-1`): an
  unanchored match found `A-1` inside `HDMI-A-1`, so gdctl was handed a monitor
  that didn't exist and games launched unmodified.

## 1.0.0 — 2026-07-24

First release.
