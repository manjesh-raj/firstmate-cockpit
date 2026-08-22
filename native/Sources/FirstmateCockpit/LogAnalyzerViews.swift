// Manjesh Grand Line - native macOS app.
//
// `fm/grandline-log-analyzer-build`: the list/pane subviews behind
// `LogAnalyzerController`. Split out of that controller for the same reason
// `ReviewPRListView`/`HostsListSection`/`ShiftProjectDetailView` are split
// out of theirs - the page controller stays about *flow* (input, analyze,
// act) while each list stays about rendering one kind of row.
//
// **Every list here is a view-based `NSTableView`, never an `NSStackView` of
// permanent rows.** This is not a style preference: a raw-log pane routinely
// holds thousands of lines and an error-group panel expands to show sample
// lines, and this codebase has hit the "an `NSStackView` with hundreds of
// arranged subviews blows up far faster than the row count" pathology and
// fixed it the same way at least four times (the Diff tool's ~13.6s blowup
// at ~340 rows, Block View's ~102s at 400 blocks, the Review page's
// stuck-on-loading regression, the Tools-page resize handler). A demand-
// driven table only builds rows actually on screen, so a 10,000-line paste
// renders in the same time as a 20-line one.
//
// Rows that can expand (error groups) are handled by **flattening** rather
// than by nesting: the expanded sample lines become their own rows in the
// same single-column table, exactly the way `ShiftProjectTaskListView`
// renders subtasks (see its own header) - `NSTableView` has no first-class
// nested-row concept, and a flattened model keeps every row a fixed height.

import AppKit

// MARK: - Raw log pane (the left half of the split workspace)

/// The read-only, line-numbered raw input. Error/warning lines carry a faint
/// severity wash, matching the mockup's `.rawline.err`/`.warn` treatment.
///
/// Severity per line comes from `LogErrorExtractor.severity(forLine:)` - the
/// same classifier the grouped rows and the detection strip use, so a line
/// tinted red here is a line that genuinely counted as an error there.
final class LogRawPaneView: NSView {

    static let rowHeight: CGFloat = 15

    let tableView = NSTableView()
    private let scroll = NSScrollView()
    private var lines: [String] = []
    private var severities: [LogSeverity] = []
    private var theme: HelmTheme = ThemeManager.shared.theme

    private static let columnID = NSUserInterfaceItemIdentifier("logRawColumn")
    private static let cellID = NSUserInterfaceItemIdentifier("logRawCell")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
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
        tableView.intercellSpacing = NSSize(width: 0, height: 0)
        tableView.rowHeight = Self.rowHeight
        tableView.dataSource = self
        tableView.delegate = self

        scroll.documentView = tableView
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.drawsBackground = true
        scroll.borderType = .noBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    func setText(_ text: String, theme: HelmTheme) {
        self.theme = theme
        lines = text.isEmpty ? [] : text.components(separatedBy: "\n")
        severities = lines.map { LogErrorExtractor.severity(forLine: $0) }
        applyTheme(theme)
        tableView.reloadData()
        tableView.scrollRowToVisible(0)
    }

    func applyTheme(_ theme: HelmTheme) {
        self.theme = theme
        scroll.backgroundColor = HelmTheme.nsColor(theme.backgroundHex)
        tableView.reloadData()
    }

    /// Scrolls a specific 1-based input line into view - used when the
    /// captain clicks a counted pattern or a timeline event.
    func reveal(line: Int) {
        let index = max(0, min(line - 1, max(lines.count - 1, 0)))
        guard !lines.isEmpty else { return }
        tableView.scrollRowToVisible(index)
    }

    var lineCount: Int { lines.count }
}

extension LogRawPaneView: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { lines.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = (tableView.makeView(withIdentifier: Self.cellID, owner: nil) as? LogRawLineCell)
            ?? {
                let v = LogRawLineCell()
                v.identifier = Self.cellID
                return v
            }()
        cell.configure(number: row + 1, text: lines[row], severity: severities[row], theme: theme)
        return cell
    }
}

