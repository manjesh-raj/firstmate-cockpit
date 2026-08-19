// Manjesh Grand Line - native macOS app.
//
// Permanent integration self-test for the trickiest of the nine
// Notification Center signals (`fm/grandline-notification-center`, #7): "SRE
// Lead answered a question on a tab you're not looking at." Drives the
// *real* `ConsoleController.onSRELeadReplyWhileBackground`/`select`/
// `closeTab` machinery through its debug hooks (`debugStartSRELead`/
// `debugAskSRELead`/`debugSelectTab`/`debugCloseTab`), not a
// reimplementation - same shape and same fake-`claude` harness as
// `SRELeadPerTabSelfTest.swift`, which this test's own setup helper mirrors
// (duplicated rather than shared, since that file's helpers are private).
//
// Run with:
//   swift build && FM_RUN_NOTIFICATION_CENTER_SRE_LEAD_TESTS=1 .build/debug/FirstmateCockpit; echo $?

import AppKit

enum NotificationCenterSRELeadSelfTest {

    static func run() -> Bool {
        let cases: [(String, () -> String?)] = [
            ("replyOnBackgroundTabFiresNotification", test_replyOnBackgroundTabFiresNotification),
            ("replyOnCurrentTabFiresNoNotification", test_replyOnCurrentTabFiresNoNotification),
            ("selectingTheTabClearsTheNotification", test_selectingTheTabClearsTheNotification),
            ("closingTheTabClearsTheNotification", test_closingTheTabClearsTheNotification),
        ]
        var failures = 0
        for (name, testCase) in cases {
            SRELead.claudePathOverrideForTests = nil
            GrandLineNotificationCenter.shared.resetForTesting()
            if let failure = testCase() {
                print("FAIL \(name): \(failure)")
                failures += 1
            } else {
                print("PASS \(name)")
            }
        }
        SRELead.claudePathOverrideForTests = nil
        GrandLineNotificationCenter.shared.resetForTesting()
        print(failures == 0 ? "NotificationCenterSRELeadSelfTest: all \(cases.count) cases passed" : "NotificationCenterSRELeadSelfTest: \(failures)/\(cases.count) cases FAILED")
        return failures == 0
    }

