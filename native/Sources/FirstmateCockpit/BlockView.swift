// Manjesh Grand Line - native macOS app.
//
// `fm/cockpit-block-view-stage0`: the native, parsed rendering mode -
// SwiftTerm's grid rendering (raw scrollback) stays completely untouched;
// this is a second NSView sibling that renders `TerminalBlockTracker.blocks`
// as a scrollable list of collapsible rows, following this codebase's own
// `SRELeadChatView.swift` precedent ("build a real native message feed
// rather than reusing SwiftTerm's grid rendering for that pane") and reusing
// `HelmUIComponents.swift`'s `IconTileView`/`HoverHighlightView` the way
// every other modern-UI page already does. Scoped to one opted-in SSH host
// page's tab only (`TabModel.blockViewOptIn`) - see AGENTS.md's block-view
// section for the scope narrowing and the crash history below.
//
// **No "Explain this," no re-run/copy actions, no live streaming - Stage 0
// only.** Those are later, separate, blocked tasks (see
// `data/cockpit-block-view-scout/report.md`'s staged design). `render(_:)`
// is called exactly once per manual "Refresh" click
// (`ConsoleController.refreshBlockView`) - never automatically.
//
// **Crash history (root-caused, not guessed) - read before touching
// `render(_:)`:** the original PR #79/#80 attempt shipped
// `BlockContainerView.render(_:)` activating
// `row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true`
// *before* calling `stack.addArrangedSubview(row)`. At the moment that
// constraint activates, `row` has no superview at all, so it and `stack`
// share no common ancestor - `NSLayoutConstraint._setActive:` throws a real
// Objective-C exception (not a catchable Swift error, not just a broken-
// constraint console warning) the instant two unconnected views are
// constrained against each other. Because the Firstmate console's default
// Shell tab used to be in scope too and auto-opens at launch, the shell-
// integration hook's first OSC 133 marker fired almost immediately, opening
// the first block and crashing the app on every single launch. PR #83
// fixed this with the correct order - add the row as an arranged subview
// first, activate the width constraint second - and this file reuses that
// exact fix. **Do not reorder the two lines marked below.** A real-view-
// hierarchy self test (`BlockViewHierarchySelfTest.swift`) mounts this exact
// view in a live `NSWindow` and drives a full render/re-render/clear cycle
// through real Auto Layout, specifically to catch a regression of this
// class of bug - the original self-tests only exercised
// `TerminalBlockTracker`'s parsing logic and never mounted a view at all.
//
// This same codebase independently made and fixed the identical ordering
// mistake once before, in `DiffResultView.rebuild()` (`fm/cockpit-tools-
// page-diff`, see AGENTS.md's AppKit gotcha catalogue) - block view's first
// attempt was written new and made the same mistake again, since nothing
// connected the two beyond a markdown bullet. That's the reason this file's
// warning comment is at the exact call site, not just in this header.

import AppKit