/// One raw line: a fixed-width gutter number plus the line itself.
private final class LogRawLineCell: NSTableCellView {
    private let numberLabel = NSTextField(labelWithString: "")
    private let textLabel = NSTextField(labelWithString: "")
    private let wash = NSView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wash.wantsLayer = true
        wash.translatesAutoresizingMaskIntoConstraints = false
        addSubview(wash)

        numberLabel.font = .monospacedSystemFont(ofSize: 9.5, weight: .regular)
        numberLabel.alignment = .right
        numberLabel.translatesAutoresizingMaskIntoConstraints = false
        numberLabel.setContentHuggingPriority(.required, for: .horizontal)
        numberLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        addSubview(numberLabel)

        textLabel.font = .monospacedSystemFont(ofSize: 10.5, weight: .regular)
        textLabel.lineBreakMode = .byTruncatingTail
        textLabel.translatesAutoresizingMaskIntoConstraints = false
        textLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(textLabel)

        NSLayoutConstraint.activate([
            wash.leadingAnchor.constraint(equalTo: leadingAnchor),
            wash.trailingAnchor.constraint(equalTo: trailingAnchor),
            wash.topAnchor.constraint(equalTo: topAnchor),
            wash.bottomAnchor.constraint(equalTo: bottomAnchor),

            numberLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            numberLabel.widthAnchor.constraint(equalToConstant: 34),
            numberLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            textLabel.leadingAnchor.constraint(equalTo: numberLabel.trailingAnchor, constant: 8),
            textLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            textLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    func configure(number: Int, text: String, severity: LogSeverity, theme: HelmTheme) {
        numberLabel.stringValue = "\(number)"
        numberLabel.textColor = HelmTheme.mutedInk(theme).withAlphaComponent(0.55)
        textLabel.stringValue = text.isEmpty ? " " : text

        switch severity {
        case .critical, .high:
            let hue = HelmTheme.nsColor(theme.ansiHex[1])
            wash.layer?.backgroundColor = hue.withAlphaComponent(0.10).cgColor
            textLabel.textColor = HelmContrast.legibleTintedText(
                tintHex: theme.ansiHex[1],
                over: HelmTheme.nsColor(theme.backgroundHex),
                theme: theme)
        case .warning:
            let hue = HelmTheme.nsColor(theme.ansiHex[3])
            wash.layer?.backgroundColor = hue.withAlphaComponent(0.08).cgColor
            textLabel.textColor = HelmContrast.legibleTintedText(
                tintHex: theme.ansiHex[3],
                over: HelmTheme.nsColor(theme.backgroundHex),
                theme: theme)
        case .informational, .normal:
            wash.layer?.backgroundColor = NSColor.clear.cgColor
            textLabel.textColor = HelmTheme.nsColor(theme.chromeInkHex).withAlphaComponent(0.85)
        }
    }
}

// MARK: - Error groups (spec §6, §7)

/// The collapsed-pattern list. Clicking a pattern expands it to show real
/// matching lines (spec §6's "clicking a pattern should show the matching
/// lines"), rendered as extra rows in this same table - see this file's
/// header on why flattening rather than nesting.
final class LogErrorGroupListView: NSView {

    private enum Row {
        case group(LogErrorGroup)
        case sample(String)
        case more(Int)
    }

    static let groupRowHeight: CGFloat = 58
    static let sampleRowHeight: CGFloat = 22
    static let emptyRowHeight: CGFloat = 140

    let tableView = NSTableView()
    private var groups: [LogErrorGroup] = []
    private var expanded: Set<String> = []
    private var rows: [Row] = []
    private var theme: HelmTheme = ThemeManager.shared.theme
    private var heightConstraint: NSLayoutConstraint!

    /// Fired with the 1-based input line number of a clicked sample line, so
    /// the raw pane can jump to it.
    var onRevealLine: ((Int) -> Void)?

    private static let columnID = NSUserInterfaceItemIdentifier("logGroupColumn")
    private static let groupCellID = NSUserInterfaceItemIdentifier("logGroupCell")
    private static let sampleCellID = NSUserInterfaceItemIdentifier("logSampleCell")
    private static let emptyID = NSUserInterfaceItemIdentifier("logGroupEmpty")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
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
        tableView.intercellSpacing = NSSize(width: 0, height: 6)
        tableView.rowHeight = Self.groupRowHeight
        tableView.autoresizingMask = [.width]
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.action = #selector(rowClicked)
        tableView.translatesAutoresizingMaskIntoConstraints = false

        addSubview(tableView)
        heightConstraint = tableView.heightAnchor.constraint(equalToConstant: Self.emptyRowHeight)
        NSLayoutConstraint.activate([
            tableView.leadingAnchor.constraint(equalTo: leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: trailingAnchor),
            tableView.topAnchor.constraint(equalTo: topAnchor),
            tableView.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightConstraint,
        ])
    }

    func setGroups(_ groups: [LogErrorGroup], theme: HelmTheme) {
        self.groups = groups
        self.theme = theme
        expanded.removeAll()
        rebuild()
    }

    func applyTheme(_ theme: HelmTheme) {
        self.theme = theme
        tableView.reloadData()
    }

    private func rebuild() {
        rows = []
        for group in groups {
            rows.append(.group(group))
            guard expanded.contains(group.id) else { continue }
            for sample in group.sampleLines { rows.append(.sample(sample)) }
            let shown = group.sampleLines.count
            if group.occurrences > shown { rows.append(.more(group.occurrences - shown)) }
        }
        recomputeHeight()
        tableView.reloadData()
    }

    private func recomputeHeight() {
        guard !rows.isEmpty else {
            heightConstraint.constant = Self.emptyRowHeight
            return
        }
        var total: CGFloat = 0
        for row in rows {
            switch row {
            case .group: total += Self.groupRowHeight
            case .sample, .more: total += Self.sampleRowHeight
            }
        }
        heightConstraint.constant = total + CGFloat(max(0, rows.count - 1)) * 6
    }

    @objc private func rowClicked() {
        let index = tableView.clickedRow
        guard index >= 0, index < rows.count else { return }
        switch rows[index] {
        case .group(let group):
            if expanded.contains(group.id) { expanded.remove(group.id) } else { expanded.insert(group.id) }
            rebuild()
        case .sample:
            // Find which group this sample belongs to, then reveal its first
            // recorded line number in the raw pane.
            var owner: LogErrorGroup?
            for candidate in rows[0...index].reversed() {
                if case .group(let g) = candidate { owner = g; break }
            }
            if let line = owner?.lineNumbers.first { onRevealLine?(line) }
        case .more:
            break
        }
    }
}

extension LogErrorGroupListView: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { rows.isEmpty ? 1 : rows.count }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        guard !rows.isEmpty else { return Self.emptyRowHeight }
        switch rows[row] {
        case .group: return Self.groupRowHeight
        case .sample, .more: return Self.sampleRowHeight
        }
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard !rows.isEmpty else {
            let empty = (tableView.makeView(withIdentifier: Self.emptyID, owner: nil) as? HelmEmptyState)
                ?? {
                    let v = HelmEmptyState(symbol: "checkmark.seal",
                                           title: "No repeated error patterns",
                                           body: "Nothing in this output repeated at warning severity or above.",
                                           size: .standard, boxed: true)
                    v.identifier = Self.emptyID
                    return v
                }()
            empty.applyTheme(theme)
            return empty
        }

