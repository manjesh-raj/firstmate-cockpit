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
//
// `fm/grandline-shift-task-row-cards` restyled both row views as bordered
// cards, translating the Notification Center's own card treatment onto this
// list - the captain liked that look and asked for it here too. As of
// `fm/grandline-design-system-phase3` that treatment is no longer copied at
// all: both rows below are thin adapters over the shared `HelmAccentRow`
// (`HelmDesignSystem.swift`), which is that same recipe promoted out of the
// Notification Center so five surfaces stopped re-implementing it. Same
// visual language (a colored left accent bar, a small round icon badge, a
// bold uppercase kicker label, body text, a trailing chip reusing
// `ToolRowLayout.pill`), still a plain `NSView` row inside the same
// `NSTableView` above, not a second rendering mechanism. Task rows: accent
// bar/badge tint is the task's priority, or `.critical` when the task is
// overdue (a stronger signal than priority alone); the badge is a real
// interactive checkbox-alike (`ShiftTaskCheckBadge`), styled as an icon tile
// but still a genuine `NSButton` so click-to-toggle is unchanged; kicker is
// the task's project name (or a generic fallback); the chip is the
// priority pill. Follow-up rows: accent/badge tint is done/pending status
// (a `.good`/`.warn` split, orthogonal to priority so it doesn't just repeat
// the chip); kicker is the status text; the chip is the priority pill -
// double-click/right-click/Snooze are all unchanged, since only the badge's
// *icon* changed, never its lack of a click target (follow-ups never had an
// inline toggle - Done/Reopen/Snooze stay context-menu/double-click only).
// Both rows grew taller to fit three lines of text plus card padding -
// `heightOfRow` below was updated to match; `ShiftController`'s shared
// `taskFollowUpPanelBodyHeight` (the fixed scroll clip both panels share)
// was deliberately left alone, since a card list showing ~3-4 rows before
// scrolling reads fine at that height, matching the Notification Center's
// own panel.

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
        tableView.rowHeight = Self.rowHeight
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(rowDoubleClicked)
    }

    /// Three text lines (kicker/title/meta) plus card padding - see the file
    /// header for the card redesign this replaced a flat 44pt row with.
    ///
    /// Measured, not guessed: a fully-populated `HelmAccentRow` reports a
    /// 75pt fitting height, and the row view insets it by 1pt top and bottom.
    /// At the previous 74 the meta line's descenders clipped - visible in a
    /// real render once the shared component brought the row onto the app's
    /// one type scale (`HelmType.rowTitle`/`caption`, a touch larger than
    /// this list's own former 13/10.5 pair).
    static let rowHeight: CGFloat = 78

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
        tasks.isEmpty ? 120 : Self.rowHeight
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard !tasks.isEmpty else {
            let empty = (tableView.makeView(withIdentifier: Self.emptyViewID, owner: nil) as? HelmEmptyState)
                ?? { let v = HelmEmptyState(symbol: "checklist", body: "Nothing on your plate. Enjoy it."); v.identifier = Self.emptyViewID; return v }()
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

/// A real, clickable checkbox styled as a small round tinted tile (the
/// notification card's own "icon in a badge" idiom, `IconTileView`'s circular
/// cousin) rather than a bare system checkbox floating on its own - still a
/// genuine `NSButton` with a real target/action, so click-to-toggle-complete
/// is byte-for-byte the same behavior as before this restyle, only the
/// drawing changed.
// Not `private` - reused by `ShiftProjectDetailView.swift`'s own task/subtask
// checklist rows (`fm/grandline-shift-project-detail-theming`) rather than a
// second tinted-circle checkbox being hand-rolled there.
final class ShiftTaskCheckBadge: NSButton {
    static let size: CGFloat = 26

    private let diameter: CGFloat

    init(size: CGFloat = ShiftTaskCheckBadge.size) {
        diameter = size
        super.init(frame: .zero)
        title = ""
        isBordered = false
        imagePosition = .imageOnly
        setButtonType(.momentaryChange)
        wantsLayer = true
        layer?.cornerRadius = diameter / 2
        layer?.borderWidth = 1.5
        translatesAutoresizingMaskIntoConstraints = false
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        setAccessibilityRole(.checkBox)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: diameter),
            heightAnchor.constraint(equalToConstant: diameter),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    /// `tint` drives both the outline (unchecked) and the fill (checked) -
    /// the same single accent color that also drives this row's own accent
    /// bar, mirroring `HelmAccentRow`'s badge/accent-bar pairing.
    func setChecked(_ checked: Bool, tint: NSColor) {
        image = checked
            ? NSImage(systemSymbolName: "checkmark", accessibilityDescription: "Completed")?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: diameter * 0.42, weight: .bold))
            : nil
        contentTintColor = .white
        layer?.backgroundColor = checked ? tint.cgColor : NSColor.clear.cgColor
        layer?.borderColor = tint.cgColor
        setAccessibilityValue(checked)
        toolTip = checked ? "Mark incomplete" : "Mark complete"
    }
}

