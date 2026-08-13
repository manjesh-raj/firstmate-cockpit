// Manjesh Grand Line - native macOS app.
//
// Conflict detection and record-level 3-way merge for Shift (cockpit-shift-
// conflict-handling, phase 6 - the last queued phase of the Shift build, see
// AGENTS.md's "Shift" section). Phase 4 (`ShiftGitSync.pullNow`) deliberately
// stopped safely on a non-fast-forward pull and left real resolution to this
// phase - see `pullNow`'s own doc comment.
//
// This is scoped to Shift's own known record types (tasks, follow-ups,
// projects), never a general-purpose git merge tool: a record is identified
// by its `id` field, and conflicts are computed by comparing a record's
// typed field snapshot across three revisions (the merge-base, local HEAD,
// and origin/<branch>) - never a raw line-based text diff of the YAML file,
// which could silently interleave two unrelated field edits into a
// nonsensical record without either side's or git's own merge algorithm
// noticing.
//
// The three possible outcomes per record, id-keyed, comparing base/local/
// remote:
//   - Unchanged, or changed identically on both sides: safe, no conflict.
//   - Changed on only one side (the other side matches base): safe, take
//     whichever side actually changed it.
//   - Added on only one side (absent from base and the other side): safe,
//     keep it - this is what makes "two different tasks added on each side
//     with no overlapping ids" auto-mergeable per the task brief.
//   - Deleted on only one side (present in base, absent from that side,
//     unchanged on the other): safe, the deletion wins.
//   - Present differently on both sides *and* differing from base on the
//     side(s) that have it (edited-both-sides, added-both-sides-with-the-
//     same-id-but-different-content, or edited-one-side/deleted-other): a
//     genuine conflict - never silently resolved, always surfaced for an
//     explicit "keep mine" / "keep GitHub's" choice.

import Foundation
import Yaml

enum ShiftRecordKind: String {
    case task = "Task"
    case followUp = "Follow-up"
    case project = "Project"
}

/// A record type that can be shown and resolved in the conflict UI. `id` is
/// already a stored property on `ShiftTask`/`ShiftFollowUp`/`ShiftProject`;
/// `fieldSnapshot()` must always return the same labels in the same order
/// for a given type, since `ShiftRecordConflict.fieldDiffs` zips two
/// snapshots positionally.
protocol ShiftConflictRecordType: Equatable {
    var id: String { get }
    var conflictTitle: String { get }
    func fieldSnapshot() -> [(label: String, value: String)]
}

enum ShiftConflictFormat {
    static func humanize(_ raw: String) -> String {
        raw.replacingOccurrences(of: "_", with: " ").capitalized
    }
}

extension ShiftTask: ShiftConflictRecordType {
    var conflictTitle: String { title.isEmpty ? "(untitled task)" : title }
    func fieldSnapshot() -> [(label: String, value: String)] {
        [
            ("Title", title),
            ("Status", ShiftConflictFormat.humanize(status.rawValue)),
            ("Priority", ShiftConflictFormat.humanize(priority.rawValue)),
            ("Due date", dueDate ?? "\u{2014}"),
            ("Due time", dueTime ?? "\u{2014}"),
            ("Description", description),
            ("Tags", tags.joined(separator: ", ")),
            ("Notes", notes ?? "\u{2014}"),
            ("Subtasks", subtasks.map { "\($0.done ? "[x]" : "[ ]") \($0.title)" }.joined(separator: "; ")),
        ]
    }
}

extension ShiftFollowUp: ShiftConflictRecordType {
    var conflictTitle: String { title.isEmpty ? "(untitled follow-up)" : title }
    func fieldSnapshot() -> [(label: String, value: String)] {
        [
            ("Title", title),
            ("Status", ShiftConflictFormat.humanize(status.rawValue)),
            ("Priority", ShiftConflictFormat.humanize(priority.rawValue)),
            ("Follow-up date", followUpAt ?? "\u{2014}"),
            ("Follow-up time", followUpTime ?? "\u{2014}"),
            ("Notes", notes ?? "\u{2014}"),
        ]
    }
}

extension ShiftProject: ShiftConflictRecordType {
    var conflictTitle: String { name.isEmpty ? "(untitled project)" : name }
    func fieldSnapshot() -> [(label: String, value: String)] {
        [
            ("Name", name),
            ("Status", ShiftConflictFormat.humanize(status.rawValue)),
            ("Description", description),
            ("Start date", startDate ?? "\u{2014}"),
            ("Due date", dueDate ?? "\u{2014}"),
        ]
    }
}

struct ShiftFieldDiff: Equatable {
    let field: String
    let local: String
    let remote: String
}

/// One record that genuinely needs a captain decision. `local`/`remote` are
/// `nil` when that side deleted the record (present at the merge-base but
/// missing there) - the UI renders that as "Deleted" rather than a field
/// list, and resolving it just means "keep it" (the non-nil side) or "let
/// the deletion stand" (the nil side).
struct ShiftRecordConflict<T: ShiftConflictRecordType> {
    let kind: ShiftRecordKind
    let id: String
    let local: T?
    let remote: T?

