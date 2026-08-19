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
// small pill-button convention (the same one Vault's "Run injected…"/"Copy
// Name" row buttons use - all of them `HelmButton` since the design system's
// phase 2), and a
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
// `fm/grandline-shift-side-by-side-composer-height` gave the intent field
// real multi-line height (captain: "increase the vertical view... so the
// user can see the text more and have a better visibility") - the field was
// a single-line `NSTextField` that scrolled its own content sideways as you
// typed. `intentTextView`/`intentScroll` (a bordered, corner-radius
// `NSScrollView`/`NSTextView` pair, mirroring the code block's own
// `codeScroll`/`codeTextView` styling below rather than inventing a new
// look) replace it - `NSTextView` has no built-in placeholder API the way
// `NSTextField`'s cell does, so `intentPlaceholderLabel` is a plain muted
// label overlaid at the text container's own inset, toggled by
// `NSTextViewDelegate.textDidChange(_:)`. `⌘⏎` still fires Generate: that
// shortcut was already handled by `generateButton`'s own `keyEquivalent`,
// which `NSWindow`'s `performKeyEquivalent:` traversal reaches before an
// event ever gets to whichever view is first responder - unaffected by
// swapping the field for a text view. A plain Return now inserts a newline
// (the field's own former submit-on-Return action only ever existed because
// a single-line field has no better use for Return) rather than submitting,
// which is the expected behavior for a field that's now genuinely
// multi-line.
//
// Nothing here ever runs a generated command automatically - see
// `ConsoleCommandComposer.swift`'s header and this task's PR description for
// the full design-constraint reasoning (SRE Lead's own approval-gated
// posture, the captain's explicit "look before you run" expectation). The
// generated command is only ever shown for review; `onRunInTerminal` is the
// one explicit action that sends anything to a real terminal, wired by
// `ConsoleController` to `currentTab?.terminal.send(txt:)` - the same call a
// Snippet's own "Run" action already uses.
//
// `fm/grandline-composer-input-styling` fixed a real captain-reported bug:
// the intent field read as plain, undifferentiated text with no visible
// field boundary, since `intentTextView.drawsBackground` was `false` and
// `intentScroll` never had a background fill of its own - only a barely-
// visible 1pt/50%-alpha border. Fixed by giving both `intentTextView` and
// `codeTextView` a real, shared "sunken field" fill
// (`ConsoleComposerViewController.fieldFillColor(for:)`) and bumping the
// border alpha (`Self.fieldBorderAlpha`, 0.5 -> 0.7) on both scroll views -
// see that method's own doc comment for why it blends `chromeInkHex` into
// `chromeBackgroundHex` rather than reusing `backgroundHex` directly (the
// two are numerically identical in 3 of 12 `HelmTheme.allThemes`, which
// would have silently reproduced the same invisible-field bug in exactly
// those themes).

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
private final class ConsoleComposerViewController: NSViewController, NSTextViewDelegate {
    private var theme = ThemeManager.shared.theme

    /// Popover width grows to fit a long generated command, floored/capped
    /// so a short command doesn't leave an oversized empty box and a long
    /// one can never grow off whatever screen it's on.
    static let minWidth: CGFloat = 380
    static let maxWidth: CGFloat = 640
    private var rootWidthConstraint: NSLayoutConstraint!

    /// A few visible lines of wrapped text, per the captain's explicit ask -
    /// see this file's header for why this replaced a single-line field.
    static let intentHeight: CGFloat = 72

    /// Border opacity for the intent field and code-block scroll views -
    /// bumped from the original 0.5 (which, combined with the intent field's
    /// former `drawsBackground = false`, is why the input box read as
    /// undifferentiated text - see this file's header) to a more visible
    /// level so the boundary itself is never the only thing telling these
    /// controls apart from the popover's own background.
    static let fieldBorderAlpha: CGFloat = 0.7

    private let iconTile = IconTileView(size: 30, cornerRadius: 8)
    private let titleLabel = NSTextField(labelWithString: "Compose a command")
    private let intentScroll = NSScrollView()
    private let intentTextView = NSTextView()
    private let intentPlaceholderLabel = NSTextField(labelWithString: "Describe what you want to run…")
    private let generateButton = HelmButton(title: "Generate", variant: .primary, target: nil, action: nil)
    private let shortcutHintLabel = NSTextField(labelWithString: "\u{2318}\u{23ce} to generate")
    private let statusLabel = NSTextField(labelWithString: "")

