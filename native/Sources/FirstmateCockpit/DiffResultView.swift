// Manjesh Grand Line - native macOS app.
//
// Rendering for the Tools page's diff result (cockpit-tools-page-diff,
// phase 2 of 3 - see ToolsController.swift's header and DiffEngine.swift
// for the algorithm this renders).
//
// `fm/cockpit-tools-yaml-quotes-diff-perf` replaced this view's original
// "plain NSStackView of one custom NSView per row" implementation with a
// single-column, view-based NSTableView. The captain reported the Diff tool
// itself (not window resize, which a prior task already fixed) was
// noticeably slow on a real 300+ line manifest, specifically at the moment
// Compare is clicked. A temporary env-gated timing probe (`FM_DEBUG_DIFF_PERF`,
// reverted before commit per AGENTS.md's "Verifying native UI bugs" convention)
// measured the real breakdown at n=320 lines/340 rows: `DiffEngine.lineDiff`
// (parse + line LCS + per-changed-row word LCS) ~12ms, `DiffResultView` view
// construction ~50ms, `setRows` (the old rebuild of the NSStackView tree)
// ~92ms - all cheap - versus `layoutSubtreeIfNeeded` (AppKit's own Auto
// Layout resolve of the resulting arranged-subview tree): ~13.6 SECONDS.
// Scaling the row count confirmed this isn't linear or even quadratic -
// 70/120/220/320 rows measured ~202ms/919ms/4483ms/13598ms respectively (a
// ~67x time increase for a ~4.6x row-count increase) - a known NSStackView
// pathology: every arranged subview participates in one shared Auto Layout
// solve simultaneously, so cost blows up far faster than the row count once
// there are hundreds of them. Neither the line/word-diff algorithm nor the
// per-row view construction needed fixing - only how the result set was
// rendered.
//
// An `NSTableView` (view-based, one column) fixes this at the root: it is
// demand-driven - `tableView(_:viewFor:row:)` is only called for rows that
// actually need to be drawn (the visible rect plus a small buffer), not for
// every row up front, so opening a 300+ row diff only ever lays out a
// double-digit number of actual row views regardless of the total row
// count. Row content (two tinted, line-numbered columns, word-level
// highlighting) is unchanged - `DiffRowView`/`CollapsedRunView` below are the
// same view classes as before, now returned as reusable table cell views
// (`tableView.makeView(withIdentifier:owner:)`) instead of permanent
// `NSStackView` arranged subviews. Verified after the fix: the same
// `FM_DEBUG_DIFF_PERF` probe at n=320 measured total Compare-click cost
// (lineDiff + view construction + `reloadData`) at ~140ms end to end, with
// no separate catastrophic layout phase - see this task's PR description
// for the full before/after numbers across row counts.
//
// Lines are rendered single-line, non-wrapping (`.byTruncatingTail`) so the
// two columns of a row always stay the same height and therefore aligned -
// wrapping would let one side grow taller than the other, which a fixed
// table `rowHeight` (required for this fix - see below) could not
// accommodate anyway.

import AppKit

/// One row of the diff result: either a real aligned line pair, or a
/// collapsed run of unchanged lines shown as a clickable separator.
private enum DiffDisplayItem {
    case row(DiffRow)
    case collapsed(id: Int, count: Int)
}

/// Renders a `[DiffRow]` (from `DiffEngine.lineDiff`) as a scrollable,
/// two-column, line-numbered diff via a single-column, view-based
/// `NSTableView` - see the header above for why. Owns its own "show only
/// differences" / expanded-collapsed-run state so `ToolsController` just
/// calls `setRows` and `setShowOnlyDifferences` and doesn't need to track
/// display state. Not an `NSView` itself (unlike the pre-fix version) -
/// callers embed `tableView` directly as an `NSScrollView`'s document view,
/// which is what makes the table's own demand-driven row rendering apply;
/// wrapping it in another plain container view would gain nothing.
final class DiffResultView: NSObject {
    let tableView = NSTableView()

