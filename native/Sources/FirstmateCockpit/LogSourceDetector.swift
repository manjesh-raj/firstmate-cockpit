// Manjesh Grand Line - native macOS app.
//
// `fm/grandline-log-analyzer-build`, spec §3: works out what kind of output
// the captain pasted, so the analysis prompt can be framed correctly and the
// detection strip can say "Source: Kubernetes · Format: kubectl output ·
// Severity: Error" before a single AI call is made.
//
// Deliberately a scored keyword/shape matcher rather than an AI call. Three
// reasons, in order of weight: it has to run *instantly* as the captain
// types or pastes (the mockup shows the strip appearing with the analysis,
// but the Source picker's "Auto Detect" row must resolve with no latency and
// no network); the captain can override it anyway (spec §3's own
// requirement), so a wrong guess costs one click rather than a wrong
// analysis; and it must keep working with `claude` unavailable, since the
// local layer is the half of this feature that never needs a network (see
// `LogAnalyzerModels.swift`'s header).
//
// Scoring, not first-match: real output is mixed (a Kubernetes describe
// contains HTTP URLs, an application log contains stack-trace frames), so
// each signal adds weight to a kind and the highest total wins. Ties resolve
// by `LogSourceKind.pickerOrder`, which puts the more specific kinds first.

import Foundation

enum LogSourceDetector {

    /// How many leading lines are scanned. A 5,000-line log's *kind* is
    /// decided by its first screenful in every realistic case, and scanning
    /// all of it on every keystroke-driven re-detect is wasted work.
    static let scanLineLimit = 400

    /// One weighted signal.
    private struct Signal {
        let kind: LogSourceKind
        let weight: Double
        let needle: String
        /// When true, `needle` is a regex; otherwise a plain lowercase
        /// substring test (much cheaper, and most signals are literal).
        let isRegex: Bool

        init(_ kind: LogSourceKind, _ weight: Double, _ needle: String, regex: Bool = false) {
            self.kind = kind
            self.weight = weight
            self.needle = needle
            self.isRegex = regex
        }
    }

    private static let signals: [Signal] = [
        // Kubernetes
        Signal(.kubernetes, 4, "kubectl "),
        Signal(.kubernetes, 3, "readiness probe"),
        Signal(.kubernetes, 3, "liveness probe"),
        Signal(.kubernetes, 3, "crashloopbackoff"),
        Signal(.kubernetes, 3, "imagepullbackoff"),
        Signal(.kubernetes, 3, "kubelet"),
        Signal(.kubernetes, 2.5, "namespace:"),
        Signal(.kubernetes, 2.5, "apiversion:"),
        Signal(.kubernetes, 2, "containers:"),
        Signal(.kubernetes, 2, "back-off restarting"),
        Signal(.kubernetes, 2, "oomkilled"),
        Signal(.kubernetes, 2, "pod/"),
        Signal(.kubernetes, 2, "deployment.apps/"),
        Signal(.kubernetes, 1.5, "replicaset"),
        Signal(.kubernetes, 1.5, "statefulset"),
        Signal(.kubernetes, 1.5, "persistentvolumeclaim"),
        Signal(.kubernetes, 1.5, "restarts"),

        // Docker
        Signal(.dockerCompose, 4, "docker "),
        Signal(.dockerCompose, 3, "docker-compose"),
        Signal(.dockerCompose, 2.5, "container_id"),
        Signal(.dockerCompose, 2.5, "cannot connect to the docker daemon"),
        Signal(.dockerCompose, 2, "no such container"),
        Signal(.dockerCompose, 2, "exited with code"),

        // systemd / journalctl
        Signal(.systemd, 4, "systemctl "),
        Signal(.systemd, 4, "journalctl"),
        Signal(.systemd, 3, "loaded: loaded"),
        Signal(.systemd, 3, "active: active"),
        Signal(.systemd, 3, "active: failed"),
        Signal(.systemd, 2.5, ".service"),
        Signal(.systemd, 2, "systemd["),
        Signal(.systemd, 2, "main pid:"),

        // Nginx
        Signal(.nginx, 4, "nginx"),
        Signal(.nginx, 2.5, "upstream"),
        Signal(.nginx, 2.5, "[error] "),
        Signal(.nginx, 2, "client:"),
        Signal(.nginx, 2, "server:"),

        // Stack traces
        Signal(.stackTrace, 4, "exception in thread"),
        Signal(.stackTrace, 3.5, "traceback (most recent call last)"),
        Signal(.stackTrace, 3, "\tat ", regex: false),
        Signal(.stackTrace, 3, "caused by:"),
        Signal(.stackTrace, 2.5, "stacktrace"),
        Signal(.stackTrace, 2.5, "panic:"),
        Signal(.stackTrace, 2.5, "goroutine "),
        Signal(.stackTrace, 2, "  file \""),
        Signal(.stackTrace, 2, "nullpointerexception"),
        Signal(.stackTrace, 2, "at java."),
        Signal(.stackTrace, 2, "unhandled exception"),

        // HTTP / network
        Signal(.httpNetwork, 4, "curl "),
        Signal(.httpNetwork, 3, "* connected to"),
        Signal(.httpNetwork, 3, "> get /"),
        Signal(.httpNetwork, 3, "< http/1.1"),
        Signal(.httpNetwork, 3, "< http/2"),
        Signal(.httpNetwork, 2.5, "traceroute"),
        Signal(.httpNetwork, 2.5, "ping "),
        Signal(.httpNetwork, 2.5, "nslookup"),
        Signal(.httpNetwork, 2.5, "dig "),
        Signal(.httpNetwork, 2, "connection refused"),
        Signal(.httpNetwork, 2, "name or service not known"),

        // TLS
        Signal(.tls, 5, "openssl s_client"),
        Signal(.tls, 3.5, "certificate chain"),
        Signal(.tls, 3, "verify return code"),
        Signal(.tls, 3, "ssl handshake"),
        Signal(.tls, 3, "x509"),
        Signal(.tls, 2.5, "notafter="),
        Signal(.tls, 2.5, "-----begin certificate-----"),

        // CloudWatch / AWS
        Signal(.cloudWatch, 4, "aws logs "),
        Signal(.cloudWatch, 3, "logstreamname"),
        Signal(.cloudWatch, 3, "loggroupname"),
        Signal(.cloudWatch, 2.5, "aws cloudwatch"),
        Signal(.cloudWatch, 2, "requestid:"),
        Signal(.cloudWatch, 2, "report requestid"),
        Signal(.cloudWatch, 2, "init duration"),

        // Terraform
        Signal(.terraform, 4, "terraform "),
        Signal(.terraform, 3.5, "terraform will perform the following actions"),
        Signal(.terraform, 3, "plan: "),
        Signal(.terraform, 2.5, "resource \""),
        Signal(.terraform, 2.5, "error: error applying plan"),

        // Application logs
        Signal(.applicationLog, 2, " info "),
        Signal(.applicationLog, 2, " warn "),
        Signal(.applicationLog, 2, " debug "),
        Signal(.applicationLog, 1.5, "level=info"),
        Signal(.applicationLog, 1.5, "level=error"),
        Signal(.applicationLog, 1.5, "logger="),
    ]

