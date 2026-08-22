// Manjesh Grand Line - native macOS app.
//
// SSH key metadata persistence. Mirrors `HostStore` exactly: an in-memory
// `[SSHKey]` backed by a JSON file, CRUD that persists on every mutation, not
// thread-safe by design (main-thread/UI only).
//
// This file only ever touches non-secret metadata - see `SSHKey`'s doc comment.
// `delete(id:)` also removes the matching Keychain items so a deleted key
// never leaves orphaned secret material behind.

import Foundation

final class SSHKeyStore {

    private(set) var keys: [SSHKey] = []

    /// Set when `load()` found a `keys.json` it could not decode and copied it
    /// aside - mirrors `HostStore.loadFailureBackupPath` so the app delegate
    /// can warn about this the same way it already warns about hosts.
    private(set) var loadFailureBackupPath: String?

    /// Fired after any mutation so the keys list can reload.
    var onChange: (() -> Void)?

    private let fileURL: URL

    init() {
        fileURL = SSHKeyStore.storeURL()
        load()
    }

    // MARK: Location

    /// `~/Library/Application Support/FirstmateCockpit/keys.json`, overridable
    /// via `FM_KEYS_FILE` (handy for tests / a scratch key set).
    private static func storeURL() -> URL {
        if let override = ProcessInfo.processInfo.environment["FM_KEYS_FILE"], !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("FirstmateCockpit", isDirectory: true)
            .appendingPathComponent("keys.json")
    }

    // MARK: CRUD

    func add(_ key: SSHKey) {
        keys.append(key)
        persist()
    }

    /// Create a brand-new key: write its Keychain secrets *before* adding the
    /// metadata to this store, so a Keychain failure never leaves a key
    /// listed with no secret behind it. Shared by the Keys screen
    /// (`KeysSidebarController`) and the host editor's inline "+ New Key…"
    /// (Fix 5), so both go through the same save order.
    func addNew(_ key: SSHKey, privateKeyData: Data, passphrase: String?) throws {
        try KeychainKeyStore.savePrivateKey(id: key.id, data: privateKeyData)
        if let passphrase {
            try KeychainKeyStore.savePassphrase(id: key.id, passphrase: passphrase)
        }
        add(key)
    }

    /// Replace the key with the same id in place (keeps ordering).
    func update(_ key: SSHKey) {
        guard let idx = keys.firstIndex(where: { $0.id == key.id }) else {
            add(key)
            return
        }
        keys[idx] = key
        persist()
    }

    /// Remove the saved metadata **and** its Keychain items (private key blob
    /// and passphrase, if any) - a deleted key should leave nothing behind.
    func delete(id: UUID) {
        keys.removeAll { $0.id == id }
        KeychainKeyStore.delete(id: id)
        persist()
    }

    func key(id: UUID) -> SSHKey? {
        keys.first { $0.id == id }
    }

    // MARK: Disk

    /// GL-01: an undecodable `keys.json` is backed up *before* the next
    /// `persist()` can atomically overwrite it. This matters more here than
    /// in any other store: losing key metadata does not just lose a list, it
    /// orphans the Keychain private-key blobs those entries pointed at, and
    /// `delete(id:)` can no longer clean them up because it no longer knows
    /// their ids exist.
    private func load() {
        var backup: String?
        keys = StoreLoadFailure.decodeJSON(
            [SSHKey].self, at: fileURL, label: "keys.json", didBackUp: &backup
        ) ?? []
        loadFailureBackupPath = backup
    }

    private func persist() {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(keys)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            PersistenceFailureReporter.report(what: "SSH key metadata", path: fileURL.path, error: error)
        }
        onChange?()
    }
}