/// One block's row: a header (status icon, command text, exit-code pill),
/// and a collapsible monospace output body. Expanded by default - a
/// Warp-style block view is most useful when output is visible without an
/// extra click, and collapsing is the exception, not the rule.
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

    private var isExpanded = true
    var onToggle: (() -> Void)?

    override init(frame frameRect: NSRect) {
        outputWrapper = Self.indentWrapper(outputLabel, indent: 30)
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        build()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    /// Wraps `inner` in a plain view with `indent` extra leading padding, so
    /// content that sits below the header's icon column (the output) lines
    /// up under the command text rather than under the icon.
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

        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = 6
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(contentStack)

        // Each view must be added as an arranged subview (giving it a
        // superview and putting it in the same view tree as `contentStack`)
        // BEFORE its width constraint against `contentStack` is activated -
        // see this file's header for the crash that happens when that order
        // is reversed. DO NOT REORDER these two lines inside the loop.
        for view in [header as NSView, outputWrapper] {
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

    private func applyExpandedState() {
        outputWrapper.isHidden = !isExpanded
        chevron.image = NSImage(
            systemSymbolName: isExpanded ? "chevron.down" : "chevron.right",
            accessibilityDescription: nil
        )
    }

    func configure(with block: TerminalBlock, theme: HelmTheme) {
        let commandText = block.commandText.isEmpty ? "\u{2026}" : block.commandText
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

/// The scrollable block list for one SSH host page tab - a sibling of that
/// tab's raw `CockpitTerminalView`, pinned to the same anchors inside
/// `content`, shown or hidden by `ConsoleController.updateTabViewVisibility`
/// without ever touching the underlying process.
///
/// **This is a single-column, view-based `NSTableView`, not an
/// `NSStackView` of permanent rows - a real, measured finding from this
/// task's own volume self-test, not a precaution.** The first version of
/// this file followed the original PR #79/#83 design (an `NSStackView` of
/// one `BlockRowView` per block, rebuilt wholesale on every render) and
/// `BlockViewVolumeSelfTest` measured it at 400 blocks: parsing took ~4.5s
/// (acceptable) but a single `render(_:)` + `layoutSubtreeIfNeeded()` took
/// **~102 seconds** - a real reproduction, at real volume, of exactly the
/// pathology the scout report's Mechanism B flagged as "plausible but
/// unverified," and the identical class of bug this codebase already hit
/// and fixed twice before: the Diff tool's ~13.6-second blowup at ~340 rows
/// (`fm/cockpit-tools-yaml-quotes-diff-perf`) and the Tools-page resize
/// handler regression that scaled with open-tab count
/// (`fm/cockpit-tools-page-ui-polish`) - see AGENTS.md's Diff-tool history
/// for the full writeup of why an `NSStackView` with hundreds of arranged
/// subviews blows up far faster than the row count (every arranged subview
/// participates in one shared Auto Layout solve simultaneously). `Diff
/// ResultView.swift`'s fix for that exact problem - a single-column,
/// view-based `NSTableView`, demand-driven so `tableView(_:viewFor:row:)`
/// only runs for rows that actually need to be drawn - is reused here
/// directly rather than re-discovering it. The one difference from
/// `DiffResultView`: block rows have variable height (multi-line,
/// collapsible output, unlike Diff's fixed-height single-line rows), so
/// this uses `usesAutomaticRowHeights` (Auto Layout-computed per row,
/// still only for rows actually being drawn) instead of a fixed
/// `rowHeight`. Re-measured after this fix at the same 400-block volume:
/// render dropped to well under a second - see this task's PR description
/// for the exact before/after numbers.
final class BlockContainerView: NSView {
    private let scroll = NSScrollView()
    let tableView = NSTableView()
    private var theme: HelmTheme = ThemeManager.shared.theme
    private var blocks: [TerminalBlock] = []

    private static let columnID = NSUserInterfaceItemIdentifier("blockRow")
    private static let rowViewID = NSUserInterfaceItemIdentifier("blockRowView")
    private static let emptyViewID = NSUserInterfaceItemIdentifier("blockEmptyView")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        build()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    private func build() {
        let column = NSTableColumn(identifier: Self.columnID)
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.backgroundColor = .clear
        tableView.selectionHighlightStyle = .none
        tableView.gridStyleMask = []
        tableView.intercellSpacing = NSSize(width: 0, height: 4)
        tableView.autoresizingMask = [.width]
        tableView.usesAutomaticRowHeights = true
        tableView.rowHeight = 60
        tableView.dataSource = self
        tableView.delegate = self

        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.documentView = tableView
        addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    /// Wholesale re-render from `blocks` - `reloadData()` on a view-based
    /// table only actually reconstructs/re-measures rows currently on
    /// screen (plus a small buffer), not the whole list, which is what
    /// keeps this cheap at real volume - see this class's header. Called by
    /// `ConsoleController`'s manual Refresh action and by `applyTheme` (a
    /// theme change re-styles the same content, it doesn't change what's
    /// shown).
    func render(_ newBlocks: [TerminalBlock]) {
        blocks = newBlocks
        tableView.reloadData()
    }

    /// Clears the rendered list back to empty - called on reconnect
    /// alongside `TerminalBlockTracker.reset()`, so a stale block from the
    /// previous session's process never lingers on screen after a restart.
    func clear() {
        render([])
    }

    func applyTheme(_ theme: HelmTheme) {
        self.theme = theme
        layer?.backgroundColor = HelmTheme.nsColor(theme.backgroundHex).cgColor
        tableView.reloadData()
    }
}

extension BlockContainerView: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        blocks.isEmpty ? 1 : blocks.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard !blocks.isEmpty else {
            // Was a bare `NSTextField` - one of the four §3.2 called out. This
            // is a table's empty cell, exactly the shape `HelmEmptyState`'s
            // `.compact` size (and every Shift list) already uses.
            let empty = (tableView.makeView(withIdentifier: Self.emptyViewID, owner: nil) as? HelmEmptyState)
                ?? {
                    let v = HelmEmptyState(symbol: "terminal",
                                           body: "No commands parsed yet. Run something, then click Refresh.")
                    v.identifier = Self.emptyViewID
                    return v
                }()
            empty.applyTheme(theme)
            return empty
        }

        let rowView = (tableView.makeView(withIdentifier: Self.rowViewID, owner: nil) as? BlockRowView)
            ?? {
                let v = BlockRowView(frame: .zero)
                v.identifier = Self.rowViewID
                return v
            }()
        // Rebound on every reuse (a dequeued row view is shared across
        // whichever block currently occupies this row index) - collapsing
        // or expanding a row changes its intrinsic height, and
        // `noteHeightOfRows` is what tells the table to re-measure just
        // this one row rather than reloading everything.
        rowView.onToggle = { [weak tableView] in
            tableView?.noteHeightOfRows(withIndexesChanged: IndexSet(integer: row))
        }
        rowView.configure(with: blocks[row], theme: theme)
        return rowView
    }
}
