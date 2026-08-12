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
//     directory, the active theme id, terminal font size, and the three
//     terminal-behavior toggles (auto-reconnect, needs-decision
//     notifications, session-logging-by-default). Everything else backed by
//     `UserDefaults` in this app (there is nothing else today) is
//     deliberately left out - only fields that are genuinely "this
//     captain's preferences," not machine-local state like `fmHome` (Firstmate
//     home is already its own explicit Bootstrap step, resolved per machine).
//
// `formatVersion` exists so a bundle from a future, incompatible version of
// this file can be detected and refused rather than silently misdecoded.

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

    init(hosts: [Host], snippets: [Snippet], keys: [SSHKey], settings: BackupSettings) {
        self.formatVersion = Self.currentFormatVersion
        self.hosts = hosts
        self.snippets = snippets
        self.keys = keys
        self.settings = settings
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
    var sessionLoggingDefault: Bool?

    static func fromCurrent() -> BackupSettings {
        let s = AppSettings.shared
        return BackupSettings(
            mirrorTarget: s.mirrorTarget,
            defaultShellCwd: s.defaultShellCwd,
            themeID: ThemeManager.shared.theme.id,
            fontSize: Double(s.fontSize),
            autoReconnect: s.autoReconnect,
            notifyOnNeedsDecision: s.notifyOnNeedsDecision,
            sessionLoggingDefault: s.sessionLoggingDefault
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
        if let sessionLoggingDefault { s.sessionLoggingDefault = sessionLoggingDefault }
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
        if sessionLoggingDefault != nil { bits.append("session logging") }
        return bits.isEmpty ? "no settings" : bits.joined(separator: ", ")
    }
}

enum GrandLineBackupBuilder {
    /// Builds a bundle from the live stores - only the `SSHKey` metadata
    /// referenced by at least one host is included, never the whole key list.
    static func build(hosts: [Host], snippets: [Snippet], allKeys: [SSHKey]) -> GrandLineBackup {
        let referencedKeyIDs = Set(hosts.compactMap { $0.keyID })
        let keys = allKeys.filter { referencedKeyIDs.contains($0.id) }
        return GrandLineBackup(hosts: hosts, snippets: snippets, keys: keys, settings: .fromCurrent())
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

enum BackupImport {
    struct Preview {
        var hostRows: [BackupHostDiffRow]
        var snippetRows: [BackupSnippetDiffRow]
        /// One line per bundled host whose `keyID` isn't a key this machine
        /// already has - see this file's header on why the bundle's key
        /// metadata is never written back into `SSHKeyStore` itself.
        var keyWarnings: [String]
        var settingsSummary: String

        var newHostsCount: Int { hostRows.filter { $0.status == .new }.count }
        var changedHostsCount: Int { hostRows.filter { $0.status == .changed }.count }
        var unchangedHostsCount: Int { hostRows.filter { $0.status == .unchanged }.count }
        var newSnippetsCount: Int { snippetRows.filter { $0.status == .new }.count }
        var changedSnippetsCount: Int { snippetRows.filter { $0.status == .changed }.count }
        var unchangedSnippetsCount: Int { snippetRows.filter { $0.status == .unchanged }.count }
    }

    /// A real comparison against the machine's current state - never a
    /// hardcoded description. Matches a bundled item to an existing one by
    /// id first (the common case: re-importing a bundle exported from this
    /// same host set), then falls back to a case-insensitive label match (a
    /// host/snippet recreated with a new id since the export still counts as
    /// "the same thing, possibly changed" rather than a duplicate).
    static func diff(bundle: GrandLineBackup, existingHosts: [Host], existingSnippets: [Snippet], existingKeys: [SSHKey]) -> Preview {
        var hostRows: [BackupHostDiffRow] = []
        for bundleHost in bundle.hosts {
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

        return Preview(hostRows: hostRows, snippetRows: snippetRows, keyWarnings: keyWarnings, settingsSummary: bundle.settings.summary)
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
    static func apply(_ preview: Preview, bundle: GrandLineBackup, hostStore: HostStore, snippetStore: SnippetStore) {
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
    }
}
