// Manjesh Grand Line - native macOS app.
//
// Permanent, dependency-free self-test for `DictationCleanup.rewrite` (phase
// 3, fm/grandline-dictation-phase3) - same convention as
// `DictationDataSelfTest.swift`/`DictationHotkeySelfTest.swift`. Drives the
// real `Process`/parsing code in `DictationCleanup.swift` end to end against
// real, disposable shell scripts standing in for `claude`
// (`DictationCleanup.claudePathOverrideForTests`), never the real `claude`
// CLI or a real network call - this is what makes the test fast and
// deterministic instead of depending on the machine's own Claude
// authentication.
// `FM_RUN_DICTATION_CLEANUP_TESTS=1 .build/debug/FirstmateCockpit`.

import Foundation

enum DictationCleanupSelfTest {
    static func run() -> Bool {
        var ok = true
        defer { DictationCleanup.claudePathOverrideForTests = nil }

        // 1. A well-formed success response is parsed and returned as-is.
        do {
            let script = writeFakeClaude(outputJSON: #"{"result": "This is a clean sentence.", "is_error": false}"#)
            defer { try? FileManager.default.removeItem(at: script) }
            DictationCleanup.claudePathOverrideForTests = script.path
            let expectation = runRewriteSync("uh so like the the thing is broken i think")
            check(expectation == .success("This is a clean sentence."), "well-formed success response should parse cleanly", &ok)
        }

        // 2. A response wrapped in straight quotes is unwrapped.
        do {
            let script = writeFakeClaude(outputJSON: #"{"result": "\"Quoted clean sentence.\"", "is_error": false}"#)
            defer { try? FileManager.default.removeItem(at: script) }
            DictationCleanup.claudePathOverrideForTests = script.path
            let expectation = runRewriteSync("some rough transcript")
            check(expectation == .success("Quoted clean sentence."), "a quote-wrapped result should be unwrapped, got \(expectation)", &ok)
        }

        // 3. `is_error: true` is treated as a failure, not a success.
        do {
            let script = writeFakeClaude(outputJSON: #"{"result": "not authenticated", "is_error": true}"#)
            defer { try? FileManager.default.removeItem(at: script) }
            DictationCleanup.claudePathOverrideForTests = script.path
            let expectation = runRewriteSync("some rough transcript")
            check(expectation.isFailure, "is_error:true should be reported as a failure, got \(expectation)", &ok)
        }

        // 4. Garbled/non-JSON output (simulating a crash or unexpected format)
        //    is a failure, not a crash and not treated as success.
        do {
            let script = writeFakeClaude(rawOutput: "not json at all\n", exitCode: 1)
            defer { try? FileManager.default.removeItem(at: script) }
            DictationCleanup.claudePathOverrideForTests = script.path
            let expectation = runRewriteSync("some rough transcript")
            check(expectation.isFailure, "garbled output should be reported as a failure, got \(expectation)", &ok)
        }

        // 5. A nonexistent claude path (simulating "not installed") fails
        //    cleanly via the `try proc.run()` catch path, not a crash.
        do {
            DictationCleanup.claudePathOverrideForTests = "/nonexistent/path/to/claude-\(UUID().uuidString)"
            let expectation = runRewriteSync("some rough transcript")
            check(expectation.isFailure, "a nonexistent claude path should fail cleanly, got \(expectation)", &ok)
        }

        // 6. An empty transcript is rejected up front, no process spawned.
        do {
            DictationCleanup.claudePathOverrideForTests = "/nonexistent/should-not-be-invoked"
            let expectation = runRewriteSync("   ")
            check(expectation.isFailure, "an empty/whitespace-only transcript should fail without spawning a process", &ok)
        }

        // 7. The prompt sent to claude contains the exact transcript and asks
        //    for a plain-text-only rewrite - a change to this shape without
        //    updating `stripWrappingQuotes`'s defensive parsing would be easy
        //    to miss otherwise.
        do {
            let transcript = "so basically what im trying to say is"
            let prompt = DictationCleanup.prompt(for: transcript)
            check(prompt.contains(transcript), "prompt should embed the exact transcript text", &ok)
            check(prompt.lowercased().contains("only"), "prompt should ask for the rewrite only, no extra commentary", &ok)
        }

        return ok
    }

    /// A fake `claude` executable: a shell script that ignores its real
    /// arguments (mirroring how `claude -p ... --output-format json` is
    /// actually invoked) and prints one line of canned output, exactly the
    /// shape `DictationCleanup.parseResult` expects to parse (its last
    /// non-empty stdout line).
    private static func writeFakeClaude(outputJSON: String) -> URL {
        writeFakeClaude(rawOutput: outputJSON + "\n", exitCode: 0)
    }

    private static func writeFakeClaude(rawOutput: String, exitCode: Int32) -> URL {
        let dir = FileManager.default.temporaryDirectory
        let path = dir.appendingPathComponent("fake-claude-\(UUID().uuidString).sh")
        let escaped = rawOutput.replacingOccurrences(of: "'", with: "'\\''")
        let script = "#!/bin/sh\nprintf '%s' '\(escaped)'\nexit \(exitCode)\n"
        try? script.write(to: path, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path.path)
        return path
    }

    private enum RewriteOutcome: Equatable {
        case success(String)
        case failure

        static func == (lhs: RewriteOutcome, rhs: RewriteOutcome) -> Bool {
            switch (lhs, rhs) {
            case (.success(let a), .success(let b)): return a == b
            case (.failure, .failure): return true
            default: return false
            }
        }

        var isFailure: Bool {
            if case .failure = self { return true }
            return false
        }
    }

    /// Waits for `DictationCleanup.rewrite`'s async completion by pumping the
    /// main run loop, not by blocking on a semaphore - `rewrite`'s completion
    /// is always dispatched via `DispatchQueue.main.async` (see that file's
    /// own doc comment), and this self-test runs on the main thread with no
    /// `NSApplication.run()` loop active yet (`main.swift` calls this before
    /// `app.run()`, matching `ShiftGitSyncSelfTest.swift`'s own note about
    /// the same constraint) - blocking that same thread on a semaphore would
    /// prevent the main dispatch queue from ever draining the very block
    /// this is waiting on, deadlocking every run. `RunLoop.main.run(mode:before:)`
    /// still drains the main dispatch queue's run-loop source even without
    /// AppKit's own event loop running.
    private static func runRewriteSync(_ transcript: String) -> RewriteOutcome {
        var outcome: RewriteOutcome?
        DictationCleanup.rewrite(transcript) { result in
            switch result {
            case .success(let text): outcome = .success(text)
            case .failure: outcome = .failure
            }
        }
        let deadline = Date().addingTimeInterval(15)
        while outcome == nil && Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        return outcome ?? .failure
    }

    private static func check(_ condition: Bool, _ message: String, _ ok: inout Bool) {
        if !condition {
            print("FAIL: \(message)")
            ok = false
        }
    }
}
