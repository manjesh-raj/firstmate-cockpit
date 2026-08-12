// Manjesh Grand Line - native macOS app.
//
// Rendering for the Tools page's diff result (cockpit-tools-page-diff,
// phase 2 of 3 - see ToolsController.swift's header and DiffEngine.swift
// for the algorithm this renders). Built as a plain NSStackView of rows
// rather than two synced NSTextViews - this app already has a working
// "row in a vertical stack, inside a flipped document view" pattern for
// every other scrollable list (Fleet's PR list, Updates' tool rows), and it
// makes word-level highlighting straightforward via NSAttributedString
// background-color runs on a plain NSTextField label, with no scroll-sync
// code needed for two independent NSTextViews.
//
// Lines are rendered single-line, non-wrapping (`.byTruncatingTail`) so the
// two columns of a row always stay the same height and therefore aligned -
// wrapping would let one side grow taller than the other and desync every
// row below it.

import AppKit

/// One row of the diff result: either a real aligned line pair, or a
/// collapsed run of unchanged lines shown as a clickable separator.
private enum DiffDisplayItem {
    case row(DiffRow)
    case collapsed(id: Int, count: Int)
}

/// Renders a `[DiffRow]` (from `DiffEngine.lineDiff`) as a scrollable,
/// two-column, line-numbered diff. Owns its own "show only differences" /
/// expanded-collapsed-run state so `ToolsController` just calls `setRows`
/// and `setShowOnlyDifferences` and doesn't need to track display state.
final class DiffResultView: NSView {
    override var isFlipped: Bool { true }

    private let stack = NSStackView()
    private var theme: HelmTheme = ThemeManager.shared.theme
    /// Follows `FontSizeManager` (`fm/cockpit-tools-page-ui-polish`) - the
    /// line-number/text/separator fonts below are all offset from this by
    /// the same deltas their original hardcoded sizes had from the default
    /// 13pt terminal size (10/11/10.5, i.e. -3/-2/-2.5).
    private var fontSize: CGFloat = FontSizeManager.shared.size
    private var rows: [DiffRow] = []
    private var showOnlyDifferences = false
    private var expandedGroups: Set<Int> = []

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 1
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
        ])
        rebuild()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not supported")
    }

    func setRows(_ rows: [DiffRow]) {
        self.rows = rows
        expandedGroups = []
        rebuild()
    }

    func setShowOnlyDifferences(_ show: Bool) {
        showOnlyDifferences = show
        rebuild()
    }

    func applyTheme(_ theme: HelmTheme) {
        self.theme = theme
        rebuild()
    }

    func setFontSize(_ size: CGFloat) {
        fontSize = size
        rebuild()
    }

    /// Groups consecutive unchanged rows into collapsed separators when
    /// `showOnlyDifferences` is on, unless that specific run's id (its start
    /// index in `rows`, stable across rebuilds of the same comparison) is in
    /// `expandedGroups`.
    private func displayItems() -> [DiffDisplayItem] {
        guard showOnlyDifferences else { return rows.map { .row($0) } }
        var items: [DiffDisplayItem] = []
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
                    for r in rows[start..<(start + count)] { items.append(.row(r)) }
                } else {
                    items.append(.collapsed(id: start, count: count))
                }
            } else {
                items.append(.row(rows[i]))
                i += 1
            }
        }
        return items
    }

    private func rebuild() {
        for v in stack.arrangedSubviews {
            stack.removeArrangedSubview(v)
            v.removeFromSuperview()
        }
        let items = displayItems()
        if items.isEmpty {
            let empty = NSTextField(labelWithString: rows.isEmpty ? "Click Compare to see a diff." : "No differences.")
            empty.font = .systemFont(ofSize: max(8, fontSize - 2))
            empty.textColor = HelmTheme.mutedInk(theme)
            stack.addArrangedSubview(empty)
            return
        }
        for item in items {
            switch item {
            case .row(let row):
                let rowView = DiffRowView()
                rowView.configure(row: row, theme: theme, fontSize: fontSize)
                stack.addArrangedSubview(rowView)
                rowView.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            case .collapsed(let id, let count):
                let sep = CollapsedRunView()
                sep.configure(count: count, theme: theme, fontSize: fontSize) { [weak self] in
                    self?.expandedGroups.insert(id)
                    self?.rebuild()
                }
                stack.addArrangedSubview(sep)
                sep.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            }
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
