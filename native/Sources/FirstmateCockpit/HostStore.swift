// Manjesh Grand Line - native macOS app.
//
// Host persistence. The native app had **zero** persistence before Phase 1
// (config was env-var only, design report A2), so this is the first on-disk
// store: a small JSON file of saved `Host` profiles under Application Support.
//
// Secrets never land here - `Host`'s `password` is excluded from `Codable`, and
// the only credential persisted is an on-disk key *path*. Phase 2 replaces that
// with a Keychain / Secure Enclave key store.

import Foundation

/// The saved-hosts store: an in-memory `[Host]` backed by a JSON file, with CRUD
/// that persists on every mutation. Not thread-safe by design - it is driven from
/// the main thread (the UI) only.
final class HostStore {

    private(set) var hosts: [Host] = []

    /// Set once, at `load()`, if `hosts.json` existed but couldn't be read as
    /// valid JSON - the file itself has already been backed up aside by then
    /// (see `load()`), but the in-memory list is empty either way, and
    /// nothing else here can tell "genuinely nothing saved yet" apart from
    /// "a corrupted file was just discarded" without this. A caller (e.g.
    /// `AppDelegate`) should surface this once, then it plays no further role -
    /// it is not cleared on a later successful `persist()`.
    private(set) var loadFailureBackupPath: String?

    /// Fired after any mutation - the Hosts sidebar and the rail's per-host
    /// icons (Fix 3, fixes4) both need to hear about every add/rename/delete,
    /// so this is a list of observers rather than a single overwritable
    /// closure (matching `ThemeManager.observe`'s shape).
    private var changeHandlers: [() -> Void] = []

    func observe(_ handler: @escaping () -> Void) {
        changeHandlers.append(handler)
    }

    private let fileURL: URL

    init() {
        fileURL = HostStore.storeURL()
        load()
    }

    // MARK: Location

    /// `~/Library/Application Support/FirstmateCockpit/hosts.json`, overridable
    /// via `FM_HOSTS_FILE` (handy for tests / a scratch profile set).
    private static func storeURL() -> URL {
        if let override = ProcessInfo.processInfo.environment["FM_HOSTS_FILE"], !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("FirstmateCockpit", isDirectory: true)
            .appendingPathComponent("hosts.json")
    }

    // MARK: CRUD

    func add(_ host: Host) {
        hosts.append(host)
        persist()
    }

    /// Replace the host with the same id in place (keeps ordering).
    func update(_ host: Host) {
        guard let idx = hosts.firstIndex(where: { $0.id == host.id }) else {
            add(host)
            return
        }
        hosts[idx] = host
        persist()
    }

    func delete(id: UUID) {
        hosts.removeAll { $0.id == id }
        persist()
    }

    func host(id: UUID) -> Host? {
        hosts.first { $0.id == id }
    }

    // MARK: Disk

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else {
            hosts = []
            return
        }
        if let decoded = try? JSONDecoder().decode([Host].self, from: data) {
            hosts = decoded
            return
        }
        // The file exists but isn't valid `[Host]` JSON - back it up before
        // proceeding with an empty list, so the very next `persist()` (the
        // first host add/edit/delete) doesn't atomically overwrite it and
        // permanently discard whatever was actually in there.
        hosts = []
        let backupURL = fileURL.deletingLastPathComponent()
            .appendingPathComponent("hosts.json.corrupt-\(Int(Date().timeIntervalSince1970))")
        do {
            try FileManager.default.copyItem(at: fileURL, to: backupURL)
            loadFailureBackupPath = backupURL.path
            NSLog("[cockpit] hosts.json failed to decode - backed up to \(backupURL.path)")
        } catch {
            NSLog("[cockpit] hosts.json failed to decode AND could not be backed up: \(error.localizedDescription)")
        }
    }

    private func persist() {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(hosts)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            NSLog("[cockpit] failed to persist hosts: \(error.localizedDescription)")
        }
        changeHandlers.forEach { $0() }
    }
}
