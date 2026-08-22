// Manjesh Grand Line - native macOS app.
//
// `swift build && FM_RUN_CLAUDE_ONE_SHOT_TESTS=1 .build/debug/FirstmateCockpit`
//
// GL-26's regression guard: the five `claude -p` runners collapsed into
// `ClaudeOneShot`, so the parse that used to exist in five drifted copies now
// has one set of tests instead of the partial coverage each copy had.
//
// Same fake-`claude` convention as `DictationCleanupSelfTest` /
// `SRELeadPostmortemSelfTest` / `ConsoleCommandComposerSelfTest`: a real,
// disposable shell script standing in for the binary, so the actual `Process`
// path, argv shape and parsing all run for real with no network, no auth and
// no dependency on `claude` being installed. Those three suites still exist
// and still drive their own callers end to end - this one covers the shared
// layer underneath them, including the malformed payloads a fake CLI is
// awkward to coax into producing.

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

enum ClaudeOneShotSelfTest {

    private static var failures: [String] = []

    private static func check(_ condition: Bool, _ label: String) {
        if condition {
            print("  ✓ \(label)")
        } else {
            print("  ✗ \(label)")
            failures.append(label)
        }
    }

    static func run() -> Bool {
        print("== ClaudeOneShot self-test (GL-26) ==")
        failures = []

        parsesAWellFormedReply()
        parsesSessionIDForConversationResume()
        rejectsAnErrorReply()
        rejectsAnEmptyReply()
        rejectsGarbledOutput()
        ignoresChatterBeforeTheJSONLine()
        reportsLaunchFailureAndTimeoutDistinctly()
        runsARealFakeClaudeEndToEnd()
        argvShapeIsWhatCallersExpect()

        print(failures.isEmpty
            ? "== PASS (ClaudeOneShot) =="
            : "== FAIL (ClaudeOneShot): \(failures.count) case(s) ==")
        return failures.isEmpty
    }

    // MARK: - parse()

    private static func exited(_ stdout: String, stderr: String = "", status: Int32 = 0) -> SubprocessResult {
        SubprocessResult(outcome: .exited, status: status,
                         stdoutData: Data(stdout.utf8), stderrData: Data(stderr.utf8), duration: 0.1)
    }

