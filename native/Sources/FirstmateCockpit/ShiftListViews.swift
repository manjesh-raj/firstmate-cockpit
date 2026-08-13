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
    /// Double-clicking a row (anywhere but the checkbox) opens the Edit Task
    /// sheet, pre-filled - phase 2's "clicking an existing task" behavior.
    var onOpen: ((ShiftTask) -> Void)?

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
        tableView.target = self
        tableView.doubleAction = #selector(rowDoubleClicked)
    }

    @objc private func rowDoubleClicked() {
        let row = tableView.clickedRow
        guard row >= 0, row < tasks.count else { return }
        onOpen?(tasks[row])
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

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        tasks.isEmpty ? 120 : 44
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard !tasks.isEmpty else {
            let empty = (tableView.makeView(withIdentifier: Self.emptyViewID, owner: nil) as? ShiftEmptyStateView)
                ?? { let v = ShiftEmptyStateView(symbol: "checklist", text: "Nothing on your plate. Enjoy it."); v.identifier = Self.emptyViewID; return v }()
            empty.applyTheme(theme)
            return empty
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
    private let hoverBackground = HoverHighlightView()
    private let checkbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let titleLabel = NSTextField(labelWithString: "")
    private let subLabel = NSTextField(labelWithString: "")
    private let priorityPill = NSView()
    private let priorityLabel = NSTextField(labelWithString: "")
    private var onToggle: (() -> Void)?

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        hoverBackground.cornerRadius = 6
        hoverBackground.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hoverBackground)
        NSLayoutConstraint.activate([
            hoverBackground.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            hoverBackground.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            hoverBackground.topAnchor.constraint(equalTo: topAnchor, constant: 1),
            hoverBackground.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -1),
        ])

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

        priorityLabel.font = ShiftFont.mono(10, weight: .semibold)
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
        hoverBackground.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: hoverBackground.leadingAnchor, constant: 6),
            row.trailingAnchor.constraint(equalTo: hoverBackground.trailingAnchor, constant: -6),
            row.centerYAnchor.constraint(equalTo: hoverBackground.centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    func configure(task: ShiftTask, project: ShiftProject?, theme: HelmTheme, onToggle: @escaping () -> Void) {
        self.onToggle = onToggle
        hoverBackground.normalColor = .clear
        hoverBackground.hoverColor = HelmTheme.nsColor(theme.chromeLineHex).withAlphaComponent(0.16)
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

/// The Snooze preset options (phase 2 acceptance criteria). `.custom` opens a
/// small date/time picker sheet - `ShiftController` owns presenting it, since
/// this list view has no window context of its own.
enum ShiftSnoozeOption {
    case minutes30, hour1, tomorrow, nextWeek, custom
}

final class ShiftFollowUpListView: NSObject {
    let tableView = NSTableView()

    private var theme: HelmTheme = ThemeManager.shared.theme
    private var items: [ShiftFollowUp] = []

    /// Edit (double-click, or the context menu's Edit item).
    var onEdit: ((ShiftFollowUp) -> Void)?
    /// Done (toggles pending <-> done).
    var onToggleDone: ((ShiftFollowUp) -> Void)?
    /// Snooze - the concrete recompute/persist happens in `ShiftController`,
    /// which knows "now" and how to present the Custom picker.
    var onSnooze: ((ShiftFollowUp, ShiftSnoozeOption) -> Void)?

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
        tableView.target = self
        tableView.doubleAction = #selector(rowDoubleClicked)
        tableView.menu = rowMenu()
    }

    func setItems(_ items: [ShiftFollowUp]) {
        self.items = items
        tableView.reloadData()
    }

    func applyTheme(_ theme: HelmTheme) {
        self.theme = theme
        tableView.reloadData()
    }

    @objc private func rowDoubleClicked() {
        let row = tableView.clickedRow
        guard row >= 0, row < items.count else { return }
        onEdit?(items[row])
    }

    private var clickedItem: ShiftFollowUp? {
        let row = tableView.clickedRow
        guard row >= 0, row < items.count else { return nil }
        return items[row]
    }

    private func rowMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Mark Done", action: #selector(doneClicked), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Reopen", action: #selector(reopenClicked), keyEquivalent: ""))
        menu.addItem(.separator())
        let snooze = NSMenuItem(title: "Snooze", action: nil, keyEquivalent: "")
        let snoozeMenu = NSMenu()
        snoozeMenu.addItem(NSMenuItem(title: "30 Minutes", action: #selector(snooze30), keyEquivalent: ""))
        snoozeMenu.addItem(NSMenuItem(title: "1 Hour", action: #selector(snoozeHour), keyEquivalent: ""))
        snoozeMenu.addItem(NSMenuItem(title: "Tomorrow", action: #selector(snoozeTomorrow), keyEquivalent: ""))
        snoozeMenu.addItem(NSMenuItem(title: "Next Week", action: #selector(snoozeNextWeek), keyEquivalent: ""))
        snoozeMenu.addItem(.separator())
        snoozeMenu.addItem(NSMenuItem(title: "Custom\u{2026}", action: #selector(snoozeCustom), keyEquivalent: ""))
        for item in snoozeMenu.items { item.target = self }
        snooze.submenu = snoozeMenu
        menu.addItem(snooze)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Edit\u{2026}", action: #selector(editClicked), keyEquivalent: ""))
        for item in menu.items { item.target = self }
        menu.delegate = self
        return menu
    }

    @objc private func doneClicked() { if let item = clickedItem { onToggleDone?(item) } }
    @objc private func reopenClicked() { if let item = clickedItem { onToggleDone?(item) } }
    @objc private func editClicked() { if let item = clickedItem { onEdit?(item) } }
    @objc private func snooze30() { if let item = clickedItem { onSnooze?(item, .minutes30) } }
    @objc private func snoozeHour() { if let item = clickedItem { onSnooze?(item, .hour1) } }
    @objc private func snoozeTomorrow() { if let item = clickedItem { onSnooze?(item, .tomorrow) } }
    @objc private func snoozeNextWeek() { if let item = clickedItem { onSnooze?(item, .nextWeek) } }
    @objc private func snoozeCustom() { if let item = clickedItem { onSnooze?(item, .custom) } }
}

extension ShiftFollowUpListView: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        let isDone = clickedItem?.status == .done
        for item in menu.items {
            switch item.action {
            case #selector(doneClicked): item.isHidden = isDone
            case #selector(reopenClicked): item.isHidden = !isDone
            default: break
            }
        }
    }
}

extension ShiftFollowUpListView: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { max(items.count, 1) }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        items.isEmpty ? 110 : 40
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard !items.isEmpty else {
            let empty = (tableView.makeView(withIdentifier: Self.emptyViewID, owner: nil) as? ShiftEmptyStateView)
                ?? { let v = ShiftEmptyStateView(symbol: "bell", text: "No follow-ups pending."); v.identifier = Self.emptyViewID; return v }()
            empty.applyTheme(theme)
            return empty
        }
        let rowView = (tableView.makeView(withIdentifier: Self.rowViewID, owner: nil) as? ShiftFollowUpRowView)
            ?? { let v = ShiftFollowUpRowView(); v.identifier = Self.rowViewID; return v }()
        rowView.configure(item: items[row], theme: theme)
        return rowView
    }
}

private final class ShiftFollowUpRowView: NSView {
    private let hoverBackground = HoverHighlightView()
    private let dot = NSView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let subLabel = NSTextField(labelWithString: "")
    private let statusPill = NSView()
    private let statusLabel = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        hoverBackground.cornerRadius = 6
        hoverBackground.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hoverBackground)
        NSLayoutConstraint.activate([
            hoverBackground.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            hoverBackground.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            hoverBackground.topAnchor.constraint(equalTo: topAnchor, constant: 1),
            hoverBackground.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -1),
        ])

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

        statusLabel.font = ShiftFont.mono(10, weight: .semibold)
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
        hoverBackground.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: hoverBackground.leadingAnchor, constant: 6),
            row.trailingAnchor.constraint(equalTo: hoverBackground.trailingAnchor, constant: -6),
            row.centerYAnchor.constraint(equalTo: hoverBackground.centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    func configure(item: ShiftFollowUp, theme: HelmTheme) {
        hoverBackground.normalColor = .clear
        hoverBackground.hoverColor = HelmTheme.nsColor(theme.chromeLineHex).withAlphaComponent(0.16)
        titleLabel.stringValue = item.title
        titleLabel.textColor = HelmTheme.nsColor(theme.chromeInkHex)

        var bits: [String] = []
        if let at = item.followUpAt { bits.append(ShiftDateFormatting.friendly(at, time: item.followUpTime)) }
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

    private static let hhmm: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        f.calendar = Calendar(identifier: .gregorian)
        return f
    }()

    private static let friendlyTime: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("jm")
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

    /// "Today at 3:00 PM" / "Aug 12" (no time shown when `hhmm` is nil).
    static func friendly(_ yyyyMMdd: String, time hhmmStr: String?) -> String {
        let dayPart = friendly(yyyyMMdd)
        guard let hhmmStr, let t = hhmm.date(from: hhmmStr) else { return dayPart }
        return "\(dayPart) at \(friendlyTime.string(from: t))"
    }

    /// Combines a `"YYYY-MM-DD"` date string with an optional `"HH:MM"` time
    /// string into one `Date` - the shared "read the two persisted scalar
    /// fields back into a real moment in time" used by both sorting (task due
    /// dates) and Snooze's relative-offset math (follow-up date + time).
    /// Falls back to local midnight when `timeStr` is nil/unparseable.
    static func dateTime(from yyyyMMdd: String?, time timeStr: String?) -> Date? {
        guard let yyyyMMdd, let base = date(from: yyyyMMdd) else { return nil }
        guard let timeStr, let t = hhmm.date(from: timeStr) else { return base }
        var comps = Calendar.current.dateComponents([.year, .month, .day], from: base)
        let timeComps = Calendar.current.dateComponents([.hour, .minute], from: t)
        comps.hour = timeComps.hour
        comps.minute = timeComps.minute
        return Calendar.current.date(from: comps)
    }

    /// Splits a real `Date` back into the `("YYYY-MM-DD", "HH:MM")` pair the
    /// YAML layer persists - the inverse of `dateTime(from:time:)`, used by
    /// Snooze to write its recomputed moment back to the two scalar fields.
    static func components(from date: Date) -> (dateStr: String, timeStr: String) {
        (iso.string(from: date), hhmm.string(from: date))
    }
}
