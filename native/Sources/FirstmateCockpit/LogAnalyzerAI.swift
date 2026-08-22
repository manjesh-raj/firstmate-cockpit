// Manjesh Grand Line - native macOS app.
//
// `fm/grandline-log-analyzer-build`, spec §4 (structured analysis), §9
// (inferred/unknown correlation), §10 (root cause with confidence), §11
// (suggested commands), §12 (what evidence is still missing) and §22
// (analysis modes).
//
// **Invocation shape.** One non-interactive `claude -p ... --output-format
// json` process per Analyze press - the same shape `SRELeadRunner.swift`
// established and `DictationCleanup.swift`/`SRELeadPostmortem.swift`/
// `ConsoleCommandComposer.swift` already reuse (see `SRELeadRunner`'s header
// for the full reasoning: `json` over `stream-json` because only the final
// reply is ever needed, `/dev/null` stdin to skip `claude -p`'s ~3s piped-
// stdin probe, both pipes drained before `waitUntilExit()` to avoid a
// full-buffer deadlock). No HTTP client, no API key, no second AI mechanism.
// `SRELead.resolveClaude()` is reused as-is, exactly as those three do.
//
// Deliberately not reusing `SRELeadRunner` itself: that type threads a
// `session_id` across turns for a conversation pane and carries an MCP
// config plus a restricted `--allowedTools` for its kubectl tool. This is a
// stateless, single-turn, tool-free request whose reply must parse as one
// fixed JSON object - a fifth small caller of the same `Process` shape is
// clearer than stretching that one to cover both.
//
// **Redaction ordering (spec §14).** Every string this file puts in a prompt
// arrives already redacted: `LogAnalyzerController` runs `LogRedactor.redact`
// at evidence-creation time and stores only the masked text on
// `LogEvidenceItem.text`, so there is no unredacted copy left anywhere for
// this file to read even by mistake. `LogAnalyzerSelfTest` proves the
// property the only way that means anything - by grepping the literal bytes
// of a built prompt for planted secret values.
//
// **What the model is not allowed to do.** The prompt asks for JSON only,
// and `parse` is strict about the shape - but two rules are enforced in code
// rather than trusted to the prompt:
//   1. A correlation link the model labels "observed" is downgraded to
//      "inferred" (spec §9 - only the local layer counted the lines, so only
//      it may claim something was observed; see `LogCorrelationBuilder`).
//   2. Suggested commands are re-pointed at the captain's own Command
//      Library afterwards by `LogAnalyzerCommandMatcher` (spec §11's "do not
//      generate arbitrary commands if an equivalent saved command exists"),
//      rather than the model being asked to remember the library's contents.

import Foundation

struct LogAnalyzerAIError: Error {
    let message: String
}

enum LogAnalyzerAI {

    /// Bounded wait for the whole round trip. Generous relative to a typical
    /// `claude -p` turn (SRE Lead's own turns routinely complete in a few
    /// seconds) but far short of "the captain assumes it hung" - and a
    /// timeout is never fatal here: the caller falls back to showing the
    /// local analysis with an inline notice.
    static let timeout: TimeInterval = 120

    /// Test-only seam, same convention as `DictationCleanup.claudePathOverrideForTests`
    /// and `SRELead.claudePathOverrideForTests`: points at a disposable fake
    /// `claude` script so `LogAnalyzerSelfTest` can drive the real
    /// `Process`/parsing code end to end without network access or the
    /// machine's own Claude auth. `nil` (production) resolves the real
    /// binary via `SRELead.resolveClaude()`.
    static var claudePathOverrideForTests: String?

    static var isAvailable: Bool { (claudePathOverrideForTests ?? SRELead.resolveClaude()) != nil }

    // MARK: - Prompt

