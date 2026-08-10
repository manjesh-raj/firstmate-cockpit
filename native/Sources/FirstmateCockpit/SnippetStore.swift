// Manjesh Grand Line - native macOS app.
//
// Snippet persistence. Mirrors `HostStore`/`SSHKeyStore` exactly: an in-memory
// `[Snippet]` backed by a JSON file, CRUD that persists on every mutation,
// not thread-safe by design (main-thread/UI only). Nothing here is secret, so
// - unlike the key store - there is no Keychain half to keep in sync.

import Foundation

final class SnippetStore {

    private(set) var snippets: [Snippet] = []

    /// Fired after any mutation so the snippets list can reload.
    var onChange: (() -> Void)?

    private let fileURL: URL

    init() {
        fileURL = SnippetStore.storeURL()
        load()
    }

    // MARK: Location

    /// `~/Library/Application Support/FirstmateCockpit/snippets.json`,
    /// overridable via `FM_SNIPPETS_FILE` (handy for tests / a scratch set).
    private static func storeURL() -> URL {
        if let override = ProcessInfo.processInfo.environment["FM_SNIPPETS_FILE"], !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("FirstmateCockpit", isDirectory: true)
            .appendingPathComponent("snippets.json")
    }

    // MARK: CRUD

    func add(_ snippet: Snippet) {
        snippets.append(snippet)
        persist()
    }

    /// Replace the snippet with the same id in place (keeps ordering).
    func update(_ snippet: Snippet) {
        guard let idx = snippets.firstIndex(where: { $0.id == snippet.id }) else {
            add(snippet)
            return
        }
        snippets[idx] = snippet
        persist()
    }

    func delete(id: UUID) {
        snippets.removeAll { $0.id == id }
        persist()
    }

    func snippet(id: UUID) -> Snippet? {
        snippets.first { $0.id == id }
    }

    // MARK: Disk

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else {
            snippets = []
            return
        }
        snippets = (try? JSONDecoder().decode([Snippet].self, from: data)) ?? []
    }

    private func persist() {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(snippets)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            NSLog("[cockpit] failed to persist snippets: \(error.localizedDescription)")
        }
        onChange?()
    }
}
