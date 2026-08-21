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

final class SRELeadChatView: NSView, NSTextViewDelegate {
    var onSubmit: ((String) -> Void)?

    /// Fired whenever `messages` changes (append or clear) - "Generate
    /// Postmortem"'s visibility (`ConsoleController.updateGeneratePostmortemButton`)
    /// depends on `hasRealExchange`, which only this view can evaluate.
    var onMessagesChanged: (() -> Void)?

    private let scroll = NSScrollView()
    private let document = FlippedView()
    private let stack = NSStackView()

    // MARK: Composer
    //
    // `fm/grandline-input-composer-redesign`: this used to be a single flat
    // `NSTextField` on a bare hairline-divided strip - no card, no toolbar,
    // no sense that this was a distinct, considered control rather than an
    // afterthought (the captain's own screenshot of this exact pane).
    // `composerCard` (`HelmComposerCard`, `HelmUIComponents.swift`) is the
    // shared "rounded, sunken, focus-glows" card this pane shares with the
    // Console Composer popover; everything inside it - the auto-resizing
    // multi-line text view and the toolbar row - is this pane's own content.

    /// Padding wrapper between the composer card and this view's own edges -
    /// the reference mockup's `.sre-area` padding, not part of the card
    /// itself.
    private let composerWrap = NSView()
    /// The small uppercase caption above the card - mirrors the reference
    /// mockup's "ASK THE CLUSTER" label and this app's own section-kicker
    /// convention (`HelmFormSheet.addSection`).
    private let composerKicker = NSTextField(labelWithString: "Ask a question")
    private let composerCard = HelmComposerCard(cornerRadius: HelmMetrics.rRow)
    private let textScroll = NSScrollView()
    private let textView = NSTextView()
    /// `NSTextView` has no built-in placeholder API - a plain muted label
    /// overlaid at the text container's own inset, toggled on every edit
    /// (mirrors `ConsoleComposerViewController.intentPlaceholderLabel`).
    private let textPlaceholderLabel = NSTextField(labelWithString: "Ask SRE Lead\u{2026}")
    private let toolbarRow = NSView()
    /// A `HelmButton(.primary)` rather than the plain borderless accent-glyph
    /// button this replaced - `.primary`'s own `isEnabled` dimming (see
    /// `HelmButton.restyle()`) is exactly the reference mockup's "muted until
    /// there's real text" send-button behaviour, for free.
    private let sendButton = HelmButton(symbol: "arrow.up", variant: .primary, size: .small)
    private var textScrollHeightConstraint: NSLayoutConstraint!
    private var documentTopConstraint: NSLayoutConstraint!

    /// The text view's height clamps between one line's worth of content and
    /// a handful of lines - the reference mockup's own `min-height`/
    /// `max-height` pair on `.sre-input`, translated into an Auto Layout
    /// constraint this view updates by hand on every edit (`NSTextView` has
    /// no "grow with content, up to a cap" behaviour of its own).
    private static let minTextHeight: CGFloat = 34
    private static let maxTextHeight: CGFloat = 120

    /// Whether the composer is allowed to accept input at all right now -
    /// independent of whether it currently holds real text. The send button
    /// is enabled only when both this and `hasText` are true, which is what
    /// gives it the reference mockup's "muted until there's something to
    /// send" behaviour without losing the pre-existing "disabled while a
    /// turn is in flight" gate.
    private var isInputEnabled = true

    private var theme: HelmTheme = ThemeManager.shared.theme
    private var messages: [SRELeadMessage] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        buildScroll()
        buildComposer()
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

