// Manjesh Grand Line - native macOS app.
//
// `fm/grandline-log-analyzer-build`: the pure data model behind the Log /
// Output Analyzer destination (`LogAnalyzerController`). No AppKit, no
// `Process`, no I/O - everything here is plain values so the pipeline that
// produces them (`LogRedactor` -> `LogSourceDetector` -> `LogErrorExtractor`
// -> `LogTimelineBuilder` -> `LogCorrelationBuilder` -> `LogAnalyzerAI`) is
// testable end to end without a window (`LogAnalyzerSelfTest.swift`,
// `FM_RUN_LOG_ANALYZER_TESTS=1`).
//
// The one structural rule worth knowing before extending any of this: an
// analysis is **two layers**, deliberately kept apart rather than merged.
//
//   1. The *local* layer (`LogLocalAnalysis`) is computed on this machine
//      with no network and no AI at all - redaction, source detection,
//      severity classification, error grouping, and the timeline. It is
//      always present, even when `claude` is missing or offline, and it is
//      the only layer allowed to claim something is `Observed`, because it
//      is the only layer that literally counted the lines.
//   2. The *AI* layer (`LogAIAnalysis`) is what one `claude -p` call adds on
//      top - findings prose, a probable root cause with confidence, next
//      steps, suggested commands, inferred/unknown correlation links, and
//      what evidence is still missing. It can be absent (no `claude`, a
//      failure, or the captain never pressed Analyze with AI available) and
//      the page still renders a real, useful investigation.
//
// This split is what makes spec §9's Observed/Inferred/Unknown distinction
// honest rather than decorative: `Observed` links are emitted by
// `LogCorrelationBuilder` from real counted evidence, and the AI is only
// ever allowed to contribute `.inferred`/`.unknown` (enforced in
// `LogAnalyzerAI.parse`, not just asked for in the prompt).

import Foundation

// MARK: - Severity (spec §5)

/// The five-level severity scale from spec §5, in descending order of
/// urgency. `rank` exists so a group's severity can be reduced across many
/// matching lines with `max` without a switch at every call site.
enum LogSeverity: String, CaseIterable, Equatable, Comparable {
    case critical
    case high
    case warning
    case informational
    case normal

    var rank: Int {
        switch self {
        case .critical: return 4
        case .high: return 3
        case .warning: return 2
        case .informational: return 1
        case .normal: return 0
        }
    }

    static func < (a: LogSeverity, b: LogSeverity) -> Bool { a.rank < b.rank }

    var displayName: String {
        switch self {
        case .critical: return "Critical"
        case .high: return "High"
        case .warning: return "Warning"
        case .informational: return "Informational"
        case .normal: return "Normal"
        }
    }

    /// The mockup's own severity dots. Semantic `HelmTint` cases, never a
    /// literal hex - so all 12 palettes resolve their own hues (see
    /// `HelmTint`'s doc comment).
    var tint: HelmTint {
        switch self {
        case .critical: return .critical
        case .high: return .warn
        case .warning: return .warn
        case .informational: return .info
        case .normal: return .good
        }
    }

    /// The coloured circle the mockup shows next to each finding.
    var symbol: String {
        switch self {
        case .critical: return "exclamationmark.octagon.fill"
        case .high: return "exclamationmark.triangle.fill"
        case .warning: return "exclamationmark.triangle"
        case .informational: return "info.circle"
        case .normal: return "checkmark.circle"
        }
    }
}

// MARK: - Source detection (spec §3)

/// The output shapes spec §3 names, plus a catch-all. `format` is the
/// second line the detection strip shows ("Format: kubectl output").
enum LogSourceKind: String, CaseIterable, Equatable {
    case kubernetes
    case dockerCompose
    case systemd
    case nginx
    case applicationLog
    case stackTrace
    case jsonError
    case httpNetwork
    case tls
    case cloudWatch
    case terraform
    case genericText

    var displayName: String {
        switch self {
        case .kubernetes: return "Kubernetes"
        case .dockerCompose: return "Docker"
        case .systemd: return "Linux service"
        case .nginx: return "Nginx"
        case .applicationLog: return "Application logs"
        case .stackTrace: return "Stack trace"
        case .jsonError: return "JSON / API error"
        case .httpNetwork: return "HTTP / network"
        case .tls: return "TLS / certificate"
        case .cloudWatch: return "AWS CloudWatch"
        case .terraform: return "Terraform"
        case .genericText: return "Generic / Unknown"
        }
    }

