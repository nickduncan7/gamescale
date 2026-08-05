// Companion indicator for gamescale. The script is the engine; this only
// reflects its state file: icon in the top bar while a run is active, gone
// when it isn't. No D-Bus protocol between the two — either side works
// without the other.
//
// While active, the shell's accessibility indicator is suppressed if (and
// only if) gamescale's font compensation is what lit it: a compensated
// text-scaling-factor > 1.0 reads as "Large Text" to the shell. The state
// file stores the PRE-game text scale, so 1.0 there means the icon is
// gamescale's fault; anything else means the user runs with large text
// anyway and the icon stays.

import Gio from 'gi://Gio';
import GLib from 'gi://GLib';
import GObject from 'gi://GObject';
import St from 'gi://St';

import {Extension} from 'resource:///org/gnome/shell/extensions/extension.js';
import * as AltTab from 'resource:///org/gnome/shell/ui/altTab.js';
import * as Main from 'resource:///org/gnome/shell/ui/main.js';
import * as PanelMenu from 'resource:///org/gnome/shell/ui/panelMenu.js';
import * as PopupMenu from 'resource:///org/gnome/shell/ui/popupMenu.js';
import {WindowPreview} from 'resource:///org/gnome/shell/ui/windowPreview.js';

const SILENCE = Gio.SubprocessFlags.STDOUT_SILENCE |
                Gio.SubprocessFlags.STDERR_SILENCE;

// Long enough to be sure rather than tuned: size-changed normally drives the
// restore, and this is only the fallback for windows that never report.
const NUDGE_DELAY_MS = 250;
const NUDGE_HOLD_MS = 600;

// 1.3333333730697632 → "1.33", 1.50 → "1.5", 1.00 → "1"
function fmtScale(s) {
    return s.toFixed(2).replace(/0+$/, '').replace(/\.$/, '');
}

const Indicator = GObject.registerClass(
class GamescaleIndicator extends PanelMenu.Button {
    _init(ext) {
        super._init(0.5, 'gamescale');
        this.accessible_name = 'gamescale';
        this._ext = ext;
        this._icon = new St.Icon({
            gicon: Gio.icon_new_for_string(
                `${ext.path}/icons/gamescale-symbolic.svg`),
            style_class: 'system-status-icon',
        });
        this.add_child(this._icon);
    }

    // Rebuilt on every state change; the menu is small and this beats keeping
    // per-item references in sync with a file that can change under us.
    update(state, stale) {
        if (stale)
            this._icon.add_style_class_name('gamescale-stale');
        else
            this._icon.remove_style_class_name('gamescale-stale');

        this.menu.removeAll();
        this.menu.addMenuItem(new PopupMenu.PopupMenuItem(
            stale ? 'Game exited without restoring' : 'Desktop at game scale',
            {reactive: false}));

        const monitors = (state?.monitors ?? []).filter(m => isFinite(m.scale));
        if (monitors.length || isFinite(state?.textScale)) {
            this.menu.addMenuItem(
                new PopupMenu.PopupSeparatorMenuItem('Restores to'));
            for (const m of monitors) {
                this.menu.addMenuItem(new PopupMenu.PopupMenuItem(
                    `${m.conns} — ${fmtScale(m.scale)}×` +
                    `${m.primary ? ' (primary)' : ''}`,
                    {reactive: false}));
            }
            if (isFinite(state?.textScale)) {
                this.menu.addMenuItem(new PopupMenu.PopupMenuItem(
                    `text — ${fmtScale(state.textScale)}×`, {reactive: false}));
            }
        }

        this.menu.addMenuItem(new PopupMenu.PopupSeparatorMenuItem());
        this.menu.addAction('Restore now', () => this._ext.restoreNow());
    }
});

export default class GamescaleExtension extends Extension {
    enable() {
        this._stale = false;
        this._chromeRatio = 0;
        this._chromeUndo = [];
        this._nudgeId = 0;
        this._unnudgeId = 0;
        this._stateDir = Gio.File.new_for_path(GLib.build_filenamev(
            [GLib.get_home_dir(), '.local', 'state', 'gamescale']));
        this._stateFile = this._stateDir.get_child('state');

        // The dir must exist to be monitored; the installer creates it, but
        // don't depend on install order.
        try {
            this._stateDir.make_directory_with_parents(null);
        } catch {
            // exists, or unwritable — the monitor below copes either way
        }
        this._monitor = this._stateDir.monitor_directory(
            Gio.FileMonitorFlags.NONE, null);
        this._monitor.connect('changed', () => this._sync());
        // The state file is written BEFORE the scale is applied, so the dash
        // ratio below is wrong at file-appear time — recompute when the
        // monitor layout actually changes.
        this._monitorsChangedId = Main.layoutManager.connect(
            'monitors-changed', () => {
                this._sync();
                this._scheduleNudge();
            });
        this._watchA11y();
        this._sync();
    }

