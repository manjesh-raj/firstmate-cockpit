// Manjesh Grand Line - native macOS app.
//
// Shift's local data layer (cockpit-shift-foundation, phase 1). Backed by
// batched YAML files under a captain-configurable root - see AGENTS.md's
// "Shift" section for the full directory layout and which phases still own
// Git sync / creation / editing / search. This phase's store only needs to:
// load `tasks/active.yaml` and `follow-ups/follow-ups.yaml` into memory,
// persist a status change back to `active.yaml`, and move a task into the
// correct month's `tasks/completed/<YYYY-MM>.yaml` file the moment it's
// marked completed - not the fuller CRUD a create/edit phase will add.
//
// Follows `HostStore.swift`'s established shape (in-memory array backed by a
// file, `FM_HOSTS_FILE`-style env override, observer list) and
// `DotfilesData.swift`'s "shell out / read real files, nothing fabricated"
// rule - just against a directory tree instead of a single JSON file.

import Foundation

final class ShiftStore {

    private(set) var activeTasks: [ShiftTask] = []
    private(set) var followUps: [ShiftFollowUp] = []
    private(set) var projects: [ShiftProject] = []
    private(set) var settings: ShiftSettings = ShiftSettings()

    private var changeHandlers: [() -> Void] = []
    func observe(_ handler: @escaping () -> Void) { changeHandlers.append(handler) }

    let root: URL

    init() {
        root = ShiftStore.resolveRoot()
        reloadAll()
    }

    // MARK: Location

    /// `~/Library/Application Support/FirstmateCockpit/shift/`, overridable
    /// via `FM_SHIFT_DIR` - same convention as `HostStore`'s `FM_HOSTS_FILE`.
    static func resolveRoot() -> URL {
        if let override = ProcessInfo.processInfo.environment["FM_SHIFT_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath, isDirectory: true)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("FirstmateCockpit", isDirectory: true).appendingPathComponent("shift", isDirectory: true)
    }

    private var activeTasksPath: String { root.appendingPathComponent("tasks/active.yaml").path }
    private func completedPath(forMonth month: String) -> String { root.appendingPathComponent("tasks/completed/\(month).yaml").path }
    private var followUpsPath: String { root.appendingPathComponent("follow-ups/follow-ups.yaml").path }
    private var projectsPath: String { root.appendingPathComponent("projects/projects.yaml").path }
    private var notesPath: String { root.appendingPathComponent("notes/notes.yaml").path }
    private func activityPath(forMonth month: String) -> String { root.appendingPathComponent("activity/\(month).yaml").path }
    private var settingsPath: String { root.appendingPathComponent("settings.yaml").path }

    private static func monthKey(for date: Date = Date()) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM"
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = TimeZone.current
        return f.string(from: date)
    }

    // MARK: Load

    /// Re-reads every file from disk into memory - the same read path a
    /// relaunch would take, which is what makes "write, then reload, and
    /// confirm the change survived" a real persistence check rather than
    /// trusting the in-memory array a write call already mutated.
    func reloadAll() {
        activeTasks = ShiftYaml.readList(path: activeTasksPath, key: "tasks").compactMap(ShiftYaml.task(from:))
        followUps = ShiftYaml.readList(path: followUpsPath, key: "follow_ups").compactMap(ShiftYaml.followUp(from:))
        projects = ShiftYaml.readList(path: projectsPath, key: "projects").compactMap(ShiftYaml.project(from:))
        if let doc = ShiftYaml.readMapping(path: settingsPath) {
            settings = ShiftYaml.settings(from: doc)
        } else {
            settings = ShiftSettings()
            try? ShiftYaml.writeMapping(path: settingsPath, doc: ShiftYaml.toYaml(settings))
        }
    }

