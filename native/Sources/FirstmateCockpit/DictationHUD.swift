// Manjesh Grand Line - native macOS app.
//
// fm/grandline-dictation-visual-feedback-hud: a captain-reported real
// usability gap - Dictation gave NO visual feedback anywhere except its own
// rail page (`DictationController.swift`'s Status card). Since the whole
// point of Dictation is dictating into whatever app currently has focus
// (never Grand Line's own window), there was no way to tell whether holding
// the shortcut actually started listening, was still transcribing, or
// failed, short of specifically navigating to the Dictation page first -
// which defeats the point. This file adds a small floating HUD, matching the
// reference UX of OpenSuperWhisper/Apple's own built-in dictation (a
// transient on-screen indicator), without copying either verbatim.
//
// Reuses the exact status-broadcast plumbing that already exists rather than
// inventing a second one: `DictationEngine.onStatusChanged` (wired in
// `main.swift`) already fires on every real transition the engine drives
// (recording, transcribing, cleaningUp, didNotCatchThat, and the final
// `DictationPermissions.currentStatus()` recompute after a successful
// paste/permission check) - `main.swift` now fans that single callback out
// to both `AppShellController.setDictationEngineStatus` (the existing
// Dictation-page status card) and `DictationHUDController.handle(_:)` (this
// file), rather than the HUD reading a second, parallel status source.
//
// `wasActive` is the one piece of state this controller needs beyond
// `DictationStatus` itself: the *same* underlying status value
// (`.ready`/`.needsMicrophone`/etc.) is reported both when a dictation
// completes successfully (`DictationEngine.deliver` re-reads
// `DictationPermissions.currentStatus()` after pasting) and whenever the
// Dictation page's own manual permission-request buttons succeed/fail - the
// engine has no distinct "success" status of its own (see
// `DictationStatus.swift`'s doc comment: there are exactly the four states
// the task brief describes, plus `.recording`). Gating on "did this
// controller actually see a real `.recording` state first, with no
// completion in between" is what tells the two apart without adding a fifth
// engine-level status: a permission-button click on the Dictation page never
// reports `.recording`/`.transcribing` first, so `wasActive` stays `false`
// and the HUD correctly never appears for it.
//
// Window shape: a plain, borderless `NSPanel` with `.nonactivatingPanel` in
// its style mask, `level = .floating`, and `ignoresMouseEvents = true` - the
// task brief's own suggested shape for "must not steal keyboard focus from
// whatever app the captain is actually typing into." A `.nonactivatingPanel`
// can be ordered front via `orderFrontRegardless()` without the owning app
// (Grand Line) ever becoming active and without the panel ever becoming the
// key window, so the app being dictated into keeps its own key
// window/first-responder status throughout - verified live, see this file's
// PR description for how.
//
// Position is a fixed, unobtrusive location (bottom-center of the screen
// currently under the mouse, falling back to `NSScreen.main`) - cursor-
// position tracking (Apple's own dictation HUD tracks the actual text caret
// via Accessibility) is explicitly out of scope for this pass, per the task
// brief.
//
// Deliberately NOT theme-aware (unlike almost everything else in this app -
// see `ThemeManager.swift`'s own checklist): this HUD floats over arbitrary
// other apps' windows, not over Grand Line's own chrome, so a fixed
// dark/translucent "system HUD" look (matching Control Center's own on-
// screen indicators) reads correctly against any background regardless of
// which Helm theme Grand Line itself is currently using - there is no
// "background" of this app's own for it to blend with.
import AppKit

enum DictationHUDVisualState: Equatable {
    case listening
    case transcribing
    case cleaningUp
    case success
    case failure(String)

    var symbol: String {
        switch self {
        case .listening: return "waveform"
        case .transcribing: return "ellipsis.circle.fill"
        case .cleaningUp: return "sparkles"
        case .success: return "checkmark.circle.fill"
        case .failure: return "questionmark.circle.fill"
        }
    }

    var text: String {
        switch self {
        case .listening: return "Listening…"
        case .transcribing: return "Transcribing…"
        case .cleaningUp: return "Cleaning up…"
        case .success: return "Pasted"
        case .failure(let message): return message
        }
    }

    var tintHex: String {
        switch self {
        case .listening, .transcribing, .cleaningUp: return "#5AC8FA"
        case .success: return "#34C759"
        case .failure: return "#FF9F0A"
        }
    }

    /// `nil` means "stays on screen until the next state change" (listening/
    /// transcribing/cleaningUp are all in-progress states with no fixed
    /// duration - they end when the engine reports the next real
    /// transition, not on a timer).
    var autoHideDelay: TimeInterval? {
        switch self {
        case .listening, .transcribing, .cleaningUp: return nil
        case .success: return 1.1
        case .failure: return 1.8
        }
    }
}

final class DictationHUDController {
    private var panel: NSPanel?
    private var iconView: NSImageView!
    private var titleLabel: NSTextField!
    private var pill: NSView!

    private var hideWorkItem: DispatchWorkItem?