    /// The shared instructions. One schema for all ten modes (spec §22) -
    /// the mode only changes emphasis, via `LogAnalysisMode.instruction`.
    static func prompt(mode: LogAnalysisMode,
                       detection: LogSourceDetection,
                       groups: [LogErrorGroup],
                       timeline: LogTimeline,
                       body: String,
                       extraContext: String? = nil) -> String {
        var countedPatterns = ""
        if groups.isEmpty {
            countedPatterns = "(none — no lines at warning severity or above were found locally)"
        } else {
            for group in groups {
                var line = "- [\(group.severity.rawValue)] \(group.label): \(group.occurrences) occurrence\(group.occurrences == 1 ? "" : "s")"
                if let range = group.timeRange { line += " (\(range))" }
                countedPatterns += line + "\n"
            }
        }

        var timelineText = ""
        switch timeline {
        case .unavailable(let reason):
            timelineText = "(unavailable — \(reason))"
        case .events(let events):
            for event in events.prefix(20) {
                timelineText += "- \(event.timestamp) \(event.title): \(event.detail)\n"
            }
        }

        return """
        You are an experienced SRE reviewing output an engineer captured from their own \
        infrastructure. Analyse it and reply with ONE JSON object and nothing else — no \
        prose before or after, no markdown code fence.

        \(mode.instruction)

        Rules you must follow:
        - Base every claim on the provided output. If something cannot be established from \
        what is here, say so in "missingEvidence" rather than asserting it.
        - Never state a root cause with more confidence than the evidence supports. \
        "confidence" must be one of "high", "medium", "low".
        - The occurrence counts below were computed locally over the complete input and are \
        exact. Do not recompute, estimate, or contradict them.
        - Do not invent timestamps. Only reference times that appear in the provided output.
        - Every correlation link must be labelled "inferred" (a likely causal relationship) \
        or "unknown" (something that cannot be established here). Do not label anything \
        "observed" — directly observed facts are added separately by the tool that counted them.
        - Suggested commands must be safe, read-only investigation commands. Never suggest a \
        command that deletes, restarts, scales, applies, or otherwise mutates anything.
        - Redaction has already been applied to the output below. Placeholders reading \
        [REDACTED] are intentional; do not speculate about their values.

        Reply with exactly this JSON shape:
        {
          "summary": "one or two sentences describing what happened",
          "findings": [
            {"severity": "critical|high|warning|informational|normal",
             "title": "short headline",
             "detail": "one or two sentences of explanation"}
          ],
          "rootCause": {
            "summary": "one short sentence naming the probable root cause",
            "explanation": "a short paragraph explaining it",
            "confidence": "high|medium|low",
            "evidence": ["what in the output supports this"],
            "missingEvidence": ["what was not provided that would confirm it"],
            "contradictingEvidence": ["anything in the output that argues against it"]
          },
          "nextSteps": ["ordered, concrete actions"],
          "suggestedCommands": [
            {"title": "what this checks",
             "command": "the literal shell command",
             "rationale": "why it helps"}
          ],
          "correlation": [
            {"kind": "inferred|unknown", "text": "one step in the causal chain"}
          ],
          "neededEvidence": ["what additional output would let you confirm the root cause"]
        }

        If a section genuinely does not apply, return it as an empty array (or null for \
        "rootCause"). Do not omit keys.

        Detected source: \(detection.kind.displayName) (\(detection.kind.formatName)).
        Highest severity seen locally: \(detection.severity.displayName).

        Patterns counted locally (exact counts):
        \(countedPatterns)
        Timeline reconstructed locally:
        \(timelineText.isEmpty ? "(none)" : timelineText)
        \(extraContext.map { "\nAdditional context from the engineer:\n\($0)\n" } ?? "")
        ----- BEGIN PROVIDED OUTPUT -----
        \(body)
        ----- END PROVIDED OUTPUT -----
        """
    }

    /// The "Investigate Further" prompt (spec §12) - a much smaller ask that
    /// only wants the list of what is still missing, so it returns fast and
    /// cheap next to a full re-analysis.
    static func investigatePrompt(detection: LogSourceDetection,
                                  rootCause: LogRootCause?,
                                  body: String) -> String {
        let current = rootCause.map {
            "The current working theory is: \($0.summary) (confidence: \($0.confidence.displayName))."
        } ?? "No root cause has been established yet."

        return """
        You are an experienced SRE. \(current)

        Given the output below, list what ADDITIONAL information you would need to confirm \
        or rule out the cause. Be specific and concrete — name the exact command output, \
        manifest, or log that would settle it, not a general category.

        Reply with ONE JSON object and nothing else:
        {"neededEvidence": ["..."], "reason": "one sentence on what each item would settle"}

        Detected source: \(detection.kind.displayName) (\(detection.kind.formatName)).

        ----- BEGIN PROVIDED OUTPUT -----
        \(body)
        ----- END PROVIDED OUTPUT -----
        """
    }

    // MARK: - Running

    /// Runs one analysis. `completion` is always called on the main thread,
    /// exactly once.
    static func analyze(mode: LogAnalysisMode,
                        local: LogLocalAnalysis,
                        body: String,
                        extraContext: String? = nil,
                        completion: @escaping (Result<LogAIAnalysis, LogAnalyzerAIError>) -> Void) {
        let text = prompt(mode: mode, detection: local.detection, groups: local.groups,
                          timeline: local.timeline, body: body, extraContext: extraContext)
        run(prompt: text) { result in
            switch result {
            case .failure(let error): completion(.failure(error))
            case .success(let json):
                guard let parsed = parse(json) else {
                    completion(.failure(LogAnalyzerAIError(message: "claude's reply was not in the expected shape.")))
                    return
                }
                completion(.success(parsed))
            }
        }
    }

