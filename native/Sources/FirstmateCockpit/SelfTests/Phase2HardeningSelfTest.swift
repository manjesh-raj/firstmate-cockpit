// Manjesh Grand Line - native macOS app.
//
// `swift build && FM_RUN_PHASE2_HARDENING_TESTS=1 .build/debug/FirstmateCockpit`
//
// The Phase 2 findings whose fix is small, easily reverted, and invisible until
// the day it matters - the same bar `Phase1HardeningSelfTest` was written to:
//
//  - **GL-10 / GL-30**: a failed persistence write reaches the log, the Health
//    card and the Notification Center instead of being swallowed. Includes a
//    source guard, because the regression here is literally typing `try?`.
//  - **GL-11 / F1**: `ServiceHealthRegistry`'s verdicts and its
//    failure-threshold rule, which is what decides whether a wedged poller
//    ever becomes visible.
//  - **GL-38**: the PR merge action passes the task id `bin/fm-pr-merge.sh`
//    requires. This one shipped broken end to end for its whole life because
//    nothing asserted the argv shape.
//  - **GL-09**: the app lock's own coverage predicate - the surfaces that must
//    refuse to act while locked.
//  - **GL-23**: one shared `CommandLibraryStore`, not two diverging caches.
//
// Everything here is pure logic or scratch-directory I/O. Nothing touches the
// captain's real stores, and nothing launches the app.

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
import LocalAuthentication

enum Phase2HardeningSelfTest {

    private static var failures: [String] = []

    private static func check(_ condition: Bool, _ label: String) {
        if condition {
            print("  ✓ \(label)")
        } else {
            print("  ✗ \(label)")
            failures.append(label)
        }
    }

    static func run() -> Bool {
        print("== Phase 2 hardening self-test ==")
        failures = []

        healthRegistryVerdicts()
        healthFailureThresholdRaisesANotification()
        persistenceFailureIsReportedNotSwallowed()
        noSilentPersistenceWrites()
        atomicWriteThrowsRatherThanFailingQuietly()
        mergeCommandCarriesTheTaskID()
        lockGatesOutOfWindowSurfaces()
        touchIDCancelIsNotAFallback()
        subprocessAdoptionIsComplete()

        print(failures.isEmpty
            ? "== PASS (phase 2 hardening) =="
            : "== FAIL (phase 2 hardening): \(failures.count) case(s) ==")
        return failures.isEmpty
    }

    // MARK: - GL-11 / F1

    private static func healthRegistryVerdicts() {
        print("- ServiceHealth: a service's verdict follows its own reports")

        let registry = ServiceHealthRegistry.shared
        // `.docsSync` is used here rather than a real production service so a
        // self-test run cannot make the Health card lie about the poller.
        let service = HealthService.docsSync

        registry.recordSuccess(service, at: Date())
        check(registry.state(service).verdict == .healthy, "a success is healthy")
        check(registry.state(service).consecutiveFailures == 0, "and resets the failure count")

        registry.recordFailure(service, "network unreachable")
        var state = registry.state(service)
        check(state.verdict == .degraded, "one failure is degraded, not failing - a blip is not news")
        check(state.lastFailureDetail == "network unreachable", "the detail is kept for the card")
        check(state.lastSuccess != nil, "the last successful run is still remembered alongside it")

        registry.recordFailure(service, "network unreachable")
        registry.recordFailure(service, "network unreachable")
        state = registry.state(service)
        check(state.consecutiveFailures >= ServiceHealthRegistry.failureThreshold,
              "three in a row crosses the threshold (\(state.consecutiveFailures))")
        check(state.verdict == .failing, "and the verdict becomes failing")

        registry.recordSuccess(service)
        check(registry.state(service).verdict == .healthy, "one success clears it again")
        check(registry.state(service).lastFailureDetail == nil, "and drops the stale failure detail")

        registry.markRunning(service)
        check(registry.state(service).verdict == .running,
              "an in-flight pass reads as running rather than showing a stale timestamp as current")
        registry.recordSuccess(service)

        // An unreported service must not claim health it has not demonstrated.
        check(ServiceHealthState().verdict == .unknown, "a never-run service is unknown, not healthy")
    }

