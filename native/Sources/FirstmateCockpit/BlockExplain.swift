// Manjesh Grand Line - native macOS app.
//
// `fm/cockpit-block-view-ssh-only` (originally PR #80): the "Explain this"
// block action - a single, captain-triggered `claude -p` call that explains
// a failed command's output. This is explicitly NOT SRE Lead (`SRELead.swift`):
// no MCP server, no kubectl access, no session/`--resume` threading across
// calls, no scratch/bridge directories to set up or tear down - it only
// ever reads text already sitting in one block and returns one reply, via
// the same `ClaudePrintInvoker` plumbing `SRELeadRunner` uses so this isn't
// a second way to shell out to `claude`. Only ever reachable from an SSH
// host page's block view - see `TabModel.supportsBlockView`.
//
// Tool access: confirmed live (not assumed) that `--permission-mode
// bypassPermissions` combined with a *restrictive* `--allowedTools` value
// does NOT actually stop the model from using an unlisted built-in tool
// (`Bash` ran successfully in a throwaway test even with `--allowedTools
// "TodoWrite"`) - `bypassPermissions` appears to grant every built-in tool
// regardless of the allow-list. What does work, confirmed the same way, is
// an explicit `--disallowedTools` deny-list naming every built-in tool: a
// test prompt explicitly asking the model to run `echo pwned` via its Bash
// tool was refused once `Bash` was on that deny-list, with or without
// `bypassPermissions`. This call therefore denies every built-in tool by
// name and passes no `--mcp-config` at all, so there is nothing for the
// model to call - it can only reply with text.
import Foundation

enum BlockExplainState: Equatable {
    case idle
    case loading
    case result(String)
    case failed(String)
}

enum BlockExplain {
    /// A block is eligible for "Explain this" only once it's genuinely
    /// failed - never while still `.running`, never when it succeeded. Pure
    /// and standalone (no `NSView`/`BlockContainerView` involved) so it can
    /// be unit-tested directly - see `BlockExplainSelfTest.swift`.
    /// `BlockContainerView.explainState(for:)` is the one call site.
    static func isEligible(_ status: TerminalBlock.Status) -> Bool {
        guard case .finished(let exitCode) = status else { return false }
        return exitCode != 0
    }

    /// Every built-in tool name, denied explicitly - see the file header for
    /// why an allow-list alone was not sufficient. `SlashCommand` included
    /// since a bare `/` in the piped-back command output could otherwise be
    /// misread as an invocation attempt.
    private static let deniedTools = [
        "Bash", "BashOutput", "KillShell", "Edit", "Write", "Read", "NotebookEdit",
        "Glob", "Grep", "Task", "TodoWrite", "WebFetch", "WebSearch", "SlashCommand",
    ].joined(separator: ",")

    /// One-shot explanation of a failed command. `completion` is always
    /// called on the main thread. No session, no working-directory setup,
    /// no cleanup - the process and its pipes are the entire lifetime of
    /// this call.
    static func explain(
        commandText: String,
        outputText: String,
        exitCode: Int32,
        completion: @escaping (Result<String, ClaudeCallError>) -> Void
    ) -> Process? {
        guard let claude = SRELead.resolveClaude() else {
            completion(.failure(ClaudeCallError(message: "claude CLI not found on PATH.")))
            return nil
        }

        let command = commandText.isEmpty ? "(unknown command)" : commandText
        let output = outputText.isEmpty ? "(no output captured)" : truncatedOutput(outputText)
        let prompt = """
        A shell command failed. Explain briefly, in plain prose (a sentence or two), what most likely went wrong and what to check next. Do not run anything or ask to run anything - you have no tools available, only reply with your explanation as text.

        Command: \(command)
        Exit code: \(exitCode)
        Output:
        \(output)
        """

        let args = [
            "-p", prompt,
            "--disallowedTools", deniedTools,
            "--output-format", "json",
        ]

        return ClaudePrintInvoker.run(
            claude: claude, args: args, currentDirectory: URL(fileURLWithPath: NSTemporaryDirectory())
        ) { result in
            switch result {
            case .failure(let error):
                completion(.failure(error))
            case .success(let obj):
                if let isError = obj["is_error"] as? Bool, isError {
                    let detail = (obj["result"] as? String) ?? "claude reported an error."
                    completion(.failure(ClaudeCallError(message: detail)))
                    return
                }
                guard let reply = obj["result"] as? String, !reply.isEmpty else {
                    completion(.failure(ClaudeCallError(message: "claude's response had no reply text.")))
                    return
                }
                completion(.success(reply))
            }
        }
    }
}

/// A failed command's output can be arbitrarily long (a full stack trace, a
/// verbose `kubectl describe`) - cap what gets sent to `claude -p` so one
/// explanation call can't balloon into a huge prompt. Cheap to raise later
/// if it ever proves too aggressive; there is no captain-facing indication
/// today that truncation happened, which is fine since this only feeds the
/// model's context, not anything rendered directly.
private func truncatedOutput(_ text: String) -> String {
    let limit = 4000
    guard text.count > limit else { return text }
    let head = text.prefix(limit)
    return "\(head)\n… (truncated)"
}
