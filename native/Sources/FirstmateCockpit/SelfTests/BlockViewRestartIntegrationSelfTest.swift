// Manjesh Grand Line - native macOS app.
//
// `fm/cockpit-block-view-stage0`: the integration test the scout report
// (`data/cockpit-block-view-scout/report.md`, "Mechanism A") says would have
// caught the second production break mechanically, without needing a live
// bastion. Neither prior self-test could have: `TerminalBlockTrackerSelfTest`
// only exercises OSC 133 parsing against a bare `HeadlessTerminal`, and
// `BlockViewHierarchySelfTest` only drives `BlockContainerView` in isolation
// with hand-built `TerminalBlock` structs - neither ever goes through
// `ConsoleController`'s real `addTab`/`startTab`/`reconnectActive` wiring,
// which is exactly where the original bug lived: `reconnectActive` (⌘R)
// explicitly reset the block tracker after restarting a process, but the
// automatic-reconnect timer (`processTerminated`, on a real network drop)
// called `startTab` directly, and `startTab` never reset anything - so an
// auto-reconnected SSH session kept a stuck "running" block from the dead
// session, with the new session's output silently bleeding into it.
//
// This test drives the *real* `ConsoleController` - the actual
// `openSSH`/`viewDidAppear`/`startTab`/`reconnectActive` methods, not
// reimplementations of them - through both restart-shaped code paths (see
// `ConsoleController`'s "Test support" section, added for exactly this) and
// asserts the tracker ends up in the same clean state after either one:
// zero blocks, none `.running`. No live network or real bastion is needed -
// the ssh subprocess itself is allowed to fail (a `ConnectTimeout=1` dial to
// `127.0.0.1`, which nothing listens on here); what's under test is the
// *bookkeeping* around a restart, not whether the connection succeeds. A
// synthetic OSC 133 `B` marker (no matching `D`) is fed straight into the
// tab's real `Terminal` to put a block into the exact "stuck running" state
// a dropped mid-command connection would leave behind.
//
// **This test was verified to actually catch the original bug, not just to
// pass**: temporarily removing the `restartTabBookkeeping(tab)` call from
// `ConsoleController.startTab` (reintroducing Mechanism A for the auto-
// reconnect-shaped path only, since `reconnectActive` still calls it
// directly) made `test_autoReconnectShapedRestartClearsStuckBlock` fail with
// a stuck running block while `test_manualReconnectShapedRestartClearsStuckBlock`
// kept passing - exactly the asymmetry the scout report describes. Restoring
// the call made both pass again. See this task's PR description for the
// exact before/after output; that experiment is not re-run automatically
// here (it requires editing production code), so this comment is the
// permanent record of it having been done.
//
// Run with:
//   swift build && FM_RUN_BLOCK_VIEW_RESTART_TESTS=1 .build/debug/FirstmateCockpit; echo $?

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

import AppKit
import SwiftTerm

enum BlockViewRestartIntegrationSelfTest {

    static func run() -> Bool {
        // Stage 0 is off by default (`BlockViewFeature.isEnabled`) - this
        // test exercises the on state deliberately, exactly the way a
        // captain running with `FM_BLOCK_VIEW_ENABLED=1` would, not by
        // reaching around the flag.
        setenv("FM_BLOCK_VIEW_ENABLED", "1", 1)
        defer { unsetenv("FM_BLOCK_VIEW_ENABLED") }

        let cases: [(String, () -> String?)] = [
            ("autoReconnectShapedRestartClearsStuckBlock", test_autoReconnectShapedRestart),
            ("manualReconnectShapedRestartClearsStuckBlock", test_manualReconnectShapedRestart),
            ("bothRestartShapesEndInIdenticalCleanState", test_bothShapesAgree),
        ]
        var failures = 0
        for (name, testCase) in cases {
            if let failure = testCase() {
                print("FAIL \(name): \(failure)")
                failures += 1
            } else {
                print("PASS \(name)")
            }
        }
        print(failures == 0 ? "BlockViewRestartIntegrationSelfTest: all \(cases.count) cases passed" : "BlockViewRestartIntegrationSelfTest: \(failures)/\(cases.count) cases FAILED")
        return failures == 0
    }

