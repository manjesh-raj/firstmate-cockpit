// Manjesh Grand Line - native macOS app.
//
// The project detail page's task list (fm/cockpit-shift-project-page-
// redesign). The captain rejected phase 3's original detail view outright -
// a cramped inline form with plain-stacked-checkbox subtasks that "doesn't
// feel like a real page" - and asked for it to read like clicking into a
// Tool on the Tools page instead: a real, clean, dedicated view. See
// AGENTS.md's "Shift" section for the full history this redesign supersedes.
//
// `ShiftProjectTaskListView` replaces `ShiftController`'s old
// `detailTaskBlock`/`rebuildDetailTasks` (an `NSStackView` of hand-built rows,
// rebuilt from scratch on every render) with an `NSTableView`-based list,
// following `ShiftListViews.swift`'s own established convention for the same
// reason documented there: an `NSStackView` of many permanent rows is the
// exact shape that blew up into a 13-second layout pass in `DiffResultView`'s
// history once row counts grew, and a project's task list has no natural
// upper bound. `NSTableView` has no first-class notion of a nested child row,
// so a task's subtasks are flattened into the same row list as
// `.subtask(taskID:subtask:)` entries that only appear while that task's id
// is in the caller-supplied `expandedTaskIDs` set - the same expand/collapse
// state `ShiftController` already tracked, just rendered through a
// table instead of a stack.

import AppKit

private enum ShiftProjectTaskRow {
    case task(ShiftTask)
    case subtask(taskID: String, subtask: ShiftSubtask)
    case noSubtasks(taskID: String)
}

final class ShiftProjectTaskListView: NSObject {
    let tableView = NSTableView()

    private var theme: HelmTheme = ThemeManager.shared.theme
    private var tasks: [ShiftTask] = []
    private var expandedTaskIDs: Set<String> = []
    private var rows: [ShiftProjectTaskRow] = []

    /// Expand/collapse a task's subtasks - `ShiftController` owns the actual
    /// `expandedTaskIDs` set (it survives across a `render()` the same way it
    /// did before this redesign) and calls `setTasks` again with the updated
    /// set.
    var onToggleExpand: ((String) -> Void)?
    var onToggleTaskCompleted: ((ShiftTask) -> Void)?
    var onToggleSubtask: ((String, String, Bool) -> Void)?
    /// Double-clicking a task row opens the same Edit Task sheet the main My
    /// Tasks list uses - one "open this task" behavior everywhere in Shift.
    var onOpenTask: ((ShiftTask) -> Void)?

    private static let columnID = NSUserInterfaceItemIdentifier("shiftProjTaskCol")
    private static let taskRowID = NSUserInterfaceItemIdentifier("shiftProjTaskRow")
    private static let subtaskRowID = NSUserInterfaceItemIdentifier("shiftProjSubtaskRow")
    private static let noSubtaskRowID = NSUserInterfaceItemIdentifier("shiftProjNoSubtaskRow")
    private static let emptyViewID = NSUserInterfaceItemIdentifier("shiftProjTaskEmpty")

    override init() {
        super.init()
        let column = NSTableColumn(identifier: Self.columnID)
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.backgroundColor = .clear
        tableView.selectionHighlightStyle = .none
        tableView.gridStyleMask = []
        tableView.intercellSpacing = NSSize(width: 0, height: 2)
        tableView.autoresizingMask = [.width]
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(rowDoubleClicked)
    }

    func setTasks(_ tasks: [ShiftTask], expandedTaskIDs: Set<String>) {
        self.tasks = tasks
        self.expandedTaskIDs = expandedTaskIDs
        rebuildRows()
        tableView.reloadData()
    }

    func applyTheme(_ theme: HelmTheme) {
        self.theme = theme
        tableView.reloadData()
    }

    private func rebuildRows() {
        var result: [ShiftProjectTaskRow] = []
        for task in tasks {
            result.append(.task(task))
            guard expandedTaskIDs.contains(task.id) else { continue }
            if task.subtasks.isEmpty {
                result.append(.noSubtasks(taskID: task.id))
            } else {
                for subtask in task.subtasks {
                    result.append(.subtask(taskID: task.id, subtask: subtask))
                }
            }
        }
        rows = result
    }

    @objc private func rowDoubleClicked() {
        let row = tableView.clickedRow
        guard row >= 0, row < rows.count, case .task(let task) = rows[row] else { return }
        onOpenTask?(task)
    }
}

