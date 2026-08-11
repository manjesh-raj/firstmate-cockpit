// Manjesh Grand Line - native macOS app.
//
// "SRE Lead": a locally-run Claude Code session, spawned per connected host
// page, that investigates that host's Kubernetes cluster via one read-only
// `kubectl` MCP tool (`native/Scripts/sre_kubectl_mcp.py`).
//
// `fm/cockpit-sre-lead-shared-terminal` replaced this tool's whole execution
// model. It used to open a *second*, independent SSH connection to the same
// bastion (five attempts across PRs #70-73 plus an abandoned PTY
// investigation, all trying to make that second connection complete the same
// multi-hop, password-gated login chain the captain does by hand). The
// captain then confirmed a hard constraint: the real "EKS Preprod Bastion"
// host's EKS Bastion hop is username/password-gated *by policy* - no SSH key
// auth is possible there - so a second, fully-automated connection can never
// complete that chain; nothing can supply a password that isn't stored
// anywhere, by design. The tool now runs kubectl inside the *same* already-
// authenticated interactive tab the captain used to log all the way in, via
// `SRELeadBridge` - see that file for the request/response protocol and
// `sre_kubectl_mcp.py`'s module docstring for the Python side. This file no
// longer knows anything about `ssh` argv, saved keys, or a host's
// `startupSnippetID` - it only spawns the `claude` session and hands it the
// bridge directory `SRELeadBridge` also watches.
//
// Lifecycle mirrors `TmuxMirror` deliberately: `SRELead.setUp` creates a
// brand-new, uniquely-named detached tmux session running `claude` (not a
// grouped attach to an existing session - there is nothing to attach to yet,
// this session *is* the thing). The toolbar pane then mirrors that session
// exactly the way the Mirror tab mirrors the real `firstmate` session -
// `TmuxMirror.setUp(target: session.tmuxSessionName)` - so the rendering path
// is the same `CockpitTerminalView`/grouped-session machinery, not a new one.
// `tearDown()` kills the tmux session and removes the whole scratch directory
// (wrapper script, MCP config, and the bridge directory's own request/
// response files), mirroring `TmuxMirror.tearDown()`.
//
// Read-only enforcement is NOT here or in the persona prompt below - it is
// enforced by `sre_kubectl_mcp.py` itself refusing any verb outside
// `get`/`describe`/`logs`/`top`/`events` and validating every argument's
// character set before it ever reaches the shared terminal.

import Foundation

struct SRELeadSetupError: Error {
    let message: String
}

/// A live SRE Lead session: the detached tmux session running `claude`, the
/// bridge directory its kubectl tool and `SRELeadBridge` both watch, and the
/// scratch directory containing both so `tearDown()` can remove everything at
/// once.
struct SRELeadSession {
    /// The detached tmux session's name (mirrored into the pane via
    /// `TmuxMirror.setUp(target:)`, exactly like the Firstmate Mirror tab).
    let tmuxSessionName: String

    /// Where `sre_kubectl_mcp.py` writes `request-<id>.json` and
    /// `SRELeadBridge` writes `response-<id>.json` back - see
    /// `SRELeadBridge.swift`'s header for the full protocol.
    let bridgeDir: URL

    private let scratchDir: URL

    /// Kill the tmux session (best-effort, mirrors `TmuxMirror.tearDown`),
    /// then remove this spawn's scratch directory (wrapper script, MCP
    /// config, and the bridge directory - nothing lingers). Safe to call
    /// more than once.
    func tearDown() {
        let env = childEnvironmentDict()
        if let tmux = TmuxMirror.resolveTmux() {
            _ = TmuxMirror.run(tmux, ["kill-session", "-t", tmuxSessionName], env: env)
        }
        try? FileManager.default.removeItem(at: scratchDir)
    }

    fileprivate init(tmuxSessionName: String, scratchDir: URL, bridgeDir: URL) {
        self.tmuxSessionName = tmuxSessionName
        self.scratchDir = scratchDir
        self.bridgeDir = bridgeDir
    }
}

enum SRELead {

    /// The SRE Lead persona (design brief: "SRE Manager -> SRE Lead -> SRE
    /// Engineers", mirroring this whole Firstmate system's own supervision
    /// rule). Delegation to subagents for independent checks is Claude
    /// Code's own Task-tool capability - this prompt only asks for it, it
    /// does not implement any orchestration itself.
    private static let persona = """
    You are the SRE Lead for this Kubernetes cluster, reporting to the captain (the human at the other end of this session).

    You have exactly one tool: kubectl_readonly. It runs a read-only kubectl verb (get, describe, logs, top, or events) in the captain's own already-connected terminal tab for this host. Any other verb is rejected by the tool itself, not by you - do not try to work around it, and do not suggest destructive commands as something the captain could run manually instead. The tool can occasionally fail with a "busy" error if the captain is actively typing in that tab, or if another call is already running - just wait a moment and retry once.

    When an investigation has genuinely independent parts (e.g. "check pod events" + "check node capacity" + "check recent logs" for one incident), delegate each part to a subagent (the Task tool) so they run in parallel, then synthesize what they found into ONE finding. The captain talks to you, not to your subagents - never relay raw tool output or a subagent's full transcript verbatim; give a short, direct diagnosis and the evidence that supports it.

    Be concise. This is an incident-investigation chat, not a report.
    """