    private var theme: HelmTheme = ThemeManager.shared.theme
    /// Follows `FontSizeManager` (`fm/cockpit-tools-page-ui-polish`) - the
    /// line-number/text/separator fonts below are all offset from this by
    /// the same deltas their original hardcoded sizes had from the default
    /// 13pt terminal size (10/11/10.5, i.e. -3/-2/-2.5).
    private var fontSize: CGFloat = FontSizeManager.shared.size
    private var rows: [DiffRow] = []
    private var showOnlyDifferences = false
    private var expandedGroups: Set<Int> = []
    private var items: [DiffDisplayItem] = []

    private static let rowColumnID = NSUserInterfaceItemIdentifier("diffRow")
    private static let rowViewID = NSUserInterfaceItemIdentifier("diffRowView")
    private static let collapsedViewID = NSUserInterfaceItemIdentifier("diffCollapsedRunView")
    private static let emptyViewID = NSUserInterfaceItemIdentifier("diffEmptyView")

    override init() {
        super.init()
        let column = NSTableColumn(identifier: Self.rowColumnID)
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.backgroundColor = .clear
        tableView.selectionHighlightStyle = .none
        tableView.gridStyleMask = []
        tableView.intercellSpacing = NSSize(width: 0, height: 1)
        tableView.autoresizingMask = [.width]
        tableView.rowHeight = Self.rowHeight(for: fontSize)
        tableView.dataSource = self
        tableView.delegate = self
        recomputeItems()
    }

    private static func rowHeight(for fontSize: CGFloat) -> CGFloat {
        max(20, fontSize + 6)
    }

    func setRows(_ rows: [DiffRow]) {
        self.rows = rows
        expandedGroups = []
        recomputeItems()
        tableView.reloadData()
    }

    func setShowOnlyDifferences(_ show: Bool) {
        showOnlyDifferences = show
        recomputeItems()
        tableView.reloadData()
    }

    func applyTheme(_ theme: HelmTheme) {
        self.theme = theme
        tableView.reloadData()
    }

    func setFontSize(_ size: CGFloat) {
        fontSize = size
        tableView.rowHeight = Self.rowHeight(for: size)
        tableView.reloadData()
    }

    /// Groups consecutive unchanged rows into collapsed separators when
    /// `showOnlyDifferences` is on, unless that specific run's id (its start
    /// index in `rows`, stable across rebuilds of the same comparison) is in
    /// `expandedGroups`.
    private func recomputeItems() {
        guard showOnlyDifferences else {
            items = rows.map { .row($0) }
            return
        }
        var result: [DiffDisplayItem] = []
        var i = 0
        while i < rows.count {
            if rows[i].kind == .unchanged {
                let start = i
                var count = 0
                while i < rows.count, rows[i].kind == .unchanged {
                    count += 1
                    i += 1
                }
                if expandedGroups.contains(start) {
                    for r in rows[start..<(start + count)] { result.append(.row(r)) }
                } else {
                    result.append(.collapsed(id: start, count: count))
                }
            } else {
                result.append(.row(rows[i]))
                i += 1
            }
        }
        items = result
    }

    private func expand(runID: Int) {
        expandedGroups.insert(runID)
        recomputeItems()
        tableView.reloadData()
    }
}

extension DiffResultView: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        items.isEmpty ? 1 : items.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard !items.isEmpty else {
            let label = (tableView.makeView(withIdentifier: Self.emptyViewID, owner: nil) as? NSTextField)
                ?? {
                    let l = NSTextField(labelWithString: "")
                    l.identifier = Self.emptyViewID
                    return l
                }()
            label.stringValue = rows.isEmpty ? "Click Compare to see a diff." : "No differences."
            label.font = .systemFont(ofSize: max(8, fontSize - 2))
            label.textColor = HelmTheme.mutedInk(theme)
            return label
        }

        switch items[row] {
        case .row(let diffRow):
            let rowView = (tableView.makeView(withIdentifier: Self.rowViewID, owner: nil) as? DiffRowView)
                ?? {
                    let v = DiffRowView()
                    v.identifier = Self.rowViewID
                    return v
                }()
            rowView.configure(row: diffRow, theme: theme, fontSize: fontSize)
            return rowView
        case .collapsed(let id, let count):
            let sep = (tableView.makeView(withIdentifier: Self.collapsedViewID, owner: nil) as? CollapsedRunView)
                ?? {
                    let v = CollapsedRunView()
                    v.identifier = Self.collapsedViewID
                    return v
                }()
            sep.configure(count: count, theme: theme, fontSize: fontSize) { [weak self] in
                self?.expand(runID: id)
            }
            return sep
        }
    }
}

