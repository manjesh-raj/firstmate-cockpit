// Manjesh Grand Line - native macOS app.
//
// `fm/cockpit-block-view-terminal`: the native, parsed rendering mode -
// SwiftTerm's grid rendering (raw scrollback) stays completely untouched;
// this is a second NSView sibling that renders `TerminalBlockTracker.blocks`
// as a scrollable list of collapsible rows, following this codebase's own
// `SRELeadChatView.swift` precedent ("build a real native message feed
// rather than reusing SwiftTerm's grid rendering for that pane") and reusing
// `HelmUIComponents.swift`'s `IconTileView`/`HoverHighlightView` the way
// every other modern-UI page already does.
//
// `fm/cockpit-block-view-error-explain` added the "Explain this \u{2726}"
// action on a failed block (see `BlockExplain.swift`) and its response
// panel, rendered via `SRELeadMarkdownView` - the same renderer the SRE Lead
// pane uses, not a second styling. This is explicitly not SRE Lead: one
// captain-triggered `claude -p` call, no tool access, no session.

import AppKit

/// One block's row: a header (status icon, command text, exit-code pill,
/// disclosure chevron), a collapsible monospace output body, and - only for
/// a failed block - an "Explain this" action and its (also collapsible)
/// response panel. Expanded by default - a Warp-style block view is most
/// useful when output is visible without an extra click, and collapsing is
/// the exception, not the rule.
final class BlockRowView: NSView {
    private let container = HoverHighlightView()
    private let contentStack = NSStackView()
    private let iconTile = IconTileView(size: 26, cornerRadius: 7)
    private let commandLabel = NSTextField(labelWithString: "")
    private let exitPill = NSTextField(labelWithString: "")
    private let chevron = NSButton(image: NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil) ?? NSImage(), target: nil, action: nil)
    private let header = NSStackView()
    private let outputWrapper: NSView
    private let outputLabel = NSTextField(wrappingLabelWithString: "")

    /// Indented to line up under `outputLabel`, not under the header's icon
    /// column - see `indentWrapper(_:)`. Hidden whenever there's nothing to
    /// show for it (block succeeded, or an explanation is already showing).
    private let explainButtonWrapper: NSView
    private let explainButton = NSButton(title: "", target: nil, action: nil)

    /// Hidden unless `explainState` is anything but `.idle`. Its content
    /// (spinner, rendered markdown, or an error line) is rebuilt fresh on
    /// every `configure` call - cheap, and matches this file's own
    /// "small enough, just redraw it" convention.
    private let explainPanelWrapper: NSView
    private let explainPanelContent = NSStackView()

    private var isExpanded = true
    var onToggle: (() -> Void)?
    var onExplain: (() -> Void)?

    override init(frame frameRect: NSRect) {
        outputWrapper = Self.indentWrapper(outputLabel, indent: 30)
        explainButtonWrapper = Self.indentWrapper(explainButton, indent: 30)
        explainPanelWrapper = Self.indentWrapper(explainPanelContent, indent: 30)
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        build()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    /// Wraps `inner` in a plain view with `indent` extra leading padding, so
    /// content that sits below the header's icon column (output, the
    /// explain action, its response panel) lines up under the command text
    /// rather than under the icon.
    private static func indentWrapper(_ inner: NSView, indent: CGFloat) -> NSView {
        let wrapper = NSView()
        wrapper.translatesAutoresizingMaskIntoConstraints = false
        inner.translatesAutoresizingMaskIntoConstraints = false
        wrapper.addSubview(inner)
        NSLayoutConstraint.activate([
            inner.leadingAnchor.constraint(equalTo: wrapper.leadingAnchor, constant: indent),
            inner.trailingAnchor.constraint(equalTo: wrapper.trailingAnchor),
            inner.topAnchor.constraint(equalTo: wrapper.topAnchor),
            inner.bottomAnchor.constraint(equalTo: wrapper.bottomAnchor),
        ])
        return wrapper
    }

    private func build() {
        container.translatesAutoresizingMaskIntoConstraints = false
        container.cornerRadius = 8
        addSubview(container)

        iconTile.configure(symbol: "circle.dotted", tint: .neutral)
        commandLabel.font = .monospacedSystemFont(ofSize: 12, weight: .medium)
        commandLabel.lineBreakMode = .byTruncatingTail
        commandLabel.isSelectable = true
        commandLabel.translatesAutoresizingMaskIntoConstraints = false
        commandLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        commandLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

        exitPill.font = .monospacedSystemFont(ofSize: 10, weight: .semibold)
        exitPill.translatesAutoresizingMaskIntoConstraints = false
        exitPill.setContentCompressionResistancePriority(.required, for: .horizontal)
        exitPill.setContentHuggingPriority(.required, for: .horizontal)
        exitPill.wantsLayer = true
        exitPill.layer?.cornerRadius = 4
        exitPill.alignment = .center

        chevron.isBordered = false
        chevron.target = self
        chevron.action = #selector(chevronClicked)
        chevron.setContentHuggingPriority(.required, for: .horizontal)
        chevron.setContentCompressionResistancePriority(.required, for: .horizontal)
        chevron.translatesAutoresizingMaskIntoConstraints = false

        header.addArrangedSubview(iconTile)
        header.addArrangedSubview(commandLabel)
        header.addArrangedSubview(exitPill)
        header.addArrangedSubview(chevron)
        header.orientation = .horizontal
        header.spacing = 8
        header.alignment = .centerY
        header.distribution = .fill
        header.translatesAutoresizingMaskIntoConstraints = false

        outputLabel.font = .monospacedSystemFont(ofSize: 11.5, weight: .regular)
        outputLabel.isSelectable = true
        outputLabel.isEditable = false
        outputLabel.drawsBackground = false
        outputLabel.isBordered = false
        outputLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        explainButton.isBordered = false
        explainButton.font = .systemFont(ofSize: 11, weight: .semibold)
        explainButton.title = "Explain this \u{2726}"
        explainButton.target = self
        explainButton.action = #selector(explainClicked)
        explainButton.setContentHuggingPriority(.required, for: .horizontal)
        explainButton.setContentCompressionResistancePriority(.required, for: .horizontal)

        explainPanelContent.orientation = .vertical
        explainPanelContent.alignment = .leading
        explainPanelContent.spacing = 6
        explainPanelContent.translatesAutoresizingMaskIntoConstraints = false

        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = 6
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(contentStack)

        for view in [header as NSView, outputWrapper, explainButtonWrapper, explainPanelWrapper] {
            contentStack.addArrangedSubview(view)
            view.widthAnchor.constraint(equalTo: contentStack.widthAnchor).isActive = true
        }

        NSLayoutConstraint.activate([
            container.leadingAnchor.constraint(equalTo: leadingAnchor),
            container.trailingAnchor.constraint(equalTo: trailingAnchor),
            container.topAnchor.constraint(equalTo: topAnchor),
            container.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),

            contentStack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 10),
            contentStack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -10),
            contentStack.topAnchor.constraint(equalTo: container.topAnchor, constant: 8),
            contentStack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -8),
        ])
    }

    @objc private func chevronClicked() {
        isExpanded.toggle()
        applyExpandedState()
        onToggle?()
    }

    @objc private func explainClicked() {
        onExplain?()
    }

    private func applyExpandedState() {
        outputWrapper.isHidden = !isExpanded
        chevron.image = NSImage(
            systemSymbolName: isExpanded ? "chevron.down" : "chevron.right",
            accessibilityDescription: nil
        )
    }

    /// `explainState` is non-nil exactly when this block is eligible for the
    /// explain action - i.e. `.finished(exitCode != 0)` - and nil for a
    /// running or successful block, which hides both the button and the
    /// panel entirely.
    func configure(with block: TerminalBlock, theme: HelmTheme, explainState: BlockExplainState?) {
        let commandText = block.commandText.isEmpty ? "…" : block.commandText
        commandLabel.stringValue = commandText
        outputLabel.stringValue = block.outputText

        switch block.status {
        case .running:
            iconTile.configure(symbol: "circle.dotted", tint: .info)
            exitPill.isHidden = true
        case .finished(let exitCode):
            let ok = exitCode == 0
            iconTile.configure(symbol: ok ? "checkmark" : "xmark", tint: ok ? .good : .critical)
            exitPill.isHidden = false
            exitPill.stringValue = " exit \(exitCode) "
        }
        applyExpandedState()
        applyExplainState(explainState, theme: theme)
        applyTheme(theme, status: block.status)
    }

    private func applyExplainState(_ state: BlockExplainState?, theme: HelmTheme) {
        guard let state else {
            explainButtonWrapper.isHidden = true
            explainPanelWrapper.isHidden = true
            return
        }

        explainPanelContent.arrangedSubviews.forEach { $0.removeFromSuperview() }

        switch state {
        case .idle:
            explainButtonWrapper.isHidden = false
            explainPanelWrapper.isHidden = true
        case .loading:
            explainButtonWrapper.isHidden = true
            explainPanelWrapper.isHidden = false
            let label = NSTextField(labelWithString: "Asking claude\u{2026}")
            label.font = .systemFont(ofSize: 11.5)
            label.textColor = HelmTheme.mutedInk(theme)
            explainPanelContent.addArrangedSubview(label)
        case .result(let text):
            explainButtonWrapper.isHidden = true
            explainPanelWrapper.isHidden = false
            let markdownView = SRELeadMarkdownView(text: text, theme: theme)
            explainPanelContent.addArrangedSubview(markdownView)
            markdownView.widthAnchor.constraint(equalTo: explainPanelContent.widthAnchor).isActive = true
        case .failed(let message):
            explainButtonWrapper.isHidden = false
            explainButton.title = "Retry explanation \u{2726}"
            explainPanelWrapper.isHidden = false
            let label = NSTextField(wrappingLabelWithString: "Could not get an explanation: \(message)")
            label.font = .systemFont(ofSize: 11.5)
            label.textColor = HelmTheme.nsColor(theme.ansiHex[1])
            label.isSelectable = true
            explainPanelContent.addArrangedSubview(label)
            label.widthAnchor.constraint(equalTo: explainPanelContent.widthAnchor).isActive = true
        }
        if case .failed = state {} else {
            explainButton.title = "Explain this \u{2726}"
        }
    }

    private func applyTheme(_ theme: HelmTheme, status: TerminalBlock.Status) {
        let ink = HelmTheme.nsColor(theme.chromeInkHex)
        commandLabel.textColor = ink
        outputLabel.textColor = HelmTheme.mutedInk(theme)
        explainButton.contentTintColor = HelmTheme.nsColor(theme.accentHex)
        let bg = HelmTheme.nsColor(theme.chromeBackgroundHex)
        container.normalColor = bg
        container.hoverColor = bg.hoverShifted(by: 0.06, forMode: theme.mode)

        switch status {
        case .running:
            exitPill.textColor = HelmTheme.nsColor(HelmTint.info.hex(in: theme))
        case .finished(let exitCode):
            let tint: HelmTint = exitCode == 0 ? .good : .critical
            let color = HelmTheme.nsColor(tint.hex(in: theme))
            exitPill.textColor = color
            exitPill.layer?.backgroundColor = color.withAlphaComponent(0.16).cgColor
        }
    }
}