        switch rows[row] {
        case .group(let group):
            let cell = (tableView.makeView(withIdentifier: Self.groupCellID, owner: nil) as? LogErrorGroupCell)
                ?? {
                    let v = LogErrorGroupCell()
                    v.identifier = Self.groupCellID
                    return v
                }()
            cell.configure(group: group, expanded: expanded.contains(group.id), theme: theme)
            return cell
        case .sample(let text):
            let cell = sampleCell(tableView)
            cell.configure(text: text, muted: false, theme: theme)
            return cell
        case .more(let count):
            let cell = sampleCell(tableView)
            cell.configure(text: "… \(count) more matching line\(count == 1 ? "" : "s")", muted: true, theme: theme)
            return cell
        }
    }

    private func sampleCell(_ tableView: NSTableView) -> LogSampleLineCell {
        (tableView.makeView(withIdentifier: Self.sampleCellID, owner: nil) as? LogSampleLineCell)
            ?? {
                let v = LogSampleLineCell()
                v.identifier = Self.sampleCellID
                return v
            }()
    }
}

private final class LogErrorGroupCell: NSTableCellView {
    private let row = HelmAccentRow(chipPlacement: .trailing, hover: true)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    func configure(group: LogErrorGroup, expanded: Bool, theme: HelmTheme) {
        var meta = group.occurrenceText
        if let range = group.timeRange { meta += " · \(range)" }
        var content = HelmAccentRow.Content(tint: group.severity.tint,
                                            kicker: group.severity.displayName.uppercased(),
                                            title: group.label)
        content.meta = meta
        content.badgeSymbol = group.severity.symbol
        content.chipText = expanded ? "Hide lines" : "Show lines"
        content.chipTint = .neutral
        content.titleWraps = false
        row.configure(content, theme: theme)
    }
}

