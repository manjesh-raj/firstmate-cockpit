// Manjesh Grand Line - native macOS app.
//
// `fm/grandline-log-analyzer-build`, spec §16 (copy sections), §17 (Create
// Incident), §18 (Create Runbook), §19 (Create Ticket) and §20/§21 (Compare
// / Diff integration).
//
// Every artifact is rendered **locally, from the investigation this app
// already holds** - no AI call is required to produce any of them. That is a
// deliberate choice, not a shortcut: the incident, runbook and ticket
// bodies are assembled from fields that were already produced and already
// reviewed by the captain (the findings, the root cause with its confidence,
// the counted patterns, the real timeline). Regenerating them through a
// second model pass would let a section drift from what the captain just
// read on screen, and would make the buttons fail offline for no benefit.
// `LogAnalyzerController` offers an optional "polish with AI" pass on top for
// the runbook only, where a reusable procedure genuinely benefits from
// prose - and even that starts from this rendering.
//
// Spec §19's constraint is honoured structurally: `ticketMarkdown` produces
// *text*. Nothing in this file, or anywhere in this feature, talks to Jira or
// any other tracker - the captain copies the generated body into whatever
// system they use. There is no API client to accidentally fire.
//
// Compare (§20/§21) reuses `DiffEngine` verbatim - the same line/word LCS the
// Tools page's Diff tab runs (`DiffEngine.swift`). This file only adds the
// *log-aware* half on top of it: which counted error patterns are new,
// which disappeared, and which got worse.

import Foundation

enum LogAnalyzerArtifacts {

    // MARK: - Shared helpers

    private static func timestampLine(_ date: Date) -> String {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.string(from: date)
    }

    private static func bulletList(_ items: [String], emptyText: String) -> String {
        guard !items.isEmpty else { return "_\(emptyText)_\n" }
        return items.map { "- \($0)\n" }.joined()
    }

    private static func numberedList(_ items: [String], emptyText: String) -> String {
        guard !items.isEmpty else { return "_\(emptyText)_\n" }
        return items.enumerated().map { "\($0.offset + 1). \($0.element)\n" }.joined()
    }

    // MARK: - Copy sections (spec §16)

    static func rootCauseText(_ investigation: LogInvestigation) -> String {
        guard let root = investigation.analysis?.ai?.rootCause else {
            return "No root cause has been established for this investigation yet."
        }
        var out = "Probable root cause: \(root.summary)\nConfidence: \(root.confidence.displayName)\n"
        if !root.explanation.isEmpty { out += "\n\(root.explanation)\n" }
        if !root.evidence.isEmpty {
            out += "\nEvidence:\n" + root.evidence.map { "- \($0)\n" }.joined()
        }
        if !root.missingEvidence.isEmpty {
            out += "\nMissing evidence:\n" + root.missingEvidence.map { "- \($0)\n" }.joined()
        }
        if !root.contradictingEvidence.isEmpty {
            out += "\nContradicting evidence:\n" + root.contradictingEvidence.map { "- \($0)\n" }.joined()
        }
        return out
    }

    static func evidenceText(_ investigation: LogInvestigation) -> String {
        var out = "Evidence in this investigation:\n"
        for item in investigation.evidence {
            out += "- \(item.label) (\(item.origin.displayName)"
            if let detail = item.sourceDetail { out += ": \(detail)" }
            out += ", \(item.lineCount) lines, \(item.detection.kind.displayName))\n"
        }
        if let groups = investigation.analysis?.local.groups, !groups.isEmpty {
            out += "\nCounted patterns:\n"
            for group in groups {
                out += "- [\(group.severity.displayName)] \(group.label) — \(group.occurrenceText)"
                if let range = group.timeRange { out += " (\(range))" }
                out += "\n"
            }
        }
        return out
    }

    static func nextStepsText(_ investigation: LogInvestigation) -> String {
        let steps = investigation.analysis?.ai?.nextSteps ?? []
        var out = "Recommended next steps:\n" + numberedList(steps, emptyText: "No next steps were produced.")
        let commands = investigation.analysis?.ai?.suggestedCommands ?? []
        if !commands.isEmpty {
            out += "\nSuggested commands:\n"
            for command in commands {
                out += "- \(command.title)\n    \(command.command)\n"
            }
        }
        return out
    }