    private static func parsesAWellFormedReply() {
        print("- a well-formed --output-format json payload yields the reply text")
        let result = ClaudeOneShot.parse(exited(#"{"result":"  Finding: the node is NotReady.  ","is_error":false}"#))
        switch result {
        case .success(let reply):
            check(reply.text == "Finding: the node is NotReady.", "the text is trimmed: '\(reply.text)'")
            check(reply.sessionID == nil, "no session_id present means nil, not an empty string")
        case .failure(let error):
            check(false, "expected success, got: \(error.message)")
        }
    }

    private static func parsesSessionIDForConversationResume() {
        print("- session_id is carried through, which is what makes --resume work")
        let result = ClaudeOneShot.parse(exited(#"{"result":"ok","session_id":"abc-123"}"#))
        if case .success(let reply) = result {
            check(reply.sessionID == "abc-123", "session_id: \(reply.sessionID ?? "nil")")
        } else {
            check(false, "expected success")
        }
    }

    private static func rejectsAnErrorReply() {
        print("- is_error:true is a failure carrying claude's own message")
        let result = ClaudeOneShot.parse(exited(#"{"result":"not authenticated","is_error":true}"#))
        if case .failure(let error) = result {
            check(error.message == "not authenticated", "the message is claude's own: '\(error.message)'")
        } else {
            check(false, "expected failure for is_error:true")
        }
    }

    private static func rejectsAnEmptyReply() {
        print("- an empty reply is a failure, not a silent empty render")
        // Two of the five original copies accepted this and three rejected it;
        // rejecting is what stops an empty paste/render looking like a
        // deliberate "nothing to say".
        for payload in [#"{"result":""}"#, #"{"result":"   \n  "}"#] {
            if case .failure = ClaudeOneShot.parse(exited(payload)) {
                check(true, "rejected: \(payload)")
            } else {
                check(false, "should have rejected: \(payload)")
            }
        }
    }

    private static func rejectsGarbledOutput() {
        print("- unparseable output falls back to stderr as the reason")
        let result = ClaudeOneShot.parse(exited("this is not json at all", stderr: "claude: bad flag", status: 2))
        if case .failure(let error) = result {
            check(error.message == "claude: bad flag", "stderr is preferred when present: '\(error.message)'")
        } else {
            check(false, "expected failure")
        }

        let noStderr = ClaudeOneShot.parse(exited("still not json", status: 3))
        if case .failure(let error) = noStderr {
            check(error.message.contains("status 3"), "with no stderr the exit status is named: '\(error.message)'")
        } else {
            check(false, "expected failure")
        }

        // Valid JSON that is not an object with a `result` key.
        if case .failure = ClaudeOneShot.parse(exited(#"{"unexpected":true}"#)) {
            check(true, "a JSON object with no result key is a failure")
        } else {
            check(false, "should have rejected a payload with no result key")
        }
    }

    private static func ignoresChatterBeforeTheJSONLine() {
        print("- progress lines before the JSON object do not break the parse")
        let stdout = "loading config\nthinking...\n" + #"{"result":"answer"}"#
        if case .success(let reply) = ClaudeOneShot.parse(exited(stdout)) {
            check(reply.text == "answer", "the last non-empty line is the payload")
        } else {
            check(false, "expected success")
        }
    }

    private static func reportsLaunchFailureAndTimeoutDistinctly() {
        print("- launch failure and timeout are distinguishable failures")

        let launch = ClaudeOneShot.parse(.launchFailure("No such file"))
        if case .failure(let error) = launch {
            check(error.message.contains("could not start claude"), "launch: '\(error.message)'")
        } else {
            check(false, "expected a launch failure")
        }

        let timedOut = SubprocessResult(outcome: .timedOut, status: Subprocess.timedOutStatus,
                                        stdoutData: Data(), stderrData: Data(), duration: 20)
        if case .failure(let error) = ClaudeOneShot.parse(timedOut) {
            check(error.message.contains("did not respond within"), "timeout: '\(error.message)'")
        } else {
            check(false, "expected a timeout failure")
        }
    }

    // MARK: - The real Process path

    private static func runsARealFakeClaudeEndToEnd() {
        print("- a real (fake) claude binary is invoked and its reply parsed")

        guard let script = makeFakeClaude(body: #"""
        printf '%s\n' '{"result":"the disk is full","session_id":"sess-9"}'
        """#) else {
            check(false, "could not write the fake claude script")
            return
        }
        defer { try? FileManager.default.removeItem(at: script.deletingLastPathComponent()) }

        let done = DispatchSemaphore(value: 0)
        var received: Result<ClaudeReply, ClaudeOneShotError>?
        ClaudeOneShot.run(executable: script.path, prompt: "what is wrong?", timeout: 20) { result in
            received = result
            done.signal()
        }
        // `run`'s completion is dispatched to main, so a blocking wait here
        // would deadlock - pump the main run loop instead, the same way this
        // project's other completion-driven self-tests do.
        let deadline = Date().addingTimeInterval(20)
        while received == nil, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        _ = done.wait(timeout: .now())

        switch received {
        case .success(let reply):
            check(reply.text == "the disk is full", "reply: '\(reply.text)'")
            check(reply.sessionID == "sess-9", "session id came through the real process path")
        case .failure(let error):
            check(false, "expected success, got: \(error.message)")
        case nil:
            check(false, "the completion never fired")
        }
    }

    private static func argvShapeIsWhatCallersExpect() {
        print("- argv: -p <prompt>, caller extras, then --output-format json (+ --resume)")

        guard let script = makeFakeClaude(body: #"""
        printf '%s\n' "$@" > "$(dirname "$0")/argv.txt"
        printf '%s\n' '{"result":"ok"}'
        """#) else {
            check(false, "could not write the fake claude script")
            return
        }
        let dir = script.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: dir) }

        var finished = false
        ClaudeOneShot.run(
            executable: script.path,
            prompt: "PROMPT-TEXT",
            extraArguments: ["--allowedTools", "Task"],
            resumeSessionID: "sess-1",
            timeout: 20
        ) { _ in finished = true }
        let deadline = Date().addingTimeInterval(20)
        while !finished, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }

        let argv = (try? String(contentsOf: dir.appendingPathComponent("argv.txt"), encoding: .utf8))?
            .split(separator: "\n").map(String.init) ?? []
        check(argv.first == "-p", "argv starts with -p")
        check(argv.count > 1 && argv[1] == "PROMPT-TEXT",
              "the prompt is one argv element - never shell-interpolated, so backticks in it are inert")
        check(argv.contains("--allowedTools") && argv.contains("Task"), "caller extras are present")
        check(argv.contains("--output-format") && argv.contains("json"), "--output-format json is present")
        if let idx = argv.firstIndex(of: "--resume") {
            check(idx + 1 < argv.count && argv[idx + 1] == "sess-1", "--resume carries the session id")
        } else {
            check(false, "--resume was not passed")
        }
    }

    // MARK: - Helpers

    /// A disposable executable shell script in its own temp directory. Never
    /// the real `claude` binary, and never anywhere near the captain's data.
    private static func makeFakeClaude(body: String) -> URL? {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("grandline-claude-oneshot-test-\(UUID().uuidString)")
        let script = dir.appendingPathComponent("claude")
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try "#!/bin/sh\n\(body)\n".write(to: script, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        } catch {
            return nil
        }
        return script
    }
}

#endif
