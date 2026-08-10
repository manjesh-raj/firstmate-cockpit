// Manjesh Grand Line - native macOS app.
//
// The herdr-backed Mirror tab, built alongside `TmuxMirror` for a fleet whose
// resolved backend (`FirstmateBackend.resolve()`) is herdr rather than tmux
// (cockpit-mirror-herdr-aware). `TmuxMirror` stays byte-identical - this is a
// separate type, not a refactor of it.
//
// **Not full parity with `TmuxMirror`, and said so plainly (per the task
// brief) rather than glossed over.** `TmuxMirror` works because tmux offers a
// *grouped session*: a second, independently-sized live attach onto the same
// windows, so the cockpit's view never disturbs the captain's real terminal,
// and `tmux attach-session` renders just the target pane with no extra
// chrome. herdr has no equivalent primitive. Investigated directly against a
// real herdr 0.8.0 install for this task: `herdr` / `herdr session attach
// <name>` is a full-app TUI client (its own tab bar and workspace chrome,
// confirmed via `herdr --help`'s usage forms - there is no bare single-pane
// attach flag), and `herdr pane read <pane> --source recent` is a bounded
// snapshot, not a stream. Embedding the former would render herdr's own UI
// chrome into what is supposed to be a clean pane mirror (wrong result, and
// the earlier `cockpit-herdr-scout` scout already ruled this out for the same
// reason); there is nothing to "attach" for the latter. So this ships the
// scout's identified fallback (its Piece C, Option C1): a plain child process
// that polls `herdr pane read --format ansi` on a short interval and redraws,
// piped through the exact same `LocalProcessTerminalView.startProcess` PTY
// path `TmuxMirror`'s live attach uses. That makes it look identical to the
// tmux mirror in the tab (same terminal view, same theme, same font), but it
// is a periodic snapshot, not a live byte stream - there is a real (~1.2s)
// latency between a keystroke landing in the real session and this view
// showing it, and, being read-only, nothing typed into this tab's terminal
// reaches the mirrored pane (there is no herdr primitive to send keystrokes
// through a "grouped" view either - `herdr pane send-text`/`send-keys` write
// directly to the pane, indistinguishable from typing there for real, which
// is not what a passive mirror should do). This is the closest honest
// approximation herdr's current primitives allow, not a drop-in replacement
// for a real live terminal.
//
// Target resolution: unlike a tmux session (which the captain names
// directly, e.g. `firstmate`), a herdr session (`default` on this captain's
// fleet, confirmed live) holds several panes, and firstmate's own crew-task
// panes are told apart from its *own* interactive pane only by which one's
// working directory is the firstmate home itself (`fm_backend_herdr_session`
// resolves the SESSION, not a specific pane - there is no equivalent "which
// pane is firstmate itself" helper in `bin/backends/herdr.sh` to defer to).
// `firstMatePane` below applies that same "cwd is the home" heuristic
// `TmuxMirror.SessionInfo`'s `isHome` flag already uses for tmux, preferring
// an EXACT match against `FirstmateHome.root` (the primary supervisor's own
// pane, not a crew task's, which normally sits one or more directories below
// it or in a worktree elsewhere entirely) over a same-session fallback. Like
// `TmuxMirror`'s own documented "Known follow-up" (picking whatever window a
// session's `select-window` was never told to pin), this is a best-effort
// default, not a guarantee - `mirrorTarget()`'s `<session>#<pane-id>` pin
// syntax exists for exactly the cases it gets wrong.

import Foundation

/// A live herdr-backed mirror: which session and pane `attachArgs`' polling
/// loop reads on every cycle. Created via `setUp`, attached by the Mirror
/// terminal exactly like `TmuxMirror`, torn down (a no-op - see `tearDown`)
/// on disconnect.
struct HerdrMirror {
    /// Absolute path to the `herdr` binary.
    let herdrPath: String
    /// The herdr session this mirror reads from (e.g. `default`).
    let session: String
    /// The specific pane within `session` this mirror reads (e.g. `wA:p1`).
    let pane: String

