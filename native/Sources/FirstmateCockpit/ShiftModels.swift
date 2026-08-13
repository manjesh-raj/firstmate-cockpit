// Manjesh Grand Line - native macOS app.
//
// Data model for "Shift" (cockpit-shift-foundation, phase 1 of a multi-phase
// build - see AGENTS.md's "Shift" section for the file-splitting scheme and
// which phases are still pending). These are plain Swift structs, not
// `Codable` against JSON - persistence goes through `ShiftYaml.swift`'s
// explicit `Yaml` conversions, since the source of truth is a captain-owned
// YAML file tree, not a database.
//
// The core distinction the captain was explicit about: a **task** is
// something to do; a **follow-up** is something to check on later. They are
// modeled as two separate types with different fields, not a shared "item"
// type with a "kind" flag - see `ShiftTask` vs `ShiftFollowUp` below.

import Foundation

enum ShiftTaskStatus: String, CaseIterable {
    case todo, inProgress = "in_progress", completed, cancelled
}

enum ShiftPriority: String, CaseIterable {
    case low, normal, high
}

/// A checklist item nested under a task. Subtasks are only ever rendered in
/// a project-scoped context (never as flat rows in the main My Tasks list) -
/// see `ShiftController`'s project section, not the task list.
struct ShiftSubtask {
    var id: String
    var title: String
    var done: Bool
}

struct ShiftTask {
    var id: String
    var title: String
    var description: String
    var status: ShiftTaskStatus
    var priority: ShiftPriority
    var dueDate: String?    // "YYYY-MM-DD"
    var dueTime: String?    // "HH:MM"
    var projectID: String?
    var tags: [String]
    var createdAt: String   // ISO 8601
    var updatedAt: String
    var completedAt: String?
    var notes: String?
    var subtasks: [ShiftSubtask]
}

enum ShiftFollowUpStatus: String, CaseIterable {
    case pending, done
}

/// Deliberately its own type, not "a task with a reminder" - a follow-up is
/// something to check on later, with no completion checklist or description
/// field, and its own `followUpAt` date rather than a due date.
struct ShiftFollowUp {
    var id: String
    var title: String
    var status: ShiftFollowUpStatus
    var priority: ShiftPriority
    var followUpAt: String?  // "YYYY-MM-DD"
    var relatedTaskID: String?
    var projectID: String?
    var notes: String?
}

enum ShiftProjectStatus: String, CaseIterable {
    case active, archived
}

/// Minimal placeholder per the phase-1 brief - a real Projects page with a
/// status control is a later phase. This exists mainly to give tasks a real
/// `projectID` to point at and to prove out project-scoped subtask
/// rendering.
struct ShiftProject {
    var id: String
    var name: String
    var status: ShiftProjectStatus
    var createdAt: String
}

struct ShiftNote {
    var id: String
    var title: String
    var body: String
    var createdAt: String
}

/// One history-log entry (the `activity/<YYYY-MM>.yaml` files) - proves out
/// the same month-split scheme `completed/<YYYY-MM>.yaml` uses, on the
/// second folder the brief's file layout calls for.
struct ShiftActivityEntry {
    var id: String
    var timestamp: String
    var kind: String   // e.g. "task_completed", "task_created"
    var summary: String
}

/// `settings.yaml` - deliberately tiny in this phase. `syncStatus` is a
/// placeholder always reporting "Synced" (see AGENTS.md) - real Git sync is
/// a later phase; the field exists now so that phase has a seam to fill in
/// rather than inventing new state.
struct ShiftSettings {
    var syncStatus: String = "Synced"
}