    /// Spawn a fresh SRE Lead session. Writes this spawn's MCP config and a
    /// wrapper script into a private scratch directory (avoids threading
    /// `claude`'s multi-line `--append-system-prompt` text through tmux's own
    /// shell-joining of its command argv - see the wrapper script comment
    /// below), creates the bridge directory the MCP config points the
    /// kubectl tool at, then creates the detached tmux session.
    static func setUp() -> Result<SRELeadSession, SRELeadSetupError> {
        guard let tmux = TmuxMirror.resolveTmux() else {
            return .failure(SRELeadSetupError(message: "tmux not found on PATH (looked in Homebrew/usr paths)."))
        }
        guard let claude = resolveClaude() else {
            return .failure(SRELeadSetupError(message: "claude CLI not found on PATH."))
        }
        guard let scriptPath = resolveKubectlScript() else {
            return .failure(SRELeadSetupError(message: "sre_kubectl_mcp.py not found (looked next to the app bundle and in the source tree)."))
        }
        let python = resolvePython3() ?? "/usr/bin/python3"

        let scratchDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fm-sre-lead-\(UUID().uuidString)", isDirectory: true)
        let bridgeDir = scratchDir.appendingPathComponent("bridge", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: scratchDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try FileManager.default.createDirectory(at: bridgeDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        } catch {
            return .failure(SRELeadSetupError(message: "could not create scratch directory: \(error.localizedDescription)"))
        }

        let mcpConfigPath = scratchDir.appendingPathComponent("mcp-config.json")
        let wrapperPath = scratchDir.appendingPathComponent("run-sre-lead.sh")
        let env = childEnvironmentDict()

        do {
            let mcpConfig: [String: Any] = [
                "mcpServers": [
                    "sre-kubectl": [
                        "command": python,
                        "args": [scriptPath],
                        "env": ["SRE_LEAD_BRIDGE_DIR": bridgeDir.path],
                    ]
                ]
            ]
            try JSONSerialization.data(withJSONObject: mcpConfig, options: [.prettyPrinted])
                .write(to: mcpConfigPath)

            // A wrapper script, not a tmux command argv, because tmux joins a
            // multi-token `new-session` command with spaces and re-parses it
            // through the login shell - fine for simple commands, but the
            // persona prompt above contains spaces/newlines/quotes that would
            // otherwise need fragile re-escaping through that second shell
            // pass. `exec`ing a single, already-quoted script file sidesteps
            // that entirely: tmux gets one argv token (the script path), no
            // re-parsing of our own arguments happens anywhere.
            //
            // The explicit `export PATH` below is not redundant with the
            // `env:` passed to `TmuxMirror.run` further down, even though
            // both come from the same `childEnvironmentDict()` call: tmux
            // only captures its own global environment once, at the moment
            // its *server* process first starts, from whichever client
            // spawned it. A `new-session -d` against an already-running
            // server (e.g. a leftover from a previous SRE Lead spawn)
            // inherits that originally-captured environment, not this call's
            // `env:` dict, unless the session overrides it itself - so
            // without baking PATH into the script directly, `claude`'s own
            // SessionStart hooks (`gh-axi`, `lavish-axi`,
            // `chrome-devtools-axi`) can fail with "command not found" on
            // every session after the first, however different the server's
            // originally-captured PATH happens to be.
            let script = """
            #!/bin/bash
            export PATH=\(shellQuote(env["PATH"] ?? ""))
            exec \(shellQuote(claude)) \\
              --mcp-config \(shellQuote(mcpConfigPath.path)) \\
              --strict-mcp-config \\
              --append-system-prompt \(shellQuote(persona)) \\
              --permission-mode bypassPermissions \\
              --allowedTools \(shellQuote("mcp__sre-kubectl__kubectl_readonly,Task,TodoWrite"))
            """
            try script.write(to: wrapperPath, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: wrapperPath.path)
        } catch {
            try? FileManager.default.removeItem(at: scratchDir)
            return .failure(SRELeadSetupError(message: "could not write session config: \(error.localizedDescription)"))
        }

        let sessionName = "fm_srelead_\(ProcessInfo.processInfo.processIdentifier)_\(String(format: "%04x", UInt16.random(in: 0...UInt16.max)))"
        guard let workingDir = resolveWorkingDirectory() else {
            try? FileManager.default.removeItem(at: scratchDir)
            return .failure(SRELeadSetupError(message: "could not create SRE Lead working directory."))
        }
        // `-c <workingDir>`, not the scratch dir the wrapper script itself
        // lives in (`ProcessInfo`'s default tmux start-directory would
        // otherwise be wherever the tmux *server* first started): a `claude`
        // session's first-ever launch in a directory it hasn't seen before
        // shows a one-time "do you trust this folder?" prompt - confirmed
        // live by launching the exact wrapper-script shape this method
        // generates in a fresh scratch dir. `workingDir` is a small,
        // dedicated app-owned folder rather than the captain's whole
        // `$HOME`, so that prompt (when it appears) scopes to something
        // purpose-built and empty instead of the captain's entire home
        // directory.
        let created = TmuxMirror.run(tmux, ["new-session", "-d", "-s", sessionName, "-c", workingDir.path, wrapperPath.path], env: env)
        if created.status != 0 {
            try? FileManager.default.removeItem(at: scratchDir)
            let detail = created.stderr.isEmpty ? "tmux could not start the session" : created.stderr
            return .failure(SRELeadSetupError(message: detail))
        }
        _ = TmuxMirror.run(tmux, ["set-option", "-t", sessionName, "status", "off"], env: env)

        return .success(SRELeadSession(tmuxSessionName: sessionName, scratchDir: scratchDir, bridgeDir: bridgeDir))
    }

    /// Single-quote `s` for embedding as one literal argv token in the
    /// generated `bash` wrapper script above.
    private static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// `~/Library/Application Support/FirstmateCockpit/sre-lead/`, created if
    /// missing - the same base directory `HostStore`/`SSHKeyStore` already
    /// use, and the same "create on demand" convention their `persist()`
    /// methods follow. This directory only needs to exist: it is never
    /// written into, it exists purely so `claude`'s one-time folder-trust
    /// prompt (when it appears) scopes to a small, purpose-built, always-
    /// empty app folder instead of the captain's entire home directory.
    private static func resolveWorkingDirectory() -> URL? {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        let dir = base.appendingPathComponent("FirstmateCockpit", isDirectory: true)
            .appendingPathComponent("sre-lead", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            return nil
        }
        return dir
    }

    /// Find the `claude` binary the same way `TmuxMirror.resolveTmux()` finds
    /// `tmux` - a Finder-launched GUI app inherits a minimal PATH.
    private static func resolveClaude() -> String? {
        resolveExecutable(name: "claude", commonPaths: ["/opt/homebrew/bin/claude", "/usr/local/bin/claude"])
    }

    private static func resolvePython3() -> String? {
        resolveExecutable(name: "python3", commonPaths: ["/usr/bin/python3", "/opt/homebrew/bin/python3", "/usr/local/bin/python3"])
    }

    private static func resolveExecutable(name: String, commonPaths: [String]) -> String? {
        let fm = FileManager.default
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            for dir in path.split(separator: ":") {
                let candidate = "\(dir)/\(name)"
                if fm.isExecutableFile(atPath: candidate) { return candidate }
            }
        }
        for candidate in commonPaths where fm.isExecutableFile(atPath: candidate) {
            return candidate
        }
        return nil
    }