    /// Executable + args for `LocalProcessTerminalView.startProcess` to
    /// attach this mirror - a plain shell loop, not a `herdr` invocation
    /// directly, so it can clear-and-redraw between polls.
    var attachExecutable: String { "/bin/bash" }
    var attachArgs: [String] { ["-c", Self.pollScript(herdrPath: herdrPath, session: session, pane: pane)] }

    // MARK: Setup / teardown

    /// Resolve `target` (`<session>` or `<session>#<pane-id>`) against the
    /// live herdr server, confirming the session is actually running and
    /// finding a pane to read when none is pinned explicitly. Mirrors
    /// `TmuxMirror.setUp`'s shape: a `Result` so the caller can show a
    /// human-readable failure in the terminal rather than crash.
    static func setUp(target: String) -> Result<HerdrMirror, MirrorSetupError> {
        guard let herdr = resolveHerdr() else {
            return .failure(MirrorSetupError(message: "herdr not found on PATH (looked in Homebrew/usr paths)."))
        }
        let env = childEnvironmentDict()
        let (session, pinnedPane) = splitTarget(target)

        let listed = run(herdr, ["session", "list", "--json"], session: session, env: env)
        guard listed.status == 0, sessionIsRunning(session, json: listed.stdout) else {
            let detail = listed.stderr.isEmpty ? "no running herdr session named '\(session)'" : listed.stderr
            return .failure(MirrorSetupError(message: "Cannot mirror '\(target)': \(detail)"))
        }

        if let pinnedPane, !pinnedPane.isEmpty {
            return .success(HerdrMirror(herdrPath: herdr, session: session, pane: pinnedPane))
        }
        guard let discovered = firstMatePane(herdr: herdr, session: session, env: env) else {
            return .failure(MirrorSetupError(message: "Cannot mirror '\(target)': no pane in that session has a working directory under the firstmate home. Pin one explicitly with '\(session)#<pane-id>'."))
        }
        return .success(HerdrMirror(herdrPath: herdr, session: session, pane: discovered))
    }

    /// Nothing persistent to tear down. Unlike `TmuxMirror`'s grouped
    /// session (a real, independently-named resource on the tmux server that
    /// outlives the attaching client until explicitly killed), this mirror's
    /// only "session" is the polling loop itself - a plain child of this
    /// tab's own PTY. Every call site already terminates that PTY
    /// (`tab.terminal.terminate()`/process exit) before or alongside calling
    /// this, which ends the loop; there is no separate herdr-side resource
    /// this mirror created that would otherwise leak. Kept as a method (not
    /// simply omitted) so call sites read the same regardless of which
    /// mirror kind a tab holds.
    func tearDown() {}

    // MARK: Helpers

    /// `'default'` -> `("default", nil)`; `'default#wA:p1'` -> `("default",
    /// "wA:p1")`. `#`, not `:`, separates session from pane - a herdr pane id
    /// (`wA:p1`) already contains a colon, so splitting on the first colon
    /// the way `TmuxMirror.splitTarget` does for `session:window` would cut
    /// the pane id in half.
    static func splitTarget(_ target: String) -> (session: String, pane: String?) {
        guard let hash = target.firstIndex(of: "#") else { return (target, nil) }
        let session = String(target[..<hash])
        let pane = String(target[target.index(after: hash)...])
        return (session, pane.isEmpty ? nil : pane)
    }

    /// The captain's own interactive pane within `session`: an exact
    /// working-directory match against the firstmate home, preferring the
    /// focused pane among ties, and falling back to a same-session,
    /// home-PREFIXED pane (a crew task's cwd, e.g. `<home>/projects/<repo>`)
    /// only when no exact match exists - closer to "some real firstmate
    /// activity" than refusing outright, but the exact-match case is what
    /// this is actually built to find.
    static func firstMatePane(herdr: String, session: String, env: [String: String]) -> String? {
        let result = run(herdr, ["pane", "list"], session: session, env: env)
        guard result.status == 0,
              let data = result.stdout.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let inner = obj["result"] as? [String: Any],
              let panes = inner["panes"] as? [[String: Any]] else {
            return nil
        }
        let home = FirstmateHome.root.path
        var exactMatches: [(pane: String, focused: Bool)] = []
        var prefixMatches: [String] = []
        for p in panes {
            guard let id = p["pane_id"] as? String, let cwd = p["cwd"] as? String else { continue }
            if cwd == home {
                exactMatches.append((id, (p["focused"] as? Bool) ?? false))
            } else if cwd.hasPrefix(home + "/") {
                prefixMatches.append(id)
            }
        }
        if let focused = exactMatches.first(where: { $0.focused }) { return focused.pane }
        if let first = exactMatches.first { return first.pane }
        return prefixMatches.first
    }

