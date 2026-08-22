// Manjesh Grand Line - native macOS app.
//
// Permanent self-test for conflict detection and resolution
// (cockpit-shift-conflict-handling, phase 6 - the last queued phase of the
// Shift build), run via `FM_RUN_SHIFT_CONFLICT_TESTS=1
// .build/debug/FirstmateCockpit` - same convention as
// `ShiftGitSyncSelfTest.swift`, which this deliberately extends rather than
// duplicates: every scenario here builds on the exact same "two disposable
// local bare-repo clones simulating two machines" setup that file already
// established, just carried one step further into `detectAndResolveConflicts`/
// `resolveConflicts` instead of stopping at `.diverged`.
//
// Every repo here is real and disposable, created fresh under a scratch temp
// directory - never the captain's real `manjesh-config` - matching phase 4's
// own safety approach, restated in the task brief for this phase.

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

enum ShiftConflictSelfTest {
    static func run() -> Bool {
        var failures: [String] = []
        func check(_ condition: Bool, _ message: String) {
            if !condition { failures.append(message) }
        }
        func finish() -> Bool {
            if !failures.isEmpty {
                for f in failures { FileHandle.standardError.write(Data(("FAIL: " + f + "\n").utf8)) }
            }
            return failures.isEmpty
        }

        let fm = FileManager.default
        let scratch = fm.temporaryDirectory.appendingPathComponent("shift-conflict-selftest-\(UUID().uuidString)", isDirectory: true)
        try? fm.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: scratch) }

        func makeBareRemote(name: String) -> URL {
            let path = scratch.appendingPathComponent(name, isDirectory: true)
            _ = shell("/usr/bin/git", ["init", "--bare", "-b", "main", path.path])
            return path
        }

        // Seeds the remote with one real task (so both "machines" start from
        // a shared, non-empty base - the case that actually matters, since
        // an empty base can't demonstrate an edited-on-both-sides conflict).
        func seedRemoteWithTask(_ remote: URL, id: String, title: String) {
            let seedDir = scratch.appendingPathComponent("seed-\(UUID().uuidString)", isDirectory: true)
            _ = shell("/usr/bin/git", ["clone", remote.path, seedDir.path])
            let taskFile = seedDir.appendingPathComponent("GrandLineDocs/personal-tasks/tasks/active.yaml")
            try? fm.createDirectory(at: taskFile.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? writeTaskYaml([ShiftTask(
                id: id, title: title, description: "", status: .todo, priority: .normal,
                dueDate: nil, dueTime: nil, projectID: nil, tags: [], createdAt: "2026-01-01T00:00:00Z",
                updatedAt: "2026-01-01T00:00:00Z", completedAt: nil, notes: nil, subtasks: [], hasAttachment: false
            )], to: taskFile)
            _ = shell("/usr/bin/git", ["-C", seedDir.path, "add", "-A"])
            _ = shell("/usr/bin/git", ["-C", seedDir.path, "-c", "user.email=test@example.com", "-c", "user.name=Shift Test", "commit", "-m", "seed"])
            _ = shell("/usr/bin/git", ["-C", seedDir.path, "push", "origin", "main"])
        }

        func writeTaskYaml(_ tasks: [ShiftTask], to url: URL) throws {
            try ShiftYaml.writeList(path: url.path, key: "tasks", items: tasks.map(ShiftYaml.toYaml))
        }

        func readTasks(_ url: URL) -> [ShiftTask] {
            ShiftYaml.readList(path: url.path, key: "tasks").compactMap(ShiftYaml.task(from:))
        }

        // MARK: 1. Same task edited differently on two machines is detected
        // as a real, specific conflict - not just "Failed" - and each
        // resolution path (keep local / keep remote) produces the correct
        // final YAML, verified by reloading afterward.

        do {
            let remote = makeBareRemote(name: "remote-conflict")
            seedRemoteWithTask(remote, id: "shared-task", title: "Original title")

            let wtA = scratch.appendingPathComponent("wt-conflict-a", isDirectory: true)
            let syncA = ShiftGitSync(workingTree: wtA, remoteURL: remote.path, debounceInterval: 0.2, periodicPullInterval: 999_999)
            check(syncA.ensureWorkingTreeNow(), "conflict scenario: machine A should clone successfully")

            let wtB = scratch.appendingPathComponent("wt-conflict-b", isDirectory: true)
            let syncB = ShiftGitSync(workingTree: wtB, remoteURL: remote.path, debounceInterval: 0.2, periodicPullInterval: 999_999)
            check(syncB.ensureWorkingTreeNow(), "conflict scenario: machine B should clone successfully")

            // A edits the task's title and pushes.
            let aFile = syncA.dataRoot.appendingPathComponent("tasks/active.yaml")
            var aTasks = readTasks(aFile)
            aTasks[0].title = "Title edited on A"
            try? writeTaskYaml(aTasks, to: aFile)
            syncA.markDirty()
            let deadlineA = Date().addingTimeInterval(5)
            while syncA.status != .synced && Date() < deadlineA { Thread.sleep(forTimeInterval: 0.05) }
            check(syncA.status == .synced, "conflict scenario: A should push its title edit cleanly, got \(syncA.status)")

            // B, without pulling first, edits the SAME task's title
            // differently and commits locally (not pushed - B doesn't know
            // about A's push yet).
            let bFile = syncB.dataRoot.appendingPathComponent("tasks/active.yaml")
            var bTasks = readTasks(bFile)
            bTasks[0].title = "Title edited on B"
            try? writeTaskYaml(bTasks, to: bFile)
            _ = shell("/usr/bin/git", ["-C", wtB.path, "add", "-A", "--", "GrandLineDocs/personal-tasks"])
            _ = shell("/usr/bin/git", ["-C", wtB.path, "-c", "user.email=test@example.com", "-c", "user.name=Shift Test", "commit", "-m", "B's title edit"])

            let pullOutcome = syncB.pullNow()
            check(pullOutcome == .diverged, "conflict scenario: pullNow() should report .diverged, got \(pullOutcome)")

            let resolutionOutcome = syncB.detectAndResolveConflicts()
            check(resolutionOutcome == .needsResolution, "conflict scenario: detectAndResolveConflicts() should report .needsResolution for a genuine same-record edit, got \(resolutionOutcome)")
            if case .conflict(let fileCount) = syncB.status {
                check(fileCount == 1, "conflict scenario: exactly one file (tasks) should be reported as affected, got \(fileCount)")
            } else {
                failures.append("conflict scenario: status should be .conflict after detection, got \(syncB.status)")
            }

            guard let set = syncB.pendingConflictSet else {
                failures.append("conflict scenario: pendingConflictSet should be populated")
                return finish()
            }
            check(set.taskConflicts.count == 1, "conflict scenario: exactly one task conflict should be found, got \(set.taskConflicts.count)")
            if let conflict = set.taskConflicts.first {
                check(conflict.local?.title == "Title edited on B", "conflict scenario: local side should be B's own edit")
                check(conflict.remote?.title == "Title edited on A", "conflict scenario: remote side should be A's pushed edit")
                let titleDiff = conflict.fieldDiffs.first(where: { $0.field == "Title" })
                check(titleDiff?.local == "Title edited on B" && titleDiff?.remote == "Title edited on A", "conflict scenario: field-level diff should surface the Title field specifically")
            }

            // Resolve by keeping remote (A's version) - verify by reloading
            // from a completely fresh ShiftGitSync instance against the same
            // working tree, not just the in-memory conflict set.
            let conflictID = set.taskConflicts.first?.id ?? ""
            let resolved = syncB.resolveConflicts(choices: [conflictID: .keepRemote])
            check(resolved, "conflict scenario: resolveConflicts(keepRemote) should succeed")
            check(syncB.status == .synced, "conflict scenario: status should return to .synced after a successful resolution, got \(syncB.status)")
            check(syncB.pendingConflictSet == nil, "conflict scenario: pendingConflictSet should be cleared after resolution")

            let reloadedAfterRemote = readTasks(syncB.dataRoot.appendingPathComponent("tasks/active.yaml"))
            check(reloadedAfterRemote.first?.title == "Title edited on A", "conflict scenario (keep remote): the on-disk file should reflect A's title after reload")

            // Verify the resolution actually reached the remote by cloning
            // fresh from it - a real push, not just a local commit.
            let freshCheck = scratch.appendingPathComponent("wt-conflict-freshcheck", isDirectory: true)
            _ = shell("/usr/bin/git", ["clone", remote.path, freshCheck.path])
            let freshTasks = readTasks(freshCheck.appendingPathComponent("GrandLineDocs/personal-tasks/tasks/active.yaml"))
            check(freshTasks.first?.title == "Title edited on A", "conflict scenario: the pushed remote should reflect the resolution too")
        }

        // MARK: 2. Two different tasks added on each side with no
        // overlapping ids auto-merge with no captain interaction at all.

        do {
            let remote = makeBareRemote(name: "remote-automerge")
            seedRemoteWithTask(remote, id: "base-task", title: "Base task")

            let wtA = scratch.appendingPathComponent("wt-automerge-a", isDirectory: true)
            let syncA = ShiftGitSync(workingTree: wtA, remoteURL: remote.path, debounceInterval: 0.2, periodicPullInterval: 999_999)
            check(syncA.ensureWorkingTreeNow(), "auto-merge scenario: machine A should clone successfully")

            let wtB = scratch.appendingPathComponent("wt-automerge-b", isDirectory: true)
            let syncB = ShiftGitSync(workingTree: wtB, remoteURL: remote.path, debounceInterval: 0.2, periodicPullInterval: 999_999)
            check(syncB.ensureWorkingTreeNow(), "auto-merge scenario: machine B should clone successfully")

            // A adds a brand-new task (distinct id) and pushes.
            let aFile = syncA.dataRoot.appendingPathComponent("tasks/active.yaml")
            var aTasks = readTasks(aFile)
            aTasks.append(ShiftTask(
                id: "added-by-a", title: "Added on A", description: "", status: .todo, priority: .normal,
                dueDate: nil, dueTime: nil, projectID: nil, tags: [], createdAt: "2026-01-02T00:00:00Z",
                updatedAt: "2026-01-02T00:00:00Z", completedAt: nil, notes: nil, subtasks: [], hasAttachment: false
            ))
            try? writeTaskYaml(aTasks, to: aFile)
            syncA.markDirty()
            let deadlineA = Date().addingTimeInterval(5)
            while syncA.status != .synced && Date() < deadlineA { Thread.sleep(forTimeInterval: 0.05) }
            check(syncA.status == .synced, "auto-merge scenario: A should push its addition cleanly, got \(syncA.status)")

            // B, without pulling, adds a DIFFERENT brand-new task (a
            // different distinct id) and commits locally.
            let bFile = syncB.dataRoot.appendingPathComponent("tasks/active.yaml")
            var bTasks = readTasks(bFile)
            bTasks.append(ShiftTask(
                id: "added-by-b", title: "Added on B", description: "", status: .todo, priority: .normal,
                dueDate: nil, dueTime: nil, projectID: nil, tags: [], createdAt: "2026-01-02T00:00:00Z",
                updatedAt: "2026-01-02T00:00:00Z", completedAt: nil, notes: nil, subtasks: [], hasAttachment: false
            ))
            try? writeTaskYaml(bTasks, to: bFile)
            _ = shell("/usr/bin/git", ["-C", wtB.path, "add", "-A", "--", "GrandLineDocs/personal-tasks"])
            _ = shell("/usr/bin/git", ["-C", wtB.path, "-c", "user.email=test@example.com", "-c", "user.name=Shift Test", "commit", "-m", "B's addition"])

            let pullOutcome = syncB.pullNow()
            check(pullOutcome == .diverged, "auto-merge scenario: pullNow() should report .diverged before resolution, got \(pullOutcome)")

            let resolutionOutcome = syncB.detectAndResolveConflicts()
            if case .autoMerged(let recordCount) = resolutionOutcome {
                check(recordCount >= 2, "auto-merge scenario: at least both additions should be reported as auto-merged, got \(recordCount)")
            } else {
                failures.append("auto-merge scenario: two distinct-id additions should auto-merge with no captain interaction, got \(resolutionOutcome)")
            }
            check(syncB.status == .synced, "auto-merge scenario: status should reach .synced with no conflict UI involved, got \(syncB.status)")
            check(syncB.pendingConflictSet == nil, "auto-merge scenario: no pending conflict set should exist after a clean auto-merge")

            let merged = readTasks(syncB.dataRoot.appendingPathComponent("tasks/active.yaml"))
            let ids = Set(merged.map(\.id))
            check(ids.contains("added-by-a"), "auto-merge scenario: A's addition should be present in the merged result")
            check(ids.contains("added-by-b"), "auto-merge scenario: B's own addition should be present in the merged result")
            check(ids.contains("base-task"), "auto-merge scenario: the untouched base task should survive the merge")

            // Verify the merge actually reached the remote.
            let freshCheck = scratch.appendingPathComponent("wt-automerge-freshcheck", isDirectory: true)
            _ = shell("/usr/bin/git", ["clone", remote.path, freshCheck.path])
            let freshIDs = Set(readTasks(freshCheck.appendingPathComponent("GrandLineDocs/personal-tasks/tasks/active.yaml")).map(\.id))
            check(freshIDs.isSuperset(of: ["added-by-a", "added-by-b", "base-task"]), "auto-merge scenario: the pushed remote should contain every record from both sides")
        }

        // MARK: 3. "Keep local" resolution path (the mirror of scenario 1's
        // "keep remote" path) - verified independently rather than assumed
        // symmetric.

        do {
            let remote = makeBareRemote(name: "remote-keeplocal")
            seedRemoteWithTask(remote, id: "shared-task-2", title: "Original title 2")

            let wtA = scratch.appendingPathComponent("wt-keeplocal-a", isDirectory: true)
            let syncA = ShiftGitSync(workingTree: wtA, remoteURL: remote.path, debounceInterval: 0.2, periodicPullInterval: 999_999)
            check(syncA.ensureWorkingTreeNow(), "keep-local scenario: machine A should clone successfully")

            let wtB = scratch.appendingPathComponent("wt-keeplocal-b", isDirectory: true)
            let syncB = ShiftGitSync(workingTree: wtB, remoteURL: remote.path, debounceInterval: 0.2, periodicPullInterval: 999_999)
            check(syncB.ensureWorkingTreeNow(), "keep-local scenario: machine B should clone successfully")

            let aFile = syncA.dataRoot.appendingPathComponent("tasks/active.yaml")
            var aTasks = readTasks(aFile)
            aTasks[0].priority = .high
            try? writeTaskYaml(aTasks, to: aFile)
            syncA.markDirty()
            let deadlineA = Date().addingTimeInterval(5)
            while syncA.status != .synced && Date() < deadlineA { Thread.sleep(forTimeInterval: 0.05) }
            check(syncA.status == .synced, "keep-local scenario: A should push its priority edit cleanly, got \(syncA.status)")

            let bFile = syncB.dataRoot.appendingPathComponent("tasks/active.yaml")
            var bTasks = readTasks(bFile)
            bTasks[0].priority = .low
            bTasks[0].notes = "B's own note"
            try? writeTaskYaml(bTasks, to: bFile)
            _ = shell("/usr/bin/git", ["-C", wtB.path, "add", "-A", "--", "GrandLineDocs/personal-tasks"])
            _ = shell("/usr/bin/git", ["-C", wtB.path, "-c", "user.email=test@example.com", "-c", "user.name=Shift Test", "commit", "-m", "B's priority edit"])

            _ = syncB.pullNow()
            let outcome = syncB.detectAndResolveConflicts()
            check(outcome == .needsResolution, "keep-local scenario: should need resolution, got \(outcome)")
            guard let conflictID = syncB.pendingConflictSet?.taskConflicts.first?.id else {
                failures.append("keep-local scenario: expected a task conflict")
                return finish()
            }
            check(syncB.resolveConflicts(choices: [conflictID: .keepLocal]), "keep-local scenario: resolveConflicts(keepLocal) should succeed")
            check(syncB.status == .synced, "keep-local scenario: status should return to .synced, got \(syncB.status)")

            let reloaded = readTasks(syncB.dataRoot.appendingPathComponent("tasks/active.yaml"))
            check(reloaded.first?.priority == .low, "keep-local scenario: on-disk priority should be B's own (low), not A's (high)")
            check(reloaded.first?.notes == "B's own note", "keep-local scenario: on-disk notes should be B's own note")
        }

        // MARK: 4. Ordinary non-conflicting sync (the common case, phase 4's
        // own happy path) - no regression. A clean fast-forward pull still
        // works exactly as before, with no conflict machinery involved.

        do {
            let remote = makeBareRemote(name: "remote-happy-path")
            seedRemoteWithTask(remote, id: "happy-task", title: "Happy path task")

            let wtA = scratch.appendingPathComponent("wt-happy-a", isDirectory: true)
            let syncA = ShiftGitSync(workingTree: wtA, remoteURL: remote.path, debounceInterval: 0.2, periodicPullInterval: 999_999)
            check(syncA.ensureWorkingTreeNow(), "happy-path scenario: machine A should clone successfully")

            let wtB = scratch.appendingPathComponent("wt-happy-b", isDirectory: true)
            let syncB = ShiftGitSync(workingTree: wtB, remoteURL: remote.path, debounceInterval: 0.2, periodicPullInterval: 999_999)
            check(syncB.ensureWorkingTreeNow(), "happy-path scenario: machine B should clone successfully")

            // B pulls first (nothing new yet) so it has no local commits of
            // its own, then A pushes a real change - a genuine, ordinary
            // fast-forward case with no divergence at all.
            check(syncB.pullNow() == .upToDate, "happy-path scenario: B's first pull should be up to date")

            let aFile = syncA.dataRoot.appendingPathComponent("tasks/active.yaml")
            var aTasks = readTasks(aFile)
            aTasks[0].title = "Updated via the ordinary path"
            try? writeTaskYaml(aTasks, to: aFile)
            syncA.markDirty()
            let deadlineA = Date().addingTimeInterval(5)
            while syncA.status != .synced && Date() < deadlineA { Thread.sleep(forTimeInterval: 0.05) }
            check(syncA.status == .synced, "happy-path scenario: A should push cleanly, got \(syncA.status)")

            let outcome = syncB.pullNow()
            check(outcome == .fastForwarded, "happy-path scenario: B's second pull should fast-forward cleanly with no conflict machinery involved, got \(outcome)")
            check(syncB.status == .synced, "happy-path scenario: status should be .synced after a clean fast-forward, got \(syncB.status)")
            check(syncB.pendingConflictSet == nil, "happy-path scenario: no conflict set should ever exist for a clean fast-forward")
            let reloaded = readTasks(syncB.dataRoot.appendingPathComponent("tasks/active.yaml"))
            check(reloaded.first?.title == "Updated via the ordinary path", "happy-path scenario: B should see A's update after the fast-forward")
        }

        return finish()
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
