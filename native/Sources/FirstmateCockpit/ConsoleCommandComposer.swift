// Manjesh Grand Line - native macOS app.
//
// Phase 3 of "Knowledge and speed" (`fm/grandline-console-command-composer`):
// Console's "✨ Compose" control turns a plain-English description of intent
// into a real shell command via one non-interactive
// `claude -p ... --output-format json` call - the exact same `Process`/
// argument/parsing shape `DictationCleanup.swift` and `SRELeadPostmortem.swift`
// already established (see either file's own header for the full reasoning:
// `json` over `stream-json` since only the final reply text is ever needed,
// `/dev/null` stdin to skip `claude -p`'s ~3s piped-stdin probe, draining both
// pipes before `waitUntilExit()` to avoid a full-buffer deadlock). This is a
// third caller of that same shape, not a fourth invention - `SRELead.
// resolveClaude()` is reused as-is, exactly like the other two already do.
//
// The generated command is never run automatically. `ConsoleComposerController`
// (`ConsoleComposerPopover.swift`) is the one UI surface that calls `generate`,
// and it only ever shows the result for review - `ConsoleController`'s "Run in
// terminal" action is the sole path that sends it to a real tab, via the exact
// same `TerminalView.send(txt:)` a Snippet's own "Run" action already uses.
//
// A `claude -p` failure (bad path, no auth, timeout, garbled response) is
// always reported as a clean `.failure`, never a crash - the popover shows it
// inline and lets the captain retry with the same intent text still in the
// field.

import Foundation

enum ConsoleCommandComposer {
    /// Bounded wait for the whole `claude -p` round trip. A single shell
    /// command is a much smaller ask than `SRELeadPostmortem`'s whole-
    /// transcript summarization, so this mirrors `DictationCleanup`'s 20s
    /// rather than that file's more generous 45s.
    static let timeout: TimeInterval = 20

    static func prompt(for intent: String) -> String {
        """
        You generate a single shell command for a captain working in a real \
        macOS Terminal (bash or zsh). Given a plain-English description of \
        intent, reply with ONLY the shell command that accomplishes it - no \
        explanation, no markdown code fence, no commentary, and no leading or \
        trailing quotes. If the intent needs more than one step, chain them \
        with && or ; on a single line rather than replying with multiple \
        lines. If the intent is too vague, ambiguous, or unsafe to turn into a \
        real command, reply with a single line starting with "# " explaining \
        why, so it renders as a comment rather than a runnable command.

        Intent:
        \(intent)
        """
    }

    /// Test-only seam, same convention as `DictationCleanup.claudePathOverrideForTests`/
    /// `SRELeadPostmortem.claudePathOverrideForTests`: a self-test points this
    /// at a real, disposable fake-`claude` script (never the real `claude`
    /// binary) so it can drive `generate`'s actual `Process`/parsing code end
    /// to end with no dependency on real network access or the machine's own
    /// Claude auth. `nil` (the production default) means "resolve the real
    /// `claude` via `SRELead.resolveClaude()`, exactly as before this seam
    /// existed."
    static var claudePathOverrideForTests: String?

    /// Generates the command. `completion` is always called on the main
    /// thread, exactly once, with `.success(command)` or `.failure(reason)` -
    /// the caller treats any failure as "show a clear inline error and let
    /// the captain retry," never as a reason to run anything.
    static func generate(intent: String, completion: @escaping (Result<String, ConsoleCommandComposerError>) -> Void) {
        let trimmed = intent.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            completion(.failure(ConsoleCommandComposerError(message: "describe what you want the command to do")))
            return
        }
        guard let claude = claudePathOverrideForTests ?? SRELead.resolveClaude() else {
            completion(.failure(ConsoleCommandComposerError(message: "claude is not installed or not on PATH")))
            return
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: claude)
        proc.arguments = ["-p", prompt(for: trimmed), "--output-format", "json"]
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
        func finishOnce(_ result: Result<String, ConsoleCommandComposerError>) {
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
                finishOnce(.failure(ConsoleCommandComposerError(message: "could not start claude: \(error.localizedDescription)")))
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
            finishOnce(.failure(ConsoleCommandComposerError(message: "claude did not respond within \(Int(timeout))s")))
        }
    }

    private static func parseResult(outData: Data, errData: Data, status: Int32) -> Result<String, ConsoleCommandComposerError> {
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
            return .failure(ConsoleCommandComposerError(message: detail))
        }

        if let isError = obj["is_error"] as? Bool, isError {
            let detail = (obj["result"] as? String) ?? "claude reported an error."
            return .failure(ConsoleCommandComposerError(message: detail))
        }

        guard let result = obj["result"] as? String else {
            return .failure(ConsoleCommandComposerError(message: "claude's response had no reply text."))
        }
        let cleaned = stripWrappingFormatting(result.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !cleaned.isEmpty else {
            return .failure(ConsoleCommandComposerError(message: "claude's reply was empty."))
        }
        return .success(cleaned)
    }

    /// Defensive only, mirroring `DictationCleanup.stripWrappingQuotes`/
    /// `SRELeadPostmortem.stripWrappingCodeFence`'s own "cheap insurance, not
    /// load-bearing" framing: a model can occasionally wrap a "reply with
    /// only the command" answer in a code fence or quotes despite the
    /// prompt's explicit instruction not to.
    private static func stripWrappingFormatting(_ text: String) -> String {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if let first = lines.first, first.hasPrefix("```") {
            lines.removeFirst()
            if let last = lines.last, last.trimmingCharacters(in: .whitespaces) == "```" {
                lines.removeLast()
            }
        }
        var joined = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        let quotePairs: [(Character, Character)] = [("\"", "\""), ("\u{201C}", "\u{201D}"), ("'", "'")]
        for (open, close) in quotePairs {
            if joined.count >= 2, joined.first == open, joined.last == close {
                joined = String(joined.dropFirst().dropLast())
            }
        }
        return joined
    }
}

struct ConsoleCommandComposerError: Error {
    let message: String
}
