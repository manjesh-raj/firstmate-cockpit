// Manjesh Grand Line - native macOS app.
//
// `fm/grandline-log-analyzer-build`, spec §15 (log privacy), §23
// (investigation history) and §25 (storage structure).
//
// **Default is not to keep anything.** `LogStorageChoice.doNotSave` is the
// default on every new investigation, and this store is only ever written to
// by an explicit `save(_:)` call that the controller makes *after* the
// captain has picked one of the other two options. Navigating away from an
// unsaved investigation loses it, on purpose.
//
// The three modes, and what each actually writes:
//   * `.doNotSave`    — nothing reaches disk. `save` deletes any previously
//                       written copy of that id, so downgrading a saved
//                       investigation genuinely removes it rather than
//                       leaving a stale file behind.
//   * `.metadataOnly` — `investigation.yaml` only: title, timestamps, source
//                       kind, severity, status, root-cause summary, tags,
//                       and the *shape* of the evidence (label, origin, line
//                       count). No log content of any kind.
//   * `.complete`     — the above, plus `analysis.md` (the same rendering
//                       "Copy Full Analysis" produces) and one file per
//                       evidence item under `evidence/`.
//
// **What can never be written, in any mode: a secret.** Evidence text only
// exists in this app already redacted (`LogEvidenceItem.text`'s doc comment
// explains why there is no unredacted copy to write), and the redaction
// records this store persists carry a kind and a fingerprint, never a value.
// `LogAnalyzerSelfTest` proves it by grepping the bytes of a real saved
// investigation for planted secret values rather than by reasoning about it.
//
// Layout, matching spec §25 (adjusted to this app's real repo layout - the
// spec's `personal-tasks/shift/` prefix is already this store's root):
//
//   <root>/investigations/<YYYY>/<YYYY-MM-DD-slug>/
//       investigation.yaml
//       analysis.md            (complete mode only)
//       evidence/<n>-<slug>.log (complete mode only)
//
// Root resolution mirrors `CommandLibraryStore`'s exactly, including the
// lesson recorded in its own header: a store living *inside*
// `ShiftGitSync`'s `personal-tasks/` subtree must honour `FM_SHIFT_DIR` as
// well as its own narrower override, or a self-test that sets only
// `FM_SHIFT_DIR` (the established way to avoid the captain's real synced
// clone) would still write into production.

import Foundation
import Yaml

final class LogAnalyzerStore {

    let root: URL
    /// `nil` when an env override bypasses git sync - same convention as
    /// `ShiftStore.gitSync`/`CommandLibraryStore.gitSync`.
    let gitSync: ShiftGitSync?

    private let fm = FileManager.default

    private var investigationsDir: URL { root.appendingPathComponent("investigations", isDirectory: true) }

    init() {
        let env = ProcessInfo.processInfo.environment
        if let override = env["FM_LOG_ANALYZER_DIR"], !override.isEmpty {
            root = URL(fileURLWithPath: (override as NSString).expandingTildeInPath, isDirectory: true)
            gitSync = nil
        } else if let override = env["FM_SHIFT_DIR"], !override.isEmpty {
            root = URL(fileURLWithPath: (override as NSString).expandingTildeInPath, isDirectory: true)
            gitSync = nil
        } else {
            let sync = ShiftGitSync.shared
            sync.start()
            root = sync.dataRoot
            gitSync = sync
        }
        try? fm.createDirectory(at: investigationsDir, withIntermediateDirectories: true)
    }

    // MARK: - History (spec §23)

    /// One row in the history list. Deliberately a separate, lighter type
    /// than `LogInvestigation`: the history panel renders dozens of these
    /// and never needs the evidence text, so a listing does not read every
    /// saved log file off disk.
    struct HistoryEntry: Identifiable, Equatable {
        var id: String
        var title: String
        var createdAt: Date
        var severity: LogSeverity
        var sourceKind: LogSourceKind
        var status: String
        var rootCauseSummary: String?
        var storage: LogStorageChoice
        var tags: [String]
        /// The on-disk folder, so `load` doesn't have to re-derive the
        /// year/slug path from the title (which could have been renamed).
        var directory: URL

