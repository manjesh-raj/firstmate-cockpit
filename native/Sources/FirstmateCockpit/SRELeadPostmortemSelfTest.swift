// Manjesh Grand Line - native macOS app.
//
// Permanent, dependency-free self-test for `SRELeadPostmortem.generate`
// (fm/grandline-sre-lead-postmortem) - same convention as
// `DictationCleanupSelfTest.swift`. Drives the real `Process`/parsing code in
// `SRELeadPostmortem.swift` end to end against real, disposable shell
// scripts standing in for `claude` (`SRELeadPostmortem.claudePathOverrideForTests`),
// never the real `claude` CLI or a real network call.
// `FM_RUN_SRE_LEAD_POSTMORTEM_TESTS=1 .build/debug/FirstmateCockpit`.

import Foundation

enum SRELeadPostmortemSelfTest {
    static func run() -> Bool {
        var ok = true
        defer { SRELeadPostmortem.claudePathOverrideForTests = nil }

        // 1. A well-formed markdown postmortem is parsed and returned as-is.
        do {
            let markdown = "# Pod crash loop on payments-worker\\n\\n## Timeline\\n- checked pod status\\n\\n## Root Cause\\n**Finding:** OOMKilled.\\n\\n## Follow-ups\\n**Recommended next action:** raise memory limit."
            let script = writeFakeClaude(outputJSON: #"{"result": "\#(markdown)", "is_error": false}"#)
            defer { try? FileManager.default.removeItem(at: script) }
            SRELeadPostmortem.claudePathOverrideForTests = script.path
            let outcome = runGenerateSync(transcript: "Captain: why is payments-worker crashing?\n\nSRE Lead: **Finding:** OOMKilled.")
            check(outcome.text?.contains("Root Cause") == true, "a well-formed markdown response should parse cleanly, got \(outcome)")
        }

        // 2. A response wrapped in a ```markdown code fence has the fence
        //    stripped (defensive - the prompt asks for no fence, but a model
        //    can add one anyway).
        do {
            let fenced = "```markdown\\n# Title\\n\\nBody text\\n```"
            let script = writeFakeClaude(outputJSON: #"{"result": "\#(fenced)", "is_error": false}"#)
            defer { try? FileManager.default.removeItem(at: script) }
            SRELeadPostmortem.claudePathOverrideForTests = script.path
            let outcome = runGenerateSync(transcript: "Captain: hello\n\nSRE Lead: hi")
            check(outcome.text == "# Title\n\nBody text", "a code-fence-wrapped result should be unwrapped, got \(String(describing: outcome.text))")
        }

        // 3. `is_error: true` is treated as a failure, not a success.
        do {
            let script = writeFakeClaude(outputJSON: #"{"result": "not authenticated", "is_error": true}"#)
            defer { try? FileManager.default.removeItem(at: script) }
            SRELeadPostmortem.claudePathOverrideForTests = script.path
            let outcome = runGenerateSync(transcript: "Captain: hello\n\nSRE Lead: hi")
            check(outcome.isFailure, "is_error:true should be reported as a failure, got \(outcome)")
        }

        // 4. Garbled/non-JSON output is a failure, not a crash and not a
        //    silently-empty "success."
        do {
            let script = writeFakeClaude(rawOutput: "not json at all\n", exitCode: 1)
            defer { try? FileManager.default.removeItem(at: script) }
            SRELeadPostmortem.claudePathOverrideForTests = script.path
            let outcome = runGenerateSync(transcript: "Captain: hello\n\nSRE Lead: hi")
            check(outcome.isFailure, "garbled output should be reported as a failure, got \(outcome)")
        }

        // 5. A nonexistent claude path (simulating "not installed") fails
        //    cleanly via the `try proc.run()` catch path, not a crash - and,
        //    crucially, does not lose the transcript that was passed in: the
        //    caller (`ConsoleController.generatePostmortemClicked`) never
        //    clears the chat on failure, only this function's own result
        //    matters here.
        do {
            SRELeadPostmortem.claudePathOverrideForTests = "/nonexistent/path/to/claude-\(UUID().uuidString)"
            let outcome = runGenerateSync(transcript: "Captain: hello\n\nSRE Lead: hi")
            check(outcome.isFailure, "a nonexistent claude path should fail cleanly, got \(outcome)")
        }

        // 6. An empty transcript is rejected up front, no process spawned.
        do {
            SRELeadPostmortem.claudePathOverrideForTests = "/nonexistent/should-not-be-invoked"
            let outcome = runGenerateSync(transcript: "   ")
            check(outcome.isFailure, "an empty transcript should fail without spawning a process")
        }

        // 7. The prompt embeds the exact transcript and the host label, and
        //    asks for the fixed Timeline/Root Cause/Follow-ups structure - a
        //    change to this shape without keeping the section headings in
        //    sync would silently break the "reads consistently with SRE
        //    Lead's own findings" goal.
        do {
            let transcript = "Captain: why is the pod restarting?\n\nSRE Lead: OOMKilled."
            let prompt = SRELeadPostmortem.prompt(hostLabel: "EKS Preprod Bastion", transcript: transcript)
            check(prompt.contains(transcript), "prompt should embed the exact transcript text")
            check(prompt.contains("EKS Preprod Bastion"), "prompt should embed the host label")
            check(prompt.contains("## Timeline"), "prompt should ask for a Timeline section")
            check(prompt.contains("## Root Cause"), "prompt should ask for a Root Cause section")
            check(prompt.contains("## Follow-ups"), "prompt should ask for a Follow-ups section")
            check(prompt.contains("**Finding:**"), "prompt should reuse SRE Lead's own Finding callout label")
            check(prompt.contains("**Recommended next action:**"), "prompt should reuse SRE Lead's own Recommended-next-action callout label")
        }

        return ok

        func check(_ condition: Bool, _ message: String) {
            if !condition {
                print("FAIL: \(message)")
                ok = false
            }
        }
    }

    private static func writeFakeClaude(outputJSON: String) -> URL {
        writeFakeClaude(rawOutput: outputJSON + "\n", exitCode: 0)
    }

    private static func writeFakeClaude(rawOutput: String, exitCode: Int32) -> URL {
        let dir = FileManager.default.temporaryDirectory
        let path = dir.appendingPathComponent("fake-claude-postmortem-\(UUID().uuidString).sh")
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

    /// Waits for `SRELeadPostmortem.generate`'s async completion by pumping
    /// the main run loop - same rationale as `DictationCleanupSelfTest.runRewriteSync`:
    /// `generate`'s completion is always dispatched via `DispatchQueue.main.async`,
    /// and this self-test runs before `NSApplication.run()` starts, so
    /// blocking on a semaphore would deadlock against the very block being
    /// waited on.
    private static func runGenerateSync(transcript: String) -> GenerateOutcome {
        var outcome: GenerateOutcome?
        SRELeadPostmortem.generate(hostLabel: "test-host", transcript: transcript) { result in
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
