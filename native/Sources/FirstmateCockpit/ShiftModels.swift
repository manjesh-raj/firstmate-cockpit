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

    /// A blank task ready for `ShiftStore.addTask` - the New Task editor
    /// (phase 2) fills fields into this rather than hand-assembling every
    /// property inline.
    static func fresh(now: Date = Date()) -> ShiftTask {
        let iso = ShiftStore.iso8601(now)
        return ShiftTask(
            id: UUID().uuidString, title: "", description: "", status: .todo, priority: .normal,
            dueDate: nil, dueTime: nil, projectID: nil, tags: [], createdAt: iso, updatedAt: iso,
            completedAt: nil, notes: nil, subtasks: []
        )
    }
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
    var followUpTime: String?  // "HH:MM", mirrors ShiftTask.dueTime
    var relatedTaskID: String?
    var projectID: String?
    var notes: String?

    /// A blank follow-up ready for `ShiftStore.addFollowUp`.
    static func fresh() -> ShiftFollowUp {
        ShiftFollowUp(
            id: UUID().uuidString, title: "", status: .pending, priority: .normal,
            followUpAt: nil, followUpTime: nil, relatedTaskID: nil, projectID: nil, notes: nil
        )
    }
}

/// `active`/`archived` (phase 1's placeholder pair) became this 5-state set
/// in phase 3 (cockpit-shift-projects), matching the real status dropdown on
/// a project's card - not just an "is this archived" flag.
enum ShiftProjectStatus: String, CaseIterable {
    case notStarted = "not_started"
    case inProgress = "in_progress"
    case onHold = "on_hold"
    case completed
    case archived

    var displayName: String {
        switch self {
        case .notStarted: return "Not Started"
        case .inProgress: return "In Progress"
        case .onHold: return "On Hold"
        case .completed: return "Completed"
        case .archived: return "Archived"
        }
    }
}

/// A real project (cockpit-shift-projects, phase 3): a status control
/// clicking through to a dropdown that actually persists, a task list scoped
/// to the project (with nested subtasks - see `ShiftSubtask`'s doc comment),
/// and an editable field set (name/description/status/start date/due date).
struct ShiftProject {
    var id: String
    var name: String
    var description: String
    var status: ShiftProjectStatus
    var startDate: String?  // "YYYY-MM-DD"
    var dueDate: String?    // "YYYY-MM-DD"
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