/// One task row: a thin adapter over the app's shared `HelmAccentRow`
/// (`HelmDesignSystem.swift`, audit §6.3 component 2). Everything visual -
/// accent bar, badge, kicker, body, meta, chip, card - now comes from that
/// one component, which is `NotificationRowView`'s recipe promoted; what is
/// left here is the part that is genuinely about a Shift task: which tint a
/// priority (or an overdue due date) maps to, what the kicker and meta lines
/// say, and the completion checkbox in the badge's place.
///
/// The checkbox is a real `ShiftTaskCheckBadge` passed as the row's
/// `leadingControl`, so click-to-toggle-complete is byte-for-byte the
/// behaviour it has always had, and the table's own double-click-to-open is
/// untouched.
private final class ShiftTaskRowView: NSView {
    private let checkBadge = ShiftTaskCheckBadge()
    private let row: HelmAccentRow
    private var onToggle: (() -> Void)?

    init() {
        row = HelmAccentRow(leadingControl: checkBadge)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        checkBadge.target = self
        checkBadge.action = #selector(checkboxClicked)
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            row.topAnchor.constraint(equalTo: topAnchor, constant: 1),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -1),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    func configure(task: ShiftTask, project: ShiftProject?, theme: HelmTheme, onToggle: @escaping () -> Void) {
        self.onToggle = onToggle

        let isOverdue: Bool = {
            guard let due = task.dueDate.flatMap(ShiftDateFormatting.date(from:)) else { return false }
            return due < Calendar.current.startOfDay(for: Date())
        }()
        let (priorityText, priorityTint): (String, HelmTint) = {
            switch task.priority {
            case .high: return ("High", .critical)
            case .normal: return ("Normal", .info)
            case .low: return ("Low", .neutral)
            }
        }()
        // Overdue is a stronger, more urgent signal than priority alone - it
        // wins the accent bar/badge tint when both are present, while the
        // chip keeps reporting priority.
        let tint: HelmTint = isOverdue ? .critical : priorityTint

        var bits: [String] = []
        if let due = task.dueDate { bits.append(ShiftDateFormatting.friendly(due)) }
        if !task.subtasks.isEmpty {
            let done = task.subtasks.filter(\.done).count
            bits.append("\(done)/\(task.subtasks.count) subtasks")
        }

        row.configure(HelmAccentRow.Content(
            tint: tint,
            kicker: project?.name ?? "Task",
            title: task.title,
            meta: bits.joined(separator: " \u{00B7} "),
            // A rendered thumbnail would blow out this row's fixed height the
            // way `fm/grandline-shift-panel-height-scroll-fix` already fixed
            // once; the real image only ever shows in the editor sheet.
            titleAccessorySymbol: task.hasAttachment ? "paperclip" : nil,
            chipText: priorityText,
            chipTint: priorityTint
        ), theme: theme)

        checkBadge.setChecked(task.status == .completed,
                              tint: HelmTheme.nsColor(tint.hex(in: theme)))
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
        tableView.rowHeight = Self.rowHeight
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(rowDoubleClicked)
        tableView.menu = rowMenu()
    }

    /// Matches `ShiftTaskListView.rowHeight` - both lists share the same card
    /// treatment, so their rows are the same height for a consistent
    /// side-by-side look (`fm/grandline-shift-side-by-side-composer-height`).
    static let rowHeight: CGFloat = ShiftTaskListView.rowHeight

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
        items.isEmpty ? 110 : Self.rowHeight
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard !items.isEmpty else {
            let empty = (tableView.makeView(withIdentifier: Self.emptyViewID, owner: nil) as? HelmEmptyState)
                ?? { let v = HelmEmptyState(symbol: "bell", body: "No follow-ups pending."); v.identifier = Self.emptyViewID; return v }()
            empty.applyTheme(theme)
            return empty
        }
        let rowView = (tableView.makeView(withIdentifier: Self.rowViewID, owner: nil) as? ShiftFollowUpRowView)
            ?? { let v = ShiftFollowUpRowView(); v.identifier = Self.rowViewID; return v }()
        rowView.configure(item: items[row], theme: theme)
        return rowView
    }
}

/// One follow-up row, the same thin adapter over `HelmAccentRow` as
/// `ShiftTaskRowView` above - but the two orthogonal signals swap roles.
/// Follow-ups have no inline toggle (Done/Reopen/Snooze stay context-menu /
/// double-click only, unchanged), so the accent bar and badge here read
/// done/pending status - a stronger "does this still need me" glance than
/// priority alone - while priority moves into the trailing chip.
private final class ShiftFollowUpRowView: NSView {
    private let row = HelmAccentRow()

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            row.topAnchor.constraint(equalTo: topAnchor, constant: 1),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -1),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    func configure(item: ShiftFollowUp, theme: HelmTheme) {
        let isDone = item.status == .done
        let (priorityText, priorityTint): (String, HelmTint) = {
            switch item.priority {
            case .high: return ("High", .critical)
            case .normal: return ("Normal", .info)
            case .low: return ("Low", .neutral)
            }
        }()
        var bits: [String] = []
        if let at = item.followUpAt { bits.append(ShiftDateFormatting.friendly(at, time: item.followUpTime)) }

        row.configure(HelmAccentRow.Content(
            tint: isDone ? .good : .warn,
            kicker: isDone ? "Done" : "Pending",
            title: item.title,
            meta: bits.joined(separator: " \u{00B7} "),
            badgeSymbol: isDone ? "checkmark" : "bell.fill",
            chipText: priorityText,
            chipTint: priorityTint
        ), theme: theme)
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
