// Manjesh Grand Line - native macOS app.
//
// GitHub as a second backup destination/source (follow-up to
// `fm/cockpit-local-state-portable`, PR #85), alongside the local
// `NSSavePanel`/`NSOpenPanel` flow in `BackupUI.swift`. There is exactly one
// bundle in GitHub at any time, at a fixed path - re-exporting overwrites it
// (Contents API create-or-update via its `sha` field), it never accumulates
// timestamped files - so import has nothing to list or pick, it just fetches
// that one fixed path.
//
// Auth reuses `DocsSyncSource.ghAuthToken()` (`DocsData.swift`) verbatim -
// this file introduces no second GitHub authentication mechanism. The
// destination repo is the same one `DotfilesSource.cloneURL` (`DotfilesData.
// swift`) already points at - parsed from that one constant rather than a
// second hardcoded owner/repo, so the two can never drift apart.

import Foundation

enum GitHubBackupSource {
    /// Parsed from `DotfilesSource.cloneURL`, not a second hardcoded copy -
    /// see this file's header.
    private static var ownerAndRepo: (owner: String, repo: String)? {
        guard let url = URL(string: DotfilesSource.cloneURL) else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }
        guard parts.count >= 2 else { return nil }
        return (parts[0], parts[1])
    }

    /// Fixed path - one bundle, always overwritten on export. See file header.
    private static let backupPath = "export-backup/grand-line-backup.glbackup"
    private static let branch = "main"

    /// A short, human-readable label for the destination/source picker -
    /// "GitHub (manjesh-config)" - built from the parsed repo name so it
    /// never drifts from `DotfilesSource.cloneURL` either.
    static var destinationLabel: String {
        "GitHub (\(ownerAndRepo?.repo ?? "unknown repo"))"
    }

    /// Whether the GitHub option should be selectable at all - `gh` installed
    /// and authenticated. Callers use this to visibly disable the option with
    /// an explanation rather than silently failing when a token isn't
    /// available, matching this app's existing guidance-only convention for a
    /// missing prerequisite (e.g. the gh-cli isotope row in "Not synced here,
    /// by design").
    static func isAvailable() -> Bool {
        DocsSyncSource.ghAuthToken() != nil
    }

    static var unavailableReason: String {
        "GitHub backup needs the `gh` CLI installed and authenticated (`gh auth login`)."
    }

    enum GitHubBackupError: LocalizedError {
        case notConfigured
        case notAuthenticated
        case requestFailed(String)

        var errorDescription: String? {
            switch self {
            case .notConfigured:
                return "Could not determine the GitHub repo from DotfilesSource.cloneURL."
            case .notAuthenticated:
                return GitHubBackupSource.unavailableReason
            case .requestFailed(let detail):
                return "GitHub request failed: \(detail)"
            }
        }
    }

    /// Create-or-update: reads the existing file's `sha` first (if any) so
    /// the Contents API PUT updates in place instead of erroring on an
    /// already-existing path - the same "one fixed file, always overwritten"
    /// contract as `DocsSyncSource.update()`'s atomic swap, just server-side.
    static func export(_ bundle: GrandLineBackup) throws {
        guard let (owner, repo) = ownerAndRepo else { throw GitHubBackupError.notConfigured }
        guard let token = DocsSyncSource.ghAuthToken() else { throw GitHubBackupError.notAuthenticated }
        guard let url = URL(string: "https://api.github.com/repos/\(owner)/\(repo)/contents/\(backupPath)") else {
            throw GitHubBackupError.notConfigured
        }

        let data = try GrandLineBackupFile.encode(bundle)
        let base64 = data.base64EncodedString()

        // One retry with a freshly re-fetched sha on a 409 - GitHub's Contents
        // API GET is cache-fronted and can momentarily lag a just-completed
        // write, so a `sha` read right before this PUT can already be stale if
        // another write to this same path landed seconds earlier (confirmed
        // live via a temporary probe: two `export()` calls a few seconds apart
        // hit exactly this). A real captain's exports are normally minutes to
        // days apart, so this is a narrow, rare race - one retry is enough
        // without adding a general backoff/retry framework this file doesn't
        // otherwise need.
        for attempt in 0..<2 {
            let existingSha = try? fetchSha(owner: owner, repo: repo, token: token)
            var body: [String: Any] = [
                "message": "Add Grand Line backup \(timestampLabel())",
                "content": base64,
                "branch": branch,
            ]
            if let existingSha {
                body["sha"] = existingSha
            }

            var request = URLRequest(url: url)
            request.httpMethod = "PUT"
            request.setValue("FirstmateCockpit", forHTTPHeaderField: "User-Agent")
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.timeoutInterval = 30

            let (status, _) = syncSend(request)
            if (200..<300).contains(status) { return }
            if status == 409 && attempt == 0 {
                // One retry with a freshly re-fetched sha - a real (if rare)
                // sha mismatch, e.g. two back-to-back exports, not the client-
                // cache issue `fetchSha`'s `.reloadIgnoringLocalAndRemoteCacheData`
                // already rules out.
                Thread.sleep(forTimeInterval: 1)
                continue
            }
            throw GitHubBackupError.requestFailed("HTTP \(status) writing \(backupPath)")
        }
    }

    /// Fetches and decodes the one fixed bundle - no listing, no picker (see
    /// file header on why there's only ever one file to fetch).
    static func fetchBundle() throws -> GrandLineBackup {
        guard let (owner, repo) = ownerAndRepo else { throw GitHubBackupError.notConfigured }
        guard let token = DocsSyncSource.ghAuthToken() else { throw GitHubBackupError.notAuthenticated }
        guard let url = URL(string: "https://api.github.com/repos/\(owner)/\(repo)/contents/\(backupPath)") else {
            throw GitHubBackupError.notConfigured
        }
        var request = URLRequest(url: url)
        request.setValue("FirstmateCockpit", forHTTPHeaderField: "User-Agent")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 30
        // A stale read here is worse than a slow one: this must always be the
        // real current sha/content, not whatever `URLSession.shared`'s
        // disk-backed `URLCache` - which persists across process launches, not
        // just within one run - happened to store from an earlier request to
        // this same URL. Confirmed live: a fresh process invocation still saw
        // a several-seconds-old sha without this.
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData

        let (status, data) = syncSend(request)
        guard (200..<300).contains(status), let data else {
            throw GitHubBackupError.requestFailed("HTTP \(status) reading \(backupPath)")
        }
        let entry = try JSONDecoder().decode(ContentFileResponse.self, from: data)
        guard let decoded = Data(base64Encoded: entry.content.replacingOccurrences(of: "\n", with: "")) else {
            throw BackupError.invalidFile
        }
        return try GrandLineBackupFile.decode(decoded)
    }

    private static func fetchSha(owner: String, repo: String, token: String) throws -> String? {
        guard let url = URL(string: "https://api.github.com/repos/\(owner)/\(repo)/contents/\(backupPath)") else { return nil }
        var request = URLRequest(url: url)
        request.setValue("FirstmateCockpit", forHTTPHeaderField: "User-Agent")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.timeoutInterval = 15
        let (status, data) = syncSend(request)
        guard status == 200, let data else { return nil }
        return try? JSONDecoder().decode(ContentFileResponse.self, from: data).sha
    }

    private struct ContentFileResponse: Decodable {
        let sha: String
        let content: String
    }

    private static func timestampLabel() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: Date())
    }

    /// Synchronous request via a semaphore - same convention as `DocsSyncSource.
    /// syncFetch`, since every caller here already runs off the main thread.
    private static func syncSend(_ request: URLRequest) -> (Int, Data?) {
        let semaphore = DispatchSemaphore(value: 0)
        var status = -1
        var result: Data?
        let task = URLSession.shared.dataTask(with: request) { data, response, _ in
            if let http = response as? HTTPURLResponse {
                status = http.statusCode
            }
            result = data
            semaphore.signal()
        }
        task.resume()
        semaphore.wait()
        return (status, result)
    }
}