    disable() {
        Main.layoutManager.disconnect(this._monitorsChangedId);
        this._cancelNudge();
        this._unwatchA11y();
        this._monitor?.cancel();
        this._monitor = null;
        this._hideIndicator();
        this._unsuppressA11y();
        this._removeChrome();
        this._stateDir = null;
        this._stateFile = null;
    }

    _sync() {
        if (this._stateFile.query_exists(null)) {
            const state = this._readState();
            this._showIndicator();
            this._indicator.update(state, this._stale);
            if (this._a11yIsOurs(state))
                this._suppressA11y();
            else
                this._unsuppressA11y();
            this._applyChrome(this._chromeRatioFor(state));
            this._checkStale();
        } else {
            this._stale = false;
            this._hideIndicator();
            this._unsuppressA11y();
            this._removeChrome();
        }
    }

    // How much bigger shell chrome must be to keep its apparent size: the
    // primary monitor's saved (pre-game) scale over its current one.
    _chromeRatioFor(state) {
        const saved = state?.monitors.find(m => m.primary) ??
            state?.monitors[0];
        if (!saved || !isFinite(saved.scale))
            return 0;
        const current = global.display.get_monitor_scale(
            Main.layoutManager.primaryIndex);
        return current > 0 ? saved.scale / current : 0;
    }

    // Chrome sized in logical px loses the primary scale's worth of apparent
    // size at 1.0. The em-sized chrome already follows text-scaling-factor,
    // which the script compensates; what's left is undone via this._chromeUndo.
    _applyChrome(ratio) {
        if (Math.abs(ratio - this._chromeRatio) < 0.01)
            return;
        this._removeChrome();
        if (ratio <= 1.01)
            return;
        this._chromeRatio = ratio;
        const px = v => Math.round(v * ratio);

        // Dash: picks its icon size from a fixed list capped at 64 logical
        // px. Intercept the `iconSize` property instead of copying
        // _adjustIconSize: the dash keeps doing its own fitting math, and
        // every size it assigns is multiplied on the way in. get/set stay
        // asymmetric on purpose — that is what defeats the "nothing changed"
        // early-return exactly once per real change.
        const dash = Main.overview.dash;
        if (dash) {
            let stored = px(dash.iconSize);
            Object.defineProperty(dash, 'iconSize', {
                configurable: true,
                get: () => stored,
                set: v => (stored = px(v)),
            });
            dash._queueRedisplay();
            this._chromeUndo.push(() => {
                delete dash.iconSize; // drop the interceptor, plain slot again
                dash.iconSize = 0;    // invalid, so the next fit can't early-return
                dash._queueRedisplay();
            });
        }

        // Alt-tab: same fixed-list pattern as the dash, but the switcher is
        // built fresh per popup, so wrap construction and scale each
        // instance's size fit. Window icons are re-created by set_size.
        const appInit = AltTab.AppSwitcherPopup.prototype._init;
        AltTab.AppSwitcherPopup.prototype._init = function (...args) {
            appInit.apply(this, args);
            const list = this._switcherList;
            const origSet = Object.getPrototypeOf(list)._setIconSize;
            if (!origSet)
                return;
            list._setIconSize = function () {
                origSet.call(this);
                this._iconSize = px(this._iconSize);
                this.icons.forEach(icon => icon.set_size(this._iconSize));
            };
        };
        this._chromeUndo.push(
            () => (AltTab.AppSwitcherPopup.prototype._init = appInit));

        // Overview window previews: the per-window app icon is a fixed
        // 64 logical px at construction.
        const previewInit = WindowPreview.prototype._init;
        WindowPreview.prototype._init = function (...args) {
            previewInit.apply(this, args);
            this._icon?.set_icon_size?.(px(64));
        };
        this._chromeUndo.push(
            () => (WindowPreview.prototype._init = previewInit));

        // Chrome sized in CSS px (the em-sized rest already follows text
        // scale): notification icons and the volume/brightness OSD. Loaded
        // as a stylesheet so unknown selectors on other shell versions are
        // inert rather than errors.
        try {
            const css =
                `.message .message-box .message-icon { icon-size: ${px(48)}px; }\n` +
                `.media-message .message-icon.message-themed-icon { icon-size: ${px(32)}px !important; }\n` +
                `.osd-window StIcon { icon-size: ${px(32)}px; }\n`;
            const file = Gio.File.new_for_path(GLib.build_filenamev(
                [GLib.get_user_cache_dir(), 'gamescale-chrome.css']));
            file.replace_contents(new TextEncoder().encode(css), null, false,
                Gio.FileCreateFlags.REPLACE_DESTINATION, null);
            const theme = St.ThemeContext.get_for_stage(global.stage)
                .get_theme();
            theme.load_stylesheet(file);
            this._chromeUndo.push(() => theme.unload_stylesheet(file));
        } catch {
            // a cache dir that can't be written costs only this piece
        }
    }

