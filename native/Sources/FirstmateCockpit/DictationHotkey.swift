// Manjesh Grand Line - native macOS app.
//
// Dictation's global hold-to-record hotkey (fm/grandline-dictation-mvp,
// phase 1): Right ⌥ Option, matching OpenSuperWhisper's own trigger shape so
// muscle memory carries over (per the captain-approved plan this task
// implements) - held to start capturing, released to stop and transcribe.
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
// installations coexist independently, confirmed live during this task (see
// `CLAUDE.md`'s "Dictation" section).
//
// The one real difference from `ShiftGlobalHotkey`: Right ⌥ Option is a
// modifier key, not a regular key, so pressing/releasing it fires
// `.flagsChanged` events (keyCode present, but no `keyDown`/`keyUp`), not
// `.keyDown`/`.keyUp`. `handle(_:)` distinguishes "key just went down" from
// "key just came up" by tracking whether `.option` was already present in
// `modifierFlags` on the previous flagsChanged event for this keyCode.

import AppKit
import ApplicationServices

final class DictationHotkey {
    /// `kVK_RightOption` (Carbon's `HIToolbox` keycode - same "no Carbon
    /// dependency needed for one literal keycode" reasoning
    /// `ShiftGlobalHotkey.spaceKeyCode` already documents). Left ⌥ Option is
    /// a distinct keycode (58) and is deliberately not matched here - only
    /// the right-hand key triggers dictation, exactly like OpenSuperWhisper's
    /// own shortcut.
    static let rightOptionKeyCode: UInt16 = 61

    private var localMonitor: Any?
    private var globalMonitor: Any?
    private let onDown: () -> Void
    private let onUp: () -> Void
    private var isHeld = false

    init(onDown: @escaping () -> Void, onUp: @escaping () -> Void) {
        self.onDown = onDown
        self.onUp = onUp
    }

    var isAccessibilityTrusted: Bool { AXIsProcessTrusted() }

    /// Safe to call every launch - a no-op (returns `true` immediately, no
    /// dialog) once already granted. Deliberately not called automatically at
    /// launch (unlike `ShiftGlobalHotkey`'s own eager launch-time request) -
    /// the task brief asks for each Dictation permission to be requested "the
    /// first time it's genuinely needed," so this is only invoked from
    /// `DictationController`'s status action / the first real hold of Right
    /// ⌥ Option, not unconditionally at app launch.
    @discardableResult
    func requestPermissionIfNeeded() -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    func start() {
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handle(event)
            return event
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handle(event)
        }
    }

    func stop() {
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        localMonitor = nil
        globalMonitor = nil
        isHeld = false
    }

    /// Internal (not `private`) so `DictationHotkeySelfTest` can drive it
    /// directly with synthetic `.flagsChanged` events, the same "widen
    /// visibility for a permanent self-test" convention this codebase already
    /// uses elsewhere (e.g. `BootstrapController.stepIsDone`).
    func handle(_ event: NSEvent) {
        guard event.keyCode == Self.rightOptionKeyCode else { return }
        let isPressed = event.modifierFlags.contains(.option)
        if isPressed && !isHeld {
            isHeld = true
            onDown()
        } else if !isPressed && isHeld {
            isHeld = false
            onUp()
        }
    }
}