    private let codeScroll = NSScrollView()
    private let codeTextView = NSTextView()
    private let copyButton = HelmButton(title: "Copy", variant: .secondary, target: nil, action: nil)
    private let runButton = HelmButton(title: "Run in Terminal", variant: .primary, target: nil, action: nil)
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

        buildIntentField()

        generateButton.target = self
        generateButton.action = #selector(generateClicked)
        generateButton.controlSize = .small
        // `⌘⏎` fires Generate regardless of first responder - `NSWindow`'s
        // `performKeyEquivalent:` traversal reaches this button before a
        // command-modified key event ever reaches whichever view is first
        // responder, so this works the same whether the intent field is
        // focused or not. A plain Return inside the (now multi-line) intent
        // field just inserts a newline, per this file's header.
        generateButton.keyEquivalent = "\r"
        generateButton.keyEquivalentModifierMask = [.command]

        let generateRow = NSStackView(views: [intentScroll, generateButton])
        generateRow.orientation = .horizontal
        generateRow.distribution = .fill
        generateRow.alignment = .bottom
        generateRow.spacing = 6
        generateRow.translatesAutoresizingMaskIntoConstraints = false
        // Gotcha #10 (AGENTS.md): `.gravityAreas` (the default) doesn't let
        // hugging/compression priorities absorb slack width - `.fill` plus
        // an explicit priority split is what makes `intentScroll`, not
        // `generateButton`, take the row's leftover width.
        intentScroll.setContentHuggingPriority(.defaultLow, for: .horizontal)
        intentScroll.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        generateButton.setContentHuggingPriority(.required, for: .horizontal)
        generateButton.setContentCompressionResistancePriority(.required, for: .horizontal)

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
        copyButton.controlSize = .small

