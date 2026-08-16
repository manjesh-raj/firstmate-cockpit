// Manjesh Grand Line - native macOS app.
//
// Dictation's global hold-to-record hotkey. Phase 1 (fm/grandline-dictation-
// mvp) shipped a fixed Right ⌥ Option combo, matching OpenSuperWhisper's own
// trigger shape so muscle memory carries over. Phase 2
// (fm/grandline-dictation-phase2) makes it configurable via a real recorder
// control on the Dictation page (`DictationShortcutRecorderView.swift`),
// persisted in `AppSettings.dictationShortcut` - so `DictationHotkey` now has
// to support two fundamentally different event shapes, not just Right Option:
//
//   - A **modifier-only** combo (Right ⌥ Option, Right ⌘, Left ⇧, ...): a
//     modifier key alone fires `.flagsChanged` events (keyCode present, but no
//     `keyDown`/`keyUp`) - held down is "flag present", released is "flag
//     absent". This is the whole mechanism phase 1 shipped.
//   - A **regular key + modifiers** combo (e.g. ⌘⇧D): fires ordinary
//     `.keyDown`/`.keyUp` events, with `event.modifierFlags` carrying whatever
//     modifiers were held at the time. Held-down is `isHeld == false` seeing a
//     `.keyDown` (repeats are naturally absorbed by the `isHeld` guard, since
//     macOS resends `.keyDown` on auto-repeat); released is the matching
//     `.keyUp`.
//
// `DictationShortcut.isModifierOnly` decides which shape a given combo is,
// decided once at record time by `DictationShortcutRecorderView` (see that
// file's header for exactly how it tells the two apart while capturing).
// `start()` installs only the monitor pair the current shortcut actually
// needs; `updateShortcut(_:)` tears down and reinstalls when the captain
// changes it - so switching from a modifier-only combo to a regular-key combo
// (or back) always ends up on the correct monitor type, not a stale one.
//
// Reuses the exact global-hotkey mechanism `ShiftGlobalHotkey`
// (`ShiftQuickCapture.swift`) already established in this codebase - a
// **local** `NSEvent` monitor (fires while this app is frontmost but some
// other window has focus, no permission needed) plus a **global** monitor
// (fires while a *different* app is frontmost - the actual "from anywhere"
// case) that, per Apple's own documentation, only delivers events once this
// process is a trusted Accessibility client (`AXIsProcessTrusted`) - see
// `ShiftGlobalHotkey`'s own header for the full reasoning. This is
// deliberately NOT a second global-hotkey mechanism: both features share one
// Accessibility trust grant (there is only one "Grand Line" entry in System
// Settings > Privacy & Security > Accessibility) and both monitor
// installations coexist independently, confirmed live during phase 1 (see
// `CLAUDE.md`'s "Dictation" section).

import AppKit
import ApplicationServices

/// A recorded shortcut - either a single held modifier key, or a regular key
/// plus zero or more modifiers. `Codable` so it round-trips through
/// `AppSettings.dictationShortcut` as JSON `Data`.
///
/// Only the four standard modifiers (⌘⌥⌃⇧) are ever tracked, deliberately
/// excluding Caps Lock/Fn from `relevantModifierMask` - Caps Lock's flag
/// reflects a toggle *state*, not a momentary press, so a captain who happens
/// to have Caps Lock on would silently break matching if it were included
/// (recorded without it, matched against an event that now always carries
/// it, or vice versa). Fn was excluded for the same "ambient/sticky, not a
/// deliberate press" reasoning.
struct DictationShortcut: Codable, Equatable {
    var keyCode: UInt16
    var modifierFlagsRaw: UInt
    var isModifierOnly: Bool

    static let relevantModifierMask: NSEvent.ModifierFlags = [.command, .option, .control, .shift]

