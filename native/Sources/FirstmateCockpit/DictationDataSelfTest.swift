// Manjesh Grand Line - native macOS app.
//
// Permanent, dependency-free self-test for Dictation phase 2's pure data
// layer (fm/grandline-dictation-phase2) - `DictationStore`'s history/
// vocabulary persistence (real scratch files, never the captain's real
// `FM_DICTATION_DIR`) and `DictationShortcut`'s encode/decode + display-string
// logic. Same convention as `HostStoreSelfTest.swift`/`ShiftStoreSelfTest.swift`
// - drives the real store against a real temp directory, reloading via a
// fresh instance between steps to catch anything that only "worked" because
// of leftover in-memory state.
// `FM_RUN_DICTATION_DATA_TESTS=1 .build/debug/FirstmateCockpit`.

import Foundation

enum DictationDataSelfTest {
    static func run() -> Bool {
        var ok = true
        let scratchDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("grandline-dictation-data-selftest-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: scratchDir) }

        setenv("FM_DICTATION_DIR", scratchDir.path, 1)
        defer { unsetenv("FM_DICTATION_DIR") }

        // 1. A fresh store (no files yet) starts empty.
        do {
            let store = DictationStore()
            check(store.history.isEmpty, "a fresh store should have no history", &ok)
            check(store.vocabulary.isEmpty, "a fresh store should have no vocabulary", &ok)
        }

        // 2. Recording history persists to disk and survives a reload via a
        //    separate store instance - newest entry first.
        do {
            let store = DictationStore()
            let firstDate = Date(timeIntervalSince1970: 1_700_000_000)
            let secondDate = Date(timeIntervalSince1970: 1_700_000_100)
            store.recordHistory(text: "first thing said", durationSeconds: 3.2, date: firstDate)
            store.recordHistory(text: "second thing said", durationSeconds: 1.5, date: secondDate)

            let reloaded = DictationStore()
            check(reloaded.history.count == 2, "both recorded entries should survive a reload", &ok)
            check(reloaded.history.first?.text == "second thing said", "history should be newest-first", &ok)
            check(reloaded.history.last?.text == "first thing said", "the first entry should still be present", &ok)
            check(abs((reloaded.history.first?.durationSeconds ?? -1) - 1.5) < 0.001, "duration should round-trip exactly", &ok)
        }

        // 3. Vocabulary add/remove persists and survives a reload;
        //    case-insensitive duplicates are rejected, not appended twice.
        do {
            let store = DictationStore()
            store.addVocabularyWord("Kubernetes")
            store.addVocabularyWord("kubernetes") // case-insensitive duplicate
            store.addVocabularyWord("Manjesh")
            check(store.vocabulary.count == 2, "a case-insensitive duplicate must not be added twice", &ok)

            let reloaded = DictationStore()
            check(reloaded.vocabulary.sorted() == ["Kubernetes", "Manjesh"].sorted(), "vocabulary should survive a reload", &ok)

            reloaded.removeVocabularyWord("Kubernetes")
            check(reloaded.vocabulary == ["Manjesh"], "removing a word should leave the other one intact", &ok)

            let reloadedAgain = DictationStore()
            check(reloadedAgain.vocabulary == ["Manjesh"], "a removal should also survive a reload", &ok)
        }

        // 4. `DictationShortcut` round-trips through JSON exactly as
        //    `AppSettings.dictationShortcut` stores it.
        do {
            let combo = DictationShortcut(keyCode: 2, modifierFlagsRaw: NSEventModifierFlagsCommandShift, isModifierOnly: false)
            let data = try? JSONEncoder().encode(combo)
            check(data != nil, "a shortcut should encode to JSON", &ok)
            if let data, let decoded = try? JSONDecoder().decode(DictationShortcut.self, from: data) {
                check(decoded == combo, "a shortcut should decode back to an identical value", &ok)
            } else {
                check(false, "a shortcut should decode back from its own encoded JSON", &ok)
            }
        }

        // 5. Display strings for a few known combos - a modifier-only
        //    default (Right ⌥ Option) and a regular-key combo (⌘⇧D).
        do {
            check(DictationShortcut.defaultShortcut.displayString == "Right ⌥", "the default shortcut should display as 'Right ⌥'", &ok)
            let combo = DictationShortcut(keyCode: 2, modifierFlagsRaw: NSEventModifierFlagsCommandShift, isModifierOnly: false)
            check(combo.displayString == "⇧⌘D", "⌘⇧D should display in the standard ⇧⌘ ordering", &ok)
        }

        return ok
    }

    /// `.command.rawValue | .shift.rawValue`, spelled out as a plain
    /// constant here so this file has no `AppKit` import of its own (the
    /// rest of Dictation's pure-logic self-tests - this one included - avoid
    /// pulling in AppKit where `Foundation` alone suffices).
    private static let NSEventModifierFlagsCommandShift: UInt = (1 << 20) | (1 << 17)

    private static func check(_ condition: Bool, _ message: String, _ ok: inout Bool) {
        if !condition {
            print("FAIL: \(message)")
            ok = false
        }
    }
}
