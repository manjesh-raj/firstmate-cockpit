// Manjesh Grand Line - native macOS app.
//
// `fm/grandline-mirror-resolve-race-fix`: reproduces, live, the captain-
// reported boot-race bug this task fixed, then proves the fix.
//
// The bug: `ConsoleController.openFirstmateHost()` used to build a Mirror
// tab's launch spec from `mirrorTarget()` (which called
// `FirstmateBackend.resolve()` once to decide the *target* string), and then
// `connectMirror` called `FirstmateBackend.resolve()` again, independently,
// to decide `TmuxMirror` vs. `HerdrMirror` (the *kind*). Right after a
// machine restart, herdr's own background server can flip from down to up
// in the gap between those two calls - the first call saw no live evidence
// and fell back to the tmux-era literal target `"firstmate"`; the second,
// moments later, saw herdr now live and picked the herdr path - producing a
// real connection attempt against herdr's real session machinery, using the
// stale, wrong target name. The exact captain-reported error:
// `[herdr] Cannot mirror 'firstmate': no running herdr session named 'firstmate'`,
// even though herdr's real session (`default`) was genuinely up.
//
// This test reproduces that disagreement for real, using the actual
// production types (`FirstmateBackend.resolve()`, `HerdrMirror.setUp`) - not
// a reimplementation of them - against two small real fake `herdr`
// executables switched in via a live `setenv("PATH", ...)` between two
// calls, deterministically forcing the down-then-up flip the captain hit by
// chance. (`HerdrMirror.resolveHerdr()`'s PATH search returns the first
// match, so putting the fake ahead of `/opt/homebrew/bin` in `PATH` shadows
// this machine's real herdr binary for the duration of one call - nothing
// about the real, live herdr session this machine is genuinely running
// under is read, touched, or affected.) It then confirms
// `FirstmateBackend.resolveMirrorTarget()` - the fix - cannot reproduce the
// same disagreement under the identical forced conditions, since it makes
// exactly one live-evidence check per call, counted directly via the fake
// script incrementing a counter file.
//
// Finally, two regression checks confirm the fix didn't change behavior for
// the two cases that were never racing: an explicit `FM_BACKEND=tmux`
// override (deterministic, no live evidence needed) and this machine's own
// real, already-live herdr session (`herdr session list --json`, confirmed
// live before writing this test to be a genuine running session named
// `default` - read-only, never started/stopped/touched here, per this
// task's hard safety gate on herdr lifecycle commands).
//
// Run with:
//   swift build && FM_RUN_MIRROR_RESOLVE_RACE_TESTS=1 .build/debug/FirstmateCockpit; echo $?

import AppKit
import Foundation

enum MirrorResolveRaceSelfTest {

    static func run() -> Bool {
        let cases: [(String, () -> String?)] = [
            ("raceReproducesCaptainReportedBug", test_raceReproducesCaptainReportedBug),
            ("atomicResolverMakesExactlyOneLiveEvidenceCheck", test_atomicResolverMakesExactlyOneCheck),
            ("atomicResolverConnectsCleanlyOnceHerdrIsLive", test_atomicResolverConnectsCleanlyOnceHerdrIsLive),
            ("consoleControllerFreezesConsistentKindAndTarget", test_consoleControllerFreezesConsistentKindAndTarget),
            ("noRegressionExplicitTmuxOverride", test_noRegressionExplicitTmuxOverride),
            ("noRegressionRealLiveHerdrFleet", test_noRegressionRealLiveHerdrFleet),
        ]
        var failures = 0
        for (name, testCase) in cases {
            let originalPath = ProcessInfo.processInfo.environment["PATH"]
            let originalBackend = ProcessInfo.processInfo.environment["FM_BACKEND"]
            defer {
                if let originalPath { setenv("PATH", originalPath, 1) } else { unsetenv("PATH") }
                if let originalBackend { setenv("FM_BACKEND", originalBackend, 1) } else { unsetenv("FM_BACKEND") }
            }
            if let failure = testCase() {
                print("FAIL \(name): \(failure)")
                failures += 1
            } else {
                print("PASS \(name)")
            }
        }
        print(failures == 0 ? "MirrorResolveRaceSelfTest: all \(cases.count) cases passed" : "MirrorResolveRaceSelfTest: \(failures)/\(cases.count) cases FAILED")
        return failures == 0
    }

    // MARK: Fake herdr fixtures

    private static let scratchRoot = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("fm-mirror-resolve-race-selftest-\(ProcessInfo.processInfo.processIdentifier)")

