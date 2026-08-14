// Manjesh Grand Line - native macOS app.
//
// App-level password lock (fm/grandline-app-lock). Reuses the Vault tab's
// existing `av` integration for the password itself (see `VaultData.swift`'s
// "App-level password lock" section) - this file owns only the lock/unlock
// state machine and its two timers, never a secret value.
//
// Three lock triggers, one state machine:
//  - launch: the app delegate calls `lock(reason: .launch)` once, before the
//    window is ever shown.
//  - idle re-lock at 1 hour: `tick()` (driven by a repeating `Timer`) reads
//    system-wide idle time via `CGEventSource.secondsSinceLastEventType` -
//    the same mechanism a screensaver uses, no Accessibility permission
//    required (unlike a global `NSEvent` monitor) - and re-locks once it
//    crosses the threshold. This is system-wide idle time, not "this app's
//    own window was idle": the whole point of an idle re-lock is "no one has
//    touched this Mac in an hour," which holds regardless of which app was
//    frontmost.
//  - hard logout at 12 hours since the *last successful unlock* (not since
//    launch - re-derived from the brief's own example: unlocking at hour 11
//    resets the clock from there, it doesn't still hit a wall at hour 12
//    from launch): `tick()` also checks `Date().timeIntervalSince(lastUnlockAt)`
//    and, if that's crossed, locks with `.sessionExpired` instead of `.idle`
//    regardless of recent activity - the hard-logout check runs first each
//    tick so a captain who is actively idle-adjacent at the 12h mark still
//    gets the "session expired" message, not the ordinary idle one.
//
// `lastUnlockAt` is in-memory only, not persisted across a relaunch - a
// relaunch already always re-locks via the `.launch` trigger regardless
// (`AppDelegate.applicationDidFinishLaunching`), so there is no window where
// skipping persistence would let content through unlocked.
//
// Every threshold and the poll interval are overridable via env vars purely
// for live verification (see this file's own test pass) - never read from
// `AppSettings`/UserDefaults, so there is no way to configure a longer idle
// window from inside the (locked) app itself.
import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

enum AppLockReason: Equatable {
    case launch
    case idle
    case sessionExpired
    case manualLogout
}

final class AppLockController {

    /// Not `private`: `AppLockControllerSelfTest` constructs instances with
    /// injected clocks/idle-time providers to exercise the timing logic
    /// without a real event loop or real elapsed wall-clock hours.
    let idleThreshold: TimeInterval
    let sessionThreshold: TimeInterval
    private let pollInterval: TimeInterval
    private let now: () -> Date
    private let systemIdleSeconds: () -> TimeInterval

    private(set) var isLocked = true
    private var lastUnlockAt: Date?
    private var timer: Timer?
    /// Held for the controller's whole lifetime once `start()` runs - macOS
    /// App Nap throttles (and can silently stop firing) a background app's
    /// timers, which is exactly the case this feature most needs to work in:
    /// the whole point of the idle/hard-logout timers is catching an
    /// unattended, possibly-backgrounded app. Confirmed live: without this,
    /// a real launched instance's 1s poll timer fired twice near launch and
    /// then never again for 8+ seconds of otherwise-idle real time, via a
    /// temporary debug probe logging every timer callback - reverted before
    /// commit, but the finding (and this fix) are real.
    private var appNapActivity: NSObjectProtocol?

    /// Set by the app delegate to actually show/hide the lock screen -
    /// this class only decides *when*, never *how*.
    var onLock: ((AppLockReason) -> Void)?

    init(
        idleThreshold: TimeInterval = AppLockController.envThreshold("FM_APP_LOCK_IDLE_SECONDS", default: 3600),
        sessionThreshold: TimeInterval = AppLockController.envThreshold("FM_APP_LOCK_SESSION_SECONDS", default: 12 * 3600),
        pollInterval: TimeInterval = AppLockController.envThreshold("FM_APP_LOCK_POLL_SECONDS", default: 30),
        now: @escaping () -> Date = Date.init,
        systemIdleSeconds: @escaping () -> TimeInterval = AppLockController.realSystemIdleSeconds
    ) {
        self.idleThreshold = idleThreshold
        self.sessionThreshold = sessionThreshold
        self.pollInterval = pollInterval
        self.now = now
        self.systemIdleSeconds = systemIdleSeconds
    }

    private static func envThreshold(_ key: String, default def: TimeInterval) -> TimeInterval {
        guard let raw = ProcessInfo.processInfo.environment[key], let value = TimeInterval(raw) else { return def }
        return value
    }

    #if canImport(CoreGraphics)
    static func realSystemIdleSeconds() -> TimeInterval {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .null)
    }
    #else
    static func realSystemIdleSeconds() -> TimeInterval { 0 }
    #endif

    func start() {
        // See `appNapActivity`'s doc comment - without this, the poll timer
        // below is subject to macOS App Nap throttling the moment this app
        // is backgrounded/occluded, which is exactly when these timers most
        // need to keep firing. Scheduled in `.common` run loop modes (not
        // just `.default`) so it keeps firing during menu tracking/live
        // resize too, not only while the run loop is fully idle.
        appNapActivity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled],
            reason: "App-level password lock idle/session timers"
        )
        timer?.invalidate()
        let newTimer = Timer(timeInterval: pollInterval, repeats: true) { [weak self] _ in
            self?.tick()
        }
        newTimer.tolerance = pollInterval * 0.1
        RunLoop.main.add(newTimer, forMode: .common)
        timer = newTimer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Not `private`: exercised directly by the self-test with a fake clock/
    /// idle-time provider rather than waiting on a real `Timer`.
    func tick() {
        guard !isLocked else { return }
        if let lastUnlockAt, now().timeIntervalSince(lastUnlockAt) >= sessionThreshold {
            lock(reason: .sessionExpired)
            return
        }
        if systemIdleSeconds() >= idleThreshold {
            lock(reason: .idle)
        }
    }

    func lock(reason: AppLockReason) {
        isLocked = true
        onLock?(reason)
    }

    /// Called once the lock screen accepts a correct password.
    func recordUnlock() {
        isLocked = false
        lastUnlockAt = now()
    }
}
