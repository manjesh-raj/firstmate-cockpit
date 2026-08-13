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
    private let syncPill = NSView()
    private let syncPillLabel = NSTextField(labelWithString: "")
    private let statsRow = NSStackView()
    private var stashedTileParts: [(container: NSView, valueLabel: NSTextField, nameLabel: NSTextField, tint: HelmTint)] = []

    private let taskListView = ShiftTaskListView()
    private let taskListScroll = NSScrollView()
    private let tasksHeader = NSTextField(labelWithString: "")
    private let tasksCountBadge = NSTextField(labelWithString: "")
    private let taskPanel = ShiftPanelView()

    private let followUpListView = ShiftFollowUpListView()
    private let followUpScroll = NSScrollView()
    private let followUpsHeader = NSTextField(labelWithString: "")
    private let followUpsCountBadge = NSTextField(labelWithString: "")
    private let followUpPanel = ShiftPanelView()

    private let projectsHeader = NSTextField(labelWithString: "")
    private let projectsCountBadge = NSTextField(labelWithString: "")
    private let projectsGridContainer = NSStackView()
    private let projectsDetailContainer = NSStackView()

    // MARK: Weekly Review (phase 5, cockpit-shift-power-features)

    /// The two-tab switcher living just below the header - "My Tasks" (the
    /// existing stats/task/follow-up/projects content, unchanged) and
    /// "Weekly Review" (a distinct summary view). This keeps Shift a single
    /// consolidated destination (the captain's phase-1 decision, restated in
    /// AGENTS.md) while still giving Weekly Review "its own view" rather than
    /// squeezing it into the daily dashboard.
    private enum ShiftTopLevelView { case dashboard, weeklyReview }
    private var topLevelView: ShiftTopLevelView = .dashboard
    private let dashboardTab = HoverHighlightView()
    private let dashboardTabLabel = NSTextField(labelWithString: "My Tasks")
    private let reviewTab = HoverHighlightView()
    private let reviewTabLabel = NSTextField(labelWithString: "Weekly Review")
    private let dashboardContainer = NSStackView()
    private let weeklyReviewContainer = NSStackView()

    private let reviewGreeting = NSTextField(labelWithString: "")
    private let reviewSubtitle = NSTextField(labelWithString: "What got done, what got pushed back, what's coming.")
    private let reviewStatsRow = NSStackView()
    private var reviewStashedTileParts: [(container: NSView, valueLabel: NSTextField, nameLabel: NSTextField, tint: HelmTint)] = []
    private let reviewPushedBackPanel = ShiftPanelView()
    private let reviewPushedBackHeader = NSTextField(labelWithString: "Pushed back repeatedly")
    private let reviewPushedBackStack = NSStackView()

    private var theme: HelmTheme = ThemeManager.shared.theme
    private var expandedTaskIDs: Set<String> = []
    private var syncStatus: ShiftGitSync.Status = .synced

    /// The Projects section's own navigation state - a grid of cards, or one
    /// project's detail (task list + edit form). Kept separate from the
    /// page's overall render() so switching between the two doesn't need to
    /// re-fetch tasks/follow-ups stats.
    private enum ShiftProjectsView: Equatable {
        case grid
        case detail(String)
    }
    private var projectsView: ShiftProjectsView = .grid
    private var subtaskContainers: [NSView] = []

    private static let projectCardMinWidth: CGFloat = 260
    private static let projectCardSpacing: CGFloat = 12

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
        let tabRow = buildTabRow()
        buildStatsRow()
        let taskSection = buildTaskSection()
        let followUpSection = buildFollowUpSection()
        let projectsSection = buildProjectsSection()

        dashboardContainer.orientation = .vertical
        dashboardContainer.alignment = .leading
        dashboardContainer.spacing = 20
        dashboardContainer.translatesAutoresizingMaskIntoConstraints = false
        dashboardContainer.addArrangedSubview(statsRow)
        dashboardContainer.addArrangedSubview(taskSection)
        dashboardContainer.addArrangedSubview(followUpSection)
        dashboardContainer.addArrangedSubview(projectsSection)

        let weeklyReviewSection = buildWeeklyReviewSection()

        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = 20
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        contentStack.addArrangedSubview(header)
        contentStack.addArrangedSubview(tabRow)
        contentStack.addArrangedSubview(dashboardContainer)
        contentStack.addArrangedSubview(weeklyReviewSection)

        content.addSubview(contentStack)
        NSLayoutConstraint.activate([
            contentStack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 28),
            contentStack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -28),
            contentStack.topAnchor.constraint(equalTo: content.topAnchor, constant: 24),
            contentStack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -28),
            dashboardContainer.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
            statsRow.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
            taskSection.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
            followUpSection.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
            projectsSection.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
            weeklyReviewSection.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
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

        NotificationCenter.default.addObserver(
            self, selector: #selector(containerWidthMayHaveChanged), name: NSWindow.didResizeNotification, object: nil
        )

        store.gitSync?.observeStatus { [weak self] status in
            self?.syncStatus = status
            self?.applySyncPill()
        }
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    /// Mirrors `ToolsController`'s own resize-gating fix (fm/cockpit-tools-
    /// yaml-quotes-diff-perf's sibling perf fix): only re-flow the grid while
    /// it's actually the visible view, so a captain's resize elsewhere in the
    /// app never pays for laying out project cards nobody is looking at.
    @objc private func containerWidthMayHaveChanged(_ note: Notification? = nil) {
        guard !view.isHidden, projectsView == .grid else { return }
        view.layoutSubtreeIfNeeded()
        rebuildProjectsGrid()
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
        greetingLabel.font = ShiftFont.serif(23)
        subtitleLabel.font = .systemFont(ofSize: 12)
        let textStack = NSStackView(views: [greetingLabel, subtitleLabel])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 4
        textStack.translatesAutoresizingMaskIntoConstraints = false

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        syncPill.translatesAutoresizingMaskIntoConstraints = false
        applySyncPill()

        let row = NSStackView(views: [textStack, spacer, syncPill])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false
        return row
    }

    /// Reflects `ShiftGitSync`'s real status - never a timer or a fake cycle.
    /// `nil` `store.gitSync` (an explicit `FM_SHIFT_DIR` override with no git
    /// backing) hides the pill entirely rather than showing a status that
    /// doesn't mean anything for that setup.
    private func applySyncPill() {
        guard store.gitSync != nil else {
            syncPill.isHidden = true
            return
        }
        syncPill.isHidden = false
        let (text, colorHex): (String, String)
        switch syncStatus {
        case .synced: (text, colorHex) = ("Synced", theme.ansiHex[2])
        case .localChanges: (text, colorHex) = ("Local changes", theme.ansiHex[3])
        case .syncing: (text, colorHex) = ("Syncing\u{2026}", theme.accentHex)
        case .failed(let reason):
            (text, colorHex) = ("Failed", theme.ansiHex[1])
            syncPill.toolTip = reason
        }
        if case .failed = syncStatus {} else {
            syncPill.toolTip = nil
        }
        ToolRowLayout.pill(text: text, colorHex: colorHex, into: syncPill, label: syncPillLabel)
        // Mono pill text, per the mockup's `--mono` role for pill labels -
        // `ToolRowLayout.pill` is shared app-wide and stays sans for its
        // other callers (Updates/Bootstrap rows), so the override happens
        // here rather than in the shared helper.
        syncPillLabel.font = ShiftFont.mono(10.5, weight: .semibold)
    }

    private func buildStatsRow() {
        statsRow.orientation = .horizontal
        statsRow.distribution = .fillEqually
        statsRow.spacing = 10
        statsRow.translatesAutoresizingMaskIntoConstraints = false
    }

    private func statTile(icon: String, value: String, label: String, tint: HelmTint = .neutral) -> NSView {
        let container = NSView()
        container.wantsLayer = true
        container.layer?.cornerRadius = 10
        container.translatesAutoresizingMaskIntoConstraints = false

        let iconView = NSImageView()
        iconView.image = NSImage(systemSymbolName: icon, accessibilityDescription: label)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 11, weight: .medium))
        iconView.translatesAutoresizingMaskIntoConstraints = false

        let valueLabel = NSTextField(labelWithString: value)
        valueLabel.font = ShiftFont.mono(19, weight: .semibold)

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
        stashedTileParts.append((container, valueLabel, nameLabel, tint))
        return container
    }

    /// A panel header row: icon + serif title + a small muted monospace
    /// count badge (the mockup's `.cnt` - "My Tasks 12", not text baked into
    /// the title itself) + an optional "+" add action. `countBadge` is
    /// `nil` for sections (Projects) that don't need a live count.
    private func sectionHeaderRow(
        iconSymbol: String, label: NSTextField, countBadge: NSTextField? = nil,
        addAction: Selector? = nil, addTooltip: String? = nil
    ) -> NSStackView {
        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: iconSymbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold))
        label.font = ShiftFont.serif(15)
        var views: [NSView] = [icon, label]
        if let countBadge {
            countBadge.font = ShiftFont.mono(11, weight: .medium)
            views.append(countBadge)
        }
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
        let headerRow = sectionHeaderRow(
            iconSymbol: "checklist", label: tasksHeader, countBadge: tasksCountBadge,
            addAction: #selector(newTaskClicked), addTooltip: "New Task (\u{2318}N)"
        )

        taskListScroll.documentView = taskListView.tableView
        taskListScroll.hasVerticalScroller = true
        taskListScroll.hasHorizontalScroller = false
        taskListScroll.borderType = .noBorder
        taskListScroll.drawsBackground = false
        taskListScroll.translatesAutoresizingMaskIntoConstraints = false
        taskListScroll.heightAnchor.constraint(equalToConstant: 300).isActive = true

        taskPanel.setHeader(headerRow)
        taskPanel.setBody(taskListScroll)
        taskPanel.translatesAutoresizingMaskIntoConstraints = false
        return taskPanel
    }

    private func buildFollowUpSection() -> NSView {
        let headerRow = sectionHeaderRow(
            iconSymbol: "bell", label: followUpsHeader, countBadge: followUpsCountBadge,
            addAction: #selector(newFollowUpClicked), addTooltip: "New Follow-up (\u{2318}\u{21e7}F)"
        )

        followUpScroll.documentView = followUpListView.tableView
        followUpScroll.hasVerticalScroller = true
        followUpScroll.hasHorizontalScroller = false
        followUpScroll.borderType = .noBorder
        followUpScroll.drawsBackground = false
        followUpScroll.translatesAutoresizingMaskIntoConstraints = false
        followUpScroll.heightAnchor.constraint(equalToConstant: 220).isActive = true

        followUpPanel.setHeader(headerRow)
        followUpPanel.setBody(followUpScroll)
        followUpPanel.translatesAutoresizingMaskIntoConstraints = false
        return followUpPanel
    }

    /// The Projects section (cockpit-shift-projects, phase 3): a real
    /// wrapping grid of project cards - see `ShiftProjectCardView` - or, once
    /// a card is clicked, that project's own detail (edit form + task list
    /// with nested subtasks). `NSStackView` rendering (not a table) is still
    /// fine here: a captain's project count is nowhere near the scale that
    /// justified a table view for tasks/follow-ups.
    private func buildProjectsSection() -> NSView {
        let headerRow = sectionHeaderRow(iconSymbol: "shippingbox", label: projectsHeader, countBadge: projectsCountBadge)

        projectsGridContainer.orientation = .vertical
        projectsGridContainer.alignment = .leading
        projectsGridContainer.spacing = Self.projectCardSpacing
        projectsGridContainer.translatesAutoresizingMaskIntoConstraints = false

        projectsDetailContainer.orientation = .vertical
        projectsDetailContainer.alignment = .leading
        projectsDetailContainer.spacing = 14
        projectsDetailContainer.translatesAutoresizingMaskIntoConstraints = false
        buildDetailChrome()

        let section = NSStackView(views: [headerRow, projectsGridContainer, projectsDetailContainer])
        section.orientation = .vertical
        section.alignment = .leading
        section.spacing = 8
        section.translatesAutoresizingMaskIntoConstraints = false
        projectsGridContainer.widthAnchor.constraint(equalTo: section.widthAnchor).isActive = true
        projectsDetailContainer.widthAnchor.constraint(equalTo: section.widthAnchor).isActive = true
        return section
    }

    // MARK: Weekly Review

    /// The mockup's `.shift-nav .item` tab look, as two clickable
    /// `HoverHighlightView`s rather than an `NSSegmentedControl` - the same
    /// custom-pill-control convention the Updates page's All/Needs-attention
    /// filter already established (see AGENTS.md's Tools section).
    private func buildTabRow() -> NSView {
        let dashboardRow = tabItem(dashboardTab, label: dashboardTabLabel, action: #selector(dashboardTabClicked))
        let reviewRow = tabItem(reviewTab, label: reviewTabLabel, action: #selector(reviewTabClicked))
        let row = NSStackView(views: [dashboardRow, reviewRow])
        row.orientation = .horizontal
        row.spacing = 6
        row.translatesAutoresizingMaskIntoConstraints = false
        return row
    }

    private func tabItem(_ container: HoverHighlightView, label: NSTextField, action: Selector) -> NSView {
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.translatesAutoresizingMaskIntoConstraints = false
        container.cornerRadius = 7
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 10),
            label.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -10),
            label.topAnchor.constraint(equalTo: container.topAnchor, constant: 6),
            label.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -6),
        ])
        let click = NSClickGestureRecognizer(target: self, action: action)
        container.addGestureRecognizer(click)
        return container
    }

    @objc private func dashboardTabClicked() { switchTopLevelView(.dashboard) }
    @objc private func reviewTabClicked() { switchTopLevelView(.weeklyReview) }

    private func switchTopLevelView(_ view: ShiftTopLevelView) {
        topLevelView = view
        dashboardContainer.isHidden = view != .dashboard
        weeklyReviewContainer.isHidden = view != .weeklyReview
        if view == .weeklyReview { renderWeeklyReview() }
        applyTheme()
    }

    /// The Shift menu / search palette's entry point into Weekly Review -
    /// selects the tab exactly like clicking it would.
    func showWeeklyReview() { switchTopLevelView(.weeklyReview) }

    /// Back to the daily dashboard - used after navigating here to open a
    /// task/follow-up/project found via search or the menu bar popover.
    func showDashboard() { switchTopLevelView(.dashboard) }

    private func buildWeeklyReviewSection() -> NSView {
        reviewGreeting.font = ShiftFont.serif(19)
        reviewSubtitle.font = .systemFont(ofSize: 12)
        let textStack = NSStackView(views: [reviewGreeting, reviewSubtitle])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 4
        textStack.translatesAutoresizingMaskIntoConstraints = false

        reviewStatsRow.orientation = .horizontal
        reviewStatsRow.distribution = .fillEqually
        reviewStatsRow.spacing = 10
        reviewStatsRow.translatesAutoresizingMaskIntoConstraints = false

        let headerRow = sectionHeaderRow(iconSymbol: "arrow.uturn.backward", label: reviewPushedBackHeader)

        reviewPushedBackStack.orientation = .vertical
        reviewPushedBackStack.alignment = .leading
        reviewPushedBackStack.spacing = 0
        reviewPushedBackStack.translatesAutoresizingMaskIntoConstraints = false
        reviewPushedBackPanel.setHeader(headerRow)
        reviewPushedBackPanel.setBody(reviewPushedBackStack)
        reviewPushedBackPanel.translatesAutoresizingMaskIntoConstraints = false

        weeklyReviewContainer.orientation = .vertical
        weeklyReviewContainer.alignment = .leading
        weeklyReviewContainer.spacing = 20
        weeklyReviewContainer.translatesAutoresizingMaskIntoConstraints = false
        weeklyReviewContainer.isHidden = true
        weeklyReviewContainer.addArrangedSubview(textStack)
        weeklyReviewContainer.addArrangedSubview(reviewStatsRow)
        weeklyReviewContainer.addArrangedSubview(reviewPushedBackPanel)
        textStack.widthAnchor.constraint(equalTo: weeklyReviewContainer.widthAnchor).isActive = true
        reviewStatsRow.widthAnchor.constraint(equalTo: weeklyReviewContainer.widthAnchor).isActive = true
        reviewPushedBackPanel.widthAnchor.constraint(equalTo: weeklyReviewContainer.widthAnchor).isActive = true
        return weeklyReviewContainer
    }

    private func renderWeeklyReview() {
        let summary = store.weeklySummary()
        reviewGreeting.stringValue = summary.weekLabel

        for v in reviewStatsRow.arrangedSubviews {
            reviewStatsRow.removeArrangedSubview(v)
            v.removeFromSuperview()
        }
        reviewStashedTileParts.removeAll()
        reviewStatsRow.addArrangedSubview(reviewStatTile(icon: "checkmark.circle", value: "\(summary.completedCount)", label: "completed this week"))
        reviewStatsRow.addArrangedSubview(reviewStatTile(icon: "arrow.uturn.backward", value: "\(summary.pushedBack.count)", label: "pushed back 2+ times", tint: .warn))
        reviewStatsRow.addArrangedSubview(reviewStatTile(icon: "calendar", value: "\(summary.upcomingCount)", label: "coming up next week"))

        for v in reviewPushedBackStack.arrangedSubviews {
            reviewPushedBackStack.removeArrangedSubview(v)
            v.removeFromSuperview()
        }
        if summary.pushedBack.isEmpty {
            let empty = ShiftEmptyStateView(symbol: "checkmark.seal", text: "Nothing's been pushed back more than once.")
            empty.applyTheme(theme)
            empty.translatesAutoresizingMaskIntoConstraints = false
            empty.heightAnchor.constraint(equalToConstant: 90).isActive = true
            reviewPushedBackStack.addArrangedSubview(empty)
            empty.widthAnchor.constraint(equalTo: reviewPushedBackStack.widthAnchor).isActive = true
        } else {
            for item in summary.pushedBack {
                let row = reviewPushedBackRow(item)
                reviewPushedBackStack.addArrangedSubview(row)
                row.widthAnchor.constraint(equalTo: reviewPushedBackStack.widthAnchor).isActive = true
            }
        }
        applyTheme()
    }

    /// Duplicates `statTile`'s layout rather than sharing its `stashedTileParts`
    /// array - the dashboard and Weekly Review stat rows are rebuilt
    /// independently (only one is ever visible), and sharing one array would
    /// mean whichever rebuilds last wins the next `applyTheme()` pass for
    /// both.
    private func reviewStatTile(icon: String, value: String, label: String, tint: HelmTint = .neutral) -> NSView {
        let container = NSView()
        container.wantsLayer = true
        container.layer?.cornerRadius = 10
        container.translatesAutoresizingMaskIntoConstraints = false

        let iconView = NSImageView()
        iconView.image = NSImage(systemSymbolName: icon, accessibilityDescription: label)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 11, weight: .medium))
        iconView.translatesAutoresizingMaskIntoConstraints = false

        let valueLabel = NSTextField(labelWithString: value)
        valueLabel.font = ShiftFont.mono(19, weight: .semibold)

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
        reviewStashedTileParts.append((container, valueLabel, nameLabel, tint))
        return container
    }

    private func reviewPushedBackRow(_ item: ShiftPushedBackItem) -> NSView {
        let titleLabel = NSTextField(labelWithString: item.title)
        titleLabel.font = .systemFont(ofSize: 12.5, weight: .medium)
        titleLabel.textColor = HelmTheme.nsColor(theme.chromeInkHex)
        titleLabel.lineBreakMode = .byTruncatingTail

        var metaText = "Pushed back \(item.count) times"
        if let projectName = item.projectName { metaText += " \u{00B7} \(projectName)" }
        let metaLabel = NSTextField(labelWithString: metaText)
        metaLabel.font = .systemFont(ofSize: 10.5)
        metaLabel.textColor = HelmTheme.mutedInk(theme)

        let textStack = NSStackView(views: [titleLabel, metaLabel])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 3
        textStack.translatesAutoresizingMaskIntoConstraints = false

        let divider = NSView()
        divider.wantsLayer = true
        divider.layer?.backgroundColor = HelmTheme.nsColor(theme.chromeLineHex).withAlphaComponent(0.5).cgColor
        divider.translatesAutoresizingMaskIntoConstraints = false
        divider.heightAnchor.constraint(equalToConstant: 1).isActive = true

        let row = NSStackView(views: [divider, textStack])
        row.orientation = .vertical
        row.alignment = .leading
        row.spacing = 0
        row.translatesAutoresizingMaskIntoConstraints = false
        let padded = NSView()
        padded.translatesAutoresizingMaskIntoConstraints = false
        padded.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: padded.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: padded.trailingAnchor),
            row.topAnchor.constraint(equalTo: padded.topAnchor),
            row.bottomAnchor.constraint(equalTo: padded.bottomAnchor),
            divider.widthAnchor.constraint(equalTo: row.widthAnchor),
            textStack.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 16),
            textStack.trailingAnchor.constraint(lessThanOrEqualTo: row.trailingAnchor, constant: -16),
            textStack.topAnchor.constraint(equalTo: divider.bottomAnchor, constant: 12),
            textStack.bottomAnchor.constraint(equalTo: row.bottomAnchor, constant: -12),
        ])
        return padded
    }

    // MARK: Search / menu-bar navigation (phase 5)

    /// Opens the New/Edit Task sheet for a task found via ⌘⇧P search or the
    /// menu bar popover. Falls back silently if the id no longer resolves to
    /// an *active* task (a completed task isn't editable through this sheet -
    /// see `ShiftStore.updateTask`'s header) - the search index only offers
    /// active tasks in the first place, so this should always resolve.
    func openTask(id: String) {
        showDashboard()
        guard let task = store.activeTasks.first(where: { $0.id == id }) else { return }
        presentTaskEditor(for: task)
    }

    func openFollowUp(id: String) {
        showDashboard()
        guard let item = store.followUps.first(where: { $0.id == id }) else { return }
        presentFollowUpEditor(for: item)
    }

    func openProject(id: String) {
        showDashboard()
        guard store.projects.contains(where: { $0.id == id }) else { return }
        projectsView = .detail(id)
        render()
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
        tasksHeader.stringValue = "My Tasks"
        tasksCountBadge.stringValue = "\(tasks.count)"

        followUpListView.setItems(followUps)
        followUpsHeader.stringValue = "Follow-ups"
        followUpsCountBadge.stringValue = "\(pendingFollowUps.count) pending"

        renderProjectsSection()
        if topLevelView == .weeklyReview { renderWeeklyReview() }

        applyTheme()
    }

    private func renderProjectsSection() {
        switch projectsView {
        case .grid:
            projectsGridContainer.isHidden = false
            projectsDetailContainer.isHidden = true
            projectsHeader.stringValue = "Projects"
            projectsCountBadge.stringValue = "\(store.projects.count)"
            rebuildProjectsGrid()
        case .detail(let projectID):
            guard let project = store.projects.first(where: { $0.id == projectID }) else {
                // Deleted out from under the open detail view (not possible
                // in this phase - there's no delete action yet - but falling
                // back to the grid is the only sane thing to do if it ever
                // happens rather than showing a detail view for nothing).
                projectsView = .grid
                renderProjectsSection()
                return
            }
            projectsGridContainer.isHidden = true
            projectsDetailContainer.isHidden = false
            projectsHeader.stringValue = "Project: \(project.name)"
            rebuildProjectDetail(project)
        }
    }

    private func rebuildStats(tasksToday: Int, followUps: Int, overdue: Int) {
        for v in statsRow.arrangedSubviews {
            statsRow.removeArrangedSubview(v)
            v.removeFromSuperview()
        }
        stashedTileParts.removeAll()
        statsRow.addArrangedSubview(statTile(icon: "sun.max", value: "\(tasksToday)", label: "tasks today"))
        statsRow.addArrangedSubview(statTile(icon: "bell", value: "\(followUps)", label: "follow-ups"))
        statsRow.addArrangedSubview(statTile(icon: "exclamationmark.triangle", value: "\(overdue)", label: "overdue", tint: .critical))
    }

    // MARK: Projects - grid

    /// A real wrapping grid, columns computed from `projectsGridContainer`'s
    /// actual width - same `minCardWidth`/partial-row-padding shape
    /// `ToolsController.rebuildGrid` already settled on (see AGENTS.md's
    /// Tools section for the partial-row-stretch bug that padding avoids).
    private func rebuildProjectsGrid() {
        for v in projectsGridContainer.arrangedSubviews {
            projectsGridContainer.removeArrangedSubview(v)
            v.removeFromSuperview()
        }
        let projects = store.projects
        guard !projects.isEmpty else {
            // Built fresh each call (not the retained `projectsEmptyState`
            // property elsewhere) so its one-time width/height constraints
            // never accumulate across repeated rebuilds - `rebuildProjectsGrid`
            // removes the view from its superview each time but never tears
            // down constraints, which would otherwise pile up duplicates.
            let empty = ShiftEmptyStateView(symbol: "shippingbox", text: "No projects yet.\nCreate one to start tracking tasks against it.")
            empty.applyTheme(theme)
            empty.translatesAutoresizingMaskIntoConstraints = false
            empty.heightAnchor.constraint(equalToConstant: 110).isActive = true
            projectsGridContainer.addArrangedSubview(empty)
            empty.widthAnchor.constraint(equalTo: projectsGridContainer.widthAnchor).isActive = true
            return
        }

        let containerWidth = projectsGridContainer.frame.width > 0 ? projectsGridContainer.frame.width : 860
        let columnsPerRow = max(1, Int((containerWidth + Self.projectCardSpacing) / (Self.projectCardMinWidth + Self.projectCardSpacing)))

        let cards: [NSView] = projects.map { project in
            let (completed, total) = store.taskCounts(forProject: project.id)
            let card = ShiftProjectCardView()
            card.configure(project: project, completed: completed, total: total, theme: theme)
            card.onOpenDetail = { [weak self] in
                self?.projectsView = .detail(project.id)
                self?.render()
            }
            card.onStatusChange = { [weak self] newStatus in
                var updated = project
                updated.status = newStatus
                self?.store.updateProject(updated)
                self?.render()
            }
            return card
        }

        for chunk in cards.chunked(into: columnsPerRow) {
            var rowViews = chunk
            while rowViews.count < columnsPerRow { rowViews.append(NSView()) }
            let row = NSStackView(views: rowViews)
            row.orientation = .horizontal
            row.spacing = Self.projectCardSpacing
            row.distribution = .fillEqually
            row.translatesAutoresizingMaskIntoConstraints = false
            projectsGridContainer.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: projectsGridContainer.widthAnchor).isActive = true
        }
    }

    // MARK: Projects - detail

    /// Built once (in `buildProjectsSection`), never torn down and rebuilt -
    /// the fixed chrome (back button, edit form) needs to survive a
    /// `render()` triggered by something unrelated (a subtask toggle)
    /// without losing whatever the captain has half-typed into the form.
    /// Only the task list below it (`detailTasksStack`) is rebuilt every
    /// time - see `rebuildDetailTasks`.
    private let detailBackButton = NSButton(title: "\u{2039} Back to Projects", target: nil, action: nil)
    private let detailNameField = NSTextField()
    private let detailDescriptionField = NSTextField()
    private let detailStatusPopup = NSPopUpButton()
    private let detailStartDateField = NSTextField()
    private let detailDueDateField = NSTextField()
    private let detailSaveButton = NSButton(title: "Save", target: nil, action: nil)
    private let detailTasksHeader = NSTextField(labelWithString: "Tasks")
    private let detailTasksStack = NSStackView()
    private var lastDetailProjectID: String?

    private func buildDetailChrome() {
        detailBackButton.bezelStyle = .rounded
        detailBackButton.target = self
        detailBackButton.action = #selector(detailBackClicked)
        detailBackButton.translatesAutoresizingMaskIntoConstraints = false

        let form = buildDetailForm()

        detailTasksHeader.font = ShiftFont.serif(14)
        detailTasksStack.orientation = .vertical
        detailTasksStack.alignment = .leading
        detailTasksStack.spacing = 8
        detailTasksStack.translatesAutoresizingMaskIntoConstraints = false

        projectsDetailContainer.addArrangedSubview(detailBackButton)
        projectsDetailContainer.addArrangedSubview(form)
        projectsDetailContainer.addArrangedSubview(detailTasksHeader)
        projectsDetailContainer.addArrangedSubview(detailTasksStack)
        form.widthAnchor.constraint(equalTo: projectsDetailContainer.widthAnchor).isActive = true
        detailTasksStack.widthAnchor.constraint(equalTo: projectsDetailContainer.widthAnchor).isActive = true
    }

    private func buildDetailForm() -> NSView {
        let nameRow = formRow(label: "Name", field: detailNameField)
        let descRow = formRow(label: "Description", field: detailDescriptionField)
        let startRow = formRow(label: "Start date", field: detailStartDateField)
        let dueRow = formRow(label: "Due date", field: detailDueDateField)

        detailStatusPopup.removeAllItems()
        detailStatusPopup.addItems(withTitles: ShiftProjectStatus.allCases.map(\.displayName))
        detailStatusPopup.translatesAutoresizingMaskIntoConstraints = false
        detailStatusPopup.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let statusLabel = NSTextField(labelWithString: "Status")
        statusLabel.font = .systemFont(ofSize: 11.5)
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.widthAnchor.constraint(equalToConstant: 90).isActive = true
        statusLabel.setContentHuggingPriority(.required, for: .horizontal)
        statusLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        let statusRow = NSStackView(views: [statusLabel, detailStatusPopup])
        statusRow.orientation = .horizontal
        statusRow.spacing = 10
        statusRow.distribution = .fill
        statusRow.translatesAutoresizingMaskIntoConstraints = false

        detailSaveButton.bezelStyle = .rounded
        detailSaveButton.target = self
        detailSaveButton.action = #selector(detailSaveClicked)
        detailSaveButton.translatesAutoresizingMaskIntoConstraints = false

        let rows = [nameRow, descRow, statusRow, startRow, dueRow]
        let stack = NSStackView(views: rows + [detailSaveButton])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        for row in rows {
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        return stack
    }

    private func formRow(label text: String, field: NSTextField) -> NSStackView {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 11.5)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.widthAnchor.constraint(equalToConstant: 90).isActive = true
        label.setContentHuggingPriority(.required, for: .horizontal)
        label.setContentCompressionResistancePriority(.required, for: .horizontal)

        field.translatesAutoresizingMaskIntoConstraints = false
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let row = NSStackView(views: [label, field])
        row.orientation = .horizontal
        row.spacing = 10
        row.distribution = .fill
        row.translatesAutoresizingMaskIntoConstraints = false
        return row
    }

    /// Refreshes the task list unconditionally, and the edit form's field
    /// values only the first time this particular project is shown - a
    /// `render()` triggered by, say, a subtask toggle re-enters this with the
    /// same `project.id` and must not clobber an in-progress edit.
    private func rebuildProjectDetail(_ project: ShiftProject) {
        if lastDetailProjectID != project.id {
            lastDetailProjectID = project.id
            detailNameField.stringValue = project.name
            detailDescriptionField.stringValue = project.description
            detailStartDateField.stringValue = project.startDate ?? ""
            detailDueDateField.stringValue = project.dueDate ?? ""
            if let idx = ShiftProjectStatus.allCases.firstIndex(of: project.status) {
                detailStatusPopup.selectItem(at: idx)
            }
        }
        rebuildDetailTasks(project)
    }

    /// The one place subtasks render - nested under their parent task inside
    /// a project's detail, never as flat rows in the main My Tasks list
    /// above (see ShiftModels.swift's header for why that boundary matters).
    /// Includes both active and completed tasks, since a project's real task
    /// breakdown includes finished work, not just what's still open.
    private func rebuildDetailTasks(_ project: ShiftProject) {
        for v in detailTasksStack.arrangedSubviews {
            detailTasksStack.removeArrangedSubview(v)
            v.removeFromSuperview()
        }
        subtaskContainers.removeAll()
        let tasks = store.allTasks(forProject: project.id)
        guard !tasks.isEmpty else {
            let label = NSTextField(labelWithString: "No tasks in this project.")
            label.font = .systemFont(ofSize: 11.5)
            label.textColor = HelmTheme.mutedInk(theme)
            detailTasksStack.addArrangedSubview(label)
            return
        }
        for task in tasks {
            let block = detailTaskBlock(task)
            detailTasksStack.addArrangedSubview(block)
            block.widthAnchor.constraint(equalTo: detailTasksStack.widthAnchor).isActive = true
        }
    }

    private func detailTaskBlock(_ task: ShiftTask) -> NSView {
        let expanded = expandedTaskIDs.contains(task.id)
        let chevron = NSImageView()
        chevron.image = NSImage(
            systemSymbolName: expanded ? "chevron.down" : "chevron.right",
            accessibilityDescription: nil
        )?.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 9, weight: .semibold))

        let titleLabel = NSTextField(labelWithString: task.title)
        titleLabel.font = .systemFont(ofSize: 12.5, weight: .medium)
        titleLabel.textColor = HelmTheme.nsColor(theme.chromeInkHex)

        var bits: [String] = []
        if task.status == .completed { bits.append("Completed") }
        if !task.subtasks.isEmpty { bits.append("\(task.subtasks.filter(\.done).count)/\(task.subtasks.count) subtasks") }
        let statusLabel = NSTextField(labelWithString: bits.joined(separator: " \u{00B7} "))
        statusLabel.font = .systemFont(ofSize: 10.5)
        statusLabel.textColor = HelmTheme.mutedInk(theme)

        let headerRow = NSStackView(views: [chevron, titleLabel, statusLabel])
        headerRow.orientation = .horizontal
        headerRow.spacing = 8
        headerRow.alignment = .centerY
        headerRow.translatesAutoresizingMaskIntoConstraints = false

        let headerContainer = HoverHighlightView()
        headerContainer.cornerRadius = 6
        headerContainer.normalColor = .clear
        headerContainer.hoverColor = HelmTheme.nsColor(theme.chromeLineHex).withAlphaComponent(0.18)
        headerContainer.translatesAutoresizingMaskIntoConstraints = false
        headerContainer.addSubview(headerRow)
        NSLayoutConstraint.activate([
            headerRow.leadingAnchor.constraint(equalTo: headerContainer.leadingAnchor, constant: 6),
            headerRow.trailingAnchor.constraint(equalTo: headerContainer.trailingAnchor, constant: -6),
            headerRow.topAnchor.constraint(equalTo: headerContainer.topAnchor, constant: 5),
            headerRow.bottomAnchor.constraint(equalTo: headerContainer.bottomAnchor, constant: -5),
        ])
        let click = NSClickGestureRecognizer(target: self, action: #selector(detailTaskHeaderClicked(_:)))
        headerContainer.addGestureRecognizer(click)
        headerContainer.identifier = NSUserInterfaceItemIdentifier(task.id)

        let column = NSStackView(views: [headerContainer])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 4
        column.translatesAutoresizingMaskIntoConstraints = false
        headerContainer.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true

        guard expanded else { return column }

        if task.subtasks.isEmpty {
            let label = NSTextField(labelWithString: "No subtasks.")
            label.font = .systemFont(ofSize: 11)
            label.textColor = HelmTheme.mutedInk(theme)
            column.addArrangedSubview(label)
            return column
        }

        let subStack = NSStackView()
        subStack.orientation = .vertical
        subStack.alignment = .leading
        subStack.spacing = 4
        subStack.translatesAutoresizingMaskIntoConstraints = false
        for subtask in task.subtasks {
            let checkbox = NSButton(checkboxWithTitle: subtask.title, target: self, action: #selector(subtaskToggled(_:)))
            checkbox.state = subtask.done ? .on : .off
            checkbox.font = .systemFont(ofSize: 11.5)
            checkbox.identifier = NSUserInterfaceItemIdentifier("\(task.id)\u{0}\(subtask.id)")
            subStack.addArrangedSubview(checkbox)
        }
        let container = NSView()
        container.wantsLayer = true
        container.layer?.cornerRadius = 8
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(subStack)
        NSLayoutConstraint.activate([
            subStack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 24),
            subStack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            subStack.topAnchor.constraint(equalTo: container.topAnchor, constant: 8),
            subStack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -8),
        ])
        subtaskContainers.append(container)
        column.addArrangedSubview(container)
        container.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
        return column
    }

    @objc private func detailTaskHeaderClicked(_ sender: NSClickGestureRecognizer) {
        guard let id = sender.view?.identifier?.rawValue else { return }
        if expandedTaskIDs.contains(id) { expandedTaskIDs.remove(id) } else { expandedTaskIDs.insert(id) }
        render()
    }

    @objc private func detailBackClicked() {
        projectsView = .grid
        render()
    }

    @objc private func detailSaveClicked() {
        guard case .detail(let projectID) = projectsView,
              var project = store.projects.first(where: { $0.id == projectID }) else { return }
        project.name = detailNameField.stringValue
        project.description = detailDescriptionField.stringValue
        let statusIdx = detailStatusPopup.indexOfSelectedItem
        if statusIdx >= 0, statusIdx < ShiftProjectStatus.allCases.count {
            project.status = ShiftProjectStatus.allCases[statusIdx]
        }
        project.startDate = detailStartDateField.stringValue.isEmpty ? nil : detailStartDateField.stringValue
        project.dueDate = detailDueDateField.stringValue.isEmpty ? nil : detailDueDateField.stringValue
        store.updateProject(project)
        Toast.show(in: view, message: "Project saved")
        render()
    }

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
        detailTasksHeader.textColor = ink

        for (container, valueLabel, nameLabel, tint) in stashedTileParts {
            container.layer?.backgroundColor = surface.cgColor
            container.layer?.borderWidth = 1
            container.layer?.borderColor = line.withAlphaComponent(0.5).cgColor
            valueLabel.textColor = tint == .neutral ? ink : HelmTheme.nsColor(tint.hex(in: theme))
            nameLabel.textColor = muted
        }
        taskPanel.applyTheme(theme)
        followUpPanel.applyTheme(theme)
        tasksCountBadge.textColor = muted
        followUpsCountBadge.textColor = muted
        projectsCountBadge.textColor = muted
        for container in subtaskContainers {
            container.layer?.backgroundColor = surface.withAlphaComponent(0.6).cgColor
        }
        taskListView.applyTheme(theme)
        followUpListView.applyTheme(theme)
        applySyncPill()

        let accent = HelmTheme.nsColor(theme.accentHex)
        let accentTint = accent.withAlphaComponent(theme.mode == .dark ? 0.20 : 0.14)
        for (container, label, isActive) in [
            (dashboardTab, dashboardTabLabel, topLevelView == .dashboard),
            (reviewTab, reviewTabLabel, topLevelView == .weeklyReview),
        ] {
            container.normalColor = isActive ? accentTint : .clear
            container.hoverColor = isActive ? accentTint : line.withAlphaComponent(0.25)
            label.textColor = isActive ? accent : muted
            label.font = .systemFont(ofSize: 12, weight: isActive ? .semibold : .medium)
        }

        reviewGreeting.textColor = ink
        reviewSubtitle.textColor = muted
        reviewPushedBackHeader.textColor = ink
        for (container, valueLabel, nameLabel, tint) in reviewStashedTileParts {
            container.layer?.backgroundColor = surface.cgColor
            container.layer?.borderWidth = 1
            container.layer?.borderColor = line.withAlphaComponent(0.5).cgColor
            valueLabel.textColor = tint == .neutral ? ink : HelmTheme.nsColor(tint.hex(in: theme))
            nameLabel.textColor = muted
        }
        reviewPushedBackPanel.applyTheme(theme)
    }
}
