// Manjesh Grand Line - native macOS app.
//
// `fm/grandline-log-analyzer-build`, spec §5 (severity classification), §6
// (error extraction from a large log) and §7 (grouping repeated errors).
//
// This is the part that makes the feature work on a real 5,000-line log
// rather than only on a tidy 30-line paste. Spec §6 is explicit that the AI
// should not be handed everything and asked to summarise: instead the
// significant lines are extracted *here*, locally, collapsed into patterns
// with real occurrence counts and time ranges, and only that condensed set
// (plus a bounded head/tail sample) is what the prompt carries. That is what
// keeps a huge log both affordable to analyse and honest - "43 occurrences"
// is a number this file counted, not a number a model estimated.
//
// **Normalisation is the whole trick.** Two lines are "the same error" when
// they differ only in the values that vary per occurrence: timestamps, IPs,
// ports, durations, UUIDs, hex ids, pod-name suffixes, quoted paths, and
// bare numbers. `normalize` replaces each of those with a fixed placeholder,
// and the resulting string is the group key. Deliberately aggressive rather
// than conservative: over-grouping shows one row that says "43 occurrences"
// where two subtly different errors were merged (recoverable - the sample
// lines are right there), while under-grouping reproduces the exact problem
// spec §7 says to avoid ("do not show 43 identical errors separately").
//
// Severity classification (§5) is a keyword ladder over the categories the
// spec lists - errors, warnings, timeouts, auth/authz failures, connection
// failures, resource issues, config issues, deployment issues, dependency
// failures, certificate problems, DNS/network problems. It runs per line and
// is shared with `LogSourceDetector.detectSeverity`, so the detection strip
// and the grouped rows always agree.

import Foundation

enum LogErrorExtractor {

    /// Sample lines kept per group, for spec §6's "clicking a pattern shows
    /// the matching lines". Bounded so a 4,000-occurrence pattern doesn't
    /// retain 4,000 strings in memory for a panel that shows a handful.
    static let maxSamplesPerGroup = 8

    /// Groups returned. A log with more distinct error shapes than this is
    /// almost certainly noisy rather than genuinely diverse - the top N by
    /// (severity, occurrences) is what a captain actually reads.
    static let maxGroups = 12

    /// Lines scanned. Well past a realistic paste; guards against a
    /// pathological multi-megabyte drop locking the main thread.
    static let maxLinesScanned = 50_000

    // MARK: - Severity (spec §5)

    /// Ordered highest-severity-first, so the first matching bucket wins and
    /// a line saying "FATAL: connection timeout" is critical, not a warning.
    private static let severityKeywords: [(LogSeverity, [String])] = [
        (.critical, [
            "fatal", "panic", "crashloopbackoff", "oomkilled", "segmentation fault",
            "data loss", "corrupt", "outofmemoryerror", "kernel panic",
            "emergency", " emerg ", "cannot allocate memory",
        ]),
        (.high, [
            "error", "err!", "failed", "failure", "exception", "denied", "refused",
            "unauthorized", "forbidden", "timeout", "timed out", "unreachable",
            "not found", "no such", "cannot connect", "connection reset",
            "certificate has expired", "certificate verify failed", "x509",
            "backoff", "back-off", "evicted", "unhealthy", "503", "502", "500",
            "rollback", "aborted", "terminated", "killed", "invalid", "rejected",
            "no route to host", "name or service not known", "nxdomain",
            "permission denied", "access denied", "authentication failure",
            "quota exceeded", "throttl", "deadline exceeded", "insufficient",
        ]),
        (.warning, [
            "warn", "warning", "deprecat", "retry", "retrying", "degraded",
            "slow", "high latency", "pending", "restarting", "skipped",
            "unavailable", "429", "404", "400", "close to limit", "nearing",
        ]),
        (.informational, [
            "info", "notice", "starting", "started", "listening", "connected",
            "ready", "scheduled", "created", "updated", "rollout", "debug",
        ]),
    ]

    /// The one severity classifier for a single line - shared with
    /// `LogSourceDetector.detectSeverity` so the detection strip and the
    /// grouped rows are always derived from the same rule.
    static func severity(forLine line: String) -> LogSeverity {
        let lower = line.lowercased()
        guard !lower.trimmingCharacters(in: .whitespaces).isEmpty else { return .normal }
        for (severity, keywords) in severityKeywords {
            if keywords.contains(where: { lower.contains($0) }) { return severity }
        }
        return .normal
    }

    /// Is this line worth extracting at all (spec §6)? Anything at warning
    /// or above. Informational and normal lines still feed the timeline and
    /// the raw pane; they just aren't "significant patterns".
    static func isSignificant(_ line: String) -> Bool {
        severity(forLine: line) >= .warning
    }

    // MARK: - Normalisation