    /// ISO-8601-ish or `HH:MM:SS` leading timestamp - the strongest signal
    /// for "this is a timestamped application log" when nothing more
    /// specific matched.
    private static let timestampedLine = try? NSRegularExpression(
        pattern: "^\\s*\\[?(\\d{4}-\\d{2}-\\d{2}[T ]\\d{2}:\\d{2}:\\d{2}|\\d{2}:\\d{2}:\\d{2})",
        options: [.anchorsMatchLines])

    /// Whole-document JSON - a body that parses as JSON, or one that at
    /// least opens and closes with braces and contains an `"error"`-ish key.
    private static func looksLikeJSON(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{") || trimmed.hasPrefix("[") else { return false }
        if let data = trimmed.data(using: .utf8),
           (try? JSONSerialization.jsonObject(with: data)) != nil {
            return true
        }
        return trimmed.hasSuffix("}") || trimmed.hasSuffix("]")
    }

    /// Runs detection. `override` short-circuits the kind (spec §3's manual
    /// override) while still computing a real severity from the content -
    /// overriding "what kind of output is this" should not also freeze the
    /// severity read at whatever it was before.
    static func detect(_ text: String, override: LogSourceKind? = nil) -> LogSourceDetection {
        let severity = detectSeverity(text)

        if let override {
            return LogSourceDetection(kind: override, severity: severity, confidence: 1.0)
        }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return LogSourceDetection(kind: .genericText, severity: .normal, confidence: 0)
        }

        let scanned = trimmed
            .components(separatedBy: "\n")
            .prefix(scanLineLimit)
            .joined(separator: "\n")
        let haystack = scanned.lowercased()

        var scores: [LogSourceKind: Double] = [:]
        for signal in signals {
            if signal.isRegex {
                guard let regex = try? NSRegularExpression(pattern: signal.needle, options: [.caseInsensitive]) else { continue }
                let n = regex.numberOfMatches(in: scanned, range: NSRange(scanned.startIndex..., in: scanned))
                if n > 0 { scores[signal.kind, default: 0] += signal.weight * min(Double(n), 3) / 3 }
            } else if haystack.contains(signal.needle) {
                scores[signal.kind, default: 0] += signal.weight
            }
        }

        if looksLikeJSON(scanned) {
            scores[.jsonError, default: 0] += 6
        }

        if let regex = timestampedLine {
            let matches = regex.numberOfMatches(in: scanned, range: NSRange(scanned.startIndex..., in: scanned))
            if matches >= 2 { scores[.applicationLog, default: 0] += 3 }
            else if matches == 1 { scores[.applicationLog, default: 0] += 1 }
        }

        let best = LogSourceKind.pickerOrder
            .map { ($0, scores[$0] ?? 0) }
            .max { a, b in a.1 == b.1 ? false : a.1 < b.1 }

        guard let (kind, score) = best, score >= 2 else {
            return LogSourceDetection(kind: .genericText, severity: severity, confidence: 0.2)
        }

        // A plain 0-1 read on "how strongly did this match", saturating at
        // 12 points - not a probability, just a comparable number.
        let confidence = min(1.0, score / 12.0)
        return LogSourceDetection(kind: kind, severity: severity, confidence: confidence)
    }

    /// The "Severity:" third of the detection strip - the highest severity
    /// any single line in the input reaches, using the same classifier the
    /// error extractor uses per line, so the strip and the grouped rows can
    /// never disagree about whether something is an error.
    static func detectSeverity(_ text: String) -> LogSeverity {
        var highest = LogSeverity.normal
        for line in text.components(separatedBy: "\n").prefix(scanLineLimit * 4) {
            let severity = LogErrorExtractor.severity(forLine: line)
            if severity > highest { highest = severity }
            if highest == .critical { break }
        }
        return highest
    }
}
