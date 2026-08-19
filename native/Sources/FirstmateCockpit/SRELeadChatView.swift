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
// carry no markdown (a captain's own typed question, or a short internal
// status/error string), so they render as plain text.
//
// `fm/grandline-sre-lead-chat-redesign`: a visual-quality-bar pass (see
// `data/grandline-sre-lead-chat-redesign/` for the captain's reference) that
// gave every message type a considered card treatment - see `accentCard(_:)`,
// `sectionLabel(_:)`, and `assistantBlock(for:)`'s header - without touching
// what SRE Lead says or how the Finding/Recommended-next-action contract is
// parsed (`SRELeadMarkdown.swift`, `SRELead.persona`). New structured fields
// like the reference's severity/downtime/confidence chips were deliberately
// NOT added - that's a behavior change to the persona's required output, not
// a rendering change, and needs its own explicit sign-off.

import AppKit

struct SRELeadMessage {
    enum Role { case user, assistant, status, error }
    let role: Role
    let text: String
}

final class SRELeadChatView: NSView, NSTextFieldDelegate {
    var onSubmit: ((String) -> Void)?

    /// Fired whenever `messages` changes (append or clear) - "Generate
    /// Postmortem"'s visibility (`ConsoleController.updateGeneratePostmortemButton`)
    /// depends on `hasRealExchange`, which only this view can evaluate.
    var onMessagesChanged: (() -> Void)?

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
        onMessagesChanged?()
    }

    func clearMessages() {
        messages.removeAll()
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        onMessagesChanged?()
    }

    /// "Generate Postmortem" is only offered once an investigation has
    /// produced real content - a bare "SRE Lead is ready" status message with
    /// no actual question asked yet doesn't count.
    var hasRealExchange: Bool {
        messages.contains { $0.role == .assistant }
    }

    /// The investigation transcript so far, as plain question/answer text -
    /// `SRELeadPostmortem.generate`'s prompt input. Only user/assistant turns
    /// are real investigation content; `.status`/`.error` messages are this
    /// pane's own UI chrome (readiness/error banners), not something SRE Lead
    /// or the captain actually said as part of the investigation.
    var transcriptForPostmortem: String {
        messages.compactMap { message -> String? in
            switch message.role {
            case .user: return "Captain: \(message.text)"
            case .assistant: return "SRE Lead: \(message.text)"
            case .status, .error: return nil
            }
        }.joined(separator: "\n\n")
    }

    /// `fm/grandline-sre-lead-per-tab`: the exact text of every message in
    /// this chat, in order - lets `SRELeadPerTabSelfTest` confirm a tab's
    /// chat contains only its own question/answer, never another tab's.
    func debugMessageTexts() -> [String] { messages.map { $0.text } }

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
        switch message.role {
        case .assistant: return assistantBlock(for: message.text)
        case .user: return userBlock(for: message.text)
        case .status: return statusBlock(for: message.text)
        case .error: return errorBlock(for: message.text)
        }
    }

    /// Shared "colored left accent bar + content" card, the one visual unit
    /// every role below (user question, Finding/Recommendation callouts,
    /// error) builds on - a colored bar reads clearly against every theme
    /// regardless of whether a given theme's surface tokens happen to be
    /// close together (see `HelmTheme.swift`'s own documented case where
    /// `chromeBackgroundHex`/`backgroundHex` coincide in a few themes), so
    /// the bar - not a background tint alone - is what actually guarantees
    /// the card reads as distinct. `backgroundTintAlpha` adds a very light
    /// wash of the same color for extra warmth; it is deliberately subtle so
    /// it never competes with the bar for "what color is this."
    private func accentCard(colorHex: String, backgroundTintAlpha: CGFloat, content: NSView) -> NSView {
        let bar = NSView()
        bar.wantsLayer = true
        bar.layer?.backgroundColor = HelmTheme.nsColor(colorHex).cgColor
        bar.layer?.cornerRadius = 1.5
        bar.translatesAutoresizingMaskIntoConstraints = false
        bar.widthAnchor.constraint(equalToConstant: 3).isActive = true

        let panel = NSView()
        panel.wantsLayer = true
        panel.layer?.cornerRadius = 10
        panel.layer?.backgroundColor = HelmTheme.nsColor(colorHex).withAlphaComponent(backgroundTintAlpha).cgColor
        panel.translatesAutoresizingMaskIntoConstraints = false
        content.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(bar)
        panel.addSubview(content)
        NSLayoutConstraint.activate([
            bar.leadingAnchor.constraint(equalTo: panel.leadingAnchor),
            bar.topAnchor.constraint(equalTo: panel.topAnchor),
            bar.bottomAnchor.constraint(equalTo: panel.bottomAnchor),

            content.leadingAnchor.constraint(equalTo: bar.trailingAnchor, constant: 12),
            content.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -12),
            content.topAnchor.constraint(equalTo: panel.topAnchor, constant: 10),
            content.bottomAnchor.constraint(equalTo: panel.bottomAnchor, constant: -10),
        ])
        return panel
    }

    /// A small bold, letter-spaced, uppercase section label in `colorHex` -
    /// the "FINDING" / "RECOMMENDED NEXT ACTION" / "ERROR" heading style used
    /// throughout the cards below, echoing the reference mockup's
    /// EXECUTIVE SUMMARY / ROOT CAUSE section headings without adopting any
    /// of its structured fields (severity/downtime/confidence) this app's
    /// persona doesn't produce.
    private func sectionLabel(_ text: String, colorHex: String) -> NSTextField {
        let label = NSTextField(labelWithString: "")
        label.attributedStringValue = NSAttributedString(string: text.uppercased(), attributes: [
            .foregroundColor: HelmTheme.nsColor(colorHex),
            .font: NSFont.systemFont(ofSize: 10.5, weight: .bold),
            .kern: 0.6,
        ])
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }

    private func userBlock(for text: String) -> NSView {
        let colorHex = theme.accentHex
        let label = sectionLabel("You", colorHex: colorHex)

        let body = NSTextField(wrappingLabelWithString: text)
        body.font = .systemFont(ofSize: 12.5, weight: .medium)
        body.textColor = HelmTheme.nsColor(theme.chromeInkHex)
        body.isSelectable = true
        body.lineBreakMode = .byWordWrapping
        body.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [label, body])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 5
        stack.translatesAutoresizingMaskIntoConstraints = false
        body.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        return accentCard(colorHex: colorHex, backgroundTintAlpha: 0.1, content: stack)
    }

    /// A short internal status line ("SRE Lead is ready...", "Thinking...")
    /// rendered as a centered system-message divider - a small muted label
    /// flanked by two hairlines - rather than a card, since this is this
    /// pane's own UI chrome, not investigation content.
    private func statusBlock(for text: String) -> NSView {
        func hairline() -> NSView {
            let line = NSView()
            line.wantsLayer = true
            line.layer?.backgroundColor = HelmTheme.nsColor(theme.chromeLineHex).withAlphaComponent(0.5).cgColor
            line.translatesAutoresizingMaskIntoConstraints = false
            line.heightAnchor.constraint(equalToConstant: 1).isActive = true
            line.setContentHuggingPriority(.defaultLow, for: .horizontal)
            return line
        }

        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 11)
        label.textColor = HelmTheme.mutedInk(theme)
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 0
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setContentHuggingPriority(.required, for: .horizontal)
        label.setContentCompressionResistancePriority(.required, for: .horizontal)

        let row = NSStackView(views: [hairline(), label, hairline()])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        row.distribution = .fill
        row.translatesAutoresizingMaskIntoConstraints = false
        return row
    }

    private func errorBlock(for text: String) -> NSView {
        let colorHex = HelmTint.critical.hex(in: theme)
        let label = sectionLabel("Error", colorHex: colorHex)

        let body = NSTextField(wrappingLabelWithString: text)
        body.font = .systemFont(ofSize: 12.5)
        body.textColor = HelmTheme.nsColor(theme.chromeInkHex)
        body.isSelectable = true
        body.lineBreakMode = .byWordWrapping
        body.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [label, body])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 5
        stack.translatesAutoresizingMaskIntoConstraints = false
        body.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        return accentCard(colorHex: colorHex, backgroundTintAlpha: 0.1, content: stack)
    }

    // MARK: Markdown rendering (assistant messages only)

    /// An assistant message's container: a bordered card with a small header
    /// (an `IconTileView` + "SRE Lead" label, the same "icon in a tinted
    /// square" idiom Bootstrap/Updates/Vault/Tools already use, rather than a
    /// new icon treatment) over a hairline divider, then a vertical stack of
    /// per-block views from `SRELeadMarkdown.parse` - the reference mockup's
    /// "card has a clear top before content starts" quality bar, applied to
    /// this app's own existing Finding/Recommendation contract rather than
    /// inventing new structured fields (severity/downtime/confidence chips)
    /// the persona doesn't produce.
    private func assistantBlock(for text: String) -> NSView {
        let icon = IconTileView(size: 22, cornerRadius: 6)
        icon.configure(symbol: "sparkles", tint: .accent, pointSize: 11)

        let title = NSTextField(labelWithString: "SRE Lead")
        title.font = .systemFont(ofSize: 11.5, weight: .semibold)
        title.textColor = HelmTheme.nsColor(theme.chromeInkHex)
        title.translatesAutoresizingMaskIntoConstraints = false

        let headerRow = NSStackView(views: [icon, title])
        headerRow.orientation = .horizontal
        headerRow.spacing = 8
        headerRow.alignment = .centerY
        headerRow.translatesAutoresizingMaskIntoConstraints = false

        let divider = NSView()
        divider.wantsLayer = true
        divider.layer?.backgroundColor = HelmTheme.nsColor(theme.chromeLineHex).withAlphaComponent(0.5).cgColor
        divider.translatesAutoresizingMaskIntoConstraints = false
        divider.heightAnchor.constraint(equalToConstant: 1).isActive = true

        let blockStack = NSStackView()
        blockStack.orientation = .vertical
        blockStack.alignment = .leading
        blockStack.spacing = 10
        blockStack.translatesAutoresizingMaskIntoConstraints = false
        for block in SRELeadMarkdown.parse(text) {
            let view = renderBlock(block)
            blockStack.addArrangedSubview(view)
            view.widthAnchor.constraint(equalTo: blockStack.widthAnchor).isActive = true
        }

        let contentStack = NSStackView(views: [headerRow, divider, blockStack])
        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = 10
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        headerRow.widthAnchor.constraint(equalTo: contentStack.widthAnchor).isActive = true
        divider.widthAnchor.constraint(equalTo: contentStack.widthAnchor).isActive = true
        blockStack.widthAnchor.constraint(equalTo: contentStack.widthAnchor).isActive = true

        let container = NSView()
        container.wantsLayer = true
        container.layer?.cornerRadius = 12
        container.layer?.backgroundColor = HelmTheme.nsColor(theme.chromeBackgroundHex).cgColor
        container.layer?.borderWidth = 1
        container.layer?.borderColor = HelmTheme.nsColor(theme.chromeLineHex).withAlphaComponent(0.5).cgColor
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(contentStack)
        NSLayoutConstraint.activate([
            contentStack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            contentStack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            contentStack.topAnchor.constraint(equalTo: container.topAnchor, constant: 12),
            contentStack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -12),
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

    /// A non-editable but selectable, word-wrapping label showing pre-built
    /// attributed text - `NSTextField(wrappingLabelWithString:)` only
    /// accepts a plain `String`, so mixed bold/code runs need this manual
    /// equivalent instead. `isSelectable = true` (with `isEditable` left
    /// false) is what makes click-drag-select + Cmd-C and the right-click
    /// Copy menu work on this text - an `NSTextField` defaults to
    /// non-selectable, which is why none of this pane's text could be
    /// selected before this fix.
    private func wrappingLabel(_ text: NSAttributedString) -> NSTextField {
        let label = NSTextField()
        label.isEditable = false
        label.isSelectable = true
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
        // A soft accent tint (rather than the previous flat neutral gray)
        // reads as a deliberate "chip," closer to the reference mockup's
        // inline code chips (`checkout-api`, `v2.15.0`) - `NSAttributedString`
        // backgrounds are rectangular with no corner radius, so this is the
        // practical ceiling for an inline (not block-level) code span in
        // AppKit without promoting every code run to its own view.
        let codeBackground = HelmTheme.nsColor(theme.accentHex).withAlphaComponent(0.14)
        let result = NSMutableAttributedString()
        for run in runs {
            var attributes: [NSAttributedString.Key: Any] = [.foregroundColor: ink]
            if run.code {
                attributes[.font] = NSFont.monospacedSystemFont(ofSize: baseSize - 1, weight: .medium)
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
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false

        for item in items {
            // A small colored dot instead of a plain ink "•" - echoes the
            // reference mockup's colored NEXT ACTIONS dots, using this app's
            // own accent hue rather than a fixed literal color.
            let bullet = NSTextField(labelWithString: "\u{25CF}")
            bullet.font = .systemFont(ofSize: 7)
            bullet.textColor = HelmTheme.nsColor(theme.accentHex)
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

    /// A fenced code block: monospace text on a subtly tinted, rounded,
    /// hairline-bordered panel - `theme.chromeLineHex` again, at a slightly
    /// stronger alpha than an inline code span since this is the block's
    /// whole background, not a small highlight behind a few characters. The
    /// added border (absent before this pass) gives the block a defined edge
    /// rather than just a soft color wash, matching the rest of this file's
    /// bordered-card treatment.
    private func codeBlockView(_ code: String) -> NSView {
        let label = NSTextField(wrappingLabelWithString: code)
        label.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        label.textColor = HelmTheme.nsColor(theme.chromeInkHex)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.lineBreakMode = .byWordWrapping
        label.isSelectable = true

        let panel = NSView()
        panel.wantsLayer = true
        panel.layer?.cornerRadius = 7
        panel.layer?.backgroundColor = HelmTheme.nsColor(theme.chromeLineHex).withAlphaComponent(0.22).cgColor
        panel.layer?.borderWidth = 1
        panel.layer?.borderColor = HelmTheme.nsColor(theme.chromeLineHex).withAlphaComponent(0.4).cgColor
        panel.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 10),
            label.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -10),
            label.topAnchor.constraint(equalTo: panel.topAnchor, constant: 8),
            label.bottomAnchor.constraint(equalTo: panel.bottomAnchor, constant: -8),
        ])
        return panel
    }

    /// The Finding/Recommended-next-action blocks' distinct callout styling:
    /// a bold, letter-spaced section label (`sectionLabel`, echoing the
    /// reference mockup's EXECUTIVE SUMMARY/ROOT CAUSE headings) over body
    /// text, on the shared `accentCard` - a colored left bar plus a light
    /// wash of the same hue, replacing the old flat full-panel tint. Finding
    /// gets `.accent` (the app's own "this is the headline" hue);
    /// Recommended next action gets `.good` (green, reads as "the actionable
    /// step") - both resolved against the active theme's own hues via
    /// `HelmTint`, never a literal color.
    private func calloutView(kind: SRELeadCalloutKind, runs: [SRELeadInlineRun]) -> NSView {
        let tint: HelmTint = kind == .finding ? .accent : .good
        let colorHex = tint.hex(in: theme)

        let label = sectionLabel(kind.label, colorHex: colorHex)
        let body = wrappingLabel(attributedInline(runs))

        let inner = NSStackView(views: [label, body])
        inner.orientation = .vertical
        inner.alignment = .leading
        inner.spacing = 6
        inner.translatesAutoresizingMaskIntoConstraints = false
        body.widthAnchor.constraint(equalTo: inner.widthAnchor).isActive = true

        return accentCard(colorHex: colorHex, backgroundTintAlpha: 0.08, content: inner)
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
