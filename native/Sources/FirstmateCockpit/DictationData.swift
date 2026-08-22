// Manjesh Grand Line - native macOS app.
//
// Dictation, phase 2 (fm/grandline-dictation-phase2): the two pieces of local
// data phase 1 deliberately deferred - transcription history and a personal
// vocabulary list. This is Grand Line's own data, never a read of
// OpenSuperWhisper's `recordings.sqlite` - that integration was explicitly
// rejected during plan discussion (see `DictationEngine.swift`'s header).
//
// `DictationStore` follows `HostStore.swift`'s exact shape: an in-memory
// array backed by a JSON file via `Codable`+`JSONEncoder`/`JSONDecoder`, CRUD
// that persists on every mutation, not thread-safe by design (driven from the
// main thread only). Two sibling files under one directory rather than one
// combined file - history and vocabulary are edited independently and there's
// no reason a vocabulary edit should ever rewrite the (potentially much
// larger) history file or vice versa.

import Foundation

/// One completed dictation - recorded only for a real, successful transcript
/// that was actually pasted (never an empty/"didn't catch that" result, see
/// `DictationEngine.finish(text:)`).
struct DictationHistoryEntry: Codable, Equatable, Identifiable {
    let id: UUID
    var date: Date
    var durationSeconds: Double
    var text: String

    init(id: UUID = UUID(), date: Date, durationSeconds: Double, text: String) {
        self.id = id
        self.date = date
        self.durationSeconds = durationSeconds
        self.text = text
    }
}

/// The whole data layer for Dictation's history + vocabulary, mirroring
/// `HostStore`'s "load once, persist on every mutation" shape. Owned once by
/// the app delegate (`AppDelegate.dictationStore`, same convention as
/// `hostStore`/`shiftStore`) and shared by `DictationEngine` (reads
/// vocabulary, writes history) and `DictationController` (reads/edits both).
final class DictationStore {
    private(set) var history: [DictationHistoryEntry] = []
    private(set) var vocabulary: [String] = []

    /// Backup paths written by `load*()` when a file existed but would not
    /// decode (GL-01) - one per file, so a run that hits both is visible.
    private(set) var loadFailureBackupPaths: [String] = []

    /// Fired after any mutation to either list - `DictationController`
    /// observes while visible, matching `HostStore.observe`'s "list of
    /// closures" shape (not a single overwritable `onChange`) in case a
    /// future caller needs to hear it too.
    private var changeHandlers: [() -> Void] = []
    func observe(_ handler: @escaping () -> Void) { changeHandlers.append(handler) }

    private let historyURL: URL
    private let vocabularyURL: URL

    init() {
        let dir = DictationStore.directoryURL()
        historyURL = dir.appendingPathComponent("history.json")
        vocabularyURL = dir.appendingPathComponent("vocabulary.json")
        loadHistory()
        loadVocabulary()
    }

