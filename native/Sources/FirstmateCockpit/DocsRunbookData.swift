// Manjesh Grand Line - native macOS app.
//
// Data layer for the Docs page's Runbooks/Postmortems tabs
// (`fm/grandline-docs-knowledge-foundation`, phase 1 of "Knowledge and
// speed" - see AGENTS.md's "Docs" / "Knowledge" section). Plain markdown
// files under `GrandLineDocs/runbooks/` (and its `postmortems/` subfolder) in
// the SAME local clone of `manjesh-config` that `ShiftGitSync` already
// manages - not a second clone of the same repo. `DocsRunbookGitSync` shares
// `ShiftGitSync.shared`'s `workingTree` and serial `queue` (see
// `ShiftGitSync.sharedQueue`) so both stores' git invocations serialize
// against the same working tree instead of racing on `.git/index.lock`, and
// relies on `ShiftGitSync.shared.ensureWorkingTreeNow()` for the actual
// clone/pull/repo-layout-migration mechanics rather than reimplementing them
// - this class only owns a debounced commit+push scoped to its own
// `GrandLineDocs/runbooks` subtree.
//
// This phase deliberately has no conflict-resolution UI (unlike Shift's own
// `cockpit-shift-conflict-handling`) - see AGENTS.md for what's in/out of
// scope for this phase.

import Foundation

// MARK: - A single runbook or postmortem document

struct DocsRunbook: Identifiable, Equatable {
    /// The filename (without `.md`) - stable across edits, used as the
    /// on-disk identity. Never regenerated from the title on save, so
    /// renaming a runbook's title doesn't orphan its old file.
    let id: String
    var title: String
    var content: String
    var modifiedAt: Date
}

// MARK: - Git sync (shares ShiftGitSync's clone/queue - see file header)

final class DocsRunbookGitSync {
    enum Status: Equatable {
        case synced
        case localChanges
        case syncing
        case failed(String)
    }

    static let runbooksSubpath = "GrandLineDocs/runbooks"

    let workingTree: URL
    let dataRoot: URL
    private let remoteURL: String
    private let branch: String
    private let debounceInterval: TimeInterval
    private let queue: DispatchQueue

    private(set) var status: Status = .synced
    private var statusHandlers: [(Status) -> Void] = []
    private var pendingCommit: DispatchWorkItem?

    /// `true` only for `.shared` - see that property's own doc comment. A
    /// standalone instance (every self-test, and any future non-production
    /// use) owns and clones its own working tree instead, so tests never
    /// risk touching `ShiftGitSync.shared`'s real production clone.
    private let sharesProductionWorkingTree: Bool

    init(
        workingTree: URL, remoteURL: String, branch: String = "main",
        debounceInterval: TimeInterval = 3.0, queue: DispatchQueue,
        sharesProductionWorkingTree: Bool = false
    ) {
        self.workingTree = workingTree
        self.dataRoot = workingTree.appendingPathComponent(Self.runbooksSubpath, isDirectory: true)
        self.remoteURL = remoteURL
        self.branch = branch
        self.debounceInterval = debounceInterval
        self.queue = queue
        self.sharesProductionWorkingTree = sharesProductionWorkingTree
    }

    /// Reuses `ShiftGitSync.shared`'s own working tree, remote, and serial
    /// queue - see this file's header for why. `ShiftGitSync.resolveDefaultRemoteURL()`
    /// already honors `FM_SHIFT_REMOTE_URL`, which is what lets a whole test
    /// instance of the app (and this phase's own live verification) point at
    /// a disposable local bare repo instead of the real `manjesh-config`.
    static let shared = DocsRunbookGitSync(
        workingTree: ShiftGitSync.shared.workingTree,
        remoteURL: ShiftGitSync.resolveDefaultRemoteURL(),
        queue: ShiftGitSync.shared.sharedQueue,
        sharesProductionWorkingTree: true
    )

    func observeStatus(_ handler: @escaping (Status) -> Void) {
        statusHandlers.append(handler)
        let current = status
        DispatchQueue.main.async { handler(current) }
    }

