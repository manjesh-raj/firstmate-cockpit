// Firstmate Cockpit - native macOS app.
//
// The tmux grouped-session lifecycle for the Mirror tab, ported to Swift from
// `backend/terminal.py` (`_setup_group` / `_teardown_group`). This keeps Phase 2
// self-contained: the console attaches a live view of the first mate's tmux
// session without the Python backend running (backend integration is Phase 3).
//
// Why a *grouped* session and not a plain `tmux attach`: a group shares the same
// windows as the real session but keeps its own size and active window, so the
// cockpit view never resizes the captain's real terminal. A per-connection
// suffix in the group name keeps two cockpit instances from fighting over one
// shared mirror. This mirrors terminal.py exactly; only the transport differs
// (SwiftTerm forks the PTY in-process instead of a websocket byte-pump).

import Foundation

/// A human-readable reason the mirror could not be set up (no tmux, no such
/// session, tmux refused to create the group). Carried so the console can show
/// it in the terminal rather than crash.
struct MirrorSetupError: Error {
    let message: String
}

/// A live grouped-session mirror of a first-mate tmux target. Created via
/// `setUp`, attached by the Mirror terminal, and torn down on disconnect.
struct TmuxMirror {
    /// Absolute path to the `tmux` binary.
    let tmuxPath: String
    /// The grouped session created for this connection (`cockpit_<sess>_<pid>_<hex>`).
    let group: String

    /// Args for `LocalProcessTerminalView.startProcess` to attach this mirror.
    var attachArgs: [String] { ["attach-session", "-t", group] }

    // MARK: Setup / teardown

    /// Build the grouped session for `target` (e.g. `firstmate` or `firstmate:1`).
    /// Returns the mirror on success, or a human-readable error string on failure
    /// (no tmux, no such session, etc.) so the caller can show it in the terminal
    /// rather than crash. Mirrors `_setup_group` in `backend/terminal.py`.
    static func setUp(target: String) -> Result<TmuxMirror, MirrorSetupError> {
        guard let tmux = resolveTmux() else {
            return .failure(MirrorSetupError(message: "tmux not found on PATH (looked in Homebrew/usr paths)."))
        }
        let env = childEnvironmentDict()
        let (session, window) = splitTarget(target)

        // Does the real session even exist? Give a clear message if not.
        let has = run(tmux, ["has-session", "-t", session], env: env)
        if has.status != 0 {
            let detail = has.stderr.isEmpty ? "no tmux session '\(session)'" : has.stderr
            return .failure(MirrorSetupError(message: "Cannot mirror '\(target)': \(detail)"))
        }

        let group = groupName(session)
        // Clear any stale group of the same name (ignore errors), then create ours.
        _ = run(tmux, ["kill-session", "-t", group], env: env)
        let created = run(tmux, ["new-session", "-d", "-s", group, "-t", session], env: env)
        if created.status != 0 {
            let detail = created.stderr.isEmpty ? "could not create grouped session" : created.stderr
            return .failure(MirrorSetupError(message: detail))
        }
        if let window {
            _ = run(tmux, ["select-window", "-t", "\(group):\(window)"], env: env)
        }
        // This view's size follows its own client (not the smallest attached).
        _ = run(tmux, ["set-option", "-t", group, "window-size", "latest"], env: env)
        // Hide tmux's own status bar in the embedded view - show just Claude Code.
        // (per-session option; the captain's real session is unaffected.)
        _ = run(tmux, ["set-option", "-t", group, "status", "off"], env: env)

        return .success(TmuxMirror(tmuxPath: tmux, group: group))
    }

    /// Kill the grouped session. Safe to call more than once. Mirrors
    /// `_teardown_group`.
    func tearDown() {
        _ = TmuxMirror.run(tmuxPath, ["kill-session", "-t", group], env: childEnvironmentDict())
    }

    // MARK: Helpers

    /// `'firstmate:1.1'` -> `("firstmate", "1")`. Window optional. Mirrors
    /// `_split_target` in `backend/terminal.py`.
    static func splitTarget(_ target: String) -> (session: String, window: String?) {
        guard let colon = target.firstIndex(of: ":") else { return (target, nil) }
        let session = String(target[..<colon])
        let rest = String(target[target.index(after: colon)...])
        let window = rest.split(separator: ".", maxSplits: 1).first.map(String.init)
        return (session, (window?.isEmpty == false) ? window : nil)
    }

    /// `cockpit_<safe-session>_<pid>_<hex>`. Mirrors `_group_name`, including the
    /// per-connection suffix that stops two cockpit instances colliding.
    static func groupName(_ session: String) -> String {
        let safe = String(session.map { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" ? $0 : "_" })
        let pid = ProcessInfo.processInfo.processIdentifier
        let hex = String(format: "%04x", UInt16.random(in: 0...UInt16.max))
        return "cockpit_\(safe)_\(pid)_\(hex)"
    }

    /// Find the `tmux` binary. A Finder-launched GUI app inherits a minimal PATH,
    /// so search `$PATH` first, then the usual Homebrew/system locations.
    static func resolveTmux() -> String? {
        let fm = FileManager.default
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            for dir in path.split(separator: ":") {
                let candidate = "\(dir)/tmux"
                if fm.isExecutableFile(atPath: candidate) { return candidate }
            }
        }
        for candidate in ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux"] {
            if fm.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    /// Run a tmux command and capture its result. The Swift analogue of the
    /// `_tmux(...)` `subprocess.run` helper in `backend/terminal.py`.
    @discardableResult
    static func run(_ executable: String, _ args: [String], env: [String: String]) -> (status: Int32, stdout: String, stderr: String) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: executable)
        proc.arguments = args
        proc.environment = env
        let out = Pipe(), err = Pipe()
        proc.standardOutput = out
        proc.standardError = err
        do {
            try proc.run()
        } catch {
            return (-1, "", "\(error.localizedDescription)")
        }
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        return (
            proc.terminationStatus,
            String(data: outData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        )
    }
}
