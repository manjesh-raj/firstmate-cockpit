// Manjesh Grand Line - native macOS app.
//
// Permanent, dependency-free self-test for `DictationHotkey.handle(_:)`'s
// pure hold/release detection logic (same convention as
// `AppLockControllerSelfTest.swift`/`ShiftDateParserSelfTest.swift` - see
// AGENTS.md's "Verifying native UI bugs" entry). Drives real synthetic
// `.flagsChanged` `NSEvent`s through the real `handle(_:)` method - no real
// event loop, no real Accessibility trust, no real keyboard involved.
// `FM_RUN_DICTATION_HOTKEY_TESTS=1 .build/debug/FirstmateCockpit`.
//
// Phase 2 (fm/grandline-dictation-phase2) extended this with
// `handleKeyEvent(_:)` coverage - a regular-key + modifiers combo (the shape
// a captain's own recorded shortcut can now take, unlike phase 1's
// modifier-only Right ⌥ Option) fires `.keyDown`/`.keyUp`, not
// `.flagsChanged`, so it needed its own synthetic-event coverage rather than
// assuming the existing `handle(_:)` tests generalized.
//
// `fm/grandline-dictation-global-hotkey-and-theme-fixes` closed a real
// coverage gap this file had until now: every test above drives
// `handle(_:)`/`handleKeyEvent(_:)` directly, which proves the hold/release
// *decision logic* is correct but never proves `start()`/`updateShortcut(_:)`
// actually install a real `NSEvent.addGlobalMonitorForEvents` monitor at
// all - a future edit that silently dropped the global registration (e.g.
// installed only the local monitor for one of the two mechanisms) would
// have kept passing every test that existed before this. Tests 10-12 below
// close that gap structurally, by calling the real `start()`/
// `updateShortcut(_:)`/`stop()` and inspecting the now-internal
// `localFlagsMonitor`/`globalFlagsMonitor`/`localKeyMonitor`/
// `globalKeyMonitor` tokens - confirming the correct pair is non-nil for
// whichever mechanism the current shortcut needs, and that the *other*
// mechanism's tokens are nil, at every stage of a modifier-only ->
// regular-key -> modifier-only round trip (the exact "switching monitor
// mechanisms" scenario this task's own brief suspected was broken).
//
// This does NOT (and structurally cannot, in a plain unit test) prove a
// *global*, other-app-frontmost monitor actually receives real system
// events - that needs a live process, real Accessibility trust, and a real
// event source. That live proof was done manually during this task via
// `CGEventPost` at the HID event-tap level (the same "indistinguishable
// from real hardware" technique this codebase already uses for `SRELead`/
// `AppLock` verification - see the "Verifying native UI bugs" convention in
// AGENTS.md) against the real signed app, with a genuinely different
// frontmost app (TextEdit): the default modifier-only shortcut fired
// correctly with TextEdit frontmost, and a full modifier-only ->
// regular-key -> modifier-only `updateShortcut` cycle fired correctly at
// every stage, each confirmed with the real frontmost app re-verified
// immediately before every synthetic keypress (an early, sloppier pass
// without that immediate re-check produced one false negative, traced to
// focus having reverted to Grand Line between the check and the keypress -
// not a code defect). No genuine defect in `DictationHotkey`'s monitor
// installation/switching was found; see `AGENTS.md`'s "Dictation" section
// for the full write-up of what was tested and why the reported symptom
// could not be reproduced against current `main`.

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

        func keyEvent(type: NSEvent.EventType, keyCode: UInt16, modifiers: NSEvent.ModifierFlags, isRepeat: Bool = false) -> NSEvent {
            NSEvent.keyEvent(
                with: type,
                location: .zero,
                modifierFlags: modifiers,
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                characters: "d",
                charactersIgnoringModifiers: "d",
                isARepeat: isRepeat,
                keyCode: keyCode
            )!
        }

        // 5. A regular-key + modifiers combo (⌘⇧D) fires onDown on keyDown,
        //    onUp on keyUp - the shape a captain's own recorded shortcut can
        //    now take, unlike phase 1's modifier-only default.
        do {
            let combo = DictationShortcut(keyCode: 2 /* D */, modifierFlagsRaw: NSEvent.ModifierFlags.command.rawValue | NSEvent.ModifierFlags.shift.rawValue, isModifierOnly: false)
            var downCount = 0
            var upCount = 0
            let hotkey = DictationHotkey(shortcut: combo, onDown: { downCount += 1 }, onUp: { upCount += 1 })
            hotkey.handleKeyEvent(keyEvent(type: .keyDown, keyCode: 2, modifiers: [.command, .shift]))
            check(downCount == 1, "pressing the recorded combo should fire onDown once", &ok)
            check(upCount == 0, "onUp should not fire yet while still held", &ok)
            hotkey.handleKeyEvent(keyEvent(type: .keyUp, keyCode: 2, modifiers: [.command, .shift]))
            check(upCount == 1, "releasing the recorded combo should fire onUp once", &ok)
        }

        // 6. Auto-repeat keyDown events while a combo is held must not
        //    re-fire onDown - macOS resends `.keyDown` on repeat.
        do {
            let combo = DictationShortcut(keyCode: 2, modifierFlagsRaw: NSEvent.ModifierFlags.command.rawValue | NSEvent.ModifierFlags.shift.rawValue, isModifierOnly: false)
            var downCount = 0
            let hotkey = DictationHotkey(shortcut: combo, onDown: { downCount += 1 }, onUp: {})
            hotkey.handleKeyEvent(keyEvent(type: .keyDown, keyCode: 2, modifiers: [.command, .shift]))
            hotkey.handleKeyEvent(keyEvent(type: .keyDown, keyCode: 2, modifiers: [.command, .shift], isRepeat: true))
            hotkey.handleKeyEvent(keyEvent(type: .keyDown, keyCode: 2, modifiers: [.command, .shift], isRepeat: true))
            check(downCount == 1, "auto-repeat keyDown events must not re-fire onDown", &ok)
        }

        // 7. A combo's modifier match is exact (not `.contains`, unlike the
        //    modifier-only case) - an extra held modifier must not trigger.
        do {
            let combo = DictationShortcut(keyCode: 2, modifierFlagsRaw: NSEvent.ModifierFlags.command.rawValue | NSEvent.ModifierFlags.shift.rawValue, isModifierOnly: false)
            var downCount = 0
            let hotkey = DictationHotkey(shortcut: combo, onDown: { downCount += 1 }, onUp: {})
            hotkey.handleKeyEvent(keyEvent(type: .keyDown, keyCode: 2, modifiers: [.command, .shift, .control]))
            check(downCount == 0, "an extra held modifier must not match an exact combo", &ok)
        }

        // 8. A modifier-only shortcut must never respond to `handleKeyEvent`,
        //    and a regular-key combo must never respond to `handle` - the two
        //    mechanisms are mutually exclusive per shortcut.
        do {
            let modifierOnly = DictationShortcut.defaultShortcut
            var downCount = 0
            let hotkey = DictationHotkey(shortcut: modifierOnly, onDown: { downCount += 1 }, onUp: {})
            hotkey.handleKeyEvent(keyEvent(type: .keyDown, keyCode: modifierOnly.keyCode, modifiers: modifierOnly.modifiers))
            check(downCount == 0, "a modifier-only shortcut must not respond to handleKeyEvent", &ok)

            let combo = DictationShortcut(keyCode: 2, modifierFlagsRaw: NSEvent.ModifierFlags.command.rawValue, isModifierOnly: false)
            var comboDownCount = 0
            let comboHotkey = DictationHotkey(shortcut: combo, onDown: { comboDownCount += 1 }, onUp: {})
            comboHotkey.handle(flagsChanged(keyCode: combo.keyCode, optionHeld: true))
            check(comboDownCount == 0, "a regular-key combo must not respond to handle (flagsChanged)", &ok)
        }

        // 9. `updateShortcut` switches which monitor mechanism a live
        //    `DictationHotkey` responds to - dispatch through `handle`/
        //    `handleKeyEvent` directly here (no real monitors), just checking
        //    the stored shortcut and per-mechanism guards update together.
        do {
            var downCount = 0
            let hotkey = DictationHotkey(onDown: { downCount += 1 }, onUp: {})
            hotkey.handle(flagsChanged(keyCode: DictationHotkey.rightOptionKeyCode, optionHeld: true))
            check(downCount == 1, "default modifier-only shortcut should still fire via handle", &ok)
            hotkey.handle(flagsChanged(keyCode: DictationHotkey.rightOptionKeyCode, optionHeld: false))

            let combo = DictationShortcut(keyCode: 2, modifierFlagsRaw: NSEvent.ModifierFlags.command.rawValue, isModifierOnly: false)
            hotkey.updateShortcut(combo)
            check(hotkey.shortcut == combo, "updateShortcut should replace the stored shortcut", &ok)
            hotkey.handle(flagsChanged(keyCode: DictationHotkey.rightOptionKeyCode, optionHeld: true))
            check(downCount == 1, "the old modifier-only shortcut must stop firing after updateShortcut", &ok)
            hotkey.handleKeyEvent(keyEvent(type: .keyDown, keyCode: 2, modifiers: [.command]))
            check(downCount == 2, "the new regular-key combo should fire via handleKeyEvent", &ok)
        }

        // 10. `start()` with the default modifier-only shortcut must install
        //     BOTH the local and global `.flagsChanged` monitors (not just
        //     the local one) - and must not leave any key-event monitor
        //     installed.
        do {
            let hotkey = DictationHotkey(onDown: {}, onUp: {})
            hotkey.start()
            check(hotkey.localFlagsMonitor != nil, "start() must install a local flagsChanged monitor for a modifier-only shortcut", &ok)
            check(hotkey.globalFlagsMonitor != nil, "start() must install a GLOBAL flagsChanged monitor for a modifier-only shortcut - this is the actual system-wide reach", &ok)
            check(hotkey.localKeyMonitor == nil, "a modifier-only shortcut must not install a local key monitor", &ok)
            check(hotkey.globalKeyMonitor == nil, "a modifier-only shortcut must not install a global key monitor", &ok)
            hotkey.stop()
        }

        // 11. `updateShortcut` to a regular-key combo must tear down the
        //     flagsChanged monitors and install BOTH local and global
        //     key-event monitors.
        do {
            let hotkey = DictationHotkey(onDown: {}, onUp: {})
            hotkey.start()
            let combo = DictationShortcut(keyCode: 2, modifierFlagsRaw: NSEvent.ModifierFlags.command.rawValue | NSEvent.ModifierFlags.shift.rawValue, isModifierOnly: false)
            hotkey.updateShortcut(combo)
            check(hotkey.localFlagsMonitor == nil, "switching to a regular-key combo must tear down the local flagsChanged monitor", &ok)
            check(hotkey.globalFlagsMonitor == nil, "switching to a regular-key combo must tear down the GLOBAL flagsChanged monitor", &ok)
            check(hotkey.localKeyMonitor != nil, "switching to a regular-key combo must install a local key monitor", &ok)
            check(hotkey.globalKeyMonitor != nil, "switching to a regular-key combo must install a GLOBAL key monitor - this is the actual system-wide reach for a recorded combo", &ok)
            hotkey.stop()
        }

        // 12. Switching back to a modifier-only shortcut must reinstall the
        //     flagsChanged monitors and tear down the key monitors - a full
        //     round trip, the exact "switching monitor mechanisms" scenario
        //     this task's own brief suspected could silently drop the global
        //     monitor.
        do {
            let hotkey = DictationHotkey(onDown: {}, onUp: {})
            hotkey.start()
            let combo = DictationShortcut(keyCode: 2, modifierFlagsRaw: NSEvent.ModifierFlags.command.rawValue, isModifierOnly: false)
            hotkey.updateShortcut(combo)
            hotkey.updateShortcut(.defaultShortcut)
            check(hotkey.localFlagsMonitor != nil, "switching back to modifier-only must reinstall the local flagsChanged monitor", &ok)
            check(hotkey.globalFlagsMonitor != nil, "switching back to modifier-only must reinstall the GLOBAL flagsChanged monitor", &ok)
            check(hotkey.localKeyMonitor == nil, "switching back to modifier-only must tear down the local key monitor", &ok)
            check(hotkey.globalKeyMonitor == nil, "switching back to modifier-only must tear down the GLOBAL key monitor", &ok)
            hotkey.stop()
            check(hotkey.localFlagsMonitor == nil && hotkey.globalFlagsMonitor == nil, "stop() must tear down every monitor", &ok)
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