    /// Spec §12's dedicated ask.
    static func investigateFurther(detection: LogSourceDetection,
                                   rootCause: LogRootCause?,
                                   body: String,
                                   completion: @escaping (Result<[String], LogAnalyzerAIError>) -> Void) {
        run(prompt: investigatePrompt(detection: detection, rootCause: rootCause, body: body)) { result in
            switch result {
            case .failure(let error): completion(.failure(error))
            case .success(let json):
                let needed = (json["neededEvidence"] as? [Any])?.compactMap { $0 as? String } ?? []
                guard !needed.isEmpty else {
                    completion(.failure(LogAnalyzerAIError(message: "claude did not name any additional evidence.")))
                    return
                }
                completion(.success(needed))
            }
        }
    }

    /// A free-form single-turn ask that returns the model's plain reply text
    /// rather than a parsed schema - used for the artifact generators
    /// (Incident / Runbook / Ticket, spec §17-§19), which want prose.
    static func freeform(prompt: String, completion: @escaping (Result<String, LogAnalyzerAIError>) -> Void) {
        runRaw(prompt: prompt) { result in
            switch result {
            case .failure(let error): completion(.failure(error))
            case .success(let text): completion(.success(text))
            }
        }
    }

    /// Runs the process and parses the outer `claude` envelope, then the
    /// inner JSON object the prompt asked for.
    private static func run(prompt: String,
                            completion: @escaping (Result<[String: Any], LogAnalyzerAIError>) -> Void) {
        runRaw(prompt: prompt) { result in
            switch result {
            case .failure(let error): completion(.failure(error))
            case .success(let reply):
                guard let object = decodeJSONObject(from: reply) else {
                    completion(.failure(LogAnalyzerAIError(message: "claude's reply was not valid JSON.")))
                    return
                }
                completion(.success(object))
            }
        }
    }

