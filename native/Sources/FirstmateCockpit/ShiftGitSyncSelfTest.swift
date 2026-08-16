// Manjesh Grand Line - native macOS app.
//
// Permanent self-test for `ShiftGitSync` (cockpit-shift-git-sync, phase 4 of
// the Shift build), run via `FM_RUN_SHIFT_GIT_SYNC_TESTS=1
// .build/debug/FirstmateCockpit` - same convention as
// `ShiftStoreSelfTest.swift`/`DiffEngineSelfTest.swift` (see main.swift's
// gate list).
//
// Every scenario here runs against a real, disposable local bare git
// repository created fresh under a scratch temp directory - never the
// captain's real `manjesh-config`. This is deliberate: it proves out the
// actual clone/commit/push/pull/debounce/status-pill logic against a real
// `git` subprocess and a real second "remote" repo, not mocked network calls
// - the acceptance bar this phase was built against explicitly calls for
// this kind of end-to-end verification instead of reasoning about the code.
//
// Status is read directly from `ShiftGitSync.status` after each synchronous
// call, not via `observeStatus`'s callback - that callback is dispatched
// through `DispatchQueue.main`, which never drains here since this self-test
// runs on the main thread with no run loop pumping (main.swift calls this
// before `app.run()`). Reading `.status` directly is safe for this test's
// purposes: every check below happens strictly after the call that mutates
// it has already returned or after a sleep long enough to cover the
// background queue's async work.

import Foundation