    private static func healthFailureThresholdRaisesANotification() {
        print("- ServiceHealth: crossing the threshold raises a Notification Center entry")

        let service = HealthService.docsSync
        let id = NotificationSources.serviceFailingID(service)
        // `recordFailure` publishes to the Notification Center on the main
        // queue, so the previous case's three failures are still queued here.
        // Drain them *before* clearing, or the clear happens first and the
        // stale publish lands on top of it.
        pumpMainQueue()
        NotificationSources.clearServiceFailing(service)
        ServiceHealthRegistry.shared.recordSuccess(service)
        pumpMainQueue()

        ServiceHealthRegistry.shared.recordFailure(service, "gh api: HTTP 503")
        pumpMainQueue()
        check(!GrandLineNotificationCenter.shared.entries.contains { $0.id == id },
              "one failure raises nothing")

        for _ in 0..<(ServiceHealthRegistry.failureThreshold - 1) {
            ServiceHealthRegistry.shared.recordFailure(service, "gh api: HTTP 503")
        }
        pumpMainQueue()
        let entry = GrandLineNotificationCenter.shared.entries.first { $0.id == id }
        check(entry != nil, "the threshold raises one")
        check(entry?.kind == .informational,
              "as informational, so a captain who knows they are offline can dismiss it")
        check((entry?.subtext ?? "").contains("503"), "carrying the real reason: \(entry?.subtext ?? "")")

        NotificationSources.clearServiceFailing(service)
        ServiceHealthRegistry.shared.recordSuccess(service)
        check(!GrandLineNotificationCenter.shared.entries.contains { $0.id == id }, "and it clears")
    }

    // MARK: - GL-10 / GL-30

    private static func persistenceFailureIsReportedNotSwallowed() {
        print("- a failed write reaches the Health card and the Notification Center")

        PersistenceFailureReporter.resetForTests()
        NotificationSources.setPersistenceFailure(count: 0, detail: "")

        // A real, guaranteed-to-fail write: a path whose parent is a *file*,
        // not a directory, so `createDirectory` genuinely fails.
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("grandline-phase2-\(UUID().uuidString)")
        try? Data("i am a file".utf8).write(to: base)
        defer { try? FileManager.default.removeItem(at: base) }
        let impossible = base.appendingPathComponent("nested/file.yaml")

        var threw = false
        do {
            try AtomicWrite.text("payload", to: impossible)
        } catch {
            threw = true
            PersistenceFailureReporter.report(what: "task", path: impossible.path, error: error)
        }
        check(threw, "the write threw rather than returning quietly")
        pumpMainQueue()

        check(PersistenceFailureReporter.recent.first?.what == "task",
              "the failure is recorded with what was being saved, not just a path")
        let entry = GrandLineNotificationCenter.shared.entries
            .first { $0.id == NotificationSources.persistenceFailureID }
        check(entry != nil, "a Notification Center entry exists")
        check(entry?.kind == .actionNeeded,
              "as actionNeeded - unlike being offline, a failed save will not fix itself")
        check(ServiceHealthRegistry.shared.state(.persistence).lastFailure != nil,
              "and the Health card's persistence row knows")

        PersistenceFailureReporter.acknowledge()
        pumpMainQueue()
        check(!GrandLineNotificationCenter.shared.entries
                .contains { $0.id == NotificationSources.persistenceFailureID },
              "acknowledging clears the notification")
        check(!PersistenceFailureReporter.recent.isEmpty,
              "but keeps the log, so the Health card can still show what happened")
        PersistenceFailureReporter.resetForTests()
    }

