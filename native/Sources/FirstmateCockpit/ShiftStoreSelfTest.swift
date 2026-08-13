// Manjesh Grand Line - native macOS app.
//
// Permanent self-test for `ShiftStore`/`ShiftYaml` (cockpit-shift-foundation),
// run via `FM_RUN_SHIFT_STORE_TESTS=1 .build/debug/FirstmateCockpit` - same
// convention as `YamlBeautifySelfTest.swift`/`DiffEngineSelfTest.swift` (see
// main.swift's gate list). Runs against a real scratch directory (never the
// captain's real `FM_SHIFT_DIR`), so every assertion here is a real disk
// read/write, not an in-memory-only check - the acceptance bar this phase
// was built against explicitly rules out "trust that a write call was made".
//
// Covers: a task's completion genuinely moving out of `active.yaml` into the
// correct month's `completed/<YYYY-MM>.yaml` file (and back, on reopen);
// state surviving a real store reload (`reloadAll()`, the same read path a
// relaunch takes); a subtask toggle persisting; and that a scalar value which
// looks like a YAML reserved word (a task titled "true", a tag "123") comes
// back as a real string, not silently coerced to a bool/int by a beautify-
// style rewrite - the same class of bug `fm/cockpit-tools-yaml-quotes-diff-perf`
// found on the Tools page's YAML Beautify action, checked here because this
// file's writer reuses that same `YamlBeautify.dump` path (see
// `ShiftYaml.swift`'s header) and the brief called for checking this
// transfers rather than assuming it does.

import Foundation
import Yaml

