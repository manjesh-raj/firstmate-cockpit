// Manjesh Grand Line - native macOS app.
//
// GL-26 (production-readiness review): the one `claude -p ... --output-format
// json` runner. Five copies of it had accumulated - `SRELeadRunner`,
// `SRELeadPostmortem`, `DictationCleanup`, `ConsoleCommandComposer`,
// `LogAnalyzerAI` - each with its own `Process` setup, its own
// finish-exactly-once lock, its own timeout constant, and its own copy of the
// same ~30-line JSON parse. They had already drifted in ways that were bugs
// waiting to be noticed rather than deliberate differences:
//
//  - Four bounded the wait (20 / 20 / 45 / 120 seconds); `SRELeadRunner` did
//    not bound it at all, so a wedged `claude` left an SRE Lead turn spinning
//    forever with no way out but closing the pane.
//  - All five drained stdout to EOF and stderr only afterwards - GL-02's
//    half-fix - so a `claude` writing a large diagnostic to stderr while
//    stdout stayed open would deadlock the turn. `claude` failure output is
//    exactly the realistic case for that.
//  - Three treated an empty `result` string as success, two as failure.
//
// ## The shape being consolidated, and what is deliberately preserved
//
// `--output-format json` (one JSON object on the last line of stdout), not
// `stream-json` - see `SRELeadRunner`'s original header for why: these callers
// only ever need the final reply, and the streaming parser would add
// line-buffering and event dispatch to get right with no cheap way to test it.
//
// stdin is `/dev/null` on purpose, and it is load-bearing rather than tidy:
// `claude -p` probes for piped stdin and (confirmed live, in `SRELeadRunner`'s
// original comment) waits ~3s before proceeding without it on *every* turn.
// `Subprocess` gives every run `/dev/null` stdin by default, so that property
// now holds for all five callers rather than the four that remembered it.
//
// The per-caller `claudePathOverrideForTests` seams are all kept exactly as
// they were: each caller resolves its own executable and passes it in. That is
// what lets the existing `DictationCleanupSelfTest`,
// `SRELeadPostmortemSelfTest`, `ConsoleCommandComposerSelfTest`,
// `SRELeadPerTabSelfTest` and `NotificationCenterSRELeadSelfTest` fake-`claude`
// harnesses keep working untouched.
//
// The prompt still travels as an argv element, never through a shell - which
// is why none of this needs quoting or escaping, and why a prompt containing
// backticks or `$(...)` is inert.

import Foundation

struct ClaudeOneShotError: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}

struct ClaudeReply {
    /// The assistant's final reply text, trimmed. Never empty - an empty
    /// `result` is reported as a failure, since every caller in this app treats
    /// "no reply" as something to tell the captain about rather than render.
    let text: String
    /// `claude`'s own session id, when it reported one. `SRELeadRunner` threads
    /// this back through `--resume` to continue a conversation; the four
    /// stateless callers ignore it.
    let sessionID: String?
}

enum ClaudeOneShot {

    /// A run that has not answered by this point is assumed unreachable rather
    /// than slow. Callers with a known-different shape pass their own: a
    /// dictation rewrite must not hold up a paste for long (20s), a log
    /// analysis legitimately takes minutes (120s).
    static let defaultTimeout: TimeInterval = 60

    /// The bound `SRELeadRunner` never had. A real SRE Lead turn can run
    /// several bridged `kubectl` calls through a captain's own terminal, so
    /// this is deliberately generous - but it is a bound, which is the point.
    /// **This is a called-out behaviour change**: before consolidation an SRE
    /// Lead turn could hang indefinitely.
    static let conversationTimeout: TimeInterval = 300

    /// Where every caller's `claude` comes from. `SRELead.resolveClaude()`
    /// remains the single resolver (it also honours
    /// `SRELead.claudePathOverrideForTests`), so this is a pointer, not a
    /// second search path.
    static func resolve() -> String? { SRELead.resolveClaude() }