private final class LogSampleLineCell: NSTableCellView {
    private let label = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        label.font = HelmType.code()
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 26),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    func configure(text: String, muted: Bool, theme: HelmTheme) {
        label.stringValue = text
        label.textColor = muted
            ? HelmTheme.mutedInk(theme)
            : HelmTheme.nsColor(theme.chromeInkHex).withAlphaComponent(0.85)
    }
}

// MARK: - Timeline (spec §8)

final class LogTimelineListView: NSView {

    static let rowHeight: CGFloat = 52
    static let emptyRowHeight: CGFloat = 130

    let tableView = NSTableView()
    private var events: [LogTimelineEvent] = []
    private var unavailableReason: String?
    private var theme: HelmTheme = ThemeManager.shared.theme
    private var heightConstraint: NSLayoutConstraint!

    var onRevealLine: ((Int) -> Void)?

    private static let columnID = NSUserInterfaceItemIdentifier("logTimelineColumn")
    private static let cellID = NSUserInterfaceItemIdentifier("logTimelineCell")
    private static let emptyID = NSUserInterfaceItemIdentifier("logTimelineEmpty")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        let column = NSTableColumn(identifier: Self.columnID)
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.backgroundColor = .clear
        tableView.selectionHighlightStyle = .none
        tableView.gridStyleMask = []
        tableView.intercellSpacing = NSSize(width: 0, height: 4)
        tableView.rowHeight = Self.rowHeight
        tableView.autoresizingMask = [.width]
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.action = #selector(rowClicked)
        tableView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(tableView)
        heightConstraint = tableView.heightAnchor.constraint(equalToConstant: Self.emptyRowHeight)
        NSLayoutConstraint.activate([
            tableView.leadingAnchor.constraint(equalTo: leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: trailingAnchor),
            tableView.topAnchor.constraint(equalTo: topAnchor),
            tableView.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightConstraint,
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    func setTimeline(_ timeline: LogTimeline, theme: HelmTheme) {
        self.theme = theme
        switch timeline {
        case .unavailable(let reason):
            events = []
            unavailableReason = reason
        case .events(let list):
            events = list
            unavailableReason = list.isEmpty ? "Timeline unavailable — no events found." : nil
        }
        heightConstraint.constant = events.isEmpty
            ? Self.emptyRowHeight
            : CGFloat(events.count) * Self.rowHeight + CGFloat(max(0, events.count - 1)) * 4
        tableView.reloadData()
    }

    func applyTheme(_ theme: HelmTheme) {
        self.theme = theme
        tableView.reloadData()
    }

    @objc private func rowClicked() {
        let index = tableView.clickedRow
        guard index >= 0, index < events.count else { return }
        onRevealLine?(events[index].lineNumber)
    }
}

extension LogTimelineListView: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { events.isEmpty ? 1 : events.count }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        events.isEmpty ? Self.emptyRowHeight : Self.rowHeight
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard !events.isEmpty else {
            let empty = (tableView.makeView(withIdentifier: Self.emptyID, owner: nil) as? HelmEmptyState)
                ?? {
                    let v = HelmEmptyState(symbol: "clock",
                                           title: "Timeline unavailable",
                                           body: unavailableReason ?? "This input does not contain usable timestamps.",
                                           size: .standard, boxed: true)
                    v.identifier = Self.emptyID
                    return v
                }()
            // Spec §8 requires the reason to be stated plainly, and the
            // reason is per-input, so it is re-applied on every render
            // rather than baked in at construction.
            empty.setText(title: "Timeline unavailable",
                          body: unavailableReason ?? "This input does not contain usable timestamps.")
            empty.applyTheme(theme)
            return empty
        }

        let cell = (tableView.makeView(withIdentifier: Self.cellID, owner: nil) as? LogTimelineCell)
            ?? {
                let v = LogTimelineCell()
                v.identifier = Self.cellID
                return v
            }()
        cell.configure(event: events[row], isFirst: row == 0, isLast: row == events.count - 1, theme: theme)
        return cell
    }
}

