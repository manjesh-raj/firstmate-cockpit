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

// GL-27: compiled into debug builds only.
//
// The 51 self-test suites are ~10,500 lines of test code, fault-injection
// seams and fixture data that used to be linked into the binary the captain
// actually runs. `FM_SELFTESTS` is defined by `Package.swift` for the debug
// configuration only, so `swift build` (and therefore CI and
// `Scripts/run-all-tests.sh`) still has every suite, while
// `swift build -c release` - what `native/build_native_app.sh` assembles the
// shipped `.app` from - has none of it.
//
// Do not remove this guard when editing a suite: `Phase3PolishSelfTest`
// asserts that every file in this directory carries it.
#if FM_SELFTESTS

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

            // Postmortems live in the same store's postmortemsRoot subfolder -
            // a file placed there directly (phase 1's own list-only path)...
            try? "# Incident: payments outage\n\nRoot cause text.".write(
                to: store.postmortemsRoot.appendingPathComponent("2026-08-payments-outage.md"), atomically: true, encoding: .utf8
            )
            check(store.listPostmortems().count == 1, "listPostmortems should see a file placed directly under postmortems/")
            check(store.listRunbooks().count == 1, "listRunbooks must never include files from the postmortems/ subfolder")

            // ...and `createPostmortem` (phase 2, "Generate Postmortem") is the
            // one write path into that subfolder - same slug-disambiguation
            // and dirty-marking as `createRunbook`, just scoped to postmortems/.
            let p1 = store.createPostmortem(title: "Pod crash loop on payments-worker", content: "# Pod crash loop on payments-worker\n\n## Root Cause\nOOMKilled.")
            check(p1.id == "pod-crash-loop-on-payments-worker", "createPostmortem should slug the id from the title")
            check(store.listPostmortems().count == 2, "listPostmortems should see the newly created postmortem alongside the pre-existing one")
            check(store.listRunbooks().count == 1, "createPostmortem must never write into the runbooks/ top level")

            let p2 = store.createPostmortem(title: "Pod crash loop on payments-worker", content: "# Pod crash loop on payments-worker (again)\n\nA duplicate title.")
            check(p2.id != p1.id, "a duplicate postmortem title should get a disambiguated slug, not overwrite the first file")
            check(store.listPostmortems().count == 3, "both postmortems should exist as separate files")
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

        // --- DocsRunbookMetadata (fm/grandline-design-fidelity-fixes) -------
        //
        // The card subtitle the Docs grid shows is derived from the document's
        // own markdown - no stored category, no stored step count. These are
        // the two real shapes on disk: a runbook (`# Title`, prose, a `##
        // Steps` fenced block of commands) and a postmortem written by
        // `SRELeadPostmortem` (`## Root Cause` with a `**Finding:**` label).
        let runbookMarkdown = """
        # Node Health Check

        Read-only survey of overall node health across the cluster.

        ## Steps

        ```
        kubectl get nodes -o wide
        kubectl top nodes
        kubectl get events -A --field-selector involvedObject.kind=Node
        ```

        ## Next steps

        - `kubectl describe node <node-name>` - check the Conditions section.
        """
        let rb = DocsRunbook(id: "node-health-check", title: "Node Health Check",
                             content: runbookMarkdown, modifiedAt: Date())
        check(DocsRunbookMetadata.stepCount(in: runbookMarkdown) == 3,
              "step count should be the 3 command lines inside the fenced block, got \(DocsRunbookMetadata.stepCount(in: runbookMarkdown))")
        check(DocsRunbookMetadata.category(in: runbookMarkdown) == "Kubernetes",
              "an all-kubectl runbook should read as Kubernetes, got \(String(describing: DocsRunbookMetadata.category(in: runbookMarkdown)))")
        check(DocsRunbookMetadata.runbookSubtitle(rb) == "Kubernetes \u{00B7} 3 steps",
              "subtitle should be \"Kubernetes \u{00B7} 3 steps\", got \(String(describing: DocsRunbookMetadata.runbookSubtitle(rb)))")

        // The `- ` bullet in "Next steps" is prose, not a step: it is outside
        // the fence, so it must not be counted.
        check(!DocsRunbookMetadata.commandLines(in: runbookMarkdown).contains { $0.hasPrefix("-") },
              "prose bullets outside a fenced block must not count as steps")

        // A document with no fenced commands has nothing to say - the caller
        // falls back to "Updated N ago".
        check(DocsRunbookMetadata.runbookSubtitle(
                DocsRunbook(id: "x", title: "x", content: "# x\n\nJust prose.\n", modifiedAt: Date())) == nil,
              "a runbook with no steps should have no derived subtitle")

        // Mixed tools: the dominant executable wins.
        let awsMarkdown = "# X\n\n```\naws s3 ls\naws ec2 describe-instances\nkubectl get pods\n```\n"
        check(DocsRunbookMetadata.category(in: awsMarkdown) == "AWS",
              "the dominant executable should decide the category, got \(String(describing: DocsRunbookMetadata.category(in: awsMarkdown)))")

        let postmortemMarkdown = """
        # 2026-08-11 worker OOMKill cascade

        ## Timeline

        - 14:02 first restart.

        ## Root Cause

        **Finding:** the worker's 512Mi memory limit was below its real working set. Everything after the first sentence is detail.

        ## Follow-ups

        **Recommended next action:** raise the limit to 768Mi.
        """
        let pm = DocsRunbook(id: "pm", title: "2026-08-11 worker OOMKill cascade",
                             content: postmortemMarkdown, modifiedAt: Date())
        let pmSubtitle = DocsRunbookMetadata.postmortemSubtitle(pm)
        check(pmSubtitle == "Root cause: the worker's 512Mi memory limit was below its real working set",
              "postmortem subtitle should be the first sentence of Root Cause with the Finding label stripped, got \(String(describing: pmSubtitle))")
        check(DocsRunbookMetadata.postmortemSubtitle(
                DocsRunbook(id: "y", title: "y", content: "# y\n\n## Timeline\n\nnothing.\n", modifiedAt: Date())) == nil,
              "a postmortem with no Root Cause section should have no derived subtitle")

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

#endif
