// Manjesh Grand Line - native macOS app.
//
// `fm/cockpit-block-view-error-explain`: env-var-gated self-test, same
// convention as `TerminalBlockTrackerSelfTest.swift`/`SRELeadMarkdownSelfTest.
// swift` (see either file's header for why this project has no real
// `swift test` story). Run with:
//
//   swift build && FM_RUN_BLOCK_EXPLAIN_TESTS=1 .build/debug/FirstmateCockpit; echo $?
//
// Covers the two acceptance criteria that don't require a live `claude`
// process: (1) the "Explain this" action's visibility rule - eligible only
// for a genuinely failed (`.finished` with a non-zero exit code) block,
// never a running or successful one - via `BlockExplain.isEligible`, the
// exact pure function `BlockContainerView.explainState(for:)` calls; and
// (2) that `SRELeadMarkdown.parse` (the renderer this feature reuses
// unmodified from SRE Lead) handles a realistic canned explanation reply -
// plain prose with inline code spans, no Finding/Recommended-next-action
// callout convention, since this feature's prompt never asks for that
// structure - without crashing or mis-grouping it into more than one block.
//
// The end-to-end path (a real `claude -p` call against this exact canned
// kubectl failure, then confirming no tool call occurred and the reply
// renders) was verified live during development, not by this file - see the
// PR description for that transcript, and AGENTS.md's "Verifying native UI
// bugs" convention for why a live `claude`/network-dependent call isn't a
// good fit for a permanent, offline-runnable self-test.

import Foundation

enum BlockExplainSelfTest {

    static func run() -> Bool {
        let cases: [(String, () -> String?)] = [
            ("notEligibleWhileRunning", test_notEligibleWhileRunning),
            ("notEligibleOnSuccess", test_notEligibleOnSuccess),
            ("eligibleOnNonZeroExit", test_eligibleOnNonZeroExit),
            ("rendersCannedKubectlFailureExplanationAsOneParagraphWithCodeSpans", test_rendersCannedKubectlFailureExplanation),
        ]
        var failures = 0
        for (name, testCase) in cases {
            if let failure = testCase() {
                print("FAIL \(name): \(failure)")
                failures += 1
            } else {
                print("PASS \(name)")
            }
        }
        print(failures == 0 ? "BlockExplainSelfTest: all \(cases.count) cases passed" : "BlockExplainSelfTest: \(failures)/\(cases.count) cases FAILED")
        return failures == 0
    }

    // MARK: Eligibility

    private static func test_notEligibleWhileRunning() -> String? {
        guard !BlockExplain.isEligible(.running) else { return "a running block was reported eligible for Explain this" }
        return nil
    }

    private static func test_notEligibleOnSuccess() -> String? {
        guard !BlockExplain.isEligible(.finished(exitCode: 0)) else {
            return "a successful (exit 0) block was reported eligible for Explain this"
        }
        return nil
    }

    private static func test_eligibleOnNonZeroExit() -> String? {
        guard BlockExplain.isEligible(.finished(exitCode: 1)) else {
            return "a failed (exit 1) block was not reported eligible for Explain this"
        }
        guard BlockExplain.isEligible(.finished(exitCode: 127)) else {
            return "a failed (exit 127) block was not reported eligible for Explain this"
        }
        return nil
    }

    // MARK: Rendering

    /// A real reply captured from a live `claude -p` call during development
    /// against this exact canned `kubectl` failure (see the file header) -
    /// pinned here as a literal so the parse/render path stays covered
    /// without needing network/`claude` access to run this suite.
    private static let cannedKubectlExplanation = """
    The pods can't pull their container image - likely the image tag doesn't exist in the registry, the deployment references a bad/typo'd tag, or the cluster lacks valid registry credentials (missing/expired imagePullSecret). Run `kubectl describe pod api-7d9f6c5b8f-4x2lq -n prod` to see the exact error in the Events section (it'll say "not found" vs "unauthorized"), and check what image/tag the deployment is actually pointing at with `kubectl get deploy api -n prod -o jsonpath='{.spec.template.spec.containers[0].image}'`.
    """

    private static func test_rendersCannedKubectlFailureExplanation() -> String? {
        let blocks = SRELeadMarkdown.parse(cannedKubectlExplanation)
        guard blocks.count == 1, case .paragraph(let runs) = blocks[0] else {
            return "expected exactly one plain paragraph block (this feature never asks for the Finding/Recommended-next-action convention), got: \(blocks)"
        }
        let codeRuns = runs.filter(\.code)
        guard codeRuns.count == 2 else {
            return "expected 2 inline code spans (the two backtick-quoted kubectl commands), found \(codeRuns.count): \(runs)"
        }
        guard codeRuns.contains(where: { $0.text.contains("kubectl describe pod") }) else {
            return "did not find the expected 'kubectl describe pod' code span: \(codeRuns)"
        }
        return nil
    }
}
