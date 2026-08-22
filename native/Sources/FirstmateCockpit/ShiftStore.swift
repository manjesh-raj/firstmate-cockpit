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
import Yaml

final class ShiftStore {

    private(set) var activeTasks: [ShiftTask] = []
    private(set) var followUps: [ShiftFollowUp] = []
    private(set) var projects: [ShiftProject] = []
    private(set) var settings: ShiftSettings = ShiftSettings()

    private var changeHandlers: [() -> Void] = []
    func observe(_ handler: @escaping () -> Void) { changeHandlers.append(handler) }

    // MARK: Failed-load state (GL-01)

    /// Paths whose *last read* found a real YAML parse failure - a file that
    /// exists and has content this store could not understand.
    ///
    /// This is the load-bearing half of GL-01 for Shift. Before it, a single
    /// hand-edited syntax error in `active.yaml` parsed as `[]`, `reloadAll`
    /// kept that silently, the next `addTask` wrote a one-task file over
    /// every real task, and the debounced `ShiftGitSync` committed and pushed
    /// the wipe to GitHub - git history was the only recovery. While a path
    /// is in here, this store refuses every write to it *and* suppresses
    /// `markDirty()` entirely, so nothing local is overwritten and nothing is
    /// propagated off-machine. Clearing it takes a successful re-read: fix
    /// the file (the `.corrupt-<ts>` copy is right beside it) and reload.
    private(set) var loadFailurePaths: Set<String> = []

    /// True while any file this store owns is unreadable - the app should
    /// treat Shift as read-only until it is resolved.
    var isInFailedLoadState: Bool { !loadFailurePaths.isEmpty }

    /// Records a `.parseFailed` read: backs the file up once (so a captain
    /// has a copy even if they then hand-fix the original into something
    /// else) and marks the path as unwritable.
    private func noteLoadFailure(_ path: String) {
        if loadFailurePaths.insert(path).inserted {
            StoreLoadFailure.backUp(URL(fileURLWithPath: path))
        }
    }

    /// Clears a path's failed state after a successful read of it.
    private func noteLoadOK(_ path: String) {
        loadFailurePaths.remove(path)
    }

    /// Reads a list file, recording a parse failure rather than silently
    /// returning `[]` for it. Every read whose result can later be written
    /// back to the same file goes through here.
    private func readListGuarded(path: String, key: String) -> [Yaml] {
        switch ShiftYaml.readListChecked(path: path, key: key) {
        case .ok(let items):
            noteLoadOK(path)
            return items
        case .missing:
            noteLoadOK(path)
            return []
        case .parseFailed:
            noteLoadFailure(path)
            return []
        }
    }

    /// The one write choke point: refuses to write a file this store could
    /// not read. Returns whether the write actually happened, so a caller
    /// that needs to know (a mutation that should not then announce success)
    /// can check.
    @discardableResult
    private func writeListGuarded(path: String, key: String, items: [Yaml]) -> Bool {
        guard !loadFailurePaths.contains(path) else {
            NSLog("[cockpit] Shift: refusing to write \(path) - its last read failed to parse (GL-01). Fix or remove the file, then reload.")
            return false
        }
        do {
            try ShiftYaml.writeList(path: path, key: key, items: items)
            return true
        } catch {
            NSLog("[cockpit] Shift: failed to write \(path): \(error.localizedDescription)")
            return false
        }
    }

    let root: URL

    /// `nil` when `FM_SHIFT_DIR` explicitly overrides `root` (every self-test
    /// in this file, and any captain who wants a plain local-only folder with
    /// no git backing at all) - in that case this store never shells out to
    /// git or touches the network, matching phases 1-3's exact behavior.
    /// Otherwise (the production default) this is `ShiftGitSync.shared`, and
    /// every persisted mutation below calls its `markDirty()` after writing -
    /// see `notify()`.
    let gitSync: ShiftGitSync?

