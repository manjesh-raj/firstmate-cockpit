// Manjesh Grand Line - native macOS app.
//
// "Command Workflows" (fm/grandline-devops-command-library-phase2) - per the
// design doc's Option A (captain-approved recommendation, restated in
// AGENTS.md's "Shift" section): a workflow IS a Docs Runbook, not a second
// parallel format. This file only formats a command's generated text into
// the fenced-code-block shape `DocsRunbookStore`/SRE Lead's `run_runbook`
// already expect (see `native/Scripts/sre_kubectl_mcp.py`'s
// `_extract_command_lines` - every non-empty, non-comment line inside a
// ``` fenced block, with an optional leading `$ ` stripped) - it never
// touches `DocsRunbookStore` itself, so it's pure, AppKit-free logic
// (`DiffEngine.swift`'s own convention) that a self-test can exercise
// directly with no store/disk involved.
//
// Kept deliberately dumb: appending a *non*-kubectl command (aws, git,
// terraform, ...) into a runbook is completely valid for a captain reading
// it as a step-by-step guide - `run_runbook`'s own validation is what
// decides whether SRE Lead can actually *execute* a given runbook, and it
// already refuses a runbook with any non-kubectl line rather than running
// part of it. That's existing, correct behavior this file doesn't change or
// second-guess.

import Foundation

enum CommandLibraryWorkflow {

    /// The markdown for a brand-new runbook seeded with one command as its
    /// first step - `# Title` heading (matching `DocsRunbookStore.
    /// titleFromContent`'s own convention) followed by the command's own
    /// description (if any) and one fenced step.
    static func newRunbookContent(title: String, command: DevOpsCommand, generatedText: String) -> String {
        var lines = ["# \(title)", ""]
        if !command.description.isEmpty {
            lines.append(command.description)
            lines.append("")
        }
        lines.append(contentsOf: step(for: command, generatedText: generatedText))
        return lines.joined(separator: "\n") + "\n"
    }

    /// Appends one more fenced step to an existing runbook's content -
    /// `run_runbook`'s extraction walks the whole document for fenced
    /// blocks, so a new block can simply be appended at the end with no
    /// need to parse/merge into an existing one.
    static func appending(command: DevOpsCommand, generatedText: String, to existingContent: String) -> String {
        var lines = existingContent.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeLast() }
        lines.append("")
        lines.append("## \(command.name)")
        lines.append("")
        lines.append(contentsOf: step(for: command, generatedText: generatedText))
        return lines.joined(separator: "\n") + "\n"
    }

    private static func step(for command: DevOpsCommand, generatedText: String) -> [String] {
        ["```", generatedText, "```", ""]
    }
}