    /// Writes a fake `herdr` executable at `<scratchRoot>/<name>/herdr` that
    /// appends one line to `counterPath` per invocation (so a test can
    /// assert exactly how many times it ran) and prints `sessionsJSON` -
    /// `[]` for "not up yet", or a real session entry for "live now".
    @discardableResult
    private static func writeFakeHerdr(name: String, sessionsJSON: String, counterPath: String) -> String {
        let dir = scratchRoot.appendingPathComponent(name)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let script = dir.appendingPathComponent("herdr")
        let contents = """
        #!/bin/bash
        echo "1" >> "\(counterPath)"
        echo '{"sessions": \(sessionsJSON)}'
        exit 0
        """
        try? contents.write(to: script, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return dir.path
    }

    /// Prepends `dir` to a real, working `PATH` (so every other real
    /// executable this process's subprocesses need - `/bin/bash` invoked via
    /// `#!/bin/bash`, etc. - is still reachable) - `HerdrMirror.resolveHerdr()`
    /// returns the first PATH entry with an executable named `herdr`, so
    /// this reliably shadows the real one for the duration of one call.
    private static func setPath(fakeHerdrDir: String) {
        let base = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        setenv("PATH", "\(fakeHerdrDir):\(base)", 1)
    }

    private static func invocationCount(_ counterPath: String) -> Int {
        (try? String(contentsOfFile: counterPath, encoding: .utf8))?
            .split(separator: "\n").count ?? 0
    }

    // MARK: Cases

    /// Reproduces the exact pre-fix race using the real, unchanged
    /// `FirstmateBackend.resolve()` and `HerdrMirror.setUp` - the two
    /// primitives the old `mirrorTarget()`/`connectMirror` pair called
    /// independently - with the down-then-up flip forced deterministically
    /// via `setenv`, standing in for the timing gap a real reboot creates.
    private static func test_raceReproducesCaptainReportedBug() -> String? {
        try? FileManager.default.removeItem(at: scratchRoot)
        let counter = scratchRoot.appendingPathComponent("count-race.txt").path
        let downDir = writeFakeHerdr(name: "down", sessionsJSON: "[]", counterPath: counter)
        let upDir = writeFakeHerdr(name: "up", sessionsJSON: #"[{"name": "default", "running": true}]"#, counterPath: counter)
        unsetenv("FM_BACKEND")

        // Call 1 (old `mirrorTarget()`'s own moment, at tab-creation time):
        // herdr not up yet.
        setPath(fakeHerdrDir: downDir)
        let kind1 = FirstmateBackend.resolve()
        guard kind1 == .tmux else { return "expected call 1 to resolve .tmux with no live herdr evidence, got \(kind1)" }
        // The old `mirrorTarget()`'s tmux-branch fallback, verbatim.
        let staleTarget = "firstmate"

        // herdr's server comes up in the gap between the two calls.
        setPath(fakeHerdrDir: upDir)

        // Call 2 (old `connectMirror`'s own moment, at actual-connect time):
        // herdr is now live.
        let kind2 = FirstmateBackend.resolve()
        guard kind2 == .herdr else { return "expected call 2 to resolve .herdr once live, got \(kind2)" }

        // Old `connectMirror`'s herdr branch, run with the stale target from
        // call 1 - this is the exact bug.
        switch HerdrMirror.setUp(target: staleTarget) {
        case .success:
            return "expected the mismatched-target connect to fail, but it succeeded"
        case .failure(let err):
            let expected = "Cannot mirror 'firstmate': no running herdr session named 'firstmate'"
            guard err.message.contains(expected) else {
                return "reproduced a failure, but not the captain's reported message - got: \(err.message)"
            }
            return nil // reproduced
        }
    }

    /// The fix: one call to `FirstmateBackend.resolveMirrorTarget()` makes
    /// exactly one live-evidence subprocess call, never two - counted
    /// directly via the fake script's invocation counter, not inferred from
    /// the output alone.
    private static func test_atomicResolverMakesExactlyOneCheck() -> String? {
        try? FileManager.default.removeItem(at: scratchRoot)
        let counter = scratchRoot.appendingPathComponent("count-atomic.txt").path
        let upDir = writeFakeHerdr(name: "up-atomic", sessionsJSON: #"[{"name": "default", "running": true}]"#, counterPath: counter)
        unsetenv("FM_BACKEND")
        setPath(fakeHerdrDir: upDir)

        _ = FirstmateBackend.resolveMirrorTarget()
        let count = invocationCount(counter)
        guard count == 1 else {
            return "expected exactly 1 live-evidence subprocess call per resolveMirrorTarget(), got \(count)"
        }
        return nil
    }

    /// Given the SAME live evidence (herdr genuinely up) that
    /// `test_raceReproducesCaptainReportedBug` used to derive a mismatched
    /// pair, the atomic resolver's kind and target always agree, so the
    /// connection succeeds instead of failing with the captain's error.
    private static func test_atomicResolverConnectsCleanlyOnceHerdrIsLive() -> String? {
        try? FileManager.default.removeItem(at: scratchRoot)
        let counter = scratchRoot.appendingPathComponent("count-connect.txt").path
        let upDir = writeFakeHerdr(name: "up-connect", sessionsJSON: #"[{"name": "default", "running": true}]"#, counterPath: counter)
        unsetenv("FM_BACKEND")
        setPath(fakeHerdrDir: upDir)

        let resolution = FirstmateBackend.resolveMirrorTarget()
        guard resolution.kind == .herdr else { return "expected .herdr, got \(resolution.kind)" }
        switch HerdrMirror.setUp(target: resolution.target) {
        case .success:
            return nil
        case .failure(let err):
            return "expected the atomically-resolved kind+target to connect cleanly, got: \(err.message)"
        }
    }

    /// Drives the real `ConsoleController.openFirstmateHost()` end to end
    /// (not a reimplementation) against the same forced-live-herdr fixture,
    /// and confirms the tab's frozen `TabLaunch.mirror` kind/target agree
    /// with each other and produced a clean connect (no `[herdr]`/`[mirror]`
    /// failure text in the terminal).
    private static func test_consoleControllerFreezesConsistentKindAndTarget() -> String? {
        try? FileManager.default.removeItem(at: scratchRoot)
        let counter = scratchRoot.appendingPathComponent("count-console.txt").path
        let upDir = writeFakeHerdr(name: "up-console", sessionsJSON: #"[{"name": "default", "running": true}]"#, counterPath: counter)
        unsetenv("FM_BACKEND")
        setPath(fakeHerdrDir: upDir)

        let controller = ConsoleController(keyStore: SSHKeyStore(), snippetStore: SnippetStore(), isFirstmateConsole: false)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = controller
        controller.view.layoutSubtreeIfNeeded()
        _ = controller.openFirstmateHost(focus: false)
        controller.viewDidAppear()
        controller.view.layoutSubtreeIfNeeded()

        // The Mirror/Herdr tab is created first (`openFirstmateHost`'s own
        // ordering) - select it explicitly rather than assuming which tab is
        // currently active.
        guard let mirrorTab = controller.debugAllTabIDs().first else { return "no tabs created" }
        controller.debugSelectTab(mirrorTab)

        // GL-12: resolution moved off the launch path, so the pair is frozen a
        // moment later than it used to be - on the main queue, once the three
        // subprocess calls answer. The invariant this suite exists to protect is
        // unchanged (one call, both values, frozen before the tab's process ever
        // starts); only the timing moved. Pump the main run loop until it lands.
        let deadline = Date().addingTimeInterval(20)
        while controller.debugIsAwaitingMirrorResolution(mirrorTab), Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        if controller.debugIsAwaitingMirrorResolution(mirrorTab) {
            return "the mirror tab never finished resolving its backend"
        }

        guard let launch = controller.debugMirrorLaunch() else { return "current tab is not a .mirror launch" }
        guard launch.kind == .herdr else { return "expected the frozen kind to be .herdr, got \(launch.kind)" }
        guard launch.target == "default" else { return "expected the frozen target to be 'default', got \(launch.target)" }

        let output = controller.debugCurrentTerminalOutput() ?? ""
        guard !output.contains("Cannot mirror") else {
            return "tab shows a mismatched-target connect failure: \(output)"
        }
        _ = window
        return nil
    }

    /// No regression: an explicit `FM_BACKEND=tmux` override still resolves
    /// exactly as before this fix - `.tmux` with the tmux-era literal
    /// target - regardless of what herdr evidence is present.
    private static func test_noRegressionExplicitTmuxOverride() -> String? {
        // Deliberately don't touch PATH here - the override must win
        // regardless of the real, live herdr binary/session this machine
        // actually has.
        setenv("FM_BACKEND", "tmux", 1)
        let resolution = FirstmateBackend.resolveMirrorTarget()
        guard resolution.kind == .tmux else { return "explicit FM_BACKEND=tmux override was not honored: got \(resolution.kind)" }
        guard resolution.target == "firstmate" else { return "expected the tmux-era literal target, got '\(resolution.target)'" }
        return nil
    }

    /// No regression against this machine's own real, already-live herdr
    /// fleet - confirmed live before writing this test
    /// (`herdr session list --json`) to be a genuine running session named
    /// `default`. Read-only: only ever calls `session list --json` via the
    /// production code path, never starts/stops/restarts anything, per this
    /// task's hard safety gate on herdr lifecycle commands.
    private static func test_noRegressionRealLiveHerdrFleet() -> String? {
        unsetenv("FM_BACKEND")
        // Deliberately don't touch PATH - this must resolve against the
        // real herdr binary and the real, live session on this machine.
        let resolution = FirstmateBackend.resolveMirrorTarget()
        guard resolution.kind == .herdr else {
            return "expected this machine's real live herdr session to resolve .herdr, got \(resolution.kind) - is herdr's server down right now?"
        }
        switch HerdrMirror.setUp(target: resolution.target) {
        case .success:
            return nil
        case .failure(let err):
            return "expected a clean connect against the real live '\(resolution.target)' session, got: \(err.message)"
        }
    }
}
