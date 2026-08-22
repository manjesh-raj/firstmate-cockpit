// Manjesh Grand Line - native macOS app.
//
// GL-29: permanent coverage for `BackgroundSignalsPoller`'s pass latch and for
// `ServiceHealthRegistry`'s verdict/threshold logic.
//
// Why the latch specifically. GL-03's shipped bug was that `isChecking` was a
// one-way door: one hung child process meant every later tick returned on
// `guard !isChecking`, and four of the Notification Center's nine signals went
// dark for the rest of the session with nothing anywhere saying so. Phase 2
// fixed it with a wall-clock watchdog and a pass id - and neither could be
// tested, because the decision was three inline lines wrapped around sixty
// subprocesses. `admit`/`mayReleaseLatch` are that decision, lifted out.
//
// Why the health registry. It is what turns a repeated failure into something
// the captain sees, and `failureThreshold` is the whole difference between
// "the network blipped once" and "this gauge is broken" - so the counter
// resetting on success is load-bearing, not incidental.
//
// Run: `FM_RUN_BACKGROUND_SIGNALS_TESTS=1 .build/debug/FirstmateCockpit`
//
// Nothing here spawns a subprocess or touches the network. The registry cases
// use a service case that no shipping code reports into during a headless run,
// so they cannot race a real reporter.

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

enum BackgroundSignalsSelfTest {

    static func run() -> Bool {
        var ok = true
        checkPassAdmission(&ok)
        checkLatchRelease(&ok)
        checkHealthVerdicts(&ok)
        print(ok ? "BackgroundSignalsSelfTest: all checks passed" : "BackgroundSignalsSelfTest: FAILED")
        return ok
    }

    private static func fail(_ message: String, _ ok: inout Bool) {
        print("  FAIL \(message)")
        ok = false
    }

    // MARK: GL-03 - the latch

    private static func checkPassAdmission(_ ok: inout Bool) {
        print("\n-- pass admission (GL-03: the latch is not a one-way door) --")
        let watchdog: TimeInterval = 300
        let now = Date()

        // Idle: go.
        if BackgroundSignalsPoller.admit(isChecking: false, passStartedAt: nil, now: now, watchdog: watchdog) != .start {
            fail("an idle poller refused to start a pass", &ok)
        }
        // Idle but with a stale start time recorded: still go. The two are set
        // together, so this is only reachable after a release, and refusing
        // here would reintroduce the stuck latch by a different route.
        if BackgroundSignalsPoller.admit(isChecking: false, passStartedAt: now.addingTimeInterval(-9999),
                                         now: now, watchdog: watchdog) != .start {
            fail("an idle poller with a stale timestamp refused to start", &ok)
        }
        // Busy and young: the ordinary skip.
        if BackgroundSignalsPoller.admit(isChecking: true, passStartedAt: now.addingTimeInterval(-30),
                                         now: now, watchdog: watchdog) != .refused {
            fail("a pass 30s into a 300s watchdog was superseded - that is just piling on", &ok)
        }
        // Exactly at the watchdog is still young: strictly greater, so the
        // boundary can never flap between two ticks landing on the same second.
        if BackgroundSignalsPoller.admit(isChecking: true, passStartedAt: now.addingTimeInterval(-watchdog),
                                         now: now, watchdog: watchdog) != .refused {
            fail("the watchdog boundary is inclusive - it should need to be genuinely exceeded", &ok)
        }
        // Busy and hung: supersede, and report how long it has been.
        switch BackgroundSignalsPoller.admit(isChecking: true, passStartedAt: now.addingTimeInterval(-601),
                                             now: now, watchdog: watchdog) {
        case .supersede(let age):
            if age < 600 { fail("superseded pass reported an age of \(age)s, want ~601", &ok) }
        default:
            fail("a pass hung for 601s past a 300s watchdog was not superseded - this is the GL-03 bug", &ok)
        }
        // Busy with no start time at all is a broken state, not a licence.
        if BackgroundSignalsPoller.admit(isChecking: true, passStartedAt: nil, now: now, watchdog: watchdog) != .refused {
            fail("a held latch with no start time started another pass anyway", &ok)
        }
        print("  OK - idle starts, young refuses, hung supersedes with a real age")
    }

    private static func checkLatchRelease(_ ok: inout Bool) {
        print("\n-- latch release (only the pass that owns it) --")
        if !BackgroundSignalsPoller.mayReleaseLatch(finishingPassID: 7, currentPassID: 7) {
            fail("the pass that owns the latch could not release it - it would stay stuck forever", &ok)
        }
        if BackgroundSignalsPoller.mayReleaseLatch(finishingPassID: 6, currentPassID: 7) {
            fail("a superseded pass released the latch out from under its replacement", &ok)
        }
        print("  OK - a superseded pass finishing cannot clear its replacement's latch")
    }

    // MARK: F1 - health verdicts

    private static func checkHealthVerdicts(_ ok: inout Bool) {
        print("\n-- service health verdicts and the failure threshold --")
        let registry = ServiceHealthRegistry.shared
        // `.docsSync` is not reported into by anything during a headless run
        // (no window, no sync started), so this cannot race a real reporter.
        let service = HealthService.docsSync

        if registry.state(service).verdict != .unknown {
            fail("a service that has never reported should read .unknown, got \(registry.state(service).verdict)", &ok)
        }
        registry.register(service)
        if registry.state(service).hasReported {
            fail("registering a service made it look like it had already reported", &ok)
        }
        if !registry.knownServices().contains(service) {
            fail("a registered service is missing from knownServices() - its row would not appear", &ok)
        }

        registry.markRunning(service)
        if registry.state(service).verdict != .running {
            fail("a running pass should read .running, got \(registry.state(service).verdict)", &ok)
        }

        registry.recordSuccess(service)
        if registry.state(service).verdict != .healthy {
            fail("a success should read .healthy, got \(registry.state(service).verdict)", &ok)
        }

        // One and two failures are "degraded"; the threshold is what escalates.
        registry.recordFailure(service, "first")
        if registry.state(service).verdict != .degraded {
            fail("one failure should read .degraded, got \(registry.state(service).verdict)", &ok)
        }
        registry.recordFailure(service, "second")
        if registry.state(service).verdict != .degraded {
            fail("two failures (threshold \(ServiceHealthRegistry.failureThreshold)) should still read .degraded", &ok)
        }
        registry.recordFailure(service, "third")
        if registry.state(service).verdict != .failing {
            fail("\(ServiceHealthRegistry.failureThreshold) failures should read .failing, got \(registry.state(service).verdict)", &ok)
        }
        if registry.state(service).lastFailureDetail != "third" {
            fail("the most recent failure detail was not retained", &ok)
        }

        // The reset is the point: "still broken" must not survive a success.
        registry.recordSuccess(service)
        if registry.state(service).consecutiveFailures != 0 {
            fail("a success did not reset the consecutive-failure count", &ok)
        }
        if registry.state(service).verdict != .healthy {
            fail("a success after crossing the threshold should read .healthy again", &ok)
        }
        if registry.state(service).lastFailureDetail != nil {
            fail("a success left a stale failure detail behind", &ok)
        }
        print("  OK - unknown -> running -> healthy -> degraded -> failing, and a success resets it")
    }
}

#endif
