// Manjesh Grand Line - native macOS app.
//
// `fm/cockpit-block-view-ssh-only`: turns the OSC 133 stream `ShellIntegration`
// installs (see that file's header for the exact two-marker protocol and why
// it's narrower than the full spec) into a list of discrete command blocks,
// using the *same* terminal buffer `SRELeadBridge` already reads from
// (`Terminal.getBufferAsData()`) - see that file's own header before touching
// anything here.
//
// Why this can never corrupt (or be corrupted by) the SRE Lead bridge:
// `Terminal.registerOscHandler(code:)` fully consumes an OSC 133 sequence
// inside SwiftTerm's escape-sequence parser - it is never written into the
// terminal's own screen/scrollback buffer as visible text (confirmed by
// reading `EscapeSequenceParser.dispatchOsc`: an *unregistered* OSC code's
// default fallback is a no-op, and a *registered* one - what this file adds -
// hands the raw payload bytes only to the registered handler, never to
// anything that renders them). `SRELeadBridge.currentBufferLines()` reads
// exactly that same rendered buffer via `getBufferAsData()`, so the escape
// bytes this file's hook emits can never land inside the substring the
// bridge extracts between its own sentinel markers, regardless of how the
// two mechanisms interleave in time. Verified concretely (not just reasoned
// about) with a live PTY session that sourced the real hook script and then
// sent a real `echo SRE_LEAD_START_...; ...; echo SRE_LEAD_END_...` line
// through it - see PR #79's description for the transcript.
//
// The complementary risk - this file's own rendering turning the bridge's
// injected sentinel command into a confusing user-facing block - is real and
// handled explicitly: `closeBlock` drops (never renders) a block whose
// command text starts with `SRELeadBridge.sentinelCommandPrefix`.
//
// Attached only to an SSH host page's tab (`TabModel.supportsBlockView`) -
// the built-in Firstmate console's Shell/Mirror tabs, and a plain ad-hoc
// local shell tab, never get a tracker at all. See AGENTS.md's block-view
// section for why this is narrower than the original PR #79 design.
import Foundation
import SwiftTerm

/// One command's lifecycle in block view: header (command text), body
/// (output text), and status. `running` blocks have incomplete `outputText`
/// that grows as more data arrives; `finished` is immutable once set.
struct TerminalBlock: Identifiable {
    enum Status: Equatable {
        case running
        case finished(exitCode: Int32)
    }

    let id: UUID
    var commandText: String
    var outputText: String
    var status: Status
}

/// Attached once per supported tab's `Terminal` (SSH only - see
/// `TabModel.supportsBlockView`), for the lifetime of that terminal. Keeps
/// tracking even while block view isn't the visible mode for that tab -
/// toggling block view on/off never restarts anything, so the tracker must
/// already have a complete, correct block history the moment the captain
/// switches to it.
final class TerminalBlockTracker {
    private(set) var blocks: [TerminalBlock] = []

    /// Fired whenever `blocks` changes - a `BlockContainerView` observes this
    /// to know when to re-render. Never fired synchronously off SwiftTerm's
    /// own parsing thread guarantees beyond what `registerOscHandler`/
    /// `dataReceived` already provide (both are called on the main thread by
    /// `LocalProcessTerminalView` today), so this can update AppKit directly.
    var onChange: (() -> Void)?

    /// Blocks beyond this count are dropped from the front, oldest first, so
    /// a long-lived session's block list doesn't grow without bound. Chosen
    /// generously - a captain reviewing block history wants real scrollback,
    /// this just stops it from being literally unbounded.
    private let maxBlocks = 500

    private weak var terminal: Terminal?
    private var openBlockID: UUID?

    /// A full copy of every buffer line, captured the instant `B` fires -
    /// **not** a row count. `Terminal`/`Buffer` pre-fills a fresh screen with
    /// `rows` blank lines up front (`Buffer.fillViewportRows`) and only
    /// *appends* new lines once real scrolling pushes old ones into history;
    /// until that first scroll, new output overwrites existing (already-
    /// counted) rows in place rather than growing `getBufferAsData()`'s line
    /// count at all. A row-count-based boundary (the first version of this
    /// file, and the same technique `SRELeadBridge.currentBufferLines()`
    /// uses) is therefore only reliable once a tab's buffer has already
    /// scrolled well past its initial screenful - true for `SRELeadBridge`
    /// in practice (a bastion session mid-investigation has produced pages
    /// of output already) but false for the very first few commands in a
    /// freshly opened tab, which is exactly when block view needs to work.
    /// Diffing a full "before" and "after" snapshot instead - the first line
    /// where they differ is where new content started, regardless of
    /// whether that line was an in-place overwrite or a freshly appended
    /// row - is correct in both regimes. Caught by this task's own self-test
    /// (`TerminalBlockTrackerSelfTest`), not by inspection: the row-count
    /// version passed the exit-code case (empty output either way) but
    /// failed both cases with real output text, in a fresh `HeadlessTerminal`
    /// exactly like a real freshly opened tab.
    private var openBlockStartSnapshot: [String]?