    /// The source guard. GL-10's regression is one character (`try` -> `try?`),
    /// invisible in review and invisible at runtime, so it is asserted against
    /// the source rather than against behaviour.
    private static func noSilentPersistenceWrites() {
        print("- source guard: no `try?` write remains in the three stores GL-10 names")

        let files = ["ShiftStore.swift", "CommandLibraryStore.swift", "DocsRunbookData.swift", "ShiftYaml.swift"]
        var offenders: [String] = []
        for name in files {
            guard let text = sourceText(name) else {
                offenders.append("\(name): could not be read")
                continue
            }
            for (index, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.contains("try?") else { continue }
                // A `try?` *read* is legitimate - a missing file is a normal
                // state, and Phase 1's `readListChecked` owns the ones that are
                // not. Only writes are the finding.
                let isWrite = trimmed.contains(".write(") || trimmed.contains("AtomicWrite.")
                    || trimmed.contains("writeList") || trimmed.contains("writeMapping")
                    || trimmed.contains("persist(")
                if isWrite {
                    offenders.append("\(name):\(index + 1): \(trimmed)")
                }
            }
        }
        check(offenders.isEmpty, "none found" + (offenders.isEmpty ? "" : " - \(offenders.joined(separator: " | "))"))
    }

    private static func atomicWriteThrowsRatherThanFailingQuietly() {
        print("- AtomicWrite creates intermediate directories and round-trips")

        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("grandline-phase2-write-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let target = dir.appendingPathComponent("a/b/c.yaml")

        do {
            try AtomicWrite.text("hello\n", to: target)
            let read = try String(contentsOf: target, encoding: .utf8)
            check(read == "hello\n", "the bytes landed through two levels of new directory")
        } catch {
            check(false, "should have succeeded: \(error.localizedDescription)")
        }
    }

    // MARK: - GL-38

    private static func mergeCommandCarriesTheTaskID() {
        print("- GL-38: the merge action passes <task-id> <pr-url>, which is what the script requires")

        let args = FleetDataSource.mergeArguments(taskID: "grandline-review-phase2-harden",
                                                 url: "https://github.com/o/r/pull/7")
        check(args == ["grandline-review-phase2-harden", "https://github.com/o/r/pull/7"],
              "argv is exactly [task id, url]: \(args)")

        // The review's own evidence: `mergePR` used to pass only the URL, so
        // the script's `$#` guard rejected every invocation. A merge with no
        // task id is now unrepresentable rather than silently broken.
        check(!FleetDataSource.canMerge(PRWithoutTask), "a PR with no tracked task cannot be merged")
        check(FleetDataSource.canMerge(PRWithTask), "a green PR with a tracked task can")
        check(!FleetDataSource.canMerge(PRWithTaskButRedChecks),
              "and a tracked PR whose checks are failing still cannot")
    }

    private static func samplePR(taskID: String?, checks: String, source: String) -> MergedPR {
        MergedPR(source: source, taskID: taskID, repo: "repo",
                 url: "https://github.com/o/r/pull/1", number: 1,
                 title: "t", checks: checks, forge: "github")
    }
    private static var PRWithoutTask: MergedPR { samplePR(taskID: nil, checks: "green", source: "forge") }
    private static var PRWithTask: MergedPR { samplePR(taskID: "task-1", checks: "green", source: "work") }
    private static var PRWithTaskButRedChecks: MergedPR { samplePR(taskID: "task-1", checks: "red", source: "work") }

    // MARK: - GL-09

    private static func lockGatesOutOfWindowSurfaces() {
        print("- GL-09: the lock's own gate refuses out-of-window surfaces while locked")

        let gate = AppLockGate.shared
        let wasLocked = gate.isLocked

        gate.setLocked(true)
        check(!gate.allows(.dictation), "dictation is refused while locked")
        check(!gate.allows(.quickCapture), "so is ⌥Space quick capture")
        check(!gate.allows(.menuBarPopover), "so is the menu-bar popover")
        check(!gate.allows(.menuBarContent), "and the status item stops disclosing counts")

        gate.setLocked(false)
        check(gate.allows(.dictation) && gate.allows(.quickCapture)
                && gate.allows(.menuBarPopover) && gate.allows(.menuBarContent),
              "all four are allowed again once unlocked")

        gate.setLocked(wasLocked)
    }

    // MARK: - Touch ID cancel (resolved captain decision)

    /// The decision: cancelling the Touch ID / passcode prompt during a keyed
    /// SSH connect aborts the connect, rather than silently continuing without
    /// `-i` and falling back to the system agent. Tested through
    /// `KeychainKeyStore.classify`, which is the whole decision - the branch in
    /// `connectSSH` keys off `KeychainError.userCancelled` and nothing else.
    private static func touchIDCancelIsNotAFallback() {
        print("- Touch ID: a cancel is classified as a cancel, an error stays an error")

        for code in [LAError.Code.userCancel, .appCancel, .systemCancel] {
            let classified = KeychainKeyStore.classify(LAError(code))
            if case KeychainError.userCancelled = classified {
                check(true, "LAError.\(code) maps to userCancelled")
            } else {
                check(false, "LAError.\(code) should map to userCancelled, got \(classified)")
            }
        }

        // A genuine failure must NOT become a cancel: an accident (no biometry
        // enrolled, a Keychain fault) still falls through to agent auth, which
        // is the pre-existing behaviour and deliberately unchanged.
        for code in [LAError.Code.authenticationFailed, .biometryNotEnrolled, .passcodeNotSet] {
            let classified = KeychainKeyStore.classify(LAError(code))
            if case KeychainError.userCancelled = classified {
                check(false, "LAError.\(code) must not be treated as a cancel")
            } else {
                check(true, "LAError.\(code) stays a real error")
            }
        }

        let unrelated = KeychainKeyStore.classify(KeychainError.notFound)
        if case KeychainError.userCancelled = unrelated {
            check(false, "a non-LAError must not become a cancel")
        } else {
            check(true, "a non-LAError passes through unchanged")
        }
    }

    // MARK: - GL-02 / GL-15 adoption

    /// The consolidation is only worth anything if it is actually adopted; a
    /// new hand-rolled `Process` with the old drain order reintroduces the
    /// deadlock class in one file while the shared runner sits unused next to
    /// it. This guard is a source sweep, with an explicit allowlist so the
    /// genuine exceptions are visible rather than lost in a count.
    private static func subprocessAdoptionIsComplete() {
        print("- source guard: no hand-rolled Process outside the allowlisted exceptions")

        // Each entry is a real reason, not a to-do:
        //   Subprocess.swift          - is the runner.
        //   *SelfTest.swift           - deliberately drive raw Process to
        //                               reproduce the pre-fix behaviour.
        //   SingleInstanceGuard/…     - none today; kept for the shape.
        let allowed: Set<String> = ["Subprocess.swift"]
        var offenders: [String] = []

        let fm = FileManager.default
        guard let dir = sourceDirectory(),
              let names = try? fm.contentsOfDirectory(atPath: dir.path) else {
            check(false, "could not enumerate the source directory")
            return
        }
        for name in names.sorted() where name.hasSuffix(".swift") {
            if allowed.contains(name) || name.hasSuffix("SelfTest.swift") { continue }
            guard let text = try? String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8) else { continue }
            if text.contains("Process()") {
                offenders.append(name)
            }
        }
        check(offenders.isEmpty,
              offenders.isEmpty ? "every call site goes through Subprocess"
                                : "still hand-rolling Process: \(offenders.joined(separator: ", "))")
    }

    // MARK: - Helpers

    /// The source tree, for the two guards above. Walks up from the working
    /// directory looking for the package, the same way `SRELead` locates its
    /// MCP script in the dev flow - so this works from `native/` or from the
    /// repo root.
    private static func sourceDirectory() -> URL? {
        var dir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        for _ in 0..<6 {
            let candidate = dir.appendingPathComponent("Sources/FirstmateCockpit")
            if FileManager.default.fileExists(atPath: candidate.appendingPathComponent("Subprocess.swift").path) {
                return candidate
            }
            let nested = dir.appendingPathComponent("native/Sources/FirstmateCockpit")
            if FileManager.default.fileExists(atPath: nested.appendingPathComponent("Subprocess.swift").path) {
                return nested
            }
            dir = dir.deletingLastPathComponent()
        }
        return nil
    }

    private static func sourceText(_ name: String) -> String? {
        guard let dir = sourceDirectory() else { return nil }
        return try? String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8)
    }

    /// Several of the reporters above hop to the main queue deliberately (the
    /// Notification Center store is main-thread-only). A headless self-test has
    /// no running main loop, so pump it.
    private static func pumpMainQueue() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
    }
}

#endif