    // MARK: Helpers

    /// A real, non-Firstmate `ConsoleController` (a dedicated host page,
    /// matching what `AppShellController.connectHost` builds) mounted in a
    /// real `NSWindow`, with one real `.ssh` tab opened and started via the
    /// real `openSSH`/`viewDidAppear` path - exactly production's own
    /// sequence for a freshly-connected, opted-in host.
    private static func makeStartedTestConsole() -> (window: NSWindow, controller: ConsoleController) {
        let controller = ConsoleController(keyStore: SSHKeyStore(), snippetStore: SnippetStore(), isFirstmateConsole: false)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = controller
        controller.view.layoutSubtreeIfNeeded()

        controller.debugOpenTestSSHTab(label: "Restart Test Host")
        // Mirrors real app launch: the tab is created before the view has
        // ever appeared (`hasAppeared` is false), so `addTab` defers the
        // actual process start to `viewDidAppear` - the real initial-start
        // path, not a direct `startTab` call from this test.
        controller.viewDidAppear()
        controller.view.layoutSubtreeIfNeeded()
        return (window, controller)
    }

    /// Puts the current tab's tracker into the exact "stuck running block"
    /// state a dropped mid-command connection leaves behind: a `B` marker
    /// with no matching `D`.
    private static func openAStuckRunningBlock(on controller: ConsoleController) -> String? {
        guard let terminal = controller.debugCurrentTerminal() else { return "no real Terminal behind the test tab" }
        terminal.feed(byteArray: [UInt8]("\u{1b}]133;B\u{07}find / -name '*.log'\r\npartial output line 1\r\n".utf8))
        guard let state = controller.debugBlockState() else { return "no block tracker attached to the test tab" }
        guard state.count == 1, state.hasRunning else {
            return "expected a single stuck running block before restart, got \(state)"
        }
        return nil
    }

    // MARK: Cases

    private static func test_autoReconnectShapedRestart() -> String? {
        let (window, controller) = makeStartedTestConsole()
        if let failure = openAStuckRunningBlock(on: controller) { return failure }

        // The exact shape `processTerminated`'s `AppSettings.shared.
        // autoReconnect` timer drives on a real network drop: it calls
        // `startTab` directly on the same `TabModel`, never `reconnectActive`.
        controller.debugSimulateAutoReconnectRestart()

        guard let state = controller.debugBlockState() else { return "block tracker disappeared after restart" }
        guard state.count == 0, !state.hasRunning else {
            return "auto-reconnect-shaped restart left stale block state: \(state) - this is exactly Mechanism A from the scout report"
        }
        _ = window
        return nil
    }

    private static func test_manualReconnectShapedRestart() -> String? {
        let (window, controller) = makeStartedTestConsole()
        if let failure = openAStuckRunningBlock(on: controller) { return failure }

        // The exact shape ⌘R drives.
        controller.debugSimulateManualReconnectRestart()

        guard let state = controller.debugBlockState() else { return "block tracker disappeared after restart" }
        guard state.count == 0, !state.hasRunning else {
            return "manual-reconnect-shaped restart left stale block state: \(state)"
        }
        _ = window
        return nil
    }

    /// The direct assertion the scout report's Mechanism A gap violates:
    /// both restart shapes must leave the tracker in *identical* state, not
    /// just each individually "clean enough."
    private static func test_bothShapesAgree() -> String? {
        let (autoWindow, autoController) = makeStartedTestConsole()
        if let failure = openAStuckRunningBlock(on: autoController) { return failure }
        autoController.debugSimulateAutoReconnectRestart()
        guard let autoState = autoController.debugBlockState() else { return "auto path: tracker disappeared" }

        let (manualWindow, manualController) = makeStartedTestConsole()
        if let failure = openAStuckRunningBlock(on: manualController) { return failure }
        manualController.debugSimulateManualReconnectRestart()
        guard let manualState = manualController.debugBlockState() else { return "manual path: tracker disappeared" }

        guard autoState.count == manualState.count, autoState.hasRunning == manualState.hasRunning else {
            return "the two restart paths disagree: auto=\(autoState), manual=\(manualState)"
        }
        _ = (autoWindow, manualWindow)
        return nil
    }
}

#endif
