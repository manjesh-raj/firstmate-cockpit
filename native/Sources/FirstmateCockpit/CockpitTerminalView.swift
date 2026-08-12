// Manjesh Grand Line - native macOS app.
//
// The paste-hardening terminal view. This is the Phase 1 subclass kept verbatim
// (design report section 5.3): both Phase 2 tabs - the Shell and the tmux Mirror
// - use it, so the screenshot-paste-into-Claude flow behaves identically on both.
//
// Phase 3 (design report Section B5, Section D Phase 3) adds session logging
// here too: `dataReceived` is SwiftTerm's one choke point for "bytes the host
// sent, before they are fed to the terminal emulator" (see
// `LocalProcessTerminalView.dataReceived` in the vendored package), so tee-ing
// it to a file is a small override, not a reimplementation of anything
// SwiftTerm already owns. This deliberately does not reuse SwiftTerm's own
// `setHostLogging(directory:)` - that writes one file per read syscall
// (`log-0`, `log-1`, ...), not the single chronological transcript per
// session the brief asks for.

import AppKit
import SwiftTerm

// MARK: - Paste-hardening terminal (design report section 5.3)

/// A `LocalProcessTerminalView` that guarantees the bracketed-paste signal for
/// an image-only clipboard.
///
/// SwiftTerm's default `paste(_:)` already emits an empty bracketed paste
/// (`ESC[200~` `ESC[201~`) when the clipboard holds no text, which is the exact
/// signal Claude Code needs to notice a paste and go read the image off the
/// system clipboard. This subclass makes that contract explicit and independent
/// of any future upstream change: if there is an image and no text, and the
/// terminal has bracketed paste mode on, it sends the empty bracketed paste
/// directly. Otherwise it defers to SwiftTerm's normal paste (real text still
/// pastes as text).
final class CockpitTerminalView: LocalProcessTerminalView {
    override func paste(_ sender: Any) {
        lastUserActivity = Date()
        let pb = NSPasteboard.general
        let hasText = (pb.string(forType: .string)?.isEmpty == false)
        let hasImage = pb.canReadObject(forClasses: [NSImage.self], options: nil)
        if !hasText, hasImage, terminal.bracketedPasteMode {
            send(data: EscapeSequences.bracketedPasteStart[0...])
            send(data: EscapeSequences.bracketedPasteEnd[0...])
            return
        }
        super.paste(sender)
    }

    // MARK: Captain activity tracking (`fm/cockpit-sre-lead-shared-terminal`)

    /// The most recent moment a real keystroke or paste reached this
    /// terminal - never set by `SRELeadBridge`'s own `send(txt:)` injections,
    /// which don't go through key events. `SRELeadBridge` reads this (via
    /// `TabModel`'s `SRELeadBridgeTerminal` conformance) to refuse a command
    /// when the captain is actively using the tab, and to detect after the
    /// fact that the captain typed into it while a command was still
    /// running.
    private(set) var lastUserActivity: Date?

    /// `TerminalView.keyDown(with:)` is declared `public`, not `open` (see
    /// the AGENTS.md gotcha catalogue's note on SwiftTerm's non-`open`
    /// override points), so it can't be overridden from this module the way
    /// `paste(_:)` above can. A local event monitor, scoped to exactly the
    /// events this view itself receives as first responder, gets the same
    /// "a real keystroke arrived" signal without needing an override point
    /// SwiftTerm doesn't expose.
    private var keyActivityMonitor: Any?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let keyActivityMonitor {
            NSEvent.removeMonitor(keyActivityMonitor)
            self.keyActivityMonitor = nil
        }
        guard window != nil else { return }
        keyActivityMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self, self.window?.firstResponder === self else { return event }
            self.lastUserActivity = Date()
            return event
        }
    }

    deinit {
        if let keyActivityMonitor {
            NSEvent.removeMonitor(keyActivityMonitor)
        }
    }

    // MARK: Session logging (B5)

    private var logHandle: FileHandle?

    var isLogging: Bool { logHandle != nil }

    /// Start (or restart) appending this terminal's host output, as raw
    /// bytes, to `url`. The file is created empty first so a fresh, empty
    /// transcript exists even if the session produces no further output.
    func startLogging(to url: URL) throws {
        stopLogging()
        FileManager.default.createFile(atPath: url.path, contents: nil)
        logHandle = try FileHandle(forWritingTo: url)
    }

    func stopLogging() {
        try? logHandle?.close()
        logHandle = nil
    }

    /// Every byte the host sends passes through here on its way to the
    /// terminal emulator (`feed`) - the single right place to tee a
    /// transcript without touching anything SwiftTerm already owns.
    override func dataReceived(slice: ArraySlice<UInt8>) {
        if let logHandle {
            logHandle.write(Data(slice))
        }
        super.dataReceived(slice: slice)
    }
}
