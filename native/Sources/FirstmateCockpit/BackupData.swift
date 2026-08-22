// Manjesh Grand Line - native macOS app.
//
// Portable local state (fm/cockpit-local-state-portable): this app's own
// on-disk state - saved hosts, snippets, and a deliberate subset of
// `AppSettings` - has no equivalent of the dotfiles card's "sync this machine
// from a real repo" story. This file is the model half: a single JSON bundle
// format (`GrandLineBackup`), the diff used to preview an import before
// anything is written, and the apply step. `BackupUI.swift` is the AppKit
// half (panels, the diff preview alert, wiring shared by Settings and
// Bootstrap).
//
// What's in the bundle and why:
//   - The full contents of `hosts.json` / `snippets.json` - nothing filtered,
//     since neither model carries a secret (`Host.password` is already
//     excluded from `Codable`, see `Host.swift`).
//   - Non-secret metadata only for every `SSHKey` a bundled host's `keyID`
//     references - never the Keychain-held private key bytes or passphrase,
//     which never leave `KeychainKeyStore` and never touch this file. This
//     is purely so an import can say "this host references key X" - it is
//     never written back into `SSHKeyStore` on import (a metadata-only
//     key entry with no secret behind it would be worse than the plain
//     "re-add this key" message this file's diff already produces).
//   - A named subset of `AppSettings`: mirror target, default working
//     directory, the active theme id, terminal font size, and the two
//     terminal-behavior toggles (auto-reconnect, needs-decision
//     notifications). Everything else backed by `UserDefaults` in this app
//     (there is nothing else today) is
//     deliberately left out - only fields that are genuinely "this
//     captain's preferences," not machine-local state like `fmHome` (Firstmate
//     home is already its own explicit Bootstrap step, resolved per machine).
//   - Dictation's personal vocabulary list and configured shortcut
//     (`DictationStore.vocabulary` / `AppSettings.dictationShortcut`, both
//     from `fm/grandline-dictation-phase2`) - the same "genuinely this
//     captain's own configuration, not machine-local state" bar the
//     `AppSettings` subset above already applies. Deliberately NOT
//     `DictationStore.history` - a transcript log is per-machine usage data
//     (what was actually said on that Mac), the same category of thing
//     `fmHome` already excludes, not portable configuration like a
//     vocabulary list or a shortcut choice.
//
// `formatVersion` exists so a bundle from a future, incompatible version of
// this file can be detected and refused rather than silently misdecoded.
// Adding or removing an *optional* field here never needs a version bump in
// either direction: an old-format bundle missing the key still decodes
// cleanly into `nil` via Swift's synthesized `Decodable` (an `Optional`-typed
// stored property is decoded with `decodeIfPresent`), and an old bundle
// carrying a key this file no longer declares is simply ignored, same as
// `JSONDecoder` already does for any unrecognized key. That last direction is
// why `fm/grandline-remove-session-logging` could drop
// `BackupSettings.sessionLoggingDefault` outright: a `.glbackup` exported by
// an earlier build still imports, its now-unknown key discarded rather than
// failing the decode.

import Foundation

// MARK: Bundle format

struct GrandLineBackup: Codable {
    static let currentFormatVersion = 1

    var formatVersion: Int
    var hosts: [Host]
    var snippets: [Snippet]
    /// Metadata only for keys referenced by `hosts` - see this file's header.
    var keys: [SSHKey]
    var settings: BackupSettings
    /// `nil` only when reading a bundle exported before this field existed -
    /// see this file's header on why that needs no format-version bump.
    var dictation: BackupDictation?

    init(hosts: [Host], snippets: [Snippet], keys: [SSHKey], settings: BackupSettings, dictation: BackupDictation? = nil) {
        self.formatVersion = Self.currentFormatVersion
        self.hosts = hosts
        self.snippets = snippets
        self.keys = keys
        self.settings = settings
        self.dictation = dictation
    }
}

/// The deliberate `AppSettings` subset this bundle carries - see this file's
/// header for which fields were included and why. Every field is optional so
/// a partially-populated or future-trimmed bundle still decodes.
struct BackupSettings: Codable {
    var mirrorTarget: String?
    var defaultShellCwd: String?
    var themeID: String?
    var fontSize: Double?
    var autoReconnect: Bool?
    var notifyOnNeedsDecision: Bool?

    static func fromCurrent() -> BackupSettings {
        let s = AppSettings.shared
        return BackupSettings(
            mirrorTarget: s.mirrorTarget,
            defaultShellCwd: s.defaultShellCwd,
            themeID: ThemeManager.shared.theme.id,
            fontSize: Double(s.fontSize),
            autoReconnect: s.autoReconnect,
            notifyOnNeedsDecision: s.notifyOnNeedsDecision
        )
    }