extension ShiftProjectTaskListView: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { max(rows.count, 1) }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        guard !rows.isEmpty else { return 130 }
        switch rows[row] {
        case .task: return 46
        case .subtask: return 30
        case .noSubtasks: return 24
        }
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard !rows.isEmpty else {
            let empty = (tableView.makeView(withIdentifier: Self.emptyViewID, owner: nil) as? HelmEmptyState)
                ?? {
                    let v = HelmEmptyState(symbol: "checklist", body: "No tasks in this project yet.\nAdd one to start tracking work here.")
                    v.identifier = Self.emptyViewID
                    return v
                }()
            empty.applyTheme(theme)
            return empty
        }
        switch rows[row] {
        case .task(let task):
            let rowView = (tableView.makeView(withIdentifier: Self.taskRowID, owner: nil) as? ShiftProjectTaskRowView)
                ?? { let v = ShiftProjectTaskRowView(); v.identifier = Self.taskRowID; return v }()
            rowView.configure(
                task: task, expanded: expandedTaskIDs.contains(task.id), theme: theme,
                onToggleExpand: { [weak self] in self?.onToggleExpand?(task.id) },
                onToggleCompleted: { [weak self] in self?.onToggleTaskCompleted?(task) }
            )
            return rowView
        case .subtask(let taskID, let subtask):
            let rowView = (tableView.makeView(withIdentifier: Self.subtaskRowID, owner: nil) as? ShiftProjectSubtaskRowView)
                ?? { let v = ShiftProjectSubtaskRowView(); v.identifier = Self.subtaskRowID; return v }()
            rowView.configure(subtask: subtask, theme: theme) { [weak self] done in
                self?.onToggleSubtask?(taskID, subtask.id, done)
            }
            return rowView
        case .noSubtasks:
            let rowView = (tableView.makeView(withIdentifier: Self.noSubtaskRowID, owner: nil) as? ShiftProjectNoSubtasksRowView)
                ?? { let v = ShiftProjectNoSubtasksRowView(); v.identifier = Self.noSubtaskRowID; return v }()
            rowView.applyTheme(theme)
            return rowView
        }
    }
}

/// A top-level task row: an expand chevron (only interactive/visible when the
/// task actually has subtasks - kept in the layout either way so every row's
/// title stays aligned to the same leading edge), a completion checkbox
/// (wired straight to `ShiftStore.setTaskCompleted`, matching the main My
/// Tasks list), title, and a meta line (due date / subtask progress /
/// "Completed").
private final class ShiftProjectTaskRowView: NSView {
    private let hoverBackground = HoverHighlightView()
    private let chevronButton = NSButton()
    private let checkbox = ShiftTaskCheckBadge()
    private let titleLabel = NSTextField(labelWithString: "")
    private let subLabel = NSTextField(labelWithString: "")
    private var onToggleExpand: (() -> Void)?
    private var onToggleCompleted: (() -> Void)?

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

        chevronButton.isBordered = false
        chevronButton.title = ""
        chevronButton.target = self
        chevronButton.action = #selector(chevronClicked)
        chevronButton.translatesAutoresizingMaskIntoConstraints = false
        chevronButton.setContentHuggingPriority(.required, for: .horizontal)
        chevronButton.widthAnchor.constraint(equalToConstant: 16).isActive = true

        checkbox.target = self
        checkbox.action = #selector(checkboxClicked)
        checkbox.translatesAutoresizingMaskIntoConstraints = false
        checkbox.setContentHuggingPriority(.required, for: .horizontal)

        titleLabel.font = .systemFont(ofSize: 12.5, weight: .medium)
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

        let row = NSStackView(views: [chevronButton, checkbox, textStack])
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