/// One line-pair row: two tinted columns (line number + text), each side
/// independently tinted/highlighted per `DiffRowKind` and, for `changed`
/// rows, per-word via `DiffToken.changed`.
private final class DiffRowView: NSView {
    private let leftNumber = NSTextField(labelWithString: "")
    private let rightNumber = NSTextField(labelWithString: "")
    private let leftText = NSTextField(labelWithString: "")
    private let rightText = NSTextField(labelWithString: "")
    private let leftBg = NSView()
    private let rightBg = NSView()

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        for tf in [leftNumber, rightNumber] {
            tf.alignment = .right
            tf.translatesAutoresizingMaskIntoConstraints = false
            tf.widthAnchor.constraint(equalToConstant: 30).isActive = true
            tf.setContentHuggingPriority(.required, for: .horizontal)
        }
        for tf in [leftText, rightText] {
            tf.lineBreakMode = .byTruncatingTail
            tf.maximumNumberOfLines = 1
            tf.translatesAutoresizingMaskIntoConstraints = false
            tf.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }

        let leftRow = NSStackView(views: [leftNumber, leftText])
        leftRow.orientation = .horizontal
        leftRow.spacing = 6
        leftRow.alignment = .centerY
        leftRow.translatesAutoresizingMaskIntoConstraints = false

        let rightRow = NSStackView(views: [rightNumber, rightText])
        rightRow.orientation = .horizontal
        rightRow.spacing = 6
        rightRow.alignment = .centerY
        rightRow.translatesAutoresizingMaskIntoConstraints = false

        for (bg, row) in [(leftBg, leftRow), (rightBg, rightRow)] {
            bg.wantsLayer = true
            bg.translatesAutoresizingMaskIntoConstraints = false
            bg.addSubview(row)
            NSLayoutConstraint.activate([
                row.leadingAnchor.constraint(equalTo: bg.leadingAnchor, constant: 4),
                row.trailingAnchor.constraint(equalTo: bg.trailingAnchor, constant: -4),
                row.topAnchor.constraint(equalTo: bg.topAnchor, constant: 2),
                row.bottomAnchor.constraint(equalTo: bg.bottomAnchor, constant: -2),
            ])
        }