    /// Applied unconditionally on import confirm - the diff preview already
    /// showed the captain what this bundle carries before they confirmed.
    func apply() {
        let s = AppSettings.shared
        if let mirrorTarget { s.mirrorTarget = mirrorTarget }
        if let defaultShellCwd { s.defaultShellCwd = defaultShellCwd }
        if let themeID, let theme = HelmTheme.theme(id: themeID) { ThemeManager.shared.setTheme(theme) }
        if let fontSize { s.fontSize = CGFloat(fontSize) }
        if let autoReconnect { s.autoReconnect = autoReconnect }
        if let notifyOnNeedsDecision { s.notifyOnNeedsDecision = notifyOnNeedsDecision }
    }

    /// A one-line, non-hardcoded summary for the diff preview - lists only
    /// the fields this specific bundle actually carries, not every field the
    /// type could hold.
    var summary: String {
        var bits: [String] = []
        if mirrorTarget != nil { bits.append("mirror target") }
        if defaultShellCwd != nil { bits.append("working directory") }
        if themeID != nil { bits.append("theme") }
        if fontSize != nil { bits.append("font size") }
        if autoReconnect != nil { bits.append("auto-reconnect") }
        if notifyOnNeedsDecision != nil { bits.append("notifications") }
        return bits.isEmpty ? "no settings" : bits.joined(separator: ", ")
    }
}

/// Dictation's portable configuration - see this file's header for why this
/// is limited to the vocabulary list and shortcut, never `DictationStore.
/// history`. Both fields are optional so a bundle exported with an empty
/// vocabulary and the default shortcut still round-trips meaningfully.
struct BackupDictation: Codable {
    var vocabulary: [String]?
    var shortcut: DictationShortcut?

    static func fromCurrent(store: DictationStore) -> BackupDictation {
        BackupDictation(vocabulary: store.vocabulary, shortcut: AppSettings.shared.dictationShortcut)
    }

    /// Applied unconditionally on import confirm, same contract as
    /// `BackupSettings.apply()` - the diff preview already showed the
    /// captain what this bundle carries before they confirmed. Vocabulary
    /// words are added one at a time through `DictationStore`'s own
    /// case-insensitive-dedup path (`addVocabularyWord`), never a raw
    /// overwrite, so a captain's own already-added words survive an import
    /// untouched.
    func apply(to store: DictationStore) {
        for word in vocabulary ?? [] { store.addVocabularyWord(word) }
        if let shortcut { AppSettings.shared.dictationShortcut = shortcut }
    }

    /// A one-line, non-hardcoded summary for the diff preview, matching
    /// `BackupSettings.summary`'s own shape.
    var summary: String {
        var bits: [String] = []
        if let vocabulary, !vocabulary.isEmpty {
            bits.append("\(vocabulary.count) vocabulary word\(vocabulary.count == 1 ? "" : "s")")
        }
        if let shortcut { bits.append("shortcut (\(shortcut.displayString))") }
        return bits.isEmpty ? "no dictation settings" : bits.joined(separator: ", ")
    }
}

enum GrandLineBackupBuilder {
    /// Builds a bundle from the live stores - only the `SSHKey` metadata
    /// referenced by at least one host is included, never the whole key list.
    static func build(hosts: [Host], snippets: [Snippet], allKeys: [SSHKey], dictationStore: DictationStore) -> GrandLineBackup {
        let referencedKeyIDs = Set(hosts.compactMap { $0.keyID })
        let keys = allKeys.filter { referencedKeyIDs.contains($0.id) }
        return GrandLineBackup(hosts: hosts, snippets: snippets, keys: keys, settings: .fromCurrent(), dictation: .fromCurrent(store: dictationStore))
    }
}

enum BackupError: LocalizedError {
    case invalidFile
    case unsupportedFormatVersion(Int)

    var errorDescription: String? {
        switch self {
        case .invalidFile:
            return "This file isn't a valid Grand Line backup."
        case .unsupportedFormatVersion(let v):
            return "This backup file uses format version \(v), which this version of the app doesn't understand. Update the app and try again."
        }
    }
}

enum GrandLineBackupFile {
    static func encode(_ bundle: GrandLineBackup) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(bundle)
    }

    static func decode(_ data: Data) throws -> GrandLineBackup {
        let bundle: GrandLineBackup
        do {
            bundle = try JSONDecoder().decode(GrandLineBackup.self, from: data)
        } catch {
            throw BackupError.invalidFile
        }
        guard bundle.formatVersion <= GrandLineBackup.currentFormatVersion else {
            throw BackupError.unsupportedFormatVersion(bundle.formatVersion)
        }
        return bundle
    }
}

// MARK: Import diff

enum BackupDiffStatus: String {
    case new, changed, unchanged
}

