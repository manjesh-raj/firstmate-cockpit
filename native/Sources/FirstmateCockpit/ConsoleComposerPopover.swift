// Manjesh Grand Line - native macOS app.
//
// Phase 3 of "Knowledge and speed" (`fm/grandline-console-command-composer`):
// the "✨ Compose" popover a plain `.shell` tab's toolbar opens. Mirrors
// `ShiftMenuBarController`'s popover shape (`ShiftMenuBar.swift`) - a small
// `NSPopover` + a plain `NSViewController` content - but (unlike
// `ShiftMenuBarController`'s popover, which only ever shows plain
// system-label-colored text) this content has its own `HelmTheme`-derived
// colors, so it needs the real live-theme treatment described below rather
// than AppKit's own default vibrant background.
//
// `fm/grandline-composer-cleanup-and-polish` gave the content view its own
// visual treatment, since the original build was a bare label/field/button
// with no styling matching the rest of this app: a tinted `IconTileView`
// (`HelmUIComponents.swift`, `.violet` - the same "AI feature" treatment
// Dictation's "Clean up my sentences" card already established, see
// `DictationController.buildCleanupSection`) next to the title, a real
// monospace code-block presentation for the generated command (mirroring
// the Tools page's own `ToolInstance.codeEditor` - a bordered, corner-radius
// `NSScrollView`/`NSTextView` in the active `HelmTheme`'s colors, not a
// plain `NSTextField`), Copy/Run buttons following this app's established
// `bezelStyle = .rounded, controlSize = .small` pill-button convention (the
// same one Vault's "Run injected…"/"Copy Name" row buttons use), and a
// `⌘⏎` shortcut hint next to the intent field.
//
// `fm/grandline-composer-theme-and-width` fixed two real captain-reported
// bugs in that polish pass: (1) the popover rendered as plain, unthemed dark
// gray regardless of the app's actual active Helm theme - the "read once at
// construction, no live observer" comment above was simply wrong for a
// popover that can stay open across a theme change, and worse, this view had
// no explicit background fill at all, so it fell back to `NSPopover`'s own
// system vibrancy (following the OS's light/dark setting, not this app's
// in-app theme) - the same root cause `ThemeManager.swift`'s own checklist
// warns about and the same class of bug `grandline-unified-search-fixes`
// fixed concurrently for the `⌘K` palette. Fixed the same way every other
// themed window in this app is: a live `ThemeManager.shared.observe`
// registration (owned by `ConsoleComposerController`, which is itself an
// app-lifetime property of `ConsoleController` - unobserved from
// `ConsoleController.shutdown()`, mirroring that controller's own theme
// token), a plain `wantsLayer`-backed root view with an explicit
// `HelmTheme`-derived `backgroundColor` fill (never `NSVisualEffectView`,
// per this file's AppKit gotcha #8), and `popover.appearance` forced to the
// theme's own light/dark mode so any leftover system-semantic color resolves
// against the in-app theme, not the OS's. (2) The popover was a fixed 380pt
// wide regardless of the generated command's length, because `root`'s width
// was never tied to a constraint at all - only its initial `loadView` frame
// size, which nothing ever changed. `rootWidthConstraint` now grows to fit
// the longest line of the generated command (measured against the code
// block's own font), capped at `maxWidth` so it can never run off-screen,
// floored at `minWidth` so a short command (or the empty/intent-only state)
// doesn't leave an oversized empty box - `updateWidth`'s resulting fitting
// size is handed to the popover explicitly (`onSizeChanged`), the same
// "compute and set the frame explicitly" style `ShiftSearchController.
// resizeToFit()` already uses, rather than relying on `NSPopover`'s
// occasionally-inconsistent automatic Auto-Layout-driven resize.
//
// Nothing here ever runs a generated command automatically - see
// `ConsoleCommandComposer.swift`'s header and this task's PR description for
// the full design-constraint reasoning (SRE Lead's own approval-gated
// posture, the captain's explicit "look before you run" expectation). The
// generated command is only ever shown for review; `onRunInTerminal` is the
// one explicit action that sends anything to a real terminal, wired by
// `ConsoleController` to `currentTab?.terminal.send(txt:)` - the same call a
// Snippet's own "Run" action already uses.

import AppKit

