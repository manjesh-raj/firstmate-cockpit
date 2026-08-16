// Manjesh Grand Line - native macOS app.
//
// Dictation's shortcut recorder (phase 2, fm/grandline-dictation-phase2): a
// small, self-built `NSView` control - click it, press the desired key/
// modifier combo, it's captured and reported via `onChange`. Built directly
// rather than adding any external dependency, per the task brief - this app
// deliberately has zero remote SPM dependencies (`CLAUDE.md`'s vendoring
// conventions for `SwiftTerm`/`YamlSwift`), and a hotkey recorder is small
// enough to build directly.
//
// Telling a **modifier-only** combo (e.g. Right ⌥ Option alone) apart from a
// **regular-key + modifiers** combo (e.g. ⌘⇧D) while recording:
//   - `flagsChanged(with:)` fires for a bare modifier press/release. The
//     *first* modifier-down transition seen while recording is captured
//     (`pendingModifierKeyCode`/`pendingModifierFlags`) - a second modifier
//     added afterward is deliberately ignored (the first-pressed key wins;
//     see the header note below on why multi-modifier-only combos aren't
//     supported). If everything releases with no regular key pressed in
//     between, that's finalized as a modifier-only shortcut.
//   - `keyDown(with:)` fires for a regular key, carrying whatever modifiers
//     are held at that instant (`event.modifierFlags`) - finalized
//     immediately as a regular-key combo, overriding any pending
//     modifier-only state (a modifier held right before a regular key was
//     always "part of a combo," not a shortcut on its own).
//
// Deliberately out of scope: a modifier-only combo made of *two or more*
// modifier keys with no regular key (e.g. "hold ⌘ then ⇧, release both").
// `DictationShortcut.isModifierOnly` combos are single-key by construction -
// matching OpenSuperWhisper's own convention (Right ⌥ Option, one physical
// key) and every "hold to record" affordance a captain would realistically
// want. Recording two modifiers with no regular key still produces a usable
// result (the *first* modifier pressed wins, and any later modifier addition
// is silently dropped) rather than a broken one.

import AppKit

final class DictationShortcutRecorderView: NSView {
    private let label = NSTextField(labelWithString: "")
    private var isRecording = false
    private var pendingModifierKeyCode: UInt16?
    private var pendingModifierFlags: NSEvent.ModifierFlags = []
    private var currentTheme: HelmTheme?

    var shortcut: DictationShortcut {
        didSet { updateLabel() }
    }
    /// Fired once a new combo is captured - never fired for a cancelled
    /// recording (Escape, or clicking away).
    var onChange: ((DictationShortcut) -> Void)?

    init(shortcut: DictationShortcut) {
        self.shortcut = shortcut
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 7
        translatesAutoresizingMaskIntoConstraints = false

        label.font = .monospacedSystemFont(ofSize: 12.5, weight: .medium)
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            widthAnchor.constraint(greaterThanOrEqualToConstant: 130),
            heightAnchor.constraint(equalToConstant: 28),
        ])
        updateLabel()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        beginRecording()
    }

    private func beginRecording() {
        isRecording = true
        pendingModifierKeyCode = nil
        pendingModifierFlags = []
        updateLabel()
        refreshThemeAppearance()
    }

    private func cancelRecording() {
        isRecording = false
        pendingModifierKeyCode = nil
        updateLabel()
        refreshThemeAppearance()
    }

    override func keyDown(with event: NSEvent) {
        guard isRecording else {
            super.keyDown(with: event)
            return
        }
        if event.keyCode == 53 { // Escape cancels without changing anything.
            cancelRecording()
            return
        }
        let mods = event.modifierFlags.intersection(DictationShortcut.relevantModifierMask)
        finalize(DictationShortcut(keyCode: event.keyCode, modifierFlagsRaw: mods.rawValue, isModifierOnly: false))
    }

    override func flagsChanged(with event: NSEvent) {
        guard isRecording else {
            super.flagsChanged(with: event)
            return
        }
        let mods = event.modifierFlags.intersection(DictationShortcut.relevantModifierMask)
        if !mods.isEmpty, pendingModifierKeyCode == nil {
            pendingModifierKeyCode = event.keyCode
            pendingModifierFlags = mods
        } else if mods.isEmpty, let keyCode = pendingModifierKeyCode {
            finalize(DictationShortcut(keyCode: keyCode, modifierFlagsRaw: pendingModifierFlags.rawValue, isModifierOnly: true))
        }
    }

    private func finalize(_ newShortcut: DictationShortcut) {
        isRecording = false
        pendingModifierKeyCode = nil
        shortcut = newShortcut
        onChange?(newShortcut)
        refreshThemeAppearance()
    }

    private func updateLabel() {
        label.stringValue = isRecording ? "Press a key or combo… (Esc to cancel)" : shortcut.displayString
    }

    func applyTheme(_ theme: HelmTheme) {
        currentTheme = theme
        refreshThemeAppearance()
    }

    private func refreshThemeAppearance() {
        guard let theme = currentTheme else { return }
        layer?.backgroundColor = HelmTheme.nsColor(theme.chromeBackgroundHex).cgColor
        layer?.borderWidth = 1
        layer?.borderColor = HelmTheme.nsColor(isRecording ? theme.accentHex : theme.chromeLineHex).cgColor
        label.textColor = isRecording ? HelmTheme.nsColor(theme.accentHex) : HelmTheme.nsColor(theme.chromeInkHex)
    }
}
