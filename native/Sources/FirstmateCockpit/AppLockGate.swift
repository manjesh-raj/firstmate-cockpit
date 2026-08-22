// Manjesh Grand Line - native macOS app.
//
// GL-09 (production-readiness review, section 15, High): the app lock's
// coverage. `LockScreenController`'s overlay is a subview of the main window's
// root, and `AppDelegate.setContentMenusEnabled` disables menu *items* - so
// before this file, everything that lives outside that one window kept working
// while locked. The review verified, and this is the honest list:
//
//  - The Shift menu-bar status item kept showing the due count in its title,
//    kept opening its popover (which discloses the next follow-up's title),
//    and its quick-add kept writing tasks - and pushing them to GitHub.
//  - ⌥Space quick capture still opened and still wrote.
//  - Dictation still recorded, transcribed, sent the transcript to `claude`,
//    pasted it into whatever had focus, and appended it to history.
//  - A Host Editor window already open at lock time stayed fully usable, at
//    `.floating` level, above the lock screen.
//
// Against the lock's actual threat model - somebody walking up to an unlocked
// Mac - each of those both discloses data and accepts writes.
//
// ## Why a separate gate rather than checks against `AppLockController`
//
// The surfaces above are not owned by the window: two are global `NSEvent`
// monitors, one is an `NSStatusItem`, one is a floating window. They have no
// path to the shell controller, and giving them one would mean four new
// dependencies pointing the wrong way through the app (`ShiftMenuBar` knowing
// about `AppShellController` is exactly the coupling this codebase's
// forward-don't-own convention exists to avoid).
//
// So this is one tiny piece of shared state that anything may read. The lock
// controller is its only writer, which keeps "am I locked" single-sourced -
// and a surface that forgets to consult it is a visible one-line omission
// rather than a subtle wiring bug.
//
// ## The rule for adding a surface
//
// Any code path that (a) runs while the main window is not frontmost, and
// (b) either shows the captain's data or writes it, must consult `allows(_:)`.
// Add a case rather than reusing a loosely-related one: the case names are
// what `Phase2HardeningSelfTest` asserts, and a shared case would hide a
// surface losing its gate.

import AppKit

/// The out-of-window surfaces the lock has to cover. Not a general capability
/// system - these are exactly the four the review found, plus the two windows
/// that need ordering out.
enum AppLockedSurface {
    /// The menu-bar status item's own title/tooltip content (the due count).
    case menuBarContent
    /// Opening the status item's popover at all.
    case menuBarPopover
    /// ⌥Space global quick capture.
    case quickCapture
    /// Recording, transcribing, pasting and logging a dictation.
    case dictation
}

final class AppLockGate {

    static let shared = AppLockGate()

    /// Starts locked, because the app does: `AppShellController` shows the lock
    /// screen before anything else at launch. Defaulting to unlocked would mean
    /// a window between process start and the first `setLocked(true)` during
    /// which a global hotkey was live.
    private(set) var isLocked: Bool = true

    private var observers: [(Bool) -> Void] = []
    private var secondaryWindows: [() -> NSWindow?] = []

    private init() {}

    /// The lock controller is the only caller. Notifies observers and orders
    /// out every registered secondary window on the way into the locked state.
    func setLocked(_ locked: Bool) {
        let changed = locked != isLocked
        isLocked = locked
        if locked { orderOutSecondaryWindows() }
        guard changed else { return }
        AppLog.lifecycle.info("lock gate: \(locked ? "locked" : "unlocked", privacy: .public)")
        for observer in observers { observer(locked) }
    }

    /// Every gated surface asks this. Deliberately one method rather than a
    /// per-surface property: the grep for `allows(` is the list of everything
    /// the lock covers.
    func allows(_ surface: AppLockedSurface) -> Bool { !isLocked }

    /// Fires immediately with the current state, then on every change - the
    /// same shape as `ThemeManager.observe`, for the same reason (a surface
    /// registering after launch must not be left holding a stale assumption).
    func observe(_ handler: @escaping (Bool) -> Void) {
        observers.append(handler)
        handler(isLocked)
    }

    /// Register a window that must not stay on screen over the lock. A closure
    /// rather than the window itself because these are all created lazily and
    /// recreated (the Host Editor is cached per presentation, the palettes
    /// build their panel on first use).
    ///
    /// Explicit registration, not a sweep of `NSApp.windows`: that array
    /// includes AppKit's own `NSStatusBarWindow` and popover windows, and
    /// ordering those out would break the status item rather than secure it.
    func registerSecondaryWindow(_ provider: @escaping () -> NSWindow?) {
        secondaryWindows.append(provider)
        if isLocked { provider()?.orderOut(nil) }
    }

    private func orderOutSecondaryWindows() {
        for provider in secondaryWindows {
            guard let window = provider(), window.isVisible else { continue }
            AppLog.lifecycle.info("lock: ordering out \(window.title, privacy: .public)")
            window.orderOut(nil)
        }
    }
}
