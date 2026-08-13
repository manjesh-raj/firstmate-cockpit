// Manjesh Grand Line - native macOS app.
//
// Table-view-based list rendering for Shift's task and follow-up lists
// (cockpit-shift-foundation). Both classes follow `DiffResultView.swift`'s
// established shape verbatim: a single-column, view-based `NSTableView`
// (never a plain `NSStackView` of one permanent row per item), because a
// growing task/follow-up list is exactly the shape that blew up into a
// 13-second layout pass there once it hit a few hundred rows - see
// `DiffResultView.swift`'s header for the full measured writeup. An
// `NSTableView` only builds row views for what's actually visible, so this
// stays fast regardless of how many months of tasks accumulate.

import AppKit

// MARK: - Task list

final class ShiftTaskListView: NSObject {
    let tableView = NSTableView()

    private var theme: HelmTheme = ThemeManager.shared.theme
    private var tasks: [ShiftTask] = []
    private var projectsByID: [String: ShiftProject] = [:]
    var onToggleCompleted: ((ShiftTask) -> Void)?

    private static let columnID = NSUserInterfaceItemIdentifier("shiftTaskCol")
    private static let rowViewID = NSUserInterfaceItemIdentifier("shiftTaskRow")
    private static let emptyViewID = NSUserInterfaceItemIdentifier("shiftTaskEmpty")

    override init() {
        super.init()
        let column = NSTableColumn(identifier: Self.columnID)
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.backgroundColor = .clear
        tableView.selectionHighlightStyle = .none
        tableView.gridStyleMask = []
        tableView.intercellSpacing = NSSize(width: 0, height: 4)
        tableView.autoresizingMask = [.width]
        tableView.rowHeight = 44
        tableView.dataSource = self
        tableView.delegate = self
    }

    func setTasks(_ tasks: [ShiftTask], projects: [ShiftProject]) {
        self.tasks = tasks
        self.projectsByID = Dictionary(uniqueKeysWithValues: projects.map { ($0.id, $0) })
        tableView.reloadData()
    }

    func applyTheme(_ theme: HelmTheme) {
        self.theme = theme
        tableView.reloadData()
    }
}

extension ShiftTaskListView: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { max(tasks.count, 1) }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard !tasks.isEmpty else {
            let label = (tableView.makeView(withIdentifier: Self.emptyViewID, owner: nil) as? NSTextField)
                ?? { let l = NSTextField(labelWithString: ""); l.identifier = Self.emptyViewID; return l }()
            label.stringValue = "Nothing on your plate. Enjoy it."
            label.font = .systemFont(ofSize: 12)
            label.textColor = HelmTheme.mutedInk(theme)
            return label
        }
        let rowView = (tableView.makeView(withIdentifier: Self.rowViewID, owner: nil) as? ShiftTaskRowView)
            ?? { let v = ShiftTaskRowView(); v.identifier = Self.rowViewID; return v }()
        let task = tasks[row]
        rowView.configure(task: task, project: task.projectID.flatMap { projectsByID[$0] }, theme: theme) { [weak self] in
            self?.onToggleCompleted?(task)
        }
        return rowView
    }
}

private final class ShiftTaskRowView: NSView {
    private let checkbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let titleLabel = NSTextField(labelWithString: "")
    private let subLabel = NSTextField(labelWithString: "")
    private let priorityPill = NSView()
    private let priorityLabel = NSTextField(labelWithString: "")
    private var onToggle: (() -> Void)?

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        checkbox.target = self
        checkbox.action = #selector(checkboxClicked)
        checkbox.translatesAutoresizingMaskIntoConstraints = false
        checkbox.setContentHuggingPriority(.required, for: .horizontal)

        titleLabel.font = .systemFont(ofSize: 13, weight: .medium)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1

        subLabel.font = .systemFont(ofSize: 10.5)
        subLabel.lineBreakMode = .byTruncatingTail
        subLabel.maximumNumberOfLines = 1

