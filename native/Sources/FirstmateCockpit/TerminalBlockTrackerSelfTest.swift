// Manjesh Grand Line - native macOS app.
//
// `fm/cockpit-block-view-ssh-only`: env-var-gated self-test, same convention
// as `SRELeadBridgeSelfTest.swift`/`SRELeadMarkdownSelfTest.swift` (see
// either file's header for why this project has no real `swift test`
// target). Run with:
//
//   swift build && FM_RUN_BLOCK_VIEW_TESTS=1 .build/debug/FirstmateCockpit; echo $?
//
// Uses SwiftTerm's own `HeadlessTerminal` (a real `Terminal` with no AppKit
// view attached) fed literal byte sequences shaped exactly like what a real
// PTY delivers when the `ShellIntegration.installCommand` hook is active -
// these byte sequences were captured and validated against real `/bin/bash`
// and `/bin/zsh` processes under a real PTY (`pty.openpty()` via Python,
// not simulated) before this file was written; see PR #79's description for
// those transcripts. This file verifies only the *parsing* side, in-process,
// with no AppKit view involved at all.
//
// **This is deliberately not the whole story.** The original PR #79/#80
// shipped and passed "5/5" tests that all looked like this file, and still
// crashed the app on every single launch, because the actual crash was in
// `BlockContainerView.render(_:)`'s Auto Layout constraint ordering - a bug
// this file's `HeadlessTerminal`-only tests structurally cannot see, since
// they never construct an `NSView`. `BlockViewHierarchySelfTest.swift` is
// the file that closes that gap: it mounts a real `BlockContainerView`
// inside a real `NSWindow` and drives it through actual Auto Layout. Do not
// treat this file's passing as evidence the view-rendering path is correct.
//
// The most important case here is `test_coexistsWithSRELeadBridge`: it feeds
// one `Terminal` both a normal OSC-133-instrumented command AND an injected
// SRE-Lead-style sentinel-wrapped command, then checks two things the task
// brief calls out explicitly: (1) `SRELeadBridge`'s own extraction technique
// (reading `getBufferAsData()`, exactly like `TabModel.currentBufferLines()`)
// never sees any OSC 133 bytes leak into the text between the sentinel
// markers, and (2) `TerminalBlockTracker` never surfaces the sentinel
// command as a normal-looking block.

import Foundation
import SwiftTerm

enum TerminalBlockTrackerSelfTest {