final class ConsoleComposerController: NSObject, NSPopoverDelegate {
    private let popover = NSPopover()
    private let content = ConsoleComposerViewController()
    private var themeObservation: ThemeObservation?

    /// Set by `ConsoleController` to `currentTab?.terminal.send(txt:)`.
    var onRunInTerminal: ((String) -> Void)?

    override init() {
        super.init()
        popover.contentViewController = content
        popover.behavior = .transient
        popover.delegate = self
        content.onRunInTerminal = { [weak self] command in
            self?.onRunInTerminal?(command)
            self?.popover.performClose(nil)
        }
        content.onSizeChanged = { [weak self] size in
            self?.popover.contentSize = size
        }
        themeObservation = ThemeManager.shared.observe { [weak self] theme in
            guard let self else { return }
            self.popover.appearance = NSAppearance(named: theme.mode == .dark ? .darkAqua : .aqua)
            self.content.applyTheme(theme)
        }
    }

    var isShown: Bool { popover.isShown }

    func toggle(relativeTo view: NSView) {
        if popover.isShown {
            popover.performClose(nil)
        } else {
            content.reset()
            popover.show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
            content.focusIntentField()
        }
    }

    func close() {
        guard popover.isShown else { return }
        popover.performClose(nil)
    }

    /// Called from `ConsoleController.shutdown()`, mirroring that
    /// controller's own `themeObservation` teardown - `ConsoleComposerController`
    /// is a per-console (not strictly app-lifetime) property, and a host
    /// page's `ConsoleController` can be deallocated mid-session (see
    /// "Dedicated host pages" in AGENTS.md), so this observer needs the same
    /// explicit unregistration or it leaks a dead closure into
    /// `ThemeManager.observers`.
    func shutdown() {
        if let themeObservation {
            ThemeManager.shared.unobserve(themeObservation)
            self.themeObservation = nil
        }
    }
}

/// The popover's content: a tinted-icon header, an intent field + Generate
/// (with a `⌘⏎` shortcut hint), a status/error line, and (once generated) the
/// command in a real code-block view with Copy/Run actions. No history is
/// kept - this is a one-shot generate-review-run per tab open, per the
/// task's explicit scope; closing and reopening the popover always starts
/// fresh (`reset()`).
private final class ConsoleComposerViewController: NSViewController {
    private var theme = ThemeManager.shared.theme

    /// Popover width grows to fit a long generated command, floored/capped
    /// so a short command doesn't leave an oversized empty box and a long
    /// one can never grow off whatever screen it's on.
    static let minWidth: CGFloat = 380
    static let maxWidth: CGFloat = 640
    private var rootWidthConstraint: NSLayoutConstraint!

    private let iconTile = IconTileView(size: 30, cornerRadius: 8)
    private let titleLabel = NSTextField(labelWithString: "Compose a command")
    private let intentField = NSTextField()
    private let generateButton = NSButton(title: "Generate", target: nil, action: nil)
    private let shortcutHintLabel = NSTextField(labelWithString: "\u{2318}\u{23ce} to generate")
    private let statusLabel = NSTextField(labelWithString: "")

    private let codeScroll = NSScrollView()
    private let codeTextView = NSTextView()
    private let copyButton = NSButton(title: "Copy", target: nil, action: nil)
    private let runButton = NSButton(title: "Run in Terminal", target: nil, action: nil)
    private let commandStack = NSStackView()

