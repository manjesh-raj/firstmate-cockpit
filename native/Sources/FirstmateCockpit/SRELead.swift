// Manjesh Grand Line - native macOS app.
//
// "SRE Lead": a locally-run Claude Code session, spawned per connected host
// page, that investigates that host's Kubernetes cluster via one read-only
// `kubectl` MCP tool (`native/Scripts/sre_kubectl_mcp.py`).
//
// `fm/cockpit-sre-lead-shared-terminal` replaced this tool's execution model
// for kubectl commands. It used to open a *second*, independent SSH
// connection to the same bastion (five attempts across PRs #70-73 plus an
// abandoned PTY investigation, all trying to make that second connection
// complete the same multi-hop, password-gated login chain the captain does
// by hand). The captain then confirmed a hard constraint: the real "EKS
// Preprod Bastion" host's EKS Bastion hop is username/password-gated *by
// policy* - no SSH key auth is possible there - so a second, fully-automated
// connection can never complete that chain; nothing can supply a password
// that isn't stored anywhere, by design. The tool now runs kubectl inside
// the *same* already-authenticated interactive tab the captain used to log
// all the way in, via `SRELeadBridge` - see that file for the request/
// response protocol and `sre_kubectl_mcp.py`'s module docstring for the
// Python side. This file no longer knows anything about `ssh` argv, saved
// keys, or a host's `startupSnippetID` - it only prepares the MCP config
// `claude` needs and hands `SRELeadRunner` the bridge directory
// `SRELeadBridge` also watches.
//
// `fm/cockpit-sre-lead-ux-fixes` then replaced *this file's* own execution
// model: it used to spawn a persistent, detached tmux session running the
// interactive `claude` TUI, mirrored into the pane via `TmuxMirror` exactly
// like the Firstmate Mirror tab - which meant the pane showed the raw
// interactive CLI (permission-mode banner, box-drawing borders, ANSI chrome)
// instead of anything native to this app. `setUp()` now only prepares the
// MCP config + a scratch/working directory; there is no tmux session, no
// wrapper script, and no `claude` process spawned here at all - `SRELeadRunner`
// spawns one non-interactive `claude -p ... --output-format json` process per
// question/follow-up, using `--resume <session_id>` (confirmed to work with
// `-p` by a live local test - `claude --help` documents `-r`/`--resume` as
// working with `--print`) to keep conversation context across turns, and the
// pane renders just the assistant's final reply as a native message feed
// (`SRELeadChatView.swift`) instead of a terminal. A wrapper script is no
// longer needed either: `Process`'s `arguments` array reaches `claude`
// directly, with no intervening shell to re-parse the persona text.
//
// Read-only enforcement is NOT here or in the persona prompt below - it is
// enforced by `sre_kubectl_mcp.py` itself refusing any verb outside
// `get`/`describe`/`logs`/`top`/`events` and validating every argument's
// character set before it ever reaches the shared terminal. `sre-kubectl` is
// also the *only* MCP tool exposed, and `--allowedTools` restricts the agent
// to it plus `Task`/`TodoWrite` - it has no path to a raw Bash/Read/Write
// tool, in the old tmux-hosted session or this one.
//
// `fm/cockpit-sre-lead-reply-formatting` addressed a captain complaint after
// the ux-fixes task above: findings-first and terse was right, but the reply
// text itself had no structure (no explicit conclusion/recommendation) and
// rendered as one flat, unstyled paragraph even when it used markdown. The
// persona below now requires a fixed two-paragraph structure for a
// substantive reply - a `**Finding:**`-labeled paragraph first, then an
// optional `**Recommended next action:**`-labeled one - and
// `SRELeadMarkdown.swift`/`SRELeadChatView.swift` parse and render those
// exact labels as distinct callouts, plus general bold/inline-code/bullet-
// list markdown, instead of plain text. The label wording is a fixed
// contract between this prompt and that parser: changing one without the
// other breaks the callout styling silently (the text still renders, just
// as a plain paragraph).
//
// `fm/grandline-sre-lead-runbook-execution` added a second MCP tool,
// `run_runbook`, for the captain's conversational "run the API latency spike
// runbook" ask - see `sre_kubectl_mcp.py`'s module docstring and
// `_run_runbook`/`_validate_runbook_line`/`_find_runbook` for the mechanism.
// It is not a new capability: it looks a runbook up by title in the same
// `GrandLineDocs/runbooks/` store phase 1 of "Knowledge and speed" built
// (`DocsRunbookStore`), validates every one of its kubectl command lines
// through the exact same `_validate_args` allowlist `kubectl_readonly`
// itself enforces, and refuses the whole runbook by name - no steps run - if
// even one line fails. This file only adds `SRE_LEAD_RUNBOOKS_DIR` to the MCP
// config (pointing at `DocsRunbookStore().root`, the same runbooks folder the
// Docs page reads/writes) and `mcp__sre-kubectl__run_runbook` to
// `allowedTools`; all lookup/validation/execution logic lives in the Python
// script, next to the allowlist it depends on.