    /// The shared `Process` half - identical in shape to
    /// `DictationCleanup.rewrite`'s, including its finish-once lock and
    /// timeout watchdog.
    private static func runRaw(prompt: String,
                               completion: @escaping (Result<String, LogAnalyzerAIError>) -> Void) {
        guard let claude = claudePathOverrideForTests ?? SRELead.resolveClaude() else {
            completion(.failure(LogAnalyzerAIError(message: "claude is not installed or not on PATH.")))
            return
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: claude)
        proc.arguments = ["-p", prompt, "--output-format", "json"]
        proc.environment = childEnvironmentDict()
        proc.standardInput = FileHandle.nullDevice
        let out = Pipe()
        let err = Pipe()
        proc.standardOutput = out
        proc.standardError = err

        var finished = false
        let finishLock = NSLock()
        func finishOnce(_ result: Result<String, LogAnalyzerAIError>) {
            finishLock.lock()
            let already = finished
            finished = true
            finishLock.unlock()
            guard !already else { return }
            DispatchQueue.main.async { completion(result) }
        }

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try proc.run()
            } catch {
                finishOnce(.failure(LogAnalyzerAIError(message: "could not start claude: \(error.localizedDescription)")))
                return
            }
            let outData = out.fileHandleForReading.readDataToEndOfFile()
            let errData = err.fileHandleForReading.readDataToEndOfFile()
            proc.waitUntilExit()
            finishOnce(parseEnvelope(outData: outData, errData: errData, status: proc.terminationStatus))
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
            finishLock.lock()
            let already = finished
            finishLock.unlock()
            guard !already else { return }
            proc.terminate()
            finishOnce(.failure(LogAnalyzerAIError(message: "claude did not respond within \(Int(timeout))s.")))
        }
    }

    /// `claude -p --output-format json` writes one JSON object on completion;
    /// `result` carries the assistant's own reply text.
    static func parseEnvelope(outData: Data, errData: Data, status: Int32) -> Result<String, LogAnalyzerAIError> {
        let stdout = String(data: outData, encoding: .utf8) ?? ""
        let lastLine = stdout.split(separator: "\n", omittingEmptySubsequences: true).last.map(String.init)

        guard let line = lastLine,
              let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            let stderr = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let detail = stderr.isEmpty ? "claude exited with no parseable output (status \(status))." : stderr
            return .failure(LogAnalyzerAIError(message: detail))
        }
        if let isError = obj["is_error"] as? Bool, isError {
            return .failure(LogAnalyzerAIError(message: (obj["result"] as? String) ?? "claude reported an error."))
        }
        guard let result = obj["result"] as? String, !result.isEmpty else {
            return .failure(LogAnalyzerAIError(message: "claude's response had no reply text."))
        }
        return .success(result)
    }

    /// Pulls a JSON object out of the model's reply. Tolerant of the two
    /// things a model does anyway despite being asked not to: wrapping the
    /// object in a ```json fence, and adding a sentence before or after it.
    static func decodeJSONObject(from reply: String) -> [String: Any]? {
        var text = reply.trimmingCharacters(in: .whitespacesAndNewlines)

        if text.hasPrefix("```") {
            // Drop the opening fence line (```json / ```) and the closing one.
            var lines = text.components(separatedBy: "\n")
            lines.removeFirst()
            if let last = lines.last, last.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                lines.removeLast()
            }
            text = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }

        if let data = text.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return obj
        }

        // Last resort: the widest brace-balanced span.
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end else { return nil }
        let slice = String(text[start...end])
        guard let data = slice.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    // MARK: - Parsing the analysis schema

    /// Maps the reply object onto `LogAIAnalysis`. Every field is optional in
    /// practice - a model that omits `nextSteps` yields an empty array rather
    /// than a failed analysis. The one hard requirement is that *something*
    /// usable came back, so a reply with no findings, no root cause and no
    /// summary is treated as a failure rather than rendered as a blank card.
    static func parse(_ json: [String: Any]) -> LogAIAnalysis? {
        let summary = (json["summary"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        let findings: [LogFinding] = (json["findings"] as? [Any] ?? []).compactMap { entry in
            guard let dict = entry as? [String: Any] else { return nil }
            guard let title = (dict["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !title.isEmpty else { return nil }
            let severity = LogSeverity(rawValue: (dict["severity"] as? String)?.lowercased() ?? "") ?? .high
            return LogFinding(severity: severity,
                              title: title,
                              detail: (dict["detail"] as? String) ?? "",
                              meta: nil)
        }

        var rootCause: LogRootCause?
        if let dict = json["rootCause"] as? [String: Any],
           let summaryText = (dict["summary"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !summaryText.isEmpty {
            rootCause = LogRootCause(
                summary: summaryText,
                explanation: (dict["explanation"] as? String) ?? "",
                confidence: LogConfidence.parse((dict["confidence"] as? String) ?? "medium"),
                evidence: stringList(dict["evidence"]),
                missingEvidence: stringList(dict["missingEvidence"]),
                contradictingEvidence: stringList(dict["contradictingEvidence"])
            )
        }

        let nextSteps = stringList(json["nextSteps"])

        let commands: [LogSuggestedCommand] = (json["suggestedCommands"] as? [Any] ?? [])
            .enumerated()
            .compactMap { index, entry in
                guard let dict = entry as? [String: Any] else { return nil }
                guard let command = (dict["command"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !command.isEmpty else { return nil }
                return LogSuggestedCommand(
                    order: index,
                    title: (dict["title"] as? String) ?? command,
                    command: command,
                    rationale: (dict["rationale"] as? String) ?? "",
                    libraryCommandID: nil,
                    libraryCommandName: nil
                )
            }

        // Spec §9, enforced rather than requested: the model never gets to
        // say "observed" - see this file's header.
        let correlation: [LogCorrelationLink] = (json["correlation"] as? [Any] ?? [])
            .enumerated()
            .compactMap { index, entry in
                guard let dict = entry as? [String: Any] else { return nil }
                guard let text = (dict["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !text.isEmpty else { return nil }
                let declared = LogCorrelationKind(rawValue: (dict["kind"] as? String)?.lowercased() ?? "") ?? .inferred
                let kind: LogCorrelationKind = declared == .observed ? .inferred : declared
                return LogCorrelationLink(order: index, kind: kind, text: text, evidence: nil)
            }

        let needed = stringList(json["neededEvidence"])

        guard !findings.isEmpty || rootCause != nil || !summary.isEmpty else { return nil }

        return LogAIAnalysis(
            findings: findings,
            rootCause: rootCause,
            nextSteps: nextSteps,
            suggestedCommands: commands,
            correlation: correlation,
            neededEvidence: needed,
            summary: summary
        )
    }

    private static func stringList(_ value: Any?) -> [String] {
        (value as? [Any] ?? [])
            .compactMap { $0 as? String }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}
