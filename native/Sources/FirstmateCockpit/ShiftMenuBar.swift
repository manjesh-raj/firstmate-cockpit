// Manjesh Grand Line - native macOS app.
//
// The Shift menu bar item (phase 5, cockpit-shift-power-features): a status
// bar icon showing today's task count, with a popover (mockup's
// `.mb-popover`) listing today's task count, the next follow-up, and a
// quick-add field that creates a real task via `ShiftStore.addTask` - the
// same store every other Shift entry point writes through, not a separate
// write path.
//
// Kept independent of the main window's `ShiftController` (which only exists
// once the window is built) so the menu bar item and its counts are correct
// even before the captain has ever opened the main window's Shift page.

import AppKit

final class ShiftMenuBarController: NSObject, NSPopoverDelegate {
    private let store: ShiftStore
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()
    private let contentController = ShiftMenuBarPopoverController()

    init(store: ShiftStore) {
        self.store = store
        super.init()

        if let button = statusItem.button {
            // fm/grandline-rail-followup-fixes: this used to be
            // "arrow.triangle.2.circlepath" (a refresh/sync glyph, unrelated
            // to what this status item actually does) - a captain screenshot
            // asked for the app's own "sailboat" mark instead (the same
            // symbol as the rail's logo, `IconRailController.loadView`'s
            // `mark.image`), since a standalone menu bar item has no nearby
            // app branding of its own to tie it back to Manjesh Grand Line.
            button.image = NSImage(systemSymbolName: "sailboat", accessibilityDescription: "Tasks")?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 12, weight: .medium))
            button.imagePosition = .imageLeading
            button.toolTip = "Tasks"
            button.target = self
            button.action = #selector(iconClicked)
        }

        popover.contentViewController = contentController
        popover.behavior = .transient
        popover.delegate = self
        contentController.onQuickAdd = { [weak self] title in
            self?.createQuickTask(title: title)
        }

        store.observe { [weak self] in self?.refreshCounts() }
        refreshCounts()
    }

    @objc private func iconClicked() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            refreshCounts()
            contentController.focusQuickAdd()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    private func createQuickTask(title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var task = ShiftTask.fresh()
        // Reuse the same natural-language date detection the New Task sheet's
        // title field already offers (cockpit-shift-create-edit), so "tomorrow
        // 3pm renew the cert" typed straight into the menu bar behaves the
        // same as typing it into the full editor.
        if let parsed = ShiftDateParser.parse(trimmed) {
            let (dateStr, timeStr) = ShiftDateFormatting.components(from: parsed.date)
            task.dueDate = dateStr
            task.dueTime = parsed.hasTime ? timeStr : nil
        }
        task.title = trimmed
        store.addTask(task)
        popover.performClose(nil)
    }

    private func refreshCounts() {
        let cal = Calendar.current
        let today = Date()
        let dueTodayCount = store.activeTasks.filter { task in
            guard let due = task.dueDate.flatMap(ShiftDateFormatting.date(from:)) else { return false }
            return cal.isDate(due, inSameDayAs: today)
        }.count

        let nextFollowUp = store.followUps
            .filter { $0.status == .pending }
            .compactMap { fu -> (ShiftFollowUp, Date)? in
                guard let date = ShiftDateFormatting.dateTime(from: fu.followUpAt, time: fu.followUpTime) else { return nil }
                return (fu, date)
            }
            .sorted { $0.1 < $1.1 }
            .first

        statusItem.button?.title = " \(dueTodayCount)"
        contentController.update(tasksToday: dueTodayCount, nextFollowUp: nextFollowUp?.0, nextFollowUpDate: nextFollowUp?.1)
    }
}

/// The popover's content: two stat rows + the next follow-up's title + a
/// quick-add field - built as a plain `NSViewController` rather than a shared
/// destination controller, since this content never needs theme-following
/// `NSVisualEffectView` tricks (a popover already gets its own vibrant
/// background from AppKit for free).
private final class ShiftMenuBarPopoverController: NSViewController {
    private let headerLabel = NSTextField(labelWithString: "Tasks")
    private let tasksRow = ShiftMenuBarStatRow(label: "Tasks today")
    private let followUpRow = ShiftMenuBarStatRow(label: "Next follow-up")
    private let nextFollowUpTitle = NSTextField(labelWithString: "")
    private let quickAddField = NSTextField()
    var onQuickAdd: ((String) -> Void)?

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 230, height: 140))
        view = root

        headerLabel.font = .systemFont(ofSize: 13, weight: .semibold)

        nextFollowUpTitle.font = .systemFont(ofSize: 11)
        // Re-derived from the active theme on every popover refresh (see
        // `update(tasksToday:nextFollowUp:nextFollowUpDate:)`), not a fixed
        // system grey - audit §5.3.
        nextFollowUpTitle.textColor = HelmTheme.mutedInk(ThemeManager.shared.theme)
        nextFollowUpTitle.lineBreakMode = .byTruncatingTail
        nextFollowUpTitle.maximumNumberOfLines = 2

        let divider = NSBox()
        divider.boxType = .separator

        quickAddField.placeholderString = "Quick add a task, press \u{23CE}\u{2026}"
        quickAddField.font = .systemFont(ofSize: 12)
        quickAddField.target = self
        quickAddField.action = #selector(quickAddSubmitted)

        let stack = NSStackView(views: [
            headerLabel, tasksRow, followUpRow, nextFollowUpTitle, divider, quickAddField,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12),
            tasksRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            followUpRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            divider.widthAnchor.constraint(equalTo: stack.widthAnchor),
            quickAddField.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
    }

    func update(tasksToday: Int, nextFollowUp: ShiftFollowUp?, nextFollowUpDate: Date?) {
        // This popover has no `ThemeManager.observe` of its own (it is rebuilt
        // from the menu bar item on every open, and `NSPopover` supplies its
        // own chrome), so its one theme-derived colour is refreshed here.
        nextFollowUpTitle.textColor = HelmTheme.mutedInk(ThemeManager.shared.theme)
        tasksRow.setValue("\(tasksToday)")
        if let nextFollowUp, let nextFollowUpDate {
            let f = DateFormatter()
            f.setLocalizedDateFormatFromTemplate("jm")
            followUpRow.setValue(f.string(from: nextFollowUpDate))
            nextFollowUpTitle.stringValue = nextFollowUp.title
            nextFollowUpTitle.isHidden = false
        } else {
            followUpRow.setValue("\u{2014}")
            nextFollowUpTitle.isHidden = true
        }
    }

    func focusQuickAdd() {
        quickAddField.stringValue = ""
        DispatchQueue.main.async { [weak self] in
            self?.view.window?.makeFirstResponder(self?.quickAddField)
        }
    }

    @objc private func quickAddSubmitted() {
        let text = quickAddField.stringValue
        quickAddField.stringValue = ""
        onQuickAdd?(text)
    }
}

private final class ShiftMenuBarStatRow: NSView {
    private let nameLabel = NSTextField(labelWithString: "")
    private let valueLabel = NSTextField(labelWithString: "")

    init(label: String) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        nameLabel.stringValue = label
        nameLabel.font = .systemFont(ofSize: 12)
        valueLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        valueLabel.alignment = .right

        let row = NSStackView(views: [nameLabel, valueLabel])
        row.orientation = .horizontal
        row.distribution = .equalSpacing
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

    func setValue(_ text: String) { valueLabel.stringValue = text }
}