    var title: String { (local ?? remote)?.conflictTitle ?? id }

    var fieldDiffs: [ShiftFieldDiff] {
        guard let l = local, let r = remote else { return [] }
        var diffs: [ShiftFieldDiff] = []
        for (a, b) in zip(l.fieldSnapshot(), r.fieldSnapshot()) where a.value != b.value {
            diffs.append(ShiftFieldDiff(field: a.label, local: a.value, remote: b.value))
        }
        return diffs
    }
}

struct ShiftAutoMergeNote {
    let kind: ShiftRecordKind
    let title: String
    let action: String
}

enum ShiftConflictChoice {
    case keepLocal
    case keepRemote
}

/// The full result of comparing Shift's three list files (tasks, follow-ups,
/// projects) across the merge-base/local/remote revisions. `resolved*`
/// arrays are already safe to write back as-is; `*Conflicts` need an
/// explicit choice per id before anything is written.
struct ShiftConflictSet {
    var taskConflicts: [ShiftRecordConflict<ShiftTask>] = []
    var followUpConflicts: [ShiftRecordConflict<ShiftFollowUp>] = []
    var projectConflicts: [ShiftRecordConflict<ShiftProject>] = []

    var resolvedTasks: [ShiftTask] = []
    var resolvedFollowUps: [ShiftFollowUp] = []
    var resolvedProjects: [ShiftProject] = []

    var autoMergeNotes: [ShiftAutoMergeNote] = []

    var totalConflictCount: Int { taskConflicts.count + followUpConflicts.count + projectConflicts.count }
    var hasConflicts: Bool { totalConflictCount > 0 }

    var affectedFileCount: Int {
        [!taskConflicts.isEmpty, !followUpConflicts.isEmpty, !projectConflicts.isEmpty].filter { $0 }.count
    }
}

/// The generic record-level 3-way merge, run once per record kind (tasks,
/// follow-ups, projects) with that kind's three loaded revisions. Pure
/// logic, no I/O - `ShiftGitSync` owns loading the three revisions via
/// `git show` and calling this.
enum ShiftThreeWayMerge {
    static func run<T: ShiftConflictRecordType>(
        kind: ShiftRecordKind, base: [T], local: [T], remote: [T]
    ) -> (resolved: [T], conflicts: [ShiftRecordConflict<T>], notes: [ShiftAutoMergeNote]) {
        let baseByID = Dictionary(base.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let localByID = Dictionary(local.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let remoteByID = Dictionary(remote.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let allIDs = Set(baseByID.keys).union(localByID.keys).union(remoteByID.keys)

        var resolved: [T] = []
        var conflicts: [ShiftRecordConflict<T>] = []
        var notes: [ShiftAutoMergeNote] = []

        for id in allIDs.sorted() {
            let b = baseByID[id]
            let l = localByID[id]
            let r = remoteByID[id]
            switch (b, l, r) {
            case (.none, .some(let lv), .none):
                resolved.append(lv)
                notes.append(ShiftAutoMergeNote(kind: kind, title: lv.conflictTitle, action: "Added locally"))
            case (.none, .none, .some(let rv)):
                resolved.append(rv)
                notes.append(ShiftAutoMergeNote(kind: kind, title: rv.conflictTitle, action: "Added on GitHub"))
            case (.none, .some(let lv), .some(let rv)):
                if lv == rv {
                    resolved.append(lv)
                } else {
                    conflicts.append(ShiftRecordConflict(kind: kind, id: id, local: lv, remote: rv))
                }
            case (.some, .none, .none):
                break // deleted on both sides - nothing to carry forward
            case (.some(let bv), .some(let lv), .none):
                if lv == bv {
                    notes.append(ShiftAutoMergeNote(kind: kind, title: lv.conflictTitle, action: "Removed (deleted on GitHub)"))
                } else {
                    conflicts.append(ShiftRecordConflict(kind: kind, id: id, local: lv, remote: nil))
                }
            case (.some(let bv), .none, .some(let rv)):
                if rv == bv {
                    notes.append(ShiftAutoMergeNote(kind: kind, title: rv.conflictTitle, action: "Removed locally"))
                } else {
                    conflicts.append(ShiftRecordConflict(kind: kind, id: id, local: nil, remote: rv))
                }
            case (.some(let bv), .some(let lv), .some(let rv)):
                if lv == rv {
                    resolved.append(lv)
                } else if lv == bv {
                    resolved.append(rv)
                    notes.append(ShiftAutoMergeNote(kind: kind, title: rv.conflictTitle, action: "Took GitHub's update (unchanged locally)"))
                } else if rv == bv {
                    resolved.append(lv)
                    notes.append(ShiftAutoMergeNote(kind: kind, title: lv.conflictTitle, action: "Kept your update (unchanged on GitHub)"))
                } else {
                    conflicts.append(ShiftRecordConflict(kind: kind, id: id, local: lv, remote: rv))
                }
            case (.none, .none, .none):
                break
            }
        }
        return (resolved, conflicts, notes)
    }
}
