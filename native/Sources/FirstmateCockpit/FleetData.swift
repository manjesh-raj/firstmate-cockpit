// Manjesh Grand Line - native macOS app.
//
// Fix 1 (Overview): a Swift port of `backend/fleet.py`'s `snapshot()` and
// `backend/openprs.py`'s `open_prs()` - the data the web cockpit's Fleet
// dashboard is built from. Rather than embedding the Python/FastAPI backend
// as a service (explicitly out of scope for the native app), this reads the
// same on-disk firstmate home directly and shells out to the same `fm-*`
// scripts and forge CLIs the backend does, so the numbers on screen are
// always real, live data from this machine - never fabricated.
//
// Everything here is read-only against firstmate's state and the forges,
// matching the backend's own contract. Network/process calls are bounded and
// meant to run off the main thread (`FleetController.refresh` dispatches this
// whole module to a background queue).

import Foundation

// MARK: - Task state (state/*.meta + fm-crew-state.sh)

struct FleetTask {
    let id: String
    let repo: String?
    let kind: String
    let pr: String?
    var state: String = "unknown"
    var source: String = "none"
    var detail: String = ""
    /// working | needs_decision | blocked | done | failed | unknown
    var status: String = "unknown"
}

struct WatcherHealth {
    /// healthy | stale | off
    let status: String
}

struct FleetSnapshot {
    let homeOk: Bool
    let captain: String
    let tasks: [FleetTask]
    let queuedCount: Int
    let doneCount: Int
    let projectsCount: Int
    let watcher: WatcherHealth
}

// MARK: - Open PRs (openprs.py)

struct OpenPRInfo {
    let repo: String
    let number: Int?
    let title: String
    let url: String
    let forge: String
    /// green | red | pending | none
    let checks: String
}

struct MergedPR {
    /// "forge" (discovered by walking project clones) or "work" (tied to a
    /// currently-tracked task, which also carries a Merge action).
    let source: String
    let taskID: String?
    let repo: String
    let url: String
    let number: Int?
    let title: String
    let checks: String
    let forge: String?
}

enum FleetDataSource {

    // MARK: Projects (data/projects.md) - only a count is needed for the stat tile.

    static func projectsCount() -> Int {
        guard let text = try? String(contentsOf: FirstmateHome.data.appendingPathComponent("projects.md"), encoding: .utf8) else {
            return 0
        }
        return text.split(separator: "\n").filter { $0.trimmingCharacters(in: .whitespaces).hasPrefix("- ") }.count
    }

    // MARK: Backlog (data/backlog.md) - queued/done counts for the stat tiles.

