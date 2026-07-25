# Changelog

Dates are release dates. "Stranding" below means a desktop left at 1× scale,
which is the failure this tool exists not to cause.

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
