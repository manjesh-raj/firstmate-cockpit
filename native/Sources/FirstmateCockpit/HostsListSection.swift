// Manjesh Grand Line - native macOS app.
//
// The one list body behind all three tabs of the Hosts destination
// (`HostsController.swift`): a `HelmCard` whose body is a demand-driven
// `NSTableView` of `HelmAccentRow` cards, with group headers and a
// `HelmEmptyState` rendered as rows of the same table.
//
// **Why this is one class and not three.** The full-app UI audit (§4.5) found
// `KeysSidebarController` and `SnippetsController` were "near-identical twins"
// - the same `footerButton` helper, the same table setup, the same title +
// caption treatment, the same `selectedX` / `clickedX` / `updateButtons`
// plumbing - and that `HostsSidebarController` was a third copy of most of it.
// Phase 5 folded all three into one destination, so the list itself is now one
// implementation fed a `[Item]` array. A tab that wants a different list says
// so in the items it builds, not in a fourth copy of the table code.
//
// **An `NSTableView`, never an `NSStackView` of permanent rows** - see
// `DiffResultView.swift`'s header for the ~13-second layout pass that pattern
// produced once a list grew, and `ShiftListViews.swift` for the same call made
// for the same reason.
//
// **Selection.** The table is `.fullWidth` + `selectionHighlightStyle = .none`,
// so AppKit's private `NSTableRowSidebarSelectionView` - the system-accent-blue
// source-list material audit §5.2 measured - is never installed at all. The
// selected row is painted by `HelmAccentRow.isRowSelected`, on the card, from
// the theme's own accent. The card is opaque, so a wash painted *behind* it by
// an `NSTableRowView` (Phase 0's fix, correct for the flat rows it was written
// for) would simply be invisible now.

import AppKit

final class HostsListSection: NSObject, NSTableViewDataSource, NSTableViewDelegate {

    /// One button (or menu item) offered by a row.
    struct Action {
        let title: String
        let symbol: String?
        let run: () -> Void

        init(title: String, symbol: String? = nil, run: @escaping () -> Void) {
            self.title = title
            self.symbol = symbol
            self.run = run
        }
    }

    /// One row. `record` rows are `HelmAccentRow` cards; the other two kinds
    /// are the list's own furniture, rendered as rows of the same table so
    /// they scroll with it and need no second container.
    struct Item {
        enum Kind {
            case record
            case group(String)
            case empty(symbol: String, title: String, body: String)
        }

        var kind: Kind = .record
        var content: HelmAccentRow.Content
        /// The row's own headline action - "Connect", "Edit", "Run". Rendered
        /// as a button in the row, which is what replaced the three-button
        /// `.fillEqually` footer strip the three lists used to share.
        var primary: Action?
        /// Everything else the row can do, behind its `⋯` button and its
        /// right-click menu (the same items in both, so neither is a
        /// second, drifting definition of what a row offers).
        var overflow: [Action] = []
        /// Double-click. Preserves each list's existing double-click
        /// behaviour: connect a host, edit a key, run a snippet.
        var activate: (() -> Void)?

        init(content: HelmAccentRow.Content) { self.content = content }

        static func group(_ name: String) -> Item {
            var item = Item(content: .init(tint: .neutral, kicker: name))
            item.kind = .group(name)
            return item
        }

        static func empty(symbol: String, title: String, body: String) -> Item {
            var item = Item(content: .init(tint: .neutral, kicker: ""))
            item.kind = .empty(symbol: symbol, title: title, body: body)
            return item
        }

        var isRecord: Bool {
            if case .record = kind { return true }
            return false
        }
    }

    let card = HelmCard()

    private let table = HelmTableView()
    private let scroll = NSScrollView()
    private var items: [Item] = []
    private var theme: HelmTheme = ThemeManager.shared.theme

    /// A fully-populated `HelmAccentRow` reports a ~75pt fitting height on the
    /// app's shared type scale (measured for `ShiftListViews`, same three text
    /// lines); the cell insets it by 1pt top and bottom, and `intercellSpacing`
    /// below supplies the gap *between* cards rather than padding inside them.
    static let recordRowHeight: CGFloat = 78
    static let groupRowHeight: CGFloat = 26
    /// The floor for an empty state; it otherwise grows to fill whatever is
    /// left of the card body, so "nothing here yet" is centred in the space it
    /// actually has rather than pinned to the top of a mostly-blank card.
    static let minimumEmptyRowHeight: CGFloat = 180