    static func run() -> Bool {
        let cases: [(String, () -> String?)] = [
            ("parsesSimpleSuccessfulCommand", test_parsesSimpleSuccessfulCommand),
            ("tracksNonZeroExitCode", test_tracksNonZeroExitCode),
            ("streamsOutputForARunningBlockBeforeItCloses", test_streamsOutputForARunningBlockBeforeItCloses),
            ("hidesSRELeadSentinelCommandFromBlockList", test_hidesSRELeadSentinelCommandFromBlockList),
            ("coexistsWithSRELeadBridge", test_coexistsWithSRELeadBridge),
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
    /// a newline, the command's output, then the `D` marker closing it -
    /// exactly the shape validated live against real bash/zsh.
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

    private static func test_streamsOutputForARunningBlockBeforeItCloses() -> String? {
        let terminal = makeTerminal()
        let tracker = TerminalBlockTracker()
        tracker.attach(to: terminal)

        // Only the `B` marker and the command echo + partial output so far -
        // no `D` yet, simulating a still-running command.
        feed(terminal, "\u{1b}]133;B\u{07}" + "sleep 5 && echo done" + "\r\n" + "partial output line 1\r\n")
        tracker.refreshRunningBlock()

        guard tracker.blocks.count == 1 else { return "expected 1 running block, got \(tracker.blocks.count)" }
        guard tracker.blocks[0].status == .running else { return "expected .running, got \(tracker.blocks[0].status)" }
        guard tracker.blocks[0].outputText.contains("partial output line 1") else {
            return "live output not reflected before the block closed: \(tracker.blocks[0].outputText)"
        }

        // Now finish it.
        feed(terminal, "more output\r\n" + "\u{1b}]133;D;0;\(b64("sleep 5 && echo done"))\u{07}")
        guard let finished = tracker.blocks.first, finished.status == .finished(exitCode: 0) else {
            return "block did not close correctly: \(tracker.blocks.first?.status as Any)"
        }
        guard finished.outputText.contains("partial output line 1"), finished.outputText.contains("more output") else {
            return "final output missing earlier or later content: \(finished.outputText)"
        }
        return nil
    }

    private static func test_hidesSRELeadSentinelCommandFromBlockList() -> String? {
        let terminal = makeTerminal()
        let tracker = TerminalBlockTracker()
        tracker.attach(to: terminal)

        let sentinelCommand = "echo SRE_LEAD_START_deadbeef; echo pod/api-1 Running; echo SRE_LEAD_END_deadbeef"
        feed(terminal, promptCycle(command: sentinelCommand, output: "pod/api-1 Running", exitCode: 0))

        guard tracker.blocks.isEmpty else {
            return "SRE Lead's sentinel-wrapped command was rendered as a normal block: \(tracker.blocks)"
        }
        return nil
    }

    /// The critical two-way safety check the task brief calls out
    /// explicitly: OSC 133 markers must never corrupt what `SRELeadBridge`
    /// extracts, and the reverse (this file hiding the sentinel command)
    /// must hold even when a normal, non-sentinel command runs immediately
    /// before it in the same terminal.
    private static func test_coexistsWithSRELeadBridge() -> String? {
        let terminal = makeTerminal()
        let tracker = TerminalBlockTracker()
        tracker.attach(to: terminal)

        // A normal captain-typed command first.
        feed(terminal, promptCycle(command: "ls -la", output: "total 0\r\ndrwxr-xr-x  file.txt", exitCode: 0))

        // Then SRE Lead injects its sentinel-wrapped kubectl command into the
        // very same terminal, exactly as `SRELeadBridge.beginProcessing`
        // does (`"echo <start>; <command>; echo <end>\n"`), while the block
        // view hook is still active on this same tab.
        let startMarker = "SRE_LEAD_START_cafef00d"
        let endMarker = "SRE_LEAD_END_cafef00d"
        let kubectlCommand = "echo \(startMarker); kubectl get pods; echo \(endMarker)"
        let kubectlOutput = "\(startMarker)\r\npod/api-1   1/1   Running\r\npod/api-2   1/1   Running\r\n\(endMarker)"
        feed(terminal, promptCycle(command: kubectlCommand, output: kubectlOutput, exitCode: 0))

        // 1) `SRELeadBridge`'s own extraction technique must see clean text
        // between its sentinels - no OSC 133 bytes, no block-view artifacts.
        let bufferLines = TerminalBlockTracker.bufferLines(terminal)
        guard let startIdx = bufferLines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == startMarker }),
              let endIdx = bufferLines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == endMarker }),
              endIdx > startIdx else {
            return "could not locate SRE Lead's own sentinel markers in the buffer - lines: \(bufferLines)"
        }
        let extracted = bufferLines[(startIdx + 1)..<endIdx].joined(separator: "\n")
        guard extracted == "pod/api-1   1/1   Running\npod/api-2   1/1   Running" else {
            return "extraction between SRE Lead's sentinels was corrupted: \(extracted)"
        }
        guard !extracted.contains("\u{1b}") else { return "extracted text contains a raw escape byte" }
        guard !extracted.contains("133;") else { return "extracted text leaked an OSC 133 payload" }

        // 2) Block view itself must show the normal command but hide the
        // sentinel-wrapped one.
        guard tracker.blocks.count == 1 else { return "expected exactly 1 visible block, got \(tracker.blocks.count): \(tracker.blocks)" }
        guard tracker.blocks[0].commandText == "ls -la" else { return "unexpected surviving block: \(tracker.blocks[0].commandText)" }
        return nil
    }
}
