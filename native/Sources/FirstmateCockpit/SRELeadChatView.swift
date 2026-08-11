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
//
// `fm/cockpit-sre-lead-reply-formatting`: an assistant message used to be one
// plain `NSTextField(wrappingLabelWithString:)` - no bold, no code, no lists,
// even when the reply text already contained that markdown, which was the
// captain's exact complaint ("no highlights, no bold, no blocks"). An
// assistant message's text is now parsed by `SRELeadMarkdown.parse` into
// blocks (paragraph/bulletList/codeBlock/callout) and each block gets its own
// small AppKit view - see `renderBlock(_:)` below. User/status/error messages
// are unchanged (plain text - a captain's own typed question, or a short
// internal status/error string, neither of which carries the persona's
// markdown convention).

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
        if message.role == .assistant {
            return assistantBlock(for: message.text)
        }
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
            break // handled by assistantBlock(for:) instead
        case .status:
            container.layer?.backgroundColor = .clear
            label.textColor = muted
            label.font = .systemFont(ofSize: 11, weight: .regular)
        case .error:
            container.layer?.backgroundColor = HelmTheme.nsColor(theme.ansiHex[1]).withAlphaComponent(0.14).cgColor
            label.textColor = HelmTheme.nsColor(theme.ansiHex[1])
        }
    }

    // MARK: Markdown rendering (assistant messages only)

    /// An assistant message's container: same rounded/tinted chrome the plain
    /// `.assistant` case used to apply directly to one label, now wrapping a
    /// vertical stack of per-block views from `SRELeadMarkdown.parse`.
    private func assistantBlock(for text: String) -> NSView {
        let blockStack = NSStackView()
        blockStack.orientation = .vertical
        blockStack.alignment = .leading
        blockStack.spacing = 8
        blockStack.translatesAutoresizingMaskIntoConstraints = false
        for block in SRELeadMarkdown.parse(text) {
            let view = renderBlock(block)
            blockStack.addArrangedSubview(view)
            view.widthAnchor.constraint(equalTo: blockStack.widthAnchor).isActive = true
        }

        let container = NSView()
        container.wantsLayer = true
        container.layer?.cornerRadius = 8
        container.layer?.backgroundColor = HelmTheme.nsColor(theme.chromeBackgroundHex).cgColor
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(blockStack)
        NSLayoutConstraint.activate([
            blockStack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 10),
            blockStack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -10),
            blockStack.topAnchor.constraint(equalTo: container.topAnchor, constant: 8),
            blockStack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -8),
        ])
        return container
    }

    private func renderBlock(_ block: SRELeadMarkdownBlock) -> NSView {
        switch block {
        case .paragraph(let runs):
            return wrappingLabel(attributedInline(runs))
        case .bulletList(let items):
            return bulletListView(items)
        case .codeBlock(let code):
            return codeBlockView(code)
        case .callout(let kind, let runs):
            return calloutView(kind: kind, runs: runs)
        }
    }

    /// A non-editable, word-wrapping label showing pre-built attributed text
    /// - `NSTextField(wrappingLabelWithString:)` only accepts a plain
    /// `String`, so mixed bold/code runs need this manual equivalent instead.
    private func wrappingLabel(_ text: NSAttributedString) -> NSTextField {
        let label = NSTextField()
        label.isEditable = false
        label.isSelectable = false
        label.isBordered = false
        label.drawsBackground = false
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 0
        label.attributedStringValue = text
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return label
    }

    /// Renders inline runs into one attributed string: bold text gets a
    /// semibold weight, code spans get a monospace font plus a subtle tinted
    /// background (`theme.chromeLineHex`, the same "line/border" token every
    /// other themed view already uses for subtle chrome - not a new literal
    /// color), everything else the base ink color at the base weight.
    private func attributedInline(_ runs: [SRELeadInlineRun], baseSize: CGFloat = 12.5) -> NSAttributedString {
        let ink = HelmTheme.nsColor(theme.chromeInkHex)
        let codeBackground = HelmTheme.nsColor(theme.chromeLineHex).withAlphaComponent(0.35)
        let result = NSMutableAttributedString()
        for run in runs {
            var attributes: [NSAttributedString.Key: Any] = [.foregroundColor: ink]
            if run.code {
                attributes[.font] = NSFont.monospacedSystemFont(ofSize: baseSize - 1, weight: .regular)
                attributes[.backgroundColor] = codeBackground
            } else if run.bold {
                attributes[.font] = NSFont.systemFont(ofSize: baseSize, weight: .semibold)
            } else {
                attributes[.font] = NSFont.systemFont(ofSize: baseSize)
            }
            result.append(NSAttributedString(string: run.text, attributes: attributes))
        }
        return result
    }

    private func bulletListView(_ items: [[SRELeadInlineRun]]) -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false

        for item in items {
            let bullet = NSTextField(labelWithString: "\u{2022}")
            bullet.font = .systemFont(ofSize: 12.5)
            bullet.textColor = HelmTheme.nsColor(theme.chromeInkHex)
            bullet.translatesAutoresizingMaskIntoConstraints = false
            bullet.setContentHuggingPriority(.required, for: .horizontal)
            bullet.setContentCompressionResistancePriority(.required, for: .horizontal)

            let body = wrappingLabel(attributedInline(item))

            let row = NSStackView(views: [bullet, body])
            row.orientation = .horizontal
            row.alignment = .top
            row.spacing = 6
            row.distribution = .fill
            row.translatesAutoresizingMaskIntoConstraints = false

            stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        return stack
    }

    /// A fenced code block: monospace text on a subtly tinted, rounded
    /// panel - `theme.chromeLineHex` again, at a slightly stronger alpha than
    /// an inline code span since this is the block's whole background, not
    /// a small highlight behind a few characters.
    private func codeBlockView(_ code: String) -> NSView {
        let label = NSTextField(wrappingLabelWithString: code)
        label.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        label.textColor = HelmTheme.nsColor(theme.chromeInkHex)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.lineBreakMode = .byWordWrapping

        let panel = NSView()
        panel.wantsLayer = true
        panel.layer?.cornerRadius = 6
        panel.layer?.backgroundColor = HelmTheme.nsColor(theme.chromeLineHex).withAlphaComponent(0.22).cgColor
        panel.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -8),
            label.topAnchor.constraint(equalTo: panel.topAnchor, constant: 6),
            label.bottomAnchor.constraint(equalTo: panel.bottomAnchor, constant: -6),
        ])
        return panel
    }

    /// The Finding/Recommended-next-action blocks' distinct callout styling
    /// (beyond plain bold): a small house-style pill (`ToolRowLayout.pill`,
    /// the same pill every Updates/Bootstrap row status already uses) as the
    /// label, over the body text, on a rounded panel tinted with the same hue
    /// as the pill. Finding gets `.accent` (the app's own "this is the
    /// headline" hue); Recommended next action gets `.good` (green, reads as
    /// "the actionable step") - both resolved against the active theme's own
    /// hues via `HelmTint`, never a literal color.
    private func calloutView(kind: SRELeadCalloutKind, runs: [SRELeadInlineRun]) -> NSView {
        let tint: HelmTint = kind == .finding ? .accent : .good
        let colorHex = tint.hex(in: theme)

        let pill = NSView()
        let pillLabel = NSTextField(labelWithString: "")
        ToolRowLayout.pill(text: kind.label, colorHex: colorHex, into: pill, label: pillLabel)
        pill.setContentHuggingPriority(.required, for: .horizontal)
        pill.setContentCompressionResistancePriority(.required, for: .horizontal)

        let body = wrappingLabel(attributedInline(runs))

        let inner = NSStackView(views: [pill, body])
        inner.orientation = .vertical
        inner.alignment = .leading
        inner.spacing = 6
        inner.translatesAutoresizingMaskIntoConstraints = false
        body.widthAnchor.constraint(equalTo: inner.widthAnchor).isActive = true

        let panel = NSView()
        panel.wantsLayer = true
        panel.layer?.cornerRadius = 8
        panel.layer?.backgroundColor = HelmTheme.nsColor(colorHex).withAlphaComponent(0.12).cgColor
        panel.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(inner)
        NSLayoutConstraint.activate([
            inner.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 10),
            inner.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -10),
            inner.topAnchor.constraint(equalTo: panel.topAnchor, constant: 8),
            inner.bottomAnchor.constraint(equalTo: panel.bottomAnchor, constant: -8),
        ])
        return panel
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
