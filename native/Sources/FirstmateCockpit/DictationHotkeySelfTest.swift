// Manjesh Grand Line - native macOS app.
//
// Permanent, dependency-free self-test for `DictationHotkey.handle(_:)`'s
// pure hold/release detection logic (same convention as
// `AppLockControllerSelfTest.swift`/`ShiftDateParserSelfTest.swift` - see
// AGENTS.md's "Verifying native UI bugs" entry). Drives real synthetic
// `.flagsChanged` `NSEvent`s through the real `handle(_:)` method - no real
// event loop, no real Accessibility trust, no real keyboard involved.
// `FM_RUN_DICTATION_HOTKEY_TESTS=1 .build/debug/FirstmateCockpit`.

import AppKit

enum DictationHotkeySelfTest {
    static func run() -> Bool {
        var ok = true

        func flagsChanged(keyCode: UInt16, optionHeld: Bool) -> NSEvent {
            NSEvent.keyEvent(
                with: .flagsChanged,
                location: .zero,
                modifierFlags: optionHeld ? [.option] : [],
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                characters: "",
                charactersIgnoringModifiers: "",
                isARepeat: false,
                keyCode: keyCode
            )!
        }

        // 1. Holding Right ⌥ Option fires onDown exactly once, releasing
        //    fires onUp exactly once.
        do {
            var downCount = 0
            var upCount = 0
            let hotkey = DictationHotkey(onDown: { downCount += 1 }, onUp: { upCount += 1 })
            hotkey.handle(flagsChanged(keyCode: DictationHotkey.rightOptionKeyCode, optionHeld: true))
            check(downCount == 1, "pressing right option should fire onDown once", &ok)
            check(upCount == 0, "onUp should not fire yet while still held", &ok)
            hotkey.handle(flagsChanged(keyCode: DictationHotkey.rightOptionKeyCode, optionHeld: false))
            check(upCount == 1, "releasing right option should fire onUp once", &ok)
        }

        // 2. A repeated flagsChanged event carrying the same held state
        //    (macOS can coalesce/redeliver) must not double-fire.
        do {
            var downCount = 0
            var upCount = 0
            let hotkey = DictationHotkey(onDown: { downCount += 1 }, onUp: { upCount += 1 })
            hotkey.handle(flagsChanged(keyCode: DictationHotkey.rightOptionKeyCode, optionHeld: true))
            hotkey.handle(flagsChanged(keyCode: DictationHotkey.rightOptionKeyCode, optionHeld: true))
            hotkey.handle(flagsChanged(keyCode: DictationHotkey.rightOptionKeyCode, optionHeld: true))
            check(downCount == 1, "repeated held-state events should not re-fire onDown", &ok)
            hotkey.handle(flagsChanged(keyCode: DictationHotkey.rightOptionKeyCode, optionHeld: false))
            hotkey.handle(flagsChanged(keyCode: DictationHotkey.rightOptionKeyCode, optionHeld: false))
            check(upCount == 1, "repeated released-state events should not re-fire onUp", &ok)
        }

        // 3. Left ⌥ Option (keyCode 58) must never trigger dictation - only
        //    the right-hand key does, matching OpenSuperWhisper's own
        //    shortcut shape.
        do {
            var downCount = 0
            var upCount = 0
            let hotkey = DictationHotkey(onDown: { downCount += 1 }, onUp: { upCount += 1 })
            hotkey.handle(flagsChanged(keyCode: 58, optionHeld: true))
            hotkey.handle(flagsChanged(keyCode: 58, optionHeld: false))
            check(downCount == 0 && upCount == 0, "left option must never trigger dictation", &ok)
        }

        // 4. An unrelated flagsChanged event (e.g. Shift, Control) at a
        //    different keyCode must not be mistaken for right option.
        do {
            var downCount = 0
            let hotkey = DictationHotkey(onDown: { downCount += 1 }, onUp: {})
            hotkey.handle(flagsChanged(keyCode: 56, optionHeld: false)) // left shift keyCode
            check(downCount == 0, "an unrelated modifier keyCode must not trigger dictation", &ok)
        }

        return ok
    }

    private static func check(_ condition: Bool, _ message: String, _ ok: inout Bool) {
        if !condition {
            print("FAIL: \(message)")
            ok = false
        }
    }
}