    /// Registers the OSC 133 handler. Call once, right after the tab's
    /// terminal exists (mirrors how `ConsoleController.makeTerminal` sets up
    /// every other one-time terminal property).
    func attach(to terminal: Terminal) {
        self.terminal = terminal
        terminal.registerOscHandler(code: 133) { [weak self] data in
            self?.handleOSC133(data)
        }
    }

    /// Call from `CockpitTerminalView.dataReceived` (or any point after new
    /// bytes have been fed to the terminal) so a `running` block's
    /// `outputText` grows as output streams in, instead of only appearing
    /// once the command finishes and `D` fires.
    func refreshRunningBlock() {
        guard let terminal, let startSnapshot = openBlockStartSnapshot, let id = openBlockID,
              let idx = blocks.firstIndex(where: { $0.id == id }) else { return }
        let text = Self.outputRegion(from: startSnapshot, current: Self.bufferLines(terminal))
        if blocks[idx].outputText != text {
            blocks[idx].outputText = text
            onChange?()
        }
    }

    private func handleOSC133(_ data: ArraySlice<UInt8>) {
        guard let terminal, let text = String(bytes: data, encoding: .utf8) else { return }
        let parts = text.split(separator: ";", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
        guard let kind = parts.first else { return }
        switch kind {
        case "B":
            openNewBlock(terminal: terminal)
        case "D":
            guard parts.count >= 3, let exitCode = Int32(parts[1]) else { return }
            closeBlock(exitCode: exitCode, base64CommandText: parts[2], terminal: terminal)
        default:
            break
        }
    }

    private func openNewBlock(terminal: Terminal) {
        let block = TerminalBlock(id: UUID(), commandText: "", outputText: "", status: .running)
        blocks.append(block)
        trimIfNeeded()
        openBlockID = block.id
        openBlockStartSnapshot = Self.bufferLines(terminal)
        onChange?()
    }

    private func closeBlock(exitCode: Int32, base64CommandText: String, terminal: Terminal) {
        let commandText = Self.decodeBase64(base64CommandText) ?? ""

        guard let id = openBlockID, let idx = blocks.firstIndex(where: { $0.id == id }) else {
            // A `D` with nothing open (e.g. the very first prompt cycle
            // after the hook installs, before any `B` has fired) - nothing
            // to close.
            return
        }
        openBlockID = nil

        if commandText.hasPrefix(SRELeadBridge.sentinelCommandPrefix) {
            // SRE Lead's own plumbing, not something the captain typed -
            // drop the block entirely rather than show it.
            blocks.remove(at: idx)
            openBlockStartSnapshot = nil
            onChange?()
            return
        }

        let startSnapshot = openBlockStartSnapshot ?? []
        openBlockStartSnapshot = nil
        let outputText = Self.outputRegion(from: startSnapshot, current: Self.bufferLines(terminal))

        blocks[idx].commandText = commandText
        blocks[idx].outputText = outputText
        blocks[idx].status = .finished(exitCode: exitCode)
        onChange?()
    }

    /// Clears block history - called on reconnect (`ConsoleController.
    /// reconnectActive`), since a fresh process means a fresh session with
    /// no relationship to whatever blocks were captured from the old one.
    /// Does not re-register the OSC handler - it's already registered on
    /// this tab's `Terminal` for the tab's lifetime.
    func reset() {
        blocks = []
        openBlockID = nil
        openBlockStartSnapshot = nil
        onChange?()
    }

    private func trimIfNeeded() {
        if blocks.count > maxBlocks {
            blocks.removeFirst(blocks.count - maxBlocks)
        }
    }

    // MARK: Helpers

    /// Same technique `SRELeadBridge.currentBufferLines()` uses - split
    /// `getBufferAsData()` by line. Kept as a free function here (not a call
    /// into `SRELeadBridgeTerminal`) since a `TerminalBlockTracker` is
    /// attached directly to a `Terminal`, not a `TabModel`.
    static func bufferLines(_ terminal: Terminal) -> [String] {
        let data = terminal.getBufferAsData()
        let text = String(data: data, encoding: .utf8) ?? ""
        return text.components(separatedBy: "\n")
    }

    static func decodeBase64(_ s: String) -> String? {
        guard let data = Data(base64Encoded: s) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Finds the first line where `current` diverges from `start` (an
    /// in-place edit or a freshly appended row both count as a divergence),
    /// then returns everything in `current` *after* that line, joined -
    /// dropping that first divergent line itself, since it's the row the
    /// echoed command text landed on, not real output. See
    /// `openBlockStartSnapshot`'s doc comment for why this diffs full
    /// snapshots instead of comparing line counts.
    static func outputRegion(from start: [String], current: [String]) -> String {
        var firstDivergence = 0
        let shared = min(start.count, current.count)
        while firstDivergence < shared, start[firstDivergence] == current[firstDivergence] {
            firstDivergence += 1
        }
        let outputStart = firstDivergence + 1
        guard current.count > outputStart else { return "" }
        return current[outputStart...].joined(separator: "\n")
    }
}
