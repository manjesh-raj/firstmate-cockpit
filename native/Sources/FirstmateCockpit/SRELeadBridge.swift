// Manjesh Grand Line - native macOS app.
//
// `fm/cockpit-sre-lead-shared-terminal`: the file-based bridge that lets SRE
// Lead's kubectl MCP tool (`native/Scripts/sre_kubectl_mcp.py`, a subprocess of
// `claude`, itself in its own tmux session - see `SRELead.swift`) run a kubectl
// command in the *same, already-authenticated* interactive terminal tab the
// captain used to log all the way into the connected host, instead of opening a
// second, independent SSH connection.
//
// Why: the captain confirmed a hard constraint on the real "EKS Preprod
// Bastion" host - its EKS Bastion hop is username/password-gated by policy,
// with no SSH key auth possible there. Five prior attempts (PRs #70-73, plus
// an abandoned PTY investigation) all tried to make a second, independent,
// fully-automated SSH connection complete that same login chain - which can
// never work, since nothing can supply a password that is not stored
// anywhere, by design. See `sre_kubectl_mcp.py`'s module docstring and the
// AGENTS.md SRE Lead bullet for the full history; do not resurrect a second-
// connection approach for this or any other password-gated hop.
//
// The Python script and this Swift app are different processes with no shared
// memory, so the bridge is a small polling protocol over files in a per-session
// scratch directory (`SRELeadSession.bridgeDir`, created by `SRELead.setUp`):
// Python writes `request-<id>.json` (`{"command": "<kubectl ...>"}`), this
// class notices it, injects `<command>` into the target tab exactly the way
// `Snippet`'s "Run" action already does (`TerminalView.send(txt:)` -
// `ConsoleController.runSnippetInActiveTab`/`runStartupSnippet`), wrapped with
// two fresh random markers so the real output can be extracted unambiguously
// from the tab's scrollback, then writes `response-<id>.json`. Python polls for
// that file to appear (see `_run_kubectl` there) up to its own timeout.

import Foundation

/// Everything `SRELeadBridge` needs from a terminal it injects commands into
/// and reads output back from, abstracted so the polling/extraction/busy-
/// detection logic below can be unit-tested without AppKit or SwiftTerm - see
/// `FirstmateCockpitTests.SRELeadBridgeTests`'s `FakeBridgeTerminal`. `TabModel`
/// conforms below by delegating to its own `terminal`.
protocol SRELeadBridgeTerminal: AnyObject {
    /// Type `text` into the terminal, exactly like `TerminalView.send(txt:)`.
    func sendCommand(_ text: String)

    /// The terminal's entire current buffer, one entry per row - the same
    /// shape `Terminal.getBufferAsData()` already returns, just split into
    /// lines. Called repeatedly while polling, so this should be cheap.
    func currentBufferLines() -> [String]

    /// The most recent moment the captain (a real keystroke or paste, never
    /// this bridge's own `sendCommand`) touched this terminal, or `nil` if
    /// never. Used to refuse a request when the tab looks actively in use,
    /// and to detect (after the fact) that the captain typed into the tab
    /// while an injected command was still running.
    var lastUserActivity: Date? { get }
}

/// Bridges one dedicated host page's SRE Lead session to its primary
/// interactive tab. Owns a repeating main-thread timer that polls
/// `bridgeDir` for request files - a plain poll, not a `DispatchSource`
/// file-system-object watcher, since every step of handling a request
/// (`sendCommand`, reading the terminal buffer) must happen on the main
/// thread anyway (AppKit/SwiftTerm), and this codebase already favors a
/// `Timer` for this shape of "check on something periodically" work
/// (`UpdatesController`'s self-ticking relative-time label).
final class SRELeadBridge {
    /// The literal prefix of every command this bridge injects
    /// (`beginProcessing`'s `"echo \(startMarker); ..."`), before shell
    /// history ever sees it. `TerminalBlockTracker` (`fm/cockpit-block-view-
    /// terminal`) checks a closed block's command text against this to hide
    /// the bridge's own sentinel-wrapped kubectl commands from block view -
    /// they are internal plumbing, not something the captain typed, and
    /// showing them as an ordinary-looking block would be confusing. Kept
    /// here (not duplicated as a separate literal in `TerminalBlockTracker`)
    /// so the two files can't silently drift apart if this bridge's marker
    /// format ever changes.
    static let sentinelCommandPrefix = "echo SRE_LEAD_START_"