        var relativeTime: String { LogAnalyzerStore.relativeTime(from: createdAt) }
    }

    /// GL-35: memoised `history()`.
    ///
    /// Building it stats and YAML-parses one folder per saved investigation,
    /// and the Log Analyzer page calls it on every render (the history rail)
    /// *and* from `directory(forID:)` on every save/delete - so the walk grew
    /// with the archive and was repaid several times per interaction.
    /// Invalidated by this store's own writes; a page that wants to see an
    /// external change calls `invalidateHistoryCache()` (its refresh path
    /// does).
    private var historyCache: [HistoryEntry]?

    func invalidateHistoryCache() { historyCache = nil }

    /// Every saved investigation, newest first.
    func history() -> [HistoryEntry] {
        if let historyCache { return historyCache }
        let entries = scanHistory()
        historyCache = entries
        return entries
    }

    private func scanHistory() -> [HistoryEntry] {
        guard let years = try? fm.contentsOfDirectory(at: investigationsDir,
                                                      includingPropertiesForKeys: [.isDirectoryKey],
                                                      options: [.skipsHiddenFiles]) else { return [] }
        var entries: [HistoryEntry] = []
        for year in years {
            guard (try? year.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { continue }
            guard let folders = try? fm.contentsOfDirectory(at: year,
                                                            includingPropertiesForKeys: [.isDirectoryKey],
                                                            options: [.skipsHiddenFiles]) else { continue }
            for folder in folders {
                guard (try? folder.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { continue }
                if let entry = readEntry(in: folder) { entries.append(entry) }
            }
        }
        return entries.sorted { $0.createdAt > $1.createdAt }
    }

    // MARK: - Saving (spec §15, §25)

    /// Writes (or removes) an investigation according to its own
    /// `storage` field. Returns the directory written, or nil for
    /// `.doNotSave`.
    @discardableResult
    func save(_ investigation: LogInvestigation) -> URL? {
        defer { invalidateHistoryCache() }
        // A previously-saved copy is always removed first, so changing the
        // storage choice downward genuinely deletes content rather than
        // leaving `analysis.md`/`evidence/` orphaned next to a now-metadata-
        // only `investigation.yaml`.
        if let existing = directory(forID: investigation.id) {
            try? fm.removeItem(at: existing)
        }

        guard investigation.storage != .doNotSave else {
            gitSync?.markDirty()
            return nil
        }

        let dir = newDirectory(for: investigation)
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try ShiftYamlBridge.writeMapping(path: dir.appendingPathComponent("investigation.yaml").path,
                                             doc: metadataYaml(investigation))

            if investigation.storage == .complete {
                let analysis = LogAnalyzerArtifacts.fullAnalysisText(investigation)
                try analysis.write(to: dir.appendingPathComponent("analysis.md"), atomically: true, encoding: .utf8)

                let evidenceDir = dir.appendingPathComponent("evidence", isDirectory: true)
                try fm.createDirectory(at: evidenceDir, withIntermediateDirectories: true)
                for (index, item) in investigation.evidence.enumerated() {
                    let name = String(format: "%02d-%@.log", index + 1, Self.slugify(item.label))
                    try item.text.write(to: evidenceDir.appendingPathComponent(name),
                                        atomically: true, encoding: .utf8)
                }
            }
        } catch {
            return nil
        }

        gitSync?.markDirty()
        return dir
    }

    /// Removes a saved investigation entirely.
    func delete(id: String) {
        guard let dir = directory(forID: id) else { return }
        try? fm.removeItem(at: dir)
        invalidateHistoryCache()
        gitSync?.markDirty()
    }

    /// Reloads a saved investigation. Evidence text is only present for a
    /// `.complete` save; a `.metadataOnly` entry comes back with its
    /// evidence shells (label/origin/line count) and empty text, which is
    /// exactly what was stored.
    func load(id: String) -> LogInvestigation? {
        guard let dir = directory(forID: id),
              let doc = ShiftYamlBridge.readMapping(path: dir.appendingPathComponent("investigation.yaml").path),
              let dict = doc.dictionary else { return nil }

        let storage = LogStorageChoice(rawValue: ShiftYamlBridge.string(dict["storage"]) ?? "") ?? .metadataOnly
        let evidenceDir = dir.appendingPathComponent("evidence", isDirectory: true)

        var evidence: [LogEvidenceItem] = []
        for (index, entry) in (dict["evidence"]?.array ?? []).enumerated() {
            guard let e = entry.dictionary else { continue }
            let label = ShiftYamlBridge.string(e["label"]) ?? "Evidence \(index + 1)"
            let origin = LogEvidenceOrigin(rawValue: ShiftYamlBridge.string(e["origin"]) ?? "") ?? .pasted
            let kind = LogSourceKind(rawValue: ShiftYamlBridge.string(e["source_kind"]) ?? "") ?? .genericText
            let severity = LogSeverity(rawValue: ShiftYamlBridge.string(e["severity"]) ?? "") ?? .normal
            var text = ""
            if storage == .complete {
                let name = String(format: "%02d-%@.log", index + 1, Self.slugify(label))
                text = (try? String(contentsOf: evidenceDir.appendingPathComponent(name), encoding: .utf8)) ?? ""
            }
            evidence.append(LogEvidenceItem(
                label: label,
                origin: origin,
                sourceDetail: ShiftYamlBridge.string(e["source_detail"]),
                text: text,
                detection: LogSourceDetection(kind: kind, severity: severity, confidence: 1),
                redactionCount: e["redactions"]?.int ?? 0,
                addedAt: ShiftYamlBridge.date(e["added_at"]) ?? Date()
            ))
        }

        return LogInvestigation(
            id: ShiftYamlBridge.string(dict["id"]) ?? id,
            title: ShiftYamlBridge.string(dict["title"]) ?? "Untitled investigation",
            createdAt: ShiftYamlBridge.date(dict["created_at"]) ?? Date(),
            updatedAt: ShiftYamlBridge.date(dict["updated_at"]) ?? Date(),
            evidence: evidence,
            analysis: nil,
            storage: storage,
            tags: (dict["tags"]?.array ?? []).compactMap { ShiftYamlBridge.string($0) }
        )
    }

    /// The saved `analysis.md`, when one exists (`.complete` only).
    func savedAnalysisMarkdown(id: String) -> String? {
        guard let dir = directory(forID: id) else { return nil }
        return try? String(contentsOf: dir.appendingPathComponent("analysis.md"), encoding: .utf8)
    }

    // MARK: - YAML

    /// Spec §25's `investigation.yaml`. Carries no log content and no secret
    /// values in any mode - see this file's header.
    private func metadataYaml(_ investigation: LogInvestigation) -> Yaml {
        var m = YamlOrderedMap()
        m[ShiftYamlBridge.key("id")] = ShiftYamlBridge.str(investigation.id)
        m[ShiftYamlBridge.key("title")] = ShiftYamlBridge.str(investigation.title)
        m[ShiftYamlBridge.key("created_at")] = ShiftYamlBridge.str(ShiftYamlBridge.isoString(investigation.createdAt))
        m[ShiftYamlBridge.key("updated_at")] = ShiftYamlBridge.str(ShiftYamlBridge.isoString(investigation.updatedAt))
        m[ShiftYamlBridge.key("storage")] = ShiftYamlBridge.str(investigation.storage.rawValue)
        m[ShiftYamlBridge.key("severity")] = ShiftYamlBridge.str(investigation.severity.rawValue)
        m[ShiftYamlBridge.key("source_kind")] = ShiftYamlBridge.str(investigation.sourceKind.rawValue)
        m[ShiftYamlBridge.key("status")] = ShiftYamlBridge.str(investigation.statusText)
        m[ShiftYamlBridge.key("root_cause")] = investigation.rootCauseSummary.map(ShiftYamlBridge.str) ?? .null
        m[ShiftYamlBridge.key("confidence")] = investigation.analysis?.ai?.rootCause
            .map { ShiftYamlBridge.str($0.confidence.rawValue) } ?? .null
        m[ShiftYamlBridge.key("mode")] = investigation.analysis
            .map { ShiftYamlBridge.str($0.mode.rawValue) } ?? .null
        m[ShiftYamlBridge.key("tags")] = .array(investigation.tags.map(ShiftYamlBridge.str))

        m[ShiftYamlBridge.key("evidence")] = .array(investigation.evidence.map { item in
            var e = YamlOrderedMap()
            e[ShiftYamlBridge.key("label")] = ShiftYamlBridge.str(item.label)
            e[ShiftYamlBridge.key("origin")] = ShiftYamlBridge.str(item.origin.rawValue)
            e[ShiftYamlBridge.key("source_detail")] = item.sourceDetail.map(ShiftYamlBridge.str) ?? .null
            e[ShiftYamlBridge.key("source_kind")] = ShiftYamlBridge.str(item.detection.kind.rawValue)
            e[ShiftYamlBridge.key("severity")] = ShiftYamlBridge.str(item.detection.severity.rawValue)
            e[ShiftYamlBridge.key("lines")] = .int(item.lineCount)
            // The *count* of redactions, never their values - see the header.
            e[ShiftYamlBridge.key("redactions")] = .int(item.redactionCount)
            e[ShiftYamlBridge.key("added_at")] = ShiftYamlBridge.str(ShiftYamlBridge.isoString(item.addedAt))
            return .dictionary(e)
        })

        // Counted patterns carry a `label` that is a **real line from the
        // log** (that is the point of a label - see `LogErrorGroup.label`),
        // so they are log content, not metadata. Spec §15's metadata-only
        // mode keeps "title, timestamp, source and root-cause summary" and
        // explicitly no log content, so these are written only for a
        // `.complete` save. Caught by `LogAnalyzerSelfTest`'s own
        // "metadata-only must not carry raw log lines" check, not by
        // reading the spec twice.
        if investigation.storage == .complete,
           let groups = investigation.analysis?.local.groups, !groups.isEmpty {
            m[ShiftYamlBridge.key("patterns")] = .array(groups.map { group in
                var g = YamlOrderedMap()
                g[ShiftYamlBridge.key("label")] = ShiftYamlBridge.str(group.label)
                g[ShiftYamlBridge.key("severity")] = ShiftYamlBridge.str(group.severity.rawValue)
                g[ShiftYamlBridge.key("occurrences")] = .int(group.occurrences)
                g[ShiftYamlBridge.key("time_range")] = group.timeRange.map(ShiftYamlBridge.str) ?? .null
                return .dictionary(g)
            })
        }

        return .dictionary(m)
    }

    private func readEntry(in folder: URL) -> HistoryEntry? {
        guard let doc = ShiftYamlBridge.readMapping(path: folder.appendingPathComponent("investigation.yaml").path),
              let dict = doc.dictionary,
              let id = ShiftYamlBridge.string(dict["id"]) else { return nil }
        return HistoryEntry(
            id: id,
            title: ShiftYamlBridge.string(dict["title"]) ?? "Untitled investigation",
            createdAt: ShiftYamlBridge.date(dict["created_at"]) ?? Date(),
            severity: LogSeverity(rawValue: ShiftYamlBridge.string(dict["severity"]) ?? "") ?? .normal,
            sourceKind: LogSourceKind(rawValue: ShiftYamlBridge.string(dict["source_kind"]) ?? "") ?? .genericText,
            status: ShiftYamlBridge.string(dict["status"]) ?? "Analyzed",
            rootCauseSummary: ShiftYamlBridge.string(dict["root_cause"]),
            storage: LogStorageChoice(rawValue: ShiftYamlBridge.string(dict["storage"]) ?? "") ?? .metadataOnly,
            tags: (dict["tags"]?.array ?? []).compactMap { ShiftYamlBridge.string($0) },
            directory: folder
        )
    }

    // MARK: - Paths

    /// Finds an already-written folder for `id` by scanning, rather than
    /// re-deriving the path from the title - a renamed investigation keeps
    /// its original folder, so a title-derived path would miss it and leave
    /// a duplicate behind.
    private func directory(forID id: String) -> URL? {
        if let known = history().first(where: { $0.id == id })?.directory { return known }
        // GL-35: a folder whose `investigation.yaml` no longer parses is
        // invisible to `history()`, which used to make it both undeletable
        // *and* invisible to `save`'s "remove the previous copy first" step -
        // so re-saving that investigation silently left a duplicate folder
        // behind and the corrupt one on disk forever. Fall back to a raw
        // scan matching the id in the file's own bytes, which needs no
        // successful parse.
        return rawDirectoryContainingID(id)
    }

    private func rawDirectoryContainingID(_ id: String) -> URL? {
        guard let years = try? fm.contentsOfDirectory(at: investigationsDir,
                                                     includingPropertiesForKeys: [.isDirectoryKey],
                                                     options: [.skipsHiddenFiles]) else { return nil }
        for year in years {
            guard let folders = try? fm.contentsOfDirectory(at: year,
                                                            includingPropertiesForKeys: [.isDirectoryKey],
                                                            options: [.skipsHiddenFiles]) else { continue }
            for folder in folders {
                let yaml = folder.appendingPathComponent("investigation.yaml")
                guard let text = try? String(contentsOf: yaml, encoding: .utf8) else { continue }
                // The id is written as its own `id: "<uuid>"` line, so a plain
                // containment check is unambiguous for a UUID-shaped id and
                // needs no parser.
                if text.contains(id) { return folder }
            }
        }
        return nil
    }

    private func newDirectory(for investigation: LogInvestigation) -> URL {
        let calendar = Calendar(identifier: .gregorian)
        let year = String(calendar.component(.year, from: investigation.createdAt))
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        let name = "\(formatter.string(from: investigation.createdAt))-\(Self.slugify(investigation.title))"
        return investigationsDir
            .appendingPathComponent(year, isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
    }

    static func slugify(_ title: String) -> String {
        var slug = ""
        var lastWasDash = false
        for ch in title.lowercased() {
            if ch.isLetter || ch.isNumber {
                slug.append(ch)
                lastWasDash = false
            } else if !lastWasDash, !slug.isEmpty {
                slug.append("-")
                lastWasDash = true
            }
        }
        while slug.hasSuffix("-") { slug.removeLast() }
        if slug.isEmpty { slug = "investigation" }
        return String(slug.prefix(60))
    }

    static func relativeTime(from date: Date) -> String {
        let calendar = Calendar.current
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")

        if calendar.isDateInToday(date) {
            formatter.dateFormat = "HH:mm"
            return "Today, \(formatter.string(from: date))"
        }
        if calendar.isDateInYesterday(date) {
            formatter.dateFormat = "HH:mm"
            return "Yesterday, \(formatter.string(from: date))"
        }
        let days = calendar.dateComponents([.day], from: date, to: Date()).day ?? 0
        if days < 7 {
            formatter.dateFormat = "HH:mm"
            return "\(days) days ago, \(formatter.string(from: date))"
        }
        formatter.dateFormat = "MMM d, HH:mm"
        return formatter.string(from: date)
    }
}

/// Thin, local YAML helpers.
///
/// `ShiftYaml`'s own equivalents are `private` to that file, and widening
/// them would mean this feature's storage format could be changed by an edit
/// aimed at task/follow-up storage. Same vendored `Yaml` library and the
/// same `YamlBeautify.dump` writer (so the order- and quote-preservation
/// patches described in `YamlBeautify.swift`'s header apply here too) - just
/// its own small surface.
enum ShiftYamlBridge {
    static func key(_ s: String) -> Yaml { .string(s, quoted: .double) }
    static func str(_ s: String) -> Yaml { .string(s, quoted: .double) }

    static func string(_ y: Yaml?) -> String? {
        guard let y else { return nil }
        if case .string(let s, _) = y { return s.isEmpty ? nil : s }
        return nil
    }

    static func date(_ y: Yaml?) -> Date? {
        guard let s = string(y) else { return nil }
        return isoFormatter.date(from: s)
    }

    static func isoString(_ date: Date) -> String { isoFormatter.string(from: date) }

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func readMapping(path: String) -> Yaml? {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8), !text.isEmpty else { return nil }
        return try? Yaml.load(text)
    }

    static func writeMapping(path: String, doc: Yaml) throws {
        let text = YamlBeautify.dump([doc])
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (text + "\n").write(to: url, atomically: true, encoding: .utf8)
    }
}
