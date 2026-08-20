// Manjesh Grand Line - native macOS app.
//
// App-level preferences, backed by `UserDefaults`. Before the Settings panel
// (Fix 3), these lived as ad-hoc environment-variable reads scattered across
// `TerminalEnvironment.swift` (`FM_SHELL_CWD`, `FM_MIRROR_TARGET`), with no
// UI to change them. The env vars still win when set (so existing dev/CI
// workflows that export them keep working unchanged); otherwise the persisted
// value here applies, editable from Settings > General.

import Foundation

final class AppSettings {
    static let shared = AppSettings()

    private let defaults = UserDefaults.standard

    private enum Keys {
        static let fontSize = "fm.fontSize"
        static let defaultShellCwd = "fm.defaultShellCwd"
        static let mirrorTarget = "fm.mirrorTarget"
        static let autoReconnect = "fm.autoReconnect"
        static let notifyOnNeedsDecision = "fm.notifyOnNeedsDecision"
        static let fmHome = "fm.fmHome"
        static let dictationShortcut = "fm.dictationShortcut"
        static let dictationCleanupEnabled = "fm.dictationCleanupEnabled"
        static let dictationLocalWhisperEnabled = "fm.dictationLocalWhisperEnabled"
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

    /// Dictation's configurable shortcut (phase 2, fm/grandline-dictation-
    /// phase2) - replaces the phase-1 fixed Right ⌥ Option combo. Stored as
    /// JSON `Data` (via `Codable`) rather than a fourth/fifth/sixth flat key,
    /// since `DictationShortcut` is a small, cohesive value that's always
    /// read/written as one unit - there's no scenario where only its keyCode
    /// or only its modifier flags would be read independently. Falls back to
    /// `.defaultShortcut` (Right ⌥ Option) whenever nothing's been saved yet
    /// or the stored value fails to decode.
    var dictationShortcut: DictationShortcut {
        get {
            guard let data = defaults.data(forKey: Keys.dictationShortcut),
                  let decoded = try? JSONDecoder().decode(DictationShortcut.self, from: data) else {
                return .defaultShortcut
            }
            return decoded
        }
        set {
            guard let data = try? JSONEncoder().encode(newValue) else { return }
            defaults.set(data, forKey: Keys.dictationShortcut)
        }
    }

    /// Dictation's "Clean up my sentences" toggle (phase 3,
    /// fm/grandline-dictation-phase3) - when on, `DictationEngine.finish`
    /// rewrites the raw transcript via a one-shot `claude -p` call
    /// (`DictationCleanup.rewrite`) before pasting/recording it. Off by
    /// default: this step needs network access and the captain's own
    /// `claude` authentication, unlike the rest of the fully on-device
    /// pipeline, so a fresh install shouldn't silently start making network
    /// calls on every dictation.
    var dictationCleanupEnabled: Bool {
        get { defaults.bool(forKey: Keys.dictationCleanupEnabled) }
        set { defaults.set(newValue, forKey: Keys.dictationCleanupEnabled) }
    }

    /// Dictation's "Use local Whisper engine" toggle
    /// (fm/grandline-dictation-whisper-engine) - when on AND the large-v3-
    /// turbo model has been downloaded AND it loads successfully, dictation
    /// runs through the vendored whisper.cpp engine instead of the Apple
    /// Speech framework. Off by default: the model is a real ~547MB download
    /// that has to happen explicitly, unlike the rest of Dictation, which
    /// works immediately after a fresh install with no extra setup.
    var dictationLocalWhisperEnabled: Bool {
        get { defaults.bool(forKey: Keys.dictationLocalWhisperEnabled) }
        set { defaults.set(newValue, forKey: Keys.dictationLocalWhisperEnabled) }
    }
}