    /// The "Format:" half of spec §3's detection strip.
    var formatName: String {
        switch self {
        case .kubernetes: return "kubectl output"
        case .dockerCompose: return "docker output"
        case .systemd: return "systemctl / journalctl output"
        case .nginx: return "nginx access/error log"
        case .applicationLog: return "timestamped application log"
        case .stackTrace: return "exception stack trace"
        case .jsonError: return "JSON payload"
        case .httpNetwork: return "curl / HTTP trace"
        case .tls: return "openssl s_client output"
        case .cloudWatch: return "CloudWatch log events"
        case .terraform: return "terraform plan/apply output"
        case .genericText: return "plain text"
        }
    }

    var symbol: String {
        switch self {
        case .kubernetes: return "square.stack.3d.up"
        case .dockerCompose: return "shippingbox"
        case .systemd: return "gearshape.2"
        case .nginx: return "network"
        case .applicationLog: return "doc.text"
        case .stackTrace: return "exclamationmark.bubble"
        case .jsonError: return "curlybraces"
        case .httpNetwork: return "antenna.radiowaves.left.and.right"
        case .tls: return "lock.shield"
        case .cloudWatch: return "cloud"
        case .terraform: return "cube.transparent"
        case .genericText: return "text.alignleft"
        }
    }

    /// Every kind the Source picker offers, in menu order. `nil` is the
    /// "Auto Detect" row (spec §3's override affordance).
    static var pickerOrder: [LogSourceKind] {
        [.kubernetes, .dockerCompose, .systemd, .nginx, .applicationLog,
         .stackTrace, .jsonError, .httpNetwork, .tls, .cloudWatch, .terraform, .genericText]
    }
}

/// What `LogSourceDetector.detect` concluded. `confidence` is a plain 0-1
/// score derived from how many signals matched - shown as nothing in the UI
/// today beyond ordering, but kept so a future "we're not sure, please
/// override" nudge has a real number rather than a guess.
struct LogSourceDetection: Equatable {
    var kind: LogSourceKind
    var severity: LogSeverity
    var confidence: Double

    var summary: String {
        "Source: \(kind.displayName) · Format: \(kind.formatName) · Severity: \(severity.displayName)"
    }
}

// MARK: - Error extraction / grouping (spec §6, §7)

/// One collapsed pattern: many raw lines that normalize to the same shape.
/// `sampleLines` holds the real matching lines (capped - see
/// `LogErrorExtractor.maxSamplesPerGroup`) so spec §6's "clicking a pattern
/// shows the matching lines" is real content, not a placeholder.
struct LogErrorGroup: Identifiable, Equatable {
    /// Stable within one analysis - the normalized pattern itself, which is
    /// by construction unique per group.
    var id: String { pattern }

    /// The normalized shape (numbers/UUIDs/IPs/timestamps replaced with
    /// placeholders) - this is what makes 43 near-identical lines one row.
    var pattern: String
    /// A human-facing label: the first real matching line, trimmed and
    /// shortened, rather than the normalized pattern with its `<n>` holes.
    var label: String
    var severity: LogSeverity
    var occurrences: Int
    var firstTimestamp: String?
    var lastTimestamp: String?
    /// 1-based line numbers in the (redacted) input, capped the same way
    /// `sampleLines` is.
    var lineNumbers: [Int]
    var sampleLines: [String]

    /// "20:14:11 → 20:21:47", or nil when the input carried no timestamps.
    var timeRange: String? {
        guard let first = firstTimestamp else { return nil }
        guard let last = lastTimestamp, last != first else { return first }
        return "\(first) → \(last)"
    }

    var occurrenceText: String {
        "\(occurrences) occurrence\(occurrences == 1 ? "" : "s")"
    }
}

// MARK: - Timeline (spec §8)

/// One dated event. Built only from timestamps genuinely present in the
/// input - `LogTimelineBuilder` never synthesizes one (spec §8's explicit
/// "do not invent timestamps").
struct LogTimelineEvent: Identifiable, Equatable {
    var id: String { "\(timestamp)#\(lineNumber)" }
    var timestamp: String
    var title: String
    var detail: String
    var severity: LogSeverity
    var lineNumber: Int
}

