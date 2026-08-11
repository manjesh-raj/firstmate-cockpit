// Manjesh Grand Line - native macOS app.
//
// `fm/cockpit-sre-lead-shared-terminal`: a self-contained, dependency-free
// regression check for `SRELeadBridge`'s polling/extraction/busy-detection
// logic, run against `FakeBridgeTerminal` - a lightweight stand-in for
// `CockpitTerminalView` that needs no AppKit or SwiftTerm, exercising exactly
// the `SRELeadBridgeTerminal` protocol the real `TabModel` conforms to. This
// is the "verify the LOCAL half of the mechanism thoroughly even without a
// real bastion" half of the acceptance criteria - the Python side has its
// own tests in `native/Scripts/test_sre_kubectl_mcp.py`.
//
// Why not a real `swift test` target: this project builds with Command Line
// Tools only (no Xcode - see `native/README.md`). CLT has no
// `XCTest.framework` at all (`xcrun --find xctest` fails). CLT *does* ship
// `Testing.framework` (swift-testing, bundled with the Swift 6 toolchain
// itself), and a `.testTarget` can be coaxed into compiling and linking
// against it with explicit `-F`/`-framework Testing` flags plus two `-rpath`
// entries - confirmed live, that part works. But the resulting
// `swift test`/`swiftpm-testing-helper` invocation produced no test output
// and exited 0 with zero tests reported, on both the plain `swift test` path
// and a manual `swiftpm-testing-helper --testing-library swift-testing`
// invocation of the built bundle - this CLT toolchain's `swift-testing`
// "bundle" discovery/hosting path appears to depend on something Xcode
// provides that CLT doesn't (bumping `swift-tools-version` to 6.0 to get
// SwiftPM's automatic swift-testing linkage instead of the manual flags was
// also tried and rejected: it turns on Swift 6 strict concurrency checking
// for the whole package, which does not compile against the vendored
// SwiftTerm module - see the `Package.swift` comment on why that module
// can't be touched that way). Rather than ship a test target that silently
// runs zero tests, this uses the same "env-var-gated, run and read the
// result" convention the codebase already relies on for AppKit UI
// verification in this same CLT-only environment (see AGENTS.md's
// "Verifying native UI bugs without a real screenshot") - `SRELeadBridgeSelfTest.run()`
// is called from `main.swift` when `FM_RUN_SRE_LEAD_BRIDGE_TESTS=1` is set,
// before any window opens, and its result becomes the process exit code:
//
//   swift build && FM_RUN_SRE_LEAD_BRIDGE_TESTS=1 .build/debug/FirstmateCockpit; echo $?

import Foundation

/// Simulates a terminal tab: `sendCommand` appends the terminal's own echo of
/// the typed line (matching real terminal behavior - a typed line is echoed
/// before it produces any output), and tests append simulated command output
/// afterward via `appendOutput`.
final class FakeBridgeTerminal: SRELeadBridgeTerminal {
    private(set) var lines: [String] = []
    private(set) var sentCommands: [String] = []
    var lastUserActivity: Date?

    /// Fires synchronously from `sendCommand`, with the exact text
    /// `SRELeadBridge` injected (including the wrapping `echo <marker>; ...`)
    /// - tests use this to discover the fresh random markers and script a
    /// realistic response before the bridge's next poll.
    var onSendCommand: ((String) -> Void)?

    func sendCommand(_ text: String) {
        sentCommands.append(text)
        let typed = text.hasSuffix("\n") ? String(text.dropLast()) : text
        lines.append(typed) // the terminal's own echo of what was typed
        onSendCommand?(text)
    }

    func currentBufferLines() -> [String] { lines }

    func appendOutput(_ text: String) {
        lines.append(contentsOf: text.components(separatedBy: "\n"))
    }

    func appendRawLine(_ line: String) {
        lines.append(line)
    }
}

enum SRELeadBridgeSelfTest {

    /// Runs every case, printing a `PASS`/`FAIL` line per case and a summary.
    /// Returns `true` only if every case passed.
    static func run() -> Bool {
        let cases: [(String, (URL) -> String?)] = [
            ("extractsRealOutputBetweenMarkers", test_extractsRealOutputBetweenMarkers),
            ("ignoresUnrelatedContentAlreadyInScrollback", test_ignoresUnrelatedContentAlreadyInScrollback),
            ("refusesRequestWhenCaptainRecentlyTypedBeforeInjection", test_refusesRequestWhenCaptainRecentlyTypedBeforeInjection),
            ("refusesConcurrentRequestWhileOneIsInFlight", test_refusesConcurrentRequestWhileOneIsInFlight),
            ("discardsOutputWhenCaptainTypesWhileCommandIsRunning", test_discardsOutputWhenCaptainTypesWhileCommandIsRunning),
            ("timesOutIfEndMarkerNeverAppears", test_timesOutIfEndMarkerNeverAppears),
            ("errorsCleanlyWhenTargetTabIsGone", test_errorsCleanlyWhenTargetTabIsGone),
        ]

        var failures = 0
        for (name, testCase) in cases {
            let dir = makeScratchDir()
            defer { try? FileManager.default.removeItem(at: dir) }
            if let failure = testCase(dir) {
                print("FAIL \(name): \(failure)")
                failures += 1
            } else {
                print("PASS \(name)")
            }
        }
        print(failures == 0 ? "SRELeadBridgeSelfTest: all \(cases.count) cases passed" : "SRELeadBridgeSelfTest: \(failures)/\(cases.count) cases FAILED")
        return failures == 0
    }

