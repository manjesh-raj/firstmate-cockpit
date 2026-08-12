// Manjesh Grand Line - native macOS app.
//
// Runs one non-interactive `claude -p ... --output-format json` process per
// SRE Lead question/follow-up and hands back just the assistant's final
// reply text - see `SRELead.swift`'s header for why this replaced the
// tmux-mirrored interactive `claude` TUI this pane used to run.
//
// `--output-format json` (a single JSON object on completion), not
// `stream-json`: the pane only ever needs to render the assistant's final
// reply as one message block (`SRELeadChatView`), never partial/incremental
// text or the intermediate tool-call events a streaming parser would also
// have to handle - `json` gets the same information with a far simpler,
// less fragile parse (one `JSONSerialization` call on one line of output,
// no line-buffering or event-type dispatch to get right without a real
// cluster to test against).
//
// Multi-turn context: confirmed live (`claude --help`, then a real two-call
// local test) that `-r`/`--resume <session_id>` works with `-p`/`--print` -
// the first call's response JSON carries a `session_id`, and passing that
// back via `--resume` on the next call continues the same conversation.
// `SRELeadRunner` tracks the most recent `session_id` and threads it through
// automatically; the caller never has to think about it.

import Foundation

/// One SRE Lead session's turn-by-turn `claude -p` runner. Not thread-safe
/// for concurrent `ask` calls - `SRELeadChatView`'s send button is disabled
/// while a turn is in flight, so callers should not need to serialize this
/// themselves, but `ask` does not defend against it either.
final class SRELeadRunner {
    private let session: SRELeadSession
    private let claude: String
    private var sessionID: String?
    private var currentProcess: Process?

    init(session: SRELeadSession, claude: String) {
        self.session = session
        self.claude = claude
    }

    /// Ask one question. `completion` is always called on the main thread.
    func ask(_ question: String, completion: @escaping (Result<String, SRELeadSetupError>) -> Void) {
        var args = [
            "-p", question,
            "--mcp-config", session.mcpConfigPath.path,
            "--strict-mcp-config",
            "--append-system-prompt", SRELead.persona,
            "--permission-mode", "bypassPermissions",
            "--allowedTools", SRELead.allowedTools,
            "--output-format", "json",
        ]
        if let sessionID {
            args += ["--resume", sessionID]
        }

        currentProcess = ClaudePrintInvoker.run(
            claude: claude,
            args: args,
            currentDirectory: session.workingDir
        ) { [weak self] result in
            self?.currentProcess = nil
            self?.handleResult(result, completion: completion)
        }
    }

    private func handleResult(
        _ result: Result<[String: Any], ClaudeCallError>,
        completion: (Result<String, SRELeadSetupError>) -> Void
    ) {
        guard case .success(let obj) = result else {
            if case .failure(let error) = result {
                completion(.failure(SRELeadSetupError(message: error.message)))
            }
            return
        }

        if let sid = obj["session_id"] as? String {
            sessionID = sid
        }

        if let isError = obj["is_error"] as? Bool, isError {
            let detail = (obj["result"] as? String) ?? "claude reported an error."
            completion(.failure(SRELeadSetupError(message: detail)))
            return
        }

        guard let result = obj["result"] as? String, !result.isEmpty else {
            completion(.failure(SRELeadSetupError(message: "claude's response had no reply text.")))
            return
        }
        completion(.success(result))
    }

    /// Best-effort kill of an in-flight turn - called when the pane closes.
    /// Safe to call whether or not a turn is running.
    func cancel() {
        currentProcess?.terminate()
        currentProcess = nil
    }
}
