// Manjesh Grand Line - native macOS app.
//
// Global quick-capture (phase 5, cockpit-shift-power-features): a small
// floating overlay that creates a real Shift task from anywhere, matching the
// captain-reviewed mockup's `.capture-overlay`/`.capture-bar`
// (data/cockpit-shift-ui-polish/reviewed-mockup-reference.html) - an
// accent-bordered input with a hint line, and a brief "Captured" confirmation
// before it dismisses itself. The mockup's own honesty note applies for
// real here too: "a real global shortcut needs a one-time macOS permission
// the first time it's used" - see `ShiftGlobalHotkey` below.
//
// The overlay itself writes through `ShiftStore.addTask` - the same store
// every other Shift entry point (the New Task sheet, the menu bar quick-add)
// uses - so a task captured this way is indistinguishable from one typed
// into the full editor.

import AppKit
import ApplicationServices

final class ShiftQuickCaptureController: NSWindowController, NSTextFieldDelegate {
    private let store: ShiftStore
    private let inputField = NSTextField()
    private let hintLabel = NSTextField(labelWithString: "")
    private let capturedLabel = NSTextField(labelWithString: "\u{2713} Captured \u{2014} landed straight in My Tasks.")
    var onCaptured: (() -> Void)?

    init(store: ShiftStore) {
        self.store = store
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 64),
            styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        super.init(window: panel)
        buildUI(in: panel)
        _ = panel.followHelmTheme()
        ThemeManager.shared.observe { [weak self] theme in self?.applyTheme(theme) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    private func buildUI(in panel: NSPanel) {
        guard let content = panel.contentView else { return }
        content.wantsLayer = true
        content.layer?.cornerRadius = 12
        content.layer?.borderWidth = 1.5

        inputField.placeholderString = "Quick capture \u{2014} try \u{201C}tomorrow 3pm review deploy notes\u{201D}"
        inputField.font = .systemFont(ofSize: 15)
        inputField.isBordered = false
        inputField.focusRingType = .none
        inputField.drawsBackground = false
        inputField.delegate = self
        inputField.translatesAutoresizingMaskIntoConstraints = false

        hintLabel.font = .systemFont(ofSize: 11)
        hintLabel.stringValue = "\u{23CE} to capture \u{00B7} Esc to dismiss"
        hintLabel.translatesAutoresizingMaskIntoConstraints = false

        capturedLabel.font = .systemFont(ofSize: 12, weight: .medium)
        capturedLabel.isHidden = true
        capturedLabel.translatesAutoresizingMaskIntoConstraints = false

        let divider = NSView()
        divider.wantsLayer = true
        divider.translatesAutoresizingMaskIntoConstraints = false

        content.addSubview(inputField)
        content.addSubview(divider)
        content.addSubview(hintLabel)
        content.addSubview(capturedLabel)
        NSLayoutConstraint.activate([
            inputField.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            inputField.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            inputField.topAnchor.constraint(equalTo: content.topAnchor, constant: 14),
            inputField.heightAnchor.constraint(equalToConstant: 24),

            divider.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            divider.topAnchor.constraint(equalTo: inputField.bottomAnchor, constant: 12),
            divider.heightAnchor.constraint(equalToConstant: 1),

            hintLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            hintLabel.topAnchor.constraint(equalTo: divider.bottomAnchor, constant: 8),
            hintLabel.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -10),

            capturedLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            capturedLabel.topAnchor.constraint(equalTo: divider.bottomAnchor, constant: 8),
        ])
        self.dividerRef = divider
    }

    private var dividerRef: NSView?