    /// Spec §16's "Copy Full Analysis" - the whole on-screen read, in the
    /// order the page shows it.
    static func fullAnalysisText(_ investigation: LogInvestigation) -> String {
        guard let analysis = investigation.analysis else {
            return "\(investigation.title)\n\nThis investigation has not been analyzed yet."
        }

        var out = "\(investigation.title)\n"
        out += "Analyzed \(timestampLine(analysis.analyzedAt)) · mode: \(analysis.mode.displayName)\n"
        out += "Source: \(analysis.local.detection.kind.displayName) (\(analysis.local.detection.kind.formatName))\n"
        out += "Highest severity: \(analysis.local.detection.severity.displayName)\n"

        if let summary = analysis.ai?.summary, !summary.isEmpty {
            out += "\nSummary\n-------\n\(summary)\n"
        }

        out += "\nFindings\n--------\n"
        if analysis.findings.isEmpty {
            out += "_No findings._\n"
        } else {
            for finding in analysis.findings {
                out += "[\(finding.severity.displayName)] \(finding.title)\n"
                if !finding.detail.isEmpty { out += "    \(finding.detail)\n" }
                if let meta = finding.meta { out += "    \(meta)\n" }
            }
        }

        out += "\nRoot cause\n----------\n" + rootCauseText(investigation)
        out += "\n" + evidenceText(investigation)
        out += "\n" + nextStepsText(investigation)

        switch analysis.local.timeline {
        case .unavailable(let reason):
            out += "\nTimeline\n--------\n\(reason)\n"
        case .events(let events):
            out += "\nTimeline\n--------\n"
            for event in events { out += "\(event.timestamp)  \(event.title) — \(event.detail)\n" }
        }

        if !analysis.correlation.isEmpty {
            out += "\nCorrelation\n-----------\n"
            for link in analysis.correlation {
                out += "[\(link.kind.displayName)] \(link.text)\n"
                if let evidence = link.evidence { out += "    \(evidence)\n" }
            }
        }

        if let needed = analysis.ai?.neededEvidence, !needed.isEmpty {
            out += "\nStill needed to confirm\n-----------------------\n" + bulletList(needed, emptyText: "")
        }

        return out
    }

    // MARK: - Create Incident (spec §17)

    /// The exact section set spec §17 names: Title, Impact, Start Time,
    /// Timeline, Symptoms, Evidence, Root Cause, Resolution, Next Steps -
    /// plus the evidence back-references the spec asks the incident to
    /// retain.
    static func incidentMarkdown(_ investigation: LogInvestigation) -> String {
        let analysis = investigation.analysis
        let root = analysis?.ai?.rootCause

        var out = "# Incident: \(investigation.title)\n\n"

        out += "## Impact\n\n"
        let topFindings = (analysis?.findings ?? []).filter { $0.severity >= .high }
        if topFindings.isEmpty {
            out += "_Impact not established from the provided output._\n\n"
        } else {
            out += topFindings.map { "- \($0.title)\($0.detail.isEmpty ? "" : " — \($0.detail)")\n" }.joined() + "\n"
        }

        out += "## Start time\n\n"
        if case .events(let events) = analysis?.local.timeline ?? .unavailable(reason: ""), let first = events.first {
            out += "First event in the provided output: **\(first.timestamp)** — \(first.title)\n\n"
        } else {
            out += "_Not established — the provided output contains no usable timestamps._\n\n"
        }

        out += "## Timeline\n\n"
        switch analysis?.local.timeline ?? .unavailable(reason: "No analysis.") {
        case .unavailable(let reason):
            out += "_\(reason)_\n\n"
        case .events(let events):
            for event in events { out += "- **\(event.timestamp)** \(event.title) — \(event.detail)\n" }
            out += "\n"
        }

        out += "## Symptoms\n\n"
        let groups = analysis?.local.groups ?? []
        if groups.isEmpty {
            out += "_No repeated error patterns were found in the provided output._\n\n"
        } else {
            for group in groups {
                out += "- \(group.label) — \(group.occurrenceText)"
                if let range = group.timeRange { out += " (\(range))" }
                out += "\n"
            }
            out += "\n"
        }

        out += "## Evidence\n\n"
        for item in investigation.evidence {
            out += "- **\(item.label)** — \(item.origin.displayName)"
            if let detail = item.sourceDetail { out += " (\(detail))" }
            out += ", \(item.lineCount) lines, detected as \(item.detection.kind.displayName)"
            if item.redactionCount > 0 { out += ", \(item.redactionCount) secret(s) redacted" }
            out += "\n"
        }
        out += "\n"

        out += "## Root cause\n\n"
        if let root {
            out += "**\(root.summary)** _(confidence: \(root.confidence.displayName))_\n\n"
            if !root.explanation.isEmpty { out += "\(root.explanation)\n\n" }
            if !root.evidence.isEmpty { out += "Supporting evidence:\n\n" + bulletList(root.evidence, emptyText: "") + "\n" }
            if !root.missingEvidence.isEmpty {
                out += "Not established from the provided output:\n\n" + bulletList(root.missingEvidence, emptyText: "") + "\n"
            }
            if !root.contradictingEvidence.isEmpty {
                out += "Contradicting evidence:\n\n" + bulletList(root.contradictingEvidence, emptyText: "") + "\n"
            }
        } else {
            out += "_No root cause has been established yet._\n\n"
        }

        out += "## Resolution\n\n_To be filled in once the fix is applied._\n\n"

        out += "## Next steps\n\n"
        out += numberedList(analysis?.ai?.nextSteps ?? [], emptyText: "No next steps were produced.")
        out += "\n"

        out += "---\n_Generated by Grand Line's Log Analyzer on \(timestampLine(Date())). "
        out += "Log content is redacted; no secret values are included._\n"
        return out
    }