    var modifiers: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: modifierFlagsRaw) }

    static let defaultShortcut = DictationShortcut(
        keyCode: DictationHotkey.rightOptionKeyCode,
        modifierFlagsRaw: NSEvent.ModifierFlags.option.rawValue,
        isModifierOnly: true
    )

    /// `kVK_RightOption`/`kVK_RightCommand`/... - Carbon's `HIToolbox`
    /// virtual keycodes for the standard modifier keys, both sides where
    /// macOS distinguishes them. No Carbon dependency needed for these
    /// literal values, same reasoning `ShiftGlobalHotkey.spaceKeyCode`'s
    /// header already documents.
    private static let modifierKeyNames: [UInt16: String] = [
        54: "Right ⌘", 55: "Left ⌘",
        56: "Left ⇧", 60: "Right ⇧",
        58: "Left ⌥", 61: "Right ⌥",
        59: "Left ⌃", 62: "Right ⌃",
    ]

    /// A modest table of common regular keys for display purposes - this
    /// isn't meant to be exhaustive (an unmapped key still displays, just as
    /// "Key N"), only to cover the combos a captain is actually likely to
    /// record (a letter, digit, or one of a few common keys alongside ⌘/⌥/⌃/⇧).
    private static let regularKeyNames: [UInt16: String] = [
        0: "A", 11: "B", 8: "C", 2: "D", 14: "E", 3: "F", 5: "G", 4: "H", 34: "I",
        38: "J", 40: "K", 37: "L", 46: "M", 45: "N", 31: "O", 35: "P", 12: "Q",
        15: "R", 1: "S", 17: "T", 32: "U", 9: "V", 13: "W", 7: "X", 16: "Y", 6: "Z",
        29: "0", 18: "1", 19: "2", 20: "3", 21: "4", 23: "5", 22: "6", 26: "7",
        28: "8", 25: "9",
        49: "Space", 36: "Return", 48: "Tab", 51: "Delete", 53: "Escape",
    ]

    static func isModifierKeyCode(_ keyCode: UInt16) -> Bool {
        modifierKeyNames[keyCode] != nil
    }

    var displayString: String {
        if isModifierOnly {
            return Self.modifierKeyNames[keyCode] ?? "Key \(keyCode)"
        }
        var s = ""
        let m = modifiers
        if m.contains(.control) { s += "⌃" }
        if m.contains(.option) { s += "⌥" }
        if m.contains(.shift) { s += "⇧" }
        if m.contains(.command) { s += "⌘" }
        s += Self.regularKeyNames[keyCode] ?? "Key \(keyCode)"
        return s
    }
}

final class DictationHotkey {
    /// `kVK_RightOption` - Left ⌥ Option is a distinct keycode (58) and is
    /// deliberately not matched by the phase-1 default - only the right-hand
    /// key triggers dictation out of the box, exactly like OpenSuperWhisper's
    /// own shortcut. A captain can still record Left ⌥ Option (or any other
    /// combo) explicitly via the shortcut recorder.
    static let rightOptionKeyCode: UInt16 = 61

    // Internal (not `private`), so `DictationHotkeySelfTest` can inspect
    // which monitor tokens are actually installed after `start()`/
    // `updateShortcut(_:)` - a structural check that a real monitor object
    // exists for the mechanism the current shortcut needs, and that the
    // *other* mechanism's monitors are torn down. This is what closes the
    // real coverage gap this class's tests had before: every prior version
    // of this self-test only drove `handle(_:)`/`handleKeyEvent(_:)`
    // directly, which proves the hold/release *decision logic* is correct
    // but never proves `start()` actually registered a live
    // `NSEvent.addGlobalMonitorForEvents` monitor at all - a future edit
    // that silently dropped the global registration (installed only the
    // local monitor, say) would have kept passing every test that existed
    // before. See `DictationHotkeySelfTest.swift`'s own header for the full
    // reasoning and for what live, real-hardware verification (HID-level
    // synthetic `CGEventPost`, run manually during this task, not part of
    // this permanent self-test) additionally confirmed.
    var localFlagsMonitor: Any?
    var globalFlagsMonitor: Any?
    var localKeyMonitor: Any?
    var globalKeyMonitor: Any?
    private let onDown: () -> Void
    private let onUp: () -> Void
    private var isHeld = false
    private(set) var shortcut: DictationShortcut

    init(shortcut: DictationShortcut = .defaultShortcut, onDown: @escaping () -> Void, onUp: @escaping () -> Void) {
        self.shortcut = shortcut
        self.onDown = onDown
        self.onUp = onUp
    }

