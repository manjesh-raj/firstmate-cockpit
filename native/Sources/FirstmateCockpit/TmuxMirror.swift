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
//
// Known follow-up (captain report, not fixed here): when `target` names only a
// session (e.g. the default `firstmate`, no `:<window>`), `setUp` below never
// calls `select-window`, so the new group's active window is whatever window
// happened to be active in the real session at the instant `new-session -t
// session` ran - it is not necessarily the window running the first-mate
// agent pane. If that session's other windows include herdr's own TUI (a
// session-list/dashboard view), the mirror can end up showing that chrome
// instead of a clean agent pane. This file has no visibility into how herdr
// lays out its tmux windows, so it cannot reliably auto-pick "the agent
// window" here. Today's workaround: set the mirror target to `firstmate:<N>`
// (Settings > General > Mirror target, or `FM_MIRROR_TARGET`) to pin the exact
// window; a real fix would need either a herdr-side convention for which
// window/pane to mirror, or a way to identify the agent pane by content.

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

    /// One discovered tmux pane - the Settings > Connection session picker's
    /// card data (Fix 3), mirroring `scripts.tmux_panes()` / `/api/targets`.
    struct SessionInfo {
        let target: String
        let session: String
        let command: String
        let path: String
        let isHome: Bool
    }

    /// List every tmux pane across every session, tagging ones whose cwd is
    /// inside the firstmate home (the "home" badge) and sorting home panes
    /// first - mirrors `backend/app.py`'s `_scan_candidates`. Returns `nil`
    /// when no tmux server is reachable. Internal `cockpit_*` mirror groups
    /// are excluded, same as the web app.
    static func listSessions() -> [SessionInfo]? {
        guard let tmux = resolveTmux() else { return nil }
        let env = childEnvironmentDict()
        let sep = "|FM|"
        let fmt = ["#{session_name}", "#{window_index}", "#{pane_index}", "#{pane_current_command}", "#{pane_current_path}"].joined(separator: sep)
        let result = run(tmux, ["list-panes", "-a", "-F", fmt], env: env)
        guard result.status == 0 else { return nil }
        let home = FirstmateHome.root.path
        var out: [SessionInfo] = []
        for line in result.stdout.split(separator: "\n") {
            let parts = line.components(separatedBy: sep)
            guard parts.count >= 5 else { continue }
            let session = parts[0]
            if session.hasPrefix("cockpit_") { continue }
            let path = parts[4]
            let isHome = path == home || path.hasPrefix(home + "/")
            out.append(SessionInfo(target: "\(session):\(parts[1]).\(parts[2])", session: session, command: parts[3], path: path, isHome: isHome))
        }
        out.sort { a, b in
            if a.isHome != b.isHome { return a.isHome && !b.isHome }
            return a.target < b.target
        }
        return out
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
