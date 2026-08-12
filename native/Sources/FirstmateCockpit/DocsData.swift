// Manjesh Grand Line - native macOS app.
//
// The Docs destination's data side: syncing a bundled, offline copy of the
// captain's DevOps Playbook (a real interactive site - canvas diagrams, tab
// switchers, local-storage reading progress - that needs `WKWebView` to
// render faithfully; see `DocsController.swift`). The captain explicitly does
// not want a live network dependency for this destination, so the site is
// synced on demand (from the Updates page, exactly like any other row in
// `UpdatesData.swift`) into a local folder rather than loaded from the
// network every time it's viewed.
//
// `DocsStore` owns where the synced copy lives; `DocsSyncSource` owns the
// GitHub REST calls that check/update it, following the same `CheckOutcome`/
// `UpdateOutcome` contract every other `UpdatesSource` check/update function
// already returns. `DocsSyncCenter` is a tiny pub-sub (mirrors `ThemeManager.
// observe`'s shape) so `DocsController` can refresh its `WKWebView` right
// after a sync completes, without `UpdatesController` needing to know
// `DocsController` exists.

import Foundation

// MARK: - Where the synced copy lives

enum DocsStore {
    /// `~/Library/Application Support/FirstmateCockpit/docs/`, overridable via
    /// `FM_DOCS_DIR` - same convention as `HostStore.storeURL`/`SSHKeyStore`.
    /// Deliberately NOT inside the `.app` bundle: this CLT-only SPM
    /// executable target's `Bundle.module` resource-bundling is unreliable
    /// (see `CaptainIcon.swift`'s file header) and this content changes at
    /// runtime anyway, which a bundle resource can't do.
    static let folderURL: URL = {
        if let override = ProcessInfo.processInfo.environment["FM_DOCS_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath, isDirectory: true)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("FirstmateCockpit", isDirectory: true)
            .appendingPathComponent("docs", isDirectory: true)
    }()

    static var indexURL: URL { folderURL.appendingPathComponent("index.html") }
    private static var syncedCommitURL: URL { folderURL.appendingPathComponent(".synced-commit") }

    static var isSynced: Bool {
        FileManager.default.fileExists(atPath: indexURL.path)
    }

    static func syncedCommit() -> String? {
        guard let raw = try? String(contentsOf: syncedCommitURL, encoding: .utf8) else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

// MARK: - "Synced" pub-sub

/// `DocsController` observes this to refresh its `WKWebView` the moment a
/// sync completes (from the Updates page's row, or from the Docs page's own
/// empty-state button) - mirrors `ThemeManager.observe`'s "list of closures,
/// not one overwritable callback" shape, though in practice there is only
/// ever one Docs page to notify.
enum DocsSyncCenter {
    private static var observers: [() -> Void] = []

    static func observe(_ handler: @escaping () -> Void) {
        observers.append(handler)
    }

    /// Always fires on the main thread - `DocsSyncSource.update()` runs on a
    /// background queue (same as every other `UpdatesSource` check/update),
    /// but the observer's job is to touch a `WKWebView`, which is main-thread only.
    static func notifySynced() {
        DispatchQueue.main.async {
            observers.forEach { $0() }
        }
    }
}

// MARK: - GitHub sync

/// Checks/updates the bundled DevOps Playbook copy by comparing commit SHAs
/// against the live repo - the same "check compares a real signal, update
/// runs the real thing, never fabricated" contract every other row in
/// `UpdatesData.swift` follows. The repo is public, so the GitHub REST API
/// works fine unauthenticated (only a `User-Agent` header is required, or a
/// 403), but an unauthenticated request shares GitHub's 60/hour-per-IP quota
/// with every other unauthenticated caller on the machine - `get(_:)`/
/// `downloadBytes(from:)` opportunistically add a `gh auth token` bearer
/// token (via `ghAuthToken()` below) when one is available, bumping the
/// effective limit to 5,000/hour tied to that account, and fall back to the
/// exact same unauthenticated request when it isn't.
enum DocsSyncSource {
    /// The one hardcoded pointer to the captain's real playbook repo - update
    /// here (and nowhere else) if it ever moves, mirroring `DotfilesSource.cloneURL`.
    private static let owner = "manjesh-raj"
    private static let repo = "devops-playbook"
    private static let branch = "main"

    static func check() -> CheckOutcome {
        guard let latestSha = fetchLatestCommitSha() else {
            return CheckOutcome(
                installedLabel: DocsStore.isSynced ? shortSha(DocsStore.syncedCommit()) : "not synced",
                latestLabel: nil, status: .checkFailed,
                detail: "Could not reach GitHub to check \(owner)/\(repo)", log: ""
            )
        }
        guard let syncedSha = DocsStore.syncedCommit(), DocsStore.isSynced else {
            return CheckOutcome(
                installedLabel: "not synced", latestLabel: shortSha(latestSha), status: .notInstalled,
                detail: "Not synced yet - \(shortSha(latestSha)) available", log: ""
            )
        }
        if syncedSha == latestSha {
            return CheckOutcome(installedLabel: shortSha(syncedSha), latestLabel: shortSha(latestSha), status: .upToDate, detail: "\(shortSha(syncedSha)) - up to date", log: "")
        }
        return CheckOutcome(installedLabel: shortSha(syncedSha), latestLabel: shortSha(latestSha), status: .updateAvailable, detail: "\(shortSha(syncedSha)) \u{2192} \(shortSha(latestSha))", log: "")
    }

    /// Downloads the repo root's current file listing (so new/removed pages
    /// are picked up automatically, not a hardcoded file list), writes every
    /// file into a fresh temp directory, then atomically swaps it into place
    /// over the old `docs/` folder via `FileManager.replaceItemAt` - so a
    /// `WKWebView` reload racing this never sees a half-written sync.
    static func update() -> UpdateOutcome {
        guard let latestSha = fetchLatestCommitSha() else {
            return UpdateOutcome(ok: false, newVersionLabel: nil, detail: "Could not reach GitHub to fetch the latest commit", log: "")
        }
        guard let entries = fetchRootContents() else {
            return UpdateOutcome(ok: false, newVersionLabel: nil, detail: "Could not list the \(owner)/\(repo) repo contents", log: "")
        }
        let files = entries.filter { $0.type == "file" && $0.downloadURL != nil }
        guard !files.isEmpty else {
            return UpdateOutcome(ok: false, newVersionLabel: nil, detail: "The repo root has no downloadable files", log: "")
        }

        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("fm-docs-sync-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        } catch {
            return UpdateOutcome(ok: false, newVersionLabel: nil, detail: "Could not create a temp directory for the sync", log: error.localizedDescription)
        }

        var failures: [String] = []
        for file in files {
            guard let downloadURL = file.downloadURL, let url = URL(string: downloadURL),
                  let data = downloadBytes(from: url) else {
                failures.append(file.name)
                continue
            }
            do {
                try data.write(to: tempDir.appendingPathComponent(file.name))
            } catch {
                failures.append(file.name)
            }
        }
        guard failures.isEmpty else {
            try? FileManager.default.removeItem(at: tempDir)
            return UpdateOutcome(ok: false, newVersionLabel: nil, detail: "Failed to download: \(failures.joined(separator: ", "))", log: "")
        }
        do {
            try latestSha.write(to: tempDir.appendingPathComponent(".synced-commit"), atomically: true, encoding: .utf8)
        } catch {
            try? FileManager.default.removeItem(at: tempDir)
            return UpdateOutcome(ok: false, newVersionLabel: nil, detail: "Could not record the synced commit", log: error.localizedDescription)
        }

        do {
            try FileManager.default.createDirectory(at: DocsStore.folderURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: DocsStore.folderURL.path) {
                _ = try FileManager.default.replaceItemAt(DocsStore.folderURL, withItemAt: tempDir)
            } else {
                try FileManager.default.moveItem(at: tempDir, to: DocsStore.folderURL)
            }
        } catch {
            try? FileManager.default.removeItem(at: tempDir)
            return UpdateOutcome(ok: false, newVersionLabel: nil, detail: "Could not swap the synced folder into place", log: error.localizedDescription)
        }

        DocsSyncCenter.notifySynced()
        return UpdateOutcome(ok: true, newVersionLabel: shortSha(latestSha), detail: "Synced \(files.count) file(s) at \(shortSha(latestSha))", log: "")
    }

    private static func shortSha(_ sha: String?) -> String {
        guard let sha else { return "\u{2014}" }
        return String(sha.prefix(7))
    }

    // MARK: GitHub REST plumbing

    /// Runs `gh auth token` fresh (mirrors `UpdatesData.swift`'s `Process`-based
    /// shell-out convention, not a new networking abstraction) and returns its
    /// trimmed stdout, or `nil` if `gh` isn't on PATH, isn't authenticated, or
    /// the command fails for any reason - never throws. Called fresh per
    /// request rather than cached, since `gh auth token` is already fast and
    /// this avoids ever holding a stale/revoked token. The repo is public, so
    /// this is purely a rate-limit improvement (60/hr shared-by-IP anonymous
    /// vs. 5,000/hr per-account) over the unauthenticated fallback below, not
    /// a requirement - `nil` here just means "send the request as before."
    /// Not `private` - `GitHubBackupSource` (`BackupGitHub.swift`) reuses this
    /// verbatim for its own Contents API calls rather than inventing a second
    /// `gh auth token` shell-out.
    static func ghAuthToken() -> String? {
        guard let ghPath = {
            let fm = FileManager.default
            if let path = ProcessInfo.processInfo.environment["PATH"] {
                for dir in path.split(separator: ":") {
                    let candidate = "\(dir)/gh"
                    if fm.isExecutableFile(atPath: candidate) { return candidate }
                }
            }
            for candidate in ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/usr/bin/gh"] {
                if fm.isExecutableFile(atPath: candidate) { return candidate }
            }
            return nil
        }() else { return nil }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: ghPath)
        proc.arguments = ["auth", "token"]
        proc.environment = childEnvironmentDict()
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = Pipe()
        do {
            try proc.run()
        } catch {
            return nil
        }
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else { return nil }
        let token = String(data: outData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (token?.isEmpty ?? true) ? nil : token
    }

    private static func applyAuth(to request: inout URLRequest) {
        if let token = ghAuthToken() {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
    }

    private struct CommitResponse: Decodable { let sha: String }

    private struct ContentEntry: Decodable {
        let name: String
        let type: String
        let downloadURL: String?

        enum CodingKeys: String, CodingKey {
            case name, type
            case downloadURL = "download_url"
        }
    }

    private static func fetchLatestCommitSha() -> String? {
        guard let url = URL(string: "https://api.github.com/repos/\(owner)/\(repo)/commits/\(branch)") else { return nil }
        guard let data = get(url) else { return nil }
        return try? JSONDecoder().decode(CommitResponse.self, from: data).sha
    }

    private static func fetchRootContents() -> [ContentEntry]? {
        guard let url = URL(string: "https://api.github.com/repos/\(owner)/\(repo)/contents/") else { return nil }
        guard let data = get(url) else { return nil }
        return try? JSONDecoder().decode([ContentEntry].self, from: data)
    }

    /// A synchronous GET via a semaphore - this file's `check`/`update` are
    /// always dispatched to a background queue by `UpdatesController`/
    /// `DocsController` (matching every other `UpdatesSource` call), so
    /// blocking here doesn't stall the main thread, mirroring how
    /// `UpdatesData.swift`'s `run()` blocks on `Process.waitUntilExit()`.
    private static func get(_ url: URL) -> Data? {
        var request = URLRequest(url: url)
        request.setValue("FirstmateCockpit", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15
        applyAuth(to: &request)
        return syncFetch(request)
    }

    private static func downloadBytes(from url: URL) -> Data? {
        var request = URLRequest(url: url)
        request.setValue("FirstmateCockpit", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 30
        applyAuth(to: &request)
        return syncFetch(request)
    }

    private static func syncFetch(_ request: URLRequest) -> Data? {
        let semaphore = DispatchSemaphore(value: 0)
        var result: Data?
        let task = URLSession.shared.dataTask(with: request) { data, response, _ in
            if let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) {
                result = data
            }
            semaphore.signal()
        }
        task.resume()
        semaphore.wait()
        return result
    }
}