    static func parseBacklogCounts() -> (queued: Int, done: Int) {
        guard let text = try? String(contentsOf: FirstmateHome.data.appendingPathComponent("backlog.md"), encoding: .utf8) else {
            return (0, 0)
        }
        var section: String?
        var queued = 0, done = 0
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("## ") {
                let title = trimmed.dropFirst(3).lowercased()
                if title.contains("flight") { section = "in_flight" }
                else if title.contains("queue") { section = "queued" }
                else if title.contains("done") { section = "done" }
                else { section = nil }
                continue
            }
            guard isChecklistItem(trimmed) else { continue }
            switch section {
            case "queued": queued += 1
            case "done": done += 1
            default: break
            }
        }
        return (queued, done)
    }

    private static func isChecklistItem(_ line: String) -> Bool {
        let c = Array(line)
        guard c.count >= 5, c[0] == "-", c[1] == " ", c[2] == "[", c[4] == "]" else { return false }
        return c[3] == " " || c[3] == "x" || c[3] == "X"
    }

    // MARK: Tasks (state/*.meta + fm-crew-state.sh)

    private static func parseMetaFile(_ url: URL) -> [String: String] {
        var meta: [String: String] = [:]
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return meta }
        for line in text.split(separator: "\n") {
            if line.hasPrefix("#") { continue }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let k = line[line.startIndex..<eq].trimmingCharacters(in: .whitespaces)
            let v = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if !k.isEmpty { meta[k] = v }
        }
        return meta
    }

    /// Mirrors `fleet.py`'s `_classify`: map a crew-state verb to a coarse
    /// status bucket the UI groups by.
    private static func classify(_ state: String) -> String {
        switch state {
        case "working": return "working"
        case "parked": return "needs_decision"
        case "done": return "done"
        case "blocked": return "blocked"
        case "failed": return "failed"
        default: return "unknown"
        }
    }

    /// Runs `bin/fm-crew-state.sh <id>` - the authoritative, deterministic
    /// current-state read (never a tail of the append-only status log - see
    /// that script's own header). Read-only, bounded by a real 15s watchdog:
    /// if the script hasn't exited by then, it's killed and this returns
    /// "unknown" rather than hanging `parseTasks()`'s serial loop forever.
    private static let crewStateTimeout: TimeInterval = 15

    private static func crewState(taskID: String) -> (state: String, source: String, detail: String) {
        let script = FirstmateHome.bin.appendingPathComponent("fm-crew-state.sh")
        guard FileManager.default.fileExists(atPath: script.path) else { return ("unknown", "none", "") }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/bash")
        proc.arguments = [script.path, taskID]
        proc.currentDirectoryURL = FirstmateHome.root
        var env = childEnvironmentDict()
        env["FM_HOME"] = FirstmateHome.root.path
        proc.environment = env
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = FileHandle.nullDevice
        do { try proc.run() } catch { return ("unknown", "none", "") }

        let deadline = DispatchTime.now() + crewStateTimeout
        let exited = DispatchSemaphore(value: 0)
        proc.terminationHandler = { _ in exited.signal() }
        if exited.wait(timeout: deadline) == .timedOut {
            proc.terminationHandler = nil
            if proc.isRunning { proc.terminate() }
            return ("unknown", "none", "")
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let line = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return parseCrewLine(line)
    }

    /// `"state: <s> · source: <src> · <detail>"` - the one stable, parseable
    /// line `fm-crew-state.sh` promises.
    private static func parseCrewLine(_ line: String) -> (state: String, source: String, detail: String) {
        let parts = line.components(separatedBy: "\u{00B7}").map { $0.trimmingCharacters(in: .whitespaces) }
        var state = "unknown", source = "none"
        var detailParts: [String] = []
        var sawState = false, sawSource = false
        for part in parts {
            if part.hasPrefix("state:") {
                state = part.dropFirst("state:".count).trimmingCharacters(in: .whitespaces)
                sawState = true
            } else if part.hasPrefix("source:") {
                source = part.dropFirst("source:".count).trimmingCharacters(in: .whitespaces)
                sawSource = true
            } else if sawSource {
                detailParts.append(part)
            }
        }
        if !sawState && !sawSource {
            return ("unknown", "none", line)
        }
        return (state, source, detailParts.joined(separator: " \u{00B7} "))
    }

    static func parseTasks() -> [FleetTask] {
        let stateDir = FirstmateHome.state
        guard let files = try? FileManager.default.contentsOfDirectory(at: stateDir, includingPropertiesForKeys: nil) else {
            return []
        }
        let metaFiles = files.filter { $0.pathExtension == "meta" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        return metaFiles.map { url in
            let id = url.deletingPathExtension().lastPathComponent
            let meta = parseMetaFile(url)
            var task = FleetTask(id: id, repo: meta["repo"], kind: meta["kind"] ?? "ship", pr: meta["pr"])
            let (state, source, detail) = crewState(taskID: id)
            task.state = state
            task.source = source
            task.detail = detail
            task.status = classify(state)
            return task
        }
    }

    // MARK: Watcher health (state/.watch.lock + state/.last-watcher-beat)

    static func watcherHealth() -> WatcherHealth {
        let stateDir = FirstmateHome.state
        let lock = stateDir.appendingPathComponent(".watch.lock")
        let beat = stateDir.appendingPathComponent(".last-watcher-beat")
        let fm = FileManager.default
        let lockPresent = fm.fileExists(atPath: lock.path)
        var lastBeatAge: Double?
        if let attrs = try? fm.attributesOfItem(atPath: beat.path), let mtime = attrs[.modificationDate] as? Date {
            lastBeatAge = Date().timeIntervalSince(mtime)
        }
        let freshSecs = 180.0
        let status: String
        if lockPresent, let age = lastBeatAge, age <= freshSecs {
            status = "healthy"
        } else if lockPresent {
            status = "stale"
        } else {
            status = "off"
        }
        return WatcherHealth(status: status)
    }

    // MARK: Snapshot

    static func snapshot() -> FleetSnapshot {
        let tasks = parseTasks()
        let (queued, done) = parseBacklogCounts()
        return FleetSnapshot(
            homeOk: FirstmateHome.homeOk(),
            captain: ProcessInfo.processInfo.environment["FM_CAPTAIN"] ?? "Manjesh",
            tasks: tasks,
            queuedCount: queued,
            doneCount: done,
            projectsCount: projectsCount(),
            watcher: watcherHealth()
        )
    }

    // MARK: Merge open-PR + task-PR views into one list (mirrors `mergedPRs()` in index.html)

    static func mergedPRs(openPRs: [OpenPRInfo], tasks: [FleetTask]) -> [MergedPR] {
        func norm(_ u: String) -> String {
            var s = u
            for prefix in ["https://", "http://"] where s.hasPrefix(prefix) { s.removeFirst(prefix.count) }
            while s.hasSuffix("/") { s.removeLast() }
            return s.lowercased()
        }
        func prNumber(from u: String) -> Int? {
            let trailingDigits = String(u.reversed().prefix(while: { $0.isNumber }).reversed())
            return trailingDigits.isEmpty ? nil : Int(trailingDigits)
        }
        var byURL: [String: MergedPR] = [:]
        for p in openPRs {
            byURL[norm(p.url)] = MergedPR(source: "forge", taskID: nil, repo: p.repo, url: p.url, number: p.number, title: p.title, checks: p.checks, forge: p.forge)
        }
        for t in tasks {
            guard let pr = t.pr, !pr.isEmpty else { continue }
            let key = norm(pr)
            let existing = byURL[key]
            byURL[key] = MergedPR(
                source: "work",
                taskID: t.id,
                repo: t.repo ?? existing?.repo ?? "",
                url: pr,
                number: existing?.number ?? prNumber(from: pr),
                title: existing?.title ?? "",
                checks: existing?.checks ?? "none",
                forge: existing?.forge
            )
        }
        return Array(byURL.values)
    }

    // MARK: Merge action (bin/fm-pr-merge.sh - firstmate's guarded merge helper)

    static func mergePR(url: String) -> (ok: Bool, message: String) {
        let script = FirstmateHome.bin.appendingPathComponent("fm-pr-merge.sh")
        guard FileManager.default.fileExists(atPath: script.path) else {
            return (false, "fm-pr-merge.sh not found under \(FirstmateHome.bin.path)")
        }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/bash")
        proc.arguments = [script.path, url]
        proc.currentDirectoryURL = FirstmateHome.root
        proc.environment = childEnvironmentDict()
        let out = Pipe(), err = Pipe()
        proc.standardOutput = out
        proc.standardError = err
        do { try proc.run() } catch {
            return (false, error.localizedDescription)
        }
        // GL-02: drain BOTH pipes concurrently, then wait. The previous order
        // (`waitUntilExit()` first, then read) deadlocks the moment the merge
        // script emits more than one pipe buffer (~64KB) on either stream: the
        // child blocks in `write()` forever waiting for a reader that never
        // comes, this thread blocks in `waitUntilExit()` forever waiting for a
        // child that never exits, the completion that re-enables the Merge
        // button never runs, and the thread leaks for the session. Reading
        // stdout to EOF and *then* stderr is only half a fix - it still
        // deadlocks on a child that fills stderr while stdout is open - so
        // both reads happen on their own queues here.
        var stdoutData = Data(), stderrData = Data()
        let drain = DispatchGroup()
        let readQueue = DispatchQueue(label: "fm.mergepr.drain", attributes: .concurrent)
        drain.enter()
        readQueue.async {
            stdoutData = out.fileHandleForReading.readDataToEndOfFile()
            drain.leave()
        }
        drain.enter()
        readQueue.async {
            stderrData = err.fileHandleForReading.readDataToEndOfFile()
            drain.leave()
        }
        drain.wait()
        proc.waitUntilExit()
        let stdout = String(data: stdoutData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let stderr = String(data: stderrData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let ok = proc.terminationStatus == 0
        return (ok, ok ? (stdout.isEmpty ? "Merged." : stdout) : (stderr.isEmpty ? stdout : stderr))
    }
}

// MARK: - Open PRs across every project clone (openprs.py)

enum OpenPRsSource {

    /// Walk `$FM_HOME/projects/*`, read each clone's `origin` remote, and ask
    /// the forge for open PRs. One bad clone is skipped, never failing the
    /// whole scan - mirrors `_aggregate()`. Meant to run off the main thread.
    ///
    /// Per-clone work (a `git remote get-url` shell-out plus a `gh pr list`/
    /// Bitbucket REST round trip) is embarrassingly parallel - each clone is
    /// independent and none of it touches shared mutable state except the
    /// final result array, which is guarded below. Measured live against 14
    /// real project clones: sequential ~9.2-10.7s, concurrent (bounded to 6)
    /// well under 2s. Concurrency is bounded rather than unbounded so this
    /// doesn't spawn a `gh`/curl process per clone all at once on a captain
    /// with dozens of projects.
    private static let fetchConcurrency = 6

    /// GL-14: what a scan actually found, including whether any of it failed.
    /// `isDegraded` is what Review/Overview render their "couldn't reach the
    /// forge" state from - the whole point is that an empty `prs` array is no
    /// longer, on its own, evidence of an all-clear.
    struct FetchResult {
        var prs: [OpenPRInfo] = []
        /// Clone labels whose forge query failed outright.
        var failedRepos: [String] = []
        /// `$FM_HOME/projects` itself could not be listed - nothing was even
        /// attempted, so this is a total failure, not a partial one.
        var projectsUnreadable = false

        var isDegraded: Bool { projectsUnreadable || !failedRepos.isEmpty }

        /// One short line naming what went wrong, for an empty state or a
        /// subtitle. `nil` when the scan was clean.
        var failureSummary: String? {
            if projectsUnreadable {
                return "Couldn't read \(FirstmateHome.projects.path)."
            }
            guard !failedRepos.isEmpty else { return nil }
            if failedRepos.count == 1 {
                return "Couldn't reach the forge for \(failedRepos[0])."
            }
            return "Couldn't reach the forge for \(failedRepos.count) repositories."
        }
    }

    /// The pre-GL-14 signature, kept for callers that genuinely only want the
    /// list (nothing in-app renders an empty state off it anymore).
    static func fetch() -> [OpenPRInfo] {
        fetchDetailed().prs
    }

    static func fetchDetailed() -> FetchResult {
        guard let clones = try? FileManager.default.contentsOfDirectory(
            at: FirstmateHome.projects, includingPropertiesForKeys: [.isDirectoryKey]
        ) else { return FetchResult(projectsUnreadable: true) }

        let sortedClones = clones
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }

        var result: [OpenPRInfo] = []
        var failed: [String] = []
        let lock = NSLock()
        let queue = DispatchQueue(label: "fm.openprs.fetch", attributes: .concurrent)
        let sema = DispatchSemaphore(value: fetchConcurrency)
        let group = DispatchGroup()

        for clone in sortedClones {
            sema.wait()
            group.enter()
            queue.async {
                defer { sema.signal(); group.leave() }
                // A directory that is not a git clone, or whose remote this
                // app does not understand, is skipped exactly as before -
                // that is not a *failure* to reach a forge, so it must not
                // trip the degraded state.
                guard let remote = originURL(clone), let parsed = parseRemote(remote) else { return }
                let label = clone.lastPathComponent
                let prs: [OpenPRInfo]?
                switch parsed.forge {
                case "github":
                    prs = githubOpenPRs(owner: parsed.owner, repo: parsed.repo, label: label)
                case "bitbucket":
                    prs = bitbucketOpenPRs(workspace: parsed.owner, repo: parsed.repo, label: label)
                default:
                    prs = []
                }
                guard let prs else {
                    lock.lock()
                    failed.append(label)
                    lock.unlock()
                    return
                }
                guard !prs.isEmpty else { return }
                lock.lock()
                result += prs
                lock.unlock()
            }
        }
        group.wait()
        return FetchResult(prs: result, failedRepos: failed.sorted(), projectsUnreadable: false)
    }

    // MARK: git plumbing

    private static func originURL(_ clone: URL) -> String? {
        guard let gitPath = resolveExecutable("git") else { return nil }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: gitPath)
        proc.arguments = ["-C", clone.path, "remote", "get-url", "origin"]
        proc.environment = childEnvironmentDict()
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = FileHandle.nullDevice
        do { try proc.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else { return nil }
        let s = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (s?.isEmpty ?? true) ? nil : s
    }

    private static func gitEmail() -> String? {
        guard let gitPath = resolveExecutable("git") else { return nil }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: gitPath)
        proc.arguments = ["config", "--global", "user.email"]
        proc.environment = childEnvironmentDict()
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = FileHandle.nullDevice
        do { try proc.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else { return nil }
        let s = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (s?.isEmpty ?? true) ? nil : s
    }

    /// `(forge, owner, repo)` for a github.com / bitbucket.org remote - both
    /// the scp-like SSH form (`git@host:owner/repo.git`) and the URL form
    /// (`https://[user@]host[:port]/owner/repo`). Anything else is skipped.
    private static func parseRemote(_ raw: String) -> (forge: String, owner: String, repo: String)? {
        let url = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty else { return nil }
        var host: String
        var path: String
        if !url.contains("://"), let at = url.range(of: "@"), let colon = url.range(of: ":", range: at.upperBound..<url.endIndex) {
            host = String(url[at.upperBound..<colon.lowerBound])
            path = String(url[colon.upperBound...])
        } else if let scheme = url.range(of: "://") {
            var rest = url[scheme.upperBound...]
            if let at = rest.range(of: "@") { rest = rest[at.upperBound...] }
            guard let slash = rest.firstIndex(of: "/") else { return nil }
            var h = String(rest[rest.startIndex..<slash])
            if let colon = h.firstIndex(of: ":") { h = String(h[h.startIndex..<colon]) }
            host = h
            path = String(rest[rest.index(after: slash)...])
        } else {
            return nil
        }
        path = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if path.hasSuffix(".git") { path = String(path.dropLast(4)) }
        let parts = path.split(separator: "/").map(String.init)
        guard parts.count >= 2 else { return nil }
        let hostLower = host.lowercased()
        let forge: String
        if hostLower == "github.com" || hostLower.hasSuffix(".github.com") {
            forge = "github"
        } else if hostLower == "bitbucket.org" || hostLower.hasSuffix(".bitbucket.org") {
            forge = "bitbucket"
        } else {
            return nil
        }
        return (forge, parts[0], parts[1])
    }

    private static func resolveExecutable(_ name: String) -> String? {
        let fm = FileManager.default
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            for dir in path.split(separator: ":") {
                let candidate = "\(dir)/\(name)"
                if fm.isExecutableFile(atPath: candidate) { return candidate }
            }
        }
        for candidate in ["/opt/homebrew/bin/\(name)", "/usr/local/bin/\(name)", "/usr/bin/\(name)", "/bin/\(name)"] {
            if fm.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    // MARK: GitHub

    private static let ghFail: Set<String> = ["FAILURE", "TIMED_OUT", "CANCELLED", "ACTION_REQUIRED", "STARTUP_FAILURE", "STALE", "ERROR"]
    private static let ghOk: Set<String> = ["SUCCESS", "NEUTRAL", "SKIPPED"]

    private static func mapGithubChecks(_ rollup: [[String: Any]]?) -> String {
        guard let rollup, !rollup.isEmpty else { return "none" }
        var sawFail = false, sawPending = false, sawSuccess = false
        for c in rollup {
            let status = (c["status"] as? String ?? "").uppercased()
            let concl = (c["conclusion"] as? String ?? "").uppercased()
            let state = (c["state"] as? String ?? "").uppercased()
            if ghFail.contains(state) || ghFail.contains(concl) {
                sawFail = true
            } else if state == "PENDING" || state == "EXPECTED" || (!status.isEmpty && status != "COMPLETED") {
                sawPending = true
            } else if state == "SUCCESS" || ghOk.contains(concl) {
                sawSuccess = true
            } else {
                sawPending = true
            }
        }
        if sawFail { return "red" }
        if sawPending { return "pending" }
        if sawSuccess { return "green" }
        return "none"
    }

    /// GL-14: `nil` means "the query failed" (no `gh`, no network, not
    /// authenticated, a non-zero exit, unparseable JSON); `[]` means "this
    /// repo genuinely has no open PRs right now". Collapsing the two - which
    /// is what this returned before - makes an offline app render a confident
    /// all-clear on the one page whose entire job is telling the captain
    /// whether there is something to act on.
    private static func githubOpenPRs(owner: String, repo: String, label: String) -> [OpenPRInfo]? {
        guard let ghPath = resolveExecutable("gh") else { return nil }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: ghPath)
        proc.arguments = [
            "pr", "list", "--repo", "\(owner)/\(repo)",
            "--state", "open", "--limit", "50",
            "--json", "number,title,url,statusCheckRollup,createdAt",
        ]
        proc.environment = childEnvironmentDict()
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = FileHandle.nullDevice
        do { try proc.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else { return nil }
        guard let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }
        return rows.map { row in
            OpenPRInfo(
                repo: label,
                number: row["number"] as? Int,
                title: row["title"] as? String ?? "",
                url: row["url"] as? String ?? "",
                forge: "github",
                checks: mapGithubChecks(row["statusCheckRollup"] as? [[String: Any]])
            )
        }
    }

    // MARK: Bitbucket

    /// The (user, token) basic-auth identity that actually works, resolved
    /// once per process (the cached git credential's bare handle is often
    /// rejected; the stored password - an Atlassian API token - must be
    /// paired with the account email instead). Mirrors `_bb_identity` /
    /// `_bb_candidates` in openprs.py.
    /// GL-28(a): these two are read and written from inside `fetch()`'s
    /// concurrent per-clone queue, so every access goes through `bbCacheLock`.
    /// Unsynchronized access to a Swift `Optional` of a tuple-of-Strings is a
    /// real data race (torn reads of the string buffers, not just a stale
    /// value), which is exactly the class TSan flags here.
    private static let bbCacheLock = NSLock()
    private static var _bbIdentity: (user: String, token: String)?
    private static var _bbCandidatesCache: [(user: String, token: String)]?

    private static var bbIdentity: (user: String, token: String)? {
        get { bbCacheLock.lock(); defer { bbCacheLock.unlock() }; return _bbIdentity }
        set { bbCacheLock.lock(); defer { bbCacheLock.unlock() }; _bbIdentity = newValue }
    }

    private static func bbCandidates() -> [(user: String, token: String)] {
        bbCacheLock.lock()
        let cachedCandidates = _bbCandidatesCache
        bbCacheLock.unlock()
        if let cached = cachedCandidates { return cached }
        var cands: [(String, String)] = []
        guard let gitPath = resolveExecutable("git") else {
            bbCacheLock.lock(); _bbCandidatesCache = cands; bbCacheLock.unlock()
            return cands
        }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: gitPath)
        proc.arguments = ["credential", "fill"]
        proc.environment = childEnvironmentDict()
        let inPipe = Pipe(), outPipe = Pipe()
        proc.standardInput = inPipe
        proc.standardOutput = outPipe
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
            inPipe.fileHandleForWriting.write("protocol=https\nhost=bitbucket.org\n\n".data(using: .utf8)!)
            inPipe.fileHandleForWriting.closeFile()
            let data = outPipe.fileHandleForReading.readDataToEndOfFile()
            proc.waitUntilExit()
            if proc.terminationStatus == 0, let text = String(data: data, encoding: .utf8) {
                var user: String?, token: String?
                for line in text.split(separator: "\n") {
                    if line.hasPrefix("username=") { user = String(line.dropFirst("username=".count)) }
                    else if line.hasPrefix("password=") { token = String(line.dropFirst("password=".count)) }
                }
                if let token {
                    if let user, !user.isEmpty { cands.append((user, token)) }
                    if let email = gitEmail(), !cands.contains(where: { $0.0 == email }) {
                        cands.append((email, token))
                    }
                }
            }
        } catch {
            // no usable credential - fall through with an empty candidate list
        }
        bbCacheLock.lock()
        // Last writer wins if two clones raced to fill this - both computed
        // the same thing from the same git credential helper, so either is
        // correct; the point of the lock is that neither read is torn.
        _bbCandidatesCache = cands
        bbCacheLock.unlock()
        return cands
    }

    private static func bbGet(url: URL, user: String, token: String) -> [String: Any]? {
        var req = URLRequest(url: url)
        let cred = "\(user):\(token)".data(using: .utf8)!.base64EncodedString()
        req.addValue("Basic \(cred)", forHTTPHeaderField: "Authorization")
        req.addValue("application/json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 10
        let semaphore = DispatchSemaphore(value: 0)
        var result: [String: Any]?
        URLSession.shared.dataTask(with: req) { data, _, error in
            if let data, error == nil {
                result = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            }
            semaphore.signal()
        }.resume()
        _ = semaphore.wait(timeout: .now() + 12)
        return result
    }

    /// `nil` on failure - see `githubOpenPRs` (GL-14).
    private static func bitbucketOpenPRs(workspace: String, repo: String, label: String) -> [OpenPRInfo]? {
        guard let url = URL(string: "https://api.bitbucket.org/2.0/repositories/\(workspace)/\(repo)/pullrequests?state=OPEN&pagelen=50") else {
            return nil
        }
        var data: [String: Any]?
        if let identity = bbIdentity {
            data = bbGet(url: url, user: identity.user, token: identity.token)
        }
        if data == nil || data?["values"] == nil {
            for cand in bbCandidates() {
                if let d = bbGet(url: url, user: cand.user, token: cand.token), d["values"] != nil {
                    bbIdentity = cand
                    data = d
                    break
                }
            }
        }
        guard let values = data?["values"] as? [[String: Any]] else { return nil }
        return values.map { pr in
            let links = pr["links"] as? [String: Any]
            let html = links?["html"] as? [String: Any]
            let href = html?["href"] as? String ?? ""
            return OpenPRInfo(
                repo: label,
                number: pr["id"] as? Int,
                title: pr["title"] as? String ?? "",
                url: href,
                forge: "bitbucket",
                checks: "none"
            )
        }
    }
}
