// Manjesh Grand Line - native macOS app.
//
// The herdr-backed tab (named "Herdr" in the tab bar, NOT "Mirror" - see
// below), built alongside `TmuxMirror`'s "Mirror" tab for a fleet whose
// resolved backend (`FirstmateBackend.resolve()`) is herdr rather than tmux
// (cockpit-mirror-herdr-aware). `TmuxMirror` stays byte-identical - this is a
// separate type, not a refactor of it.
//
// **fm/cockpit-mirror-herdr-real-attach replaced the original polling
// snapshot with a real `herdr session attach` client**, after the captain
// compared the shipped v1 (a read-only `herdr pane read` loop, no sidebar, no
// input) against the real herdr TUI and asked for the genuine thing. The
// original polling approach existed specifically because of an open question
// about whether a second concurrent `herdr session attach` disturbs an
// already-attached client - this task answered that question live before
// changing anything, rather than assuming either way:
//
// **Live finding (this task, herdr 0.8.0):** a second `herdr session attach
// <name>` (and `herdr --session <name>`) against a session that already has
// one attached client is safe - exactly like tmux's grouped multi-attach.
// Verified against a throwaway, disposable herdr session created solely for
// this test (`fm_test_attach_verify`, stopped and deleted afterward) rather
// than the machine's real, live-in-use `default` session, to avoid any risk
// to real concurrent work: started one client, confirmed it rendering and
// responsive (`herdr pane send-text`/`pane read` round-tripped through it),
// then started a second client against the same session name. Both client
// processes stayed alive and attached with no errors, disconnects, or
// visible disruption to the first; `herdr pane list` against that session
// the whole time reported a single shared pane, confirming both clients were
// viewing/driving the same underlying session state rather than forking it -
// the same shape as tmux's grouped session. One incidental finding along the
// way: launching `herdr session attach`/`herdr --session` from a shell that
// already has `HERDR_ENV=1` set (i.e. a shell herdr itself spawned) is
// refused outright ("nested herdr is disabled by default") - irrelevant to
// two independent GUI-launched clients, but see `childEnvironmentDict()` in
// `TerminalEnvironment.swift`, which now strips `HERDR_ENV`/`HERDR_*` from a
// tab's child environment for exactly this reason (mirroring why `TMUX` is
// already stripped there).
//
// With concurrent attach confirmed safe, this now ships the captain's own
// simpler framing: no bespoke mirroring/rendering mechanism at all, and no
// "Mirror" naming either - it isn't a mirror of anything, it's the genuine
// herdr client. This tab is just `herdr session attach <session>` run
// through the exact same `LocalProcessTerminalView.startProcess` PTY path
// every other tab (shell, ssh, tmux mirror) already uses -
// `ConsoleController.connectMirror` barely needed to change, since it
// already just reads `attachExecutable`/`attachArgs` off whichever mirror
// kind it got and hands them to `startProcess`; `TabLaunch.defaultName`
// picks "herdr" instead of "Mirror" for this backend specifically (the tmux
// case is untouched and still says "Mirror"). herdr's own client renders its
// own real UI (sidebar, tab bar, full interactivity) with zero custom
// rendering code on this app's side. The former polling implementation (a
// generated `bash -c` loop calling `herdr pane read --format ansi` on a
// ~1.2s interval, plus the pane-discovery heuristic it needed to pick which
// pane to read) is deleted entirely - there's nothing left to poll.
//
// Target resolution is simpler than it used to be, too: earlier, a herdr
// session (`default` on this captain's fleet, confirmed live) held several
// panes and this had to guess which one was firstmate's own interactive
// pane. That guess doesn't exist anymore, because a real attach shows the
// WHOLE session (every space/agent in its own sidebar entry, like the
// captain's screenshot), not one pane's text - so `HerdrMirror` no longer
// needs (or has) any pane-discovery logic, and the `<session>#<pane-id>` pin
// syntax `mirrorTarget()` used to document is gone with it.
// `FirstmateBackend.herdrSessionName()` (unchanged) still resolves which
// session name to attach, and `ConsoleController.connectMirror` launches it
// with its cwd set to `FirstmateHome.root` (the captain's explicit call),
// not the general shell-tab cwd preference.

import Foundation

/// A real, interactive `herdr session attach` client - the "Herdr" tab.
/// Created via `setUp` (which only confirms the session exists - it does not
/// create or attach anything itself), attached by the console's tab
/// terminal exactly like `TmuxMirror`, torn down (a no-op - see `tearDown`)
/// on disconnect, since ending the child process IS detaching this client;
/// unlike `TmuxMirror`'s grouped session, there's no separate server-side
/// resource this mirror creates that would otherwise leak.
struct HerdrMirror {
    /// Absolute path to the `herdr` binary.
    let herdrPath: String
    /// The herdr session this mirror attaches to (e.g. `default`).
    let session: String

    /// Executable + args for `LocalProcessTerminalView.startProcess` to
    /// attach this mirror - the real `herdr session attach <session>` a
    /// captain would type themselves, so herdr's own client renders its own
    /// real UI (sidebar included) with zero custom rendering code here.
    var attachExecutable: String { herdrPath }
    var attachArgs: [String] { ["session", "attach", session] }

    // MARK: Setup / teardown

    /// Confirm `target` (a plain session name - see this file's header
    /// comment for why there's no pane-pin syntax anymore) names a live,
    /// running herdr session before attaching to it, so a genuinely missing
    /// session still shows the same clear in-terminal error it always has,
    /// rather than regressing into whatever raw error `herdr session attach`
    /// itself would print for a nonexistent name. Mirrors `TmuxMirror.setUp`'s
    /// shape: a `Result` so the caller can show a human-readable failure in
    /// the terminal rather than crash.
    static func setUp(target: String) -> Result<HerdrMirror, MirrorSetupError> {
        guard let herdr = resolveHerdr() else {
            return .failure(MirrorSetupError(message: "herdr not found on PATH (looked in Homebrew/usr paths)."))
        }
        let env = childEnvironmentDict()
        let listed = run(herdr, ["session", "list", "--json"], session: target, env: env)
        guard listed.status == 0, sessionIsRunning(target, json: listed.stdout) else {
            let detail = listed.stderr.isEmpty ? "no running herdr session named '\(target)'" : listed.stderr
            return .failure(MirrorSetupError(message: "Cannot mirror '\(target)': \(detail)"))
        }
        return .success(HerdrMirror(herdrPath: herdr, session: target))
    }

    /// Nothing persistent to tear down. Ending the attached `herdr session
    /// attach` child process (every call site already terminates this tab's
    /// PTY before or alongside calling this) IS detaching this client from
    /// the session - herdr's own server keeps the session itself running for
    /// any other attached client, exactly like closing one tmux client
    /// doesn't kill a grouped session. Kept as a method (not simply omitted)
    /// so call sites read the same regardless of which mirror kind a tab
    /// holds.
    func tearDown() {}

    // MARK: Helpers

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
    /// convention (see `fm_backend_herdr_cli`'s own comment). Used for the
    /// `session list --json` existence check above and by
    /// `FirstmateBackend.hasLiveHerdrSession()`; the actual attach itself
    /// (`attachArgs`) is a plain positional-argument invocation, not routed
    /// through this helper.
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