/// One timeline beat: a dotted rail with a severity dot, a monospace
/// timestamp, and the title/detail pair.
private final class LogTimelineCell: NSTableCellView {
    private let rail = NSView()
    private let dot = NSView()
    private let timeLabel = NSTextField(labelWithString: "")
    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        rail.wantsLayer = true
        rail.translatesAutoresizingMaskIntoConstraints = false
        addSubview(rail)

        dot.wantsLayer = true
        dot.layer?.cornerRadius = 4
        dot.translatesAutoresizingMaskIntoConstraints = false
        addSubview(dot)

        timeLabel.font = .monospacedSystemFont(ofSize: 11, weight: .medium)
        timeLabel.alignment = .right
        timeLabel.translatesAutoresizingMaskIntoConstraints = false
        timeLabel.setContentHuggingPriority(.required, for: .horizontal)
        timeLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        addSubview(timeLabel)

        titleLabel.font = HelmType.rowTitle()
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(titleLabel)

        detailLabel.font = HelmType.caption()
        detailLabel.lineBreakMode = .byTruncatingTail
        detailLabel.translatesAutoresizingMaskIntoConstraints = false
        detailLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(detailLabel)

        NSLayoutConstraint.activate([
            timeLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            timeLabel.widthAnchor.constraint(equalToConstant: 64),
            timeLabel.topAnchor.constraint(equalTo: topAnchor, constant: 8),

            rail.leadingAnchor.constraint(equalTo: timeLabel.trailingAnchor, constant: 12),
            rail.widthAnchor.constraint(equalToConstant: 1),
            rail.topAnchor.constraint(equalTo: topAnchor),
            rail.bottomAnchor.constraint(equalTo: bottomAnchor),

            dot.centerXAnchor.constraint(equalTo: rail.centerXAnchor),
            dot.centerYAnchor.constraint(equalTo: timeLabel.centerYAnchor),
            dot.widthAnchor.constraint(equalToConstant: 8),
            dot.heightAnchor.constraint(equalToConstant: 8),

            titleLabel.leadingAnchor.constraint(equalTo: rail.trailingAnchor, constant: 14),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 7),

            detailLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            detailLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            detailLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 2),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    func configure(event: LogTimelineEvent, isFirst: Bool, isLast: Bool, theme: HelmTheme) {
        timeLabel.stringValue = event.timestamp
        timeLabel.textColor = HelmTheme.mutedInk(theme)
        titleLabel.stringValue = event.title
        titleLabel.textColor = HelmTheme.nsColor(theme.chromeInkHex)
        detailLabel.stringValue = event.detail
        detailLabel.textColor = HelmTheme.mutedInk(theme)

        let hue = HelmTheme.nsColor(event.severity.tint.hex(in: theme))
        dot.layer?.backgroundColor = hue.cgColor
        rail.layer?.backgroundColor = HelmTheme.nsColor(theme.chromeLineHex).withAlphaComponent(0.7).cgColor
        rail.isHidden = isFirst && isLast
    }
}

