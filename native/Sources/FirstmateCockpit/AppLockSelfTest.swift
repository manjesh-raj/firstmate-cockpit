// Manjesh Grand Line - native macOS app.
//
// Permanent, dependency-free self-test for `AppLockController`'s pure timing
// logic (same convention as `ShiftDateParserSelfTest.swift` etc. - see
// AGENTS.md's "Verifying native UI bugs" entry): a fake clock and a fake
// system-idle-seconds provider let this exercise the 1-hour idle / 12-hour
// hard-logout math without a real event loop or real elapsed wall-clock
// hours. `FM_RUN_APP_LOCK_TESTS=1 .build/debug/FirstmateCockpit`.
import Foundation

enum AppLockControllerSelfTest {
    static func run() -> Bool {
        var ok = true

        // 1. Idle re-lock fires once system idle time crosses the threshold,
        //    not before.
        do {
            var fakeIdle: TimeInterval = 0
            let lock = AppLockController(
                idleThreshold: 3600, sessionThreshold: 12 * 3600, pollInterval: 30,
                now: { Date(timeIntervalSince1970: 1_000_000) },
                systemIdleSeconds: { fakeIdle }
            )
            lock.recordUnlock()
            fakeIdle = 3599
            lock.tick()
            check(!lock.isLocked, "idle just under threshold should not lock", &ok)
            fakeIdle = 3600
            var lockedReason: AppLockReason?
            lock.onLock = { lockedReason = $0 }
            lock.tick()
            check(lock.isLocked, "idle at threshold should lock", &ok)
            check(lockedReason == .idle, "idle lock should report .idle", &ok)
        }

        // 2. Hard logout fires at 12h since the *last unlock*, not since a
        //    fixed launch time - unlocking partway through resets the clock.
        do {
            var fakeNow = Date(timeIntervalSince1970: 1_000_000)
            let lock = AppLockController(
                idleThreshold: 3600, sessionThreshold: 12 * 3600, pollInterval: 30,
                now: { fakeNow }, systemIdleSeconds: { 0 }
            )
            lock.recordUnlock() // unlock at t=0
            fakeNow = fakeNow.addingTimeInterval(11 * 3600) // hour 11: re-unlock resets the clock
            lock.recordUnlock()
            fakeNow = fakeNow.addingTimeInterval(11 * 3600) // 11h after the *second* unlock - should NOT expire yet
            lock.tick()
            check(!lock.isLocked, "12h clock should reset from the later unlock, not the original launch", &ok)
            fakeNow = fakeNow.addingTimeInterval(1 * 3600 + 1) // now 12h+ since the second unlock
            var lockedReason: AppLockReason?
            lock.onLock = { lockedReason = $0 }
            lock.tick()
            check(lock.isLocked, "12h since last unlock should force logout", &ok)
            check(lockedReason == .sessionExpired, "hard logout should report .sessionExpired, not .idle", &ok)
        }

        // 3. A locked controller doesn't keep firing/re-evaluating on tick.
        do {
            var tickCount = 0
            let lock = AppLockController(
                idleThreshold: 3600, sessionThreshold: 12 * 3600, pollInterval: 30,
                now: { Date(timeIntervalSince1970: 1_000_000) },
                systemIdleSeconds: { tickCount += 1; return 9999 }
            )
            // Never unlocked - starts locked by construction.
            lock.tick()
            check(tickCount == 0, "tick() should no-op while already locked (idle-seconds provider never called)", &ok)
        }

        // 4. The hard-logout check takes priority over idle at the same
        //    tick, so a captain who is exactly at the 12h mark gets the
        //    session-expired message even if they're also idle right then.
        do {
            var fakeNow = Date(timeIntervalSince1970: 1_000_000)
            let lock = AppLockController(
                idleThreshold: 3600, sessionThreshold: 12 * 3600, pollInterval: 30,
                now: { fakeNow }, systemIdleSeconds: { 4000 }
            )
            lock.recordUnlock()
            fakeNow = fakeNow.addingTimeInterval(12 * 3600 + 1)
            var lockedReason: AppLockReason?
            lock.onLock = { lockedReason = $0 }
            lock.tick()
            check(lockedReason == .sessionExpired, "both thresholds crossed at once should report .sessionExpired, not .idle", &ok)
        }

        return ok
    }

    private static func check(_ condition: Bool, _ message: String, _ ok: inout Bool) {
        if !condition {
            print("FAIL: \(message)")
            ok = false
        }
    }
}
