// Manjesh Grand Line - native macOS app.
//
// Permanent integration self-test for `fm/grandline-sre-lead-per-tab`: each
// `.ssh` tab inside one dedicated host page now holds its own independent
// SRE Lead investigation (`TabModel.sreLead`), instead of every tab sharing
// one page-level session pinned to whichever tab connected first - see
// `SRELeadTabState.swift`'s header and
// `data/grandline-sre-lead-per-tab/design-reference.html` for the design.
//
// This drives the *real* `ConsoleController` - the actual `startSRELead(for:)`/
// `handleSRELeadSubmit(_:in:)`/`tearDownSRELead(for:)`/`closeTab`/`select`
// methods, not reimplementations of them - through a real multi-tab host
// page, exactly the way `BlockViewRestartIntegrationSelfTest.swift` drives
// the real restart machinery for the same reason. No live SSH bastion or
// kubectl cluster is needed: the ssh subprocess itself is allowed to fail (a
// `ConnectTimeout=1` dial to `127.0.0.1`, nothing listens there in this
// environment) since starting/using SRE Lead never depends on the tab's ssh
// connection actually succeeding, only on its `Terminal`/chat existing. The
// `claude -p` calls are real `Process` invocations against a disposable fake
// script (`SRELead.claudePathOverrideForTests`), never the real `claude` CLI
// or a real network call - same convention as `SRELeadPostmortemSelfTest.swift`/
// `DictationCleanupSelfTest.swift`.
//
// Run with:
//   swift build && FM_RUN_SRE_LEAD_PER_TAB_TESTS=1 .build/debug/FirstmateCockpit; echo $?

import AppKit

enum SRELeadPerTabSelfTest {

    static func run() -> Bool {
        let cases: [(String, () -> String?)] = [
            ("independentPhasesAndNoChatCrossTalk", test_independentPhasesAndNoChatCrossTalk),
            ("tabSwitchRebindsPaneToCurrentTab", test_tabSwitchRebindsPaneToCurrentTab),
            ("fifthTabStartsSixthIsRefused", test_fifthTabStartsSixthIsRefused),
            ("closingATabOnlyTearsDownItsOwnSession", test_closingATabOnlyTearsDownItsOwnSession),
        ]
        var failures = 0
        for (name, testCase) in cases {
            SRELead.claudePathOverrideForTests = nil
            if let failure = testCase() {
                print("FAIL \(name): \(failure)")
                failures += 1
            } else {
                print("PASS \(name)")
            }
        }
        SRELead.claudePathOverrideForTests = nil
        print(failures == 0 ? "SRELeadPerTabSelfTest: all \(cases.count) cases passed" : "SRELeadPerTabSelfTest: \(failures)/\(cases.count) cases FAILED")
        return failures == 0
    }

    // MARK: Helpers

    /// A real, non-Firstmate `ConsoleController` (a dedicated host page)
    /// mounted in a real `NSWindow`, with `tabCount` real `.ssh` tabs opened
    /// and started via the real `openSSH`/`viewDidAppear` path - mirrors
    /// `BlockViewRestartIntegrationSelfTest.makeStartedTestConsole()`.
    private static func makeStartedTestConsole(tabCount: Int) -> (window: NSWindow, controller: ConsoleController, tabIDs: [UUID]) {
        let controller = ConsoleController(keyStore: SSHKeyStore(), snippetStore: SnippetStore(), isFirstmateConsole: false)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = controller
        controller.view.layoutSubtreeIfNeeded()

        for i in 0..<tabCount {
            controller.openSSH(
                label: "Per-Tab Test Host \(i + 1)",
                args: ["-o", "ConnectTimeout=1", "-o", "BatchMode=yes", "127.0.0.1"],
                accentHex: nil, keyID: nil, startupSnippetID: nil
            )
        }
        controller.viewDidAppear()
        controller.view.layoutSubtreeIfNeeded()
        return (window, controller, controller.debugAllTabIDs())
    }

    /// A fake `claude -p ... --output-format json` stand-in: echoes the
    /// question it was asked (`-p <question>` is always argv[1]/argv[2])
    /// back inside `result`, so two tabs asking different questions produce
    /// distinguishable replies without needing a real model or cluster.
    private static func writeFakeClaude() -> URL {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("fake-claude-per-tab-\(UUID().uuidString).sh")
        let script = """
        #!/bin/sh
        printf '{"result": "reply-to: %s", "is_error": false, "session_id": "fake-session-%s"}' "$2" "$2"
        """
        try? script.write(to: path, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path.path)
        return path
    }