enum ShiftStoreSelfTest {
    static func run() -> Bool {
        var failures: [String] = []

        func check(_ condition: Bool, _ message: String) {
            if !condition { failures.append(message) }
        }

        let scratchRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("shift-selftest-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: scratchRoot) }

        setenv("FM_SHIFT_DIR", scratchRoot.path, 1)
        defer { unsetenv("FM_SHIFT_DIR") }

        // MARK: Seed + reload round trip

        let store = ShiftStore()
        store.seedIfEmpty()
        check(store.activeTasks.count == 2, "seed should create 2 active tasks, got \(store.activeTasks.count)")
        check(store.followUps.count == 1, "seed should create 1 follow-up, got \(store.followUps.count)")
        check(store.projects.count == 1, "seed should create 1 project, got \(store.projects.count)")

        let taskWithSubtasks = store.activeTasks.first { !$0.subtasks.isEmpty }
        check(taskWithSubtasks != nil, "seed should include a task with subtasks")
        check(taskWithSubtasks?.subtasks.count == 2, "seeded task should have 2 subtasks")

        // Reload from disk (the same path a relaunch takes) and confirm the
        // in-memory state actually came from the files, not just survived
        // because nothing touched it.
        let reloaded = ShiftStore()
        check(reloaded.activeTasks.count == 2, "reload should still see 2 active tasks")
        check(reloaded.activeTasks.map(\.id).sorted() == store.activeTasks.map(\.id).sorted(), "reloaded task ids should match")

        // MARK: Completion moves the task, not just a status flag

        guard let targetID = store.activeTasks.first?.id else {
            return report(failures + ["no active task to complete"])
        }
        let augFirst = ShiftStoreSelfTest.date(year: 2026, month: 8, day: 1)
        store.setTaskCompleted(id: targetID, completed: true, now: augFirst)
        check(!store.activeTasks.contains { $0.id == targetID }, "completed task should leave active.yaml in memory")

        let afterCompleteReload = ShiftStore()
        check(!afterCompleteReload.activeTasks.contains { $0.id == targetID }, "completed task should stay out of active.yaml after reload")
        let completedTasks = afterCompleteReload.allCompletedTasks()
        let movedTask = completedTasks.first { $0.id == targetID }
        check(movedTask != nil, "completed task should appear in a completed/<month>.yaml file")
        check(movedTask?.status == .completed, "moved task should have status completed")
        check(movedTask?.completedAt != nil, "moved task should have completed_at set")

        let augCompletedPath = scratchRoot.appendingPathComponent("tasks/completed/2026-08.yaml").path
        check(FileManager.default.fileExists(atPath: augCompletedPath), "expected tasks/completed/2026-08.yaml to exist")

        // MARK: Two different months split into two different files

        guard let secondID = afterCompleteReload.activeTasks.first?.id else {
            return report(failures + ["no second active task to complete"])
        }
        let janFirst = ShiftStoreSelfTest.date(year: 2027, month: 1, day: 15)
        afterCompleteReload.setTaskCompleted(id: secondID, completed: true, now: janFirst)
        let janCompletedPath = scratchRoot.appendingPathComponent("tasks/completed/2027-01.yaml").path
        check(FileManager.default.fileExists(atPath: janCompletedPath), "expected tasks/completed/2027-01.yaml to exist")
        check(FileManager.default.fileExists(atPath: augCompletedPath), "2026-08.yaml should still exist after a second month's completion")
        let augTasksAfter = ShiftYaml.readList(path: augCompletedPath, key: "tasks")
        check(augTasksAfter.count == 1, "2026-08.yaml should still hold exactly its own 1 task, got \(augTasksAfter.count)")

        // MARK: Reopen moves it back

        afterCompleteReload.setTaskCompleted(id: targetID, completed: false, now: augFirst)
        let afterReopenReload = ShiftStore()
        check(afterReopenReload.activeTasks.contains { $0.id == targetID }, "reopened task should be back in active.yaml after reload")
        check(!afterReopenReload.allCompletedTasks().contains { $0.id == targetID }, "reopened task should be gone from the completed files")

        // MARK: Subtask toggle persists

        if let taskID = taskWithSubtasks?.id, let subtaskID = taskWithSubtasks?.subtasks.last?.id {
            afterReopenReload.setSubtaskDone(taskID: taskID, subtaskID: subtaskID, done: true)
            let afterSubtaskReload = ShiftStore()
            let task = afterSubtaskReload.activeTasks.first { $0.id == taskID }
            check(task?.subtasks.first { $0.id == subtaskID }?.done == true, "subtask toggle should persist across reload")
        } else {
            failures.append("expected a reopened task with subtasks to toggle")
        }

        // MARK: Reserved-word-looking scalars stay strings, not coerced

        let trickyTask = ShiftTask(
            id: UUID().uuidString, title: "true", description: "no",
            status: .todo, priority: .normal, dueDate: nil, dueTime: nil, projectID: nil,
            tags: ["123", "yes"], createdAt: "2026-01-01T00:00:00Z", updatedAt: "2026-01-01T00:00:00Z",
            completedAt: nil, notes: nil, subtasks: []
        )
        let trickyPath = scratchRoot.appendingPathComponent("tricky.yaml").path
        try? ShiftYaml.writeList(path: trickyPath, key: "tasks", items: [ShiftYaml.toYaml(trickyTask)])

        guard let rawText = try? String(contentsOfFile: trickyPath, encoding: .utf8) else {
            return report(failures + ["could not read back tricky.yaml"])
        }
        check(rawText.contains("\"true\""), "title \"true\" should be written quoted, raw text was:\n\(rawText)")
        check(rawText.contains("\"123\""), "tag \"123\" should be written quoted")
        check(rawText.contains("\"no\""), "description \"no\" should be written quoted (else a stricter YAML reader could read it as false)")

        guard let doc = try? Yaml.load(rawText) else {
            return report(failures + ["could not parse tricky.yaml back"])
        }
        let firstItem = doc.dictionary?[.string("tasks")]?.array?.first
        check(firstItem?.dictionary?[.string("title")]?.string == "true", "title should decode back to the string \"true\", not a bool")
        check(firstItem?.dictionary?[.string("description")]?.string == "no", "description should decode back to the string \"no\", not a bool")
        let decodedTags = firstItem?.dictionary?[.string("tags")]?.array?.compactMap { $0.string } ?? []
        check(decodedTags.contains("123"), "tag \"123\" should decode back to a string, not an int")

        // Round-trip through our own typed decoder too, not just the raw Yaml tree.
        let decodedTask = ShiftYaml.task(from: firstItem ?? .null)
        check(decodedTask?.title == "true", "typed decode of title should be the string \"true\"")
        check(decodedTask?.tags.contains("123") == true, "typed decode of tags should include the string \"123\"")

        return report(failures)
    }

    private static func date(year: Int, month: Int, day: Int) -> Date {
        var comps = DateComponents()
        comps.year = year; comps.month = month; comps.day = day; comps.hour = 12
        return Calendar(identifier: .gregorian).date(from: comps) ?? Date()
    }

    private static func report(_ failures: [String]) -> Bool {
        if failures.isEmpty {
            print("[ShiftStoreSelfTest] all checks passed")
            return true
        }
        print("[ShiftStoreSelfTest] \(failures.count) failure(s):")
        for f in failures { print("  - \(f)") }
        return false
    }
}