    /// Locate `sre_kubectl_mcp.py`: first a copy alongside the app bundle
    /// (`build_native_app.sh` copies it into `Contents/Resources`, the same
    /// convention as `icon.icns`), then an `FM_SRE_KUBECTL_SCRIPT` override,
    /// then the source tree itself (the `swift run`/`swift build` dev flow -
    /// walks up from the current working directory looking for
    /// `native/Scripts/sre_kubectl_mcp.py`, mirroring how `FirstmateHome`
    /// tries a list of candidates rather than assuming one fixed layout).
    private static func resolveKubectlScript() -> String? {
        let fm = FileManager.default
        if let resourceURL = Bundle.main.resourceURL {
            let candidate = resourceURL.appendingPathComponent("sre_kubectl_mcp.py").path
            if fm.isReadableFile(atPath: candidate) { return candidate }
        }
        if let override = ProcessInfo.processInfo.environment["FM_SRE_KUBECTL_SCRIPT"], fm.isReadableFile(atPath: override) {
            return override
        }
        var dir = fm.currentDirectoryPath
        for _ in 0..<6 {
            let candidate = (dir as NSString).appendingPathComponent("native/Scripts/sre_kubectl_mcp.py")
            if fm.isReadableFile(atPath: candidate) { return candidate }
            let parent = (dir as NSString).deletingLastPathComponent
            if parent == dir { break }
            dir = parent
        }
        return nil
    }
}