    private static let columnID = NSUserInterfaceItemIdentifier("hostsListCol")
    private static let recordID = NSUserInterfaceItemIdentifier("hostsListRecord")
    private static let groupID = NSUserInterfaceItemIdentifier("hostsListGroup")
    private static let emptyID = NSUserInterfaceItemIdentifier("hostsListEmpty")

    override init() {
        super.init()

        let column = NSTableColumn(identifier: Self.columnID)
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.backgroundColor = .clear
        // `.fullWidth`, not `.sourceList`: the source-list style is what
        // installs the private selection material audit §5.2 is about, and it
        // also adds its own insets, which fight a row that is already a card.
        table.style = .fullWidth
        table.selectionHighlightStyle = .none
        table.gridStyleMask = []
        table.intercellSpacing = NSSize(width: 0, height: 6)
        table.rowHeight = Self.recordRowHeight
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(rowDoubleClicked)
        table.allowsEmptySelection = true

        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.automaticallyAdjustsContentInsets = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        // A resize changes how much room an empty state has, so its row height
        // has to be recomputed - see `heightOfRow`.
        scroll.contentView.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(clipViewResized),
                                               name: NSView.frameDidChangeNotification,
                                               object: scroll.contentView)

        card.setBody(scroll, insets: NSEdgeInsets(top: HelmMetrics.s3, left: HelmMetrics.s3,
                                                  bottom: HelmMetrics.s3, right: HelmMetrics.s3))
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    // MARK: Content

    func setItems(_ items: [Item]) {
        let previouslySelected = table.selectedRow
        self.items = items
        table.reloadData()
        // Keep a selection where one is still meaningful (a reload fires on
        // every store change, including one the captain caused from a
        // different row), but never leave it pointing at a group header or an
        // empty state.
        if previouslySelected >= 0, previouslySelected < items.count, items[previouslySelected].isRecord {
            table.selectRowIndexes(IndexSet(integer: previouslySelected), byExtendingSelection: false)
        }
    }

    func applyTheme(_ theme: HelmTheme) {
        self.theme = theme
        card.applyTheme(theme)
        // Every cell carries theme-derived colours that do not re-derive
        // themselves, so the list is rebuilt rather than relying on system
        // semantic colours re-resolving against a forced appearance.
        table.reloadData()
    }

    // MARK: Probe / self-test surface
    //
    // Real, live handles rather than a screenshot: a probe drives the same
    // button target/action and the same menu item a click would, and reads the
    // same resolved geometry the row actually rendered with.

    var debugRowCount: Int { items.count }
    var debugTable: NSTableView { table }

    /// The live row view for `row`.
    func debugRowView(_ row: Int) -> NSView? {
        table.view(atColumn: 0, row: row, makeIfNecessary: true)
    }

    /// The shared `HelmAccentRow` inside `row`'s cell, for `debugGeometry()`.
    func debugAccentRow(_ row: Int) -> HelmAccentRow? {
        (debugRowView(row) as? HostsListRecordView)?.debugAccentRow
    }

    /// `row`'s real primary-action button ("Connect" / "Edit" / "Run"), so a
    /// probe can `performClick(nil)` the genuine control.
    func debugPrimaryButton(_ row: Int) -> NSButton? {
        (debugRowView(row) as? HostsListRecordView)?.debugPrimaryButton
    }

    /// `row`'s real overflow/context menu, so a probe can dispatch one of its
    /// items through the same target/action a click would.
    func debugRowMenu(_ row: Int) -> NSMenu? {
        (debugRowView(row) as? HostsListRecordView)?.debugMenu()
    }

    func debugSelect(_ row: Int) {
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
    }

