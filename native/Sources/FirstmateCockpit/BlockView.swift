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

import AppKit

/// One block's row: a header (status icon, command text, exit-code pill,
/// disclosure chevron) and a collapsible monospace output body. Expanded by
/// default - a Warp-style block view is most useful when output is visible
/// without an extra click, and collapsing is the exception, not the rule.
final class BlockRowView: NSView {
    private let container = HoverHighlightView()
    private let iconTile = IconTileView(size: 26, cornerRadius: 7)
    private let commandLabel = NSTextField(labelWithString: "")
    private let exitPill = NSTextField(labelWithString: "")
    private let chevron = NSButton(image: NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil) ?? NSImage(), target: nil, action: nil)
    private let outputLabel = NSTextField(wrappingLabelWithString: "")
    private var outputTopConstraint: NSLayoutConstraint!

    private var isExpanded = true
    var onToggle: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        build()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

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

        let header = NSStackView(views: [iconTile, commandLabel, exitPill, chevron])
        header.orientation = .horizontal
        header.spacing = 8
        header.alignment = .centerY
        header.distribution = .fill
        header.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(header)

        outputLabel.font = .monospacedSystemFont(ofSize: 11.5, weight: .regular)
        outputLabel.isSelectable = true
        outputLabel.isEditable = false
        outputLabel.drawsBackground = false
        outputLabel.isBordered = false
        outputLabel.translatesAutoresizingMaskIntoConstraints = false
        outputLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        container.addSubview(outputLabel)

        NSLayoutConstraint.activate([
            container.leadingAnchor.constraint(equalTo: leadingAnchor),
            container.trailingAnchor.constraint(equalTo: trailingAnchor),
            container.topAnchor.constraint(equalTo: topAnchor),
            container.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),

            header.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 10),
            header.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -10),
            header.topAnchor.constraint(equalTo: container.topAnchor, constant: 8),

            outputLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 40),
            outputLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -10),
            outputLabel.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor, constant: -8),
        ])
        outputTopConstraint = outputLabel.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 6)
        outputTopConstraint.isActive = true
    }

    @objc private func chevronClicked() {
        isExpanded.toggle()
        applyExpandedState()
        onToggle?()
    }

    private func applyExpandedState() {
        outputLabel.isHidden = !isExpanded
        chevron.image = NSImage(
            systemSymbolName: isExpanded ? "chevron.down" : "chevron.right",
            accessibilityDescription: nil
        )
    }

    func configure(with block: TerminalBlock, theme: HelmTheme) {
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
        applyTheme(theme, status: block.status)
    }

    private func applyTheme(_ theme: HelmTheme, status: TerminalBlock.Status) {
        let ink = HelmTheme.nsColor(theme.chromeInkHex)
        commandLabel.textColor = ink
        outputLabel.textColor = HelmTheme.mutedInk(theme)
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
            row.configure(with: block, theme: theme)
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            stack.addArrangedSubview(row)
        }
    }

    func applyTheme(_ theme: HelmTheme) {
        self.theme = theme
        layer?.backgroundColor = HelmTheme.nsColor(theme.backgroundHex).cgColor
        emptyLabel.textColor = HelmTheme.mutedInk(theme)
        render(lastBlocks)
    }
}