        let textStack = NSStackView(views: [titleLabel, subLabel])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 2
        textStack.setContentHuggingPriority(.defaultLow, for: .horizontal)
        textStack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        priorityLabel.font = .systemFont(ofSize: 10, weight: .semibold)
        priorityLabel.translatesAutoresizingMaskIntoConstraints = false
        priorityPill.wantsLayer = true
        priorityPill.layer?.cornerRadius = 8
        priorityPill.translatesAutoresizingMaskIntoConstraints = false
        priorityPill.addSubview(priorityLabel)
        NSLayoutConstraint.activate([
            priorityLabel.leadingAnchor.constraint(equalTo: priorityPill.leadingAnchor, constant: 7),
            priorityLabel.trailingAnchor.constraint(equalTo: priorityPill.trailingAnchor, constant: -7),
            priorityLabel.topAnchor.constraint(equalTo: priorityPill.topAnchor, constant: 2),
            priorityLabel.bottomAnchor.constraint(equalTo: priorityPill.bottomAnchor, constant: -2),
        ])
        priorityPill.setContentHuggingPriority(.required, for: .horizontal)
        priorityPill.setContentCompressionResistancePriority(.required, for: .horizontal)

        let row = NSStackView(views: [checkbox, textStack, priorityPill])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        row.distribution = .fill
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    func configure(task: ShiftTask, project: ShiftProject?, theme: HelmTheme, onToggle: @escaping () -> Void) {
        self.onToggle = onToggle
        checkbox.state = task.status == .completed ? .on : .off

        titleLabel.stringValue = task.title
        titleLabel.textColor = HelmTheme.nsColor(theme.chromeInkHex)

        var bits: [String] = []
        if let due = task.dueDate { bits.append(ShiftDateFormatting.friendly(due)) }
        if let project { bits.append(project.name) }
        if !task.subtasks.isEmpty {
            let done = task.subtasks.filter(\.done).count
            bits.append("\(done)/\(task.subtasks.count) subtasks")
        }
        subLabel.stringValue = bits.joined(separator: " \u{00B7} ")
        subLabel.textColor = HelmTheme.mutedInk(theme)

        let (text, tint): (String, HelmTint) = {
            switch task.priority {
            case .high: return ("High", .critical)
            case .normal: return ("Normal", .info)
            case .low: return ("Low", .neutral)
            }
        }()
        priorityLabel.stringValue = text
        let color = HelmTheme.nsColor(tint.hex(in: theme))
        priorityLabel.textColor = color
        priorityPill.layer?.backgroundColor = color.withAlphaComponent(0.15).cgColor
    }

    @objc private func checkboxClicked() { onToggle?() }
}

// MARK: - Follow-up list

final class ShiftFollowUpListView: NSObject {
    let tableView = NSTableView()

    private var theme: HelmTheme = ThemeManager.shared.theme
    private var items: [ShiftFollowUp] = []

    private static let columnID = NSUserInterfaceItemIdentifier("shiftFollowUpCol")
    private static let rowViewID = NSUserInterfaceItemIdentifier("shiftFollowUpRow")
    private static let emptyViewID = NSUserInterfaceItemIdentifier("shiftFollowUpEmpty")

    override init() {
        super.init()
        let column = NSTableColumn(identifier: Self.columnID)
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.backgroundColor = .clear
        tableView.selectionHighlightStyle = .none
        tableView.gridStyleMask = []
        tableView.intercellSpacing = NSSize(width: 0, height: 4)
        tableView.autoresizingMask = [.width]
        tableView.rowHeight = 40
        tableView.dataSource = self
        tableView.delegate = self
    }

    func setItems(_ items: [ShiftFollowUp]) {
        self.items = items
        tableView.reloadData()
    }

    func applyTheme(_ theme: HelmTheme) {
        self.theme = theme
        tableView.reloadData()
    }
}

extension ShiftFollowUpListView: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { max(items.count, 1) }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard !items.isEmpty else {
            let label = (tableView.makeView(withIdentifier: Self.emptyViewID, owner: nil) as? NSTextField)
                ?? { let l = NSTextField(labelWithString: ""); l.identifier = Self.emptyViewID; return l }()
            label.stringValue = "No follow-ups pending."
            label.font = .systemFont(ofSize: 12)
            label.textColor = HelmTheme.mutedInk(theme)
            return label
        }
        let rowView = (tableView.makeView(withIdentifier: Self.rowViewID, owner: nil) as? ShiftFollowUpRowView)
            ?? { let v = ShiftFollowUpRowView(); v.identifier = Self.rowViewID; return v }()
        rowView.configure(item: items[row], theme: theme)
        return rowView
    }
}