    // MARK: - Create Runbook (spec §18)

    /// The section set spec §18's own example uses: Symptoms, Investigation,
    /// Resolution, Prevention. Investigation steps are emitted as fenced
    /// command blocks in exactly the shape
    /// `native/Scripts/sre_kubectl_mcp.py`'s `_extract_command_lines`
    /// already reads, so a runbook created here is immediately runnable by
    /// SRE Lead's `run_runbook` tool - the same integration
    /// `CommandLibraryWorkflow` established for the Command Library.
    static func runbookMarkdown(_ investigation: LogInvestigation) -> String {
        let analysis = investigation.analysis
        let root = analysis?.ai?.rootCause
        let title = root?.summary ?? investigation.title

        var out = "# Runbook: \(title)\n\n"

        out += "## Symptoms\n\n"
        let groups = analysis?.local.groups ?? []
        if groups.isEmpty {
            out += "_No repeated error patterns were recorded for this runbook._\n\n"
        } else {
            for group in groups.prefix(8) { out += "- \(group.label)\n" }
            out += "\n"
        }

        out += "## Investigation\n\n"
        let commands = analysis?.ai?.suggestedCommands ?? []
        if commands.isEmpty {
            out += "_No investigation commands were produced._\n\n"
        } else {
            for (index, command) in commands.enumerated() {
                out += "\(index + 1). \(command.title)\n"
                if !command.rationale.isEmpty { out += "\n   \(command.rationale)\n" }
                out += "\n```sh\n\(command.command)\n```\n\n"
            }
        }

        out += "## Resolution\n\n"
        let steps = analysis?.ai?.nextSteps ?? []
        if steps.isEmpty {
            out += "_To be filled in._\n\n"
        } else {
            out += numberedList(steps, emptyText: "") + "\n"
        }

        out += "## Prevention\n\n"
        if let missing = root?.missingEvidence, !missing.isEmpty {
            out += "Signals that were not available during this investigation and would speed up the next one:\n\n"
            out += bulletList(missing, emptyText: "") + "\n"
        } else {
            out += "_To be filled in._\n\n"
        }

        out += "---\n_Generated by Grand Line's Log Analyzer on \(timestampLine(Date()))._\n"
        return out
    }

    // MARK: - Create Ticket (spec §19)

    /// Spec §19's exact fields. Text only - see this file's header on why
    /// nothing here calls a tracker API.
    static func ticketMarkdown(_ investigation: LogInvestigation) -> String {
        let analysis = investigation.analysis
        let root = analysis?.ai?.rootCause
        let severity = investigation.severity

        var out = "## Summary\n\n"
        out += "\(root?.summary ?? investigation.title)\n\n"

        out += "## Description\n\n"
        out += (analysis?.ai?.summary.isEmpty == false ? analysis!.ai!.summary : "See findings below.") + "\n\n"
        for finding in analysis?.findings ?? [] {
            out += "- **[\(finding.severity.displayName)]** \(finding.title)"
            if !finding.detail.isEmpty { out += " — \(finding.detail)" }
            out += "\n"
        }
        out += "\n"

        out += "## Impact\n\n"
        out += "Highest observed severity: **\(severity.displayName)**.\n\n"
        let critical = (analysis?.findings ?? []).filter { $0.severity >= .high }
        if !critical.isEmpty {
            out += bulletList(critical.map { $0.title }, emptyText: "") + "\n"
        }

        out += "## Root cause\n\n"
        if let root {
            out += "\(root.summary) _(confidence: \(root.confidence.displayName))_\n\n"
            if !root.explanation.isEmpty { out += "\(root.explanation)\n\n" }
        } else {
            out += "_Not yet established._\n\n"
        }

        out += "## Evidence\n\n"
        for group in analysis?.local.groups ?? [] {
            out += "- \(group.label) — \(group.occurrenceText)"
            if let range = group.timeRange { out += " (\(range))" }
            out += "\n"
        }
        if (analysis?.local.groups ?? []).isEmpty { out += "_No counted patterns._\n" }
        out += "\n"

        out += "## Timeline\n\n"
        switch analysis?.local.timeline ?? .unavailable(reason: "No analysis.") {
        case .unavailable(let reason): out += "_\(reason)_\n\n"
        case .events(let events):
            for event in events.prefix(12) { out += "- **\(event.timestamp)** \(event.title)\n" }
            out += "\n"
        }

        out += "## Resolution\n\n_To be filled in._\n\n"

        out += "## Preventive actions\n\n"
        out += numberedList(analysis?.ai?.nextSteps ?? [], emptyText: "To be filled in.")
        out += "\n---\n_Drafted by Grand Line's Log Analyzer. Nothing was filed automatically — "
        out += "copy this into your tracker if it is correct._\n"
        return out
    }