    private let bridgeDir: URL
    private weak var target: SRELeadBridgeTerminal?
    private var timer: Timer?
    private var inFlight: InFlight?

    /// A request is refused as "busy" if the captain touched the tab within
    /// this many seconds before injection. An instance property (not a
    /// `static let`), defaulted below, so `FirstmateCockpitTests` can pass a
    /// much smaller value and keep the test suite fast rather than sleeping
    /// through the production window.
    let userActivityQuietWindow: TimeInterval

    /// Stays comfortably under `sre_kubectl_mcp.py`'s own `_TIMEOUT_SECONDS`
    /// (30s) so a timeout here always produces a real response file before
    /// Python's own poll gives up. Also overridable for tests, for the same
    /// reason as `userActivityQuietWindow`.
    let commandTimeout: TimeInterval

    /// How often to poll both for new request files and for the in-flight
    /// command's end marker.
    static let pollInterval: TimeInterval = 0.2

    private struct InFlight {
        let id: String
        let startMarker: String
        let endMarker: String
        let startedAt: Date
        /// Only lines at or beyond this index (in the buffer snapshot taken
        /// right before injection) are ever searched - so a marker string
        /// that happens to appear earlier in scrollback (an unrelated prior
        /// run, or the captain's own typing) can never be mistaken for this
        /// request's own output.
        let searchFromLine: Int
    }

    init(
        bridgeDir: URL, target: SRELeadBridgeTerminal,
        userActivityQuietWindow: TimeInterval = 0.5, commandTimeout: TimeInterval = 25
    ) {
        self.bridgeDir = bridgeDir
        self.target = target
        self.userActivityQuietWindow = userActivityQuietWindow
        self.commandTimeout = commandTimeout
    }

    func start() {
        stop()
        let t = Timer.scheduledTimer(withTimeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        inFlight = nil
    }

    // MARK: Polling

    func tick() {
        if let current = inFlight {
            checkInFlight(current)
        }
        if inFlight != nil {
            // Still busy (either it was already running, or `checkInFlight`
            // just started it) - any other request that shows up while busy
            // is refused outright rather than silently queued, so a captain
            // (or a parallel SRE Lead subagent) calling this tool twice at
            // once gets a clear "busy" error instead of a long, surprising
            // wait or, worse, two commands' output getting interleaved.
            rejectAllPending(reason: "SRE Lead's shared terminal is already running another command - try again once it finishes.")
            return
        }
        guard let request = nextPendingRequest() else { return }
        beginProcessing(request)
    }

    private struct PendingRequest { let id: String; let command: String }

    /// Claims (reads, then deletes) the oldest waiting request file, if any.
    /// Deleting immediately on claim means a request is never processed
    /// twice, even if a tick runs slowly.
    private func nextPendingRequest() -> PendingRequest? {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: bridgeDir, includingPropertiesForKeys: nil) else {
            return nil
        }
        let requestFiles = files
            .filter { $0.lastPathComponent.hasPrefix("request-") && $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard let file = requestFiles.first else { return nil }

        let id = String(file.lastPathComponent.dropFirst("request-".count).dropLast(".json".count))
        guard let data = try? Data(contentsOf: file) else {
            try? fm.removeItem(at: file)
            return nil
        }
        try? fm.removeItem(at: file)
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let command = obj["command"] as? String, !command.isEmpty else {
            return nil
        }
        return PendingRequest(id: id, command: command)
    }

    private func rejectAllPending(reason: String) {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: bridgeDir, includingPropertiesForKeys: nil) else { return }
        for file in files where file.lastPathComponent.hasPrefix("request-") && file.pathExtension == "json" {
            let id = String(file.lastPathComponent.dropFirst("request-".count).dropLast(".json".count))
            try? fm.removeItem(at: file)
            writeResponse(id: id, ok: false, error: reason)
        }
    }

    // MARK: Starting a command