import Foundation

struct SRELeadSetupError: Error {
    let message: String
}

/// A live SRE Lead session: the MCP config `claude -p` is launched against
/// each turn, the bridge directory its kubectl tool and `SRELeadBridge` both
/// watch, and the scratch/working directories so `tearDown()` can remove
/// them.
struct SRELeadSession {
    /// The `claude -p --mcp-config <this>` argument for every turn.
    let mcpConfigPath: URL

    /// Where `sre_kubectl_mcp.py` writes `request-<id>.json` and
    /// `SRELeadBridge` writes `response-<id>.json` back - see
    /// `SRELeadBridge.swift`'s header for the full protocol.
    let bridgeDir: URL

    /// `claude -p`'s working directory for every turn - see
    /// `resolveWorkingDirectory()` for why this is a small, dedicated
    /// app-owned folder rather than the captain's whole `$HOME`.
    let workingDir: URL

    private let scratchDir: URL

    /// Remove this spawn's scratch directory (MCP config and the bridge
    /// directory's own request/response files) - nothing lingers. Safe to
    /// call more than once. Killing an in-flight `claude -p` process is
    /// `SRELeadRunner.cancel()`'s job, not this method's - this only cleans
    /// up files.
    func tearDown() {
        try? FileManager.default.removeItem(at: scratchDir)
    }

    fileprivate init(mcpConfigPath: URL, scratchDir: URL, bridgeDir: URL, workingDir: URL) {
        self.mcpConfigPath = mcpConfigPath
        self.scratchDir = scratchDir
        self.bridgeDir = bridgeDir
        self.workingDir = workingDir
    }
}

enum SRELead {

    /// The SRE Lead persona (design brief: "SRE Manager -> SRE Lead -> SRE
    /// Engineers", mirroring this whole Firstmate system's own supervision
    /// rule). Delegation to subagents for independent checks is Claude
    /// Code's own Task-tool capability - this prompt only asks for it, it
    /// does not implement any orchestration itself. Not `private`:
    /// `SRELeadRunner` passes this as `--append-system-prompt` for every
    /// turn.
    static let persona = """
    You are the SRE Lead for this Kubernetes cluster, reporting to the captain (the human at the other end of this session).

    You have two tools. kubectl_readonly runs a read-only kubectl verb (get, describe, logs, top, or events) in the captain's own already-connected terminal tab for this host. Any other verb is rejected by the tool itself, not by you - do not try to work around it, and do not suggest destructive commands as something the captain could run manually instead. The tool can occasionally fail with a "busy" error if the captain is actively typing in that tab, or if another call is already running - just wait a moment and retry once.

    run_runbook runs every kubectl step of a named runbook from Docs > Runbooks (e.g. "run the API latency spike runbook") - call it with the runbook's title, not a filename or slug. It validates every step against the exact same read-only allowlist before running any of them; if the tool refuses the whole runbook, tell the captain plainly which step failed and why, and point them at running it manually via a Console tab instead - never try to run the remaining steps yourself one at a time as a workaround. If it succeeds, summarize what each step found, not just that it ran.

    When an investigation has genuinely independent parts (e.g. "check pod events" + "check node capacity" + "check recent logs" for one incident), delegate each part to a subagent (the Task tool) so they run in parallel, then synthesize what they found into ONE finding. The captain talks to you, not to your subagents - never relay raw tool output or a subagent's full transcript verbatim.

    How to reply, every time, with no exceptions: lead with the finding or the answer to what the captain asked, in the first sentence. Do not open with what you checked, what commands you ran, what you ruled out, or hedge about tool limitations before getting there - the captain wants the conclusion first, not a walkthrough of how you reached it. Do not describe your own methodology ("I checked X, then Y, then ruled out Z") unless the captain explicitly asks "how did you check" or "what did you rule out" - if you were genuinely unable to check something because of the read-only restriction, say so in one short clause, not a paragraph. Default to terse: a few sentences, not a report.

    For a substantive investigation reply (not a short acknowledgement, a clarifying question, or confirming you'll proceed), structure it as two labeled paragraphs, in this exact order and with this exact literal wording - the pane parses these two labels to render them as distinct callouts, so do not vary the wording, drop the double asterisks, or add a blank line between a label and the rest of its sentence:

    **Finding:** the direct answer or conclusion, one to a few sentences, with only the minimum supporting evidence needed to back it (one or two specifics - a pod name, an error string, a count). Not a narration of your investigation process. If the finding is inconclusive, say what it points to next, still leading with that.

    **Recommended next action:** the concrete next step the captain (or whoever they hand this to) should take. Omit this second paragraph entirely - do not write the label with no content - when there genuinely isn't a next action, e.g. a pure informational lookup with nothing actionable.

    You can use other lightweight markdown too - backtick code spans for pod/resource/file names, and `-` bullet lists when enumerating more than a couple of items (e.g. several crashing pods) - the pane renders it with real formatting.
    """