    /// Run one turn. `completion` is always called on the main thread, exactly
    /// once - which is the contract all five original copies hand-rolled with
    /// their own lock, and is now provided by `Subprocess.run` returning once.
    ///
    /// - Parameters:
    ///   - executable: the resolved `claude` path. Passed in rather than
    ///     resolved here so each caller keeps its own test seam.
    ///   - extraArguments: inserted before `--output-format json`. This is how
    ///     SRE Lead adds its MCP config, persona and tool allowlist.
    ///   - cancellation: cancel an in-flight turn (SRE Lead's pane teardown).
    @discardableResult
    static func run(
        executable: String,
        prompt: String,
        extraArguments: [String] = [],
        resumeSessionID: String? = nil,
        cwd: URL? = nil,
        timeout: TimeInterval = defaultTimeout,
        label: String = "claude -p",
        cancellation: SubprocessCancellation? = nil,
        completion: @escaping (Result<ClaudeReply, ClaudeOneShotError>) -> Void
    ) -> SubprocessCancellation {
        let token = cancellation ?? SubprocessCancellation()
        var arguments = ["-p", prompt] + extraArguments + ["--output-format", "json"]
        if let resumeSessionID {
            arguments += ["--resume", resumeSessionID]
        }

        DispatchQueue.global(qos: .userInitiated).async {
            let result = Subprocess.run(
                executable: executable,
                arguments: arguments,
                cwd: cwd,
                timeout: timeout,
                log: AppLog.ai,
                label: label,
                cancellation: token
            )
            let parsed = parse(result)
            DispatchQueue.main.async { completion(parsed) }
        }
        return token
    }

    /// Blocking variant, for a caller already on a background queue that wants
    /// the reply inline. Same parsing, same bound.
    static func runSync(
        executable: String,
        prompt: String,
        extraArguments: [String] = [],
        cwd: URL? = nil,
        timeout: TimeInterval = defaultTimeout,
        label: String = "claude -p"
    ) -> Result<ClaudeReply, ClaudeOneShotError> {
        let result = Subprocess.run(
            executable: executable,
            arguments: ["-p", prompt] + extraArguments + ["--output-format", "json"],
            cwd: cwd,
            timeout: timeout,
            log: AppLog.ai,
            label: label
        )
        return parse(result)
    }

    /// The one copy of what were five near-identical parses. Kept `internal`
    /// so `ClaudeOneShotSelfTest` can drive it directly against hand-built
    /// payloads, including the malformed ones a fake `claude` cannot easily
    /// produce.
    static func parse(_ result: SubprocessResult) -> Result<ClaudeReply, ClaudeOneShotError> {
        if result.launchFailed {
            return .failure(ClaudeOneShotError(message: "could not start claude: \(result.stderr)"))
        }
        if result.timedOut {
            return .failure(ClaudeOneShotError(
                message: "claude did not respond within \(Int(result.duration.rounded()))s"))
        }

        // `claude` can print progress/diagnostic lines before the single JSON
        // object it ends with, so the payload is the last non-empty line - not
        // the whole of stdout.
        let stdout = String(data: result.stdoutData, encoding: .utf8) ?? ""
        let lastLine = stdout
            .split(separator: "\n", omittingEmptySubsequences: true)
            .last
            .map(String.init)

        guard let line = lastLine,
              let jsonData = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
            let stderr = result.stderr
            let detail = stderr.isEmpty
                ? "claude exited with no parseable output (status \(result.status))."
                : stderr
            return .failure(ClaudeOneShotError(message: detail))
        }

        let sessionID = obj["session_id"] as? String

        if let isError = obj["is_error"] as? Bool, isError {
            let detail = (obj["result"] as? String) ?? "claude reported an error."
            return .failure(ClaudeOneShotError(message: detail))
        }

        guard let text = obj["result"] as? String else {
            return .failure(ClaudeOneShotError(message: "claude's response had no reply text."))
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            // Two of the five copies accepted an empty reply and three
            // rejected it. Rejecting is the honest reading: every caller here
            // renders the text or pastes it, and an empty render is a silent
            // failure the captain cannot distinguish from "nothing to say".
            return .failure(ClaudeOneShotError(message: "claude's reply was empty."))
        }
        return .success(ClaudeReply(text: trimmed, sessionID: sessionID))
    }
}
