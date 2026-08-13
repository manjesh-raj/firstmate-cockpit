// Manjesh Grand Line - native macOS app.
//
// The `.shift` rail destination: "My Tasks" (cockpit-shift-foundation, phase
// 1 of a multi-phase build - see AGENTS.md's "Shift" section). Structure
// mirrors `FleetController.swift`'s established page shape (greeting header,
// stat tiles, list sections in a `FlippedView`-backed scroll area) but the
// two real lists - tasks and follow-ups - render via `ShiftListViews.swift`'s
// `NSTableView`-based views rather than a plain `NSStackView` of permanent
// rows, per this app's own hard-learned Diff-tool lesson (see
// `DiffResultView.swift`'s header) about what happens to that pattern once a
// list grows into the hundreds.
//
// Creation/editing, Git sync, search, and the full Projects page are all
// out of scope for this phase - see the brief's "explicitly out of scope"
// list, restated in AGENTS.md. The Projects section here is the minimal
// placeholder the brief allowed, included mainly to prove out project-scoped
// subtask rendering (subtasks never appear as flat rows in the main task
// list - see the rule stated in ShiftModels.swift's header).

import AppKit

final class ShiftController: NSViewController {

    private let store: ShiftStore

    private let scroll = NSScrollView()
    private let contentStack = NSStackView()

    private let greetingLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let statsRow = NSStackView()
    private var stashedTileParts: [(NSView, NSTextField, NSTextField)] = []

    private let taskListView = ShiftTaskListView()
    private let taskListScroll = NSScrollView()
    private let tasksHeader = NSTextField(labelWithString: "")

    private let followUpListView = ShiftFollowUpListView()
    private let followUpScroll = NSScrollView()
    private let followUpsHeader = NSTextField(labelWithString: "")

    private let projectsHeader = NSTextField(labelWithString: "")
    private let projectsStack = NSStackView()

    private var theme: HelmTheme = ThemeManager.shared.theme
    private var expandedProjectID: String?

