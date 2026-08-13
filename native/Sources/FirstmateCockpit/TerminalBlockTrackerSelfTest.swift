// Manjesh Grand Line - native macOS app.
//
// `fm/cockpit-block-view-stage0`: env-var-gated self-test, same convention as
// `SRELeadBridgeSelfTest.swift`/`SRELeadMarkdownSelfTest.swift` (see either
// file's header for why this project has no real `swift test` target). Run
// with:
//
//   swift build && FM_RUN_BLOCK_VIEW_TESTS=1 .build/debug/FirstmateCockpit; echo $?
//
// Uses SwiftTerm's own `HeadlessTerminal` (a real `Terminal` with no AppKit
// view attached) fed literal byte sequences shaped exactly like what a real
// PTY delivers when the `ShellIntegration.installCommand` hook is active.
// This file verifies only the *parsing* side, in-process, with no AppKit
// view involved at all.
//
// **This is deliberately not the whole story.** The original PR #79/#80
// shipped and passed self-tests that all looked like this file, and still
// crashed the app on every single launch, because the actual crash was in
// `BlockContainerView.render(_:)`'s Auto Layout constraint ordering - a bug
// this file's `HeadlessTerminal`-only tests structurally cannot see, since
// they never construct an `NSView`. `BlockViewHierarchySelfTest.swift` closes
// that gap; `BlockViewRestartIntegrationSelfTest.swift` closes the separate
// reconnect-bookkeeping gap neither of those two catches. Do not treat this
// file's passing as evidence the view-rendering or reconnect path is
// correct.
import Foundation
import SwiftTerm

enum TerminalBlockTrackerSelfTest {

    static func run() -> Bool {
        let cases: [(String, () -> String?)] = [
            ("parsesSimpleSuccessfulCommand", test_parsesSimpleSuccessfulCommand),
            ("tracksNonZeroExitCode", test_tracksNonZeroExitCode),
            ("resetClearsBlocksAndOpenState", test_resetClearsBlocksAndOpenState),
            ("aDCloseWithNothingOpenIsIgnored", test_closeWithNothingOpenIsIgnored),
            ("trimsOldestBlocksBeyondTheCap", test_trimsOldestBlocksBeyondCap),
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
        print(failures == 0 ? "TerminalBlockTrackerSelfTest: all \(cases.count) cases passed" : "TerminalBlockTrackerSelfTest: \(failures)/\(cases.count) cases FAILED")
        return failures == 0
    }

    // MARK: Helpers

    private static func makeTerminal() -> Terminal {
        let headless = HeadlessTerminal(options: .default) { _ in }
        return headless.terminal
    }

    private static func b64(_ s: String) -> String {
        Data(s.utf8).base64EncodedString()
    }

    /// Builds the raw byte stream a real PTY would deliver for one prompt
    /// cycle: the `B` marker, the terminal's own echo of the typed command,
    /// a newline, the command's output, then the `D` marker closing it.
    private static func promptCycle(command: String, output: String, exitCode: Int32) -> String {
        "\u{1b}]133;B\u{07}" + command + "\r\n" + output + "\r\n" + "\u{1b}]133;D;\(exitCode);\(b64(command))\u{07}"
    }

    private static func feed(_ terminal: Terminal, _ text: String) {
        terminal.feed(byteArray: [UInt8](text.utf8))
    }

    // MARK: Cases

    private static func test_parsesSimpleSuccessfulCommand() -> String? {
        let terminal = makeTerminal()
        let tracker = TerminalBlockTracker()
        tracker.attach(to: terminal)

        feed(terminal, promptCycle(command: "echo hello world", output: "hello world", exitCode: 0))

        guard tracker.blocks.count == 1 else { return "expected 1 block, got \(tracker.blocks.count)" }
        let block = tracker.blocks[0]
        guard block.commandText == "echo hello world" else { return "unexpected command text: \(block.commandText)" }
        guard block.outputText.contains("hello world") else { return "unexpected output text: \(block.outputText)" }
        guard block.status == .finished(exitCode: 0) else { return "unexpected status: \(block.status)" }
        return nil
    }

    private static func test_tracksNonZeroExitCode() -> String? {
        let terminal = makeTerminal()
        let tracker = TerminalBlockTracker()
        tracker.attach(to: terminal)

        feed(terminal, promptCycle(command: "false", output: "", exitCode: 1))

        guard let block = tracker.blocks.first else { return "no block recorded" }
        guard block.status == .finished(exitCode: 1) else { return "expected exit code 1, got \(block.status)" }
        guard block.commandText == "false" else { return "unexpected command text: \(block.commandText)" }
        return nil
    }

    private static func test_resetClearsBlocksAndOpenState() -> String? {
        let terminal = makeTerminal()
        let tracker = TerminalBlockTracker()
        tracker.attach(to: terminal)

        feed(terminal, promptCycle(command: "echo one", output: "one", exitCode: 0))
        // An open block with no closing `D` - the "stuck running" shape a
        // dropped connection leaves behind (see the restart-integration
        // self-test for the full reconnect-bookkeeping story).
        feed(terminal, "\u{1b}]133;B\u{07}" + "sleep 5" + "\r\n")
        guard tracker.blocks.count == 2, tracker.blocks[1].status == .running else {
            return "expected a finished block plus a running one before reset, got \(tracker.blocks)"
        }

        tracker.reset()
        guard tracker.blocks.isEmpty else { return "reset() did not clear blocks: \(tracker.blocks)" }

        // A fresh `D` after reset must be ignored (nothing open), not
        // misattributed to whatever was open before reset.
        feed(terminal, "\u{1b}]133;D;0;\(b64("stale"))\u{07}")
        guard tracker.blocks.isEmpty else { return "a D marker after reset() was incorrectly applied: \(tracker.blocks)" }
        return nil
    }

    private static func test_closeWithNothingOpenIsIgnored() -> String? {
        let terminal = makeTerminal()
        let tracker = TerminalBlockTracker()
        tracker.attach(to: terminal)

        // A `D` with no preceding `B` - e.g. the very first prompt cycle
        // after the hook installs.
        feed(terminal, "\u{1b}]133;D;0;\(b64("echo x"))\u{07}")
        guard tracker.blocks.isEmpty else { return "a D with nothing open should be a no-op: \(tracker.blocks)" }
        return nil
    }

    private static func test_trimsOldestBlocksBeyondCap() -> String? {
        let terminal = makeTerminal()
        let tracker = TerminalBlockTracker()
        tracker.attach(to: terminal)

        for i in 0..<520 {
            feed(terminal, promptCycle(command: "echo \(i)", output: "\(i)", exitCode: 0))
        }
        guard tracker.blocks.count == 500 else { return "expected the 500-block cap to trim older blocks, got \(tracker.blocks.count)" }
        guard tracker.blocks.last?.commandText == "echo 519" else {
            return "expected the newest block to survive trimming, last is \(tracker.blocks.last?.commandText ?? "nil")"
        }
        guard tracker.blocks.first?.commandText == "echo 20" else {
            return "expected the oldest 20 blocks to be trimmed, first surviving is \(tracker.blocks.first?.commandText ?? "nil")"
        }
        return nil
    }
}