struct BackupHostDiffRow {
    var label: String
    var status: BackupDiffStatus
    var bundleHost: Host
    /// The existing local host this bundle host matched (by id, then by
    /// label) - `nil` for `.new`.
    var matchedLocalID: UUID?
}

struct BackupSnippetDiffRow {
    var label: String
    var status: BackupDiffStatus
    var bundleSnippet: Snippet
    var matchedLocalID: UUID?
}

/// A single bundled vocabulary word - `.changed` is never produced here (a
/// word has no fields of its own to differ on, unlike a host/snippet), only
/// `.new`/`.unchanged`.
struct BackupVocabularyDiffRow {
    var word: String
    var status: BackupDiffStatus
}

enum BackupImport {
    struct Preview {
        var hostRows: [BackupHostDiffRow]
        var snippetRows: [BackupSnippetDiffRow]
        /// One line per bundled host whose `keyID` isn't a key this machine
        /// already has - see this file's header on why the bundle's key
        /// metadata is never written back into `SSHKeyStore` itself.
        var keyWarnings: [String]
        /// GL-08: one line per bundled host this import refused outright,
        /// because a field `ssh` would read as an option (a leading `-`) made
        /// it a code-execution vector rather than a host. These never appear in
        /// `hostRows`, so `apply` cannot write them - a rejected host is not a
        /// "changed" host the captain might approve past.
        var rejectedHostWarnings: [String] = []
        var settingsSummary: String
        var vocabularyRows: [BackupVocabularyDiffRow]
        /// `nil` when the bundle carries no shortcut at all (an old-format
        /// bundle, see `GrandLineBackup.dictation`'s doc comment); otherwise
        /// whether applying it would change what's currently configured.
        var shortcutStatus: BackupDiffStatus?
        var shortcutDisplay: String?

        var newHostsCount: Int { hostRows.filter { $0.status == .new }.count }
        var changedHostsCount: Int { hostRows.filter { $0.status == .changed }.count }
        var unchangedHostsCount: Int { hostRows.filter { $0.status == .unchanged }.count }
        var newSnippetsCount: Int { snippetRows.filter { $0.status == .new }.count }
        var changedSnippetsCount: Int { snippetRows.filter { $0.status == .changed }.count }
        var unchangedSnippetsCount: Int { snippetRows.filter { $0.status == .unchanged }.count }
        var newVocabularyCount: Int { vocabularyRows.filter { $0.status == .new }.count }
        var unchangedVocabularyCount: Int { vocabularyRows.filter { $0.status == .unchanged }.count }
    }

