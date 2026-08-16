// Manjesh Grand Line - native macOS app.
//
// Dictation, phase 3 (fm/grandline-dictation-phase3): the "clean up my
// sentences" polish pass. When the Dictation page's "Clean up my sentences"
// toggle is on, a raw transcript is rewritten into a well-formed sentence via
// a single non-interactive `claude -p ... --output-format json` call before
// it's pasted/recorded - the exact same invocation shape `SRELeadRunner.swift`
// already established (see that file's own header for the full reasoning:
// `json` over `stream-json` since only the final reply text is ever needed,
// `/dev/null` stdin to skip `claude -p`'s ~3s piped-stdin probe, draining both
// pipes before `waitUntilExit()` to avoid a full-buffer deadlock).
//
// Deliberately NOT reusing `SRELeadRunner` itself: that type threads a
// `session_id` across turns via `--resume` for a multi-turn conversation
// pane, carries an MCP config + a restricted `--allowedTools`/persona for the
// kubectl tool, and reports failures into `SRELeadChatView`'s chat feed. This
// is a single, stateless one-shot rewrite per dictation with no conversation
// to resume and no MCP tool involved - a second, smaller type mirroring
// `SRELeadRunner`'s `Process`/argument/parsing shape was clearer than
// stretching that one to cover both call shapes. `SRELead.resolveClaude()` is
// reused as-is (it's already `internal`, built for exactly this kind of
// second caller - see its own doc comment).
//
// Real response shape, verified live rather than assumed (see this task's PR
// description for the actual transcript): `claude -p "<prompt>" --output-
// format json` with a plain rewrite instruction returns `result` as clean
// text with no wrapping quotes or preamble - matching the persona-free,
// system-prompt-free single-turn case (SRE Lead's own persona is what
// produces its `**Finding:**`-labeled structure; a bare `-p` prompt with no
// system prompt does not add that kind of framing on its own). `cleanedText`
// still strips a leading/trailing straight or curly quote pair defensively,
// since a model can occasionally wrap a "rewrite this text" answer in quotes
// depending on phrasing - cheap insurance, not something depended on to make
// the feature work.
//
// This step needs network access and the captain's own already-authenticated
// `claude` CLI - unlike every other step in the Dictation pipeline, which is
// fully on-device/offline (see `DictationEngine.swift`'s header). A failure
// here (no network, not authenticated, `claude` not on PATH, a bad/garbled
// response) always falls back to the raw transcript rather than losing or
// blocking the dictation - `DictationEngine.finish(text:)` is the one call
// site, and it never waits on this indefinitely either (see `timeout` below).

import Foundation

/// Rewrites a raw transcript into a well-formed sentence via one non-
/// interactive `claude -p` call. Stateless - a fresh instance's `rewrite`
/// call is independent of any other; there is no conversation to resume.
enum DictationCleanup {
    /// Bounded wait for the whole `claude -p` round trip - a rewrite that
    /// takes meaningfully longer than this is assumed hung/unreachable, and
    /// the caller falls back to the raw transcript rather than blocking a
    /// dictation indefinitely on a network call. Generous relative to a
    /// typical `claude -p` turn (SRE Lead's own turns routinely complete in a
    /// few seconds) while still being far short of "the captain gives up."
    static let timeout: TimeInterval = 20

    static func prompt(for transcript: String) -> String {
        """
        Rewrite the following rough, spoken transcript as a single grammatically \
        correct, well-formed piece of text. Fix filler words, false starts, and \
        awkward phrasing, but preserve the original meaning and intent exactly - \
        do not add information, opinions, or commentary. Reply with ONLY the \
        rewritten text and nothing else - no quotes, no preamble, no explanation.

        Transcript:
        \(transcript)
        """
    }

    /// Runs the rewrite. `completion` is always called on the main thread,
    /// exactly once, with `.success(rewritten)` or `.failure(reason)` - the
    /// caller (`DictationEngine.finish`) treats any failure as "fall back to
    /// the raw transcript," so `reason` only matters for whatever debug
    /// logging a caller chooses to do with it, never for control flow beyond
    /// success/failure.
    /// Test-only seam: `DictationCleanupSelfTest` points this at a real,
    /// disposable fake-`claude` script (never the real `claude` binary) so it
    /// can drive `rewrite`'s actual `Process`/parsing code end to end without
    /// depending on real network access or the machine's own Claude auth.
    /// `nil` (the production default) means "resolve the real `claude` via
    /// `SRELead.resolveClaude()`, exactly as before this seam existed."
    static var claudePathOverrideForTests: String?

    static func rewrite(_ transcript: String, completion: @escaping (Result<String, DictationCleanupError>) -> Void) {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            completion(.failure(DictationCleanupError(message: "empty transcript")))
            return
        }
        guard let claude = claudePathOverrideForTests ?? SRELead.resolveClaude() else {
            completion(.failure(DictationCleanupError(message: "claude is not installed or not on PATH")))
            return
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: claude)
        proc.arguments = ["-p", prompt(for: trimmed), "--output-format", "json"]
        proc.environment = childEnvironmentDict()
        proc.standardInput = FileHandle.nullDevice
        let out = Pipe()
        let err = Pipe()
        proc.standardOutput = out
        proc.standardError = err

        var finished = false
        let finishLock = NSLock()
        func finishOnce(_ result: Result<String, DictationCleanupError>) {
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
                finishOnce(.failure(DictationCleanupError(message: "could not start claude: \(error.localizedDescription)")))
                return
            }
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
            finishOnce(.failure(DictationCleanupError(message: "claude did not respond within \(Int(timeout))s")))
        }
    }

    private static func parseResult(outData: Data, errData: Data, status: Int32) -> Result<String, DictationCleanupError> {
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
            return .failure(DictationCleanupError(message: detail))
        }

        if let isError = obj["is_error"] as? Bool, isError {
            let detail = (obj["result"] as? String) ?? "claude reported an error."
            return .failure(DictationCleanupError(message: detail))
        }

        guard let result = obj["result"] as? String else {
            return .failure(DictationCleanupError(message: "claude's response had no reply text."))
        }
        let cleaned = stripWrappingQuotes(result.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !cleaned.isEmpty else {
            return .failure(DictationCleanupError(message: "claude's rewrite was empty."))
        }
        return .success(cleaned)
    }

    /// Defensive only - see this file's header for why this isn't load-
    /// bearing for the feature to work in the common case.
    private static func stripWrappingQuotes(_ text: String) -> String {
        let quotePairs: [(Character, Character)] = [("\"", "\""), ("\u{201C}", "\u{201D}"), ("'", "'")]
        for (open, close) in quotePairs {
            if text.count >= 2, text.first == open, text.last == close {
                return String(text.dropFirst().dropLast())
            }
        }
        return text
    }
}

struct DictationCleanupError: Error {
    let message: String
}
