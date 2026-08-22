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
import SwiftTerm

enum TerminalBlockTrackerSelfTest {

    static func run() -> Bool {
        let cases: [(String, () -> String?)] = [
            ("parsesSimpleSuccessfulCommand", test_parsesSimpleSuccessfulCommand),
            ("tracksNonZeroExitCode", test_tracksNonZeroExitCode),
            ("resetClearsBlocksAndOpenState", test_resetClearsBlocksAndOpenState),
            ("aDCloseWithNothingOpenIsIgnored", test_closeWithNothingOpenIsIgnored),
            ("trimsOldestBlocksBeyondTheCap", test_trimsOldestBlocksBeyondCap),
            ("blankEnterDoesNotCreatePhantomBlock", test_blankEnterDoesNotCreatePhantomBlock),
            ("repeatedIdenticalCommandStillProducesTwoRealBlocks", test_repeatedIdenticalCommandStillProducesTwoRealBlocks),
            ("blankEnterBetweenTwoRealRepeatsIsDroppedNotTheReals", test_blankEnterBetweenTwoRealRepeatsIsDroppedNotTheReals),
            ("oldStyleThreeFieldDMarkerStillTreatedAsReal", test_oldStyleThreeFieldDMarkerStillTreatedAsReal),
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
    /// `real` mirrors the shell hook's own history-number-based flag (see
    /// `ShellIntegration.swift`'s header) - omit it (`nil`) to build an
    /// old-style, 3-field `D` marker (no flag at all), matching a session
    /// that hasn't reinstalled the newer hook yet.
    private static func promptCycle(command: String, output: String, exitCode: Int32, real: Bool? = true) -> String {
        let dMarker: String
        if let real {
            dMarker = "\u{1b}]133;D;\(exitCode);\(b64(command));\(real ? "1" : "0")\u{07}"
        } else {
            dMarker = "\u{1b}]133;D;\(exitCode);\(b64(command))\u{07}"
        }
        return "\u{1b}]133;B\u{07}" + command + "\r\n" + output + "\r\n" + dMarker
    }

    /// A prompt cycle with nothing typed - a blank Enter. Only `B` fires
    /// from the redrawn prompt, then `D` closes it with `real=0` and
    /// whatever the *previous* real command's text/exit code happened to
    /// be (since `history 1`/`fc -ln -1` didn't change) - exactly what the
    /// real shell hook sends in this case.
    private static func blankEnterCycle(previousCommand: String, previousExitCode: Int32) -> String {
        "\u{1b}]133;B\u{07}" + "\r\n" + "\u{1b}]133;D;\(previousExitCode);\(b64(previousCommand));0\u{07}"
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

    /// `fm/cockpit-fix-block-view-stage0-bugs`, bug 1: reproduced live (see
    /// this task's PR description for the pty-based transcripts) that a
    /// captain hitting Enter on a blank prompt line - a common habit -
    /// produced a spurious extra block labeled with the *previous* real
    /// command's text, its old exit code, and empty output, indistinguishable
    /// in the UI from a genuine repeat of that command. A blank Enter still
    /// fires `B` then `D` (nothing in the protocol suppresses that), but the
    /// hook's `D` now carries `real=0` for it - `closeBlock` must discard
    /// that close rather than finalize it.
    private static func test_blankEnterDoesNotCreatePhantomBlock() -> String? {
        let terminal = makeTerminal()
        let tracker = TerminalBlockTracker()
        tracker.attach(to: terminal)

        feed(terminal, promptCycle(command: "ls -ltrh", output: "total 0", exitCode: 0))
        guard tracker.blocks.count == 1 else { return "expected 1 block after the real command, got \(tracker.blocks.count)" }

        feed(terminal, blankEnterCycle(previousCommand: "ls -ltrh", previousExitCode: 0))
        guard tracker.blocks.count == 1 else {
            return "a blank Enter created a phantom block: \(tracker.blocks)"
        }
        return nil
    }

    /// The other half of bug 1: a *genuine* back-to-back repeat of the same
    /// command (the captain's actual reported scenario - re-running
    /// `ls -ltrh` a few times) must still produce its own real, populated
    /// block each time - the fix must not overcorrect into treating every
    /// repeat as a no-op.
    private static func test_repeatedIdenticalCommandStillProducesTwoRealBlocks() -> String? {
        let terminal = makeTerminal()
        let tracker = TerminalBlockTracker()
        tracker.attach(to: terminal)

        feed(terminal, promptCycle(command: "ls -ltrh", output: "total 4\nfile-a.txt", exitCode: 0))
        feed(terminal, promptCycle(command: "ls -ltrh", output: "total 4\nfile-a.txt", exitCode: 0))

        guard tracker.blocks.count == 2 else { return "expected 2 real blocks for 2 real repeats, got \(tracker.blocks.count)" }
        for (i, block) in tracker.blocks.enumerated() {
            guard block.commandText == "ls -ltrh" else { return "block \(i) has wrong command text: \(block.commandText)" }
            guard block.outputText.contains("file-a.txt") else { return "block \(i) has empty/wrong output: \(block.outputText.debugDescription)" }
            guard block.status == .finished(exitCode: 0) else { return "block \(i) has wrong status: \(block.status)" }
        }
        return nil
    }

    /// A blank Enter sandwiched between two real repeats (closest to what
    /// the captain actually did) - exactly one phantom must be dropped, the
    /// two real commands must both survive with real output, in order.
    private static func test_blankEnterBetweenTwoRealRepeatsIsDroppedNotTheReals() -> String? {
        let terminal = makeTerminal()
        let tracker = TerminalBlockTracker()
        tracker.attach(to: terminal)

        feed(terminal, promptCycle(command: "ls -ltrh", output: "total 4\nfile-a.txt", exitCode: 0))
        feed(terminal, blankEnterCycle(previousCommand: "ls -ltrh", previousExitCode: 0))
        feed(terminal, promptCycle(command: "ls -ltrh manjesh/", output: "total 8\nfile-b.txt\nfile-c.txt", exitCode: 0))

        guard tracker.blocks.count == 2 else { return "expected 2 real blocks (blank Enter dropped), got \(tracker.blocks.count): \(tracker.blocks)" }
        guard tracker.blocks[0].commandText == "ls -ltrh", tracker.blocks[0].outputText.contains("file-a.txt") else {
            return "first real block wrong: \(tracker.blocks[0])"
        }
        guard tracker.blocks[1].commandText == "ls -ltrh manjesh/", tracker.blocks[1].outputText.contains("file-b.txt") else {
            return "second real block wrong: \(tracker.blocks[1])"
        }
        return nil
    }

    /// Backward compatibility: an old-format, 3-field `D` marker (no `real`
    /// flag at all - a tab whose remote hook hasn't been reinstalled with
    /// this fix yet) must still be treated as a real close, matching every
    /// pre-fix self-test case above that still uses this shape.
    private static func test_oldStyleThreeFieldDMarkerStillTreatedAsReal() -> String? {
        let terminal = makeTerminal()
        let tracker = TerminalBlockTracker()
        tracker.attach(to: terminal)

        feed(terminal, promptCycle(command: "echo legacy", output: "legacy-output", exitCode: 0, real: nil))

        guard tracker.blocks.count == 1 else { return "expected 1 block, got \(tracker.blocks.count)" }
        guard tracker.blocks[0].outputText.contains("legacy-output") else {
            return "unexpected output text: \(tracker.blocks[0].outputText.debugDescription)"
        }
        return nil
    }
}

#endif