enum ShiftGitSyncSelfTest {
    static func run() -> Bool {
        var failures: [String] = []
        func check(_ condition: Bool, _ message: String) {
            if !condition { failures.append(message) }
        }

        let fm = FileManager.default
        let scratch = fm.temporaryDirectory.appendingPathComponent("shift-git-sync-selftest-\(UUID().uuidString)", isDirectory: true)
        try? fm.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: scratch) }

        func makeBareRemote(name: String) -> URL {
            let path = scratch.appendingPathComponent(name, isDirectory: true)
            _ = shell("/usr/bin/git", ["init", "--bare", "-b", "main", path.path])
            return path
        }

        func seedRemote(_ remote: URL) {
            let seedDir = scratch.appendingPathComponent("seed-\(UUID().uuidString)", isDirectory: true)
            _ = shell("/usr/bin/git", ["clone", remote.path, seedDir.path])
            let personalTasks = seedDir.appendingPathComponent("GrandLineDocs/personal-tasks", isDirectory: true)
            try? fm.createDirectory(at: personalTasks, withIntermediateDirectories: true)
            try? "seed".write(to: personalTasks.appendingPathComponent(".keep"), atomically: true, encoding: .utf8)
            _ = shell("/usr/bin/git", ["-C", seedDir.path, "add", "-A"])
            _ = shell("/usr/bin/git", ["-C", seedDir.path, "-c", "user.email=test@example.com", "-c", "user.name=Shift Test", "commit", "-m", "seed"])
            _ = shell("/usr/bin/git", ["-C", seedDir.path, "push", "origin", "main"])
        }

        func commitCount(_ repo: URL, gitDir: Bool = false) -> Int {
            let args = gitDir ? ["--git-dir", repo.path, "log", "--oneline"] : ["-C", repo.path, "log", "--oneline"]
            let result = shell("/usr/bin/git", args)
            guard result.status == 0 else { return 0 }
            return result.stdout.split(separator: "\n").count
        }

        // `String.write(to:)` does NOT create missing parent directories (unlike
        // `ShiftYaml.writeList`, which this test deliberately doesn't go
        // through so it can write arbitrary content directly) - every write
        // below needs this or it silently no-ops and the test would wrongly
        // read that as "git saw no changes."
        func writeTaskFile(_ content: String, to url: URL) {
            try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? content.write(to: url, atomically: true, encoding: .utf8)
        }

        // Polls rather than sleeping a fixed amount - the debounced commit+
        // push runs on a real background queue against a real (if local)
        // git subprocess, and this machine's actual scheduling latency isn't
        // something this test should hardcode a guess for. Still bounded
        // (5s), so a genuine hang fails the test instead of hanging forever.
        func waitForSynced(_ sync: ShiftGitSync, timeout: TimeInterval = 5.0) {
            let deadline = Date().addingTimeInterval(timeout)
            while sync.status != .synced && Date() < deadline {
                Thread.sleep(forTimeInterval: 0.05)
            }
        }

        // MARK: 1. Instant local write, independent of network - simulate
        // network unavailable via a remote URL that can never be reached.

        do {
            let wt = scratch.appendingPathComponent("wt-offline", isDirectory: true)
            let sync = ShiftGitSync(
                workingTree: wt, remoteURL: "https://127.0.0.1.invalid/does-not-exist/repo.git",
                debounceInterval: 0.2, periodicPullInterval: 999_999
            )
            let ok = sync.ensureWorkingTreeNow()
            check(!ok, "ensureWorkingTreeNow should report failure when the remote is unreachable")
            if case .failed = sync.status {} else { failures.append("status should be .failed after an unreachable clone, got \(sync.status)") }
            check(fm.fileExists(atPath: sync.dataRoot.path), "dataRoot should exist locally even when the initial clone fails (offline-first)")

            let start = Date()
            let taskFile = sync.dataRoot.appendingPathComponent("tasks/active.yaml")
            try? fm.createDirectory(at: taskFile.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? "tasks: []\n".write(to: taskFile, atomically: true, encoding: .utf8)
            let elapsed = Date().timeIntervalSince(start)
            check(elapsed < 0.5, "local YAML write should be instant regardless of network state, took \(elapsed)s")
            check((try? String(contentsOf: taskFile, encoding: .utf8)) == "tasks: []\n", "local write should have actually landed on disk")
        }

        // MARK: 2. Real commit+push reaches a real disposable remote.

        var pushedRemote: URL!
        var pushedWT: URL!
        do {
            let remote = makeBareRemote(name: "remote-push")
            seedRemote(remote)
            let wt = scratch.appendingPathComponent("wt-push", isDirectory: true)
            let sync = ShiftGitSync(workingTree: wt, remoteURL: remote.path, debounceInterval: 0.2, periodicPullInterval: 999_999)
            check(sync.ensureWorkingTreeNow(), "ensureWorkingTreeNow should succeed cloning a real local bare remote")
            check(sync.status == .synced, "status should be .synced right after a clean clone, got \(sync.status)")

            let before = commitCount(remote, gitDir: true)
            let taskFile = sync.dataRoot.appendingPathComponent("tasks/active.yaml")
            writeTaskFile("tasks:\n  - id: t1\n", to: taskFile)
            sync.markDirty()
            check(sync.status == .localChanges, "status should flip to .localChanges immediately on markDirty(), before any commit runs")
            waitForSynced(sync)
            check(sync.status == .synced, "status should settle back to .synced once the debounced commit+push completes, got \(sync.status)")
            let after = commitCount(remote, gitDir: true)
            check(after == before + 1, "exactly one new commit should have reached the remote, before=\(before) after=\(after)")

            pushedRemote = remote
            pushedWT = wt
        }

        // MARK: 3. Debounce actually batches several rapid edits into one
        // commit, not one commit per edit.

        do {
            let remote = makeBareRemote(name: "remote-batch")
            seedRemote(remote)
            let wt = scratch.appendingPathComponent("wt-batch", isDirectory: true)
            let sync = ShiftGitSync(workingTree: wt, remoteURL: remote.path, debounceInterval: 0.5, periodicPullInterval: 999_999)
            check(sync.ensureWorkingTreeNow(), "ensureWorkingTreeNow should succeed for the batching scenario")
            let before = commitCount(remote, gitDir: true)

            let taskFile = sync.dataRoot.appendingPathComponent("tasks/active.yaml")
            for i in 0..<5 {
                writeTaskFile("tasks:\n  - id: t\(i)\n", to: taskFile)
                sync.markDirty()
                Thread.sleep(forTimeInterval: 0.1)  // well under the 0.5s debounce window
            }
            check(sync.status == .localChanges, "status should still be .localChanges immediately after the last rapid edit")
            waitForSynced(sync)
            check(sync.status == .synced, "status should settle to .synced once the single batched commit+push completes, got \(sync.status)")
            let after = commitCount(remote, gitDir: true)
            check(after == before + 1, "5 rapid edits within the debounce window should produce exactly 1 commit, before=\(before) after=\(after)")
        }

        // MARK: 4. A real pull (via a second clone pushing new content)
        // brings changes back into the app.

        do {
            let remote = makeBareRemote(name: "remote-pull")
            seedRemote(remote)

            // "Machine B" clones first, at the seed state - before A pushes
            // anything - so it genuinely has an older history to pull.
            let wtB = scratch.appendingPathComponent("wt-pull-b", isDirectory: true)
            let syncB = ShiftGitSync(workingTree: wtB, remoteURL: remote.path, debounceInterval: 0.2, periodicPullInterval: 999_999)
            check(syncB.ensureWorkingTreeNow(), "machine B should clone successfully")
            let bTaskFileBefore = try? String(contentsOf: syncB.dataRoot.appendingPathComponent("tasks/active.yaml"), encoding: .utf8)
            check((bTaskFileBefore ?? "").contains("from-machine-a") == false, "machine B should not see A's change before A has even pushed it")

            // "Machine A": clones after B, then pushes a new task.
            let wtA = scratch.appendingPathComponent("wt-pull-a", isDirectory: true)
            let syncA = ShiftGitSync(workingTree: wtA, remoteURL: remote.path, debounceInterval: 0.2, periodicPullInterval: 999_999)
            check(syncA.ensureWorkingTreeNow(), "machine A should clone successfully")
            let taskFile = syncA.dataRoot.appendingPathComponent("tasks/active.yaml")
            writeTaskFile("tasks:\n  - id: from-machine-a\n", to: taskFile)
            syncA.markDirty()
            waitForSynced(syncA)
            check(syncA.status == .synced, "machine A should reach .synced after pushing, got \(syncA.status)")

            // Now B pulls and should see A's change.
            let outcome = syncB.pullNow()
            check(outcome == .fastForwarded, "pullNow() should fast-forward cleanly, got \(outcome)")
            check(syncB.status == .synced, "machine B should be .synced after a clean pull with no local edits")
            let bTaskFileAfter = try? String(contentsOf: syncB.dataRoot.appendingPathComponent("tasks/active.yaml"), encoding: .utf8)
            check((bTaskFileAfter ?? "").contains("from-machine-a"), "machine B's local file should contain A's change after pulling")
        }

        // MARK: 5. A forced failure (unreachable remote after a successful
        // clone) shows "Failed" without losing the local edit - the commit
        // already landed locally, only the push failed.

        if let remote = pushedRemote, let wt = pushedWT {
            let sync = ShiftGitSync(workingTree: wt, remoteURL: remote.path, debounceInterval: 0.2, periodicPullInterval: 999_999)
            // Simulate "remote became unreachable" by deleting the bare repo
            // out from under an already-cloned working tree - a real push
            // will now fail exactly like a network drop or revoked auth
            // would, without this test needing real network conditions.
            try? fm.removeItem(at: remote)

            let localCommitsBefore = commitCount(wt)
            let taskFile = sync.dataRoot.appendingPathComponent("tasks/active.yaml")
            writeTaskFile("tasks:\n  - id: will-fail-to-push\n", to: taskFile)
            let committed = sync.commitAndPushNow()
            check(!committed, "commitAndPushNow() should report failure when the remote has vanished")
            if case .failed = sync.status {} else { failures.append("status should be .failed after a push failure, got \(sync.status)") }
            let localCommitsAfter = commitCount(wt)
            check(localCommitsAfter == localCommitsBefore + 1, "the local commit should still exist even though the push failed - no data loss")
            let onDisk = try? String(contentsOf: taskFile, encoding: .utf8)
            check(onDisk?.contains("will-fail-to-push") == true, "the local file itself must be untouched by the failed push")
        }

        // MARK: 6. Non-fast-forward (diverged) history stops safely - no
        // force, no data loss, clear "Failed" status.

        do {
            let remote = makeBareRemote(name: "remote-diverge")
            seedRemote(remote)

            let wtA = scratch.appendingPathComponent("wt-diverge-a", isDirectory: true)
            let syncA = ShiftGitSync(workingTree: wtA, remoteURL: remote.path, debounceInterval: 0.2, periodicPullInterval: 999_999)
            check(syncA.ensureWorkingTreeNow(), "diverge scenario: machine A should clone successfully")

            let wtB = scratch.appendingPathComponent("wt-diverge-b", isDirectory: true)
            let syncB = ShiftGitSync(workingTree: wtB, remoteURL: remote.path, debounceInterval: 0.2, periodicPullInterval: 999_999)
            check(syncB.ensureWorkingTreeNow(), "diverge scenario: machine B should clone successfully")

            // A pushes a change.
            let aFile = syncA.dataRoot.appendingPathComponent("tasks/active.yaml")
            writeTaskFile("tasks:\n  - id: from-a\n", to: aFile)
            syncA.markDirty()
            waitForSynced(syncA)
            check(syncA.status == .synced, "diverge scenario: A should push its change cleanly, got \(syncA.status)")

            // B, without pulling first, makes its own local commit -
            // genuine divergence from origin once B tries to sync.
            let bFile = syncB.dataRoot.appendingPathComponent("tasks/active.yaml")
            writeTaskFile("tasks:\n  - id: from-b\n", to: bFile)
            _ = shell("/usr/bin/git", ["-C", wtB.path, "add", "-A", "--", "GrandLineDocs/personal-tasks"])
            _ = shell("/usr/bin/git", ["-C", wtB.path, "-c", "user.email=test@example.com", "-c", "user.name=Shift Test", "commit", "-m", "B's own local commit"])

            let bCommitsBefore = commitCount(wtB)
            let outcome = syncB.pullNow()
            check(outcome == .diverged, "pullNow() should report .diverged, got \(outcome)")
            if case .failed = syncB.status {} else { failures.append("status should be .failed on divergence, got \(syncB.status)") }
            let bCommitsAfter = commitCount(wtB)
            check(bCommitsBefore == bCommitsAfter, "a diverged pull must not add, drop, or rewrite any local commit")
            let bContent = try? String(contentsOf: bFile, encoding: .utf8)
            check(bContent?.contains("from-b") == true, "B's own local edit must survive a diverged pull untouched")
        }

        // MARK: 7. Repo-layout migration (fm/grandline-docs-knowledge-
        // foundation): a remote still on the OLD top-level `personal-tasks/`
        // layout gets `git mv`'d to `GrandLineDocs/personal-tasks/` on first
        // clone, with zero data loss, and never re-fires on a later clone.

        do {
            let remote = makeBareRemote(name: "remote-layout-migration")
            // Seed with the OLD layout directly (not via seedRemote, which
            // already seeds the NEW layout) - real task content, not just a
            // `.keep` file, to prove zero data loss.
            let seedDir = scratch.appendingPathComponent("seed-old-layout-\(UUID().uuidString)", isDirectory: true)
            _ = shell("/usr/bin/git", ["clone", remote.path, seedDir.path])
            let oldTasks = seedDir.appendingPathComponent("personal-tasks", isDirectory: true)
            writeTaskFile("tasks:\n  - id: pre-migration-task\n    title: \"Survives the move\"\n", to: oldTasks.appendingPathComponent("tasks/active.yaml"))
            writeTaskFile("follow_ups: []\n", to: oldTasks.appendingPathComponent("follow-ups/follow-ups.yaml"))
            _ = shell("/usr/bin/git", ["-C", seedDir.path, "add", "-A"])
            _ = shell("/usr/bin/git", ["-C", seedDir.path, "-c", "user.email=test@example.com", "-c", "user.name=Shift Test", "commit", "-m", "seed old layout"])
            _ = shell("/usr/bin/git", ["-C", seedDir.path, "push", "origin", "main"])

            let wt = scratch.appendingPathComponent("wt-layout-migration", isDirectory: true)
            let sync = ShiftGitSync(workingTree: wt, remoteURL: remote.path, debounceInterval: 0.2, periodicPullInterval: 999_999)
            check(sync.ensureWorkingTreeNow(), "layout migration: clone of an old-layout remote should still succeed")
            waitForSynced(sync)
            check(fm.fileExists(atPath: wt.appendingPathComponent("GrandLineDocs/personal-tasks/tasks/active.yaml").path),
                  "layout migration: data should now live at GrandLineDocs/personal-tasks/ locally")
            check(!fm.fileExists(atPath: wt.appendingPathComponent("personal-tasks").path),
                  "layout migration: the old top-level personal-tasks/ should be gone after git mv")
            let movedContent = try? String(contentsOf: sync.dataRoot.appendingPathComponent("tasks/active.yaml"), encoding: .utf8)
            check(movedContent?.contains("pre-migration-task") == true, "layout migration: the real task content must survive the move with zero loss")

            // Confirm the move landed on the remote too (re-clone fresh).
            let freshClone = scratch.appendingPathComponent("fresh-after-layout-migration", isDirectory: true)
            _ = shell("/usr/bin/git", ["clone", remote.path, freshClone.path])
            check(fm.fileExists(atPath: freshClone.appendingPathComponent("GrandLineDocs/personal-tasks/tasks/active.yaml").path),
                  "layout migration: the move must have been pushed to the remote, not just applied locally")
            check(!fm.fileExists(atPath: freshClone.appendingPathComponent("personal-tasks").path),
                  "layout migration: a fresh clone from the remote should never see the old top-level folder again")

            // A second client cloning after the migration must NOT re-migrate
            // or duplicate anything - it should just see the new layout.
            let wt2 = scratch.appendingPathComponent("wt-layout-migration-second-client", isDirectory: true)
            let sync2 = ShiftGitSync(workingTree: wt2, remoteURL: remote.path, debounceInterval: 0.2, periodicPullInterval: 999_999)
            check(sync2.ensureWorkingTreeNow(), "layout migration: a second client cloning post-migration should succeed normally")
            waitForSynced(sync2)
            check(sync2.status == .synced, "layout migration: a second client's clone should settle to .synced with no further migration commit, got \(sync2.status)")
            let secondClientContent = try? String(contentsOf: sync2.dataRoot.appendingPathComponent("tasks/active.yaml"), encoding: .utf8)
            check(secondClientContent?.contains("pre-migration-task") == true, "layout migration: a second client should see the already-migrated data intact")
        }

        // MARK: 8. Repo-layout migration must not nest when the NEW dataRoot
        // path already exists (e.g. a lone file salvaged there by
        // `ShiftStore.init()`'s own premature-write race, documented in
        // `ensureWorkingTreeNow`, landing before this migration runs) - a
        // real bug this migration's own live verification against a
        // disposable repo caught: a naive `git mv personal-tasks
        // GrandLineDocs/personal-tasks` nests the whole old folder one level
        // too deep (`GrandLineDocs/personal-tasks/personal-tasks/...`)
        // whenever the destination directory already exists.

        do {
            let remote = makeBareRemote(name: "remote-layout-migration-race")
            let seedDir = scratch.appendingPathComponent("seed-old-layout-race-\(UUID().uuidString)", isDirectory: true)
            _ = shell("/usr/bin/git", ["clone", remote.path, seedDir.path])
            let oldTasks = seedDir.appendingPathComponent("personal-tasks", isDirectory: true)
            writeTaskFile("tasks:\n  - id: race-task\n    title: \"Survives a raced destination\"\n", to: oldTasks.appendingPathComponent("tasks/active.yaml"))
            _ = shell("/usr/bin/git", ["-C", seedDir.path, "add", "-A"])
            _ = shell("/usr/bin/git", ["-C", seedDir.path, "-c", "user.email=test@example.com", "-c", "user.name=Shift Test", "commit", "-m", "seed old layout"])
            _ = shell("/usr/bin/git", ["-C", seedDir.path, "push", "origin", "main"])

            let wt = scratch.appendingPathComponent("wt-layout-migration-race", isDirectory: true)
            let sync = ShiftGitSync(workingTree: wt, remoteURL: remote.path, debounceInterval: 0.2, periodicPullInterval: 999_999)
            // Simulate the exact race: a lone `settings.yaml` already sitting
            // at the NEW dataRoot path, on disk, before `ensureWorkingTreeNow()`
            // (and therefore the migration inside it) ever runs - exactly
            // what `ShiftStore.init()`'s premature write can produce.
            writeTaskFile("captain: \"test\"\n", to: sync.dataRoot.appendingPathComponent("settings.yaml"))

            check(sync.ensureWorkingTreeNow(), "raced-destination migration: clone should still succeed")
            waitForSynced(sync)
            check(fm.fileExists(atPath: sync.dataRoot.appendingPathComponent("tasks/active.yaml").path),
                  "raced-destination migration: the real task data should land directly at GrandLineDocs/personal-tasks/, not nested")
            check(!fm.fileExists(atPath: wt.appendingPathComponent("GrandLineDocs/personal-tasks/personal-tasks").path),
                  "raced-destination migration: must never produce a nested GrandLineDocs/personal-tasks/personal-tasks/ folder")
            check(!fm.fileExists(atPath: wt.appendingPathComponent("personal-tasks").path),
                  "raced-destination migration: the old top-level personal-tasks/ should be gone")
            let content = try? String(contentsOf: sync.dataRoot.appendingPathComponent("tasks/active.yaml"), encoding: .utf8)
            check(content?.contains("race-task") == true, "raced-destination migration: the real task content must survive with zero loss")
            let settingsContent = try? String(contentsOf: sync.dataRoot.appendingPathComponent("settings.yaml"), encoding: .utf8)
            check(settingsContent?.contains("captain") == true, "raced-destination migration: the pre-existing salvaged file at the new path must also survive, untouched")

            let freshClone = scratch.appendingPathComponent("fresh-after-layout-migration-race", isDirectory: true)
            _ = shell("/usr/bin/git", ["clone", remote.path, freshClone.path])
            check(fm.fileExists(atPath: freshClone.appendingPathComponent("GrandLineDocs/personal-tasks/tasks/active.yaml").path),
                  "raced-destination migration: the (non-nested) move must have been pushed to the remote")
            check(!fm.fileExists(atPath: freshClone.appendingPathComponent("GrandLineDocs/personal-tasks/personal-tasks").path),
                  "raced-destination migration: the remote itself must not carry a nested folder either")
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