    func configure(
        task: ShiftTask, expanded: Bool, theme: HelmTheme,
        onToggleExpand: @escaping () -> Void, onToggleCompleted: @escaping () -> Void
    ) {
        self.onToggleExpand = onToggleExpand
        self.onToggleCompleted = onToggleCompleted
        hoverBackground.normalColor = .clear
        hoverBackground.hoverColor = HelmTheme.nsColor(theme.chromeLineHex).withAlphaComponent(0.16)

        let hasSubtasks = !task.subtasks.isEmpty
        chevronButton.image = NSImage(
            systemSymbolName: expanded ? "chevron.down" : "chevron.right", accessibilityDescription: nil
        )?.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 9, weight: .semibold))
        chevronButton.contentTintColor = HelmTheme.mutedInk(theme)
        chevronButton.alphaValue = hasSubtasks ? 1 : 0
        chevronButton.isEnabled = hasSubtasks

        // Same overdue-wins-over-priority tint rule `ShiftTaskRowView`
        // (`ShiftListViews.swift`) uses for the main My Tasks list, so a
        // project's own task checklist reads consistently with it.
        let isOverdue: Bool = {
            guard let due = task.dueDate.flatMap(ShiftDateFormatting.date(from:)) else { return false }
            return due < Calendar.current.startOfDay(for: Date())
        }()
        let priorityTint: HelmTint = {
            switch task.priority {
            case .high: return .critical
            case .normal: return .info
            case .low: return .neutral
            }
        }()
        let tint: HelmTint = isOverdue ? .critical : priorityTint
        checkbox.setChecked(task.status == .completed, tint: HelmTheme.nsColor(tint.hex(in: theme)))

        titleLabel.stringValue = task.title
        titleLabel.textColor = HelmTheme.nsColor(theme.chromeInkHex)

        var bits: [String] = []
        if task.status == .completed { bits.append("Completed") }
        if let due = task.dueDate { bits.append(ShiftDateFormatting.friendly(due)) }
        if hasSubtasks {
            let done = task.subtasks.filter(\.done).count
            bits.append("\(done)/\(task.subtasks.count) subtasks")
        }
        subLabel.stringValue = bits.joined(separator: " \u{00B7} ")
        subLabel.textColor = HelmTheme.mutedInk(theme)
    }

    @objc private func chevronClicked() { onToggleExpand?() }
    @objc private func checkboxClicked() { onToggleCompleted?() }
}

/// A subtask row, indented and connected to its parent by a thin vertical
/// line - the mockup's "reads clearly nested" bar the captain asked for,
/// instead of phase 3's plain stacked checkboxes in a faint rounded box.
private final class ShiftProjectSubtaskRowView: NSView {
    private let indent = NSView()
    private let connector = NSView()
    /// Smaller than the task-level `ShiftTaskCheckBadge()` default (26pt) to
    /// fit this row's compact 30pt height.
    private let checkbox = ShiftTaskCheckBadge(size: 18)
    private let titleLabel = NSTextField(labelWithString: "")
    private var isDone = false
    private var onToggle: ((Bool) -> Void)?

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        indent.translatesAutoresizingMaskIntoConstraints = false
        indent.widthAnchor.constraint(equalToConstant: 26).isActive = true

        connector.wantsLayer = true
        connector.translatesAutoresizingMaskIntoConstraints = false
        indent.addSubview(connector)
        NSLayoutConstraint.activate([
            connector.centerXAnchor.constraint(equalTo: indent.centerXAnchor),
            connector.topAnchor.constraint(equalTo: indent.topAnchor),
            connector.bottomAnchor.constraint(equalTo: indent.bottomAnchor),
            connector.widthAnchor.constraint(equalToConstant: 1.5),
        ])

        checkbox.target = self
        checkbox.action = #selector(checkboxClicked)
        checkbox.translatesAutoresizingMaskIntoConstraints = false
        checkbox.setContentHuggingPriority(.required, for: .horizontal)

        titleLabel.font = .systemFont(ofSize: 11.5)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1
        titleLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let row = NSStackView(views: [indent, checkbox, titleLabel])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 6
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

    func configure(subtask: ShiftSubtask, theme: HelmTheme, onToggle: @escaping (Bool) -> Void) {
        self.onToggle = onToggle
        isDone = subtask.done
        checkbox.setChecked(subtask.done, tint: HelmTheme.nsColor(theme.accentHex))
        titleLabel.stringValue = subtask.title
        titleLabel.textColor = subtask.done ? HelmTheme.mutedInk(theme) : HelmTheme.nsColor(theme.chromeInkHex)
        connector.layer?.backgroundColor = HelmTheme.nsColor(theme.chromeLineHex).withAlphaComponent(0.6).cgColor
    }

    // `ShiftTaskCheckBadge` is `.momentaryChange` (image-only, no persistent
    // toggle state of its own - see its header) so the new value has to come
    // from the model's current value, not from reading `checkbox.state` back
    // after the click.
    @objc private func checkboxClicked() { onToggle?(!isDone) }
}

/// The "no subtasks yet" placeholder row shown when an expanded task has
/// none - indented to the same column the real subtask rows use.
private final class ShiftProjectNoSubtasksRowView: NSView {
    private let label = NSTextField(labelWithString: "No subtasks.")

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 10.5)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 38),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    func applyTheme(_ theme: HelmTheme) { label.textColor = HelmTheme.mutedInk(theme) }
}