    private func setStatus(_ newStatus: Status) {
        status = newStatus
        let handlers = statusHandlers
        DispatchQueue.main.async { handlers.forEach { $0(newStatus) } }
    }

    /// Production entry point - dispatches the real work onto `queue`
    /// asynchronously, never blocking the caller (`DocsRunbookStore.init()`,
    /// called on the main thread). Tests that need to observe the result
    /// synchronously should call `ensureReadyNow()` directly instead (mirrors
    /// `ShiftGitSync`'s own `start()`-dispatches-async /
    /// `ensureWorkingTreeNow()`-runs-synchronously split, and its self-test's
    /// convention of calling the synchronous form directly).
    func start() {
        queue.async { [weak self] in self?.ensureReadyNow() }
    }

    /// Ensures a working tree exists (delegating to `ShiftGitSync.shared` when
    /// this instance shares its production clone, never re-cloning
    /// independently in that case; cloning its own otherwise - see
    /// `sharesProductionWorkingTree`) and that `dataRoot`/`postmortems/`
    /// exist, then reports the current dirty/synced state - synchronously,
    /// so a caller (production or test) can rely on `status` reflecting
    /// reality the moment this returns.
    @discardableResult
    func ensureReadyNow() -> Bool {
        let ok = sharesProductionWorkingTree ? ShiftGitSync.shared.ensureWorkingTreeNow() : ensureStandaloneWorkingTreeNow()
        let fm = FileManager.default
        try? fm.createDirectory(at: dataRoot, withIntermediateDirectories: true)
        try? fm.createDirectory(at: dataRoot.appendingPathComponent("postmortems"), withIntermediateDirectories: true)
        let dirty = !uncommittedFiles().isEmpty
        setStatus(dirty ? .localChanges : .synced)
        if dirty { markDirty() }
        return ok
    }

    /// Only reached when `sharesProductionWorkingTree` is `false` (a
    /// standalone instance, e.g. a self-test against a disposable repo) - a
    /// minimal clone-if-needed, since a standalone instance's own repo is
    /// already expected to have the right layout by construction (no repo-
    /// layout migration needed here, unlike `ShiftGitSync`'s own).
    @discardableResult
    private func ensureStandaloneWorkingTreeNow() -> Bool {
        let fm = FileManager.default
        let gitDir = workingTree.appendingPathComponent(".git")
        guard !fm.fileExists(atPath: gitDir.path) else { return true }
        setStatus(.syncing)
        try? fm.createDirectory(at: workingTree.deletingLastPathComponent(), withIntermediateDirectories: true)
        let clone = runGit(["clone", remoteURL, workingTree.path], cwd: nil, authenticated: true)
        guard clone.status == 0 else {
            try? fm.createDirectory(at: dataRoot, withIntermediateDirectories: true)
            setStatus(.failed("Could not clone \(remoteURL): \(clone.stderr.isEmpty ? "unknown error" : clone.stderr)"))
            return false
        }
        return true
    }

    /// Called right after a local markdown write has already completed
    /// synchronously - same debounce shape as `ShiftGitSync.markDirty()`.
    func markDirty() {
        setStatus(.localChanges)
        queue.async { [weak self] in
            guard let self else { return }
            self.pendingCommit?.cancel()
            let item = DispatchWorkItem { [weak self] in self?.commitAndPushNow() }
            self.pendingCommit = item
            self.queue.asyncAfter(deadline: .now() + self.debounceInterval, execute: item)
        }
    }

    @discardableResult
    func commitAndPushNow() -> Bool {
        guard FileManager.default.fileExists(atPath: workingTree.appendingPathComponent(".git").path) else {
            setStatus(.failed("No local git checkout at \(workingTree.path)"))
            return false
        }
        let dirty = uncommittedFiles()
        guard !dirty.isEmpty else { return pushOnly() }
        setStatus(.syncing)
        let add = runGit(["add", "-A", "--", Self.runbooksSubpath], cwd: workingTree, authenticated: false)
        guard add.status == 0 else {
            setStatus(.failed("git add failed: \(add.stderr)"))
            return false
        }
        let commit = runGit(["commit", "-m", "Runbooks: \(dirty.count) file(s) updated"], cwd: workingTree, authenticated: false)
        guard commit.status == 0 else {
            setStatus(.failed("git commit failed: \(commit.stderr)"))
            return false
        }
        return pushOnly()
    }