    init(store: ShiftStore) {
        self.store = store
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 940, height: 720))
        root.wantsLayer = true
        view = root

        // FlippedView, not a plain NSView - see FleetController.swift's
        // header for why a non-flipped document view leaves a blank gap
        // above the header while content is still shorter than the
        // viewport.
        let content = FlippedView()
        content.translatesAutoresizingMaskIntoConstraints = false

        let header = buildHeader()
        buildStatsRow()
        let taskSection = buildTaskSection()
        let followUpSection = buildFollowUpSection()
        let projectsSection = buildProjectsSection()

        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = 20
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        contentStack.addArrangedSubview(header)
        contentStack.addArrangedSubview(statsRow)
        contentStack.addArrangedSubview(taskSection)
        contentStack.addArrangedSubview(followUpSection)
        contentStack.addArrangedSubview(projectsSection)

        content.addSubview(contentStack)
        NSLayoutConstraint.activate([
            contentStack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 28),
            contentStack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -28),
            contentStack.topAnchor.constraint(equalTo: content.topAnchor, constant: 24),
            contentStack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -28),
            statsRow.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
            taskSection.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
            followUpSection.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
            projectsSection.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
        ])

        scroll.documentView = content
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: root.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            content.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
        ])

        taskListView.onToggleCompleted = { [weak self] task in
            self?.store.setTaskCompleted(id: task.id, completed: task.status != .completed)
            self?.render()
        }
        taskListView.onOpen = { [weak self] task in
            self?.presentTaskEditor(for: task)
        }

        followUpListView.onEdit = { [weak self] item in
            self?.presentFollowUpEditor(for: item)
        }
        followUpListView.onToggleDone = { [weak self] item in
            self?.store.setFollowUpStatus(id: item.id, done: item.status != .done)
            self?.render()
        }
        followUpListView.onSnooze = { [weak self] item, option in
            self?.snoozeFollowUp(item, option: option)
        }

        ThemeManager.shared.observe { [weak self, weak root] theme in
            self?.theme = theme
            root?.appearance = NSAppearance(named: theme.mode == .dark ? .darkAqua : .aqua)
            self?.applyTheme()
        }
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        view.layoutSubtreeIfNeeded()
        scrollToTop()
        store.reloadAll()
        render()
    }

    private func scrollToTop() {
        scroll.contentView.scroll(to: .zero)
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    // MARK: Building chrome

    private func buildHeader() -> NSView {
        greetingLabel.font = .systemFont(ofSize: 22, weight: .semibold)
        subtitleLabel.font = .systemFont(ofSize: 12)
        let stack = NSStackView(views: [greetingLabel, subtitleLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }

    private func buildStatsRow() {
        statsRow.orientation = .horizontal
        statsRow.distribution = .fillEqually
        statsRow.spacing = 10
        statsRow.translatesAutoresizingMaskIntoConstraints = false
    }

    private func statTile(icon: String, value: String, label: String) -> NSView {
        let container = NSView()
        container.wantsLayer = true
        container.layer?.cornerRadius = 10
        container.translatesAutoresizingMaskIntoConstraints = false

        let iconView = NSImageView()
        iconView.image = NSImage(systemSymbolName: icon, accessibilityDescription: label)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 11, weight: .medium))
        iconView.translatesAutoresizingMaskIntoConstraints = false

        let valueLabel = NSTextField(labelWithString: value)
        valueLabel.font = .monospacedDigitSystemFont(ofSize: 17, weight: .semibold)

        let nameLabel = NSTextField(labelWithString: label)
        nameLabel.font = .systemFont(ofSize: 9.5)

        let topRow = NSStackView(views: [iconView, valueLabel])
        topRow.orientation = .horizontal
        topRow.spacing = 5
        topRow.alignment = .firstBaseline

        let stack = NSStackView(views: [topRow, nameLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 3
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -10),
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 10),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -10),
            container.heightAnchor.constraint(equalToConstant: 56),
        ])
        stashedTileParts.append((container, valueLabel, nameLabel))
        return container
    }

    private func sectionHeaderRow(iconSymbol: String, label: NSTextField, addAction: Selector? = nil, addTooltip: String? = nil) -> NSStackView {
        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: iconSymbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold))
        label.font = .systemFont(ofSize: 14, weight: .semibold)
        var views: [NSView] = [icon, label]
        if let addAction {
            let spacer = NSView()
            spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
            let addButton = NSButton(title: "", target: self, action: addAction)
            addButton.isBordered = false
            addButton.image = NSImage(systemSymbolName: "plus.circle", accessibilityDescription: addTooltip)
            addButton.toolTip = addTooltip
            addButton.translatesAutoresizingMaskIntoConstraints = false
            views += [spacer, addButton]
        }
        let row = NSStackView(views: views)
        row.orientation = .horizontal
        row.spacing = 8
        row.alignment = .firstBaseline
        row.translatesAutoresizingMaskIntoConstraints = false
        return row
    }

    private func buildTaskSection() -> NSView {
        let headerRow = sectionHeaderRow(iconSymbol: "checklist", label: tasksHeader, addAction: #selector(newTaskClicked), addTooltip: "New Task (\u{2318}N)")

        taskListScroll.documentView = taskListView.tableView
        taskListScroll.hasVerticalScroller = true
        taskListScroll.hasHorizontalScroller = false
        taskListScroll.borderType = .noBorder
        taskListScroll.wantsLayer = true
        taskListScroll.layer?.cornerRadius = 8
        taskListScroll.translatesAutoresizingMaskIntoConstraints = false
        taskListScroll.heightAnchor.constraint(equalToConstant: 300).isActive = true

        let section = NSStackView(views: [headerRow, taskListScroll])
        section.orientation = .vertical
        section.alignment = .leading
        section.spacing = 8
        section.translatesAutoresizingMaskIntoConstraints = false
        headerRow.widthAnchor.constraint(equalTo: section.widthAnchor).isActive = true
        taskListScroll.widthAnchor.constraint(equalTo: section.widthAnchor).isActive = true
        return section
    }

    private func buildFollowUpSection() -> NSView {
        let headerRow = sectionHeaderRow(iconSymbol: "bell", label: followUpsHeader, addAction: #selector(newFollowUpClicked), addTooltip: "New Follow-up (\u{2318}\u{21e7}F)")

        followUpScroll.documentView = followUpListView.tableView
        followUpScroll.hasVerticalScroller = true
        followUpScroll.hasHorizontalScroller = false
        followUpScroll.borderType = .noBorder
        followUpScroll.wantsLayer = true
        followUpScroll.layer?.cornerRadius = 8
        followUpScroll.translatesAutoresizingMaskIntoConstraints = false
        followUpScroll.heightAnchor.constraint(equalToConstant: 220).isActive = true

        let section = NSStackView(views: [headerRow, followUpScroll])
        section.orientation = .vertical
        section.alignment = .leading
        section.spacing = 8
        section.translatesAutoresizingMaskIntoConstraints = false
        headerRow.widthAnchor.constraint(equalTo: section.widthAnchor).isActive = true
        followUpScroll.widthAnchor.constraint(equalTo: section.widthAnchor).isActive = true
        return section
    }

    /// Minimal placeholder Projects entry point (brief-approved) - proves the
    /// project-scoped subtask model without building the real Projects page
    /// (status control, editing) a later phase owns. Small, non-table
    /// `NSStackView` rendering is fine here: this list is only ever as long
    /// as the captain's project count, nowhere near the scale that justified
    /// a table view for tasks/follow-ups.
    private func buildProjectsSection() -> NSView {
        let headerRow = sectionHeaderRow(iconSymbol: "shippingbox", label: projectsHeader)
        projectsStack.orientation = .vertical
        projectsStack.alignment = .leading
        projectsStack.spacing = 6
        projectsStack.translatesAutoresizingMaskIntoConstraints = false

        let section = NSStackView(views: [headerRow, projectsStack])
        section.orientation = .vertical
        section.alignment = .leading
        section.spacing = 8
        section.translatesAutoresizingMaskIntoConstraints = false
        projectsStack.widthAnchor.constraint(equalTo: section.widthAnchor).isActive = true
        return section
    }

    // MARK: Rendering

    private func render() {
        let hour = Calendar.current.component(.hour, from: Date())
        let part = hour < 5 ? "Still up" : hour < 12 ? "Good morning" : hour < 17 ? "Good afternoon" : "Good evening"
        greetingLabel.stringValue = "\(part)"
        let df = DateFormatter()
        df.setLocalizedDateFormatFromTemplate("EEEE, MMMM d")
        subtitleLabel.stringValue = df.string(from: Date())

        let tasks = store.activeTasks
        let followUps = store.followUps
        let today = Date()
        let cal = Calendar.current

        let dueToday = tasks.filter { task in
            guard let due = task.dueDate.flatMap(ShiftDateFormatting.date(from:)) else { return false }
            return cal.isDate(due, inSameDayAs: today)
        }
        let overdue = tasks.filter { task in
            guard let due = task.dueDate.flatMap(ShiftDateFormatting.date(from:)) else { return false }
            return due < cal.startOfDay(for: today)
        }
        let pendingFollowUps = followUps.filter { $0.status == .pending }

        rebuildStats(tasksToday: dueToday.count, followUps: pendingFollowUps.count, overdue: overdue.count)

        let sortedTasks = tasks.sorted { lhs, rhs in
            let ld = lhs.dueDate.flatMap(ShiftDateFormatting.date(from:))
            let rd = rhs.dueDate.flatMap(ShiftDateFormatting.date(from:))
            switch (ld, rd) {
            case (.some(let l), .some(let r)): return l < r
            case (.some, .none): return true
            case (.none, .some): return false
            default: return lhs.createdAt < rhs.createdAt
            }
        }
        taskListView.setTasks(sortedTasks, projects: store.projects)
        tasksHeader.stringValue = "My Tasks (\(tasks.count))"

        followUpListView.setItems(followUps)
        followUpsHeader.stringValue = "Follow-ups (\(pendingFollowUps.count) pending)"

        projectsHeader.stringValue = "Projects (\(store.projects.count))"
        rebuildProjects()

        applyTheme()
    }

    private func rebuildStats(tasksToday: Int, followUps: Int, overdue: Int) {
        for v in statsRow.arrangedSubviews {
            statsRow.removeArrangedSubview(v)
            v.removeFromSuperview()
        }
        stashedTileParts.removeAll()
        statsRow.addArrangedSubview(statTile(icon: "sun.max", value: "\(tasksToday)", label: "tasks today"))
        statsRow.addArrangedSubview(statTile(icon: "bell", value: "\(followUps)", label: "follow-ups"))
        statsRow.addArrangedSubview(statTile(icon: "exclamationmark.triangle", value: "\(overdue)", label: "overdue"))
    }

    private func rebuildProjects() {
        for v in projectsStack.arrangedSubviews {
            projectsStack.removeArrangedSubview(v)
            v.removeFromSuperview()
        }
        subtaskContainers.removeAll()
        if store.projects.isEmpty {
            let label = NSTextField(labelWithString: "No projects yet.")
            label.font = .systemFont(ofSize: 12)
            label.textColor = HelmTheme.mutedInk(theme)
            projectsStack.addArrangedSubview(label)
            return
        }
        for project in store.projects {
            let row = projectRow(project)
            projectsStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: projectsStack.widthAnchor).isActive = true
            if expandedProjectID == project.id {
                let detail = projectTasksView(project)
                projectsStack.addArrangedSubview(detail)
                detail.widthAnchor.constraint(equalTo: projectsStack.widthAnchor).isActive = true
            }
        }
    }

    private func projectRow(_ project: ShiftProject) -> NSView {
        let icon = NSImageView()
        icon.image = NSImage(
            systemSymbolName: expandedProjectID == project.id ? "chevron.down" : "chevron.right",
            accessibilityDescription: nil
        )?.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 10, weight: .semibold))

        let nameLabel = NSTextField(labelWithString: project.name)
        nameLabel.font = .systemFont(ofSize: 12.5, weight: .medium)

        let countLabel = NSTextField(labelWithString: "\(store.activeTasks.filter { $0.projectID == project.id }.count) tasks")
        countLabel.font = .systemFont(ofSize: 10.5)
        countLabel.textColor = HelmTheme.mutedInk(theme)

        let row = NSStackView(views: [icon, nameLabel, countLabel])
        row.orientation = .horizontal
        row.spacing = 8
        row.alignment = .centerY
        row.translatesAutoresizingMaskIntoConstraints = false

        let container = HoverHighlightView()
        container.cornerRadius = 6
        container.normalColor = .clear
        container.hoverColor = HelmTheme.nsColor(theme.chromeLineHex).withAlphaComponent(0.18)
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 6),
            row.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -6),
            row.topAnchor.constraint(equalTo: container.topAnchor, constant: 6),
            row.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -6),
        ])
        let click = NSClickGestureRecognizer(target: self, action: #selector(projectRowClicked(_:)))
        container.addGestureRecognizer(click)
        container.identifier = NSUserInterfaceItemIdentifier(project.id)
        return container
    }

    @objc private func projectRowClicked(_ sender: NSClickGestureRecognizer) {
        guard let id = sender.view?.identifier?.rawValue else { return }
        expandedProjectID = expandedProjectID == id ? nil : id
        rebuildProjects()
    }

    /// The one place subtasks render - nested under their parent task,
    /// inside a project's expanded detail, never as flat rows in the main
    /// task list above.
    private func projectTasksView(_ project: ShiftProject) -> NSView {
        let tasks = store.activeTasks.filter { $0.projectID == project.id }
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false

        if tasks.isEmpty {
            let label = NSTextField(labelWithString: "No tasks in this project.")
            label.font = .systemFont(ofSize: 11.5)
            label.textColor = HelmTheme.mutedInk(theme)
            stack.addArrangedSubview(label)
        }

        for task in tasks {
            let titleLabel = NSTextField(labelWithString: "\u{2022} " + task.title)
            titleLabel.font = .systemFont(ofSize: 12, weight: .medium)
            titleLabel.textColor = HelmTheme.nsColor(theme.chromeInkHex)
            let taskColumn = NSStackView(views: [titleLabel])
            taskColumn.orientation = .vertical
            taskColumn.alignment = .leading
            taskColumn.spacing = 4

            for subtask in task.subtasks {
                let checkbox = NSButton(checkboxWithTitle: subtask.title, target: self, action: #selector(subtaskToggled(_:)))
                checkbox.state = subtask.done ? .on : .off
                checkbox.font = .systemFont(ofSize: 11.5)
                checkbox.identifier = NSUserInterfaceItemIdentifier("\(task.id)\u{0}\(subtask.id)")
                taskColumn.addArrangedSubview(checkbox)
            }
            stack.addArrangedSubview(taskColumn)
        }

        let container = NSView()
        container.wantsLayer = true
        container.layer?.cornerRadius = 8
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 10),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -10),
        ])
        subtaskContainers.append(container)
        return container
    }

    private var subtaskContainers: [NSView] = []

    @objc private func subtaskToggled(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue else { return }
        let parts = raw.components(separatedBy: "\u{0}")
        guard parts.count == 2 else { return }
        store.setSubtaskDone(taskID: parts[0], subtaskID: parts[1], done: sender.state == .on)
        render()
    }

    // MARK: Creation / editing (phase 2)

    /// The Shift menu's "New Task…" (⌘N) - also reachable from the My Tasks
    /// header's "+" button.
    func presentNewTaskEditor() { presentTaskEditor(for: nil) }

    /// The Shift menu's "New Follow-up…" (⌘⇧F) - also reachable from the
    /// Follow-ups header's "+" button.
    func presentNewFollowUpEditor() { presentFollowUpEditor(for: nil) }

    @objc private func newTaskClicked() { presentTaskEditor(for: nil) }
    @objc private func newFollowUpClicked() { presentFollowUpEditor(for: nil) }

    private func presentTaskEditor(for task: ShiftTask?) {
        let editor = ShiftTaskEditorController(task: task, projects: store.projects)
        editor.onSave = { [weak self] saved in
            guard let self else { return }
            if task != nil {
                self.store.updateTask(saved)
            } else {
                self.store.addTask(saved)
            }
            self.render()
        }
        presentAsSheet(editor)
    }

    private func presentFollowUpEditor(for followUp: ShiftFollowUp?) {
        let editor = ShiftFollowUpEditorController(followUp: followUp, tasks: store.activeTasks, projects: store.projects)
        editor.onSave = { [weak self] saved in
            guard let self else { return }
            if followUp != nil {
                self.store.updateFollowUp(saved)
            } else {
                self.store.addFollowUp(saved)
            }
            self.render()
        }
        presentAsSheet(editor)
    }

    /// Recomputes and persists a follow-up's `follow_up_at`/`follow_up_time`
    /// for one of the Snooze menu's presets, or opens the Custom picker
    /// sheet for the last option - the actual write happens in
    /// `ShiftStore.snoozeFollowUp`, this just does the relative-offset math.
    private func snoozeFollowUp(_ item: ShiftFollowUp, option: ShiftSnoozeOption) {
        let now = Date()
        let current = ShiftDateFormatting.dateTime(from: item.followUpAt, time: item.followUpTime) ?? now
        let cal = Calendar.current
        switch option {
        case .minutes30:
            store.snoozeFollowUp(id: item.id, to: cal.date(byAdding: .minute, value: 30, to: now) ?? now)
            render()
        case .hour1:
            store.snoozeFollowUp(id: item.id, to: cal.date(byAdding: .hour, value: 1, to: now) ?? now)
            render()
        case .tomorrow:
            store.snoozeFollowUp(id: item.id, to: cal.date(byAdding: .day, value: 1, to: current) ?? now)
            render()
        case .nextWeek:
            store.snoozeFollowUp(id: item.id, to: cal.date(byAdding: .day, value: 7, to: current) ?? now)
            render()
        case .custom:
            let picker = ShiftSnoozeCustomController(initial: current)
            picker.onPick = { [weak self] date in
                self?.store.snoozeFollowUp(id: item.id, to: date)
                self?.render()
            }
            presentAsSheet(picker)
        }
    }

    // MARK: Theme

    private func applyTheme() {
        view.layer?.backgroundColor = HelmTheme.nsColor(theme.backgroundHex).cgColor
        let ink = HelmTheme.nsColor(theme.chromeInkHex)
        let surface = HelmTheme.nsColor(theme.chromeBackgroundHex)
        let line = HelmTheme.nsColor(theme.chromeLineHex)
        let muted = HelmTheme.mutedInk(theme)

        greetingLabel.textColor = ink
        subtitleLabel.textColor = muted
        tasksHeader.textColor = ink
        followUpsHeader.textColor = ink
        projectsHeader.textColor = ink

        for (container, valueLabel, nameLabel) in stashedTileParts {
            container.layer?.backgroundColor = surface.cgColor
            container.layer?.borderWidth = 1
            container.layer?.borderColor = line.withAlphaComponent(0.5).cgColor
            valueLabel.textColor = ink
            nameLabel.textColor = muted
        }
        for scroll in [taskListScroll, followUpScroll] {
            scroll.layer?.backgroundColor = surface.cgColor
        }
        for container in subtaskContainers {
            container.layer?.backgroundColor = surface.withAlphaComponent(0.6).cgColor
        }
        taskListView.applyTheme(theme)
        followUpListView.applyTheme(theme)
    }
}