    private func beginProcessing(_ request: PendingRequest) {
        guard let target else {
            writeResponse(id: request.id, ok: false, error: "The connected host's interactive terminal tab is no longer available - reconnect the host first.")
            return
        }
        let now = Date()
        if let last = target.lastUserActivity, now.timeIntervalSince(last) < userActivityQuietWindow {
            writeResponse(id: request.id, ok: false, error: "The connected terminal tab looks like it's actively being used right now - try again in a moment.")
            return
        }

        let unique = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let startMarker = "SRE_LEAD_START_\(unique)"
        let endMarker = "SRE_LEAD_END_\(unique)"
        let searchFromLine = target.currentBufferLines().count

        target.sendCommand("echo \(startMarker); \(request.command); echo \(endMarker)\n")
        inFlight = InFlight(
            id: request.id, startMarker: startMarker, endMarker: endMarker,
            startedAt: now, searchFromLine: searchFromLine
        )
    }

    // MARK: Watching the in-flight command

    private func checkInFlight(_ current: InFlight) {
        guard let target else {
            writeResponse(id: current.id, ok: false, error: "The connected host's interactive terminal tab is no longer available - reconnect the host first.")
            inFlight = nil
            return
        }

        if Date().timeIntervalSince(current.startedAt) > commandTimeout {
            writeResponse(id: current.id, ok: false, error: "Timed out waiting for the command to finish in the shared terminal.")
            inFlight = nil
            return
        }

        let allLines = target.currentBufferLines()
        guard allLines.count > current.searchFromLine else { return }
        let newLines = Array(allLines[current.searchFromLine...])

        guard let endIdx = newLines.firstIndex(where: { isMarkerLine($0, marker: current.endMarker) }) else {
            return // still running
        }
        guard let startIdx = newLines[..<endIdx].firstIndex(where: { isMarkerLine($0, marker: current.startMarker) }) else {
            writeResponse(id: current.id, ok: false, error: "Could not find the command's own output markers in the terminal - the tab may have changed unexpectedly.")
            inFlight = nil
            return
        }

        // Concurrency guard: a real keystroke/paste from the captain at any
        // point after injection means the shared shell's input/output could
        // have interleaved with ours - discard rather than risk returning
        // corrupted output.
        if let last = target.lastUserActivity, last > current.startedAt {
            writeResponse(id: current.id, ok: false, error: "The terminal received input from the captain while this command was running, so its output can't be trusted - discarded. Try again.")
            inFlight = nil
            return
        }

        let output = newLines[(startIdx + 1)..<endIdx].joined(separator: "\n")
        writeResponse(id: current.id, ok: true, output: output)
        inFlight = nil
    }

    /// A line counts as "the marker itself" only when it is *exactly* the
    /// marker (after trimming whitespace) - the terminal's echo of the typed
    /// input line (`"echo <marker>; <command>; echo <otherMarker>"`) contains
    /// the marker as a substring but is never equal to it, so this can't
    /// mistake the echoed command for the marker's own output.
    private func isMarkerLine(_ line: String, marker: String) -> Bool {
        line.trimmingCharacters(in: .whitespaces) == marker
    }

    // MARK: Responses

    private func writeResponse(id: String, ok: Bool, output: String? = nil, error: String? = nil) {
        var obj: [String: Any] = ["ok": ok]
        if let output { obj["output"] = output }
        if let error { obj["error"] = error }
        guard let data = try? JSONSerialization.data(withJSONObject: obj) else { return }

        let fm = FileManager.default
        let tmp = bridgeDir.appendingPathComponent("response-\(id).json.tmp")
        let final = bridgeDir.appendingPathComponent("response-\(id).json")
        guard (try? data.write(to: tmp)) != nil else { return }
        try? fm.removeItem(at: final)
        try? fm.moveItem(at: tmp, to: final)
    }
}

// MARK: - TabModel conformance

extension TabModel: SRELeadBridgeTerminal {
    func sendCommand(_ text: String) {
        terminal.send(txt: text)
    }

    func currentBufferLines() -> [String] {
        guard let data = terminal.terminal?.getBufferAsData() else { return [] }
        let text = String(data: data, encoding: .utf8) ?? ""
        return text.components(separatedBy: "\n")
    }

    var lastUserActivity: Date? { terminal.lastUserActivity }
}