    private func pushOnly() -> Bool {
        let push = runGit(["push", "origin", "HEAD:\(branch)"], cwd: workingTree, authenticated: true)
        guard push.status == 0 else {
            setStatus(.failed("git push failed: \(push.stderr.isEmpty ? "unknown error" : push.stderr)"))
            return false
        }
        setStatus(.synced)
        return true
    }

    private func uncommittedFiles() -> [String] {
        let result = runGit(["status", "--short", "--", Self.runbooksSubpath], cwd: workingTree, authenticated: false)
        return result.stdout.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
    }

    // MARK: Process plumbing (same shape as ShiftGitSync.runGit - see that
    // file's own doc comment on the authenticated-header mechanism)

    private struct GitResult { let status: Int32; let stdout: String; let stderr: String }

    private func runGit(_ args: [String], cwd: URL?, authenticated: Bool) -> GitResult {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        proc.arguments = args
        if let cwd { proc.currentDirectoryURL = cwd }
        var env = childEnvironmentDict()
        if authenticated, remoteURL.hasPrefix("https://"), let token = DocsSyncSource.ghAuthToken() {
            let basic = Data("x-access-token:\(token)".utf8).base64EncodedString()
            env["GIT_CONFIG_COUNT"] = "1"
            env["GIT_CONFIG_KEY_0"] = "http.extraheader"
            env["GIT_CONFIG_VALUE_0"] = "Authorization: Basic \(basic)"
        }
        proc.environment = env
        let out = Pipe(), err = Pipe()
        proc.standardOutput = out
        proc.standardError = err
        do {
            try proc.run()
        } catch {
            return GitResult(status: -1, stdout: "", stderr: "\(error)")
        }
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        return GitResult(
            status: proc.terminationStatus,
            stdout: String(data: outData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            stderr: String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        )
    }
}

// MARK: - Local CRUD store

final class DocsRunbookStore {
    private let fm = FileManager.default
    let root: URL
    var postmortemsRoot: URL { root.appendingPathComponent("postmortems", isDirectory: true) }

    /// `nil` when `FM_DOCS_RUNBOOKS_DIR` overrides `root` (every self-test in
    /// this area, and any captain who wants a plain local-only folder with no
    /// git backing) - same convention as `ShiftStore.gitSync`.
    let gitSync: DocsRunbookGitSync?

    init() {
        if let override = ProcessInfo.processInfo.environment["FM_DOCS_RUNBOOKS_DIR"], !override.isEmpty {
            root = URL(fileURLWithPath: (override as NSString).expandingTildeInPath, isDirectory: true)
            gitSync = nil
            try? fm.createDirectory(at: root, withIntermediateDirectories: true)
            try? fm.createDirectory(at: root.appendingPathComponent("postmortems"), withIntermediateDirectories: true)
        } else {
            let sync = DocsRunbookGitSync.shared
            sync.start()
            root = sync.dataRoot
            gitSync = sync
        }
    }

    func listRunbooks() -> [DocsRunbook] {
        list(in: root, onlyTopLevel: true)
    }

    func listPostmortems() -> [DocsRunbook] {
        list(in: postmortemsRoot, onlyTopLevel: true)
    }