    init() {
        if let override = ProcessInfo.processInfo.environment["FM_SHIFT_DIR"], !override.isEmpty {
            root = URL(fileURLWithPath: (override as NSString).expandingTildeInPath, isDirectory: true)
            gitSync = nil
        } else {
            let sync = ShiftGitSync.shared
            sync.start()
            root = sync.dataRoot
            gitSync = sync
        }
        reloadAll()
    }

    // MARK: Location

    /// `personal-tasks/` inside a local clone of the captain's `manjesh-
    /// config` GitHub repo (`ShiftGitSync.shared.dataRoot`), overridable via
    /// `FM_SHIFT_DIR` - same convention as `HostStore`'s `FM_HOSTS_FILE`, and
    /// unchanged from phases 1-3's own `FM_SHIFT_DIR` in that setting it still
    /// points straight at the data root and bypasses everything else,
    /// including git sync entirely (see `gitSync`'s doc comment above). What
    /// changed in this phase (cockpit-shift-git-sync) is only the *default*
    /// when `FM_SHIFT_DIR` is unset: phases 1-3 defaulted to a bare, non-git
    /// `~/Library/Application Support/FirstmateCockpit/shift/` folder; that
    /// folder's real data (if any) is migrated automatically into the new
    /// git-backed location the first time `ShiftGitSync` runs - see
    /// `ShiftGitSync.migrateLegacyDataIfNeeded()`. The local git clone itself
    /// lives at `ShiftGitSync.resolveDefaultWorkingTree()`, overridable via
    /// `FM_SHIFT_GIT_CLONE_PATH`; the remote it clones/pulls/pushes is
    /// `ShiftGitSync.resolveDefaultRemoteURL()`, overridable via
    /// `FM_SHIFT_REMOTE_URL` (how this phase's own verification pointed a
    /// whole test instance of the app at a disposable local bare repo instead
    /// of the captain's real `manjesh-config`).
    static func resolveRoot() -> URL {
        if let override = ProcessInfo.processInfo.environment["FM_SHIFT_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath, isDirectory: true)
        }
        return ShiftGitSync.shared.dataRoot
    }

    private var activeTasksPath: String { root.appendingPathComponent("tasks/active.yaml").path }
    private func completedPath(forMonth month: String) -> String { root.appendingPathComponent("tasks/completed/\(month).yaml").path }
    private var followUpsPath: String { root.appendingPathComponent("follow-ups/follow-ups.yaml").path }
    private var projectsPath: String { root.appendingPathComponent("projects/projects.yaml").path }
    private var notesPath: String { root.appendingPathComponent("notes/notes.yaml").path }
    private func activityPath(forMonth month: String) -> String { root.appendingPathComponent("activity/\(month).yaml").path }
    private var settingsPath: String { root.appendingPathComponent("settings.yaml").path }

