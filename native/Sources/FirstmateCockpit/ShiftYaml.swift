// Manjesh Grand Line - native macOS app.
//
// Shift <-> Yaml conversions, and the one place that reads/writes a Shift
// YAML file end to end. Uses the vendored `Yaml` library (Vendor/YamlSwift)
// for parsing and `YamlBeautify.dump` for serialization - deliberately not a
// second hand-rolled YAML writer, so this file automatically inherits
// YamlBeautify's order-preservation and quote-preservation patches (see
// YamlBeautify.swift's header) for free: a value round-tripped through
// `Yaml.load` -> mutate -> `YamlBeautify.dump` keeps whatever key order and
// scalar quoting the file already had, and every string field this file
// writes fresh is written double-quoted (`.string(_, quoted: .double)`) so a
// later beautify pass doesn't have to guess whether it needs quoting.

import Foundation
import Yaml

enum ShiftYaml {

    // MARK: Scalar helpers

    private static func str(_ s: String) -> Yaml { .string(s, quoted: .double) }

    private static func strOpt(_ s: String?) -> Yaml { s.map(str) ?? .null }

    private static func optString(_ y: Yaml) -> String? {
        switch y {
        case .null: return nil
        case .string(let s, _): return s.isEmpty ? nil : s
        default: return nil
        }
    }

    private static func reqString(_ y: Yaml) -> String {
        optString(y) ?? ""
    }

    // MARK: Subtask

    static func toYaml(_ s: ShiftSubtask) -> Yaml {
        var m = YamlOrderedMap()
        m[str("id")] = str(s.id)
        m[str("title")] = str(s.title)
        m[str("done")] = .bool(s.done)
        return .dictionary(m)
    }

    static func subtask(from y: Yaml) -> ShiftSubtask? {
        guard let dict = y.dictionary else { return nil }
        return ShiftSubtask(
            id: reqString(dict[str("id")] ?? .null),
            title: reqString(dict[str("title")] ?? .null),
            done: dict[str("done")]?.bool ?? false
        )
    }

    // MARK: Task

    static func toYaml(_ t: ShiftTask) -> Yaml {
        var m = YamlOrderedMap()
        m[str("id")] = str(t.id)
        m[str("title")] = str(t.title)
        m[str("description")] = str(t.description)
        m[str("status")] = str(t.status.rawValue)
        m[str("priority")] = str(t.priority.rawValue)
        m[str("due_date")] = strOpt(t.dueDate)
        m[str("due_time")] = strOpt(t.dueTime)
        m[str("project_id")] = strOpt(t.projectID)
        m[str("tags")] = .array(t.tags.map(str))
        m[str("created_at")] = str(t.createdAt)
        m[str("updated_at")] = str(t.updatedAt)
        m[str("completed_at")] = strOpt(t.completedAt)
        m[str("notes")] = strOpt(t.notes)
        m[str("subtasks")] = .array(t.subtasks.map(toYaml))
        return .dictionary(m)
    }

    static func task(from y: Yaml) -> ShiftTask? {
        guard let dict = y.dictionary else { return nil }
        let id = reqString(dict[str("id")] ?? .null)
        guard !id.isEmpty else { return nil }
        let subtasksYaml = dict[str("subtasks")]?.array ?? []
        return ShiftTask(
            id: id,
            title: reqString(dict[str("title")] ?? .null),
            description: reqString(dict[str("description")] ?? .null),
            status: ShiftTaskStatus(rawValue: reqString(dict[str("status")] ?? .null)) ?? .todo,
            priority: ShiftPriority(rawValue: reqString(dict[str("priority")] ?? .null)) ?? .normal,
            dueDate: optString(dict[str("due_date")] ?? .null),
            dueTime: optString(dict[str("due_time")] ?? .null),
            projectID: optString(dict[str("project_id")] ?? .null),
            tags: (dict[str("tags")]?.array ?? []).compactMap { optString($0) },
            createdAt: reqString(dict[str("created_at")] ?? .null),
            updatedAt: reqString(dict[str("updated_at")] ?? .null),
            completedAt: optString(dict[str("completed_at")] ?? .null),
            notes: optString(dict[str("notes")] ?? .null),
            subtasks: subtasksYaml.compactMap(subtask(from:))
        )
    }

    // MARK: Follow-up

    static func toYaml(_ f: ShiftFollowUp) -> Yaml {
        var m = YamlOrderedMap()
        m[str("id")] = str(f.id)
        m[str("title")] = str(f.title)
        m[str("status")] = str(f.status.rawValue)
        m[str("priority")] = str(f.priority.rawValue)
        m[str("follow_up_at")] = strOpt(f.followUpAt)
        m[str("follow_up_time")] = strOpt(f.followUpTime)
        m[str("related_task_id")] = strOpt(f.relatedTaskID)
        m[str("project_id")] = strOpt(f.projectID)
        m[str("notes")] = strOpt(f.notes)
        return .dictionary(m)
    }

