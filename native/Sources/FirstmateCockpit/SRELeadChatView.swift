// Manjesh Grand Line - native macOS app.
//
// The SRE Lead pane's native message feed - replaces the tmux-mirrored
// interactive `claude` TUI (raw ANSI chrome, permission-mode banner,
// box-drawing borders) with a plain scrollable stack of message blocks plus
// a single-line input field, matching this app's existing visual language
// (`HelmTheme`, `HelmUIComponents.swift`'s hover/tint helpers) instead of
// showing someone else's CLI. See `SRELead.swift`'s header and the AGENTS.md
// "SRE Lead" bullet for why this replaced the terminal-based pane.
//
// This view knows nothing about `claude`, MCP, or the bridge - it only
// renders `SRELeadMessage` values `ConsoleController` appends (from
// `SRELeadRunner`'s callbacks) and reports submitted text via `onSubmit`.

import AppKit

struct SRELeadMessage {
    enum Role { case user, assistant, status, error }
    let role: Role
    let text: String
}

final class SRELeadChatView: NSView, NSTextFieldDelegate {
    var onSubmit: ((String) -> Void)?

    private let scroll = NSScrollView()
    private let document = FlippedView()
    private let stack = NSStackView()
    private let inputRow = NSView()
    private let inputField = NSTextField()
    private let sendButton = NSButton()
    private var documentTopConstraint: NSLayoutConstraint!

    private var theme: HelmTheme = ThemeManager.shared.theme
    private var messages: [SRELeadMessage] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        buildScroll()
        buildInputRow()
        applyTheme(theme)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func buildScroll() {
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        addSubview(scroll)

        document.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = document

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)

        documentTopConstraint = stack.topAnchor.constraint(equalTo: document.topAnchor, constant: 12)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -12),
            documentTopConstraint,
            stack.bottomAnchor.constraint(lessThanOrEqualTo: document.bottomAnchor, constant: -12),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
        ])
    }

    private func buildInputRow() {
        inputRow.translatesAutoresizingMaskIntoConstraints = false
        inputRow.wantsLayer = true
        addSubview(inputRow)

        inputField.translatesAutoresizingMaskIntoConstraints = false
        inputField.placeholderString = "Ask SRE Lead\u{2026}"
        inputField.font = .systemFont(ofSize: 12)
        inputField.isBordered = false
        inputField.focusRingType = .none
        inputField.delegate = self
        (inputField.cell as? NSTextFieldCell)?.usesSingleLineMode = true
        inputRow.addSubview(inputField)

        sendButton.translatesAutoresizingMaskIntoConstraints = false
        sendButton.title = ""
        sendButton.isBordered = false
        sendButton.image = NSImage(systemSymbolName: "arrow.up.circle.fill", accessibilityDescription: "Send")
        sendButton.imageScaling = .scaleProportionallyDown
        sendButton.target = self
        sendButton.action = #selector(submit)
        inputRow.addSubview(sendButton)

        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: inputRow.topAnchor),

            inputRow.leadingAnchor.constraint(equalTo: leadingAnchor),
            inputRow.trailingAnchor.constraint(equalTo: trailingAnchor),
            inputRow.bottomAnchor.constraint(equalTo: bottomAnchor),
            inputRow.heightAnchor.constraint(equalToConstant: 44),

            inputField.leadingAnchor.constraint(equalTo: inputRow.leadingAnchor, constant: 12),
            inputField.trailingAnchor.constraint(equalTo: sendButton.leadingAnchor, constant: -8),
            inputField.centerYAnchor.constraint(equalTo: inputRow.centerYAnchor),

            sendButton.trailingAnchor.constraint(equalTo: inputRow.trailingAnchor, constant: -10),
            sendButton.centerYAnchor.constraint(equalTo: inputRow.centerYAnchor),
            sendButton.widthAnchor.constraint(equalToConstant: 24),
            sendButton.heightAnchor.constraint(equalToConstant: 24),
        ])
    }

    // MARK: Messages

    func append(_ message: SRELeadMessage) {
        messages.append(message)
        let block = messageBlock(for: message)
        stack.addArrangedSubview(block)
        block.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        scrollToBottom()
    }

    func clearMessages() {
        messages.removeAll()
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
    }

    /// Disables input while a turn is in flight so the captain can't fire a
    /// second question before the first one's `claude -p` process exits -
    /// `SRELeadRunner` is not built to handle concurrent `ask` calls.
    func setInputEnabled(_ enabled: Bool) {
        inputField.isEnabled = enabled
        sendButton.isEnabled = enabled
    }

    private func scrollToBottom() {
        layoutSubtreeIfNeeded()
        let maxY = max(0, document.frame.height - scroll.contentView.bounds.height)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: maxY))
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    private func messageBlock(for message: SRELeadMessage) -> NSView {
        let label = NSTextField(wrappingLabelWithString: message.text)
        label.font = .systemFont(ofSize: 12.5)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.lineBreakMode = .byWordWrapping

        let container = NSView()
        container.wantsLayer = true
        container.layer?.cornerRadius = 8
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 10),
            label.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -10),
            label.topAnchor.constraint(equalTo: container.topAnchor, constant: 8),
            label.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -8),
        ])
        style(container, label: label, role: message.role)
        return container
    }

    private func style(_ container: NSView, label: NSTextField, role: SRELeadMessage.Role) {
        let ink = HelmTheme.nsColor(theme.chromeInkHex)
        let muted = HelmTheme.mutedInk(theme)
        switch role {
        case .user:
            container.layer?.backgroundColor = HelmTheme.nsColor(theme.accentHex).withAlphaComponent(0.16).cgColor
            label.textColor = ink
            label.font = .systemFont(ofSize: 12.5, weight: .medium)
        case .assistant:
            container.layer?.backgroundColor = HelmTheme.nsColor(theme.chromeBackgroundHex).cgColor
            label.textColor = ink
        case .status:
            container.layer?.backgroundColor = .clear
            label.textColor = muted
            label.font = .systemFont(ofSize: 11, weight: .regular)
        case .error:
            container.layer?.backgroundColor = HelmTheme.nsColor(theme.ansiHex[1]).withAlphaComponent(0.14).cgColor
            label.textColor = HelmTheme.nsColor(theme.ansiHex[1])
        }
    }

    @objc private func submit() {
        let text = inputField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        inputField.stringValue = ""
        onSubmit?(text)
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard let field = obj.object as? NSTextField, field === inputField else { return }
        guard let event = NSApp.currentEvent, event.type == .keyDown, event.keyCode == 36 else { return } // Return
        submit()
    }

    // MARK: Theming

    func applyTheme(_ theme: HelmTheme) {
        self.theme = theme
        layer?.backgroundColor = HelmTheme.nsColor(theme.backgroundHex).cgColor
        inputRow.layer?.backgroundColor = HelmTheme.nsColor(theme.chromeBackgroundHex).cgColor
        inputField.textColor = HelmTheme.nsColor(theme.chromeInkHex)
        (inputField.cell as? NSTextFieldCell)?.placeholderAttributedString = NSAttributedString(
            string: "Ask SRE Lead\u{2026}",
            attributes: [.foregroundColor: HelmTheme.mutedInk(theme)]
        )
        sendButton.contentTintColor = HelmTheme.nsColor(theme.accentHex)

        // Rebuild every block rather than trying to re-derive each one's
        // role from its current styling - `messages` is the source of truth
        // for what each block should look like, styling is a pure function
        // of it.
        let saved = messages
        clearMessages()
        for message in saved { append(message) }
    }
}