// MARK: - Correlation (spec §9)

final class LogCorrelationListView: NSView {

    static let rowHeight: CGFloat = 56
    static let emptyRowHeight: CGFloat = 130

    let tableView = NSTableView()
    private var links: [LogCorrelationLink] = []
    private var theme: HelmTheme = ThemeManager.shared.theme
    private var heightConstraint: NSLayoutConstraint!

    private static let columnID = NSUserInterfaceItemIdentifier("logCorrelationColumn")
    private static let cellID = NSUserInterfaceItemIdentifier("logCorrelationCell")
    private static let emptyID = NSUserInterfaceItemIdentifier("logCorrelationEmpty")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        let column = NSTableColumn(identifier: Self.columnID)
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.backgroundColor = .clear
        tableView.selectionHighlightStyle = .none
        tableView.gridStyleMask = []
        tableView.intercellSpacing = NSSize(width: 0, height: 6)
        tableView.rowHeight = Self.rowHeight
        tableView.autoresizingMask = [.width]
        tableView.dataSource = self
        tableView.delegate = self
        tableView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(tableView)
        heightConstraint = tableView.heightAnchor.constraint(equalToConstant: Self.emptyRowHeight)
        NSLayoutConstraint.activate([
            tableView.leadingAnchor.constraint(equalTo: leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: trailingAnchor),
            tableView.topAnchor.constraint(equalTo: topAnchor),
            tableView.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightConstraint,
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    func setLinks(_ links: [LogCorrelationLink], theme: HelmTheme) {
        self.links = links
        self.theme = theme
        heightConstraint.constant = links.isEmpty
            ? Self.emptyRowHeight
            : CGFloat(links.count) * Self.rowHeight + CGFloat(max(0, links.count - 1)) * 6
        tableView.reloadData()
    }

    func applyTheme(_ theme: HelmTheme) {
        self.theme = theme
        tableView.reloadData()
    }
}

extension LogCorrelationListView: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { links.isEmpty ? 1 : links.count }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        links.isEmpty ? Self.emptyRowHeight : Self.rowHeight
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard !links.isEmpty else {
            let empty = (tableView.makeView(withIdentifier: Self.emptyID, owner: nil) as? HelmEmptyState)
                ?? {
                    let v = HelmEmptyState(symbol: "arrow.triangle.branch",
                                           title: "No correlation yet",
                                           body: "Run an analysis to see what the provided output does and does not establish.",
                                           size: .standard, boxed: true)
                    v.identifier = Self.emptyID
                    return v
                }()
            empty.applyTheme(theme)
            return empty
        }

        let cell = (tableView.makeView(withIdentifier: Self.cellID, owner: nil) as? LogCorrelationCell)
            ?? {
                let v = LogCorrelationCell()
                v.identifier = Self.cellID
                return v
            }()
        cell.configure(link: links[row], theme: theme)
        return cell
    }
}