    private static let normalizers: [(pattern: String, replacement: String)] = [
        // Timestamps first, in the widest shape, so the rest never sees them.
        ("\\d{4}-\\d{2}-\\d{2}[T ]\\d{2}:\\d{2}:\\d{2}(?:[.,]\\d+)?(?:Z|[+-]\\d{2}:?\\d{2})?", "<ts>"),
        ("\\b\\d{2}:\\d{2}:\\d{2}(?:[.,]\\d+)?\\b", "<time>"),
        // UUIDs, then long hex/base64-ish ids (container ids, sha digests).
        ("\\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\\b", "<uuid>"),
        ("\\b(?:sha256:)?[0-9a-f]{12,}\\b", "<hash>"),
        // IPv4[:port] and bare host:port.
        ("\\b\\d{1,3}(?:\\.\\d{1,3}){3}(?::\\d+)?\\b", "<addr>"),
        // Kubernetes pod-name suffixes: name-<replicaset hash>-<pod hash>.
        ("([a-z0-9]+(?:-[a-z0-9]+)*)-[a-z0-9]{8,10}-[a-z0-9]{5}\\b", "$1-<pod>"),
        // Durations and sizes.
        ("\\b\\d+(?:\\.\\d+)?(?:ms|s|m|h|d|ns|us|µs|Ki|Mi|Gi|Ti|KB|MB|GB|TB|kB)\\b", "<qty>"),
        // Quoted strings - a path or a message argument that varies.
        ("\"[^\"]{0,200}\"", "\"<str>\""),
        ("'[^']{0,200}'", "'<str>'"),
        // Absolute paths.
        ("(?:/[A-Za-z0-9._@-]+){2,}/?", "<path>"),
        // Whatever numbers are left.
        ("\\b\\d+\\b", "<n>"),
        // Collapse runs of whitespace so column padding doesn't split a group.
        ("\\s+", " "),
    ]

    private static let compiledNormalizers: [(NSRegularExpression, String)] = {
        normalizers.compactMap { entry in
            guard let regex = try? NSRegularExpression(pattern: entry.pattern, options: []) else {
                assertionFailure("LogErrorExtractor: normalizer '\(entry.pattern)' failed to compile")
                return nil
            }
            return (regex, entry.replacement)
        }
    }()

    /// The group key for a line - see this file's header for why this is
    /// deliberately aggressive.
    static func normalize(_ line: String) -> String {
        var current = line.trimmingCharacters(in: .whitespaces)
        for (regex, replacement) in compiledNormalizers {
            let range = NSRange(current.startIndex..., in: current)
            current = regex.stringByReplacingMatches(in: current, options: [], range: range, withTemplate: replacement)
        }
        return current.trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Timestamps

    private static let timestampPatterns: [String] = [
        "\\d{4}-\\d{2}-\\d{2}[T ]\\d{2}:\\d{2}:\\d{2}(?:[.,]\\d+)?(?:Z|[+-]\\d{2}:?\\d{2})?",
        "\\b\\d{2}:\\d{2}:\\d{2}(?:[.,]\\d+)?\\b",
        // syslog style: "Aug 22 20:14:11"
        "\\b[A-Z][a-z]{2} {1,2}\\d{1,2} \\d{2}:\\d{2}:\\d{2}\\b",
    ]

    private static let compiledTimestamps: [NSRegularExpression] = {
        timestampPatterns.compactMap { try? NSRegularExpression(pattern: $0) }
    }()

    /// The first timestamp appearing in a line, verbatim, or nil. Verbatim
    /// on purpose - spec §8 forbids inventing timestamps, and reformatting a
    /// captured one into a different representation is a small step toward
    /// showing the captain something the log didn't say.
    static func timestamp(in line: String) -> String? {
        let ns = line as NSString
        let full = NSRange(location: 0, length: ns.length)
        for regex in compiledTimestamps {
            if let match = regex.firstMatch(in: line, options: [], range: full) {
                return ns.substring(with: match.range)
            }
        }
        return nil
    }

    /// The short, comparable form used in a group's time range - "20:14:11"
    /// out of a full ISO stamp, so two differently-formatted lines in one
    /// log still read as one range. Falls back to the verbatim stamp.
    static func shortTime(_ stamp: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: "\\d{2}:\\d{2}:\\d{2}") else { return stamp }
        let ns = stamp as NSString
        if let match = regex.firstMatch(in: stamp, options: [], range: NSRange(location: 0, length: ns.length)) {
            return ns.substring(with: match.range)
        }
        return stamp
    }

    // MARK: - Extraction (spec §6, §7)