    /// Builds the composer: a padded wrapper holding a small kicker caption
    /// and the `HelmComposerCard` itself, which in turn holds the
    /// auto-resizing text view and a toolbar row carrying the send button.
    ///
    /// No left-side toolbar icons were added (the reference mockup shows a
    /// "+"/attach pair) - neither has a real backing action on this pane
    /// today (there is no context-attachment mechanism for SRE Lead), and
    /// this task's brief is explicit that inventing one would be a
    /// functional change, not a layout redesign. Likewise no separate
    /// "connection status" chip was added above the card: the pane's own
    /// header (`ConsoleController.sreLeadStatusPill`) already shows this
    /// tab's live SRE Lead phase (ready/starting/failed) immediately above
    /// this whole card, so a second copy of the same signal a few dozen
    /// points below it would be pure duplication, not information - this
    /// app's own "quiet until it matters" convention (see the Notification
    /// Center section of AGENTS.md) argues against it. Send button aside,
    /// this leaves the toolbar row itself as the one real "whatever actions
    /// make sense here" surface for a future task that adds one.
    private func buildComposer() {
        composerWrap.translatesAutoresizingMaskIntoConstraints = false
        addSubview(composerWrap)

        composerKicker.translatesAutoresizingMaskIntoConstraints = false
        composerKicker.attributedStringValue = NSAttributedString(
            string: "Ask a question".uppercased(),
            attributes: [.font: HelmType.kicker(), .kern: HelmType.kickerKern]
        )

        composerCard.translatesAutoresizingMaskIntoConstraints = false

        let composerStack = NSStackView(views: [composerKicker, composerCard])
        composerStack.orientation = .vertical
        composerStack.alignment = .leading
        composerStack.spacing = HelmMetrics.s1 + 2
        composerStack.translatesAutoresizingMaskIntoConstraints = false
        composerWrap.addSubview(composerStack)

        buildTextView()
        buildToolbar()

        let cardStack = NSStackView(views: [textScroll, toolbarRow])
        cardStack.orientation = .vertical
        cardStack.alignment = .leading
        cardStack.spacing = 0
        cardStack.translatesAutoresizingMaskIntoConstraints = false
        composerCard.contentContainer.addSubview(cardStack)

        textScrollHeightConstraint = textScroll.heightAnchor.constraint(equalToConstant: Self.minTextHeight)

        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: composerWrap.topAnchor),

            composerWrap.leadingAnchor.constraint(equalTo: leadingAnchor),
            composerWrap.trailingAnchor.constraint(equalTo: trailingAnchor),
            composerWrap.bottomAnchor.constraint(equalTo: bottomAnchor),

            composerStack.leadingAnchor.constraint(equalTo: composerWrap.leadingAnchor, constant: HelmMetrics.s3),
            composerStack.trailingAnchor.constraint(equalTo: composerWrap.trailingAnchor, constant: -HelmMetrics.s3),
            composerStack.topAnchor.constraint(equalTo: composerWrap.topAnchor, constant: HelmMetrics.s2),
            composerStack.bottomAnchor.constraint(equalTo: composerWrap.bottomAnchor, constant: -HelmMetrics.s3),
            composerCard.widthAnchor.constraint(equalTo: composerStack.widthAnchor),

            cardStack.leadingAnchor.constraint(equalTo: composerCard.contentContainer.leadingAnchor),
            cardStack.trailingAnchor.constraint(equalTo: composerCard.contentContainer.trailingAnchor),
            cardStack.topAnchor.constraint(equalTo: composerCard.contentContainer.topAnchor),
            cardStack.bottomAnchor.constraint(equalTo: composerCard.contentContainer.bottomAnchor),
            textScroll.widthAnchor.constraint(equalTo: cardStack.widthAnchor),
            textScrollHeightConstraint,
            toolbarRow.widthAnchor.constraint(equalTo: cardStack.widthAnchor),
            toolbarRow.heightAnchor.constraint(equalToConstant: 36),

