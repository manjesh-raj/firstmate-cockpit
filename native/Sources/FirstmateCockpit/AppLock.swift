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
//
//    `fm/grandline-lock-and-rail-fixes` fixed a severe live regression here:
//    the captain reported the app re-locking every 10-30s (this class's own
//    `pollInterval`) even during continuous active use. The threshold/poll
//    constants were already correct (3600/30, confirmed by the self-test
//    below, which passes both before and after this fix) - the bug was in
//    trusting `CGEventSource` as the *only* idle signal. Two changes: (1)
//    the state ID moved from `.combinedSessionState` to `.hidSystemState` -
//    the latter is the documented, canonical idiom for "seconds since any
//    real hardware input" (what every other idle-time recipe for this exact
//    API uses); `.combinedSessionState` additionally folds in "events posted
//    by the current process via a private event source," which is the wrong
//    signal for a system-wide idle check and, on this unsigned/ad-hoc-signed
//    dev build (see this file's own "Local signing setup" notes elsewhere in
//    this repo), was the more plausible one to behave inconsistently. (2) a
//    local `NSEvent` monitor (`localActivityMonitor`, needs no Accessibility
//    permission since it only observes events already targeted at this
//    app's own windows) independently stamps `lastLocalActivityAt` on every
//    mouse/keyboard/scroll event this app receives - `tick()` now uses
//    `min(systemIdleSeconds(), secondsSinceLocalActivity())` as the idle
//    reading, so a captain who is demonstrably, continuously interacting
//    with this app's own UI can never be misread as idle no matter what a
//    single system-wide counter reports on a given machine. Genuine
//    inactivity (the captain away from the Mac entirely) still locks
//    correctly, since both signals then grow stale together.
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
#if canImport(AppKit)
import AppKit
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
    /// Stamped by `localActivityMonitor` on every mouse/keyboard/scroll event
    /// this app's own windows receive - the safety net described in this
    /// file's header. Not `private`: the self-test stamps it directly via
    /// `recordLocalActivity()` rather than needing a real event loop.
    private var lastLocalActivityAt: Date?
    /// A **local** `NSEvent` monitor (fires only for events sent to this
    /// app's own windows - unlike a *global* monitor, this needs no
    /// Accessibility/Input Monitoring permission at all). Purely a
    /// `lastLocalActivityAt` timestamp updater; never consumes/alters the
    /// event, so nothing about normal event delivery changes.
    private var localActivityMonitor: Any?
    /// Held for the controller's whole lifetime once `start()` runs - macOS
    /// App Nap throttles (and can silently stop firing) a background app's
    /// timers, which is exactly the case this feature most needs to work in:
    /// the whole point of the idle/hard-logout timers is catching an
    /// unattended, possibly-backgrounded app. Confirmed live: without this,
    /// a real launched instance's 1s poll timer fired twice near launch and
    /// then never again for 8+ seconds of otherwise-idle real time, via a
    /// temporary debug probe logging every timer callback - reverted before
    /// commit, but the finding (and this fix) are real.
    ///
    /// GL-13: the *options* on this assertion were wrong, even though the
    /// assertion itself is right. It was `[.userInitiated,
    /// .idleSystemSleepDisabled]`, held for the app's lifetime - and
    /// `.idleSystemSleepDisabled` does not just protect this app's timers, it
    /// tells macOS the whole *machine* must not idle-sleep for as long as
    /// Grand Line is open. Nothing here needs that: a lock timer that pauses
    /// while the Mac is asleep is not a problem, because the wake-up path
    /// re-reads the wall clock (`tick()` compares `Date()` against
    /// `lastUnlockAt`/idle, it does not count ticks), so a machine that slept
    /// for two hours locks correctly on wake. `.background` also means the
    /// pollers this assertion incidentally kept at full speed while the app is
    /// backgrounded are no longer promised foreground scheduling - which is the
    /// right trade for a 30-second/15-minute cadence.
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
        CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: .null)
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
        // GL-13: `.background` (not `.userInitiated`) and no
        // `.idleSystemSleepDisabled` - see `appNapActivity`'s doc comment for
        // why keeping the whole machine awake was never needed here.
        // `.background` still opts this activity out of App Nap suspension,
        // which is the one property the timer below actually depends on.
        appNapActivity = ProcessInfo.processInfo.beginActivity(
            options: [.background],
            reason: "App-level password lock idle/session timers"
        )
        timer?.invalidate()
        let newTimer = Timer(timeInterval: pollInterval, repeats: true) { [weak self] _ in
            self?.tick()
        }
        newTimer.tolerance = pollInterval * 0.1
        RunLoop.main.add(newTimer, forMode: .common)
        timer = newTimer

        #if canImport(AppKit)
        if localActivityMonitor == nil {
            localActivityMonitor = NSEvent.addLocalMonitorForEvents(
                matching: [.mouseMoved, .leftMouseDown, .rightMouseDown, .otherMouseDown,
                           .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
                           .scrollWheel, .keyDown, .flagsChanged]
            ) { [weak self] event in
                self?.recordLocalActivity()
                return event
            }
        }
        #endif
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        #if canImport(AppKit)
        if let localActivityMonitor {
            NSEvent.removeMonitor(localActivityMonitor)
        }
        localActivityMonitor = nil
        #endif
    }

    /// Stamps "the captain just did something inside this app" - called by
    /// the local `NSEvent` monitor installed in `start()`. Not `private`: the
    /// self-test calls this directly to simulate real in-app interaction
    /// without a real event loop.
    func recordLocalActivity() {
        lastLocalActivityAt = now()
    }

    /// Not `private`: exercised directly by the self-test with a fake clock/
    /// idle-time provider rather than waiting on a real `Timer`.
    func tick() {
        guard !isLocked else { return }
        if let lastUnlockAt, now().timeIntervalSince(lastUnlockAt) >= sessionThreshold {
            lock(reason: .sessionExpired)
            return
        }
        if effectiveIdleSeconds() >= idleThreshold {
            lock(reason: .idle)
        }
    }

    /// The smaller (fresher) of the system-wide idle counter and "seconds
    /// since this app last saw a real local event" - see this file's header
    /// for why relying on the system-wide signal alone caused the false-
    /// positive re-lock regression. `lastLocalActivityAt` being `nil` (no
    /// local event observed yet, e.g. right after launch) falls back to pure
    /// `systemIdleSeconds()` rather than artificially suppressing a lock.
    private func effectiveIdleSeconds() -> TimeInterval {
        let system = systemIdleSeconds()
        guard let lastLocalActivityAt else { return system }
        let local = now().timeIntervalSince(lastLocalActivityAt)
        return min(system, local)
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