/// The scrollable block list for one tab - a sibling of that tab's raw
/// `CockpitTerminalView`, pinned to the same anchors inside `content`, shown
/// or hidden by `ConsoleController.applyBlockViewVisibility` without ever
/// touching the underlying process. Rebuilds its rows wholesale on every
/// `TerminalBlockTracker.onChange` - the same "small enough list, just redraw
/// it" convention `BootstrapController`'s dynamic sections already use.
final class BlockContainerView: NSView {
    private let scroll = NSScrollView()
    private let stack = NSStackView()
    private let emptyLabel = NSTextField(labelWithString: "No commands run yet in this tab.")
    private var theme: HelmTheme = ThemeManager.shared.theme
    private var lastBlocks: [TerminalBlock] = []

    /// One entry per block that has ever had "Explain this" clicked (or is
    /// eligible to) - keyed by `TerminalBlock.id`, not persisted anywhere and
    /// not tied to any process lifecycle beyond the one in-flight `claude -p`
    /// call a `.loading` entry represents. Lives here, not on `BlockRowView`,
    /// because `render(_:)` recreates every row from scratch on every change
    /// (a still-`running` block's output growing, a new block appearing) -
    /// the same reason `BootstrapController`'s `SoftwareRowState` persists
    /// its log/expanded state on the model instead of the view.
    private var explainStates: [UUID: BlockExplainState] = [:]
    private var explainProcesses: [UUID: Process] = [:]

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        build()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    private func build() {
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        addSubview(scroll)

        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false

        stack.orientation = .vertical
        stack.spacing = 4
        stack.alignment = .leading
        stack.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)