    _removeChrome() {
        this._chromeRatio = 0;
        this._chromeUndo.reverse().forEach(undo => undo());
        this._chromeUndo = [];
    }

    // Some clients — Steam's CEF UI is the reason this exists — never repaint
    // when the output's mode changes under them; they redraw on a size change
    // and only on a size change. Neither X11 nor Wayland has a "please
    // redraw", so a 1px shrink and restore is the ask: it makes mutter send a
    // configure, and the configure is what drives the relayout.
    _scheduleNudge() {
        if (this._nudgeId)
            GLib.Source.remove(this._nudgeId);
        this._nudgeId = GLib.timeout_add(
            GLib.PRIORITY_DEFAULT, NUDGE_DELAY_MS, () => {
                this._nudgeId = 0;
                this._nudge();
                return GLib.SOURCE_REMOVE;
            });
    }

    // Floating windows only: mutter already re-lays out maximised, tiled and
    // fullscreen ones, and skipping fullscreen keeps this off the game.
    //
    // Each window gives its pixel back on its own size-changed, not a shared
    // timer: restoring mid-paint leaves mutter stretching the stale buffer
    // over both resizes, which is what smears. The timer is only the fallback.
    _nudge() {
        this._unnudge();
        this._nudged = [];
        for (const actor of global.get_window_actors()) {
            const w = actor.meta_window;
            if (w.is_override_redirect() || w.is_fullscreen() ||
                w.get_maximized() || w.minimized)
                continue;
            const r = w.get_frame_rect();
            const entry = [w, r, 0];
            // Connect after the request, not before: should any shell emit
            // size-changed synchronously from it, missing that one drops the
            // window to the timer rather than restoring it instantly — which
            // is the smear this is here to avoid.
            w.move_resize_frame(false, r.x, r.y, r.width - 1, r.height);
            entry[2] = w.connect('size-changed', () => this._restore(entry));
            this._nudged.push(entry);
        }
        if (!this._nudged.length)
            return;
        this._unnudgeId = GLib.timeout_add(
            GLib.PRIORITY_DEFAULT, NUDGE_HOLD_MS, () => {
                this._unnudgeId = 0;
                this._unnudge();
                return GLib.SOURCE_REMOVE;
            });
    }

    // Give one window its pixel back, at most once. Disconnect first: the
    // restore is itself a size change and would otherwise re-enter. A window
    // closed before its turn has no compositor private and must not be
    // touched.
    _restore(entry) {
        const [w, r, id] = entry;
        if (!id)
            return;
        entry[2] = 0;
        w.disconnect(id);
        if (w.get_compositor_private())
            w.move_resize_frame(false, r.x, r.y, r.width, r.height);
    }

    _unnudge() {
        if (this._unnudgeId)
            GLib.Source.remove(this._unnudgeId);
        this._unnudgeId = 0;
        (this._nudged ?? []).forEach(entry => this._restore(entry));
        this._nudged = null;
    }

    _cancelNudge() {
        if (this._nudgeId)
            GLib.Source.remove(this._nudgeId);
        this._nudgeId = 0;
        this._unnudge(); // never leave a window a pixel short
    }

    // Same keys the script writes; anything malformed just drops out of the
    // display — this never feeds a restore, so it can afford to be lenient.
    _readState() {
        let contents;
        try {
            [, contents] = this._stateFile.load_contents(null);
        } catch {
            return null;
        }
        const state = {monitors: []};
        for (const line of new TextDecoder().decode(contents).split('\n')) {
            const eq = line.indexOf('=');
            if (eq < 0)
                continue;
            const key = line.slice(0, eq);
            const value = line.slice(eq + 1);
            if (key === 'text_scale') {
                state.textScale = parseFloat(value);
            } else if (key === 'monitor') {
                const f = value.split(';');
                if (f.length === 6) {
                    state.monitors.push({
                        conns: f[0],
                        scale: parseFloat(f[1]),
                        primary: f[2] === 'yes',
                    });
                }
            }
        }
        return state;
    }