private final class LogCorrelationCell: NSTableCellView {
    private let row = HelmAccentRow(chipPlacement: .trailing, hover: false)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    func configure(link: LogCorrelationLink, theme: HelmTheme) {
        var content = HelmAccentRow.Content(tint: link.kind.tint,
                                            kicker: link.kind.displayName.uppercased(),
                                            title: link.text)
        content.meta = link.evidence ?? link.kind.detail
        content.badgeSymbol = link.kind == .observed ? "checkmark"
            : (link.kind == .inferred ? "arrow.triangle.branch" : "questionmark")
        content.titleWraps = true
        row.configure(content, theme: theme)
    }
}

// MARK: - Generic HelmAccentRow-backed list

/// A small, shared table for the three lists whose rows are all just a
/// `HelmAccentRow` with different content: findings, evidence and history.
/// Each caller supplies the content mapping and (optionally) a click
/// handler; the table plumbing is written once rather than three times.
final class LogAccentRowListView: NSView {

    let tableView = NSTableView()
    private var contents: [HelmAccentRow.Content] = []
    private var theme: HelmTheme = ThemeManager.shared.theme
    private var heightConstraint: NSLayoutConstraint!
    private let rowHeight: CGFloat
    private let emptyState: HelmEmptyState

    var onSelect: ((Int) -> Void)?

    private static let columnID = NSUserInterfaceItemIdentifier("logAccentColumn")
    private static let cellID = NSUserInterfaceItemIdentifier("logAccentCell")

    init(rowHeight: CGFloat = 70, emptySymbol: String, emptyTitle: String, emptyBody: String) {
        self.rowHeight = rowHeight
        self.emptyState = HelmEmptyState(symbol: emptySymbol, title: emptyTitle, body: emptyBody,
                                         size: .standard, boxed: true)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        let column = NSTableColumn(identifier: Self.columnID)
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.backgroundColor = .clear
        tableView.selectionHighlightStyle = .none
        tableView.gridStyleMask = []
        tableView.intercellSpacing = NSSize(width: 0, height: 8)
        tableView.rowHeight = rowHeight
        tableView.autoresizingMask = [.width]
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.action = #selector(rowClicked)
        tableView.translatesAutoresizingMaskIntoConstraints = false

        addSubview(tableView)
        heightConstraint = tableView.heightAnchor.constraint(equalToConstant: 130)
        NSLayoutConstraint.activate([
            tableView.leadingAnchor.constraint(equalTo: leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: trailingAnchor),
            tableView.topAnchor.constraint(equalTo: topAnchor),
            tableView.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightConstraint,
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    func setContents(_ contents: [HelmAccentRow.Content], theme: HelmTheme) {
        self.contents = contents
        self.theme = theme
        heightConstraint.constant = contents.isEmpty
            ? 130
            : CGFloat(contents.count) * rowHeight + CGFloat(max(0, contents.count - 1)) * 8
        tableView.reloadData()
    }

    func setEmptyText(title: String, body: String) {
        emptyState.setText(title: title, body: body)
    }

    func applyTheme(_ theme: HelmTheme) {
        self.theme = theme
        emptyState.applyTheme(theme)
        tableView.reloadData()
    }

    var count: Int { contents.count }

    @objc private func rowClicked() {
        let index = tableView.clickedRow
        guard index >= 0, index < contents.count else { return }
        onSelect?(index)
    }
}

extension LogAccentRowListView: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { contents.isEmpty ? 1 : contents.count }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        contents.isEmpty ? 130 : rowHeight
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard !contents.isEmpty else {
            emptyState.applyTheme(theme)
            return emptyState
        }
        let cell = (tableView.makeView(withIdentifier: Self.cellID, owner: nil) as? LogAccentRowCell)
            ?? {
                let v = LogAccentRowCell()
                v.identifier = Self.cellID
                return v
            }()
        cell.configure(contents[row], theme: theme)
        return cell
    }
}

private final class LogAccentRowCell: NSTableCellView {
    private let row = HelmAccentRow(chipPlacement: .trailing, hover: true)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    func configure(_ content: HelmAccentRow.Content, theme: HelmTheme) {
        row.configure(content, theme: theme)
    }
}
