// Manjesh Grand Line - native macOS app.
//
// `fm/grandline-log-analyzer-build`, spec §2's "Send from Terminal": what
// the Console page's "Analyze Logs" toolbar button actually captures.
//
// **The captain's resolved decision, implemented here exactly:** the default
// capture is the *most recently completed command's own block* (its command
// line plus its output) - NOT the whole scrollback (10,000 lines, mostly
// irrelevant - see `ConsoleController`'s scrollback note) and NOT just what
// happens to be visible in the viewport (which silently drops a bug that
// scrolled past). A manual text selection in the terminal overrides that and
// is sent instead, regardless of block boundaries.
//
// **The block boundaries come from the mechanism this app already has**, not
// a second one: `TerminalBlockTracker`'s OSC 133 markers, installed by
// `ShellIntegration` (read both of those files' headers before changing
// anything here). No new shell hook, no new marker protocol, no screen
// scraping for prompt lines.
//
// **The gap that mechanism leaves, and how it is handled.** Investigated
// rather than assumed: `ConsoleController.installShellIntegrationIfSupported`
// guards on `tab.blockTracker != nil`, and `addTab` only creates a tracker
// when `case .ssh = launch && blockViewOptIn && BlockViewFeature.isEnabled`.
// So the OSC 133 hook is **not** active on every SSH tab - it is active only
// on the one saved host that has opted into Block View, and only while that
// feature flag is set. On any other host there is no block data at all.
//
// Three options were considered for that case:
//   1. Install the shell hook for every SSH tab regardless of Block View.
//      Rejected: that injects keystrokes into a captain's live remote shell
//      on hosts that never opted in, which is a real behaviour change to the
//      terminal well outside this feature's scope, and Block View's own
//      staged-rollout history (two prior production breaks, see AGENTS.md)
//      is precisely a warning against widening that mechanism casually.
//   2. Heuristically find the last prompt line by scanning the buffer.
//      Rejected: a prompt is arbitrary text (starship, powerlevel10k, a bare
//      `$`), so this guesses, and a wrong guess silently truncates or
//      over-captures the evidence an investigation is built on.
//   3. Fall back to a **bounded tail** of the buffer, labelled honestly.
//      Chosen. It satisfies both halves of the captain's rule - it is not
//      the full scrollback (bounded at `fallbackTailLines`) and it is not
//      the viewport (it reads the buffer, including rows scrolled off
//      screen) - and it says exactly what it did in `scopeDescription`, so
//      the captain is never left guessing what got sent.
//
// The page also surfaces the upgrade path rather than hiding it: a capture
// that fell back says so, and points at Block View's per-host opt-in as the
// way to get exact last-command capture on that host.

import Foundation

/// What a terminal capture actually grabbed.
enum LogTerminalCaptureScope: Equatable {
    /// The captain had text selected - that selection was sent verbatim.
    case selection
    /// The last completed command block (command line + its output).
    case lastCommandBlock(command: String)
    /// No block data available on this tab - a bounded tail of the buffer.
    case recentOutputFallback(lines: Int)

    /// The badge/label text the analyzer shows above imported evidence.
    var shortLabel: String {
        switch self {
        case .selection: return "Selected text"
        case .lastCommandBlock: return "Last command"
        case .recentOutputFallback: return "Recent output"
        }
    }
}

struct LogTerminalCapture: Equatable {
    var text: String
    var scope: LogTerminalCaptureScope
    /// One plain sentence stating exactly what was captured - shown to the
    /// captain, so the capture rule is never something they have to infer.
    var scopeDescription: String
    /// Set only for the fallback case: the reason exact capture wasn't
    /// possible, plus what would enable it.
    var fallbackNotice: String?

    var isEmpty: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}

enum LogTerminalCaptureBuilder {

    /// The bounded tail used when no block data exists. Comfortably more
    /// than a screenful (so nothing that scrolled past during the last
    /// command is lost) and far less than the 10,000-line scrollback.
    static let fallbackTailLines = 400

    /// Pure decision logic - no AppKit, no SwiftTerm, so
    /// `LogAnalyzerSelfTest` can drive every branch without a terminal.
    ///
    /// - Parameters:
    ///   - selection: the terminal's current selection, if any.
    ///   - blocks: `TerminalBlockTracker.blocks` for this tab, or `[]` when
    ///     the tab has no tracker at all.
    ///   - bufferLines: the tab's full rendered buffer, oldest line first.
    ///   - hasBlockTracking: whether this tab has OSC 133 block tracking at
    ///     all - distinguishes "tracking is on but no command has completed
    ///     yet" from "this host never opted in", which get different notices.
    static func build(selection: String?,
                      blocks: [TerminalBlock],
                      bufferLines: [String],
                      hasBlockTracking: Bool) -> LogTerminalCapture {

        // 1. A manual selection always wins (the captain's explicit override).
        if let selection, !selection.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return LogTerminalCapture(
                text: selection,
                scope: .selection,
                scopeDescription: "Captured the text you had selected in the terminal.",
                fallbackNotice: nil
            )
        }

        // 2. The most recently *completed* block. A still-running block is
        //    skipped deliberately: its output is incomplete by definition,
        //    and Stage 0's tracker never populates `outputText` until the
        //    block closes anyway (see `TerminalBlockTracker`'s header).
        if let last = blocks.last(where: { if case .finished = $0.status { return true } else { return false } }) {
            var text = last.commandText
            if !last.outputText.isEmpty {
                text += text.isEmpty ? last.outputText : "\n" + last.outputText
            }
            var description = "Captured your last completed command"
            if !last.commandText.isEmpty { description += " (`\(last.commandText)`)" }
            description += " and its output — not the whole scrollback."
            return LogTerminalCapture(
                text: text,
                scope: .lastCommandBlock(command: last.commandText),
                scopeDescription: description,
                fallbackNotice: nil
            )
        }

        // 3. Bounded tail - see this file's header for why this shape.
        let trimmedTail = Array(bufferLines.suffix(fallbackTailLines))
        // Drop trailing blank rows: a terminal buffer is pre-filled with
        // blank lines up to its row count (`Buffer.fillViewportRows` - see
        // `TerminalBlockTracker`'s own note on this), so a naive tail is
        // mostly empty on a freshly-connected tab.
        var lines = trimmedTail
        while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty {
            lines.removeLast()
        }

        let notice: String
        if hasBlockTracking {
            notice = "No completed command has been recorded on this tab yet, so the most recent "
                + "output was captured instead. Run a command and try again for an exact capture."
        } else {
            notice = "This host doesn't have per-command tracking enabled, so the most recent output "
                + "was captured instead of one exact command. Enable Block View for this host "
                + "(Hosts → edit the host) to capture exactly the last command, or select text in "
                + "the terminal first to send something specific."
        }

        return LogTerminalCapture(
            text: lines.joined(separator: "\n"),
            scope: .recentOutputFallback(lines: lines.count),
            scopeDescription: "Captured the most recent \(lines.count) line\(lines.count == 1 ? "" : "s") "
                + "of this tab's output — not the whole scrollback.",
            fallbackNotice: notice
        )
    }
}
