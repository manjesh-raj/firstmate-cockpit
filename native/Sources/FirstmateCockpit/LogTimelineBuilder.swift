// Manjesh Grand Line - native macOS app.
//
// `fm/grandline-log-analyzer-build`, spec §8: builds an event timeline from
// timestamps that are genuinely present in the input, and says so plainly
// when there are none.
//
// The spec's hard rule is "do not invent timestamps," so this is a purely
// local, purely extractive builder - the AI layer never contributes a
// timeline event, and no event exists here that wasn't read off a real line.
// A line's `timestamp` is carried verbatim out of `LogErrorExtractor`
// (short-formed only for display alignment, never reformatted into a
// different clock or timezone).
//
// Selection, not transcription: a 5,000-line log has 5,000 timestamps, and a
// timeline of 5,000 rows is not a timeline. The events kept are the ones a
// captain would circle on a whiteboard - the first and last occurrence of
// each distinct significant pattern, plus any line matching a small set of
// lifecycle phrases (a deployment starting, a restart, a recovery), capped
// and sorted. Everything dropped is still visible in the raw pane and
// counted in the Error Groups tab, so nothing is hidden, only de-duplicated.

import Foundation

enum LogTimelineBuilder {

    /// Cap on rendered events. Past this a timeline stops being scannable.
    static let maxEvents = 24

    /// Lifecycle phrases worth a timeline row even at informational severity
    /// - these are the "what happened to the system" beats spec §8's own
    /// example is made of (deployment started, pod restart, service healthy).
    private static let lifecyclePhrases: [(needle: String, title: String, severity: LogSeverity)] = [
        ("deployment started", "Deployment started", .informational),
        ("rollout", "Rollout event", .informational),
        ("scaled", "Scaling event", .informational),
        ("created container", "Container created", .informational),
        ("started container", "Container started", .informational),
        ("killing container", "Container killed", .warning),
        ("restarting", "Restart", .warning),
        ("restarted", "Restart", .warning),
        ("back-off restarting", "Restart back-off", .high),
        ("pulling image", "Image pull started", .informational),
        ("successfully pulled", "Image pulled", .informational),
        ("listening on", "Service began listening", .informational),
        ("server started", "Service started", .informational),
        ("shutting down", "Shutdown began", .warning),
        ("became healthy", "Service healthy", .normal),
        ("now healthy", "Service healthy", .normal),
        ("readiness probe failed", "Readiness probe failure", .high),
        ("liveness probe failed", "Liveness probe failure", .high),
        ("connection established", "Connection established", .informational),
        ("rollback", "Rollback", .warning),
    ]

    /// Builds the timeline, or the explicit unavailable state.
    ///
    /// `groups` is passed in (rather than recomputed) so the first/last
    /// occurrence rows and the Error Groups tab are guaranteed to be talking
    /// about the same patterns and the same counted timestamps.
    static func build(text: String, groups: [LogErrorGroup]) -> LogTimeline {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .unavailable(reason: "Timeline unavailable — no input provided.")
        }

        let lines = text.components(separatedBy: "\n")
        var candidates: [LogTimelineEvent] = []
        var sawAnyTimestamp = false

        // Pass 1: lifecycle beats.
        for (index, rawLine) in lines.prefix(LogErrorExtractor.maxLinesScanned).enumerated() {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            guard let stamp = LogErrorExtractor.timestamp(in: line) else { continue }
            sawAnyTimestamp = true

            let lower = line.lowercased()
            guard let match = lifecyclePhrases.first(where: { lower.contains($0.needle) }) else { continue }
            candidates.append(LogTimelineEvent(
                timestamp: LogErrorExtractor.shortTime(stamp),
                title: match.title,
                detail: LogErrorExtractor.shortLabel(line, limit: 130),
                severity: max(match.severity, LogErrorExtractor.severity(forLine: line)),
                lineNumber: index + 1
            ))
        }

        // Pass 2: the first (and, when it differs, last) occurrence of each
        // counted pattern - the "this started here / was still happening
        // here" pair that makes a timeline readable.
        for group in groups {
            if let first = group.firstTimestamp {
                sawAnyTimestamp = true
                candidates.append(LogTimelineEvent(
                    timestamp: first,
                    title: "First: \(group.label)",
                    detail: group.occurrences > 1
                        ? "First of \(group.occurrences) occurrences."
                        : "Single occurrence.",
                    severity: group.severity,
                    lineNumber: group.lineNumbers.first ?? 0
                ))
            }
            if group.occurrences > 1, let last = group.lastTimestamp, last != group.firstTimestamp {
                candidates.append(LogTimelineEvent(
                    timestamp: last,
                    title: "Last: \(group.label)",
                    detail: "Last of \(group.occurrences) occurrences.",
                    severity: group.severity,
                    lineNumber: group.lineNumbers.last ?? 0
                ))
            }
        }

        guard sawAnyTimestamp else {
            return .unavailable(reason: "Timeline unavailable — input does not contain usable timestamps.")
        }
        guard !candidates.isEmpty else {
            return .unavailable(reason: "Timeline unavailable — no significant timestamped events found in this input.")
        }

        // De-duplicate exact (timestamp, title) repeats - a lifecycle phrase
        // repeated 40 times at the same second is one beat, not 40.
        var seen = Set<String>()
        let deduped = candidates.filter { seen.insert("\($0.timestamp)#\($0.title)").inserted }

        // Chronological by the captured string. Deliberately a plain string
        // sort rather than a parsed `Date`: every stamp here is short-formed
        // to `HH:MM:SS` by `LogErrorExtractor.shortTime` where possible, which
        // sorts correctly lexicographically, and a log that mixes formats has
        // no single clock to parse against anyway. `lineNumber` breaks ties,
        // preserving the order the lines actually appeared in.
        let sorted = deduped.sorted { a, b in
            if a.timestamp != b.timestamp { return a.timestamp < b.timestamp }
            return a.lineNumber < b.lineNumber
        }

        guard sorted.count > maxEvents else { return .events(sorted) }

        // Over the cap: keep the highest-severity events, then restore
        // chronological order - so a trimmed timeline still reads forward
        // in time, it just has fewer rows.
        let kept = sorted
            .enumerated()
            .sorted { a, b in
                if a.element.severity != b.element.severity { return a.element.severity > b.element.severity }
                return a.offset < b.offset
            }
            .prefix(maxEvents)
            .sorted { $0.offset < $1.offset }
            .map(\.element)
        return .events(kept)
    }
}