    /// Pumps the main run loop (this self-test runs before `NSApplication.run()`
    /// starts, so a semaphore wait would deadlock against the very
    /// `DispatchQueue.main.async` callback being waited on - same rationale
    /// as `SRELeadPostmortemSelfTest.runGenerateSync`) until `condition` is
    /// true or `timeout` elapses.
    @discardableResult
    private static func waitUntil(timeout: TimeInterval = 10, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        return condition()
    }

    // MARK: Cases

    private static func test_independentPhasesAndNoChatCrossTalk() -> String? {
        let script = writeFakeClaude()
        defer { try? FileManager.default.removeItem(at: script) }
        SRELead.claudePathOverrideForTests = script.path

        let (window, controller, ids) = makeStartedTestConsole(tabCount: 2)
        _ = window
        guard ids.count == 2 else { return "expected 2 tabs, got \(ids.count)" }
        let (tabA, tabB) = (ids[0], ids[1])

        controller.debugStartSRELead(forTabID: tabA)
        controller.debugStartSRELead(forTabID: tabB)
        guard waitUntil({ controller.debugSRELeadPhase(forTabID: tabA) == .ready && controller.debugSRELeadPhase(forTabID: tabB) == .ready }) else {
            return "expected both tabs to reach .ready independently, got A=\(String(describing: controller.debugSRELeadPhase(forTabID: tabA))) B=\(String(describing: controller.debugSRELeadPhase(forTabID: tabB)))"
        }

        controller.debugAskSRELead(forTabID: tabA, question: "QUESTIONFROMTABA")
        controller.debugAskSRELead(forTabID: tabB, question: "QUESTIONFROMTABB")

        guard waitUntil({
            (controller.debugSRELeadChatTexts(forTabID: tabA) ?? []).contains(where: { $0.contains("QUESTIONFROMTABA") && $0.contains("reply-to") }) &&
            (controller.debugSRELeadChatTexts(forTabID: tabB) ?? []).contains(where: { $0.contains("QUESTIONFROMTABB") && $0.contains("reply-to") })
        }) else {
            return "both tabs' own replies never arrived: A=\(controller.debugSRELeadChatTexts(forTabID: tabA) ?? []) B=\(controller.debugSRELeadChatTexts(forTabID: tabB) ?? [])"
        }

        let textsA = controller.debugSRELeadChatTexts(forTabID: tabA) ?? []
        let textsB = controller.debugSRELeadChatTexts(forTabID: tabB) ?? []
        guard !textsA.contains(where: { $0.contains("QUESTIONFROMTABB") }) else { return "tab A's chat leaked tab B's question/answer: \(textsA)" }
        guard !textsB.contains(where: { $0.contains("QUESTIONFROMTABA") }) else { return "tab B's chat leaked tab A's question/answer: \(textsB)" }
        return nil
    }