private final class ShiftFollowUpRowView: NSView {
    private let dot = NSView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let subLabel = NSTextField(labelWithString: "")
    private let statusPill = NSView()
    private let statusLabel = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        dot.wantsLayer = true
        dot.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            dot.widthAnchor.constraint(equalToConstant: 8),
            dot.heightAnchor.constraint(equalToConstant: 8),
        ])
        dot.setContentHuggingPriority(.required, for: .horizontal)

        titleLabel.font = .systemFont(ofSize: 13, weight: .medium)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1

        subLabel.font = .systemFont(ofSize: 10.5)
        subLabel.lineBreakMode = .byTruncatingTail
        subLabel.maximumNumberOfLines = 1

        let textStack = NSStackView(views: [titleLabel, subLabel])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 2
        textStack.setContentHuggingPriority(.defaultLow, for: .horizontal)
        textStack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        statusLabel.font = .systemFont(ofSize: 10, weight: .semibold)
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusPill.wantsLayer = true
        statusPill.layer?.cornerRadius = 8
        statusPill.translatesAutoresizingMaskIntoConstraints = false
        statusPill.addSubview(statusLabel)
        NSLayoutConstraint.activate([
            statusLabel.leadingAnchor.constraint(equalTo: statusPill.leadingAnchor, constant: 7),
            statusLabel.trailingAnchor.constraint(equalTo: statusPill.trailingAnchor, constant: -7),
            statusLabel.topAnchor.constraint(equalTo: statusPill.topAnchor, constant: 2),
            statusLabel.bottomAnchor.constraint(equalTo: statusPill.bottomAnchor, constant: -2),
        ])
        statusPill.setContentHuggingPriority(.required, for: .horizontal)
        statusPill.setContentCompressionResistancePriority(.required, for: .horizontal)

        let row = NSStackView(views: [dot, textStack, statusPill])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        row.distribution = .fill
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    func configure(item: ShiftFollowUp, theme: HelmTheme) {
        titleLabel.stringValue = item.title
        titleLabel.textColor = HelmTheme.nsColor(theme.chromeInkHex)

        var bits: [String] = []
        if let at = item.followUpAt { bits.append(ShiftDateFormatting.friendly(at)) }
        subLabel.stringValue = bits.joined(separator: " \u{00B7} ")
        subLabel.textColor = HelmTheme.mutedInk(theme)

        let priorityTint: HelmTint = {
            switch item.priority {
            case .high: return .critical
            case .normal: return .info
            case .low: return .neutral
            }
        }()
        dot.layer?.cornerRadius = 4
        dot.layer?.backgroundColor = HelmTheme.nsColor(priorityTint.hex(in: theme)).cgColor

        let statusTint: HelmTint = item.status == .done ? .good : .warn
        statusLabel.stringValue = item.status == .done ? "Done" : "Pending"
        let color = HelmTheme.nsColor(statusTint.hex(in: theme))
        statusLabel.textColor = color
        statusPill.layer?.backgroundColor = color.withAlphaComponent(0.15).cgColor
    }
}

// MARK: - Shared date formatting

enum ShiftDateFormatting {
    private static let iso: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.calendar = Calendar(identifier: .gregorian)
        return f
    }()

    static func date(from yyyyMMdd: String) -> Date? { iso.date(from: yyyyMMdd) }

    /// "Today" / "Tomorrow" / "Aug 12" - never a raw ISO string in the UI.
    static func friendly(_ yyyyMMdd: String) -> String {
        guard let date = date(from: yyyyMMdd) else { return yyyyMMdd }
        let cal = Calendar.current
        if cal.isDateInToday(date) { return "Today" }
        if cal.isDateInTomorrow(date) { return "Tomorrow" }
        if cal.isDateInYesterday(date) { return "Yesterday" }
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("MMMd")
        return f.string(from: date)
    }
}