    /// `true` when `session list --json`'s output names `sessionName` as
    /// currently `running`.
    static func sessionIsRunning(_ sessionName: String, json: String) -> Bool {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sessions = obj["sessions"] as? [[String: Any]] else {
            return false
        }
        return sessions.contains { ($0["name"] as? String) == sessionName && (($0["running"] as? Bool) ?? false) }
    }

    /// A `bash -c` script: clear the screen, print a read-only banner, read
    /// the pane, sleep, repeat. `--lines 200` (never smaller) works around a
    /// verified herdr CLI quirk (`bin/backends/herdr.sh`'s
    /// `fm_backend_herdr_capture_ansi` comment): `pane read --source recent
    /// --lines N` returns completely empty output when `N` is smaller than
    /// the pane's current viewport height, rather than clamping - so a small,
    /// "just fill one screen" request can silently read as nothing at all.
    /// `HERDR_SESSION`/`--session` are both set on the `herdr` call, mirroring
    /// `bin/backends/herdr.sh`'s own `fm_backend_herdr_cli` convention
    /// (verified there: the env var alone is not reliably honored once
    /// another herdr server is bound on the machine).
    static func pollScript(herdrPath: String, session: String, pane: String) -> String {
        let herdrQ = shellQuote(herdrPath)
        let sessionQ = shellQuote(session)
        let paneQ = shellQuote(pane)
        return """
        trap 'exit 0' INT TERM
        printf '\\033[2m[herdr mirror] read-only, ~1.2s-latency snapshot of pane %s in session %s - not a live attach\\033[0m\\r\\n' \(paneQ) \(sessionQ)
        while true; do
          printf '\\033[2J\\033[H'
          HERDR_SESSION=\(sessionQ) \(herdrQ) pane read \(paneQ) --source recent --lines 200 --format ansi --session \(sessionQ) 2>&1
          sleep 1.2
        done
        """
    }

    /// Single-quote `s` for embedding as one literal token in `pollScript`'s
    /// generated shell script, mirroring `SRELead.swift`'s own private
    /// `shellQuote` helper (kept separate rather than shared, matching that
    /// file's one-helper-per-type convention).
    private static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Find the `herdr` binary. Mirrors `TmuxMirror.resolveTmux()` exactly -
    /// a Finder-launched GUI app inherits a minimal PATH, so search `$PATH`
    /// first, then the usual Homebrew/system locations.
    static func resolveHerdr() -> String? {
        let fm = FileManager.default
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            for dir in path.split(separator: ":") {
                let candidate = "\(dir)/herdr"
                if fm.isExecutableFile(atPath: candidate) { return candidate }
            }
        }
        for candidate in ["/opt/homebrew/bin/herdr", "/usr/local/bin/herdr", "/usr/bin/herdr"] {
            if fm.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    /// Run a herdr command scoped to `session`, appending the trailing
    /// `--session <name>` flag and setting `HERDR_SESSION` in the child
    /// environment - `bin/backends/herdr.sh`'s verified-reliable targeting
    /// convention (see `fm_backend_herdr_cli`'s own comment).
    @discardableResult
    static func run(_ executable: String, _ args: [String], session: String, env: [String: String]) -> (status: Int32, stdout: String, stderr: String) {
        var scopedEnv = env
        scopedEnv["HERDR_SESSION"] = session
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: executable)
        proc.arguments = args + ["--session", session]
        proc.environment = scopedEnv
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