    func present() {
        guard let window else { return }
        inputField.stringValue = ""
        hintLabel.isHidden = false
        capturedLabel.isHidden = true
        if let screen = NSScreen.main {
            let x = screen.frame.midX - window.frame.width / 2
            let y = screen.frame.maxY - 220
            window.setFrameTopLeftPoint(NSPoint(x: x, y: y))
        } else {
            window.center()
        }
        // A quick-capture invocation can arrive while some other app is
        // frontmost (that's the whole point of a global hotkey) - `orderFront`
        // alone would show the panel behind the still-frontmost app.
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(inputField)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.insertNewline(_:)):
            capture()
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            window?.orderOut(nil)
            return true
        default:
            return false
        }
    }

    private func capture() {
        let text = inputField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        var task = ShiftTask.fresh()
        if let parsed = ShiftDateParser.parse(text) {
            let (dateStr, timeStr) = ShiftDateFormatting.components(from: parsed.date)
            task.dueDate = dateStr
            task.dueTime = parsed.hasTime ? timeStr : nil
        }
        task.title = text
        store.addTask(task)
        onCaptured?()

        hintLabel.isHidden = true
        capturedLabel.isHidden = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in
            self?.window?.orderOut(nil)
        }
    }

    private func applyTheme(_ theme: HelmTheme) {
        let accent = HelmTheme.nsColor(theme.accentHex)
        window?.contentView?.layer?.backgroundColor = HelmTheme.nsColor(theme.chromeBackgroundHex).cgColor
        window?.contentView?.layer?.borderColor = accent.cgColor
        inputField.textColor = HelmTheme.nsColor(theme.chromeInkHex)
        hintLabel.textColor = HelmTheme.mutedInk(theme)
        capturedLabel.textColor = HelmTheme.nsColor(theme.ansiHex[2])
        dividerRef?.layer?.backgroundColor = HelmTheme.nsColor(theme.chromeLineHex).withAlphaComponent(0.6).cgColor
    }
}

/// Registers the system-wide "⌥Space" quick-capture shortcut. Two monitors
/// are needed to cover both cases the brief calls out: a **local** monitor
/// (`NSEvent.addLocalMonitorForEvents`) fires while this app is frontmost but
/// some other window has focus, no permission required; a **global** monitor
/// (`NSEvent.addGlobalMonitorForEvents`) fires while a *different* app is
/// frontmost - the actual "from anywhere" case the brief asks for - but per
/// Apple's own documentation that only delivers keyDown/keyUp/flagsChanged
/// events once the process is a trusted Accessibility client
/// (`AXIsProcessTrusted`), which is exactly the "one-time macOS permission"
/// the reviewed mockup's own capture overlay text already calls out.
/// `requestPermissionIfNeeded()` triggers the real system prompt via
/// `AXIsProcessTrustedWithOptions`; until granted, the global monitor is
/// registered but macOS simply never calls it - no crash, no error, just
/// silence, which is why `isAccessibilityTrusted` exists for callers (and
/// this phase's own verification) to check honestly rather than assuming the
/// hotkey works everywhere just because `start()` didn't throw.
final class ShiftGlobalHotkey {
    private var localMonitor: Any?
    private var globalMonitor: Any?
    private let handler: () -> Void

    /// `kVK_Space` (Carbon's `HIToolbox` keycode, still the standard
    /// reference even without linking Carbon - this app has no Carbon
    /// dependency and doesn't need one just for one literal keycode).
    private static let spaceKeyCode: UInt16 = 49

    init(handler: @escaping () -> Void) {
        self.handler = handler
    }

    var isAccessibilityTrusted: Bool { AXIsProcessTrusted() }

    /// Shows the real system "Accessibility" permission prompt if not already
    /// granted. Safe to call every launch - a no-op (returns `true`
    /// immediately, no dialog) once already granted.
    @discardableResult
    func requestPermissionIfNeeded() -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    func start() {
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if Self.matches(event) {
                self?.handler()
                return nil
            }
            return event
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if Self.matches(event) { self?.handler() }
        }
    }

    func stop() {
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        localMonitor = nil
        globalMonitor = nil
    }

    private static func matches(_ event: NSEvent) -> Bool {
        guard event.keyCode == spaceKeyCode else { return false }
        return event.modifierFlags.intersection(.deviceIndependentFlagsMask) == [.option]
    }
}