    var onRunInTerminal: ((String) -> Void)?
    /// Fires whenever the content's own fitting size may have changed (a
    /// width recompute, or a height change from a status/command-block
    /// toggle) - `ConsoleComposerController` forwards this straight to
    /// `popover.contentSize`, the same explicit "compute then set" style
    /// `ShiftSearchController.resizeToFit()` already uses.
    var onSizeChanged: ((NSSize) -> Void)?
    private var generatedCommand: String?
    private var statusIsError = false

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: Self.minWidth, height: 170))
        root.wantsLayer = true
        view = root

        iconTile.configure(symbol: "sparkles", tint: .violet)

        titleLabel.font = .systemFont(ofSize: 13.5, weight: .semibold)
        titleLabel.textColor = HelmTheme.nsColor(theme.chromeInkHex)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        let titleRow = NSStackView(views: [iconTile, titleLabel])
        titleRow.orientation = .horizontal
        titleRow.alignment = .centerY
        titleRow.spacing = 10
        titleRow.translatesAutoresizingMaskIntoConstraints = false

        intentField.placeholderString = "Describe what you want to run…"
        intentField.font = .systemFont(ofSize: 12)
        intentField.target = self
        intentField.action = #selector(generateClicked)

        generateButton.target = self
        generateButton.action = #selector(generateClicked)
        generateButton.bezelStyle = .rounded
        generateButton.controlSize = .small
        // The intent field already submits on a plain Return via its own
        // target/action above (the natural behavior for a single-line
        // field) - this gives the same action a second, always-available
        // trigger regardless of first responder, matching the hint text
        // below.
        generateButton.keyEquivalent = "\r"
        generateButton.keyEquivalentModifierMask = [.command]

        let generateRow = NSStackView(views: [intentField, generateButton])
        generateRow.orientation = .horizontal
        generateRow.spacing = 6
        generateRow.translatesAutoresizingMaskIntoConstraints = false

        shortcutHintLabel.font = .systemFont(ofSize: 10)
        shortcutHintLabel.textColor = HelmTheme.mutedInk(theme)
        shortcutHintLabel.alignment = .right
        shortcutHintLabel.translatesAutoresizingMaskIntoConstraints = false

        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = HelmTheme.mutedInk(theme)
        statusLabel.lineBreakMode = .byWordWrapping
        statusLabel.maximumNumberOfLines = 3
        statusLabel.isHidden = true

        buildCodeBlock()

        copyButton.target = self
        copyButton.action = #selector(copyClicked)
        copyButton.bezelStyle = .rounded
        copyButton.controlSize = .small

        runButton.target = self
        runButton.action = #selector(runClicked)
        runButton.bezelStyle = .rounded
        runButton.controlSize = .small
        runButton.keyEquivalent = "\r"

        let actionRow = NSStackView(views: [copyButton, runButton])
        actionRow.orientation = .horizontal
        actionRow.spacing = 6

        commandStack.orientation = .vertical
        commandStack.alignment = .leading
        commandStack.spacing = 8
        commandStack.translatesAutoresizingMaskIntoConstraints = false
        commandStack.addArrangedSubview(codeScroll)
        commandStack.addArrangedSubview(actionRow)
        commandStack.isHidden = true

        let stack = NSStackView(views: [titleRow, generateRow, shortcutHintLabel, statusLabel, commandStack])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.setCustomSpacing(3, after: generateRow)
        root.addSubview(stack)

        rootWidthConstraint = root.widthAnchor.constraint(equalToConstant: Self.minWidth)

        NSLayoutConstraint.activate([
            rootWidthConstraint,
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 12),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: root.bottomAnchor, constant: -12),
            titleRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            generateRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            shortcutHintLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            statusLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            commandStack.widthAnchor.constraint(equalTo: stack.widthAnchor),
            codeScroll.widthAnchor.constraint(equalTo: commandStack.widthAnchor),
            codeScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 64),
            intentField.widthAnchor.constraint(greaterThanOrEqualToConstant: 210),
        ])

        applyTheme(theme)
    }

    /// Mirrors `ToolInstance.codeEditor`'s own monospace/bordered/rounded
    /// code-block styling (Tools page's YAML/JSON output) rather than a
    /// plain `NSTextField`, so a generated command reads the same way any
    /// other code output in this app does.
    private func buildCodeBlock() {
        codeTextView.isEditable = false
        codeTextView.isSelectable = true
        codeTextView.isRichText = false
        codeTextView.font = .monospacedSystemFont(ofSize: 11.5, weight: .regular)
        codeTextView.textContainerInset = NSSize(width: 8, height: 8)
        codeTextView.isVerticallyResizable = true
        codeTextView.isHorizontallyResizable = false
        codeTextView.autoresizingMask = [.width]
        codeTextView.textContainer?.widthTracksTextView = true
        codeTextView.textColor = HelmTheme.nsColor(theme.chromeInkHex)
        codeTextView.backgroundColor = HelmTheme.nsColor(theme.backgroundHex)

        codeScroll.documentView = codeTextView
        codeScroll.hasVerticalScroller = true
        codeScroll.borderType = .noBorder
        codeScroll.wantsLayer = true
        codeScroll.layer?.cornerRadius = 8
        codeScroll.layer?.borderWidth = 1
        codeScroll.layer?.borderColor = HelmTheme.nsColor(theme.chromeLineHex).withAlphaComponent(0.5).cgColor
        codeScroll.translatesAutoresizingMaskIntoConstraints = false
    }

    func reset() {
        intentField.stringValue = ""
        generatedCommand = nil
        codeTextView.string = ""
        commandStack.isHidden = true
        statusLabel.isHidden = true
        generateButton.isEnabled = true
        intentField.isEnabled = true
        statusIsError = false
        updateWidth(for: nil)
    }

    /// Re-themes every colored element in the popover - registered against
    /// a live `ThemeManager.shared.observe` by `ConsoleComposerController`
    /// (see this file's header), not just applied once at construction.
    func applyTheme(_ theme: HelmTheme) {
        self.theme = theme
        let ink = HelmTheme.nsColor(theme.chromeInkHex)
        let muted = HelmTheme.mutedInk(theme)
        let background = HelmTheme.nsColor(theme.backgroundHex)
        let line = HelmTheme.nsColor(theme.chromeLineHex)

        view.layer?.backgroundColor = HelmTheme.nsColor(theme.chromeBackgroundHex).cgColor
        iconTile.applyTheme(theme)
        titleLabel.textColor = ink
        shortcutHintLabel.textColor = muted
        statusLabel.textColor = statusIsError ? .systemRed : muted
        codeTextView.textColor = ink
        codeTextView.backgroundColor = background
        codeScroll.layer?.borderColor = line.withAlphaComponent(0.5).cgColor
    }

    /// Measures the generated command's longest line against the code
    /// block's own font and clamps the result to `[minWidth, maxWidth]` -
    /// `nil` (no command yet, or a fresh/reset popover) always floors to
    /// `minWidth` so a short/empty state never leaves an oversized box.
    private func computeWidth(for command: String?) -> CGFloat {
        guard let command, !command.isEmpty else { return Self.minWidth }
        let font = codeTextView.font ?? .monospacedSystemFont(ofSize: 11.5, weight: .regular)
        let longestLine = command.components(separatedBy: "\n").max(by: { $0.count < $1.count }) ?? command
        let textWidth = (longestLine as NSString).size(withAttributes: [.font: font]).width
        // Stack leading/trailing insets (14pt each side) + the code block's
        // own text-container inset (8pt each side) + a little breathing room
        // for the vertical scroller.
        let chrome: CGFloat = (14 * 2) + (8 * 2) + 24
        return min(max(textWidth + chrome, Self.minWidth), Self.maxWidth)
    }

    private func updateWidth(for command: String?) {
        rootWidthConstraint.constant = computeWidth(for: command)
        view.layoutSubtreeIfNeeded()
        onSizeChanged?(view.fittingSize)
    }

    func focusIntentField() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.view.window?.makeFirstResponder(self.intentField)
        }
    }

    @objc private func generateClicked() {
        let intent = intentField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !intent.isEmpty else { return }
        generatedCommand = nil
        commandStack.isHidden = true
        statusIsError = false
        statusLabel.isHidden = false
        statusLabel.textColor = HelmTheme.mutedInk(theme)
        statusLabel.stringValue = "Generating…"
        generateButton.isEnabled = false
        intentField.isEnabled = false
        updateWidth(for: nil)

        ConsoleCommandComposer.generate(intent: intent) { [weak self] result in
            guard let self else { return }
            self.generateButton.isEnabled = true
            self.intentField.isEnabled = true
            switch result {
            case .success(let command):
                self.statusLabel.isHidden = true
                self.generatedCommand = command
                self.codeTextView.string = command
                self.commandStack.isHidden = false
                self.updateWidth(for: command)
            case .failure(let error):
                self.statusIsError = true
                self.statusLabel.isHidden = false
                self.statusLabel.textColor = .systemRed
                self.statusLabel.stringValue = error.message
                self.generatedCommand = nil
                self.commandStack.isHidden = true
                self.updateWidth(for: nil)
            }
        }
    }

    @objc private func copyClicked() {
        guard let command = generatedCommand else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
    }

    /// The only path that ever sends the generated command anywhere - never
    /// called automatically, only from this explicit button click (or its
    /// ⏎ key equivalent while it has focus).
    @objc private func runClicked() {
        guard let command = generatedCommand else { return }
        onRunInTerminal?(command)
    }
}