        emptyLabel.font = .systemFont(ofSize: 12)
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(emptyLabel)

        scroll.documentView = document
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),

            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),

            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: document.topAnchor, constant: 10),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: document.bottomAnchor, constant: -10),

            emptyLabel.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 12),
            emptyLabel.topAnchor.constraint(equalTo: document.topAnchor, constant: 10),
        ])
    }

    func render(_ blocks: [TerminalBlock]) {
        lastBlocks = blocks
        for v in stack.arrangedSubviews {
            stack.removeArrangedSubview(v)
            v.removeFromSuperview()
        }
        emptyLabel.isHidden = !blocks.isEmpty
        for block in blocks {
            let row = BlockRowView(frame: .zero)
            row.configure(with: block, theme: theme, explainState: explainState(for: block))
            row.onExplain = { [weak self] in self?.requestExplanation(for: block) }
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            stack.addArrangedSubview(row)
        }
    }

    /// `nil` (no button, no panel) unless the block is genuinely failed -
    /// see `BlockRowView.configure`'s doc comment.
    private func explainState(for block: TerminalBlock) -> BlockExplainState? {
        guard BlockExplain.isEligible(block.status) else { return nil }
        return explainStates[block.id] ?? .idle
    }

    /// Fires the one-shot `claude -p` call for a block's "Explain this"
    /// action (or its retry) - never automatic, only ever reached via
    /// `BlockRowView.onExplain`, itself only wired to a real button click.
    private func requestExplanation(for block: TerminalBlock) {
        guard explainProcesses[block.id] == nil, case .finished(let exitCode) = block.status else { return }
        let id = block.id
        explainStates[id] = .loading
        render(lastBlocks)

        let proc = BlockExplain.explain(
            commandText: block.commandText,
            outputText: block.outputText,
            exitCode: exitCode
        ) { [weak self] result in
            guard let self else { return }
            self.explainProcesses[id] = nil
            switch result {
            case .success(let text):
                self.explainStates[id] = .result(text)
            case .failure(let error):
                self.explainStates[id] = .failed(error.message)
            }
            self.render(self.lastBlocks)
        }
        explainProcesses[id] = proc
    }

    /// Called alongside `TerminalBlockTracker.reset()` on reconnect - a fresh
    /// process means a fresh block history with no relationship to whatever
    /// explanations were requested against the old one.
    func resetExplanations() {
        explainProcesses.values.forEach { $0.terminate() }
        explainProcesses.removeAll()
        explainStates.removeAll()
    }

    func applyTheme(_ theme: HelmTheme) {
        self.theme = theme
        layer?.backgroundColor = HelmTheme.nsColor(theme.backgroundHex).cgColor
        emptyLabel.textColor = HelmTheme.mutedInk(theme)
        render(lastBlocks)
    }
}