/// Either a real timeline or the explicit "unavailable" state spec §8
/// requires the UI to state plainly.
enum LogTimeline: Equatable {
    case unavailable(reason: String)
    case events([LogTimelineEvent])

    var events: [LogTimelineEvent] {
        if case .events(let e) = self { return e }
        return []
    }

    var isAvailable: Bool {
        if case .events(let e) = self { return !e.isEmpty }
        return false
    }
}

// MARK: - Correlation (spec §9)

enum LogCorrelationKind: String, Equatable, CaseIterable {
    /// Directly present in the input - only `LogCorrelationBuilder` (which
    /// counted the lines) may produce these.
    case observed
    /// A likely relationship, contributed by the AI layer.
    case inferred
    /// Explicitly cannot be established from what was provided.
    case unknown

    var displayName: String {
        switch self {
        case .observed: return "Observed"
        case .inferred: return "Inferred"
        case .unknown: return "Unknown"
        }
    }

    var detail: String {
        switch self {
        case .observed: return "Stated directly in the provided output"
        case .inferred: return "The most likely causal link"
        case .unknown: return "Needs more evidence"
        }
    }

    var tint: HelmTint {
        switch self {
        case .observed: return .good
        case .inferred: return .warn
        case .unknown: return .neutral
        }
    }

    var badgeLetter: String {
        switch self {
        case .observed: return "O"
        case .inferred: return "I"
        case .unknown: return "?"
        }
    }
}

struct LogCorrelationLink: Identifiable, Equatable {
    var id: String { "\(kind.rawValue)#\(order)#\(text)" }
    var order: Int
    var kind: LogCorrelationKind
    var text: String
    /// Only set for `.observed` - the group/timeline evidence that produced
    /// it, so the UI can say *why* something counts as observed.
    var evidence: String?
}

// MARK: - Findings, root cause, next steps (spec §4, §10)

struct LogFinding: Identifiable, Equatable {
    var id: String { "\(severity.rawValue)#\(title)" }
    var severity: LogSeverity
    var title: String
    var detail: String
    /// e.g. "43 occurrences · 20:14:11 → 20:21:47" - only populated when a
    /// real `LogErrorGroup` backs the finding.
    var meta: String?
}

enum LogConfidence: String, Equatable, CaseIterable {
    case high
    case medium
    case low

    var displayName: String {
        switch self {
        case .high: return "High"
        case .medium: return "Medium"
        case .low: return "Low"
        }
    }

    var tint: HelmTint {
        switch self {
        case .high: return .good
        case .medium: return .warn
        case .low: return .critical
        }
    }

    static func parse(_ raw: String) -> LogConfidence {
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "high": return .high
        case "low": return .low
        default: return .medium
        }
    }
}

/// Spec §10. `missingEvidence` is not optional decoration - the spec's
/// "never claim certainty when the logs don't prove it" rule is enforced in
/// the prompt *and* surfaced here so the UI always has somewhere to show
/// what could not be established.
struct LogRootCause: Equatable {
    var summary: String
    var explanation: String
    var confidence: LogConfidence
    var evidence: [String]
    var missingEvidence: [String]
    var contradictingEvidence: [String]
}

/// Spec §11. `libraryCommandID` is set by `LogAnalyzerCommandMatcher` when
/// an equivalent command already exists in the captain's own Command
/// Library - the spec's "do not generate arbitrary commands if an
/// equivalent saved command exists" rule, resolved after the AI answers
/// rather than trusted to the model.
struct LogSuggestedCommand: Identifiable, Equatable {
    var id: String { "\(order)#\(command)" }
    var order: Int
    var title: String
    var command: String
    var rationale: String
    var libraryCommandID: String?
    var libraryCommandName: String?

    var isFromLibrary: Bool { libraryCommandID != nil }
}

// MARK: - The two analysis layers

/// Everything computed on this machine with no AI and no network.
struct LogLocalAnalysis: Equatable {
    var detection: LogSourceDetection
    var groups: [LogErrorGroup]
    var timeline: LogTimeline
    /// `.observed` links only - see this file's header.
    var observedCorrelation: [LogCorrelationLink]
    var lineCount: Int
    /// Findings derived purely from the counted groups, so the Analysis tab
    /// is never empty even with no AI available.
    var findings: [LogFinding]
}

