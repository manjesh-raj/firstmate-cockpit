// Manjesh Grand Line - native macOS app.
//
// Phase 3 of "Knowledge and speed" (`fm/grandline-console-command-composer`):
// the "✨ Compose" popover a plain `.shell` tab's toolbar opens. Mirrors
// `ShiftMenuBarController`'s popover shape (`ShiftMenuBar.swift`) - a small
// `NSPopover` + a plain `NSViewController` content, no theme-following
// `NSVisualEffectView` tricks, since a popover already gets AppKit's own
// vibrant background for free.
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

/// The popover's content: an intent field + Generate, a status/error line,
/// and (once generated) the command for review with Copy/Run actions. No
/// history is kept - this is a one-shot generate-review-run per tab open,
/// per the task's explicit scope; closing and reopening the popover always
/// starts fresh (`reset()`).
private final class ConsoleComposerViewController: NSViewController {
    private let titleLabel = NSTextField(labelWithString: "Compose a command")
    private let intentField = NSTextField()
    private let generateButton = NSButton(title: "Generate", target: nil, action: nil)
    private let statusLabel = NSTextField(labelWithString: "")
    private let commandField = NSTextField()
    private let copyButton = NSButton(title: "Copy", target: nil, action: nil)
    private let runButton = NSButton(title: "Run in Terminal", target: nil, action: nil)
    private let commandStack = NSStackView()

    var onRunInTerminal: ((String) -> Void)?
    private var generatedCommand: String?

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 340, height: 150))
        view = root

        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)

        intentField.placeholderString = "Describe what you want to run…"
        intentField.font = .systemFont(ofSize: 12)
        intentField.target = self
        intentField.action = #selector(generateClicked)

        generateButton.target = self
        generateButton.action = #selector(generateClicked)
        generateButton.bezelStyle = .rounded
        generateButton.controlSize = .small

        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byWordWrapping
        statusLabel.maximumNumberOfLines = 3
        statusLabel.isHidden = true

        commandField.isEditable = false
        commandField.isSelectable = true
        commandField.isBordered = true
        commandField.drawsBackground = true
        commandField.font = .monospacedSystemFont(ofSize: 11.5, weight: .regular)
        commandField.lineBreakMode = .byCharWrapping
        commandField.cell?.wraps = true
        commandField.cell?.usesSingleLineMode = false

        copyButton.target = self
        copyButton.action = #selector(copyClicked)
        copyButton.bezelStyle = .rounded
        copyButton.controlSize = .small

        runButton.target = self
        runButton.action = #selector(runClicked)
        runButton.bezelStyle = .rounded
        runButton.controlSize = .small
        runButton.keyEquivalent = "\r"

        let generateRow = NSStackView(views: [intentField, generateButton])
        generateRow.orientation = .horizontal
        generateRow.spacing = 6
        generateRow.translatesAutoresizingMaskIntoConstraints = false

        let actionRow = NSStackView(views: [copyButton, runButton])
        actionRow.orientation = .horizontal
        actionRow.spacing = 6

        commandStack.orientation = .vertical
        commandStack.alignment = .leading
        commandStack.spacing = 6
        commandStack.translatesAutoresizingMaskIntoConstraints = false
        commandStack.addArrangedSubview(commandField)
        commandStack.addArrangedSubview(actionRow)
        commandStack.isHidden = true

        let stack = NSStackView(views: [titleLabel, generateRow, statusLabel, commandStack])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 12),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: root.bottomAnchor, constant: -12),
            generateRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            statusLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            commandStack.widthAnchor.constraint(equalTo: stack.widthAnchor),
            commandField.widthAnchor.constraint(equalTo: commandStack.widthAnchor),
            intentField.widthAnchor.constraint(greaterThanOrEqualToConstant: 210),
        ])
    }

    func reset() {
        intentField.stringValue = ""
        generatedCommand = nil
        commandField.stringValue = ""
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
        statusLabel.textColor = .secondaryLabelColor
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
                self.commandField.stringValue = command
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
