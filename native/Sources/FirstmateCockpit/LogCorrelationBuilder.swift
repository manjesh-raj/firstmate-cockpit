// Manjesh Grand Line - native macOS app.
//
// `fm/grandline-log-analyzer-build`, spec §9: the Observed / Inferred /
// Unknown chain. The spec's stated purpose for this section is blunt - "this
// is important to avoid AI hallucinating root causes" - so the split is
// enforced structurally rather than requested politely:
//
//   * `.observed` links are produced **only here**, from patterns this
//     machine actually counted and timestamps it actually read. Every
//     observed link carries `evidence` naming the count/time range behind it.
//   * `.inferred` and `.unknown` links come **only** from the AI layer, and
//     `LogAnalyzerAI.parse` drops any link the model tries to label
//     `.observed` (downgrading it to `.inferred`), because the model did not
//     count anything - it read a condensed summary.
//
// So a captain reading the Correlation tab can trust that a green "Observed"
// badge means "this app counted it", not "the model was confident."

import Foundation

enum LogCorrelationBuilder {

    /// Observed links to emit at most - one chain, not a transcript.
    static let maxObserved = 8

    /// Builds the observed half of the chain from local evidence only.
    ///
    /// Ordering is chronological where timestamps exist (so the chain reads
    /// as a sequence of events rather than a ranked list), falling back to
    /// severity/count order when the input carried no timestamps at all.
    static func observed(groups: [LogErrorGroup], timeline: LogTimeline) -> [LogCorrelationLink] {
        guard !groups.isEmpty else { return [] }

        let hasTimestamps = groups.contains { $0.firstTimestamp != nil }
        let ordered: [LogErrorGroup]
        if hasTimestamps {
            ordered = groups.sorted { a, b in
                switch (a.firstTimestamp, b.firstTimestamp) {
                case let (x?, y?):
                    if x != y { return x < y }
                    return a.severity > b.severity
                case (nil, _?): return false
                case (_?, nil): return true
                default: return a.severity > b.severity
                }
            }
        } else {
            ordered = groups
        }

        var links: [LogCorrelationLink] = []
        for (index, group) in ordered.prefix(maxObserved).enumerated() {
            var evidence = "\(group.occurrences) matching line\(group.occurrences == 1 ? "" : "s") in the provided output"
            if let range = group.timeRange { evidence += ", \(range)" }
            links.append(LogCorrelationLink(
                order: index,
                kind: .observed,
                text: group.label,
                evidence: evidence
            ))
        }

        // A timeline whose first beat is a lifecycle event (a deployment, a
        // restart) is genuinely the start of the chain and belongs at the
        // front - it is what the errors below it followed.
        if case .events(let events) = timeline,
           let firstLifecycle = events.first(where: { !$0.title.hasPrefix("First:") && !$0.title.hasPrefix("Last:") }),
           !links.contains(where: { $0.text == firstLifecycle.title }) {
            links.insert(LogCorrelationLink(
                order: -1,
                kind: .observed,
                text: firstLifecycle.title,
                evidence: "Logged at \(firstLifecycle.timestamp): \(firstLifecycle.detail)"
            ), at: 0)
        }

        // Renumber so `order` is a dense 0-based sequence regardless of the
        // insert above - the UI renders in `order`, and a gap or a -1 would
        // read as a missing step.
        return links.enumerated().map { index, link in
            LogCorrelationLink(order: index, kind: link.kind, text: link.text, evidence: link.evidence)
        }
    }
}