    /// Every completed task across every month file this root currently
    /// has, for stats/lookups that need to see completed work (not shown in
    /// the My Tasks list itself, which is active tasks only).
    func allCompletedTasks() -> [ShiftTask] {
        let completedDir = root.appendingPathComponent("tasks/completed", isDirectory: true)
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: completedDir.path) else { return [] }
        return files.filter { $0.hasSuffix(".yaml") }.flatMap { file -> [ShiftTask] in
            ShiftYaml.readList(path: completedDir.appendingPathComponent(file).path, key: "tasks").compactMap(ShiftYaml.task(from:))
        }
    }

    // MARK: Mutations

    /// Toggles a task's completion. Marking it done moves it out of
    /// `active.yaml` entirely and appends it to `tasks/completed/<YYYY-MM>.yaml`
    /// for the month it was completed in (not just a status flag flip in
    /// place - the acceptance bar this phase was built against). Un-marking a
    /// completed task (toggling it back to `todo`) is the reverse: pull it out
    /// of whichever month file it's sitting in and put it back in
    /// `active.yaml`. Every subtask toggle, by contrast, rewrites the task in
    /// whichever file it currently lives in without moving it.
    func setTaskCompleted(id: String, completed: Bool, now: Date = Date()) {
        let iso = ShiftStore.iso8601(now)
        if completed {
            guard let idx = activeTasks.firstIndex(where: { $0.id == id }) else { return }
            var task = activeTasks[idx]
            task.status = .completed
            task.completedAt = iso
            task.updatedAt = iso
            activeTasks.remove(at: idx)
            persistActiveTasks()
            appendToCompletedMonth(task, month: ShiftStore.monthKey(for: now))
            logActivity(kind: "task_completed", summary: "Completed \"\(task.title)\"", now: now)
        } else {
            guard let (month, task) = findCompletedTask(id: id) else { return }
            var restored = task
            restored.status = .todo
            restored.completedAt = nil
            restored.updatedAt = iso
            removeFromCompletedMonth(id: id, month: month)
            activeTasks.append(restored)
            persistActiveTasks()
            logActivity(kind: "task_reopened", summary: "Reopened \"\(restored.title)\"", now: now)
        }
        notify()
    }

    /// Toggles one subtask's done state on a task that's currently in
    /// `active.yaml`. Subtasks on a completed task are read-only in this
    /// phase (editing history isn't in scope) - callers should not offer the
    /// control there.
    func setSubtaskDone(taskID: String, subtaskID: String, done: Bool, now: Date = Date()) {
        guard let taskIdx = activeTasks.firstIndex(where: { $0.id == taskID }),
              let subIdx = activeTasks[taskIdx].subtasks.firstIndex(where: { $0.id == subtaskID }) else { return }
        activeTasks[taskIdx].subtasks[subIdx].done = done
        activeTasks[taskIdx].updatedAt = ShiftStore.iso8601(now)
        persistActiveTasks()
        notify()
    }

    private func findCompletedTask(id: String) -> (month: String, task: ShiftTask)? {
        let completedDir = root.appendingPathComponent("tasks/completed", isDirectory: true)
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: completedDir.path) else { return nil }
        for file in files where file.hasSuffix(".yaml") {
            let path = completedDir.appendingPathComponent(file).path
            let tasks = ShiftYaml.readList(path: path, key: "tasks").compactMap(ShiftYaml.task(from:))
            if let task = tasks.first(where: { $0.id == id }) {
                return (String(file.dropLast(".yaml".count)), task)
            }
        }
        return nil
    }

    private func appendToCompletedMonth(_ task: ShiftTask, month: String) {
        let path = completedPath(forMonth: month)
        var tasks = ShiftYaml.readList(path: path, key: "tasks").compactMap(ShiftYaml.task(from:))
        tasks.removeAll { $0.id == task.id }
        tasks.append(task)
        try? ShiftYaml.writeList(path: path, key: "tasks", items: tasks.map(ShiftYaml.toYaml))
    }

    private func removeFromCompletedMonth(id: String, month: String) {
        let path = completedPath(forMonth: month)
        var tasks = ShiftYaml.readList(path: path, key: "tasks").compactMap(ShiftYaml.task(from:))
        tasks.removeAll { $0.id == id }
        try? ShiftYaml.writeList(path: path, key: "tasks", items: tasks.map(ShiftYaml.toYaml))
    }

    private func logActivity(kind: String, summary: String, now: Date) {
        let path = activityPath(forMonth: ShiftStore.monthKey(for: now))
        var entries = ShiftYaml.readList(path: path, key: "activity").compactMap(ShiftYaml.activity(from:))
        entries.append(ShiftActivityEntry(id: UUID().uuidString, timestamp: ShiftStore.iso8601(now), kind: kind, summary: summary))
        try? ShiftYaml.writeList(path: path, key: "activity", items: entries.map(ShiftYaml.toYaml))
    }

    private func persistActiveTasks() {
        try? ShiftYaml.writeList(path: activeTasksPath, key: "tasks", items: activeTasks.map(ShiftYaml.toYaml))
    }

    private func notify() { changeHandlers.forEach { $0() } }

    static func iso8601(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        return f.string(from: date)
    }

    // MARK: Seed data (first-run convenience only - never overwrites an
    // existing file)

    /// Writes a small starter set of files the very first time Shift's root
    /// doesn't exist yet, so a fresh captain profile lands on a page with
    /// real (if modest) content instead of a totally blank one. Does nothing
    /// if `tasks/active.yaml` already exists - never clobbers real data.
    func seedIfEmpty(now: Date = Date()) {
        guard !FileManager.default.fileExists(atPath: activeTasksPath) else { return }
        let iso = ShiftStore.iso8601(now)
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        let today = df.string(from: now)

        let project = ShiftProject(id: UUID().uuidString, name: "Shift", status: .active, createdAt: iso)
        projects = [project]
        try? ShiftYaml.writeList(path: projectsPath, key: "projects", items: projects.map(ShiftYaml.toYaml))

        activeTasks = [
            ShiftTask(
                id: UUID().uuidString, title: "Wire up the Shift release flow",
                description: "Foundation phase: rail destination + local YAML store.",
                status: .inProgress, priority: .high, dueDate: today, dueTime: nil,
                projectID: project.id, tags: ["shift"], createdAt: iso, updatedAt: iso, completedAt: nil,
                notes: nil,
                subtasks: [
                    ShiftSubtask(id: UUID().uuidString, title: "Update version creation", done: true),
                    ShiftSubtask(id: UUID().uuidString, title: "Fix release flow", done: false),
                ]
            ),
            ShiftTask(
                id: UUID().uuidString, title: "Review captain-approved mockup",
                description: "", status: .todo, priority: .normal, dueDate: today, dueTime: nil,
                projectID: nil, tags: [], createdAt: iso, updatedAt: iso, completedAt: nil, notes: nil, subtasks: []
            ),
        ]
        persistActiveTasks()

        followUps = [
            ShiftFollowUp(
                id: UUID().uuidString, title: "Check back on the Projects page plan",
                status: .pending, priority: .normal, followUpAt: today, relatedTaskID: nil,
                projectID: project.id, notes: nil
            ),
        ]
        try? ShiftYaml.writeList(path: followUpsPath, key: "follow_ups", items: followUps.map(ShiftYaml.toYaml))

        settings = ShiftSettings()
        try? ShiftYaml.writeMapping(path: settingsPath, doc: ShiftYaml.toYaml(settings))
    }
}
