// Manjesh Grand Line - native macOS app.
//
// "SRE Lead": a locally-run Claude Code session, spawned per connected host
// page, that investigates that host's Kubernetes cluster via one read-only
// `kubectl` MCP tool (`native/Scripts/sre_kubectl_mcp.py`) run over a second
// SSH connection to the same bastion the host page is already connected to -
// never a local kubeconfig, never a credential on a separate machine.
//
// Lifecycle mirrors `TmuxMirror` deliberately: `SRELead.setUp` creates a
// brand-new, uniquely-named detached tmux session running `claude` (not a
// grouped attach to an existing session - there is nothing to attach to yet,
// this session *is* the thing). The toolbar pane then mirrors that session
// exactly the way the Mirror tab mirrors the real `firstmate` session -
// `TmuxMirror.setUp(target: session.tmuxSessionName)` - so the rendering path
// is the same `CockpitTerminalView`/grouped-session machinery, not a new one.
// `tearDown()` kills the tmux session and every temp file this spawn wrote,
// mirroring `TmuxMirror.tearDown()` and `SSHKeyMaterializer.cleanup`.
//
// Read-only enforcement is NOT here or in the persona prompt below - it is
// enforced by `sre_kubectl_mcp.py` itself refusing any verb outside
// `get`/`describe`/`logs`/`top`/`events` and validating every argument's
// character set before it ever reaches `ssh`. This file's only security-
// relevant job is choosing which host's `ssh` argv the tool is allowed to
// run against, and it does that once, at spawn time, via a generated
// per-session JSON config file (`SRE_LEAD_HOST_CONFIG`) - never a shared or
// persisted credential.

import Foundation

struct SRELeadSetupError: Error {
    let message: String
}

/// A live SRE Lead session: the detached tmux session running `claude`, plus
/// every scratch path this spawn created so `tearDown()` can remove them all.
struct SRELeadSession {
    /// The detached tmux session's name (mirrored into the pane via
    /// `TmuxMirror.setUp(target:)`, exactly like the Firstmate Mirror tab).
    let tmuxSessionName: String

    private let scratchDir: URL
    private let sshKeyTempPath: String?

    /// Kill the tmux session (best-effort, mirrors `TmuxMirror.tearDown`),
    /// then remove this spawn's scratch directory (wrapper script, MCP
    /// config, host config) and any materialized SSH key. Safe to call more
    /// than once.
    func tearDown() {
        let env = childEnvironmentDict()
        if let tmux = TmuxMirror.resolveTmux() {
            _ = TmuxMirror.run(tmux, ["kill-session", "-t", tmuxSessionName], env: env)
        }
        try? FileManager.default.removeItem(at: scratchDir)
        if let sshKeyTempPath {
            SSHKeyMaterializer.cleanup(privateKeyPath: sshKeyTempPath)
        }
    }