    /// `~/Library/Application Support/FirstmateCockpit/dictation/`,
    /// overridable via `FM_DICTATION_DIR` - the same `FM_*_DIR`/`FM_*_FILE`
    /// env-var convention `HostStore`/`SSHKeyStore`/`ShiftStore` already
    /// established, so tests/verification can point this at a scratch
    /// directory without touching the captain's real data.
    private static func directoryURL() -> URL {
        if let override = ProcessInfo.processInfo.environment["FM_DICTATION_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("FirstmateCockpit", isDirectory: true)
            .appendingPathComponent("dictation", isDirectory: true)
    }

    // MARK: History

    /// GL-35: the retained-history cap.
    ///
    /// The whole file is rewritten on every dictation, so an uncapped history
    /// makes each dictation slower than the last, forever, for data nobody
    /// scrolls back to - and it is the captain's own spoken text, which is the
    /// last thing that should accumulate unbounded on disk by default. 500 is
    /// far more than the page's list is ever scrolled through and still keeps
    /// the rewrite trivial.
    static let historyLimit = 500

    /// Called by `DictationEngine.onTranscript` right after a real paste -
    /// newest entry first, matching the page's "most recent first" display.
    func recordHistory(text: String, durationSeconds: Double, date: Date) {
        history.insert(DictationHistoryEntry(date: date, durationSeconds: durationSeconds, text: text), at: 0)
        if history.count > Self.historyLimit {
            history.removeLast(history.count - Self.historyLimit)
        }
        persistHistory()
    }

    /// GL-33: put a just-deleted entry back where it was, not at the top -
    /// `recordHistory` is for a *new* dictation and always inserts newest-
    /// first, which would silently reorder the list on undo.
    func restoreHistoryEntry(_ entry: DictationHistoryEntry) {
        guard !history.contains(where: { $0.date == entry.date && $0.text == entry.text }) else { return }
        let index = history.firstIndex { $0.date < entry.date } ?? history.count
        history.insert(entry, at: index)
        if history.count > Self.historyLimit {
            history.removeLast(history.count - Self.historyLimit)
        }
        persistHistory()
    }

    /// GL-35's other half: one entry, removed. "Clear everything" was the only
    /// way to get rid of a single mis-transcribed line before this.
    /// Identified by date + text rather than an index, so a list that has been
    /// re-read since the row was drawn cannot delete the wrong row.
    func removeHistoryEntry(date: Date, text: String) {
        let before = history.count
        history.removeAll { $0.date == date && $0.text == text }
        guard history.count != before else { return }
        persistHistory()
    }

    func clearHistory() {
        history.removeAll()
        persistHistory()
    }

    // MARK: Vocabulary

    /// No-op (not persisted, no duplicate) for an already-present word,
    /// case-insensitively - the chip row has nothing to show for adding the
    /// same phrase twice.
    func addVocabularyWord(_ word: String) {
        let trimmed = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard !vocabulary.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) else { return }
        vocabulary.append(trimmed)
        persistVocabulary()
    }

    func removeVocabularyWord(_ word: String) {
        vocabulary.removeAll { $0 == word }
        persistVocabulary()
    }

    // MARK: Disk

    private static let dateFormatEncoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private static let dateFormatDecoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    /// GL-01: both loads back an undecodable file up before the very next
    /// dictation (history) or vocabulary edit atomically overwrites it - see
    /// `StoreLoadFailure`'s header. Without this a single unreadable
    /// `history.json` was silently replaced by a one-entry file.
    private func loadHistory() {
        var backup: String?
        history = StoreLoadFailure.decodeJSON(
            [DictationHistoryEntry].self, at: historyURL,
            decoder: Self.dateFormatDecoder, label: "history.json", didBackUp: &backup
        ) ?? []
        if let backup { loadFailureBackupPaths.append(backup) }
        // GL-35: an already-oversized file (written before the cap existed) is
        // trimmed on load rather than only on the next dictation, so the very
        // first rewrite after upgrading is already the small one.
        if history.count > Self.historyLimit {
            history.removeLast(history.count - Self.historyLimit)
            persistHistory()
        }
    }

    private func loadVocabulary() {
        var backup: String?
        vocabulary = StoreLoadFailure.decodeJSON(
            [String].self, at: vocabularyURL, label: "vocabulary.json", didBackUp: &backup
        ) ?? []
        if let backup { loadFailureBackupPaths.append(backup) }
    }

    private func persistHistory() {
        persist(history, to: historyURL, encoder: Self.dateFormatEncoder)
    }

    private func persistVocabulary() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        persist(vocabulary, to: vocabularyURL, encoder: encoder)
    }

    private func persist<T: Encodable>(_ value: T, to url: URL, encoder: JSONEncoder) {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try encoder.encode(value)
            try data.write(to: url, options: .atomic)
        } catch {
            PersistenceFailureReporter.report(what: url.lastPathComponent == "vocabulary.json" ? "dictation vocabulary" : "dictation history", path: url.path, error: error)
        }
        changeHandlers.forEach { $0() }
    }
}

/// Shared "2 minutes ago"-style formatting for the history list - the one
/// place both the list rows and any future consumer should get this from,
/// rather than each hand-rolling a `DateComponentsFormatter`.
enum DictationRelativeTime {
    private static let formatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()

    static func string(from date: Date, relativeTo now: Date = Date()) -> String {
        formatter.localizedString(for: date, relativeTo: now)
    }

    /// "12s"/"1m 04s" - short enough to sit next to a relative timestamp in
    /// one row without crowding it.
    static func duration(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        let m = total / 60
        let s = total % 60
        return m > 0 ? String(format: "%dm %02ds", m, s) : String(format: "%ds", s)
    }
}