        runButton.target = self
        runButton.action = #selector(runClicked)
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
            intentScroll.heightAnchor.constraint(equalToConstant: Self.intentHeight),
            intentPlaceholderLabel.leadingAnchor.constraint(equalTo: intentScroll.leadingAnchor, constant: 8),
            intentPlaceholderLabel.topAnchor.constraint(equalTo: intentScroll.topAnchor, constant: 8),
            intentPlaceholderLabel.trailingAnchor.constraint(lessThanOrEqualTo: intentScroll.trailingAnchor, constant: -8),
        ])

        applyTheme(theme)
    }

    /// A bordered, corner-radius `NSScrollView`/`NSTextView` pair sized for
    /// a few visible lines - mirrors `buildCodeBlock()`'s own code-block
    /// styling below rather than a plain single-line `NSTextField`. See this
    /// file's header for why (captain ask for more visible height) and why
    /// the placeholder is a manually-overlaid label rather than a built-in
    /// API (`NSTextView` has none).
    private func buildIntentField() {
        intentTextView.isRichText = false
        intentTextView.isEditable = true
        intentTextView.isSelectable = true
        intentTextView.font = .systemFont(ofSize: 12)
        intentTextView.textContainerInset = NSSize(width: 4, height: 6)
        intentTextView.isVerticallyResizable = true
        intentTextView.isHorizontallyResizable = false
        intentTextView.autoresizingMask = [.width]
        intentTextView.textContainer?.widthTracksTextView = true
        // `drawsBackground = true` + an explicit theme-derived fill (set in
        // `applyTheme` via `fieldFillColor(for:)`, shared with `codeTextView`
        // below) is the actual fix for the "input box has no visible
        // boundary" bug - `drawsBackground = false` left this control fully
        // transparent except for a barely-visible border, so on a light
        // theme especially it visually disappeared into the popover's own
        // `chromeBackgroundHex` background. See this file's header.
        intentTextView.drawsBackground = true
        intentTextView.delegate = self

        intentScroll.documentView = intentTextView
        intentScroll.hasVerticalScroller = true
        intentScroll.borderType = .noBorder
        intentScroll.wantsLayer = true
        intentScroll.layer?.cornerRadius = 8
        intentScroll.layer?.borderWidth = 1
        intentScroll.drawsBackground = false
        intentScroll.translatesAutoresizingMaskIntoConstraints = false

        intentPlaceholderLabel.font = intentTextView.font
        intentPlaceholderLabel.isEditable = false
        intentPlaceholderLabel.isBordered = false
        intentPlaceholderLabel.isSelectable = false
        intentPlaceholderLabel.drawsBackground = false
        intentPlaceholderLabel.lineBreakMode = .byWordWrapping
        intentPlaceholderLabel.maximumNumberOfLines = 1
        intentPlaceholderLabel.translatesAutoresizingMaskIntoConstraints = false
        intentScroll.addSubview(intentPlaceholderLabel)
    }

    func textDidChange(_ notification: Notification) {
        updateIntentPlaceholderVisibility()
    }

    private func updateIntentPlaceholderVisibility() {
        intentPlaceholderLabel.isHidden = !intentTextView.string.isEmpty
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
        codeTextView.backgroundColor = Self.fieldFillColor(for: theme)

        codeScroll.documentView = codeTextView
        codeScroll.hasVerticalScroller = true
        codeScroll.borderType = .noBorder
        codeScroll.wantsLayer = true
        codeScroll.layer?.cornerRadius = 8
        codeScroll.layer?.borderWidth = 1
        codeScroll.drawsBackground = false
        codeScroll.layer?.borderColor = HelmTheme.nsColor(theme.chromeLineHex).withAlphaComponent(Self.fieldBorderAlpha).cgColor
        codeScroll.translatesAutoresizingMaskIntoConstraints = false
    }

    func reset() {
        intentTextView.string = ""
        updateIntentPlaceholderVisibility()
        generatedCommand = nil
        codeTextView.string = ""
        commandStack.isHidden = true
        statusLabel.isHidden = true
        generateButton.isEnabled = true
        intentTextView.isEditable = true
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
        let line = HelmTheme.nsColor(theme.chromeLineHex)
        let fieldFill = Self.fieldFillColor(for: theme)

        view.layer?.backgroundColor = HelmTheme.nsColor(theme.chromeBackgroundHex).cgColor
        iconTile.applyTheme(theme)
        titleLabel.textColor = ink
        shortcutHintLabel.textColor = muted
        statusLabel.textColor = statusIsError ? .systemRed : muted
        codeTextView.textColor = ink
        codeTextView.backgroundColor = fieldFill
        codeScroll.layer?.borderColor = line.withAlphaComponent(Self.fieldBorderAlpha).cgColor
        intentTextView.textColor = ink
        intentTextView.insertionPointColor = ink
        intentTextView.backgroundColor = fieldFill
        intentPlaceholderLabel.textColor = muted
        intentScroll.layer?.borderColor = line.withAlphaComponent(Self.fieldBorderAlpha).cgColor
    }

    /// The "sunken field" fill both `intentTextView` and `codeTextView` use -
    /// see this file's header for why the intent field previously had none
    /// at all. Deliberately blends `chromeInkHex` into `chromeBackgroundHex`
    /// (the popover root's own fill) rather than using `backgroundHex`
    /// directly: `chromeBackgroundHex` and `backgroundHex` are numerically
    /// identical in 3 of the 12 `HelmTheme.allThemes` (`gruvbox-light`,
    /// `tokyo-night-dark`, `tokyo-night-light` - see AGENTS.md's
    /// `fm/grandline-sre-lead-polish` entry for the same gotcha found
    /// elsewhere), which would have silently reproduced this exact bug in
    /// those three themes. Ink and background are guaranteed to differ in
    /// every theme (otherwise text would be invisible), so blending toward
    /// ink at a small fraction always yields a fill distinct from the root.
    private static func fieldFillColor(for theme: HelmTheme) -> NSColor {
        let chromeBackground = HelmTheme.nsColor(theme.chromeBackgroundHex)
        let ink = HelmTheme.nsColor(theme.chromeInkHex)
        return chromeBackground.blended(withFraction: 0.08, of: ink) ?? chromeBackground
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
            self.view.window?.makeFirstResponder(self.intentTextView)
        }
    }

    @objc private func generateClicked() {
        let intent = intentTextView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !intent.isEmpty else { return }
        generatedCommand = nil
        commandStack.isHidden = true
        statusIsError = false
        statusLabel.isHidden = false
        statusLabel.textColor = HelmTheme.mutedInk(theme)
        statusLabel.stringValue = "Generating…"
        generateButton.isEnabled = false
        intentTextView.isEditable = false
        updateWidth(for: nil)

        ConsoleCommandComposer.generate(intent: intent) { [weak self] result in
            guard let self else { return }
            self.generateButton.isEnabled = true
            self.intentTextView.isEditable = true
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