    @objc private func clipViewResized() {
        // GL-20: gate on visibility. Hosts is a permanently mounted,
        // `isHidden`-toggled destination, so an ungated handler here recomputes
        // row heights on every resize frame no matter which page is showing -
        // the same measured regression `ToolsController` and
        // `SettingsController` each fixed for their own resize handlers.
        guard let clip = table.enclosingScrollView?.contentView,
              clip.window != nil, !clip.isHiddenOrHasHiddenAncestor else { return }
        guard items.contains(where: { if case .empty = $0.kind { return true }; return false }) else { return }
        table.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: 0..<items.count))
    }

    @objc private func rowDoubleClicked() {
        let row = table.clickedRow
        guard row >= 0, row < items.count else { return }
        items[row].activate?()
    }

    // MARK: NSTableView

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        guard row < items.count else { return Self.recordRowHeight }
        switch items[row].kind {
        case .record: return Self.recordRowHeight
        case .group: return Self.groupRowHeight
        case .empty:
            // Fill whatever the other rows leave behind, so an empty state is
            // centred in the card body rather than sitting in its top 180pt.
            let others = items.enumerated().reduce(CGFloat(0)) { total, pair in
                guard pair.offset != row else { return total }
                switch pair.element.kind {
                case .record: return total + Self.recordRowHeight
                case .group: return total + Self.groupRowHeight
                case .empty: return total
                }
            }
            let spacing = CGFloat(max(items.count - 1, 0)) * tableView.intercellSpacing.height
            let available = scroll.contentView.bounds.height - others - spacing
            return max(Self.minimumEmptyRowHeight, available)
        }
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        row < items.count && items[row].isRecord
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < items.count else { return nil }
        let item = items[row]
        switch item.kind {
        case .group(let name):
            let cell = (tableView.makeView(withIdentifier: Self.groupID, owner: nil) as? HostsListGroupHeaderView)
                ?? { let v = HostsListGroupHeaderView(); v.identifier = Self.groupID; return v }()
            cell.configure(name: name, theme: theme)
            return cell
        case .empty(let symbol, let title, let body):
            // `.standard`, not `.compact`: this state is the whole card body of
            // a full-width page, which is exactly the case the component's own
            // doc comment reserves the larger glyph and the real title for.
            // Reused by identifier like any other cell, but only while the
            // symbol matches - the glyph is fixed at init.
            let reused = tableView.makeView(withIdentifier: Self.emptyID, owner: nil) as? HelmEmptyState
            let cell = (reused?.symbolName == symbol ? reused : nil)
                ?? { let v = HelmEmptyState(symbol: symbol, title: title, body: body, size: .standard)
                     v.identifier = Self.emptyID
                     return v }()
            cell.setText(title: title, body: body)
            cell.applyTheme(theme)
            return cell
        case .record:
            let cell = (tableView.makeView(withIdentifier: Self.recordID, owner: nil) as? HostsListRecordView)
                ?? { let v = HostsListRecordView(); v.identifier = Self.recordID; return v }()
            cell.configure(item, theme: theme, selected: tableView.selectedRowIndexes.contains(row))
            return cell
        }
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        // Repaint only what is on screen - `reloadData` here would rebuild
        // every cell (and drop the click that caused the selection).
        let visible = table.rows(in: table.visibleRect)
        guard visible.length > 0 else { return }
        for row in visible.location..<(visible.location + visible.length) where row < items.count {
            (table.view(atColumn: 0, row: row, makeIfNecessary: false) as? HostsListRecordView)?
                .setSelected(table.selectedRowIndexes.contains(row))
        }
    }
}

// MARK: - Group header

/// A group section header: the app's one kicker treatment
/// (`HelmType.kickerAttributes`, never a hand-rolled kern - see
/// `HelmContrastSelfTest.checkNoHandRolledKickers`) in `mutedInk`.
private final class HostsListGroupHeaderView: NSView {
    private let label = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: HelmMetrics.s3),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -HelmMetrics.s2),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -HelmMetrics.s1),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(name: String, theme: HelmTheme) {
        label.attributedStringValue = NSAttributedString(
            string: name.uppercased(),
            attributes: HelmType.kickerAttributes(color: HelmTheme.mutedInk(theme))
        )
    }
}

// MARK: - Record row

/// One record row: the shared `HelmAccentRow` plus this list's own trailing
/// action controls in its `trailingAccessory` slot.
///
/// The same actions are also this view's right-click `menu`, built from one
/// array, so the button menu and the context menu cannot drift apart the way
/// the three lists' own footer buttons and context menus previously could.
private final class HostsListRecordView: NSView {

    private let primaryButton = HelmButton(title: "", variant: .secondary, size: .small)
    private let overflowButton = HelmButton(title: "", variant: .quiet, size: .small, symbol: "ellipsis")
    /// Holds the overflow button's width open for a row that has no overflow
    /// menu (only the pinned "Firstmate" entry). An `NSStackView` drops a
    /// hidden arranged subview out of layout entirely, so without this the
    /// pinned row's Connect sits ~30pt right of every other row's and the
    /// action column reads ragged - the same complaint audit §5.4 makes about
    /// `ToolRowLayout`'s status column. A real spacer rather than
    /// `alphaValue = 0` on the button itself: an invisible-but-present control
    /// is still in the accessibility and hit-test trees, and it also renders
    /// visibly under `cacheDisplay`, which is this repo's screenshot
    /// substitute (seen in a real Phase 5 render).
    private let overflowSpacer = NSView()
    private let actions = NSStackView()
    private let row: HelmAccentRow