        let columns = NSStackView(views: [leftBg, rightBg])
        columns.orientation = .horizontal
        columns.spacing = 1
        columns.distribution = .fillEqually
        columns.translatesAutoresizingMaskIntoConstraints = false
        addSubview(columns)
        NSLayoutConstraint.activate([
            columns.leadingAnchor.constraint(equalTo: leadingAnchor),
            columns.trailingAnchor.constraint(equalTo: trailingAnchor),
            columns.topAnchor.constraint(equalTo: topAnchor),
            columns.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not supported")
    }

    func configure(row: DiffRow, theme: HelmTheme, fontSize: CGFloat) {
        let numberFont = NSFont.monospacedSystemFont(ofSize: max(8, fontSize - 3), weight: .regular)
        let textFont = NSFont.monospacedSystemFont(ofSize: max(8, fontSize - 2), weight: .regular)
        for tf in [leftNumber, rightNumber] { tf.font = numberFont }
        for tf in [leftText, rightText] { tf.font = textFont }

        leftNumber.stringValue = row.leftNumber.map(String.init) ?? ""
        rightNumber.stringValue = row.rightNumber.map(String.init) ?? ""
        let muted = HelmTheme.mutedInk(theme)
        leftNumber.textColor = muted
        rightNumber.textColor = muted

        leftText.attributedStringValue = Self.attributedText(row.leftTokens, theme: theme)
        rightText.attributedStringValue = Self.attributedText(row.rightTokens, theme: theme)

        let (leftTint, rightTint) = Self.rowTints(kind: row.kind, theme: theme)
        leftBg.layer?.backgroundColor = leftTint?.cgColor
        rightBg.layer?.backgroundColor = rightTint?.cgColor
    }

    private static func rowTints(kind: DiffRowKind, theme: HelmTheme) -> (NSColor?, NSColor?) {
        switch kind {
        case .unchanged:
            return (nil, nil)
        case .added:
            return (nil, HelmTheme.nsColor(HelmTint.good.hex(in: theme)).withAlphaComponent(0.16))
        case .removed:
            return (HelmTheme.nsColor(HelmTint.critical.hex(in: theme)).withAlphaComponent(0.16), nil)
        case .changed:
            let c = HelmTheme.nsColor(HelmTint.warn.hex(in: theme)).withAlphaComponent(0.12)
            return (c, c)
        }
    }

    private static func attributedText(_ tokens: [DiffToken]?, theme: HelmTheme) -> NSAttributedString {
        guard let tokens, !tokens.isEmpty else { return NSAttributedString(string: "") }
        let ink = HelmTheme.nsColor(theme.chromeInkHex)
        let wordHighlight = HelmTheme.nsColor(HelmTint.warn.hex(in: theme)).withAlphaComponent(0.5)
        let result = NSMutableAttributedString()
        for token in tokens {
            var attrs: [NSAttributedString.Key: Any] = [.foregroundColor: ink]
            if token.changed { attrs[.backgroundColor] = wordHighlight }
            result.append(NSAttributedString(string: token.text, attributes: attrs))
        }
        return result
    }
}

/// The clickable "N unchanged lines" separator that stands in for a
/// collapsed run - expands in place via its `onExpand` callback, which
/// `DiffResultView` wires to reveal the real rows for that run's id.
private final class CollapsedRunView: NSView {
    private let highlight = HoverHighlightView()
    private let label = NSTextField(labelWithString: "")
    private var onExpand: (() -> Void)?

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        label.translatesAutoresizingMaskIntoConstraints = false

        highlight.cornerRadius = 5
        highlight.translatesAutoresizingMaskIntoConstraints = false
        highlight.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: highlight.centerXAnchor),
            label.topAnchor.constraint(equalTo: highlight.topAnchor, constant: 4),
            label.bottomAnchor.constraint(equalTo: highlight.bottomAnchor, constant: -4),
        ])
        addSubview(highlight)
        NSLayoutConstraint.activate([
            highlight.leadingAnchor.constraint(equalTo: leadingAnchor),
            highlight.trailingAnchor.constraint(equalTo: trailingAnchor),
            highlight.topAnchor.constraint(equalTo: topAnchor),
            highlight.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        let click = NSClickGestureRecognizer(target: self, action: #selector(clicked))
        highlight.addGestureRecognizer(click)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not supported")
    }

    func configure(count: Int, theme: HelmTheme, fontSize: CGFloat, onExpand: @escaping () -> Void) {
        label.font = .systemFont(ofSize: max(8, fontSize - 2.5), weight: .medium)
        label.stringValue = "\u{25B8} \(count) unchanged line\(count == 1 ? "" : "s") - click to expand"
        label.textColor = HelmTheme.mutedInk(theme)
        let line = HelmTheme.nsColor(theme.chromeLineHex)
        highlight.normalColor = line.withAlphaComponent(0.08)
        highlight.hoverColor = line.withAlphaComponent(0.22)
        self.onExpand = onExpand
    }

    @objc private func clicked() {
        onExpand?()
    }
}
