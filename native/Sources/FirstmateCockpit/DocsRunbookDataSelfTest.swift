// Manjesh Grand Line - native macOS app.
//
// Permanent self-test for the Docs Runbooks/Postmortems data layer
// (`fm/grandline-docs-knowledge-foundation`), run via
// `FM_RUN_DOCS_RUNBOOK_TESTS=1 .build/debug/FirstmateCockpit` - same
// convention as `ShiftGitSyncSelfTest.swift`. Every git-backed scenario here
// runs against a real, disposable local bare repository under a scratch temp
// directory - never the captain's real `manjesh-config` - and constructs
// `DocsRunbookGitSync` directly (never `.shared`) so this test can never
// touch the real production clone.

import Foundation

enum DocsRunbookDataSelfTest {
    static func run() -> Bool {
        var failures: [String] = []
        func check(_ condition: Bool, _ message: String) {
            if !condition { failures.append(message) }
        }

        let fm = FileManager.default
        let scratch = fm.temporaryDirectory.appendingPathComponent("docs-runbook-selftest-\(UUID().uuidString)", isDirectory: true)
        try? fm.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: scratch) }

        // MARK: 1. Slugify + title-from-content

        check(DocsRunbookStore.slugify("Restart the payments worker") == "restart-the-payments-worker", "slugify should lowercase and dash-join words")
        check(DocsRunbookStore.slugify("  ***  ") == "runbook", "slugify should fall back to a placeholder for content with no alphanumerics")
        check(DocsRunbookStore.titleFromContent("# My Runbook\n\nBody text", fallback: "x") == "My Runbook", "titleFromContent should read a leading '# ' heading")
        check(DocsRunbookStore.titleFromContent("No heading here", fallback: "fallback-slug") == "fallback-slug", "titleFromContent should fall back when there's no leading heading")

        // MARK: 2. CRUD against a plain scratch folder (FM_DOCS_RUNBOOKS_DIR-style override)

        do {
            let dir = scratch.appendingPathComponent("plain-crud", isDirectory: true)
            setenv("FM_DOCS_RUNBOOKS_DIR", dir.path, 1)
            defer { unsetenv("FM_DOCS_RUNBOOKS_DIR") }
            let store = DocsRunbookStore()
            check(store.gitSync == nil, "an FM_DOCS_RUNBOOKS_DIR override should mean no git sync at all")

            let r1 = store.createRunbook(title: "Restart the payments worker", content: "# Restart the payments worker\n\nStep one.")
            check(r1.id == "restart-the-payments-worker", "createRunbook should slug the id from the title")
            check(store.listRunbooks().count == 1, "listRunbooks should see the newly created file")

            let r2 = store.createRunbook(title: "Restart the payments worker", content: "# Restart the payments worker (again)\n\nA duplicate title.")
            check(r2.id != r1.id, "a duplicate title should get a disambiguated slug, not overwrite the first file")
            check(store.listRunbooks().count == 2, "both runbooks should exist as separate files")

            store.updateRunbook(id: r1.id, content: "# Restart the payments worker\n\nUpdated step one.")
            let reloaded = store.listRunbooks().first { $0.id == r1.id }
            check(reloaded?.content.contains("Updated step one.") == true, "updateRunbook should persist the new content")

            store.deleteRunbook(id: r2.id)
            check(store.listRunbooks().count == 1, "deleteRunbook should remove exactly that file")
            check(store.listRunbooks().first?.id == r1.id, "the remaining runbook should be the one not deleted")

            // Postmortems live in the same store's postmortemsRoot subfolder,
            // list-only for this phase - write one directly (no create API
            // needed yet, generation is a later task) and confirm it's seen.
            try? "# Incident: payments outage\n\nRoot cause text.".write(
                to: store.postmortemsRoot.appendingPathComponent("2026-08-payments-outage.md"), atomically: true, encoding: .utf8
            )
            check(store.listPostmortems().count == 1, "listPostmortems should see a file placed directly under postmortems/")
            check(store.listRunbooks().count == 1, "listRunbooks must never include files from the postmortems/ subfolder")
        }

        // MARK: 3. Search across runbooks + postmortems, by title and by content

        do {
            let dir = scratch.appendingPathComponent("search", isDirectory: true)
            setenv("FM_DOCS_RUNBOOKS_DIR", dir.path, 1)
            defer { unsetenv("FM_DOCS_RUNBOOKS_DIR") }
            let store = DocsRunbookStore()
            store.createRunbook(title: "Rotate the database credentials", content: "# Rotate the database credentials\n\nConnect to the vault and rotate the secret.")
            store.createRunbook(title: "Deploy the frontend", content: "# Deploy the frontend\n\nRun the release pipeline.")
            try? "# Incident: credential leak\n\nA rotated database credential was exposed in logs.".write(
                to: store.postmortemsRoot.appendingPathComponent("2026-07-credential-leak.md"), atomically: true, encoding: .utf8
            )

            let byTitle = DocsKnowledgeSearch.search(query: "Deploy", store: store)
            check(byTitle.count == 1 && byTitle.first?.scope == .runbook, "a title match should be found and scoped as a runbook")

            let byContent = DocsKnowledgeSearch.search(query: "rotate the secret", store: store)
            check(byContent.contains { $0.runbook.id == "rotate-the-database-credentials" }, "a content match inside a runbook should be found")

            let crossScope = DocsKnowledgeSearch.search(query: "credential", store: store)
            let scopes = Set(crossScope.map(\.scope))
            check(scopes.contains(.runbook) && scopes.contains(.postmortem), "a query matching both a runbook and a postmortem should return both scopes, got \(crossScope.map { ($0.scope, $0.runbook.id) })")

            check(DocsKnowledgeSearch.search(query: "", store: store).isEmpty, "an empty query should return no results, not everything")
            check(DocsKnowledgeSearch.search(query: "no-such-term-anywhere", store: store).isEmpty, "a query with no matches should return no results")
        }

        // MARK: 4. Git sync - a real commit+push to a disposable bare repo,
        // scoped only to GrandLineDocs/runbooks (never personal-tasks).

        func makeBareRemote(name: String) -> URL {
            let path = scratch.appendingPathComponent(name, isDirectory: true)
            _ = shell("/usr/bin/git", ["init", "--bare", "-b", "main", path.path])
            return path
        }
        func seedRemote(_ remote: URL) {
            let seedDir = scratch.appendingPathComponent("seed-\(UUID().uuidString)", isDirectory: true)
            _ = shell("/usr/bin/git", ["clone", remote.path, seedDir.path])
            let runbooks = seedDir.appendingPathComponent("GrandLineDocs/runbooks", isDirectory: true)
            try? fm.createDirectory(at: runbooks.appendingPathComponent("postmortems"), withIntermediateDirectories: true)
            try? "seed".write(to: runbooks.appendingPathComponent(".keep"), atomically: true, encoding: .utf8)
            _ = shell("/usr/bin/git", ["-C", seedDir.path, "add", "-A"])
            _ = shell("/usr/bin/git", ["-C", seedDir.path, "-c", "user.email=test@example.com", "-c", "user.name=Runbook Test", "commit", "-m", "seed"])
            _ = shell("/usr/bin/git", ["-C", seedDir.path, "push", "origin", "main"])
        }
        func commitCount(_ repo: URL) -> Int {
            let result = shell("/usr/bin/git", ["--git-dir", repo.path, "log", "--oneline"])
            guard result.status == 0 else { return 0 }
            return result.stdout.split(separator: "\n").count
        }
        func waitForSynced(_ sync: DocsRunbookGitSync, timeout: TimeInterval = 5.0) {
            let deadline = Date().addingTimeInterval(timeout)
            while sync.status != .synced && Date() < deadline {
                Thread.sleep(forTimeInterval: 0.05)
            }
        }

        do {
            let remote = makeBareRemote(name: "remote-runbooks")
            seedRemote(remote)
            let wt = scratch.appendingPathComponent("wt-runbooks", isDirectory: true)
            let queue = DispatchQueue(label: "docs-runbook-selftest-queue")
            let sync = DocsRunbookGitSync(workingTree: wt, remoteURL: remote.path, debounceInterval: 0.2, queue: queue)

            check(sync.ensureReadyNow(), "ensureReadyNow() should succeed cloning a real local bare remote")
            check(sync.status == .synced, "status should be .synced right after a clean clone, got \(sync.status)")

            let before = commitCount(remote)
            let runbookFile = sync.dataRoot.appendingPathComponent("first-runbook.md")
            try? "# First runbook\n\nReal content.".write(to: runbookFile, atomically: true, encoding: .utf8)
            sync.markDirty()
            check(sync.status == .localChanges, "status should flip to .localChanges immediately on markDirty()")
            waitForSynced(sync)
            check(sync.status == .synced, "status should settle back to .synced once the debounced commit+push completes, got \(sync.status)")
            let after = commitCount(remote)
            check(after == before + 1, "exactly one new commit should have reached the remote, before=\(before) after=\(after)")

            // Confirm the commit is scoped to GrandLineDocs/runbooks only.
            let showFiles = shell("/usr/bin/git", ["--git-dir", remote.path, "show", "--name-only", "--format=", "HEAD"])
            check(showFiles.stdout.contains("GrandLineDocs/runbooks/first-runbook.md"), "the pushed commit should include the new runbook file")
            check(!showFiles.stdout.contains("personal-tasks"), "a runbook commit must never touch personal-tasks/")

            // A fresh clone of the remote should see the real file content.
            let freshClone = scratch.appendingPathComponent("fresh-runbooks-check", isDirectory: true)
            _ = shell("/usr/bin/git", ["clone", remote.path, freshClone.path])
            let freshContent = try? String(contentsOf: freshClone.appendingPathComponent("GrandLineDocs/runbooks/first-runbook.md"), encoding: .utf8)
            check(freshContent?.contains("Real content.") == true, "a fresh clone from the remote should show the real committed runbook content")
        }

        if !failures.isEmpty {
            for f in failures { FileHandle.standardError.write(Data(("FAIL: " + f + "\n").utf8)) }
        }
        return failures.isEmpty
    }

    private struct ShellResult { let status: Int32; let stdout: String }

    private static func shell(_ executable: String, _ args: [String]) -> ShellResult {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: executable)
        proc.arguments = args
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = Pipe()
        do {
            try proc.run()
        } catch {
            return ShellResult(status: -1, stdout: "")
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        return ShellResult(status: proc.terminationStatus, stdout: String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
    }
}
