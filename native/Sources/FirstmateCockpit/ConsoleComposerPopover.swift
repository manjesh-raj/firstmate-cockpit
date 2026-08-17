// Manjesh Grand Line - native macOS app.
//
// Phase 3 of "Knowledge and speed" (`fm/grandline-console-command-composer`):
// the "✨ Compose" popover a plain `.shell` tab's toolbar opens. Mirrors
// `ShiftMenuBarController`'s popover shape (`ShiftMenuBar.swift`) - a small
// `NSPopover` + a plain `NSViewController` content, no theme-following
// `NSVisualEffectView` tricks, since a popover already gets AppKit's own
// vibrant background for free.
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
// `⌘⏎` shortcut hint next to the intent field. Theme colors are read once
// at construction (`ThemeManager.shared.theme`), the same one-shot pattern
// `IconTileView.configure` itself already uses - this popover is
// `.transient` and short-lived, so it doesn't need a live theme observer
// the way a permanent destination does.
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
}

/// The popover's content: a tinted-icon header, an intent field + Generate
/// (with a `⌘⏎` shortcut hint), a status/error line, and (once generated) the
/// command in a real code-block view with Copy/Run actions. No history is
/// kept - this is a one-shot generate-review-run per tab open, per the
/// task's explicit scope; closing and reopening the popover always starts
/// fresh (`reset()`).
private final class ConsoleComposerViewController: NSViewController {
    private let theme = ThemeManager.shared.theme

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
    private var generatedCommand: String?

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 380, height: 170))
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

        NSLayoutConstraint.activate([
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
        statusLabel.isHidden = false
        statusLabel.textColor = HelmTheme.mutedInk(theme)
        statusLabel.stringValue = "Generating…"
        generateButton.isEnabled = false
        intentField.isEnabled = false

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
            case .failure(let error):
                self.statusLabel.isHidden = false
                self.statusLabel.textColor = .systemRed
                self.statusLabel.stringValue = error.message
                self.generatedCommand = nil
                self.commandStack.isHidden = true
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