            // Activated here, once `textScroll` is already embedded in the
            // full tree, not inside `buildTextView()` where it's still an
            // orphaned view - see this method's own history for the real,
            // measured layout bug that ordering caused (a required
            // content-size constraint that never actually resolved to the
            // label's own intrinsic width). `ConsoleComposerViewController`'s
            // identical placeholder pattern already activates its
            // constraints at this same late point, for the same reason.
            textPlaceholderLabel.leadingAnchor.constraint(equalTo: textScroll.leadingAnchor, constant: 9),
            textPlaceholderLabel.topAnchor.constraint(equalTo: textScroll.topAnchor, constant: 9),
            textPlaceholderLabel.trailingAnchor.constraint(lessThanOrEqualTo: textScroll.trailingAnchor, constant: -9),
        ])
    }

    /// The auto-resizing multi-line text view - the reference mockup's
    /// `.sre-input`, translated: a plain `NSTextView` (no bezel/background of
    /// its own, since the shared card underneath already paints the fill) in
    /// an `NSScrollView` whose own height this view grows/shrinks by hand as
    /// content changes, clamped to `[minTextHeight, maxTextHeight]`.
    ///
    /// Plain Return still submits, matching this pane's pre-existing exact
    /// behaviour (`fm/grandline-input-composer-redesign` is a layout
    /// redesign, not a functional change) - Shift+Return inserts a newline
    /// instead, a purely additive capability a single-line field never had
    /// room to offer.
    private func buildTextView() {
        textView.isRichText = false
        textView.isEditable = true
        textView.isSelectable = true
        textView.font = HelmType.body()
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        // Transparent: the card's own `contentContainer` layer is what paints
        // the sunken fill, and letting the text view show it through (rather
        // than painting a second, identical fill on top) is what keeps the
        // text area and the toolbar below reading as one surface, not two.
        textView.drawsBackground = false
        textView.delegate = self

        textScroll.documentView = textView
        textScroll.hasVerticalScroller = true
        textScroll.borderType = .noBorder
        textScroll.drawsBackground = false
        textScroll.translatesAutoresizingMaskIntoConstraints = false

        textPlaceholderLabel.font = textView.font
        textPlaceholderLabel.isEditable = false
        textPlaceholderLabel.isBordered = false
        textPlaceholderLabel.isSelectable = false
        textPlaceholderLabel.drawsBackground = false
        textPlaceholderLabel.lineBreakMode = .byWordWrapping
        textPlaceholderLabel.maximumNumberOfLines = 1
        textPlaceholderLabel.translatesAutoresizingMaskIntoConstraints = false
        textScroll.addSubview(textPlaceholderLabel)
        // Constraints for this label are activated later, in
        // `buildComposer`'s own final activation block - see the doc comment
        // there for why.
    }

    /// The toolbar strip under the text view - just the send button today
    /// (see `buildComposer`'s doc comment for why there is nothing on the
    /// left), built as a real row rather than pinning the button straight to
    /// the card so a future real toolbar action has somewhere to go.
    private func buildToolbar() {
        toolbarRow.translatesAutoresizingMaskIntoConstraints = false

        sendButton.translatesAutoresizingMaskIntoConstraints = false
        sendButton.target = self
        sendButton.action = #selector(submit)
        sendButton.isEnabled = false
        toolbarRow.addSubview(sendButton)

        // The same alignment-rect-inset correction `HelmPageToolbar.
        // iconButton` uses: a `HelmButton`'s frame is taller than its own
        // height constraint by `alignmentRectInsets`, so subtracting them is
        // what makes the button actually measure `side`pt square instead of
        // a few points taller.
        let side: CGFloat = 28
        let insets = sendButton.alignmentRectInsets
        NSLayoutConstraint.activate([
            sendButton.trailingAnchor.constraint(equalTo: toolbarRow.trailingAnchor, constant: -HelmMetrics.s2),
            sendButton.centerYAnchor.constraint(equalTo: toolbarRow.centerYAnchor),
            sendButton.widthAnchor.constraint(equalToConstant: side - insets.left - insets.right),
            sendButton.heightAnchor.constraint(equalToConstant: side - insets.top - insets.bottom),
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
        isInputEnabled = enabled
        textView.isEditable = enabled
        updateSendButtonEnabled()
    }

    /// The send button is enabled only while input is allowed at all
    /// (`isInputEnabled`) *and* there is real, non-whitespace text to send -
    /// the reference mockup's "muted until there's something to send" state,
    /// which `HelmButton(.primary)`'s own `isEnabled` dimming already renders
    /// correctly with no extra styling needed here.
    private func updateSendButtonEnabled() {
        let hasText = !textView.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        sendButton.isEnabled = isInputEnabled && hasText
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

    /// One accent card in this pane - a question, an error, a Finding or a
    /// Recommended next action - built from the app's shared `HelmAccentRow`
    /// (`HelmDesignSystem.swift`, audit §6.3 component 2).
    ///
    /// This pane used to hand-roll its own version of that card and was the
    /// audit's named outlier (§3.2, §4.3): a tint-washed panel with **no
    /// border**, whose section label was coloured from the tint hue rather
    /// than `mutedInk`. The visible consequence was that an SRE Lead
    /// "Finding" and a Notification "PR Ready" - both meaning *here is a
    /// coloured, kickered finding* - did not read as the same kind of object.
    /// They now are the same object: same bar, same badge, same kicker
    /// typography and colour, same card fill and tinted border.
    ///
    /// `hover: false` because these cards are transcript content, not
    /// controls - a hover highlight on something that does nothing is a lie.
    /// The card is nested inside `assistantBlock`'s own container, which
    /// shares its fill; the tinted border and the accent bar are what
    /// separate them, exactly as a notification row separates from the
    /// notification panel behind it (both `chromeBackgroundHex`).
    private func accentRow(kicker: String, tint: HelmTint, badgeSymbol: String, content: NSView) -> NSView {
        let row = HelmAccentRow(contentView: content, hover: false)
        row.configure(HelmAccentRow.Content(tint: tint, kicker: kicker, badgeSymbol: badgeSymbol),
                      theme: theme)
        return row
    }

    private func userBlock(for text: String) -> NSView {
        let body = NSTextField(wrappingLabelWithString: text)
        body.font = .systemFont(ofSize: 12.5, weight: .medium)
        body.textColor = HelmTheme.nsColor(theme.chromeInkHex)
        body.isSelectable = true
        body.lineBreakMode = .byWordWrapping
        body.translatesAutoresizingMaskIntoConstraints = false
        return accentRow(kicker: "You", tint: .accent, badgeSymbol: "person.fill", content: body)
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
        let body = NSTextField(wrappingLabelWithString: text)
        body.font = .systemFont(ofSize: 12.5)
        body.textColor = HelmTheme.nsColor(theme.chromeInkHex)
        body.isSelectable = true
        body.lineBreakMode = .byWordWrapping
        body.translatesAutoresizingMaskIntoConstraints = false
        return accentRow(kicker: "Error", tint: .critical,
                         badgeSymbol: "exclamationmark.triangle.fill", content: body)
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
        let symbol = kind == .finding ? "magnifyingglass" : "arrow.right.circle.fill"
        return accentRow(kicker: kind.label, tint: tint, badgeSymbol: symbol,
                         content: wrappingLabel(attributedInline(runs)))
    }

    @objc private func submit() {
        let text = textView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        textView.string = ""
        updateTextPlaceholderVisibility()
        updateTextViewHeight()
        updateSendButtonEnabled()
        onSubmit?(text)
    }

    // MARK: Text view delegate

    func textDidChange(_ notification: Notification) {
        updateTextPlaceholderVisibility()
        updateTextViewHeight()
        updateSendButtonEnabled()
    }

    func textDidBeginEditing(_ notification: Notification) {
        composerCard.setFocused(true)
    }

    func textDidEndEditing(_ notification: Notification) {
        composerCard.setFocused(false)
    }

    /// Plain Return still submits - this pane's pre-existing exact behaviour
    /// (see `buildTextView`'s doc comment). Shift+Return inserts a newline
    /// instead, the one additive capability a genuinely multi-line field can
    /// offer that a single-line one never could.
    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard commandSelector == #selector(NSResponder.insertNewline(_:)) else { return false }
        if NSApp.currentEvent?.modifierFlags.contains(.shift) == true {
            textView.insertText("\n", replacementRange: textView.selectedRange())
            return true
        }
        submit()
        return true
    }

    private func updateTextPlaceholderVisibility() {
        textPlaceholderLabel.isHidden = !textView.string.isEmpty
    }

    /// Grows or shrinks `textScrollHeightConstraint` to fit the text view's
    /// real content, clamped to `[minTextHeight, maxTextHeight]` - the
    /// reference mockup's `autoResize` JS helper, done as an Auto Layout
    /// constraint update instead of a raw frame write.
    private func updateTextViewHeight() {
        guard let layoutManager = textView.layoutManager, let textContainer = textView.textContainer else { return }
        layoutManager.ensureLayout(for: textContainer)
        let used = layoutManager.usedRect(for: textContainer).height
        let desired = ceil(used) + textView.textContainerInset.height * 2
        let clamped = min(max(desired, Self.minTextHeight), Self.maxTextHeight)
        guard abs(clamped - textScrollHeightConstraint.constant) > 0.5 else { return }
        textScrollHeightConstraint.constant = clamped
    }

    // MARK: Theming

    func applyTheme(_ theme: HelmTheme) {
        self.theme = theme
        // **`chromeBackgroundHex`, not `backgroundHex`.** `backgroundHex` is
        // the *terminal's* own token; `chromeBackgroundHex` is this app's
        // surface. `fm/grandline-sre-lead-polish` moved `sreLeadPane` and
        // `sreLeadEmptyStateView` onto the surface token precisely so the pane
        // stops reading as a continuation of the terminal beside it - and
        // missed this view, which is what actually fills the pane once a tab
        // has a chat. The consequence, reported live: a started-but-unasked
        // pane rendered as "a large black empty area" between the readiness
        // status line and the input row, indistinguishable from the terminal.
        //
        // Note this token pair is *identical* in `gruvbox-light`,
        // `tokyo-night-dark` and `tokyo-night-light`, so those three never
        // showed the bug and no fill change can be what proves the fix -
        // measure the resolved colour against the pane's, per theme.
        layer?.backgroundColor = HelmTheme.nsColor(theme.chromeBackgroundHex).cgColor
        composerKicker.textColor = HelmTheme.mutedInk(theme)
        composerCard.applyTheme(theme)
        let ink = HelmField.ink(theme)
        textView.textColor = ink
        textView.insertionPointColor = ink
        textPlaceholderLabel.textColor = HelmField.mutedInk(theme)
        // `HelmButton` themes its own fill/border/label - nothing else to set
        // here beyond what `buildToolbar`/`setInputEnabled` already own.

        // Rebuild every block rather than trying to re-derive each one's
        // role from its current styling - `messages` is the source of truth
        // for what each block should look like, styling is a pure function
        // of it.
        let saved = messages
        clearMessages()
        for message in saved { append(message) }
    }
}
