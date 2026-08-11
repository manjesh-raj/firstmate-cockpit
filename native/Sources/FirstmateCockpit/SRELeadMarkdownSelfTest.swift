// Manjesh Grand Line - native macOS app.
//
// Permanent, dependency-free self-test for `SRELeadMarkdown.parse` - same
// "env-var-gated, run and read the result" convention as
// `SRELeadBridgeSelfTest.swift` (see that file's header and the AGENTS.md
// "Verifying native UI bugs without a real screenshot" bullet for why this
// project has no `swift test` story). Run with:
//
//   swift build && FM_RUN_SRE_LEAD_MARKDOWN_TESTS=1 .build/debug/FirstmateCockpit; echo $?
//
// Covers the parsing half of the reply-structure/rendering fix
// (`fm/cockpit-sre-lead-reply-formatting`): bold, inline code, bullet
// lists, fenced code blocks, and the two labeled callout paragraphs
// (`**Finding:**` / `**Recommended next action:**`) `SRELead.persona` is
// instructed to produce. The rendering half (block -> NSView, theme
// colors) has no equivalent here - it was verified with a temporary
// env-gated geometry probe per the same AGENTS.md convention, reverted
// before commit; see this task's PR description for that transcript.
import Foundation

enum SRELeadMarkdownSelfTest {

    static func run() -> Bool {
        let cases: [(String, () -> String?)] = [
            ("boldAndInlineCodeInAParagraph", test_boldAndInlineCodeInAParagraph),
            ("bulletListBecomesOneBlockWithSeparateItems", test_bulletListBecomesOneBlockWithSeparateItems),
            ("fencedCodeBlockIsPreserved", test_fencedCodeBlockIsPreserved),
            ("findingCalloutIsRecognizedAndLabelStripped", test_findingCalloutIsRecognizedAndLabelStripped),
            ("recommendationCalloutIsRecognized", test_recommendationCalloutIsRecognized),
            ("ordinaryBoldTextIsNotMistakenForACallout", test_ordinaryBoldTextIsNotMistakenForACallout),
            ("fullReplyProducesFindingThenEvidenceThenRecommendation", test_fullReplyProducesFindingThenEvidenceThenRecommendation),
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
        print(failures == 0 ? "SRELeadMarkdownSelfTest: all \(cases.count) cases passed" : "SRELeadMarkdownSelfTest: \(failures)/\(cases.count) cases FAILED")
        return failures == 0
    }

    // MARK: Cases - each returns `nil` on success, or a failure message.

    private static func test_boldAndInlineCodeInAParagraph() -> String? {
        let blocks = SRELeadMarkdown.parse("The pod `api-1` is **crashlooping**.")
        guard blocks.count == 1, case .paragraph(let runs) = blocks[0] else { return "expected one paragraph block, got \(blocks)" }
        guard runs.contains(where: { $0.code && $0.text == "api-1" }) else { return "no code run for api-1: \(runs)" }
        guard runs.contains(where: { $0.bold && $0.text == "crashlooping" }) else { return "no bold run for crashlooping: \(runs)" }
        return nil
    }

    private static func test_bulletListBecomesOneBlockWithSeparateItems() -> String? {
        let blocks = SRELeadMarkdown.parse("- pod a is fine\n- pod b is crashing\n- pod c is pending")
        guard blocks.count == 1, case .bulletList(let items) = blocks[0] else { return "expected one bulletList block, got \(blocks)" }
        guard items.count == 3 else { return "expected 3 items, got \(items.count)" }
        guard items[1].map(\.text).joined().contains("crashing") else { return "item 2 text wrong: \(items[1])" }
        return nil
    }

    private static func test_fencedCodeBlockIsPreserved() -> String? {
        let text = "Before.\n\n```\nkubectl get pods\nNAME   READY\n```\n\nAfter."
        let blocks = SRELeadMarkdown.parse(text)
        guard blocks.count == 3 else { return "expected 3 blocks, got \(blocks.count): \(blocks)" }
        guard case .codeBlock(let code) = blocks[1] else { return "middle block is not code: \(blocks[1])" }
        guard code.contains("kubectl get pods") else { return "code block missing content: \(code)" }
        return nil
    }

    private static func test_findingCalloutIsRecognizedAndLabelStripped() -> String? {
        let blocks = SRELeadMarkdown.parse("**Finding:** three pods are crashlooping in `payments`.")
        guard blocks.count == 1, case .callout(let kind, let runs) = blocks[0] else { return "expected one callout block, got \(blocks)" }
        guard kind == .finding else { return "expected .finding, got \(kind)" }
        let joined = runs.map(\.text).joined()
        guard joined.hasPrefix("three pods"), !joined.contains("Finding:") else { return "label not stripped cleanly: \(joined)" }
        return nil
    }

    private static func test_recommendationCalloutIsRecognized() -> String? {
        let blocks = SRELeadMarkdown.parse("**Recommended next action:** restart the `payments` deployment.")
        guard blocks.count == 1, case .callout(let kind, _) = blocks[0] else { return "expected one callout block, got \(blocks)" }
        guard kind == .recommendation else { return "expected .recommendation, got \(kind)" }
        return nil
    }

    private static func test_ordinaryBoldTextIsNotMistakenForACallout() -> String? {
        let blocks = SRELeadMarkdown.parse("**Note:** this is just emphasis, not a callout label.")
        guard blocks.count == 1, case .paragraph = blocks[0] else { return "expected a plain paragraph, got \(blocks)" }
        return nil
    }

    private static func test_fullReplyProducesFindingThenEvidenceThenRecommendation() -> String? {
        let text = """
        **Finding:** the `payments-7c9` deployment has 2 of 3 pods crashlooping with OOMKilled.

        - payments-7c9-abcde: OOMKilled 4 times in the last hour
        - payments-7c9-fghij: OOMKilled 3 times in the last hour

        **Recommended next action:** raise the memory limit on the `payments` deployment and redeploy.
        """
        let blocks = SRELeadMarkdown.parse(text)
        guard blocks.count == 3 else { return "expected 3 blocks, got \(blocks.count): \(blocks)" }
        guard case .callout(.finding, _) = blocks[0] else { return "block 0 not a finding callout: \(blocks[0])" }
        guard case .bulletList(let items) = blocks[1], items.count == 2 else { return "block 1 not a 2-item list: \(blocks[1])" }
        guard case .callout(.recommendation, _) = blocks[2] else { return "block 2 not a recommendation callout: \(blocks[2])" }
        return nil
    }
}