    private func list(in dir: URL, onlyTopLevel: Bool) -> [DocsRunbook] {
        guard let entries = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsSubdirectoryDescendants]) else { return [] }
        return entries
            .filter { $0.pathExtension.lowercased() == "md" }
            .compactMap { url -> DocsRunbook? in
                guard let content = try? String(contentsOf: url, encoding: .utf8) else { return nil }
                let attrs = try? fm.attributesOfItem(atPath: url.path)
                let modified = (attrs?[.modificationDate] as? Date) ?? Date(timeIntervalSince1970: 0)
                let slug = url.deletingPathExtension().lastPathComponent
                return DocsRunbook(id: slug, title: Self.titleFromContent(content, fallback: slug), content: content, modifiedAt: modified)
            }
            .sorted { $0.modifiedAt > $1.modifiedAt }
    }

    @discardableResult
    func createRunbook(title: String, content: String) -> DocsRunbook {
        let base = Self.slugify(title)
        var slug = base
        var n = 2
        while fm.fileExists(atPath: root.appendingPathComponent("\(slug).md").path) {
            slug = "\(base)-\(n)"
            n += 1
        }
        let url = root.appendingPathComponent("\(slug).md")
        try? content.write(to: url, atomically: true, encoding: .utf8)
        gitSync?.markDirty()
        return DocsRunbook(id: slug, title: Self.titleFromContent(content, fallback: slug), content: content, modifiedAt: Date())
    }

    func updateRunbook(id: String, content: String) {
        let url = root.appendingPathComponent("\(id).md")
        try? content.write(to: url, atomically: true, encoding: .utf8)
        gitSync?.markDirty()
    }

    func deleteRunbook(id: String) {
        let url = root.appendingPathComponent("\(id).md")
        try? fm.removeItem(at: url)
        gitSync?.markDirty()
    }

    // MARK: Title/slug helpers

    /// The first non-empty line's `# Heading` text, or `fallback` (the file's
    /// own slug) if the content has no leading heading.
    static func titleFromContent(_ content: String, fallback: String) -> String {
        for line in content.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            if trimmed.hasPrefix("# ") {
                return String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            }
            break
        }
        return fallback
    }

    static func slugify(_ title: String) -> String {
        var slug = ""
        var lastWasDash = false
        for scalar in title.lowercased().unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                slug.unicodeScalars.append(scalar)
                lastWasDash = false
            } else if !lastWasDash && !slug.isEmpty {
                slug.append("-")
                lastWasDash = true
            }
        }
        let trimmed = slug.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return trimmed.isEmpty ? "runbook" : trimmed
    }
}

// MARK: - Search (Runbooks + Postmortems only - see AGENTS.md for what's deferred)

enum DocsKnowledgeSearchScope: String {
    case runbook = "Runbook"
    case postmortem = "Postmortem"
}

struct DocsKnowledgeSearchResult: Identifiable {
    var id: String { "\(scope.rawValue):\(runbook.id)" }
    let scope: DocsKnowledgeSearchScope
    let runbook: DocsRunbook
    /// A short excerpt around the first match, for the results list.
    let snippet: String
}

enum DocsKnowledgeSearch {
    /// Plain case-insensitive substring match over title + content - the
    /// same simplicity `ShiftSearchIndex.search` uses. Deliberately not
    /// wired to global `⌘K` or terminal history yet - see AGENTS.md.
    static func search(query: String, store: DocsRunbookStore) -> [DocsKnowledgeSearchResult] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }
        var results: [DocsKnowledgeSearchResult] = []
        for r in store.listRunbooks() {
            if let snippet = matchSnippet(query: q, in: r) {
                results.append(DocsKnowledgeSearchResult(scope: .runbook, runbook: r, snippet: snippet))
            }
        }
        for r in store.listPostmortems() {
            if let snippet = matchSnippet(query: q, in: r) {
                results.append(DocsKnowledgeSearchResult(scope: .postmortem, runbook: r, snippet: snippet))
            }
        }
        return results
    }

    private static func matchSnippet(query: String, in runbook: DocsRunbook) -> String? {
        if let range = runbook.title.range(of: query, options: .caseInsensitive) {
            _ = range
            return runbook.title
        }
        guard let range = runbook.content.range(of: query, options: .caseInsensitive) else { return nil }
        let content = runbook.content
        let contextChars = 60
        let startIndex = content.index(range.lowerBound, offsetBy: -contextChars, limitedBy: content.startIndex) ?? content.startIndex
        let endIndex = content.index(range.upperBound, offsetBy: contextChars, limitedBy: content.endIndex) ?? content.endIndex
        var excerpt = String(content[startIndex..<endIndex]).replacingOccurrences(of: "\n", with: " ")
        if startIndex != content.startIndex { excerpt = "\u{2026}" + excerpt }
        if endIndex != content.endIndex { excerpt += "\u{2026}" }
        return excerpt
    }
}
