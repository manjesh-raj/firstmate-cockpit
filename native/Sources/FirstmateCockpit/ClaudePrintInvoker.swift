// Manjesh Grand Line - native macOS app.
//
// Shared low-level plumbing for a single non-interactive
// `claude -p ... --output-format json` call - the `Process`/pipe-draining
// pattern `SRELeadRunner` established first (see that file's header for why
// `json`, not `stream-json`). Extracted here (`fm/cockpit-block-view-ssh-only`,
// originally PR #80) so the "Explain this" block action can shell out to
// `claude` the same way instead of hand-rolling a second copy of this -
// callers own their own argv and JSON interpretation; this only runs the
// process and hands back the parsed JSON object (or a failure message) on
// the main thread.

import Foundation

/// A failure from a `claude -p` invocation - just a message, shared by every
/// caller of `ClaudePrintInvoker` so none of them has to invent its own
/// wrapper just to satisfy `Result`'s `Error` conformance requirement.
struct ClaudeCallError: Error {
    let message: String
}

enum ClaudePrintInvoker {
    /// Runs `claude` with `args`, draining both pipes concurrently with the
    /// child (a pipe's buffer filling can deadlock the child otherwise), and
    /// calls `completion` on the main thread with the parsed JSON object from
    /// the last non-empty stdout line, or a failure message built from
    /// stderr/exit status. Returns the `Process` so a caller that wants to
    /// support cancellation (as `SRELeadRunner` does) can hold onto it.
    @discardableResult
    static func run(
        claude: String,
        args: [String],
        currentDirectory: URL?,
        completion: @escaping (Result<[String: Any], ClaudeCallError>) -> Void
    ) -> Process {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: claude)
        proc.arguments = args
        proc.environment = childEnvironmentDict()
        if let currentDirectory {
            proc.currentDirectoryURL = currentDirectory
        }
        let out = Pipe()
        let err = Pipe()
        proc.standardOutput = out
        proc.standardError = err
        // Without this, `claude -p` probes for piped stdin and (confirmed
        // live in the SRE Lead task) waits ~3s before proceeding without it,
        // on every single call - `/dev/null` tells it immediately there's
        // nothing coming.
        proc.standardInput = FileHandle.nullDevice

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try proc.run()
            } catch {
                DispatchQueue.main.async {
                    completion(.failure(ClaudeCallError(message: "could not start claude: \(error.localizedDescription)")))
                }
                return
            }
            let outData = out.fileHandleForReading.readDataToEndOfFile()
            let errData = err.fileHandleForReading.readDataToEndOfFile()
            proc.waitUntilExit()
            let status = proc.terminationStatus
            DispatchQueue.main.async {
                completion(Self.parse(outData: outData, errData: errData, status: status))
            }
        }
        return proc
    }

    private static func parse(outData: Data, errData: Data, status: Int32) -> Result<[String: Any], ClaudeCallError> {
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
            return .failure(ClaudeCallError(message: detail))
        }
        return .success(obj)
    }
}
