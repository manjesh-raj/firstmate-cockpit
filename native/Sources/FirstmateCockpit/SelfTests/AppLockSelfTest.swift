// Manjesh Grand Line - native macOS app.
//
// Permanent, dependency-free self-test for `AppLockController`'s pure timing
// logic (same convention as `ShiftDateParserSelfTest.swift` etc. - see
// AGENTS.md's "Verifying native UI bugs" entry): a fake clock and a fake
// system-idle-seconds provider let this exercise the 1-hour idle / 12-hour
// hard-logout math without a real event loop or real elapsed wall-clock
// hours. `FM_RUN_APP_LOCK_TESTS=1 .build/debug/FirstmateCockpit`.

// GL-27: compiled into debug builds only.
//
// The 51 self-test suites are ~10,500 lines of test code, fault-injection
// seams and fixture data that used to be linked into the binary the captain
// actually runs. `FM_SELFTESTS` is defined by `Package.swift` for the debug
// configuration only, so `swift build` (and therefore CI and
// `Scripts/run-all-tests.sh`) still has every suite, while
// `swift build -c release` - what `native/build_native_app.sh` assembles the
// shipped `.app` from - has none of it.
//
// Do not remove this guard when editing a suite: `Phase3PolishSelfTest`
// asserts that every file in this directory carries it.
#if FM_SELFTESTS

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

        // 5. `fm/grandline-lock-and-rail-fixes`: recent local in-app activity
        //    (a real click/keypress this app itself saw) must suppress an
        //    idle lock even if the system-wide idle signal reports a huge,
        //    stuck value - this is the false-positive regression fix. Real
        //    inactivity (no local activity call, system idle crosses the
        //    threshold) must still lock correctly - the fix must not trade
        //    one failure mode for the other.
        do {
            var fakeNow = Date(timeIntervalSince1970: 1_000_000)
            let lock = AppLockController(
                idleThreshold: 3600, sessionThreshold: 12 * 3600, pollInterval: 30,
                now: { fakeNow }, systemIdleSeconds: { 9999 } // stuck/bogus system-wide reading
            )
            lock.recordUnlock()
            lock.recordLocalActivity() // captain just clicked/typed inside the app
            lock.tick()
            check(!lock.isLocked, "recent local activity should suppress a lock despite a stuck system-idle reading", &ok)

            fakeNow = fakeNow.addingTimeInterval(3601)
            lock.tick()
            check(lock.isLocked, "idle lock should still fire once local activity itself goes stale", &ok)
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

#endif