    /// A real comparison against the machine's current state - never a
    /// hardcoded description. Matches a bundled item to an existing one by
    /// id first (the common case: re-importing a bundle exported from this
    /// same host set), then falls back to a case-insensitive label match (a
    /// host/snippet recreated with a new id since the export still counts as
    /// "the same thing, possibly changed" rather than a duplicate).
    static func diff(bundle: GrandLineBackup, existingHosts: [Host], existingSnippets: [Snippet], existingKeys: [SSHKey], existingVocabulary: [String] = [], existingShortcut: DictationShortcut? = nil) -> Preview {
        var hostRows: [BackupHostDiffRow] = []
        var rejectedHostWarnings: [String] = []
        for bundleHost in bundle.hosts {
            // GL-08: this is the finding's realistic delivery vector - a
            // `.glbackup` restores hosts verbatim (including one fetched from
            // GitHub), so a tampered bundle could plant an address of
            // `-oProxyCommand=<cmd>` that executes locally on Connect. The
            // `--` terminator in `Host.sshArguments` already defuses it and
            // `HostEditorController` blocks typing one, but a bundle bypasses
            // the editor entirely - so a host that could never have been saved
            // by hand is refused here rather than stored and left to fail
            // confusingly later.
            let unsafe = bundleHost.unsafeFieldNames
            if !unsafe.isEmpty {
                let fields = unsafe.joined(separator: ", ")
                rejectedHostWarnings.append(
                    "\"\(bundleHost.label)\" was skipped: \(fields) starts with \u{201C}-\u{201D}, "
                    + "which `ssh` reads as a command-line option rather than a destination. "
                    + "This is not a valid host - re-add it by hand if you expected it here."
                )
                AppLog.store.error("backup import: refused host \"\(bundleHost.label, privacy: .public)\" - unsafe field(s): \(fields, privacy: .public) (GL-08)")
                continue
            }
            if let match = existingHosts.first(where: { $0.id == bundleHost.id })
                ?? existingHosts.first(where: { $0.label.caseInsensitiveCompare(bundleHost.label) == .orderedSame }) {
                let same = hostsEqualIgnoringIdentityAndSecrets(match, bundleHost)
                hostRows.append(BackupHostDiffRow(label: bundleHost.label, status: same ? .unchanged : .changed, bundleHost: bundleHost, matchedLocalID: match.id))
            } else {
                hostRows.append(BackupHostDiffRow(label: bundleHost.label, status: .new, bundleHost: bundleHost, matchedLocalID: nil))
            }
        }

        var snippetRows: [BackupSnippetDiffRow] = []
        for bundleSnippet in bundle.snippets {
            if let match = existingSnippets.first(where: { $0.id == bundleSnippet.id })
                ?? existingSnippets.first(where: { $0.label.caseInsensitiveCompare(bundleSnippet.label) == .orderedSame }) {
                let same = match.label == bundleSnippet.label && match.command == bundleSnippet.command
                snippetRows.append(BackupSnippetDiffRow(label: bundleSnippet.label, status: same ? .unchanged : .changed, bundleSnippet: bundleSnippet, matchedLocalID: match.id))
            } else {
                snippetRows.append(BackupSnippetDiffRow(label: bundleSnippet.label, status: .new, bundleSnippet: bundleSnippet, matchedLocalID: nil))
            }
        }

        let localKeyIDs = Set(existingKeys.map { $0.id })
        var keyWarnings: [String] = []
        for bundleHost in bundle.hosts {
            guard let keyID = bundleHost.keyID, !localKeyIDs.contains(keyID) else { continue }
            let meta = bundle.keys.first { $0.id == keyID }
            let keyDesc = meta.map { "\"\($0.label)\" (\($0.fingerprint))" } ?? "a key"
            keyWarnings.append("\"\(bundleHost.label)\" references \(keyDesc), which isn't on this machine - re-add it from the Keys screen before connecting.")
        }

        var vocabularyRows: [BackupVocabularyDiffRow] = []
        let existingVocabularyLower = Set(existingVocabulary.map { $0.lowercased() })
        for word in bundle.dictation?.vocabulary ?? [] {
            let status: BackupDiffStatus = existingVocabularyLower.contains(word.lowercased()) ? .unchanged : .new
            vocabularyRows.append(BackupVocabularyDiffRow(word: word, status: status))
        }

        var shortcutStatus: BackupDiffStatus?
        var shortcutDisplay: String?
        if let bundleShortcut = bundle.dictation?.shortcut {
            shortcutDisplay = bundleShortcut.displayString
            shortcutStatus = (bundleShortcut == existingShortcut) ? .unchanged : .changed
        }

        return Preview(
            hostRows: hostRows, snippetRows: snippetRows, keyWarnings: keyWarnings,
            rejectedHostWarnings: rejectedHostWarnings, settingsSummary: bundle.settings.summary,
            vocabularyRows: vocabularyRows, shortcutStatus: shortcutStatus, shortcutDisplay: shortcutDisplay
        )
    }

    /// Field-by-field comparison, deliberately skipping `id` (a rename-in-
    /// place still has the same id; a label-matched pair never will) and
    /// `password` (session-only, never persisted or bundled - see `Host`'s
    /// own doc comment).
    private static func hostsEqualIgnoringIdentityAndSecrets(_ a: Host, _ b: Host) -> Bool {
        a.label == b.label && a.address == b.address && a.port == b.port && a.username == b.username
            && a.keyID == b.keyID && a.iconSymbol == b.iconSymbol && a.accentHex == b.accentHex
            && a.group == b.group && a.tags == b.tags && a.agentForward == b.agentForward
            && a.jumpVia == b.jumpVia && a.portForwards == b.portForwards && a.startupSnippetID == b.startupSnippetID
    }

    /// Applies a previously computed diff. New items are added as-is;
    /// matched-but-changed items are written under the LOCAL id (never the
    /// bundle's), so anything already pointing at that host/snippet - a jump
    /// chain resolved by label, a startup-snippet reference by id - stays
    /// valid. Unchanged items are left untouched. The bundle's settings
    /// subset is always applied, since the diff preview already showed it
    /// before this was called.
    static func apply(_ preview: Preview, bundle: GrandLineBackup, hostStore: HostStore, snippetStore: SnippetStore, dictationStore: DictationStore? = nil) {
        for row in preview.hostRows {
            var host = row.bundleHost
            switch row.status {
            case .new:
                hostStore.add(host)
            case .changed:
                if let localID = row.matchedLocalID { host.id = localID }
                hostStore.update(host)
            case .unchanged:
                continue
            }
        }
        for row in preview.snippetRows {
            var snippet = row.bundleSnippet
            switch row.status {
            case .new:
                snippetStore.add(snippet)
            case .changed:
                if let localID = row.matchedLocalID { snippet.id = localID }
                snippetStore.update(snippet)
            case .unchanged:
                continue
            }
        }
        bundle.settings.apply()
        if let dictationStore {
            bundle.dictation?.apply(to: dictationStore)
        }
    }
}