    /// Collapses every significant line into patterns, ordered by severity
    /// then occurrence count. Bounded by `maxGroups`.
    static func groups(in text: String) -> [LogErrorGroup] {
        guard !text.isEmpty else { return [] }

        struct Accumulator {
            var label: String
            var severity: LogSeverity
            var occurrences: Int
            var firstTimestamp: String?
            var lastTimestamp: String?
            var lineNumbers: [Int]
            var samples: [String]
            /// Preserves discovery order, so two groups with identical
            /// severity and count still sort deterministically.
            var order: Int
        }

        var accumulators: [String: Accumulator] = [:]
        var nextOrder = 0

        for (index, rawLine) in text.components(separatedBy: "\n").prefix(maxLinesScanned).enumerated() {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            let severity = severity(forLine: line)
            guard severity >= .warning else { continue }

            let key = normalize(line)
            guard !key.isEmpty else { continue }
            let stamp = timestamp(in: line).map(shortTime)
            let lineNumber = index + 1

            if var existing = accumulators[key] {
                existing.occurrences += 1
                if existing.severity < severity { existing.severity = severity }
                if let stamp {
                    if existing.firstTimestamp == nil { existing.firstTimestamp = stamp }
                    existing.lastTimestamp = stamp
                }
                if existing.lineNumbers.count < maxSamplesPerGroup { existing.lineNumbers.append(lineNumber) }
                if existing.samples.count < maxSamplesPerGroup { existing.samples.append(line) }
                accumulators[key] = existing
            } else {
                accumulators[key] = Accumulator(
                    label: shortLabel(line),
                    severity: severity,
                    occurrences: 1,
                    firstTimestamp: stamp,
                    lastTimestamp: stamp,
                    lineNumbers: [lineNumber],
                    samples: [line],
                    order: nextOrder
                )
                nextOrder += 1
            }
        }

        let all = accumulators.map { key, acc in
            (acc.order, LogErrorGroup(
                pattern: key,
                label: acc.label,
                severity: acc.severity,
                occurrences: acc.occurrences,
                firstTimestamp: acc.firstTimestamp,
                lastTimestamp: acc.lastTimestamp,
                lineNumbers: acc.lineNumbers,
                sampleLines: acc.samples
            ))
        }

        return all
            .sorted { a, b in
                if a.1.severity != b.1.severity { return a.1.severity > b.1.severity }
                if a.1.occurrences != b.1.occurrences { return a.1.occurrences > b.1.occurrences }
                return a.0 < b.0
            }
            .prefix(maxGroups)
            .map(\.1)
    }

    /// A readable one-line label for a group: the real first matching line
    /// with its leading timestamp/level noise trimmed off and a length cap,
    /// rather than the normalized pattern with its `<n>` placeholders (which
    /// is a key, not something to show a human).
    static func shortLabel(_ line: String, limit: Int = 110) -> String {
        var text = line.trimmingCharacters(in: .whitespaces)

        // Drop a leading timestamp and any immediately following level token.
        if let stamp = timestamp(in: text), text.hasPrefix(stamp) {
            text = String(text.dropFirst(stamp.count)).trimmingCharacters(in: .whitespaces)
        }
        let levelTokens = ["ERROR", "WARN", "WARNING", "FATAL", "INFO", "DEBUG", "TRACE", "[ERROR]", "[WARN]", "[INFO]"]
        for token in levelTokens where text.uppercased().hasPrefix(token) {
            text = String(text.dropFirst(token.count)).trimmingCharacters(in: CharacterSet(charactersIn: " :-\t"))
            break
        }
        if text.isEmpty { text = line.trimmingCharacters(in: .whitespaces) }
        guard text.count > limit else { return text }
        return String(text.prefix(limit - 1)) + "…"
    }

    /// Spec §4/§6's findings, derived purely from what was counted - so the
    /// Analysis tab shows something real even with no AI layer at all.
    /// Only groups at `.high` or above become findings; warnings stay in the
    /// Error Groups tab rather than being promoted into "Critical Findings".
    static func findings(from groups: [LogErrorGroup]) -> [LogFinding] {
        groups
            .filter { $0.severity >= .high }
            .prefix(6)
            .map { group in
                var meta = group.occurrenceText
                if let range = group.timeRange { meta += " · \(range)" }
                return LogFinding(
                    severity: group.severity,
                    title: group.label,
                    detail: "Detected \(group.occurrences) matching line\(group.occurrences == 1 ? "" : "s") in the provided output.",
                    meta: meta
                )
            }
    }

    /// The condensed representation handed to the AI in place of a full log
    /// (spec §6). Never the whole input when it is large: the grouped
    /// patterns with their real counts, plus a bounded head and tail so the
    /// model still sees genuine raw context and formatting.
    static func condensedForPrompt(_ text: String, groups: [LogErrorGroup],
                                   headLines: Int = 60, tailLines: Int = 60) -> String {
        let lines = text.components(separatedBy: "\n")
        guard lines.count > headLines + tailLines else { return text }

        let head = lines.prefix(headLines).joined(separator: "\n")
        let tail = lines.suffix(tailLines).joined(separator: "\n")
        let omitted = lines.count - headLines - tailLines

        var out = head
        out += "\n\n… [\(omitted) lines omitted from the middle of this input — the distinct patterns they contain are listed below] …\n\n"
        out += tail

        if !groups.isEmpty {
            out += "\n\n----- COUNTED PATTERNS (computed locally over all \(lines.count) lines; these counts are exact) -----\n"
            for group in groups {
                var line = "- [\(group.severity.rawValue)] \(group.label) — \(group.occurrences) occurrence\(group.occurrences == 1 ? "" : "s")"
                if let range = group.timeRange { line += " (\(range))" }
                out += line + "\n"
            }
        }
        return out
    }
}