    private static func test_tabSwitchRebindsPaneToCurrentTab() -> String? {
        let script = writeFakeClaude()
        defer { try? FileManager.default.removeItem(at: script) }
        SRELead.claudePathOverrideForTests = script.path

        let (window, controller, ids) = makeStartedTestConsole(tabCount: 2)
        _ = window
        let (tabA, tabB) = (ids[0], ids[1])

        controller.debugStartSRELead(forTabID: tabA)
        guard waitUntil({ controller.debugSRELeadPhase(forTabID: tabA) == .ready }) else {
            return "tab A never reached .ready"
        }
        // Tab A is current (the last-opened/selected tab is B, so select A
        // explicitly first to establish the known "started tab is current" state).
        controller.debugSelectTab(tabA)
        guard controller.debugSRELeadShowingEmptyState() == false else { return "tab A (started) incorrectly showed the empty state" }
        guard controller.debugSRELeadPaneOpen() else { return "tab A has an active session - the pane must be open, not closed" }
        guard (controller.debugSRELeadChatTexts(forTabID: tabA) ?? []).contains(where: { $0.contains("SRE Lead is ready") }) else {
            return "tab A's own transcript should already contain the ready status message"
        }

        // Bug 1 (`fm/grandline-sre-lead-polish`): switching to a tab with no
        // `sreLead` state at all must show the pane fully CLOSED - not just
        // the empty state rendered inside a still-open pane. Asserting on
        // the width constraint directly (not just the empty-state flag) is
        // what actually catches the regression this fix targets.
        controller.debugSelectTab(tabB)
        guard controller.debugSRELeadShowingEmptyState() == true else { return "tab B (never started) should show the empty state, not tab A's chat or a blank pane" }
        guard controller.debugSRELeadPhase(forTabID: tabB) == nil else { return "tab B should have no SRE Lead state at all" }
        guard !controller.debugSRELeadPaneOpen() else { return "tab B has no SRE Lead state - the pane must be fully closed, not open showing the empty state" }

        controller.debugSelectTab(tabA)
        guard controller.debugSRELeadShowingEmptyState() == false else { return "switching back to tab A should show its chat again, not the empty state" }
        guard controller.debugSRELeadPaneOpen() else { return "switching back to tab A should reopen the pane" }
        guard (controller.debugSRELeadChatTexts(forTabID: tabA) ?? []).contains(where: { $0.contains("SRE Lead is ready") }) else {
            return "tab A's prior transcript should still be intact after switching away and back"
        }
        return nil
    }

    private static func test_fifthTabStartsSixthIsRefused() -> String? {
        let script = writeFakeClaude()
        defer { try? FileManager.default.removeItem(at: script) }
        SRELead.claudePathOverrideForTests = script.path

        let (window, controller, ids) = makeStartedTestConsole(tabCount: 6)
        _ = window
        guard ids.count == 6 else { return "expected 6 tabs, got \(ids.count)" }

        for id in ids.prefix(5) {
            controller.debugStartSRELead(forTabID: id)
        }
        guard controller.debugActiveSRELeadCount() == 5 else {
            return "expected exactly 5 active SRE Lead tabs after starting the first 5, got \(controller.debugActiveSRELeadCount())"
        }

        // Attempting a 6th must not crash (this test completing at all is
        // part of that proof) and must not silently start either.
        let sixth = ids[5]
        controller.debugStartSRELead(forTabID: sixth)
        guard controller.debugActiveSRELeadCount() == 5 else {
            return "a 6th tab should be refused, not silently started - active count is now \(controller.debugActiveSRELeadCount())"
        }
        guard controller.debugSRELeadPhase(forTabID: sixth) == nil else {
            return "the refused 6th tab should have no SRE Lead state at all, got \(String(describing: controller.debugSRELeadPhase(forTabID: sixth)))"
        }
        return nil
    }

    private static func test_closingATabOnlyTearsDownItsOwnSession() -> String? {
        let script = writeFakeClaude()
        defer { try? FileManager.default.removeItem(at: script) }
        SRELead.claudePathOverrideForTests = script.path

        let (window, controller, ids) = makeStartedTestConsole(tabCount: 2)
        _ = window
        let (tabA, tabB) = (ids[0], ids[1])

        controller.debugStartSRELead(forTabID: tabA)
        controller.debugStartSRELead(forTabID: tabB)
        guard waitUntil({ controller.debugSRELeadPhase(forTabID: tabA) == .ready && controller.debugSRELeadPhase(forTabID: tabB) == .ready }) else {
            return "both tabs should reach .ready before this test closes one of them"
        }
        guard controller.debugSRELeadPaneOpen() else { return "pane should be open with two active sessions" }

        controller.debugCloseTab(id: tabA)

        guard controller.debugSRELeadPhase(forTabID: tabA) == nil else {
            return "tab A no longer exists after being closed, so it should report no SRE Lead state"
        }
        guard controller.debugSRELeadPhase(forTabID: tabB) == .ready else {
            return "closing tab A must not disturb tab B's own still-running session, got \(String(describing: controller.debugSRELeadPhase(forTabID: tabB)))"
        }
        guard (controller.debugSRELeadChatTexts(forTabID: tabB) ?? []).contains(where: { $0.contains("SRE Lead is ready") }) else {
            return "tab B's own chat/transcript should be completely unaffected by tab A's close"
        }
        guard controller.debugSRELeadPaneOpen() else {
            return "the pane should stay open - tab B still has an active session"
        }
        return nil
    }
}