    // MARK: Helpers (mirrors SRELeadPerTabSelfTest.swift's own private helpers)

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
                label: "Notification Test Host \(i + 1)",
                args: ["-o", "ConnectTimeout=1", "-o", "BatchMode=yes", "127.0.0.1"],
                accentHex: nil, keyID: nil, startupSnippetID: nil
            )
        }
        controller.viewDidAppear()
        controller.view.layoutSubtreeIfNeeded()
        return (window, controller, controller.debugAllTabIDs())
    }

    private static func writeFakeClaude() -> URL {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("fake-claude-notification-center-\(UUID().uuidString).sh")
        let script = """
        #!/bin/sh
        printf '{"result": "reply-to: %s", "is_error": false, "session_id": "fake-session-%s"}' "$2" "$2"
        """
        try? script.write(to: path, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path.path)
        return path
    }

    @discardableResult
    private static func waitUntil(timeout: TimeInterval = 10, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        return condition()
    }

    /// Wires the controller's own reporting callback into
    /// `NotificationSources`/`GrandLineNotificationCenter`, exactly the way
    /// `AppShellController.connectHost` does in production - this test does
    /// not reimplement the wiring, it exercises the same call.
    private static func wireNotificationCenter(_ controller: ConsoleController, hostLabel: String) {
        controller.onSRELeadReplyWhileBackground = { [weak controller] tab in
            guard let controller else { return }
            NotificationSources.setSRELeadReply(tabID: tab.id, tabName: tab.name, hostLabel: hostLabel) {
                controller.selectAndFocusTab(id: tab.id)
            }
        }
    }

    // MARK: Cases

    private static func test_replyOnBackgroundTabFiresNotification() -> String? {
        let script = writeFakeClaude()
        defer { try? FileManager.default.removeItem(at: script) }
        SRELead.claudePathOverrideForTests = script.path

        let (window, controller, ids) = makeStartedTestConsole(tabCount: 2)
        _ = window
        wireNotificationCenter(controller, hostLabel: "Test Host")
        guard ids.count == 2 else { return "expected 2 tabs, got \(ids.count)" }
        let (tabA, tabB) = (ids[0], ids[1])

        controller.debugStartSRELead(forTabID: tabA)
        controller.debugStartSRELead(forTabID: tabB)
        guard waitUntil({
            controller.debugSRELeadPhase(forTabID: tabA) == .ready && controller.debugSRELeadPhase(forTabID: tabB) == .ready
        }) else { return "SRE Lead never reached .ready on both tabs" }

        // The captain is looking at tab A; a reply lands on tab B instead.
        controller.debugSelectTab(tabA)
        controller.debugAskSRELead(forTabID: tabB, question: "what happened")
        guard waitUntil({
            GrandLineNotificationCenter.shared.entries.contains { $0.id == NotificationSources.sreLeadReplyID(tabID: tabB) }
        }) else { return "no notification appeared for the background tab's reply" }

        let entry = GrandLineNotificationCenter.shared.entries.first { $0.id == NotificationSources.sreLeadReplyID(tabID: tabB) }
        guard entry?.kind == .actionNeeded else { return "SRE Lead reply notification should be .actionNeeded" }
        guard entry?.subtext.contains("Test Host") == true else { return "subtext should name the host" }
        return nil
    }

    private static func test_replyOnCurrentTabFiresNoNotification() -> String? {
        let script = writeFakeClaude()
        defer { try? FileManager.default.removeItem(at: script) }
        SRELead.claudePathOverrideForTests = script.path

        let (window, controller, ids) = makeStartedTestConsole(tabCount: 1)
        _ = window
        wireNotificationCenter(controller, hostLabel: "Test Host")
        guard let tabA = ids.first else { return "expected at least 1 tab" }

        controller.debugStartSRELead(forTabID: tabA)
        guard waitUntil({ controller.debugSRELeadPhase(forTabID: tabA) == .ready }) else {
            return "SRE Lead never reached .ready"
        }
        controller.debugSelectTab(tabA)
        controller.debugAskSRELead(forTabID: tabA, question: "status check")
        guard waitUntil({ (controller.debugSRELeadChatTexts(forTabID: tabA)?.count ?? 0) >= 2 }) else {
            return "reply never landed in the chat"
        }
        // Give any (incorrect) notification a moment to appear before asserting its absence.
        _ = waitUntil(timeout: 0.3) { false }
        guard !GrandLineNotificationCenter.shared.entries.contains(where: { $0.id == NotificationSources.sreLeadReplyID(tabID: tabA) }) else {
            return "a reply on the currently-visible tab must not create a notification"
        }
        return nil
    }

    private static func test_selectingTheTabClearsTheNotification() -> String? {
        let script = writeFakeClaude()
        defer { try? FileManager.default.removeItem(at: script) }
        SRELead.claudePathOverrideForTests = script.path

        let (window, controller, ids) = makeStartedTestConsole(tabCount: 2)
        _ = window
        wireNotificationCenter(controller, hostLabel: "Test Host")
        guard ids.count == 2 else { return "expected 2 tabs" }
        let (tabA, tabB) = (ids[0], ids[1])

        controller.debugStartSRELead(forTabID: tabA)
        controller.debugStartSRELead(forTabID: tabB)
        guard waitUntil({
            controller.debugSRELeadPhase(forTabID: tabA) == .ready && controller.debugSRELeadPhase(forTabID: tabB) == .ready
        }) else { return "SRE Lead never reached .ready on both tabs" }

        controller.debugSelectTab(tabA)
        controller.debugAskSRELead(forTabID: tabB, question: "background question")
        guard waitUntil({
            GrandLineNotificationCenter.shared.entries.contains { $0.id == NotificationSources.sreLeadReplyID(tabID: tabB) }
        }) else { return "notification never appeared" }

        // Simulates clicking the notification: select+focus the tab it points at.
        controller.selectAndFocusTab(id: tabB)
        guard !GrandLineNotificationCenter.shared.entries.contains(where: { $0.id == NotificationSources.sreLeadReplyID(tabID: tabB) }) else {
            return "selecting the tab should clear its own notification"
        }
        return nil
    }

    private static func test_closingTheTabClearsTheNotification() -> String? {
        let script = writeFakeClaude()
        defer { try? FileManager.default.removeItem(at: script) }
        SRELead.claudePathOverrideForTests = script.path

        let (window, controller, ids) = makeStartedTestConsole(tabCount: 2)
        _ = window
        wireNotificationCenter(controller, hostLabel: "Test Host")
        guard ids.count == 2 else { return "expected 2 tabs" }
        let (tabA, tabB) = (ids[0], ids[1])

        controller.debugStartSRELead(forTabID: tabA)
        controller.debugStartSRELead(forTabID: tabB)
        guard waitUntil({
            controller.debugSRELeadPhase(forTabID: tabA) == .ready && controller.debugSRELeadPhase(forTabID: tabB) == .ready
        }) else { return "SRE Lead never reached .ready on both tabs" }

        controller.debugSelectTab(tabA)
        controller.debugAskSRELead(forTabID: tabB, question: "background question")
        guard waitUntil({
            GrandLineNotificationCenter.shared.entries.contains { $0.id == NotificationSources.sreLeadReplyID(tabID: tabB) }
        }) else { return "notification never appeared" }

        controller.debugCloseTab(id: tabB)
        guard !GrandLineNotificationCenter.shared.entries.contains(where: { $0.id == NotificationSources.sreLeadReplyID(tabID: tabB) }) else {
            return "closing the tab should clear its own dangling notification"
        }
        return nil
    }
}
