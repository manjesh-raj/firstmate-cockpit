// Firstmate Cockpit - native macOS app.
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

    /// Fired after any mutation so the sidebar can reload. Set by the UI.
    var onChange: (() -> Void)?

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
        hosts = (try? JSONDecoder().decode([Host].self, from: data)) ?? []
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
        onChange?()
    }
}