    // MARK: Helpers

    private static func makeScratchDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sre-lead-bridge-selftest-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func writeRequest(dir: URL, id: String, command: String) throws {
        let data = try JSONSerialization.data(withJSONObject: ["command": command])
        try data.write(to: dir.appendingPathComponent("request-\(id).json"))
    }

    private static func readResponse(dir: URL, id: String) -> [String: Any]? {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent("response-\(id).json")) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func requestFileExists(dir: URL, id: String) -> Bool {
        FileManager.default.fileExists(atPath: dir.appendingPathComponent("request-\(id).json").path)
    }

    /// Extracts the two fresh markers `SRELeadBridge` wraps a command with
    /// from the exact text it injected (`"echo <start>; <command>; echo
    /// <end>\n"`), so a case can script realistic output without knowing the
    /// random UUID suffix ahead of time.
    private static func markers(in injected: String) -> (start: String, end: String)? {
        let pattern = "SRE_LEAD_(START|END)_[0-9a-fA-F]+"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = injected as NSString
        let found = regex.matches(in: injected, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range) }
        guard found.count == 2 else { return nil }
        guard let start = found.first(where: { $0.contains("START") }),
              let end = found.first(where: { $0.contains("END") }) else { return nil }
        return (start, end)
    }

    /// Ticks `bridge` until `condition` is true or `maxTicks` is reached.
    private static func tickUntil(_ bridge: SRELeadBridge, maxTicks: Int = 20, _ condition: () -> Bool) {
        for _ in 0..<maxTicks where !condition() {
            bridge.tick()
        }
    }

    // MARK: Cases - each returns `nil` on success, or a failure message.

    private static func test_extractsRealOutputBetweenMarkers(with dir: URL) -> String? {
        let fake = FakeBridgeTerminal()
        let bridge = SRELeadBridge(bridgeDir: dir, target: fake)
        fake.onSendCommand = { injected in
            guard let (start, end) = markers(in: injected) else { return }
            fake.appendOutput("\(start)\npod/api-1   1/1   Running\npod/api-2   1/1   Running\n\(end)")
        }

        do { try writeRequest(dir: dir, id: "abc123", command: "kubectl get pods") } catch { return "writeRequest threw: \(error)" }
        tickUntil(bridge) { readResponse(dir: dir, id: "abc123") != nil }

        guard let response = readResponse(dir: dir, id: "abc123") else { return "no response written" }
        guard response["ok"] as? Bool == true else { return "expected ok=true, got \(response)" }
        let expected = "pod/api-1   1/1   Running\npod/api-2   1/1   Running"
        guard response["output"] as? String == expected else { return "unexpected output: \(response["output"] ?? "nil")" }
        guard !requestFileExists(dir: dir, id: "abc123") else { return "request file was not claimed/deleted" }
        return nil
    }

    private static func test_ignoresUnrelatedContentAlreadyInScrollback(with dir: URL) -> String? {
        let fake = FakeBridgeTerminal()
        // Pre-existing scrollback from an earlier, unrelated session in this
        // same tab - the extraction must never look here, only at content
        // appended after this request's own injection.
        fake.appendRawLine("$ echo SRE_LEAD_START_deadbeef; some old leftover; echo SRE_LEAD_END_deadbeef")
        fake.appendRawLine("SRE_LEAD_START_deadbeef")
        fake.appendRawLine("stale output that must never be returned")
        fake.appendRawLine("SRE_LEAD_END_deadbeef")

        let bridge = SRELeadBridge(bridgeDir: dir, target: fake)
        fake.onSendCommand = { injected in
            guard let (start, end) = markers(in: injected) else { return }
            fake.appendOutput("\(start)\nNAMESPACE   NAME\ndefault     web-1\n\(end)")
        }

        do { try writeRequest(dir: dir, id: "fresh1", command: "kubectl get pods -A") } catch { return "writeRequest threw: \(error)" }
        tickUntil(bridge) { readResponse(dir: dir, id: "fresh1") != nil }

        guard let response = readResponse(dir: dir, id: "fresh1") else { return "no response written" }
        guard response["ok"] as? Bool == true else { return "expected ok=true, got \(response)" }
        guard response["output"] as? String == "NAMESPACE   NAME\ndefault     web-1" else {
            return "extraction leaked stale scrollback: \(response["output"] ?? "nil")"
        }
        return nil
    }

    private static func test_refusesRequestWhenCaptainRecentlyTypedBeforeInjection(with dir: URL) -> String? {
        let fake = FakeBridgeTerminal()
        fake.lastUserActivity = Date() // "typing right now"
        let bridge = SRELeadBridge(bridgeDir: dir, target: fake, userActivityQuietWindow: 5)

        do { try writeRequest(dir: dir, id: "busy1", command: "kubectl get pods") } catch { return "writeRequest threw: \(error)" }
        bridge.tick()

        guard let response = readResponse(dir: dir, id: "busy1") else { return "no response written" }
        guard response["ok"] as? Bool == false else { return "expected ok=false, got \(response)" }
        guard response["error"] != nil else { return "expected an error message" }
        guard fake.sentCommands.isEmpty else { return "command was injected despite recent captain activity" }
        return nil
    }

    private static func test_refusesConcurrentRequestWhileOneIsInFlight(with dir: URL) -> String? {
        let fake = FakeBridgeTerminal()
        let bridge = SRELeadBridge(bridgeDir: dir, target: fake)

        do { try writeRequest(dir: dir, id: "first", command: "kubectl get pods") } catch { return "writeRequest threw: \(error)" }
        bridge.tick() // claims + injects "first"; markers not resolved yet, no output supplied

        do { try writeRequest(dir: dir, id: "second", command: "kubectl get nodes") } catch { return "writeRequest threw: \(error)" }
        bridge.tick() // "first" still running (no end marker yet) - "second" must be refused, not queued

        guard let secondResponse = readResponse(dir: dir, id: "second") else { return "no response written for the concurrent request" }
        guard secondResponse["ok"] as? Bool == false else { return "expected the concurrent request to be refused" }
        guard readResponse(dir: dir, id: "first") == nil else { return "\"first\" resolved unexpectedly early" }
        guard fake.sentCommands.count == 1 else { return "expected exactly one injected command, got \(fake.sentCommands.count)" }

        guard let (start, end) = markers(in: fake.sentCommands[0]) else { return "could not find markers in injected command" }
        fake.appendOutput("\(start)\nnode-1   Ready\n\(end)")
        tickUntil(bridge) { readResponse(dir: dir, id: "first") != nil }
        guard readResponse(dir: dir, id: "first")?["ok"] as? Bool == true else { return "\"first\" did not complete successfully afterward" }
        return nil
    }

    private static func test_discardsOutputWhenCaptainTypesWhileCommandIsRunning(with dir: URL) -> String? {
        let fake = FakeBridgeTerminal()
        let bridge = SRELeadBridge(bridgeDir: dir, target: fake)

        do { try writeRequest(dir: dir, id: "interleaved", command: "kubectl get pods") } catch { return "writeRequest threw: \(error)" }
        bridge.tick() // injects, no output yet

        guard let (start, end) = markers(in: fake.sentCommands.first ?? "") else { return "could not find markers in injected command" }

        // The captain types into the tab while the command is "still running".
        fake.lastUserActivity = Date()
        fake.appendOutput("\(start)\npod/api-1   1/1   Running\n\(end)")

        tickUntil(bridge) { readResponse(dir: dir, id: "interleaved") != nil }

        guard let response = readResponse(dir: dir, id: "interleaved") else { return "no response written" }
        guard response["ok"] as? Bool == false else { return "expected ok=false when the captain typed mid-command" }
        guard response["output"] == nil else { return "possibly-corrupted output was returned instead of being discarded" }
        return nil
    }

    private static func test_timesOutIfEndMarkerNeverAppears(with dir: URL) -> String? {
        let fake = FakeBridgeTerminal()
        let bridge = SRELeadBridge(bridgeDir: dir, target: fake, commandTimeout: 0)

        do { try writeRequest(dir: dir, id: "stuck", command: "kubectl get pods") } catch { return "writeRequest threw: \(error)" }
        bridge.tick() // injects
        bridge.tick() // commandTimeout is 0, so this tick already sees it as timed out

        guard let response = readResponse(dir: dir, id: "stuck") else { return "no response written" }
        guard response["ok"] as? Bool == false else { return "expected ok=false on timeout" }
        let message = (response["error"] as? String ?? "").lowercased()
        guard message.contains("timed out") else { return "error message doesn't mention a timeout: \(message)" }
        return nil
    }

    private static func test_errorsCleanlyWhenTargetTabIsGone(with dir: URL) -> String? {
        final class Holder {
            var fake: FakeBridgeTerminal? = FakeBridgeTerminal()
        }
        let holder = Holder()
        let bridge = SRELeadBridge(bridgeDir: dir, target: holder.fake!)
        holder.fake = nil // simulates the primary ssh tab being closed

        do { try writeRequest(dir: dir, id: "gone", command: "kubectl get pods") } catch { return "writeRequest threw: \(error)" }
        bridge.tick()

        guard let response = readResponse(dir: dir, id: "gone") else { return "no response written" }
        guard response["ok"] as? Bool == false else { return "expected ok=false when the target tab is gone" }
        guard response["error"] != nil else { return "expected an error message" }
        return nil
    }
}