/// Everything one `claude -p` call added.
struct LogAIAnalysis: Equatable {
    var findings: [LogFinding]
    var rootCause: LogRootCause?
    var nextSteps: [String]
    var suggestedCommands: [LogSuggestedCommand]
    /// `.inferred`/`.unknown` only - `LogAnalyzerAI.parse` drops anything
    /// claiming `.observed`, since the model did not count the lines.
    var correlation: [LogCorrelationLink]
    /// Spec §12 - what the AI says it still needs.
    var neededEvidence: [String]
    var summary: String
}

/// One completed analysis pass over the current evidence set.
struct LogAnalysis: Equatable {
    var local: LogLocalAnalysis
    var ai: LogAIAnalysis?
    /// Set when the AI layer was attempted and failed - shown as an inline
    /// notice rather than swallowed, while the local layer still renders.
    var aiFailure: String?
    var mode: LogAnalysisMode
    var analyzedAt: Date

    /// AI findings first (they carry prose), then any counted-group finding
    /// the AI didn't already cover, de-duplicated by title.
    var findings: [LogFinding] {
        var seen = Set<String>()
        var out: [LogFinding] = []
        for finding in (ai?.findings ?? []) + local.findings
        where seen.insert(finding.title.lowercased()).inserted {
            out.append(finding)
        }
        return out.sorted { $0.severity > $1.severity }
    }

    /// Observed links (local, counted) always lead; inferred/unknown follow
    /// in the order the AI returned them.
    var correlation: [LogCorrelationLink] {
        local.observedCorrelation + (ai?.correlation ?? [])
    }
}

// MARK: - Analysis modes (spec §22)

/// The quick modes spec §22 asks for, so the captain never writes a prompt.
enum LogAnalysisMode: String, CaseIterable, Equatable {
    case analyze
    case explain
    case findRootCause
    case findErrors
    case summarize
    case troubleshoot
    case compare
    case suggestNextSteps
    case createRCA
    case createRunbook

    var displayName: String {
        switch self {
        case .analyze: return "Analyze"
        case .explain: return "Explain"
        case .findRootCause: return "Find Root Cause"
        case .findErrors: return "Find Errors"
        case .summarize: return "Summarize"
        case .troubleshoot: return "Troubleshoot"
        case .compare: return "Compare"
        case .suggestNextSteps: return "Suggest Next Steps"
        case .createRCA: return "Create RCA"
        case .createRunbook: return "Create Runbook"
        }
    }

    /// One extra sentence appended to the shared analysis prompt - the modes
    /// differ in emphasis, never in the response schema, so one parser
    /// handles all ten.
    var instruction: String {
        switch self {
        case .analyze:
            return "Give a balanced, complete analysis: what is failing, why, and what to do next."
        case .explain:
            return "Focus on explaining, in plain language, what this output means for someone who did not run the command."
        case .findRootCause:
            return "Focus almost entirely on the root cause: weigh competing explanations and be explicit about what the evidence does and does not prove."
        case .findErrors:
            return "Focus on enumerating every distinct error and warning present. Keep the root cause section brief."
        case .summarize:
            return "Focus on a short, high-signal summary. Keep findings to the few that matter."
        case .troubleshoot:
            return "Focus on an actionable troubleshooting path: ordered next steps and the commands that would confirm or eliminate each hypothesis."
        case .compare:
            return "The input contains two labelled sections to compare. Focus on what changed between them: new errors, resolved errors, changed values, and behavioural differences."
        case .suggestNextSteps:
            return "Focus on next steps and investigation commands. Keep findings and root cause brief."
        case .createRCA:
            return "Focus on material for a written incident review: impact, timeline, root cause, and preventive actions."
        case .createRunbook:
            return "Focus on the reusable procedure: the symptoms that identify this situation, the ordered investigation steps, and the resolution."
        }
    }
}

// MARK: - Evidence (spec §13)

/// Where one piece of evidence came from. Retained per item, per spec §13's
/// "each evidence item should retain its source".
enum LogEvidenceOrigin: String, Equatable {
    case pasted
    case file
    case clipboard
    case terminal

    var displayName: String {
        switch self {
        case .pasted: return "Pasted"
        case .file: return "File"
        case .clipboard: return "Clipboard"
        case .terminal: return "Terminal"
        }
    }

