// Manjesh Grand Line - native macOS app.
//
// "Generate Postmortem" (phase 2 of "Knowledge and speed",
// fm/grandline-sre-lead-postmortem): summarizes a completed SRE Lead
// investigation (the pane's own question/answer transcript - see
// `SRELeadChatView.transcriptForPostmortem`) into a structured markdown
// postmortem via one non-interactive `claude -p ... --output-format json`
// call, saved into the same `GrandLineDocs/runbooks/postmortems/` store
// phase 1 already built (`DocsRunbookStore.createPostmortem`).
//
// This mirrors `DictationCleanup.swift`'s exact `Process`/argument/parsing
// shape (see that file's own header for the full reasoning: `json` over
// `stream-json` since only the final reply text is ever needed, `/dev/null`
// stdin to skip `claude -p`'s ~3s piped-stdin probe, draining both pipes
// before `waitUntilExit()` to avoid a full-buffer deadlock) - not
// `SRELeadRunner`'s own multi-turn `--resume` pattern, since this is a
// single, stateless one-shot summarization with no follow-up turns needed
// and no MCP tool/persona/`--allowedTools` involved. `SRELead.resolveClaude()`
// is reused as-is, exactly like `DictationCleanup` already does.
//
// A `claude -p` failure here (no network, not authenticated, `claude` not on
// PATH, a bad/garbled response, a timeout) never loses or discards the
// original investigation transcript - `ConsoleController.generatePostmortemClicked`
// is the one call site, and it only ever appends an error message to the
// existing chat feed on failure; the transcript itself lives in
// `SRELeadChatView.messages`, untouched either way, so the captain can retry
// with no data lost.

import Foundation

enum SRELeadPostmortem {
    /// Bounded wait for the whole `claude -p` round trip. Generous relative to
    /// `DictationCleanup`'s 20s: a postmortem prompt embeds a whole
    /// investigation transcript (can be considerably longer than one
    /// dictation) and asks for a longer, structured reply, but a real
    /// `claude -p` turn that takes meaningfully longer than this is still
    /// assumed hung/unreachable rather than making the captain wait
    /// indefinitely.
    static let timeout: TimeInterval = 45

    static func prompt(hostLabel: String, transcript: String) -> String {
        """
        You are writing a postmortem document from a completed SRE Lead investigation transcript for the host "\(hostLabel)". The transcript is a real back-and-forth between the captain and SRE Lead, an assistant with exactly one tool - a read-only kubectl command run in the captain's own terminal - investigating this Kubernetes cluster.

        Write a structured postmortem in Markdown with exactly these sections, in this order:

        # <a short, specific title for what was investigated - this becomes the document's title>

        ## Timeline
        A chronological account of what was checked and found, as a `-` bullet list - one bullet per meaningful step or finding, not a copy of the raw transcript.

        ## Root Cause
        **Finding:** the root cause or best-supported conclusion from the investigation, one to a few sentences, with only the minimum supporting evidence needed to back it. If the investigation was inconclusive, say so plainly and state what it points to instead.

        ## Follow-ups
        **Recommended next action:** one or more concrete next steps, as a `-` bullet list if there is more than one. Omit this whole section only when the investigation reached no actionable follow-up at all.

        Base every claim only on the transcript below - do not invent facts, commands, findings, or output that isn't actually there. Reply with ONLY the markdown document itself - no preamble, no code fences, no commentary before or after it.

        Transcript:
        \(transcript)
        """
    }

    /// Test-only seam, same convention as `DictationCleanup.claudePathOverrideForTests`:
    /// `SRELeadPostmortemSelfTest` points this at a real, disposable fake-
    /// `claude` script (never the real `claude` binary) so it can drive
    /// `generate`'s actual `Process`/parsing code end to end with no
    /// dependency on real network access or the machine's own Claude auth.
    /// `nil` (the production default) means "resolve the real `claude` via
    /// `SRELead.resolveClaude()`, exactly as before this seam existed."
    static var claudePathOverrideForTests: String?