    /// The `--allowedTools` value for every `claude -p` turn - the kubectl
    /// MCP tool plus `Task`/`TodoWrite`, nothing else. Not `private`:
    /// `SRELeadRunner` needs it too.
    static let allowedTools = "mcp__sre-kubectl__kubectl_readonly,mcp__sre-kubectl__run_runbook,Task,TodoWrite"

    /// Prepare a fresh SRE Lead session: writes this spawn's MCP config into
    /// a private scratch directory and creates the bridge directory the MCP
    /// config points the kubectl tool at. Does not spawn `claude` itself -
    /// `SRELeadRunner` does that, once per question/follow-up.
    static func setUp() -> Result<SRELeadSession, SRELeadSetupError> {
        guard resolveClaude() != nil else {
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

        // `DocsRunbookStore().root` is the same `GrandLineDocs/runbooks/`
        // folder the Docs page reads/writes (see that type's own header) -
        // constructing a fresh instance here is deliberate, matching this
        // app's established "each page/session keeps an independent copy of
        // the same underlying store" convention (`UpdatesController`/
        // `BootstrapController` do the same for `DependencyCatalog`), not a
        // shared singleton.
        let runbooksDir = DocsRunbookStore().root

        let mcpConfigPath = scratchDir.appendingPathComponent("mcp-config.json")
        do {
            let mcpConfig: [String: Any] = [
                "mcpServers": [
                    "sre-kubectl": [
                        "command": python,
                        "args": [scriptPath],
                        "env": [
                            "SRE_LEAD_BRIDGE_DIR": bridgeDir.path,
                            "SRE_LEAD_RUNBOOKS_DIR": runbooksDir.path,
                        ],
                    ]
                ]
            ]
            try JSONSerialization.data(withJSONObject: mcpConfig, options: [.prettyPrinted])
                .write(to: mcpConfigPath)
        } catch {
            try? FileManager.default.removeItem(at: scratchDir)
            return .failure(SRELeadSetupError(message: "could not write session config: \(error.localizedDescription)"))
        }

        guard let workingDir = resolveWorkingDirectory() else {
            try? FileManager.default.removeItem(at: scratchDir)
            return .failure(SRELeadSetupError(message: "could not create SRE Lead working directory."))
        }

        return .success(SRELeadSession(mcpConfigPath: mcpConfigPath, scratchDir: scratchDir, bridgeDir: bridgeDir, workingDir: workingDir))
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
    /// `tmux` - a Finder-launched GUI app inherits a minimal PATH. Not
    /// `private`: `SRELeadRunner` resolves this once per session too.
    static func resolveClaude() -> String? {
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