    var isAccessibilityTrusted: Bool { AXIsProcessTrusted() }

    /// Safe to call every launch - a no-op (returns `true` immediately, no
    /// dialog) once already granted. Deliberately not called automatically at
    /// launch (unlike `ShiftGlobalHotkey`'s own eager launch-time request) -
    /// the task brief asks for each Dictation permission to be requested "the
    /// first time it's genuinely needed," so this is only invoked from
    /// `DictationController`'s status action / the first real hold of the
    /// configured shortcut, not unconditionally at app launch.
    @discardableResult
    func requestPermissionIfNeeded() -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    func start() {
        stopMonitors()
        isHeld = false
        if shortcut.isModifierOnly {
            localFlagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
                self?.handle(event)
                return event
            }
            globalFlagsMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
                self?.handle(event)
            }
        } else {
            localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
                self?.handleKeyEvent(event)
                return event
            }
            globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
                self?.handleKeyEvent(event)
            }
        }
    }

    func stop() {
        stopMonitors()
        isHeld = false
    }

    private func stopMonitors() {
        if let localFlagsMonitor { NSEvent.removeMonitor(localFlagsMonitor) }
        if let globalFlagsMonitor { NSEvent.removeMonitor(globalFlagsMonitor) }
        if let localKeyMonitor { NSEvent.removeMonitor(localKeyMonitor) }
        if let globalKeyMonitor { NSEvent.removeMonitor(globalKeyMonitor) }
        localFlagsMonitor = nil
        globalFlagsMonitor = nil
        localKeyMonitor = nil
        globalKeyMonitor = nil
    }

    /// Swaps in a newly recorded shortcut and restarts monitoring under
    /// whichever mechanism (`.flagsChanged` vs `.keyDown`/`.keyUp`) that combo
    /// needs - a plain property set with no restart would leave the *old*
    /// monitor type installed, silently deaf to the new combo's real event
    /// shape whenever the two differ (e.g. switching from Right ⌥ Option to
    /// ⌘⇧D).
    func updateShortcut(_ newShortcut: DictationShortcut) {
        shortcut = newShortcut
        start()
    }

    /// Internal (not `private`) so `DictationHotkeySelfTest` can drive it
    /// directly with synthetic `.flagsChanged` events - handles a
    /// modifier-only shortcut. `.contains` (not exact equality) matches phase
    /// 1's original behavior: holding an *additional* unrelated modifier
    /// alongside the recorded one doesn't break the match, only the
    /// recorded modifier's own presence/absence matters.
    func handle(_ event: NSEvent) {
        guard shortcut.isModifierOnly, event.keyCode == shortcut.keyCode else { return }
        let current = event.modifierFlags.intersection(DictationShortcut.relevantModifierMask)
        let isPressed = !shortcut.modifiers.isEmpty && current.contains(shortcut.modifiers)
        if isPressed && !isHeld {
            isHeld = true
            onDown()
        } else if !isPressed && isHeld {
            isHeld = false
            onUp()
        }
    }

    /// Internal (not `private`) so `DictationHotkeySelfTest` can drive it
    /// directly with synthetic `.keyDown`/`.keyUp` events - handles a
    /// regular-key + modifiers combo. Exact equality (not `.contains`) here,
    /// unlike `handle(_:)` above: a regular-key combo is a more deliberate,
    /// precise gesture (e.g. ⌘⇧D specifically, not ⌘⇧⌃D too), and the
    /// recorder captures the exact modifier set at the moment the key was
    /// pressed, so an exact match is what a captain would expect back.
    func handleKeyEvent(_ event: NSEvent) {
        guard !shortcut.isModifierOnly, event.keyCode == shortcut.keyCode else { return }
        let current = event.modifierFlags.intersection(DictationShortcut.relevantModifierMask)
        guard current == shortcut.modifiers else { return }
        if event.type == .keyDown, !isHeld {
            isHeld = true
            onDown()
        } else if event.type == .keyUp, isHeld {
            isHeld = false
            onUp()
        }
    }
}