    // State present with nobody holding the lock means the run (and its
    // watchdog) died without restoring — the recovery case, worth looking
    // different. flock taking the lock is the probe: success = free = stale.
    _checkStale() {
        let proc;
        try {
            proc = Gio.Subprocess.new(
                ['flock', '-n', this._stateDir.get_child('lock').get_path(),
                    'true'],
                SILENCE);
        } catch {
            return; // no flock — can't tell, keep showing plain active
        }
        proc.wait_async(null, (p, res) => {
            try {
                p.wait_finish(res);
            } catch {
                return;
            }
            const stale = p.get_successful();
            if (stale === this._stale || !this._indicator)
                return;
            this._stale = stale;
            this._indicator.update(this._readState(), stale);
        });
    }

    _showIndicator() {
        if (this._indicator)
            return;
        this._indicator = new Indicator(this);
        Main.panel.addToStatusArea('gamescale', this._indicator);
    }

    _hideIndicator() {
        this._indicator?.destroy();
        this._indicator = null;
    }

    // Every accessibility feature is a settings-bound switch in that menu,
    // including the "Large Text" one our compensation lights, so notify::state
    // is the single signal for both "the icon became ours" and "it stopped
    // being ours". Without it the decision would only ever run at state-file
    // and monitor-layout time — both of which happen BEFORE the script raises
    // the text scale, i.e. always on the wrong answer.
    _watchA11y() {
        const items = Main.panel.statusArea.a11y?.menu?._getMenuItems?.() ?? [];
        this._a11yWatch = items
            .filter(item => item.state !== undefined)
            .map(item => [
                item,
                item.connect('notify::state', () => this._sync()),
            ]);
    }

    _unwatchA11y() {
        this._a11yWatch?.forEach(([item, id]) => item.disconnect(id));
        this._a11yWatch = null;
    }

    // The icon is ours alone when: the saved (pre-game) text scale was 1.0,
    // the current scale is actually > 1.0 (so Large Text IS what's lit),
    // always-show is off, and no OTHER accessibility feature is active — the
    // menu's toggle states are the same list ATIndicator derives its
    // visibility from, so >1 active toggle means the icon predates the game.
    // Anything unreadable answers no: never hide an icon the user may own.
    _a11yIsOurs(state) {
        if (state?.textScale !== 1.0)
            return false;
        try {
            const iface = new Gio.Settings(
                {schema_id: 'org.gnome.desktop.interface'});
            if (iface.get_double('text-scaling-factor') <= 1.0)
                return false;
            const prefs = new Gio.Settings(
                {schema_id: 'org.gnome.desktop.a11y'});
            if (prefs.get_boolean('always-show-universal-access-status'))
                return false;
            const active = (Main.panel.statusArea.a11y?.menu
                ?._getMenuItems?.() ?? []).filter(item => item.state === true);
            return active.length <= 1;
        } catch {
            return false;
        }
    }

    // Hide the container, not the button: ATIndicator recomputes its own
    // `visible` on every settings change, so fighting it there would need its
    // private resync to undo. Nothing in current shells touches the
    // container's visibility (verified against gnome-50 panel.js), so a hide
    // holds; the 'show' listener covers older shells that synced it from the
    // button.
    _suppressA11y() {
        if (this._a11ySignal)
            return;
        const a11y = Main.panel.statusArea.a11y;
        if (!a11y)
            return;
        this._a11y = a11y;
        this._a11ySignal = a11y.container.connect('show',
            () => a11y.container.hide());
        a11y.container.hide();
    }

    _unsuppressA11y() {
        if (!this._a11ySignal)
            return;
        this._a11y.container.disconnect(this._a11ySignal);
        // Back to the shell's own default: the container always visible, the
        // button's own `visible` deciding. Mirroring the button here would
        // read a value its idle resync hasn't caught up to yet, and a
        // container left hidden would outlive the run.
        this._a11y.container.visible = true;
        this._a11y = null;
        this._a11ySignal = null;
    }

    restoreNow() {
        const bin = GLib.find_program_in_path('gamescale') ??
            GLib.build_filenamev(
                [GLib.get_home_dir(), '.local', 'bin', 'gamescale']);
        let proc;
        try {
            proc = Gio.Subprocess.new([bin, '--restore'], SILENCE);
        } catch (e) {
            Main.notifyError('gamescale', `could not run ${bin}: ${e.message}`);
            return;
        }
        // Success shows itself — the icon disappears. Only failure speaks,
        // because a silently failed restore is the stranded-desktop case.
        proc.wait_async(null, (p, res) => {
            try {
                p.wait_finish(res);
            } catch {
                return;
            }
            if (!p.get_successful()) {
                Main.notifyError('gamescale',
                    'restore failed — state kept; see gamescale --status');
            }
        });
    }
}