    fileprivate init(tmuxSessionName: String, scratchDir: URL, sshKeyTempPath: String?) {
        self.tmuxSessionName = tmuxSessionName
        self.scratchDir = scratchDir
        self.sshKeyTempPath = sshKeyTempPath
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

    You have exactly one tool: kubectl_readonly. It runs a read-only kubectl verb (get, describe, logs, top, or events) on the connected bastion over SSH. Any other verb is rejected by the tool itself, not by you - do not try to work around it, and do not suggest destructive commands as something the captain could run manually instead.

    When an investigation has genuinely independent parts (e.g. "check pod events" + "check node capacity" + "check recent logs" for one incident), delegate each part to a subagent (the Task tool) so they run in parallel, then synthesize what they found into ONE finding. The captain talks to you, not to your subagents - never relay raw tool output or a subagent's full transcript verbatim; give a short, direct diagnosis and the evidence that supports it.

    Be concise. This is an incident-investigation chat, not a report.
    """

    /// Build the second SSH connection's argv: the exact same host argv the
    /// interactive tab already uses (`Host.sshArguments(allHosts:)`), plus a
    /// freshly materialized `-i <key>` when the host uses a saved key -
    /// independent of whatever temp key file the interactive tab itself is
    /// using, so this session's lifecycle (and cleanup) is entirely its own.
    private static func buildSSHArgv(
        hostArgs: [String], keyID: UUID?, keyStore: SSHKeyStore
    ) -> (argv: [String], keyTempPath: String?) {
        guard let keyID, let key = keyStore.key(id: keyID) else {
            return (hostArgs, nil)
        }
        do {
            let materialized = try SSHKeyMaterializer.materialize(key: key)
            return (["-i", materialized.privateKeyPath] + hostArgs, materialized.privateKeyPath)
        } catch {
            // Same fallback the interactive tab takes: connect without -i
            // rather than fail the whole session, since the system agent /
            // known_hosts may still work.
            return (hostArgs, nil)
        }
    }

    /// Spawn a fresh SRE Lead session for `hostArgs`/`keyID` (the same values
    /// `ConsoleController.connectSSHIfNeeded` already resolved for the
    /// interactive tab). Writes this spawn's MCP config, host config, and a
    /// wrapper script into a private scratch directory (avoids threading
    /// `claude`'s multi-line `--append-system-prompt` text through tmux's own
    /// shell-joining of its command argv - see the wrapper script comment
    /// below), then creates the detached tmux session.
    static func setUp(hostArgs: [String], keyID: UUID?, keyStore: SSHKeyStore) -> Result<SRELeadSession, SRELeadSetupError> {
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

        let (sshArgv, keyTempPath) = buildSSHArgv(hostArgs: hostArgs, keyID: keyID, keyStore: keyStore)

        let scratchDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fm-sre-lead-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: scratchDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        } catch {
            return .failure(SRELeadSetupError(message: "could not create scratch directory: \(error.localizedDescription)"))
        }

        let hostConfigPath = scratchDir.appendingPathComponent("host-config.json")
        let mcpConfigPath = scratchDir.appendingPathComponent("mcp-config.json")
        let wrapperPath = scratchDir.appendingPathComponent("run-sre-lead.sh")

        do {
            let hostConfig: [String: Any] = ["ssh_executable": HostCatalog.sshExecutable, "ssh_argv": sshArgv]
            try JSONSerialization.data(withJSONObject: hostConfig, options: [.prettyPrinted])
                .write(to: hostConfigPath)

            let mcpConfig: [String: Any] = [
                "mcpServers": [
                    "sre-kubectl": [
                        "command": python,
                        "args": [scriptPath],
                        "env": ["SRE_LEAD_HOST_CONFIG": hostConfigPath.path],
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
            let script = """
            #!/bin/bash
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
        let env = childEnvironmentDict()
        // `-c $HOME`, not the scratch dir the wrapper script itself lives in
        // (`ProcessInfo`'s default tmux start-directory would otherwise be
        // wherever the tmux *server* first started): a `claude` session's
        // first-ever launch in a directory it hasn't seen before shows a
        // one-time "do you trust this folder?" prompt - confirmed live by
        // launching the exact wrapper-script shape this method generates in
        // a fresh scratch dir. `$HOME` is overwhelmingly likely to already
        // be trusted (or at least a directory the captain recognizes and can
        // decide about themselves in the mirrored terminal, rather than an
        // opaque `/tmp` path this feature invented).
        let created = TmuxMirror.run(tmux, ["new-session", "-d", "-s", sessionName, "-c", FileManager.default.homeDirectoryForCurrentUser.path, wrapperPath.path], env: env)
        if created.status != 0 {
            try? FileManager.default.removeItem(at: scratchDir)
            if let keyTempPath { SSHKeyMaterializer.cleanup(privateKeyPath: keyTempPath) }
            let detail = created.stderr.isEmpty ? "tmux could not start the session" : created.stderr
            return .failure(SRELeadSetupError(message: detail))
        }
        _ = TmuxMirror.run(tmux, ["set-option", "-t", sessionName, "status", "off"], env: env)

        return .success(SRELeadSession(tmuxSessionName: sessionName, scratchDir: scratchDir, sshKeyTempPath: keyTempPath))
    }

    /// Single-quote `s` for embedding as one literal argv token in the
    /// generated `bash` wrapper script above.
    private static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
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
