// Manjesh Grand Line - native macOS app.
//
// `swift build && FM_RUN_STORE_DURABILITY_TESTS=1 .build/debug/FirstmateCockpit`
//
// Permanent regression coverage for GL-01 (store decode failure silently
// destroys user data) and GL-21 (`CommandLibraryStore` re-seeds over a failed
// directory read) - the two findings in phase 1 whose failure mode is
// *invisible*. A regression here does not crash, does not log, and does not
// look wrong on screen: it just quietly removes data the captain trusted the
// app with, which is exactly why it needs a test rather than a code read.
//
// The bar every case here is written to: **prove the original file is still on
// disk afterwards.** Asserting "the store loaded zero items" is not enough -
// that was true before the fix too. What matters is that the *next write*
// cannot destroy the bytes, so every case writes through the store after a
// failed load and then re-reads the original path (or its `.corrupt-` copy)
// to confirm the real data survived.
//
// Everything runs against a scratch directory via the stores' own `FM_*`
// overrides - never the captain's real `keys.json`, `snippets.json`,
// `history.json`, Shift clone or command library. `SSHKeyStore` is exercised
// through its metadata path only; no Keychain item is created or deleted here
// (that is `HostStoreSelfTest`/`BackupSelfTest` territory).

import Foundation
import Yaml

enum StoreDurabilitySelfTest {

    private static var failures: [String] = []

    private static func check(_ condition: Bool, _ label: String) {
        if condition {
            print("  ✓ \(label)")
        } else {
            print("  ✗ \(label)")
            failures.append(label)
        }
    }

