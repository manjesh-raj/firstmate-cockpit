// Manjesh Grand Line - native macOS app.
//
// App-level preferences, backed by `UserDefaults`. Before the Settings panel
// (Fix 3), these lived as ad-hoc environment-variable reads scattered across
// `TerminalEnvironment.swift` (`FM_SHELL_CWD`, `FM_MIRROR_TARGET`) and
// `ConsoleController` (`FM_LOG_SESSIONS_DEFAULT`), with no UI to change them.
// The env vars still win when set (so existing dev/CI workflows that export
// them keep working unchanged); otherwise the persisted value here applies,
// editable from Settings > General.

import Foundation

final class AppSettings {
    static let shared = AppSettings()

    private let defaults = UserDefaults.standard

    private enum Keys {
        static let fontSize = "fm.fontSize"
        static let defaultShellCwd = "fm.defaultShellCwd"
        static let mirrorTarget = "fm.mirrorTarget"
        static let sessionLoggingDefault = "fm.sessionLoggingDefault"
        static let autoReconnect = "fm.autoReconnect"
        static let notifyOnNeedsDecision = "fm.notifyOnNeedsDecision"
        static let fmHome = "fm.fmHome"
    }

    private init() {}

    /// Terminal font size in points. Settings > Terminal's +/- steppers and
    /// `ConsoleController.zoomIn/zoomOut` both read and write this so the
    /// choice survives relaunch.
    var fontSize: CGFloat {
        get {
            let v = defaults.double(forKey: Keys.fontSize)
            return v > 0 ? CGFloat(v) : 13
        }
        set { defaults.set(Double(newValue), forKey: Keys.fontSize) }
    }

    /// Settings > General's "Default working directory" - checked by
    /// `shellCwd()` after `FM_SHELL_CWD`, before falling back to `$HOME`.
    var defaultShellCwd: String? {
        get { defaults.string(forKey: Keys.defaultShellCwd) }
        set { defaults.set(newValue, forKey: Keys.defaultShellCwd) }
    }

    /// Settings > General's "Mirror target" - checked by `mirrorTarget()`
    /// after `FM_MIRROR_TARGET`.
    var mirrorTarget: String? {
        get { defaults.string(forKey: Keys.mirrorTarget) }
        set { defaults.set(newValue, forKey: Keys.mirrorTarget) }
    }

    /// Settings > General's "Log sessions by default" toggle - checked by
    /// `ConsoleController` after `FM_LOG_SESSIONS_DEFAULT`.
    var sessionLoggingDefault: Bool {
        get { defaults.bool(forKey: Keys.sessionLoggingDefault) }
        set { defaults.set(newValue, forKey: Keys.sessionLoggingDefault) }
    }

    /// Settings > Terminal's "Reconnect automatically" toggle (Fix 3) -
    /// `ConsoleController.processTerminated` schedules a real reconnect of a
    /// tab whose process exited unexpectedly when this is on, rather than
    /// just showing the "press ⌘R to reconnect" hint. Defaults to on, since
    /// a dropped connection auto-recovering is the least surprising default.
    var autoReconnect: Bool {
        get { defaults.object(forKey: Keys.autoReconnect) == nil ? true : defaults.bool(forKey: Keys.autoReconnect) }
        set { defaults.set(newValue, forKey: Keys.autoReconnect) }
    }

    /// Settings > Terminal's "Bell & notifications" toggle (Fix 3) - when on,
    /// `FleetNotifier` posts a real macOS notification the moment a task
    /// newly needs the captain's decision. Off by default so a fresh launch
    /// never surprises anyone with a notification-permission prompt.
    var notifyOnNeedsDecision: Bool {
        get { defaults.bool(forKey: Keys.notifyOnNeedsDecision) }
        set { defaults.set(newValue, forKey: Keys.notifyOnNeedsDecision) }
    }

    /// Bootstrap page's "Firstmate home" card - checked by
    /// `FirstmateHome.resolve()` after `FM_HOME`/`FIRSTMATE_HOME`, before the
    /// hardcoded fallback candidates. `FirstmateHome.root` is computed once
    /// at process launch, so changing this only takes effect after a
    /// restart - the Bootstrap page makes that explicit on save.
    var fmHome: String? {
        get { defaults.string(forKey: Keys.fmHome) }
        set { defaults.set(newValue, forKey: Keys.fmHome) }
    }
}