    private var primary: HostsListSection.Action?
    private var overflow: [HostsListSection.Action] = []

    init() {
        actions.orientation = .horizontal
        actions.alignment = .centerY
        actions.spacing = HelmMetrics.s1
        actions.distribution = .fill
        // The *stack*-level pair, not the content-level one - see
        // `HelmAccentRow.buildLayout`'s note on AGENTS.md gotcha (12). Set here
        // as well as there so this stack is correct on its own terms rather
        // than relying on the row to fix it up.
        actions.setHuggingPriority(.required, for: .horizontal)
        actions.setClippingResistancePriority(.required, for: .horizontal)
        actions.translatesAutoresizingMaskIntoConstraints = false
        // The buttons themselves have to hug: they *do* have an intrinsic
        // content size (unlike the stack around them, where the content-level
        // API is a no-op - AGENTS.md gotcha (12)), and without this the
        // stack's own `.fill` distribution stretches whichever of them can
        // grow, which is what made a 90pt "Connect" render ~900pt wide in the
        // first Phase 5 render of this page. Same call `HelmCard.setHeader`
        // already makes for its own trailing actions.
        for b in [primaryButton, overflowButton] {
            b.setContentHuggingPriority(.required, for: .horizontal)
            b.setContentCompressionResistancePriority(.required, for: .horizontal)
        }
        overflowSpacer.translatesAutoresizingMaskIntoConstraints = false
        overflowSpacer.widthAnchor
            .constraint(equalToConstant: overflowButton.intrinsicContentSize.width).isActive = true
        actions.addArrangedSubview(primaryButton)
        actions.addArrangedSubview(overflowButton)
        actions.addArrangedSubview(overflowSpacer)

        row = HelmAccentRow(trailingAccessory: actions)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        primaryButton.target = self
        primaryButton.action = #selector(primaryClicked)
        overflowButton.target = self
        overflowButton.action = #selector(overflowClicked)
        overflowButton.toolTip = "More actions"

        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor, constant: 1),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -1),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(_ item: HostsListSection.Item, theme: HelmTheme, selected: Bool) {
        primary = item.primary
        overflow = item.overflow

        if let primary = item.primary {
            primaryButton.isHidden = false
            primaryButton.title = primary.title
            primaryButton.symbolName = primary.symbol
        } else {
            primaryButton.isHidden = true
        }
        // Exactly one of the two is in layout, so every row's action column is
        // the same width - see `overflowSpacer`.
        let hasOverflow = !item.overflow.isEmpty
        overflowButton.isHidden = !hasOverflow
        overflowSpacer.isHidden = hasOverflow

        menu = item.overflow.isEmpty ? nil : buildMenu()
        row.isRowSelected = selected
        row.configure(item.content, theme: theme)
    }

    func setSelected(_ selected: Bool) { row.isRowSelected = selected }

    var debugAccentRow: HelmAccentRow { row }
    var debugPrimaryButton: NSButton? { primaryButton.isHidden ? nil : primaryButton }
    func debugMenu() -> NSMenu? { overflow.isEmpty ? nil : buildMenu() }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        if let primary {
            let item = NSMenuItem(title: primary.title, action: #selector(primaryClicked), keyEquivalent: "")
            item.target = self
            menu.addItem(item)
            menu.addItem(.separator())
        }
        for (index, action) in overflow.enumerated() {
            let item = NSMenuItem(title: action.title, action: #selector(overflowItemPicked(_:)), keyEquivalent: "")
            item.target = self
            item.tag = index
            menu.addItem(item)
        }
        return menu
    }

    @objc private func primaryClicked() { primary?.run() }

    @objc private func overflowClicked() {
        guard !overflow.isEmpty else { return }
        let menu = buildMenu()
        menu.popUp(positioning: nil,
                   at: NSPoint(x: 0, y: overflowButton.bounds.height + 2),
                   in: overflowButton)
    }

    @objc private func overflowItemPicked(_ sender: NSMenuItem) {
        guard sender.tag >= 0, sender.tag < overflow.count else { return }
        overflow[sender.tag].run()
    }
}