    /// One attachment per task (this pass's scope), named by the task's own
    /// id so re-saving replaces rather than accumulates - never a second
    /// file for the same id. Always `.png`: every image saved through
    /// `ShiftImageAttachmentWell.normalizedPNGData` is already re-encoded as
    /// PNG on the way in, regardless of the source format, so there's never
    /// an ambiguous extension to track.
    private var attachmentsDir: URL { root.appendingPathComponent("attachments", isDirectory: true) }
    private func attachmentURL(forTaskID id: String) -> URL { attachmentsDir.appendingPathComponent("\(id).png") }

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
        activeTasks = readListGuarded(path: activeTasksPath, key: "tasks").compactMap(ShiftYaml.task(from:))
        followUps = readListGuarded(path: followUpsPath, key: "follow_ups").compactMap(ShiftYaml.followUp(from:))
        projects = readListGuarded(path: projectsPath, key: "projects").compactMap(ShiftYaml.project(from:))
        switch ShiftYaml.readMappingChecked(path: settingsPath) {
        case .ok(let doc):
            noteLoadOK(settingsPath)
            settings = ShiftYaml.settings(from: doc)
        case .missing:
            // Genuine first run - write the scaffold, as before.
            noteLoadOK(settingsPath)
            settings = ShiftSettings()
            try? ShiftYaml.writeMapping(path: settingsPath, doc: ShiftYaml.toYaml(settings))
        case .parseFailed:
            // GL-01: do NOT overwrite a settings file we could not read.
            noteLoadFailure(settingsPath)
            settings = ShiftSettings()
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
            logActivity(kind: "task_completed", summary: "Completed \"\(task.title)\"", targetID: task.id, now: now)
        } else {
            guard let (month, task) = findCompletedTask(id: id) else { return }
            var restored = task
            restored.status = .todo
            restored.completedAt = nil
            restored.updatedAt = iso
            removeFromCompletedMonth(id: id, month: month)
            activeTasks.append(restored)
            persistActiveTasks()
            logActivity(kind: "task_reopened", summary: "Reopened \"\(restored.title)\"", targetID: restored.id, now: now)
        }
        notify()
    }

    /// Toggles one subtask's done state on a task, wherever it currently
    /// lives - `active.yaml` or the right completed month file. Phase 1 only
    /// needed the active case; phase 3's project detail (cockpit-shift-
    /// projects) lists a project's completed tasks alongside its active
    /// ones, and the brief's own acceptance bar requires a subtask toggle on
    /// a completed task to persist to the correct month file too.
    func setSubtaskDone(taskID: String, subtaskID: String, done: Bool, now: Date = Date()) {
        if let taskIdx = activeTasks.firstIndex(where: { $0.id == taskID }),
           let subIdx = activeTasks[taskIdx].subtasks.firstIndex(where: { $0.id == subtaskID }) {
            activeTasks[taskIdx].subtasks[subIdx].done = done
            activeTasks[taskIdx].updatedAt = ShiftStore.iso8601(now)
            persistActiveTasks()
            notify()
            return
        }
        guard let found = findCompletedTask(id: taskID) else { return }
        var task = found.task
        guard let subIdx = task.subtasks.firstIndex(where: { $0.id == subtaskID }) else { return }
        task.subtasks[subIdx].done = done
        task.updatedAt = ShiftStore.iso8601(now)
        appendToCompletedMonth(task, month: found.month)
        notify()
    }

    // MARK: Creation / editing (phase 2)

    /// Appends a brand-new task to `active.yaml` and persists immediately.
    /// The caller is responsible for filling in `id`/`createdAt`/`updatedAt`
    /// (`ShiftTask.fresh` on the model side does this) - this is purely the
    /// "append and write" half. `attachment` (grandline-shift-task-image-
    /// attachments) is applied *before* the task is written, so
    /// `active.yaml` and the on-disk attachment file/`hasAttachment` flag
    /// never disagree even momentarily.
    func addTask(_ task: ShiftTask, attachment: ShiftAttachmentChange = .unchanged) {
        var task = task
        applyAttachmentChange(attachment, taskID: task.id, task: &task)
        activeTasks.append(task)
        persistActiveTasks()
        logActivity(kind: "task_created", summary: "Created \"\(task.title)\"", targetID: task.id, now: Date())
        notify()
    }

    /// Replaces an existing task in `active.yaml` in place (same array index,
    /// same file) - a completed task isn't editable through this path since
    /// it no longer lives in `active.yaml` (see `setTaskCompleted`'s header).
    ///
    /// Logs a `task_due_date_changed` activity entry (phase 5) whenever an
    /// already-set due date is edited to a different value (including
    /// cleared) - the one signal Weekly Review's "pushed back repeatedly"
    /// stat has for a task, since phases 1-4 never tracked due-date history
    /// as a field on `ShiftTask` itself. A task getting its *first* due date
    /// isn't a "push back," so this only fires when `previous.dueDate` was
    /// already non-nil.
    func updateTask(_ task: ShiftTask, attachment: ShiftAttachmentChange = .unchanged, now: Date = Date()) {
        guard let idx = activeTasks.firstIndex(where: { $0.id == task.id }) else { return }
        let previous = activeTasks[idx]
        var updated = task
        updated.updatedAt = ShiftStore.iso8601(now)
        applyAttachmentChange(attachment, taskID: updated.id, task: &updated)
        activeTasks[idx] = updated
        persistActiveTasks()
        if let oldDue = previous.dueDate, oldDue != updated.dueDate {
            logActivity(
                kind: "task_due_date_changed", summary: "Pushed back due date for \"\(updated.title)\"",
                targetID: updated.id, now: now
            )
        }
        notify()
    }

    /// Appends a brand-new follow-up to `follow-ups.yaml` and persists
    /// immediately.
    func addFollowUp(_ followUp: ShiftFollowUp) {
        followUps.append(followUp)
        persistFollowUps()
        logActivity(kind: "follow_up_created", summary: "Created follow-up \"\(followUp.title)\"", targetID: followUp.id, now: Date())
        notify()
    }

    /// Replaces an existing follow-up in place.
    func updateFollowUp(_ followUp: ShiftFollowUp) {
        guard let idx = followUps.firstIndex(where: { $0.id == followUp.id }) else { return }
        followUps[idx] = followUp
        persistFollowUps()
        notify()
    }

    /// Marks a follow-up done/pending - stays in `follow-ups.yaml` either way
    /// (unlike a task, there's no month-split "completed" file for
    /// follow-ups in this phase's file layout), but a `done` follow-up drops
    /// out of the "active follow-ups" view (`ShiftController` already
    /// filters by `status == .pending`) and gets an activity log entry, which
    /// is what "moves it out of the active list, into activity" means here.
    func setFollowUpStatus(id: String, done: Bool, now: Date = Date()) {
        guard let idx = followUps.firstIndex(where: { $0.id == id }) else { return }
        followUps[idx].status = done ? .done : .pending
        persistFollowUps()
        logActivity(
            kind: done ? "follow_up_completed" : "follow_up_reopened",
            summary: "\(done ? "Completed" : "Reopened") follow-up \"\(followUps[idx].title)\"",
            targetID: followUps[idx].id, now: now
        )
        notify()
    }

    /// Recomputes and persists `follow_up_at`/`follow_up_time` from a new
    /// target `Date` - the one place Snooze writes back, whether the preset
    /// was a relative offset (30 min / 1 hour) or an absolute pick (Tomorrow /
    /// Next week / Custom).
    func snoozeFollowUp(id: String, to date: Date, now: Date = Date()) {
        guard let idx = followUps.firstIndex(where: { $0.id == id }) else { return }
        let (dateStr, timeStr) = ShiftDateFormatting.components(from: date)
        followUps[idx].followUpAt = dateStr
        followUps[idx].followUpTime = timeStr
        followUps[idx].status = .pending
        persistFollowUps()
        logActivity(
            kind: "follow_up_snoozed", summary: "Snoozed follow-up \"\(followUps[idx].title)\"",
            targetID: followUps[idx].id, now: now
        )
        notify()
    }

    private func persistFollowUps() {
        writeListGuarded(path: followUpsPath, key: "follow_ups", items: followUps.map(ShiftYaml.toYaml))
    }

    // MARK: Projects (phase 3)

    /// Appends a brand-new project to `projects/projects.yaml` and persists
    /// immediately (cockpit-fix-shift-new-project) - the counterpart to
    /// `addTask`/`addFollowUp` above that phase 3 never added when it shipped
    /// `updateProject` (edit-only, no creation path).
    func addProject(_ project: ShiftProject) {
        projects.append(project)
        persistProjects()
        logActivity(kind: "project_created", summary: "Created project \"\(project.name)\"", targetID: project.id, now: Date())
        notify()
    }

    /// Persists a project's edited fields (status, name, description, dates)
    /// back to `projects/projects.yaml` in full - there is no partial-field
    /// write, callers pass the whole struct with their edit applied.
    func updateProject(_ project: ShiftProject) {
        guard let idx = projects.firstIndex(where: { $0.id == project.id }) else { return }
        projects[idx] = project
        persistProjects()
        notify()
    }

    /// `(completed, total)` task counts for one project, counting both
    /// active and completed tasks - what a project card's "X of Y tasks
    /// completed" line and progress bar need.
    func taskCounts(forProject projectID: String) -> (completed: Int, total: Int) {
        let activeCount = activeTasks.filter { $0.projectID == projectID }.count
        let completedCount = allCompletedTasks().filter { $0.projectID == projectID }.count
        return (completedCount, activeCount + completedCount)
    }

    /// Every task belonging to a project, active and completed alike - what
    /// project detail's task list shows (never the flat My Tasks list, which
    /// stays active-only and never renders subtasks - see ShiftModels.swift).
    func allTasks(forProject projectID: String) -> [ShiftTask] {
        activeTasks.filter { $0.projectID == projectID } + allCompletedTasks().filter { $0.projectID == projectID }
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
        var tasks = readListGuarded(path: path, key: "tasks").compactMap(ShiftYaml.task(from:))
        tasks.removeAll { $0.id == task.id }
        tasks.append(task)
        writeListGuarded(path: path, key: "tasks", items: tasks.map(ShiftYaml.toYaml))
    }

    private func removeFromCompletedMonth(id: String, month: String) {
        let path = completedPath(forMonth: month)
        var tasks = readListGuarded(path: path, key: "tasks").compactMap(ShiftYaml.task(from:))
        tasks.removeAll { $0.id == id }
        writeListGuarded(path: path, key: "tasks", items: tasks.map(ShiftYaml.toYaml))
    }

    private func logActivity(kind: String, summary: String, targetID: String? = nil, now: Date) {
        let path = activityPath(forMonth: ShiftStore.monthKey(for: now))
        var entries = readListGuarded(path: path, key: "activity").compactMap(ShiftYaml.activity(from:))
        entries.append(ShiftActivityEntry(id: UUID().uuidString, timestamp: ShiftStore.iso8601(now), kind: kind, summary: summary, targetID: targetID))
        writeListGuarded(path: path, key: "activity", items: entries.map(ShiftYaml.toYaml))
    }

    private func persistActiveTasks() {
        writeListGuarded(path: activeTasksPath, key: "tasks", items: activeTasks.map(ShiftYaml.toYaml))
    }

    private func persistProjects() {
        writeListGuarded(path: projectsPath, key: "projects", items: projects.map(ShiftYaml.toYaml))
    }

    // MARK: Attachments (grandline-shift-task-image-attachments)

    /// Reads the raw bytes of a task's attached image, if any - `nil` when
    /// the task has none, or (a defensive mismatch that should never happen
    /// in practice, but costs nothing to guard) when `hasAttachment` says
    /// `true` but the file is missing. Callers (the task editor sheet, for
    /// showing a real thumbnail on open) are expected to already know
    /// `hasAttachment` is `true` before calling this - this method itself
    /// never touches `activeTasks`.
    func attachmentData(forTaskID id: String) -> Data? {
        try? Data(contentsOf: attachmentURL(forTaskID: id))
    }

    /// Writes (or overwrites) a task's attachment file and flips
    /// `hasAttachment` on `task` - `task` is mutated in place by the caller
    /// (`addTask`/`updateTask`), never persisted here directly, so the YAML
    /// write and the binary file write land as one logical unit before
    /// `notify()` schedules the debounced commit+push. `data` is expected to
    /// already be normalized (downscaled, PNG-encoded) - see
    /// `ShiftImageAttachmentWell.normalizedPNGData`; this method just writes
    /// whatever bytes it's given.
    private func writeAttachment(_ data: Data, taskID: String) {
        try? FileManager.default.createDirectory(at: attachmentsDir, withIntermediateDirectories: true)
        try? data.write(to: attachmentURL(forTaskID: taskID), options: .atomic)
    }

    /// Deletes a task's attachment file, if any - a no-op if there isn't
    /// one. Never fails the caller: a missing file here just means there was
    /// nothing to remove.
    private func removeAttachmentFile(taskID: String) {
        try? FileManager.default.removeItem(at: attachmentURL(forTaskID: taskID))
    }

    /// Applies a captain's attachment decision (from the task editor sheet)
    /// to both the on-disk file and `task.hasAttachment`, called by
    /// `addTask`/`updateTask` before either persists the task record - so
    /// the two never disagree, even for the brief window between writing the
    /// image file and writing `active.yaml`.
    private func applyAttachmentChange(_ change: ShiftAttachmentChange, taskID: String, task: inout ShiftTask) {
        switch change {
        case .unchanged:
            break
        case .set(let data):
            writeAttachment(data, taskID: taskID)
            task.hasAttachment = true
        case .removed:
            removeAttachmentFile(taskID: taskID)
            task.hasAttachment = false
        }
    }

    /// Every mutation above already wrote its YAML file synchronously before
    /// calling this - `markDirty()` only ever schedules the debounced
    /// git commit/push that happens afterward, on a background queue. Never
    /// called when `gitSync` is `nil` (an explicit `FM_SHIFT_DIR` override),
    /// so a self-test or a plain local-only setup never shells out to git.
    private func notify() {
        changeHandlers.forEach { $0() }
        // GL-01: never propagate a write that happened while some file this
        // store owns is unreadable - that is the path by which a local wipe
        // became a pushed wipe.
        guard !isInFailedLoadState else {
            NSLog("[cockpit] Shift: skipping git sync - \(loadFailurePaths.count) file(s) failed to parse (GL-01).")
            return
        }
        gitSync?.markDirty()
    }

    static func iso8601(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        return f.string(from: date)
    }

    private static func iso8601Date(_ s: String) -> Date? {
        ISO8601DateFormatter().date(from: s)
    }

    // MARK: Weekly review (phase 5, cockpit-shift-power-features)

    /// Every activity entry from the current month plus `monthsBack` prior
    /// months' `activity/<YYYY-MM>.yaml` files - a bounded lookback (default
    /// 2 months) rather than scanning every month file that has ever
    /// existed, since "pushed back repeatedly" only needs a recent window to
    /// be useful.
    private func recentActivityEntries(monthsBack: Int, reference: Date) -> [ShiftActivityEntry] {
        let cal = Calendar(identifier: .gregorian)
        var entries: [ShiftActivityEntry] = []
        for offset in 0...monthsBack {
            guard let month = cal.date(byAdding: .month, value: -offset, to: reference) else { continue }
            let path = activityPath(forMonth: ShiftStore.monthKey(for: month))
            entries.append(contentsOf: ShiftYaml.readList(path: path, key: "activity").compactMap(ShiftYaml.activity(from:)))
        }
        return entries
    }

    /// Computes Weekly Review's three headline numbers, entirely from data
    /// phases 1-4 already persist - never a new tracked field on `ShiftTask`/
    /// `ShiftFollowUp` themselves (the brief's explicit instruction). The
    /// week is `reference`'s own `Calendar.current` week (`.weekOfYear`),
    /// Monday-first or Sunday-first per the system calendar, matching how
    /// every other date computation in this app already defers to
    /// `Calendar.current` rather than hardcoding a week start.
    ///
    /// - "completed this week": tasks whose `completedAt` falls in the week,
    ///   plus follow-ups with a `follow_up_completed` activity entry in the
    ///   week (a follow-up has no completion timestamp field of its own).
    /// - "pushed back 2+ times": groups `follow_up_snoozed` (by follow-up)
    ///   and `task_due_date_changed` (by task) activity entries - within the
    ///   lookback window, not just this week, since a captain re-prioritizing
    ///   something is a signal worth surfacing even if the pushes happened
    ///   over several weeks - by `targetID`, keeping any id with 2+
    ///   occurrences whose task/follow-up still exists.
    /// - "coming up next week": active tasks due, and pending follow-ups
    ///   due, in the 7 days immediately after this week ends.
    func weeklySummary(reference: Date = Date()) -> ShiftWeeklySummary {
        let cal = Calendar.current
        guard let weekInterval = cal.dateInterval(of: .weekOfYear, for: reference) else {
            return ShiftWeeklySummary(weekLabel: "This week", completedCount: 0, pushedBack: [], upcomingCount: 0)
        }
        let weekStart = weekInterval.start
        let weekEnd = weekInterval.end // exclusive

        let completedTasksThisWeek = allCompletedTasks().filter { task in
            guard let completedAt = task.completedAt, let date = ShiftStore.iso8601Date(completedAt) else { return false }
            return date >= weekStart && date < weekEnd
        }.count

        let recent = recentActivityEntries(monthsBack: 2, reference: reference)

        let completedFollowUpsThisWeek = recent.filter { entry in
            guard entry.kind == "follow_up_completed", let date = ShiftStore.iso8601Date(entry.timestamp) else { return false }
            return date >= weekStart && date < weekEnd
        }.count

        var pushCounts: [String: (kind: String, count: Int)] = [:]
        for entry in recent where entry.kind == "follow_up_snoozed" || entry.kind == "task_due_date_changed" {
            guard let targetID = entry.targetID else { continue }
            pushCounts[targetID, default: (entry.kind, 0)].count += 1
        }
        let allCompleted = allCompletedTasks()
        var pushedBack: [ShiftPushedBackItem] = pushCounts.compactMap { id, info in
            guard info.count >= 2 else { return nil }
            let title: String?
            let projectID: String?
            if info.kind == "task_due_date_changed" {
                let task = activeTasks.first(where: { $0.id == id }) ?? allCompleted.first(where: { $0.id == id })
                title = task?.title
                projectID = task?.projectID
            } else {
                let fu = followUps.first(where: { $0.id == id })
                title = fu?.title
                projectID = fu?.projectID
            }
            guard let title else { return nil }
            let projectName = projectID.flatMap { pid in projects.first(where: { $0.id == pid })?.name }
            return ShiftPushedBackItem(id: id, title: title, count: info.count, projectName: projectName)
        }
        pushedBack.sort { $0.count > $1.count }

        let nextWeekEnd = cal.date(byAdding: .day, value: 7, to: weekEnd) ?? weekEnd
        let upcomingTasks = activeTasks.filter { task in
            guard let due = task.dueDate.flatMap(ShiftDateFormatting.date(from:)) else { return false }
            return due >= weekEnd && due < nextWeekEnd
        }.count
        let upcomingFollowUps = followUps.filter { $0.status == .pending }.filter { fu in
            guard let due = fu.followUpAt.flatMap(ShiftDateFormatting.date(from:)) else { return false }
            return due >= weekEnd && due < nextWeekEnd
        }.count

        let df = DateFormatter()
        df.setLocalizedDateFormatFromTemplate("MMMd")
        let weekEndInclusive = cal.date(byAdding: .day, value: -1, to: weekEnd) ?? weekEnd
        let weekLabel = "Week of \(df.string(from: weekStart)) \u{2013} \(df.string(from: weekEndInclusive))"

        return ShiftWeeklySummary(
            weekLabel: weekLabel,
            completedCount: completedTasksThisWeek + completedFollowUpsThisWeek,
            pushedBack: pushedBack,
            upcomingCount: upcomingTasks + upcomingFollowUps
        )
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

        let project = ShiftProject(
            id: UUID().uuidString, name: "Shift", description: "Building the Shift feature itself.",
            status: .inProgress, startDate: today, dueDate: nil, createdAt: iso
        )
        projects = [project]
        persistProjects()

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
                ],
                hasAttachment: false
            ),
            ShiftTask(
                id: UUID().uuidString, title: "Review captain-approved mockup",
                description: "", status: .todo, priority: .normal, dueDate: today, dueTime: nil,
                projectID: nil, tags: [], createdAt: iso, updatedAt: iso, completedAt: nil, notes: nil, subtasks: [],
                hasAttachment: false
            ),
        ]
        persistActiveTasks()

        followUps = [
            ShiftFollowUp(
                id: UUID().uuidString, title: "Check back on the Projects page plan",
                status: .pending, priority: .normal, followUpAt: today, followUpTime: nil, relatedTaskID: nil,
                projectID: project.id, notes: nil
            ),
        ]
        try? ShiftYaml.writeList(path: followUpsPath, key: "follow_ups", items: followUps.map(ShiftYaml.toYaml))

        settings = ShiftSettings()
        try? ShiftYaml.writeMapping(path: settingsPath, doc: ShiftYaml.toYaml(settings))
    }
}
