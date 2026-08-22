// Manjesh Grand Line - native macOS app.
//
// Permanent, dependency-free self-test for `ConsoleCommandComposer.generate`
// (`fm/grandline-console-command-composer`) - same convention as
// `DictationCleanupSelfTest.swift`/`SRELeadPostmortemSelfTest.swift`. Drives
// the real `Process`/parsing code in `ConsoleCommandComposer.swift` end to end
// against real, disposable shell scripts standing in for `claude`
// (`ConsoleCommandComposer.claudePathOverrideForTests`), never the real
// `claude` CLI or a real network call.
// `FM_RUN_CONSOLE_COMMAND_COMPOSER_TESTS=1 .build/debug/FirstmateCockpit`.

// GL-27: compiled into debug builds only.
//
// The 51 self-test suites are ~10,500 lines of test code, fault-injection
// seams and fixture data that used to be linked into the binary the captain
// actually runs. `FM_SELFTESTS` is defined by `Package.swift` for the debug
// configuration only, so `swift build` (and therefore CI and
// `Scripts/run-all-tests.sh`) still has every suite, while
// `swift build -c release` - what `native/build_native_app.sh` assembles the
// shipped `.app` from - has none of it.
//
// Do not remove this guard when editing a suite: `Phase3PolishSelfTest`
// asserts that every file in this directory carries it.
#if FM_SELFTESTS

import Foundation

enum ConsoleCommandComposerSelfTest {
    static func run() -> Bool {
        var ok = true
        defer { ConsoleCommandComposer.claudePathOverrideForTests = nil }

        // 1. A well-formed single-line command is parsed and returned as-is.
        do {
            let script = writeFakeClaude(result: "find . -name '*.log' -delete", isError: false)
            defer { try? FileManager.default.removeItem(at: script) }
            ConsoleCommandComposer.claudePathOverrideForTests = script.path
            let outcome = runGenerateSync(intent: "delete all log files in this directory")
            check(outcome.text == "find . -name '*.log' -delete", "a well-formed single-line command should parse cleanly, got \(outcome)")
        }

        // 2. A response wrapped in a code fence and quotes has both stripped
        //    (defensive - the prompt asks for neither, but a model can add
        //    them anyway).
        do {
            let script = writeFakeClaude(result: "```\n\"ls -la\"\n```", isError: false)
            defer { try? FileManager.default.removeItem(at: script) }
            ConsoleCommandComposer.claudePathOverrideForTests = script.path
            let outcome = runGenerateSync(intent: "list files with details")
            check(outcome.text == "ls -la", "a fence-and-quote-wrapped result should be unwrapped, got \(String(describing: outcome.text))")
        }

        // 3. `is_error: true` is treated as a failure, not a success.
        do {
            let script = writeFakeClaude(result: "not authenticated", isError: true)
            defer { try? FileManager.default.removeItem(at: script) }
            ConsoleCommandComposer.claudePathOverrideForTests = script.path
            let outcome = runGenerateSync(intent: "list files")
            check(outcome.isFailure, "is_error:true should be reported as a failure, got \(outcome)")
        }

        // 4. Garbled/non-JSON output is a failure, not a crash and not a
        //    silently-empty "success."
        do {
            let script = writeFakeClaude(rawOutput: "not json at all\n", exitCode: 1)
            defer { try? FileManager.default.removeItem(at: script) }
            ConsoleCommandComposer.claudePathOverrideForTests = script.path
            let outcome = runGenerateSync(intent: "list files")
            check(outcome.isFailure, "garbled output should be reported as a failure, got \(outcome)")
        }

        // 5. A nonexistent claude path (simulating "not installed") fails
        //    cleanly via the `try proc.run()` catch path, not a crash.
        do {
            ConsoleCommandComposer.claudePathOverrideForTests = "/nonexistent/path/to/claude-\(UUID().uuidString)"
            let outcome = runGenerateSync(intent: "list files")
            check(outcome.isFailure, "a nonexistent claude path should fail cleanly, got \(outcome)")
        }

        // 6. An empty intent is rejected up front, no process spawned.
        do {
            ConsoleCommandComposer.claudePathOverrideForTests = "/nonexistent/should-not-be-invoked"
            let outcome = runGenerateSync(intent: "   ")
            check(outcome.isFailure, "an empty intent should fail without spawning a process")
        }

        // 7. The prompt embeds the exact intent text and asks for a single
        //    runnable command with no explanation/fence/quotes.
        do {
            let intent = "restart the nginx service"
            let prompt = ConsoleCommandComposer.prompt(for: intent)
            check(prompt.contains(intent), "prompt should embed the exact intent text")
            check(prompt.contains("ONLY"), "prompt should ask for only the command, no commentary")
            check(prompt.lowercased().contains("code fence"), "prompt should explicitly rule out a code fence")
        }

        return ok

        func check(_ condition: Bool, _ message: String) {
            if !condition {
                print("FAIL: \(message)")
                ok = false
            }
        }
    }

    /// Builds the fake `claude -p --output-format json` payload via
    /// `JSONSerialization` rather than a hand-escaped string literal - safe
    /// for a `result` value containing real newlines/quotes (e.g. a code
    /// fence), which a hand-written JSON literal would need fragile manual
    /// escaping to represent correctly.
    private static func writeFakeClaude(result: String, isError: Bool) -> URL {
        let obj: [String: Any] = ["result": result, "is_error": isError]
        let data = (try? JSONSerialization.data(withJSONObject: obj)) ?? Data()
        let json = String(data: data, encoding: .utf8) ?? "{}"
        return writeFakeClaude(rawOutput: json + "\n", exitCode: 0)
    }

    private static func writeFakeClaude(rawOutput: String, exitCode: Int32) -> URL {
        let dir = FileManager.default.temporaryDirectory
        let path = dir.appendingPathComponent("fake-claude-composer-\(UUID().uuidString).sh")
        let escaped = rawOutput.replacingOccurrences(of: "'", with: "'\\''")
        let script = "#!/bin/sh\nprintf '%s' '\(escaped)'\nexit \(exitCode)\n"
        try? script.write(to: path, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path.path)
        return path
    }

    private struct GenerateOutcome: CustomStringConvertible {
        let text: String?
        var isFailure: Bool { text == nil }
        var description: String { text.map { "success(\($0))" } ?? "failure" }
    }

    /// Waits for `ConsoleCommandComposer.generate`'s async completion by
    /// pumping the main run loop - same rationale as
    /// `SRELeadPostmortemSelfTest.runGenerateSync`: `generate`'s completion is
    /// always dispatched via `DispatchQueue.main.async`, and this self-test
    /// runs before `NSApplication.run()` starts, so blocking on a semaphore
    /// would deadlock against the very block being waited on.
    private static func runGenerateSync(intent: String) -> GenerateOutcome {
        var outcome: GenerateOutcome?
        ConsoleCommandComposer.generate(intent: intent) { result in
            switch result {
            case .success(let text): outcome = GenerateOutcome(text: text)
            case .failure: outcome = GenerateOutcome(text: nil)
            }
        }
        let deadline = Date().addingTimeInterval(15)
        while outcome == nil && Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        return outcome ?? GenerateOutcome(text: nil)
    }
}

#endif