    // MARK: - Compare / Diff (spec §20, §21)

    /// The log-aware half of Compare, on top of `DiffEngine`'s line diff.
    struct ComparisonResult: Equatable {
        var newPatterns: [LogErrorGroup]
        var resolvedPatterns: [LogErrorGroup]
        var worsenedPatterns: [(pattern: LogErrorGroup, before: Int, after: Int)]
        var unchangedCount: Int
        /// The `DiffEngine` rows, so the UI can render the same
        /// line-by-line view the Tools page's Diff tab uses.
        var rows: [DiffRow]

        static func == (a: ComparisonResult, b: ComparisonResult) -> Bool {
            a.newPatterns == b.newPatterns
                && a.resolvedPatterns == b.resolvedPatterns
                && a.unchangedCount == b.unchangedCount
                && a.worsenedPatterns.map(\.pattern) == b.worsenedPatterns.map(\.pattern)
                && a.worsenedPatterns.map(\.before) == b.worsenedPatterns.map(\.before)
                && a.worsenedPatterns.map(\.after) == b.worsenedPatterns.map(\.after)
        }
    }

    /// Compares two outputs. Pattern-level rather than line-level, because
    /// spec §20's scenarios (before/after a deploy, healthy vs unhealthy pod,
    /// prod vs UAT) are all cases where the raw text differs on every line
    /// (timestamps, pod names) while the *errors* are what actually changed -
    /// which is exactly what `LogErrorExtractor.normalize` already
    /// neutralises.
    static func compare(before: String, after: String) -> ComparisonResult {
        let beforeGroups = LogErrorExtractor.groups(in: before)
        let afterGroups = LogErrorExtractor.groups(in: after)

        let beforeByPattern = Dictionary(beforeGroups.map { ($0.pattern, $0) }, uniquingKeysWith: { a, _ in a })
        let afterByPattern = Dictionary(afterGroups.map { ($0.pattern, $0) }, uniquingKeysWith: { a, _ in a })

        let newPatterns = afterGroups.filter { beforeByPattern[$0.pattern] == nil }
        let resolvedPatterns = beforeGroups.filter { afterByPattern[$0.pattern] == nil }

        var worsened: [(LogErrorGroup, Int, Int)] = []
        var unchanged = 0
        for group in afterGroups {
            guard let previous = beforeByPattern[group.pattern] else { continue }
            if group.occurrences > previous.occurrences {
                worsened.append((group, previous.occurrences, group.occurrences))
            } else {
                unchanged += 1
            }
        }

        return ComparisonResult(
            newPatterns: newPatterns,
            resolvedPatterns: resolvedPatterns,
            worsenedPatterns: worsened,
            unchangedCount: unchanged,
            rows: DiffEngine.lineDiff(before: before, after: after)
        )
    }

    /// A copyable text rendering of a comparison, matching the sections spec
    /// §21 asks the analyzer to identify.
    static func comparisonText(_ result: ComparisonResult, beforeLabel: String, afterLabel: String) -> String {
        var out = "Comparison: \(beforeLabel) → \(afterLabel)\n\n"

        out += "New errors (\(result.newPatterns.count))\n"
        out += result.newPatterns.isEmpty
            ? "  none\n"
            : result.newPatterns.map { "  - \($0.label) (\($0.occurrenceText))\n" }.joined()

        out += "\nResolved errors (\(result.resolvedPatterns.count))\n"
        out += result.resolvedPatterns.isEmpty
            ? "  none\n"
            : result.resolvedPatterns.map { "  - \($0.label) (was \($0.occurrenceText))\n" }.joined()

        out += "\nGot worse (\(result.worsenedPatterns.count))\n"
        out += result.worsenedPatterns.isEmpty
            ? "  none\n"
            : result.worsenedPatterns.map { "  - \($0.pattern.label): \($0.before) → \($0.after) occurrences\n" }.joined()

        let changedLines = result.rows.filter { $0.kind != .unchanged }.count
        out += "\nUnchanged patterns: \(result.unchangedCount)\n"
        out += "Changed lines: \(changedLines) of \(result.rows.count)\n"
        return out
    }
}
