// Manjesh Grand Line - native macOS app.
//
// `fm/cockpit-block-view-stage0`: turns the OSC 133 stream `ShellIntegration`
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
// two mechanisms interleave in time.
//
// **This is Stage 0 of a staged rollout** (see `data/cockpit-block-view-
// scout/report.md` and AGENTS.md's block-view section): a command's
// `B`/`D` markers are still parsed the instant they arrive (this part - the
// OSC 133 parsing itself - was never the source of either prior production
// break, per the scout report), so `blocks` always holds an up-to-date
// history in memory. What Stage 0 deliberately does NOT do is wire anything
// to `CockpitTerminalView.onDataReceived` (that per-chunk hook is exactly
// what the scout report's Mechanism B blames for the earlier main-thread
// stall under real scrollback volume) or auto-re-render a view whenever
// `blocks` changes. Rendering only happens when `ConsoleController`'s
// manual "Refresh" action calls `BlockContainerView.render(tracker.blocks)`
// directly - between refreshes, new commands can complete in the
// background with no visible effect until the next click. A `running`
// block's `outputText` is intentionally never populated in this stage
// (no live streaming of in-progress output) - it appears only once the
// block closes.
//
// Attached only to an SSH host page's tab, and only for the one host that
// opted in (`Host.blockViewOptIn`) - see `TabModel.blockViewOptIn` and
// AGENTS.md's block-view section for the scope narrowing.
import Foundation
import SwiftTerm

/// One command's lifecycle in block view: header (command text), body
/// (output text), and status.
struct TerminalBlock: Identifiable, Equatable {
    enum Status: Equatable {
        case running
        case finished(exitCode: Int32)
    }

    let id: UUID
    var commandText: String
    var outputText: String
    var status: Status
}

/// Attached once per supported tab's `Terminal`, for the lifetime of that
/// terminal. Keeps tracking even while block view isn't the visible mode for
/// that tab - toggling block view on/off never restarts anything, and a
/// manual refresh always reflects the tracker's full history regardless of
/// how long it's been since the tab was last looked at.
final class TerminalBlockTracker {
    private(set) var blocks: [TerminalBlock] = []

    /// Fired whenever `blocks` changes (a marker opened/closed a block, or
    /// `reset()` ran). Stage 0 does not use this to drive automatic
    /// rendering - `ConsoleController`'s manual Refresh action reads
    /// `blocks` directly instead - but it's real signal a self-test can
    /// assert against without needing a live view.
    var onChange: (() -> Void)?

    /// Blocks beyond this count are dropped from the front, oldest first, so
    /// a long-lived session's block list doesn't grow without bound.
    private let maxBlocks = 500

    private weak var terminal: Terminal?
    private var openBlockID: UUID?

    /// A full copy of every buffer line, captured the instant `B` fires -
    /// **not** a row count. `Terminal`/`Buffer` pre-fills a fresh screen with
    /// `rows` blank lines up front (`Buffer.fillViewportRows`) and only
    /// *appends* new lines once real scrolling pushes old ones into history;
    /// until that first scroll, new output overwrites existing (already-
    /// counted) rows in place rather than growing `getBufferAsData()`'s line
    /// count at all. A row-count-based boundary is therefore only reliable
    /// once a tab's buffer has already scrolled well past its initial
    /// screenful - diffing a full "before" and "after" snapshot instead - the
    /// first line where they differ is where new content started - is
    /// correct in both regimes. Caught by this tracker's own self-test, not
    /// by inspection: the row-count version passed the exit-code case but
    /// failed cases with real output text in a fresh `HeadlessTerminal`.
    private var openBlockStartSnapshot: [String]?

    /// Registers the OSC 133 handler. Call once, right after the tab's
    /// terminal exists.
    func attach(to terminal: Terminal) {
        self.terminal = terminal
        terminal.registerOscHandler(code: 133) { [weak self] data in
            self?.handleOSC133(data)
        }
    }

    private func handleOSC133(_ data: ArraySlice<UInt8>) {
        guard let terminal, let text = String(bytes: data, encoding: .utf8) else { return }
        let parts = text.split(separator: ";", maxSplits: 3, omittingEmptySubsequences: false).map(String.init)
        guard let kind = parts.first else { return }
        switch kind {
        case "B":
            openNewBlock(terminal: terminal)
        case "D":
            guard parts.count >= 3, let exitCode = Int32(parts[1]) else { return }
            // The 4th field (`fm/cockpit-fix-block-view-stage0-bugs`) is
            // whether the shell hook thinks a real command actually ran
            // since the last close - see `ShellIntegration.swift`'s header
            // for why `D` still fires unconditionally (even for a blank
            // Enter) and what "real" means. Missing entirely (an old/
            // not-yet-reinstalled hook from before this field existed)
            // defaults to real, matching the previous unconditional behavior.
            let isReal = parts.count >= 4 ? (parts[3] != "0") : true
            closeBlock(exitCode: exitCode, base64CommandText: parts[2], isReal: isReal, terminal: terminal)
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

    /// Closes the currently-open block, unless `isReal` is false, in which
    /// case the block is discarded entirely instead of finalized.
    ///
    /// `isReal` comes from the shell hook's own history-number comparison
    /// (see `ShellIntegration.swift`'s header): a `D` fires for *every*
    /// prompt cycle, including one triggered by pressing Enter on a blank
    /// line with nothing typed - bash/zsh don't add an empty line to
    /// history, so the hook can tell "nothing really happened here" from
    /// "the history number moved" and flags the close accordingly. Before
    /// this existed, a blank Enter closed the open block as a normal,
    /// visible, `.finished(exitCode: <whatever $? was before>)` block with
    /// empty output and the *previous* real command's text (since that's
    /// what `history 1`/`fc -ln -1` still returned) - a real, reproduced bug
    /// (see this task's PR description for the pty-based repro). Discarding
    /// rather than finalizing means B/D still pair up 1:1 (the shell always
    /// sends D, so no block is ever left permanently stuck `.running`), but
    /// nothing spurious ever reaches `blocks`.
    private func closeBlock(exitCode: Int32, base64CommandText: String, isReal: Bool, terminal: Terminal) {
        guard let id = openBlockID, let idx = blocks.firstIndex(where: { $0.id == id }) else {
            // A `D` with nothing open (e.g. the very first prompt cycle
            // after the hook installs, before any `B` has fired) - nothing
            // to close.
            return
        }
        openBlockID = nil
        let startSnapshot = openBlockStartSnapshot ?? []
        openBlockStartSnapshot = nil

        guard isReal else {
            blocks.remove(at: idx)
            onChange?()
            return
        }

        let commandText = Self.decodeBase64(base64CommandText) ?? ""
        let outputText = Self.outputRegion(from: startSnapshot, current: Self.bufferLines(terminal))

        blocks[idx].commandText = commandText
        blocks[idx].outputText = outputText
        blocks[idx].status = .finished(exitCode: exitCode)
        onChange?()
    }

    /// Clears block history. Stage 0's one, simplest-correct-by-construction
    /// reconnect behavior (see the scout report's Mechanism A and design
    /// section 2): a fresh process means a fresh session with no
    /// relationship to whatever blocks were captured from the old one, so
    /// this wipes and starts over rather than trying to preserve and patch
    /// old state. Called from exactly one place -
    /// `ConsoleController.restartTabBookkeeping` - which both the initial
    /// start and any reconnect path route through, so this can never be
    /// skipped by one restart path and not the other. See that method's own
    /// doc comment for why this used to be able to happen (and now can't).
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
    /// `getBufferAsData()` by line.
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
    /// echoed command text landed on, not real output.
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