    static func run() -> Bool {
        print("== Store durability self-test (GL-01 / GL-21) ==")
        failures = []

        let scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("fm-store-durability-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        sshKeyStoreBacksUpAndDoesNotOverwrite(scratch: scratch)
        snippetStoreBacksUpAndDoesNotOverwrite(scratch: scratch)
        dictationStoreBacksUpAndDoesNotOverwrite(scratch: scratch)
        shiftDistinguishesMissingFromCorrupt(scratch: scratch)
        shiftRefusesWritesWhileLoadFailed(scratch: scratch)
        commandLibraryDoesNotSeedOverAFailedRead(scratch: scratch)

        print(failures.isEmpty
            ? "== PASS (store durability) =="
            : "== FAIL (store durability): \(failures.count) case(s) ==")
        return failures.isEmpty
    }

    // MARK: - Helpers

    /// Runs `body` with `key` set to `value` in the process environment, then
    /// restores whatever was there. The stores read these at `init`, so each
    /// case constructs its store inside the closure.
    private static func withEnv(_ pairs: [String: String], _ body: () -> Void) {
        var previous: [String: String?] = [:]
        for (k, v) in pairs {
            previous[k] = ProcessInfo.processInfo.environment[k]
            setenv(k, v, 1)
        }
        body()
        for (k, old) in previous {
            if let old { setenv(k, old, 1) } else { unsetenv(k) }
        }
    }

    private static func corruptBackupPaths(besides original: URL) -> [URL] {
        let dir = original.deletingLastPathComponent()
        let entries = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return entries.filter { $0.lastPathComponent.hasPrefix(original.lastPathComponent + ".corrupt-") }
    }

    // MARK: - GL-01: the three JSON stores

    private static func sshKeyStoreBacksUpAndDoesNotOverwrite(scratch: URL) {
        print("- SSHKeyStore: an undecodable keys.json is preserved, not overwritten")
        let file = scratch.appendingPathComponent("keys.json")
        // Realistic damage: a truncated write, which decodes as neither
        // `[SSHKey]` nor anything else - not a syntactically wild string.
        let realBytes = #"[{"id":"6F9619FF-8B86-D011-B42D-00CF4FC964FF","label":"prod-ed25519","#
        try? realBytes.write(to: file, atomically: true, encoding: .utf8)

        withEnv(["FM_KEYS_FILE": file.path]) {
            let store = SSHKeyStore()
            check(store.keys.isEmpty, "load() yields an empty list rather than crashing")
            check(store.loadFailureBackupPath != nil, "the failure is reported (loadFailureBackupPath is set)")

            // The write that used to destroy the file.
            store.add(SSHKey(label: "new-key", type: .ed25519, publicKey: "ssh-ed25519 AAAA", fingerprint: "SHA256:x", certificate: nil))

            let backups = corruptBackupPaths(besides: file)
            check(backups.count == 1, "exactly one .corrupt- backup exists")
            let recovered = backups.first.flatMap { try? String(contentsOf: $0, encoding: .utf8) }
            check(recovered == realBytes, "the backup holds the original bytes byte-for-byte")
        }
    }

    private static func snippetStoreBacksUpAndDoesNotOverwrite(scratch: URL) {
        print("- SnippetStore: an undecodable snippets.json is preserved, not overwritten")
        let file = scratch.appendingPathComponent("snippets.json")
        let realBytes = #"[{"id":"not-a-uuid","label":"attach tmux","command":"tmux a"}]"#
        try? realBytes.write(to: file, atomically: true, encoding: .utf8)

        withEnv(["FM_SNIPPETS_FILE": file.path]) {
            let store = SnippetStore()
            check(store.snippets.isEmpty, "load() yields an empty list")
            check(store.loadFailureBackupPath != nil, "the failure is reported")
            store.add(Snippet(label: "fresh", command: "echo hi"))
            let backups = corruptBackupPaths(besides: file)
            check(backups.count == 1, "exactly one .corrupt- backup exists")
            let recovered = backups.first.flatMap { try? String(contentsOf: $0, encoding: .utf8) }
            check(recovered == realBytes, "the backup holds the original bytes")
        }
    }

    private static func dictationStoreBacksUpAndDoesNotOverwrite(scratch: URL) {
        print("- DictationStore: an undecodable history.json is preserved, not overwritten")
        let dir = scratch.appendingPathComponent("dictation", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("history.json")
        // A real transcript array whose date encoding no longer matches - the
        // exact shape a decoder-strategy change would produce.
        let realBytes = #"[{"id":"A","text":"deploy the api","durationSeconds":2.5,"createdAt":1750000000}]"#
        try? realBytes.write(to: file, atomically: true, encoding: .utf8)

        withEnv(["FM_DICTATION_DIR": dir.path]) {
            let store = DictationStore()
            check(store.history.isEmpty, "loadHistory() yields an empty list")
            check(!store.loadFailureBackupPaths.isEmpty, "the failure is reported")
            store.recordHistory(text: "a brand new transcript", durationSeconds: 1, date: Date())
            let backups = corruptBackupPaths(besides: file)
            check(backups.count == 1, "exactly one .corrupt- backup exists")
            let recovered = backups.first.flatMap { try? String(contentsOf: $0, encoding: .utf8) }
            check(recovered == realBytes, "the backup holds the original transcript bytes")
        }
    }

    // MARK: - GL-01: Shift's YAML

    private static func shiftDistinguishesMissingFromCorrupt(scratch: URL) {
        print("- ShiftYaml: `missing`, `ok` and `parseFailed` are three different answers")
        let dir = scratch.appendingPathComponent("shift-reads", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let absent = dir.appendingPathComponent("absent.yaml").path
        if case .missing = ShiftYaml.readListChecked(path: absent, key: "tasks") {
            check(true, "a file that does not exist reads as .missing")
        } else {
            check(false, "a file that does not exist reads as .missing")
        }

        let empty = dir.appendingPathComponent("empty.yaml")
        try? "\n  \n".write(to: empty, atomically: true, encoding: .utf8)
        if case .missing = ShiftYaml.readListChecked(path: empty.path, key: "tasks") {
            check(true, "a whitespace-only file reads as .missing")
        } else {
            check(false, "a whitespace-only file reads as .missing")
        }

        // The shape `writeList` produces for a genuinely empty list must stay
        // `.ok([])`, not `.parseFailed` - otherwise a captain with no tasks
        // would find Shift permanently read-only.
        let emptyList = dir.appendingPathComponent("empty-list.yaml")
        try? "\"tasks\": []\n".write(to: emptyList, atomically: true, encoding: .utf8)
        if case .ok(let items) = ShiftYaml.readListChecked(path: emptyList.path, key: "tasks") {
            check(items.isEmpty, "a valid document with an empty list reads as .ok([])")
        } else {
            check(false, "a valid document with an empty list reads as .ok([])")
        }

        // A real syntax error: an unterminated flow sequence.
        let broken = dir.appendingPathComponent("broken.yaml")
        try? "\"tasks\": [ {id: a, title: \"x\"\n".write(to: broken, atomically: true, encoding: .utf8)
        if case .parseFailed = ShiftYaml.readListChecked(path: broken.path, key: "tasks") {
            check(true, "a YAML syntax error reads as .parseFailed")
        } else {
            check(false, "a YAML syntax error reads as .parseFailed")
        }
    }

    private static func shiftRefusesWritesWhileLoadFailed(scratch: URL) {
        print("- ShiftStore: a corrupt active.yaml is never overwritten, and never synced")
        let root = scratch.appendingPathComponent("shift-store", isDirectory: true)
        let tasksDir = root.appendingPathComponent("tasks", isDirectory: true)
        try? FileManager.default.createDirectory(at: tasksDir, withIntermediateDirectories: true)
        let active = tasksDir.appendingPathComponent("active.yaml")

        // Two real tasks, then a syntax error - the "hand-edited the file and
        // fat-fingered a bracket" case the finding describes.
        let realBytes = """
        "tasks":
          - "id": "task-one"
            "title": "Ship phase 1"
          - "id": "task-two
            "title": "Broken quoting above this line"
        """
        try? realBytes.write(to: active, atomically: true, encoding: .utf8)

        withEnv(["FM_SHIFT_DIR": root.path]) {
            let store = ShiftStore()
            check(store.activeTasks.isEmpty, "the corrupt file yields no in-memory tasks")
            check(store.isInFailedLoadState, "the store knows it is in a failed-load state")
            check(store.loadFailurePaths.contains(active.path), "the failing path is named")

            // The write that used to wipe the file.
            var newTask = ShiftTask.fresh()
            newTask.id = "task-three"
            newTask.title = "A task added after the failure"
            store.addTask(newTask)

            let onDisk = (try? String(contentsOf: active, encoding: .utf8)) ?? ""
            check(onDisk == realBytes, "active.yaml still holds the original bytes after a write attempt")
            check(!onDisk.contains("task-three"), "the new task was NOT written over the corrupt file")

            let backups = corruptBackupPaths(besides: active)
            check(backups.count == 1, "the corrupt file was backed up once")

            // And the fix must clear itself: repair the file, reload, write.
            try? "\"tasks\": []\n".write(to: active, atomically: true, encoding: .utf8)
            store.reloadAll()
            check(!store.isInFailedLoadState, "reloading a repaired file clears the failed state")
            var repaired = ShiftTask.fresh()
            repaired.id = "task-four"
            repaired.title = "Written after repair"
            store.addTask(repaired)
            let afterRepair = (try? String(contentsOf: active, encoding: .utf8)) ?? ""
            check(afterRepair.contains("task-four"), "writes resume once the file parses again")
        }
    }

    // MARK: - GL-21

    private static func commandLibraryDoesNotSeedOverAFailedRead(scratch: URL) {
        print("- CommandLibraryStore: a failed directory read is not treated as 'empty'")

        // A genuinely empty library still seeds - the behaviour that must not
        // regress in the other direction.
        let fresh = scratch.appendingPathComponent("cmdlib-fresh", isDirectory: true)
        withEnv(["FM_COMMAND_LIBRARY_DIR": fresh.path]) {
            let store = CommandLibraryStore()
            check(!store.commands.isEmpty, "a genuinely empty library still seeds")
        }

        // Enumeration failure: `root` exists as a *file*, so
        // `contentsOfDirectory` throws rather than returning an empty list.
        // Before GL-21 this looked identical to "empty" and triggered a
        // 73-file seed.
        let blocked = scratch.appendingPathComponent("cmdlib-blocked")
        try? "not a directory".write(to: blocked, atomically: true, encoding: .utf8)
        withEnv(["FM_COMMAND_LIBRARY_DIR": blocked.path]) {
            let store = CommandLibraryStore()
            check(store.commands.isEmpty, "an unreadable root yields no commands")
            let stillAFile = (try? String(contentsOf: blocked, encoding: .utf8)) == "not a directory"
            check(stillAFile, "the unreadable path was left exactly as it was - no seed files written")
        }
    }
}