    /// Set the moment a real `.recording` status is seen, cleared the moment
    /// a terminal status (success or `.didNotCatchThat`) is handled - see
    /// this file's header for why this is what distinguishes "a dictation
    /// just finished" from "a permission button was just clicked."
    private var wasActive = false

    /// The one entry point - fed every `DictationStatus` the engine reports,
    /// exactly like `AppShellController.setDictationEngineStatus` already is.
    func handle(_ status: DictationStatus) {
        switch status {
        case .recording:
            wasActive = true
            present(.listening)
        case .transcribing:
            guard wasActive else { return }
            present(.transcribing)
        case .cleaningUp:
            guard wasActive else { return }
            present(.cleaningUp)
        case .didNotCatchThat:
            guard wasActive else { return }
            wasActive = false
            present(.failure("Didn't catch that"))
        case .ready, .needsMicrophone, .needsSpeechRecognition, .needsAccessibility:
            guard wasActive else { return }
            wasActive = false
            present(.success)
        }
    }

    private func present(_ state: DictationHUDVisualState) {
        hideWorkItem?.cancel()
        hideWorkItem = nil

        let panel = ensurePanel()
        iconView.image = NSImage(systemSymbolName: state.symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 15, weight: .semibold))
        iconView.contentTintColor = HelmTheme.nsColor(state.tintHex)
        titleLabel.stringValue = state.text
        stopPulsing()
        if state == .listening {
            startPulsing()
        }

        positionPanel(panel)
        panel.alphaValue = panel.isVisible ? panel.alphaValue : 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.12
            panel.animator().alphaValue = 1
        }

        if let delay = state.autoHideDelay {
            let workItem = DispatchWorkItem { [weak self] in self?.dismiss() }
            hideWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
        }
    }

    private func dismiss() {
        hideWorkItem?.cancel()
        hideWorkItem = nil
        guard let panel, panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.2
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak panel] in
            panel?.orderOut(nil)
        })
    }

    // MARK: Window construction

    private func ensurePanel() -> NSPanel {
        if let panel { return panel }

        let width: CGFloat = 220
        let height: CGFloat = 44
        let newPanel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        newPanel.isOpaque = false
        newPanel.backgroundColor = .clear
        newPanel.hasShadow = true
        newPanel.level = .floating
        newPanel.ignoresMouseEvents = true
        newPanel.hidesOnDeactivate = false
        newPanel.isReleasedWhenClosed = false
        newPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        newPanel.alphaValue = 0

        let content = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        content.wantsLayer = true

        let pillView = NSView()
        pillView.wantsLayer = true
        pillView.layer?.cornerRadius = height / 2
        pillView.layer?.backgroundColor = NSColor(calibratedWhite: 0.08, alpha: 0.92).cgColor
        pillView.layer?.borderWidth = 1
        pillView.layer?.borderColor = NSColor(calibratedWhite: 1, alpha: 0.12).cgColor
        pillView.translatesAutoresizingMaskIntoConstraints = false
        self.pill = pillView

        let icon = NSImageView()
        icon.wantsLayer = true
        icon.symbolConfiguration = .init(pointSize: 15, weight: .semibold)
        icon.contentTintColor = .white
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.setContentHuggingPriority(.required, for: .horizontal)
        self.iconView = icon

        let label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: 12.5, weight: .semibold)
        label.textColor = .white
        label.translatesAutoresizingMaskIntoConstraints = false
        self.titleLabel = label

        let stack = NSStackView(views: [icon, label])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false

        pillView.addSubview(stack)
        content.addSubview(pillView)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: pillView.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: pillView.trailingAnchor, constant: -16),
            stack.centerYAnchor.constraint(equalTo: pillView.centerYAnchor),
            pillView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            pillView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            pillView.topAnchor.constraint(equalTo: content.topAnchor),
            pillView.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])

        newPanel.contentView = content
        self.panel = newPanel
        return newPanel
    }

    /// Bottom-center of whichever screen currently has the mouse cursor
    /// (falling back to `NSScreen.main`) - a captain dictating on a
    /// secondary display should see the HUD there, not only on the main one.
    /// Fixed position, not cursor-tracked (out of scope for this pass, see
    /// this file's header).
    private func positionPanel(_ panel: NSPanel) {
        let mouseLocation = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouseLocation) } ?? NSScreen.main
        guard let screen else { return }
        let frame = screen.visibleFrame
        let size = panel.frame.size
        let x = frame.midX - size.width / 2
        let y = frame.minY + 56
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    // MARK: Pulsing (listening state only)

    private static let pulseAnimationKey = "dictationHUD.pulse"

    private func startPulsing() {
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = 1.0
        animation.toValue = 0.35
        animation.duration = 0.55
        animation.autoreverses = true
        animation.repeatCount = .infinity
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        iconView.layer?.add(animation, forKey: Self.pulseAnimationKey)
    }

    private func stopPulsing() {
        iconView.layer?.removeAnimation(forKey: Self.pulseAnimationKey)
        iconView.layer?.opacity = 1
    }
}