    var symbol: String {
        switch self {
        case .pasted: return "doc.on.clipboard"
        case .file: return "doc.text"
        case .clipboard: return "list.clipboard"
        case .terminal: return "terminal"
        }
    }
}

/// One piece of evidence in a (possibly multi-input) investigation.
///
/// **`text` is always the redacted text.** Raw, unredacted input never
/// reaches this type - `LogAnalyzerController` redacts at the moment
/// evidence is added, so nothing downstream (analysis, storage, copy,
/// artifacts) can accidentally handle secrets. `redactions` carries only the
/// *shape* of what was removed (kind + the masked replacement), never the
/// secret value itself, so an investigation this app saves can never contain
/// one (spec §14's "never automatically store detected secrets").
struct LogEvidenceItem: Identifiable, Equatable {
    var id: UUID
    var label: String
    var origin: LogEvidenceOrigin
    /// Free text naming where it came from - a host label, a filename, etc.
    var sourceDetail: String?
    var text: String
    var detection: LogSourceDetection
    var redactionCount: Int
    var addedAt: Date

    init(id: UUID = UUID(), label: String, origin: LogEvidenceOrigin, sourceDetail: String? = nil,
         text: String, detection: LogSourceDetection, redactionCount: Int, addedAt: Date = Date()) {
        self.id = id
        self.label = label
        self.origin = origin
        self.sourceDetail = sourceDetail
        self.text = text
        self.detection = detection
        self.redactionCount = redactionCount
        self.addedAt = addedAt
    }

    var lineCount: Int { text.isEmpty ? 0 : text.components(separatedBy: "\n").count }
}

// MARK: - Storage choice (spec §15)

enum LogStorageChoice: String, CaseIterable, Equatable {
    /// The default, per spec §15.
    case doNotSave
    case metadataOnly
    case complete

    var displayName: String {
        switch self {
        case .doNotSave: return "Do not save"
        case .metadataOnly: return "Save metadata only"
        case .complete: return "Save complete investigation"
        }
    }

    var detail: String {
        switch self {
        case .doNotSave:
            return "This investigation exists only for this session and disappears when you navigate away"
        case .metadataOnly:
            return "Title, timestamp, source and root-cause summary — no log content is kept"
        case .complete:
            return "Redacted input, findings, timeline and correlation — visible in History below"
        }
    }
}

// MARK: - Investigation (spec §13, §23, §25)

/// A whole investigation: its evidence, its latest analysis, and the
/// metadata `LogAnalyzerStore` persists (when the captain asks it to).
struct LogInvestigation: Identifiable, Equatable {
    var id: String
    var title: String
    var createdAt: Date
    var updatedAt: Date
    var evidence: [LogEvidenceItem]
    var analysis: LogAnalysis?
    var storage: LogStorageChoice
    var tags: [String]

    init(id: String = LogInvestigation.newID(), title: String = "Untitled investigation",
         createdAt: Date = Date(), updatedAt: Date = Date(),
         evidence: [LogEvidenceItem] = [], analysis: LogAnalysis? = nil,
         storage: LogStorageChoice = .doNotSave, tags: [String] = []) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.evidence = evidence
        self.analysis = analysis
        self.storage = storage
        self.tags = tags
    }

    static func newID() -> String { UUID().uuidString.lowercased() }

    /// Highest severity anything in the analysis reached - drives the
    /// history row's severity dot (spec §23).
    var severity: LogSeverity {
        analysis?.findings.map(\.severity).max()
            ?? analysis?.local.groups.map(\.severity).max()
            ?? .normal
    }

    var rootCauseSummary: String? { analysis?.ai?.rootCause?.summary }

    var sourceKind: LogSourceKind { evidence.first?.detection.kind ?? .genericText }

    /// The one-line status spec §23's history list shows.
    var statusText: String {
        if analysis == nil { return "Not analyzed" }
        if rootCauseSummary != nil { return "Root cause found" }
        if (analysis?.local.groups.isEmpty ?? true) { return "No issues found" }
        return "Analyzed"
    }

    var combinedText: String {
        evidence.map { item in
            let header = "===== \(item.label) (\(item.origin.displayName)"
                + (item.sourceDetail.map { ": \($0)" } ?? "") + ") ====="
            return header + "\n" + item.text
        }.joined(separator: "\n\n")
    }
}