    /// Generates the postmortem markdown. `completion` is always called on
    /// the main thread, exactly once, with `.success(markdown)` or
    /// `.failure(reason)` - the caller treats any failure as "show a clear
    /// error and let the captain retry," never as data loss, since the
    /// original transcript this was generated from is never touched here.
    static func generate(hostLabel: String, transcript: String, completion: @escaping (Result<String, SRELeadPostmortemError>) -> Void) {
        let trimmedTranscript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTranscript.isEmpty else {
            completion(.failure(SRELeadPostmortemError(message: "no investigation content to summarize yet")))
            return
        }
        guard let claude = claudePathOverrideForTests ?? SRELead.resolveClaude() else {
            completion(.failure(SRELeadPostmortemError(message: "claude is not installed or not on PATH")))
            return
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: claude)
        proc.arguments = ["-p", prompt(hostLabel: hostLabel, transcript: trimmedTranscript), "--output-format", "json"]
        proc.environment = childEnvironmentDict()
        // Without this, `claude -p` probes for piped stdin and waits ~3s
        // before proceeding without it, on every single call - see
        // `SRELeadRunner.ask`'s identical comment.
        proc.standardInput = FileHandle.nullDevice
        let out = Pipe()
        let err = Pipe()
        proc.standardOutput = out
        proc.standardError = err

        var finished = false
        let finishLock = NSLock()
        func finishOnce(_ result: Result<String, SRELeadPostmortemError>) {
            finishLock.lock()
            let alreadyFinished = finished
            finished = true
            finishLock.unlock()
            guard !alreadyFinished else { return }
            DispatchQueue.main.async { completion(result) }
        }

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try proc.run()
            } catch {
                finishOnce(.failure(SRELeadPostmortemError(message: "could not start claude: \(error.localizedDescription)")))
                return
            }
            // Read both pipes to completion before `waitUntilExit()` - a
            // pipe's buffer can fill and deadlock the child if the parent
            // isn't draining it concurrently with the child still writing.
            let outData = out.fileHandleForReading.readDataToEndOfFile()
            let errData = err.fileHandleForReading.readDataToEndOfFile()
            proc.waitUntilExit()
            let status = proc.terminationStatus
            finishOnce(Self.parseResult(outData: outData, errData: errData, status: status))
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
            finishLock.lock()
            let alreadyFinished = finished
            finishLock.unlock()
            guard !alreadyFinished else { return }
            proc.terminate()
            finishOnce(.failure(SRELeadPostmortemError(message: "claude did not respond within \(Int(timeout))s")))
        }
    }

    private static func parseResult(outData: Data, errData: Data, status: Int32) -> Result<String, SRELeadPostmortemError> {
        let stdout = String(data: outData, encoding: .utf8) ?? ""
        let lastNonEmptyLine = stdout
            .split(separator: "\n", omittingEmptySubsequences: true)
            .last
            .map(String.init)

        guard let line = lastNonEmptyLine,
              let jsonData = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
            let stderr = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let detail = stderr.isEmpty ? "claude exited with no parseable output (status \(status))." : stderr
            return .failure(SRELeadPostmortemError(message: detail))
        }

        if let isError = obj["is_error"] as? Bool, isError {
            let detail = (obj["result"] as? String) ?? "claude reported an error."
            return .failure(SRELeadPostmortemError(message: detail))
        }

        guard let result = obj["result"] as? String else {
            return .failure(SRELeadPostmortemError(message: "claude's response had no reply text."))
        }
        let cleaned = stripWrappingCodeFence(result.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !cleaned.isEmpty else {
            return .failure(SRELeadPostmortemError(message: "claude's postmortem was empty."))
        }
        return .success(cleaned)
    }

    /// Defensive only, mirroring `DictationCleanup.stripWrappingQuotes`'s own
    /// "cheap insurance, not load-bearing" framing: a model can occasionally
    /// wrap a "reply with only the document" answer in a ```markdown fence
    /// despite the prompt's explicit instruction not to.
    private static func stripWrappingCodeFence(_ text: String) -> String {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let first = lines.first, first.hasPrefix("```") else { return text }
        lines.removeFirst()
        if let last = lines.last, last.trimmingCharacters(in: .whitespaces) == "```" {
            lines.removeLast()
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct SRELeadPostmortemError: Error {
    let message: String
}