    static func followUp(from y: Yaml) -> ShiftFollowUp? {
        guard let dict = y.dictionary else { return nil }
        let id = reqString(dict[str("id")] ?? .null)
        guard !id.isEmpty else { return nil }
        return ShiftFollowUp(
            id: id,
            title: reqString(dict[str("title")] ?? .null),
            status: ShiftFollowUpStatus(rawValue: reqString(dict[str("status")] ?? .null)) ?? .pending,
            priority: ShiftPriority(rawValue: reqString(dict[str("priority")] ?? .null)) ?? .normal,
            followUpAt: optString(dict[str("follow_up_at")] ?? .null),
            followUpTime: optString(dict[str("follow_up_time")] ?? .null),
            relatedTaskID: optString(dict[str("related_task_id")] ?? .null),
            projectID: optString(dict[str("project_id")] ?? .null),
            notes: optString(dict[str("notes")] ?? .null)
        )
    }

    // MARK: Project

    static func toYaml(_ p: ShiftProject) -> Yaml {
        var m = YamlOrderedMap()
        m[str("id")] = str(p.id)
        m[str("name")] = str(p.name)
        m[str("status")] = str(p.status.rawValue)
        m[str("created_at")] = str(p.createdAt)
        return .dictionary(m)
    }

    static func project(from y: Yaml) -> ShiftProject? {
        guard let dict = y.dictionary else { return nil }
        let id = reqString(dict[str("id")] ?? .null)
        guard !id.isEmpty else { return nil }
        return ShiftProject(
            id: id,
            name: reqString(dict[str("name")] ?? .null),
            status: ShiftProjectStatus(rawValue: reqString(dict[str("status")] ?? .null)) ?? .active,
            createdAt: reqString(dict[str("created_at")] ?? .null)
        )
    }

    // MARK: Note

    static func toYaml(_ n: ShiftNote) -> Yaml {
        var m = YamlOrderedMap()
        m[str("id")] = str(n.id)
        m[str("title")] = str(n.title)
        m[str("body")] = str(n.body)
        m[str("created_at")] = str(n.createdAt)
        return .dictionary(m)
    }

    static func note(from y: Yaml) -> ShiftNote? {
        guard let dict = y.dictionary else { return nil }
        let id = reqString(dict[str("id")] ?? .null)
        guard !id.isEmpty else { return nil }
        return ShiftNote(
            id: id,
            title: reqString(dict[str("title")] ?? .null),
            body: reqString(dict[str("body")] ?? .null),
            createdAt: reqString(dict[str("created_at")] ?? .null)
        )
    }

    // MARK: Activity

    static func toYaml(_ a: ShiftActivityEntry) -> Yaml {
        var m = YamlOrderedMap()
        m[str("id")] = str(a.id)
        m[str("timestamp")] = str(a.timestamp)
        m[str("kind")] = str(a.kind)
        m[str("summary")] = str(a.summary)
        return .dictionary(m)
    }

    static func activity(from y: Yaml) -> ShiftActivityEntry? {
        guard let dict = y.dictionary else { return nil }
        let id = reqString(dict[str("id")] ?? .null)
        guard !id.isEmpty else { return nil }
        return ShiftActivityEntry(
            id: id,
            timestamp: reqString(dict[str("timestamp")] ?? .null),
            kind: reqString(dict[str("kind")] ?? .null),
            summary: reqString(dict[str("summary")] ?? .null)
        )
    }

    // MARK: Settings

    static func toYaml(_ s: ShiftSettings) -> Yaml {
        var m = YamlOrderedMap()
        m[str("sync_status")] = str(s.syncStatus)
        return .dictionary(m)
    }

    static func settings(from y: Yaml) -> ShiftSettings {
        guard let dict = y.dictionary else { return ShiftSettings() }
        return ShiftSettings(syncStatus: optString(dict[str("sync_status")] ?? .null) ?? "Synced")
    }

    // MARK: Whole-document (top-level `<key>: [ ... ]` mapping)

    /// Reads `path`, parses it as a single YAML document, and returns the
    /// array under `key` (empty if the file doesn't exist yet or the key is
    /// missing) - the shared shape every list file
    /// (active/completed/follow-ups/projects/notes/activity) uses.
    static func readList(path: String, key: String) -> [Yaml] {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8), !text.isEmpty else { return [] }
        guard let doc = try? Yaml.load(text) else { return [] }
        return doc.dictionary?[str(key)]?.array ?? []
    }

    /// Serializes `items` under `key` as one YAML document and writes it to
    /// `path` atomically, creating parent directories as needed.
    static func writeList(path: String, key: String, items: [Yaml]) throws {
        var m = YamlOrderedMap()
        m[str(key)] = .array(items)
        let text = YamlBeautify.dump([.dictionary(m)])
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (text + "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    /// Reads a flat mapping document (`settings.yaml`'s shape) rather than a
    /// `key: [ ... ]` list.
    static func readMapping(path: String) -> Yaml? {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8), !text.isEmpty else { return nil }
        return try? Yaml.load(text)
    }

    static func writeMapping(path: String, doc: Yaml) throws {
        let text = YamlBeautify.dump([doc])
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (text + "\n").write(to: url, atomically: true, encoding: .utf8)
    }
}
