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
    private let taskPanel = HelmCard()

    private let followUpListView = ShiftFollowUpListView()
    private let followUpScroll = NSScrollView()
    private let followUpsHeader = NSTextField(labelWithString: "")
    private let followUpsCountBadge = NSTextField(labelWithString: "")
    private let followUpPanel = HelmCard()

    private let projectsHeader = NSTextField(labelWithString: "")
    private let projectsCountBadge = NSTextField(labelWithString: "")
    private let projectsPanel = HelmCard()
    private let projectsGridContainer = NSStackView()
    private let projectsDetailContainer = NSStackView()

    // MARK: Weekly Review (phase 5, cockpit-shift-power-features)

    /// The two-tab switcher living just below the header - "My Tasks" (the
    /// existing stats/task/follow-up/projects content, unchanged) and
    /// "Weekly Review" (a distinct summary view). This keeps Shift a single
    /// consolidated destination (the captain's phase-1 decision, restated in
    /// AGENTS.md) while still giving Weekly Review "its own view" rather than
    /// squeezing it into the daily dashboard.
    private enum ShiftTopLevelView { case dashboard, weeklyReview, commandLibrary }
    private var topLevelView: ShiftTopLevelView = .dashboard
    private let dashboardTab = HoverHighlightView()
    private let dashboardTabLabel = NSTextField(labelWithString: "My Tasks")
    private let reviewTab = HoverHighlightView()
    private let reviewTabLabel = NSTextField(labelWithString: "Weekly Review")
    private let dashboardContainer = NSStackView()
    private let weeklyReviewContainer = NSStackView()

    // MARK: DevOps Commands (fm/grandline-devops-command-library, Phase 1)

    /// A third tab alongside My Tasks/Weekly Review - see AGENTS.md's "Shift"
    /// section. Owns its own store: Phase 1 has no other consumer of the
    /// command library (search-palette/`⌘⇧P` integration is explicitly
    /// Phase 3 per the design doc), so there's no need to thread this through
    /// `AppShellController`'s init chain the way the shared `ShiftStore` is.
    private let commandLibraryStore = CommandLibraryStore()
    private lazy var commandLibraryView = CommandLibraryPageView(store: commandLibraryStore)
    private let commandsTab = HoverHighlightView()
    private let commandsTabLabel = NSTextField(labelWithString: "DevOps Commands")
    /// Wraps the three tab pills in one bordered/tinted segmented-control
    /// look (mockup: the tab row sits inside its own rounded, bordered
    /// group) instead of three loose pills floating in space - the same
    /// `segmentedBackground` idiom `UpdatesController`'s All/Needs Attention
    /// filter already established.
    private let tabsBackground = NSView()

    /// Phase 2 (fm/grandline-devops-command-library-phase2) - forward-don't-
    /// own, same convention as every other page's `onRunCommand`/`onRun`:
    /// `ShiftController` knows nothing about the console, `AppShellController`
    /// wires this to `ConsoleController.sendCommandLibraryTextToActiveTab`.
    var onSendCommandToTerminal: ((String) -> Void)?

    private let reviewGreeting = NSTextField(labelWithString: "")
    private let reviewSubtitle = NSTextField(labelWithString: "What got done, what got pushed back, what's coming.")
    private let reviewStatsRow = NSStackView()
    private var reviewStashedTileParts: [(container: NSView, valueLabel: NSTextField, nameLabel: NSTextField, tint: HelmTint)] = []
    private let reviewPushedBackPanel = HelmCard()
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

    private static let projectCardMinWidth: CGFloat = 260
    private static let projectCardSpacing: CGFloat = 12

    /// Shared fixed body height for the side-by-side My Tasks/Follow-ups
    /// panels (fm/grandline-shift-panel-height-scroll-fix). Both panels must
    /// always be the same height as each other regardless of how much - or
    /// how little - content either list holds; previously each scroll view
    /// had its own independent constant (300 for tasks, 220 for follow-ups),
    /// so the two cards never lined up once they sat side by side. A single
    /// shared constant on both `NSScrollView`s is what makes each list
    /// scroll internally once its content overflows, rather than the
    /// enclosing card growing to fit - see `buildTaskSection`/
    /// `buildFollowUpSection`.
    private static let taskFollowUpPanelBodyHeight: CGFloat = 280

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

        // Side by side, not stacked (captain ask): two equal-width columns,
        // matching this app's plain-horizontal-NSStackView convention for
        // multi-column layout elsewhere (e.g. `statsRow` itself). No
        // responsive breakpoint - this app has no existing convention for
        // that (unlike `ToolsController`'s grid, which recomputes column
        // count from measured width for a much larger, unbounded card
        // count), and a fixed two-column row is the simpler, consistent
        // choice for exactly two panels. `.fillEqually` sizes both panels to
        // the same width; each panel keeps its own fixed scroll height (see
        // `buildTaskSection`/`buildFollowUpSection`), so `.top` alignment
        // keeps them flush at the top rather than vertically centered
        // against each other.
        let tasksRow = NSStackView(views: [taskSection, followUpSection])
        tasksRow.orientation = .horizontal
        tasksRow.distribution = .fillEqually
        tasksRow.alignment = .top
        tasksRow.spacing = 20
        tasksRow.translatesAutoresizingMaskIntoConstraints = false

        dashboardContainer.orientation = .vertical
        dashboardContainer.alignment = .leading
        dashboardContainer.spacing = 20
        dashboardContainer.translatesAutoresizingMaskIntoConstraints = false
        dashboardContainer.addArrangedSubview(statsRow)
        dashboardContainer.addArrangedSubview(tasksRow)
        dashboardContainer.addArrangedSubview(projectsSection)

        let weeklyReviewSection = buildWeeklyReviewSection()
        commandLibraryView.view.translatesAutoresizingMaskIntoConstraints = false
        commandLibraryView.view.isHidden = true
        commandLibraryView.onSendToTerminal = { [weak self] text in self?.onSendCommandToTerminal?(text) }
        commandLibraryView.onPresentEditor = { [weak self] editor in
            guard let self else { return }
            self.presentAsSheet(editor)
        }

        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = 20
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        contentStack.addArrangedSubview(header)
        contentStack.addArrangedSubview(tabRow)
        contentStack.addArrangedSubview(dashboardContainer)
        contentStack.addArrangedSubview(weeklyReviewSection)
        contentStack.addArrangedSubview(commandLibraryView.view)

        content.addSubview(contentStack)
        NSLayoutConstraint.activate([
            contentStack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: HelmMetrics.pageGutter),
            contentStack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -HelmMetrics.pageGutter),
            contentStack.topAnchor.constraint(equalTo: content.topAnchor, constant: 24),
            contentStack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -28),
            dashboardContainer.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
            statsRow.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
            tasksRow.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
            projectsSection.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
            weeklyReviewSection.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
            commandLibraryView.view.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
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
        let syncPillClick = NSClickGestureRecognizer(target: self, action: #selector(syncPillClicked))
        syncPill.addGestureRecognizer(syncPillClick)
        applySyncPill()

        // `store.gitSync` is fixed for this controller's whole lifetime (a
        // `let` on `ShiftStore`, decided once at store construction by
        // whether `FM_SHIFT_DIR` was set), so whether the pill belongs in
        // the header at all is also decided once, here - rather than only
        // ever toggling its `isHidden` flag. This is deliberately stronger
        // than `isHidden`: a view never added as an arranged subview can't
        // be shown by any later code path that forgets this rule, and can't
        // report a stale on-screen frame to anything inspecting the view
        // tree (isHidden was already correct at every layer verified live -
        // see fm/cockpit-fix-shift-sync-pill - but leaving a real, non-empty
        // pill sitting hidden in the tree is an unnecessary trap for the
        // next person who touches this header).
        let row: NSStackView
        if store.gitSync != nil {
            row = NSStackView(views: [textStack, spacer, syncPill])
        } else {
            row = NSStackView(views: [textStack, spacer])
        }
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false
        return row
    }

    /// Reflects `ShiftGitSync`'s real status - never a timer or a fake cycle.
    /// `nil` `store.gitSync` (an explicit `FM_SHIFT_DIR` override with no git
    /// backing) means the pill was never added to the header at all (see
    /// `buildHeader()`) - nothing to style.
    private func applySyncPill() {
        guard store.gitSync != nil else { return }
        syncPill.isHidden = false
        let (text, colorHex): (String, String)
        switch syncStatus {
        case .synced: (text, colorHex) = ("Synced", theme.ansiHex[2])
        case .localChanges: (text, colorHex) = ("Local changes", theme.ansiHex[3])
        case .syncing: (text, colorHex) = ("Syncing\u{2026}", theme.accentHex)
        case .failed(let reason):
            (text, colorHex) = ("Failed", theme.ansiHex[1])
            syncPill.toolTip = reason
        case .conflict(let fileCount):
            (text, colorHex) = ("Conflict \u{2013} click to resolve", theme.ansiHex[1])
            syncPill.toolTip = "\(fileCount) file\(fileCount == 1 ? "" : "s") need a decision - click to resolve."
        }
        switch syncStatus {
        case .failed, .conflict: break
        default: syncPill.toolTip = nil
        }
        ToolRowLayout.pill(text: text, colorHex: colorHex, into: syncPill, label: syncPillLabel)
        // Mono pill text, per the mockup's `--mono` role for pill labels -
        // `ToolRowLayout.pill` is shared app-wide and stays sans for its
        // other callers (Updates/Bootstrap rows), so the override happens
        // here rather than in the shared helper.
        syncPillLabel.font = ShiftFont.mono(10.5, weight: .semibold)
    }

    /// Only meaningful while the pill is in `.conflict` - opens the
    /// resolution sheet. A click in any other state is a harmless no-op
    /// (the gesture recognizer is unconditionally attached rather than
    /// added/removed per state, since that's simpler and there is nothing
    /// to do for any other status anyway).
    @objc private func syncPillClicked() {
        guard case .conflict = syncStatus, let gitSync = store.gitSync, let conflictSet = gitSync.pendingConflictSet else { return }
        let resolver = ShiftConflictController(conflictSet: conflictSet)
        resolver.onResolve = { [weak self] choices, completion in
            gitSync.resolveConflictsAsync(choices: choices) { ok in
                completion(ok)
                if ok { self?.render() }
            }
        }
        presentAsSheet(resolver)
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
        taskListScroll.heightAnchor.constraint(equalToConstant: Self.taskFollowUpPanelBodyHeight).isActive = true

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
        followUpScroll.heightAnchor.constraint(equalToConstant: Self.taskFollowUpPanelBodyHeight).isActive = true

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
    ///
    /// The header row + grid are wrapped in `projectsPanel`, the same
    /// `HelmCard` `taskPanel`/`followUpPanel` already use
    /// (fm/grandline-shift-projects-panel-background) - previously this
    /// section sat directly on the page's plain background with no
    /// enclosing card, reading as a different kind of section next to My
    /// Tasks/Follow-ups. `projectsDetailContainer` (the full-page project
    /// detail) stays a sibling *outside* `projectsPanel`, not nested inside
    /// it - it already builds its own two `HelmCard`s
    /// (`detailFormPanel`/`detailTasksPanel`, see `buildDetailChrome`), so
    /// wrapping it in a third outer panel would double the border/background
    /// rather than match it.
    private func buildProjectsSection() -> NSView {
        let headerRow = sectionHeaderRow(
            iconSymbol: "shippingbox", label: projectsHeader, countBadge: projectsCountBadge,
            addAction: #selector(newProjectClicked), addTooltip: "New Project"
        )

        projectsGridContainer.orientation = .vertical
        projectsGridContainer.alignment = .leading
        projectsGridContainer.spacing = Self.projectCardSpacing
        projectsGridContainer.translatesAutoresizingMaskIntoConstraints = false

        projectsPanel.setHeader(headerRow)
        projectsPanel.setBody(projectsGridContainer)
        projectsPanel.translatesAutoresizingMaskIntoConstraints = false

        projectsDetailContainer.orientation = .vertical
        projectsDetailContainer.alignment = .leading
        projectsDetailContainer.spacing = 14
        projectsDetailContainer.translatesAutoresizingMaskIntoConstraints = false
        buildDetailChrome()

        let section = NSStackView(views: [projectsPanel, projectsDetailContainer])
        section.orientation = .vertical
        section.alignment = .leading
        section.spacing = 8
        section.translatesAutoresizingMaskIntoConstraints = false
        projectsPanel.widthAnchor.constraint(equalTo: section.widthAnchor).isActive = true
        projectsDetailContainer.widthAnchor.constraint(equalTo: section.widthAnchor).isActive = true
        return section
    }

    // MARK: Weekly Review

    /// The mockup's `.shift-nav .item` tab look, as three clickable
    /// `HoverHighlightView`s rather than an `NSSegmentedControl` - the same
    /// custom-pill-control convention the Updates page's All/Needs-attention
    /// filter already established (see AGENTS.md's Tools section). Wrapped
    /// in `tabsBackground` so the three read as one unified segmented
    /// control (mockup: a bordered, tinted group), not three pills loose on
    /// the page background.
    private func buildTabRow() -> NSView {
        let dashboardRow = tabItem(dashboardTab, label: dashboardTabLabel, action: #selector(dashboardTabClicked))
        let reviewRow = tabItem(reviewTab, label: reviewTabLabel, action: #selector(reviewTabClicked))
        let commandsRow = tabItem(commandsTab, label: commandsTabLabel, action: #selector(commandsTabClicked))
        let row = NSStackView(views: [dashboardRow, reviewRow, commandsRow])
        row.orientation = .horizontal
        row.spacing = 3
        row.translatesAutoresizingMaskIntoConstraints = false

        tabsBackground.wantsLayer = true
        tabsBackground.layer?.cornerRadius = 9
        tabsBackground.translatesAutoresizingMaskIntoConstraints = false
        tabsBackground.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: tabsBackground.leadingAnchor, constant: 3),
            row.trailingAnchor.constraint(equalTo: tabsBackground.trailingAnchor, constant: -3),
            row.topAnchor.constraint(equalTo: tabsBackground.topAnchor, constant: 3),
            row.bottomAnchor.constraint(equalTo: tabsBackground.bottomAnchor, constant: -3),
        ])
        tabsBackground.setContentHuggingPriority(.required, for: .horizontal)
        return tabsBackground
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
    @objc private func commandsTabClicked() { switchTopLevelView(.commandLibrary) }

    private func switchTopLevelView(_ view: ShiftTopLevelView) {
        topLevelView = view
        dashboardContainer.isHidden = view != .dashboard
        weeklyReviewContainer.isHidden = view != .weeklyReview
        commandLibraryView.view.isHidden = view != .commandLibrary
        if view == .weeklyReview { renderWeeklyReview() }
        if view == .commandLibrary { commandLibraryView.reloadAndRender() }
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
        if topLevelView == .commandLibrary { commandLibraryView.reloadAndRender() }

        applyTheme()
    }

    /// Whether a project's detail is the whole page right now - `statsRow`/
    /// `taskPanel`/`followUpPanel` and the Projects section's own panel
    /// (header + grid) all hide entirely (not just scrolled past) while
    /// true, matching how `switchTopLevelView` already hides
    /// `dashboardContainer` in favor of `weeklyReviewContainer`
    /// (fm/cockpit-fix-shift-project-detail-fullpage). The top-level
    /// greeting header and the My Tasks/Weekly Review tab row are
    /// deliberately left alone - they're app-level navigation chrome, not
    /// dashboard content, exactly as Weekly Review's own toggle already
    /// treats them.
    private func applyProjectDetailFullPage(_ isDetail: Bool) {
        statsRow.isHidden = isDetail
        taskPanel.isHidden = isDetail
        followUpPanel.isHidden = isDetail
        projectsPanel.isHidden = isDetail
    }

    private func renderProjectsSection() {
        switch projectsView {
        case .grid:
            applyProjectDetailFullPage(false)
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
            applyProjectDetailFullPage(true)
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
    //
    // Rebuilt to read like a real dedicated page (fm/cockpit-shift-project-
    // page-redesign) - "clicking a project should feel like clicking into a
    // Tool on the Tools page," per the captain's own comparison, not a form
    // squeezed into leftover space. Built once (in `buildProjectsSection`),
    // never torn down - the fixed chrome (back button, header, edit form,
    // task list) needs to survive a `render()` triggered by something
    // unrelated (a subtask toggle, an expand/collapse) without losing
    // whatever the captain has half-typed into the form. `detailTaskListView`
    // (an `NSTableView`, see `ShiftProjectDetailView.swift`) is refreshed on
    // every render; the edit form's field values only refresh the first time
    // a given project is shown - see `rebuildProjectDetail`.

    private let detailBackButton = NSButton(title: "\u{2039} Back to Projects", target: nil, action: nil)
    private let detailIconTile = IconTileView(size: 40, cornerRadius: 10)
    private let detailNameLabel = NSTextField(labelWithString: "")
    private let detailStatusPill = NSView()
    private let detailStatusPillLabel = NSTextField(labelWithString: "")
    private let detailMetaLabel = NSTextField(labelWithString: "")
    private let detailDescriptionLabel = NSTextField(wrappingLabelWithString: "")

    private let detailFormPanel = HelmCard()
    private let detailNameField = NSTextField()
    private let detailDescriptionField = NSTextField()
    private let detailStatusPopup = HelmPopUpButton()
    private let detailStartDateField = NSTextField()
    private let detailDueDateField = NSTextField()
    private let detailSaveButton = HelmButton(title: "Save", variant: .primary, target: nil, action: nil)

    private let detailTasksPanel = HelmCard()
    private let detailTasksHeader = NSTextField(labelWithString: "Tasks")
    private let detailTasksCountBadge = NSTextField(labelWithString: "")
    private let detailTaskListView = ShiftProjectTaskListView()
    private let detailTaskListScroll = NSScrollView()

    private var lastDetailProjectID: String?
    /// The project the detail page currently shows - kept separate from
    /// `lastDetailProjectID` (which only tracks "should the form re-fill")
    /// so "+ Add Task" always knows which project to pre-select, even on a
    /// `render()` that doesn't touch the form.
    private var currentDetailProjectID: String?

    private func buildDetailChrome() {
        detailBackButton.isBordered = false
        detailBackButton.contentTintColor = nil
        detailBackButton.target = self
        detailBackButton.action = #selector(detailBackClicked)
        detailBackButton.font = .systemFont(ofSize: 12, weight: .medium)
        detailBackButton.translatesAutoresizingMaskIntoConstraints = false

        let header = buildDetailHeader()
        let form = buildDetailForm()
        detailFormPanel.setHeader(sectionHeaderRow(iconSymbol: "pencil", label: NSTextField(labelWithString: "Details")))
        detailFormPanel.setBody(form)
        detailFormPanel.translatesAutoresizingMaskIntoConstraints = false

        let tasksHeaderRow = sectionHeaderRow(
            iconSymbol: "checklist", label: detailTasksHeader, countBadge: detailTasksCountBadge,
            addAction: #selector(addTaskToProjectClicked), addTooltip: "Add Task"
        )
        detailTaskListScroll.documentView = detailTaskListView.tableView
        detailTaskListScroll.hasVerticalScroller = true
        detailTaskListScroll.hasHorizontalScroller = false
        detailTaskListScroll.borderType = .noBorder
        detailTaskListScroll.drawsBackground = false
        detailTaskListScroll.translatesAutoresizingMaskIntoConstraints = false
        detailTaskListScroll.heightAnchor.constraint(equalToConstant: 280).isActive = true
        detailTasksPanel.setHeader(tasksHeaderRow)
        detailTasksPanel.setBody(detailTaskListScroll)
        detailTasksPanel.translatesAutoresizingMaskIntoConstraints = false

        detailTaskListView.onToggleExpand = { [weak self] taskID in
            guard let self else { return }
            if self.expandedTaskIDs.contains(taskID) { self.expandedTaskIDs.remove(taskID) } else { self.expandedTaskIDs.insert(taskID) }
            self.render()
        }
        detailTaskListView.onToggleTaskCompleted = { [weak self] task in
            self?.store.setTaskCompleted(id: task.id, completed: task.status != .completed)
            self?.render()
        }
        detailTaskListView.onToggleSubtask = { [weak self] taskID, subtaskID, done in
            self?.store.setSubtaskDone(taskID: taskID, subtaskID: subtaskID, done: done)
            self?.render()
        }
        detailTaskListView.onOpenTask = { [weak self] task in
            self?.presentTaskEditor(for: task)
        }

        projectsDetailContainer.addArrangedSubview(detailBackButton)
        projectsDetailContainer.addArrangedSubview(header)
        projectsDetailContainer.addArrangedSubview(detailFormPanel)
        projectsDetailContainer.addArrangedSubview(detailTasksPanel)
        header.widthAnchor.constraint(equalTo: projectsDetailContainer.widthAnchor).isActive = true
        detailFormPanel.widthAnchor.constraint(equalTo: projectsDetailContainer.widthAnchor).isActive = true
        detailTasksPanel.widthAnchor.constraint(equalTo: projectsDetailContainer.widthAnchor).isActive = true
    }

    /// The page-header block: an icon tile, the project name as a real
    /// serif title (matching My Tasks' own greeting treatment), a read-only
    /// status pill + start/due date meta line, and the description as a
    /// wrapping paragraph - all presentation, no input fields. Editing lives
    /// entirely in the "Details" panel below, so there is exactly one place
    /// that changes a project's fields, not a header control and a form both
    /// claiming to own status.
    private func buildDetailHeader() -> NSView {
        detailIconTile.configure(symbol: "shippingbox", tint: .accent)

        detailNameLabel.font = ShiftFont.serif(22)
        detailNameLabel.lineBreakMode = .byTruncatingTail

        detailStatusPillLabel.font = ShiftFont.mono(10.5, weight: .semibold)
        detailStatusPillLabel.translatesAutoresizingMaskIntoConstraints = false
        detailStatusPill.wantsLayer = true
        detailStatusPill.layer?.cornerRadius = 8
        detailStatusPill.translatesAutoresizingMaskIntoConstraints = false
        detailStatusPill.addSubview(detailStatusPillLabel)
        NSLayoutConstraint.activate([
            detailStatusPillLabel.leadingAnchor.constraint(equalTo: detailStatusPill.leadingAnchor, constant: 8),
            detailStatusPillLabel.trailingAnchor.constraint(equalTo: detailStatusPill.trailingAnchor, constant: -8),
            detailStatusPillLabel.topAnchor.constraint(equalTo: detailStatusPill.topAnchor, constant: 3),
            detailStatusPillLabel.bottomAnchor.constraint(equalTo: detailStatusPill.bottomAnchor, constant: -3),
        ])
        detailStatusPill.setContentHuggingPriority(.required, for: .horizontal)

        detailMetaLabel.font = .systemFont(ofSize: 11)

        let metaRow = NSStackView(views: [detailStatusPill, detailMetaLabel])
        metaRow.orientation = .horizontal
        metaRow.alignment = .centerY
        metaRow.spacing = 10
        metaRow.translatesAutoresizingMaskIntoConstraints = false

        detailDescriptionLabel.font = .systemFont(ofSize: 12.5)
        detailDescriptionLabel.preferredMaxLayoutWidth = 640
        detailDescriptionLabel.lineBreakMode = .byWordWrapping

        let textStack = NSStackView(views: [detailNameLabel, metaRow, detailDescriptionLabel])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 8
        textStack.translatesAutoresizingMaskIntoConstraints = false
        detailDescriptionLabel.widthAnchor.constraint(equalTo: textStack.widthAnchor).isActive = true

        let row = NSStackView(views: [detailIconTile, textStack])
        row.orientation = .horizontal
        row.alignment = .top
        row.spacing = 14
        row.translatesAutoresizingMaskIntoConstraints = false
        return row
    }

    /// The editable field set, laid out in an `NSGridView` (the same
    /// approach `ShiftTaskEditorController`'s sheet uses) rather than a
    /// hand-stacked column of rows - a fixed, right-aligned label column and
    /// a fill-width field column read as a real form, not a raw debug
    /// dump of controls.
    private func buildDetailForm() -> NSView {
        for field in [detailNameField, detailDescriptionField, detailStartDateField, detailDueDateField] {
            styleDetailFormField(field)
        }
        detailNameField.translatesAutoresizingMaskIntoConstraints = false
        detailDescriptionField.translatesAutoresizingMaskIntoConstraints = false

        detailStatusPopup.removeAllItems()
        detailStatusPopup.addItems(withTitles: ShiftProjectStatus.allCases.map(\.displayName))
        detailStatusPopup.translatesAutoresizingMaskIntoConstraints = false

        detailStartDateField.placeholderString = "YYYY-MM-DD"
        detailStartDateField.translatesAutoresizingMaskIntoConstraints = false
        detailDueDateField.placeholderString = "YYYY-MM-DD"
        detailDueDateField.translatesAutoresizingMaskIntoConstraints = false

        let grid = NSGridView(views: [
            [gridLabel("Name"), detailNameField],
            [gridLabel("Description"), detailDescriptionField],
            [gridLabel("Status"), detailStatusPopup],
            [gridLabel("Start date"), detailStartDateField],
            [gridLabel("Due date"), detailDueDateField],
        ])
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.rowSpacing = 14
        grid.columnSpacing = 14
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 0).width = 100
        grid.column(at: 1).xPlacement = .fill

        detailSaveButton.target = self
        detailSaveButton.action = #selector(detailSaveClicked)
        detailSaveButton.translatesAutoresizingMaskIntoConstraints = false

        let saveRow = NSStackView(views: [NSView(), detailSaveButton])
        saveRow.orientation = .horizontal
        saveRow.distribution = .fill
        saveRow.translatesAutoresizingMaskIntoConstraints = false
        saveRow.arrangedSubviews[0].setContentHuggingPriority(.defaultLow, for: .horizontal)

        let stack = NSStackView(views: [grid, saveRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 18
        stack.translatesAutoresizingMaskIntoConstraints = false
        grid.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        saveRow.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        return stack
    }

    private func gridLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 12)
        return label
    }

    /// Removes the stock system bezel and hands the whole look to an
    /// explicit `HelmTheme`-derived fill/border (recolored in `applyTheme()`)
    /// - these four fields sit directly on this page's own dark, custom
    /// background, not inside a sheet with its own system chrome, and the
    /// stock bezel rendered as an off-theme brownish box in that context
    /// (a real, captain-reported bug, `fm/grandline-shift-project-detail-
    /// theming`). Mirrors `ConsoleComposerViewController`'s identical fix for
    /// its own intent/code fields - `isBordered`/`drawsBackground` off,
    /// `wantsLayer` on with a masked, rounded layer so the field's own
    /// background paint (not just its border) respects the corner radius.
    private func styleDetailFormField(_ field: NSTextField) {
        field.isBordered = false
        field.isBezeled = false
        field.focusRingType = .none
        field.drawsBackground = true
        field.wantsLayer = true
        field.layer?.masksToBounds = true
        field.layer?.cornerRadius = 5
        field.layer?.borderWidth = 1
        field.heightAnchor.constraint(equalToConstant: 26).isActive = true
    }

    /// The detail form's "sunken field" fill - blends `chromeInkHex` into
    /// `detailFormPanel`'s own `chromeBackgroundHex` fill rather than reusing
    /// `backgroundHex` directly, so the field reads as a distinct control
    /// even in the themes where those two tokens are numerically identical
    /// (see `ConsoleComposerPopover.fieldFillColor(for:)`'s own doc comment
    /// for the confirmed list of themes this matters for).
    private static func detailFieldFillColor(for theme: HelmTheme) -> NSColor {
        let chromeBackground = HelmTheme.nsColor(theme.chromeBackgroundHex)
        let ink = HelmTheme.nsColor(theme.chromeInkHex)
        return chromeBackground.blended(withFraction: 0.08, of: ink) ?? chromeBackground
    }

    /// Refreshes the header + task list unconditionally, and the edit form's
    /// field values only the first time this particular project is shown - a
    /// `render()` triggered by, say, a subtask toggle re-enters this with the
    /// same `project.id` and must not clobber an in-progress edit.
    private func rebuildProjectDetail(_ project: ShiftProject) {
        currentDetailProjectID = project.id
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
        applyDetailHeader(project)
        rebuildDetailTasks(project)
    }

    private func applyDetailHeader(_ project: ShiftProject) {
        detailNameLabel.stringValue = project.name
        var meta: [String] = []
        if let start = project.startDate { meta.append("Starts \(ShiftDateFormatting.friendly(start))") }
        if let due = project.dueDate { meta.append("Due \(ShiftDateFormatting.friendly(due))") }
        detailMetaLabel.stringValue = meta.joined(separator: "  \u{00B7}  ")
        detailDescriptionLabel.stringValue = project.description
        detailDescriptionLabel.isHidden = project.description.isEmpty
        applyDetailStatusPill(project.status)
    }

    private func applyDetailStatusPill(_ status: ShiftProjectStatus) {
        let tint: HelmTint = {
            switch status {
            case .notStarted: return .neutral
            case .inProgress: return .info
            case .onHold: return .warn
            case .completed: return .good
            case .archived: return .critical
            }
        }()
        let color = HelmTheme.nsColor(tint.hex(in: theme))
        detailStatusPill.layer?.backgroundColor = color.withAlphaComponent(0.16).cgColor
        detailStatusPillLabel.stringValue = status.displayName
        detailStatusPillLabel.textColor = color
    }

    /// The one place subtasks render - nested under their parent task inside
    /// a project's detail, never as flat rows in the main My Tasks list
    /// above (see ShiftModels.swift's header for why that boundary matters).
    /// Includes both active and completed tasks, since a project's real task
    /// breakdown includes finished work, not just what's still open.
    private func rebuildDetailTasks(_ project: ShiftProject) {
        let tasks = store.allTasks(forProject: project.id)
        detailTasksCountBadge.stringValue = "\(tasks.count)"
        detailTaskListView.setTasks(tasks, expandedTaskIDs: expandedTaskIDs)
        detailTaskListView.applyTheme(theme)
    }

    @objc private func detailBackClicked() {
        projectsView = .grid
        render()
    }

    /// "+ Add Task" (fm/cockpit-shift-project-page-redesign) - opens the
    /// same New Task sheet the My Tasks header's "+" uses, pre-selecting
    /// the project currently open. `presentTaskEditor`'s existing `onSave`
    /// calls `render()`, which re-enters `rebuildProjectDetail` for this
    /// same project and re-reads `store.allTasks(forProject:)` - the new
    /// task appears immediately, no navigation required.
    @objc private func addTaskToProjectClicked() {
        presentTaskEditor(for: nil, defaultProjectID: currentDetailProjectID)
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

    // MARK: Creation / editing (phase 2)

    /// The Shift menu's "New Task…" (⌘N) - also reachable from the My Tasks
    /// header's "+" button.
    func presentNewTaskEditor() { presentTaskEditor(for: nil) }

    /// The Shift menu's "New Follow-up…" (⌘⇧F) - also reachable from the
    /// Follow-ups header's "+" button.
    func presentNewFollowUpEditor() { presentFollowUpEditor(for: nil) }

    /// The Shift menu's "New Project…" - also reachable from the Projects
    /// header's "+" button (cockpit-fix-shift-new-project).
    func presentNewProjectEditor() { presentProjectEditor() }

    @objc private func newTaskClicked() { presentTaskEditor(for: nil) }
    @objc private func newFollowUpClicked() { presentFollowUpEditor(for: nil) }
    @objc private func newProjectClicked() { presentProjectEditor() }

    private func presentTaskEditor(for task: ShiftTask?, defaultProjectID: String? = nil) {
        let existingAttachmentData = (task?.hasAttachment ?? false) ? store.attachmentData(forTaskID: task!.id) : nil
        let editor = ShiftTaskEditorController(
            task: task, projects: store.projects, defaultProjectID: defaultProjectID,
            existingAttachmentData: existingAttachmentData
        )
        editor.onSave = { [weak self] saved, attachmentChange in
            guard let self else { return }
            if task != nil {
                self.store.updateTask(saved, attachment: attachmentChange)
            } else {
                self.store.addTask(saved, attachment: attachmentChange)
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

    /// Presents the New Project sheet (cockpit-fix-shift-new-project) - the
    /// grid re-renders immediately on save so the new project shows up
    /// without navigating away and back, exactly like a new task/follow-up.
    private func presentProjectEditor() {
        let editor = ShiftProjectEditorController()
        editor.onSave = { [weak self] saved in
            guard let self else { return }
            self.store.addProject(saved)
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
        projectsPanel.applyTheme(theme)
        tasksCountBadge.textColor = muted
        followUpsCountBadge.textColor = muted
        projectsCountBadge.textColor = muted
        taskListView.applyTheme(theme)
        followUpListView.applyTheme(theme)
        applySyncPill()

        detailBackButton.contentTintColor = muted
        detailIconTile.applyTheme(theme)
        detailNameLabel.textColor = ink
        detailMetaLabel.textColor = muted
        detailDescriptionLabel.textColor = muted
        detailFormPanel.applyTheme(theme)
        let fieldFill = Self.detailFieldFillColor(for: theme)
        for field in [detailNameField, detailDescriptionField, detailStartDateField, detailDueDateField] {
            field.textColor = ink
            field.backgroundColor = fieldFill
            field.layer?.borderColor = line.withAlphaComponent(0.7).cgColor
        }
        detailStatusPopup.contentTintColor = ink
        detailTasksPanel.applyTheme(theme)
        detailTasksCountBadge.textColor = muted
        if case .detail(let projectID) = projectsView, let project = store.projects.first(where: { $0.id == projectID }) {
            applyDetailStatusPill(project.status)
        }
        detailTaskListView.applyTheme(theme)

        let accent = HelmTheme.nsColor(theme.accentHex)
        let accentTint = accent.withAlphaComponent(theme.mode == .dark ? 0.20 : 0.14)
        tabsBackground.layer?.backgroundColor = surface.withAlphaComponent(0.6).cgColor
        tabsBackground.layer?.borderWidth = 1
        tabsBackground.layer?.borderColor = line.withAlphaComponent(0.5).cgColor
        for (container, label, isActive) in [
            (dashboardTab, dashboardTabLabel, topLevelView == .dashboard),
            (reviewTab, reviewTabLabel, topLevelView == .weeklyReview),
            (commandsTab, commandsTabLabel, topLevelView == .commandLibrary),
        ] {
            container.normalColor = isActive ? accentTint : .clear
            container.hoverColor = isActive ? accentTint : line.withAlphaComponent(0.25)
            label.textColor = isActive ? accent : muted
            label.font = .systemFont(ofSize: 12, weight: isActive ? .semibold : .medium)
        }
        commandLibraryView.applyTheme(theme)

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
