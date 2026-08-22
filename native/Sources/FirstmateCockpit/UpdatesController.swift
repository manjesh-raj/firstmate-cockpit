// Manjesh Grand Line - native macOS app.
//
// "Firstmate Latest Updates" - the new `.updates` rail destination (rail icon
// pinned directly above Settings). Lists every tool in the captain's
// ecosystem, checks each for updates automatically on page load, and lets the
// captain apply an update with one explicit click per row. Laid out with the
// same card-section/row visual density as `SettingsController` (card chrome,
// row style, `FlippedView` + `scrollToTop()` for the same "empty gap above
// the header" fix that page already carries) rather than inventing a new
// layout language.
//
// Interaction flow (captain-specified):
//   1. Check (automatic on load, or the row's own button) runs the read-only
//      comparison and updates status. Update only appears when Check found a
//      genuine update available - see `DependencyStatus.showsUpdateButton`.
//      cockpit-bootstrap-software: `.notInstalled` is the one exception - it
//      no longer shows Update (which used to silently mean "install"); it
//      shows a distinct "Install in Bootstrap ->" action instead, which
//      navigates to the `.bootstrap` rail destination's own Software
//      checklist card (`onNavigateToBootstrap`, wired by
//      `AppShellController` to `show(.bootstrap)`) rather than running the
//      install here. Every other status's Update button is unchanged.
//   2. Update immediately shows an in-progress state (spinner + "Updating…",
//      row disabled) while the real command runs in the background.
//   3. On success: a `Toast` ("{tool} updated to {version}") plus the row
//      flips back to up to date (Update disappears again).
//   4. Also fires a macOS user notification for the same event, so the
//      captain can tell it finished even unfocused - permission requested
//      gracefully, and a denial only skips the notification, never the toast.
//   5. On failure the row shows a clear failure state with the real command
//      output (via the row's expandable log), never a silent revert.
//
// All `UpdatesSource.check`/`.update` calls run on a background queue
// (`DispatchQueue.global`), matching `FleetController.refresh`/`.mergePR`.

import AppKit
import UserNotifications

/// Mutable per-row state and the views it owns - one instance per
/// `DependencyItem`, built once in `loadView` and updated in place by
/// `render(_:)` rather than rebuilt on every check/update.
private final class UpdateRow {
    let item: DependencyItem
    var status: DependencyStatus = .unknown
    var latestLabel: String?
    var detail: String = "Not checked yet"
    var log: String = ""
    var isLogExpanded = false
    var isBusy = false

    let iconTile = IconTileView()
    let nameLabel = NSTextField(labelWithString: "")
    let detailLabel = NSTextField(labelWithString: "")
    let pill = NSView()
    let pillLabel = NSTextField(labelWithString: "")
    let spinner = NSProgressIndicator()
    let progressLabel = NSTextField(labelWithString: "Updating\u{2026}")
    let checkButton = HelmButton(title: "Check", variant: .secondary, size: .small)
    let updateButton = HelmButton(title: "Update", variant: .primary, size: .small)
    /// `.notInstalled`-only action, styled deliberately unlike `updateButton`
    /// (inline/link-style rather than a bordered rounded button) so it reads
    /// as "go elsewhere," not "click to install here" - see the file header.
    let installInBootstrapButton = HelmButton(title: "Install in Bootstrap \u{2192}", variant: .quiet, size: .small)
    let detailsButton = NSButton()
    let logField = NSTextField(wrappingLabelWithString: "")
    let logContainer = NSView()
    let rowContainer = HoverHighlightView()
    /// Swapped between [pill, checkButton, updateButton] and
    /// [spinner, progressLabel] depending on `isBusy`.
    let trailingStack = NSStackView()

    /// This row's fields, packaged for the shared `ToolRowLayout` assembly.
    var toolRowViews: ToolRowLayout.Views {
        ToolRowLayout.Views(
            iconTile: iconTile, nameLabel: nameLabel, detailLabel: detailLabel,
            pill: pill, pillLabel: pillLabel, trailingStack: trailingStack,
            detailsButton: detailsButton, logField: logField, logContainer: logContainer,
            rowContainer: rowContainer
        )
    }

    init(item: DependencyItem) { self.item = item }
}

final class UpdatesController: NSViewController {

    /// One category card's rows + the separators between them, kept so the
    /// search field can hide non-matching rows and collapse the separator
    /// that would otherwise sit next to a hidden row - see `applyFilter`.
    private struct CategorySection {
        let background: NSView
        let rows: [UpdateRow]
        let separators: [NSView]
    }

    /// `String`-backed so it can be the id `HelmSegmentedTabs` hands back - the
    /// shared component deals in caller-owned ids rather than indices.
    private enum ToolFilterMode: String { case all, needsAttention }

    private var rows: [UpdateRow] = DependencyCatalog.items.map(UpdateRow.init)
    private var theme: HelmTheme = ThemeManager.shared.theme
    private var scrollView: NSScrollView!
    private var cards: [HelmCard] = []
    private var separators: [NSView] = []
    private var categorySections: [CategorySection] = []
    /// The summary strip's four tiles. Each themes itself; this list is what
    /// `renderStats` writes the numbers into and `applyTheme` hands the theme to.
    private var statTiles: [HelmStatTile] = []
    private let searchField = NSSearchField()
    private var filterMode: ToolFilterMode = .all
    /// The All / Needs Attention filter, now the app's shared
    /// `HelmSegmentedTabs` (`HelmDesignSystem.swift`, audit §6.3 component 6) at
    /// its `.compact` size - this control sits in a toolbar beside a search
    /// field rather than under a page title, which is what `.compact` exists
    /// for. It was a third near-copy of Shift's and Docs' pill recipe, at
    /// radius 6 in a radius-8 container.
    private let filterTabs = HelmSegmentedTabs(items: [
        .init(id: ToolFilterMode.all.rawValue, title: "All"),
        .init(id: ToolFilterMode.needsAttention.rawValue, title: "Needs Attention"),
    ], selected: ToolFilterMode.all.rawValue, size: .compact)
    /// Set by `AppShellController` (mirrors `BootstrapController.onRunCommand`'s
    /// closure-injection pattern) so a `.notInstalled` row's action can select
    /// the Bootstrap rail destination without this controller knowing
    /// anything about `AppShellController`/`RailDestination` itself.
    var onNavigateToBootstrap: (() -> Void)?
    private var lastCheckedAt: Date?
    private var lastCheckedTimer: Timer?
    private var hasCheckedOnce = false

    deinit {
        lastCheckedTimer?.invalidate()
    }

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 700, height: 720))
        root.wantsLayer = true
        view = root
        ThemeManager.shared.observe { [weak root, weak self] theme in
            root?.appearance = NSAppearance(named: theme.mode == .dark ? .darkAqua : .aqua)
            root?.layer?.backgroundColor = HelmTheme.nsColor(theme.backgroundHex).cgColor
            self?.theme = theme
            self?.applyTheme()
        }

        let header = buildHeader()
        let statsRow = buildStatsRow()
        let toolbarRow = buildToolbarRow()
        var sections: [NSView] = [header, statsRow, toolbarRow]
        for category in DependencyCatalog.categoryOrder {
            let categoryRows = rows.filter { $0.item.category == category }
            guard !categoryRows.isEmpty else { continue }
            sections.append(card(icon: iconFor(category: category), title: category, rows: categoryRows))
        }

        let stack = NSStackView(views: sections)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.setCustomSpacing(18, after: header)
        stack.setCustomSpacing(18, after: statsRow)
        stack.setCustomSpacing(18, after: toolbarRow)

        let content = FlippedView()
        content.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: HelmMetrics.pageGutter),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -HelmMetrics.pageGutter),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 18),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
        ])
        for section in sections {
            section.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }

        let scroll = NSScrollView()
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
        scrollView = scroll

        for row in rows { render(row) }
        applyFilter()
        applyTheme()
        renderStats()
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        view.layoutSubtreeIfNeeded()
        scrollToTop()
        renderStats()
        lastCheckedTimer?.invalidate()
        lastCheckedTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.renderStats()
        }
        if !hasCheckedOnce {
            hasCheckedOnce = true
            checkAll()
        }
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        lastCheckedTimer?.invalidate()
        lastCheckedTimer = nil
    }

    private func scrollToTop() {
        scrollView.contentView.scroll(to: .zero)
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    // MARK: Header

    private let subtitleLabel = NSTextField(labelWithString: "Every tool in the fleet, checked against its real source - npm, Homebrew, herdr, no-mistakes, and firstmate's own upstream.")

    private func buildHeader() -> NSView {
        subtitleLabel.font = .systemFont(ofSize: 12)
        subtitleLabel.preferredMaxLayoutWidth = 560
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        return subtitleLabel
    }

    // MARK: Toolbar (segmented filter + search + Refresh)

    /// A prominent, labeled, accent-colored pill (icon + "Refresh") - the
    /// captain's mockup showed this as the page's clear primary action, not a
    /// bare icon glyph, superseding cockpit-native-updates-polish's earlier
    /// borderless-icon-button decision for this control. Built the same way
    /// `SettingsController.themeCard`/`sessionCard` build a clickable styled
    /// card (a plain `NSView` + click gesture) rather than fighting `NSButton`
    /// for custom padding on a borderless button.
    /// GL-16: a `HoverHighlightView` (colours left clear, so it renders
    /// exactly as the plain `NSView` it replaced) purely to inherit that
    /// component's accessibility press action, focus ring and Return/Space
    /// handling - this pill is the page's primary action.
    private let checkAllPill = HoverHighlightView()
    private let checkAllIcon = NSImageView()
    private let checkAllLabel = NSTextField(labelWithString: "Refresh")
    private let checkAllProgressBar = NSProgressIndicator()
    private let checkAllProgressLabel = NSTextField(labelWithString: "")
    private var isCheckingAll = false

    /// The mockup's `.toolbar-row`: segmented "All / Needs attention" filter,
    /// the live search field, and the Refresh action (swapped for a progress
    /// bar+label while a check-all is running) pinned to the trailing edge.
    private func buildToolbarRow() -> NSView {
        filterTabs.onSelect = { [weak self] id in
            guard let self else { return }
            self.filterMode = ToolFilterMode(rawValue: id) ?? .all
            self.applyFilter()
        }

        searchField.placeholderString = "Filter tools\u{2026}"
        searchField.delegate = self
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.widthAnchor.constraint(equalToConstant: 200).isActive = true
        searchField.setContentHuggingPriority(.required, for: .horizontal)
        searchField.setContentCompressionResistancePriority(.required, for: .horizontal)

        checkAllIcon.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold))
        checkAllIcon.translatesAutoresizingMaskIntoConstraints = false
        checkAllLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        checkAllLabel.translatesAutoresizingMaskIntoConstraints = false

        let pillContent = NSStackView(views: [checkAllIcon, checkAllLabel])
        pillContent.orientation = .horizontal
        pillContent.alignment = .centerY
        pillContent.spacing = 7
        pillContent.translatesAutoresizingMaskIntoConstraints = false

        checkAllPill.wantsLayer = true
        checkAllPill.layer?.cornerRadius = 8
        checkAllPill.translatesAutoresizingMaskIntoConstraints = false
        checkAllPill.toolTip = "Check all tools for updates"
        checkAllPill.setAccessibilityRole(.button)
        checkAllPill.setAccessibilityLabel("Refresh")
        checkAllPill.accessibilityLabelOverride = "Refresh"
        checkAllPill.cornerRadius = 8
        checkAllPill.addSubview(pillContent)
        NSLayoutConstraint.activate([
            pillContent.leadingAnchor.constraint(equalTo: checkAllPill.leadingAnchor, constant: 13),
            pillContent.trailingAnchor.constraint(equalTo: checkAllPill.trailingAnchor, constant: -13),
            pillContent.topAnchor.constraint(equalTo: checkAllPill.topAnchor, constant: 7),
            pillContent.bottomAnchor.constraint(equalTo: checkAllPill.bottomAnchor, constant: -7),
        ])
        checkAllPill.addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(checkAllTapped)))
        checkAllPill.setContentHuggingPriority(.required, for: .horizontal)
        checkAllPill.setContentCompressionResistancePriority(.required, for: .horizontal)

        checkAllProgressBar.style = .bar
        checkAllProgressBar.isIndeterminate = false
        checkAllProgressBar.controlSize = .small
        checkAllProgressBar.minValue = 0
        checkAllProgressBar.isHidden = true
        checkAllProgressBar.translatesAutoresizingMaskIntoConstraints = false
        checkAllProgressBar.widthAnchor.constraint(equalToConstant: 90).isActive = true

        checkAllProgressLabel.font = .systemFont(ofSize: 11, weight: .medium)
        checkAllProgressLabel.isHidden = true
        checkAllProgressLabel.translatesAutoresizingMaskIntoConstraints = false
        for v: NSView in [checkAllProgressLabel, checkAllProgressBar] {
            v.setContentHuggingPriority(.required, for: .horizontal)
            v.setContentCompressionResistancePriority(.required, for: .horizontal)
        }

        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let row = NSStackView(views: [
            filterTabs, searchField, spacer,
            checkAllProgressLabel, checkAllProgressBar, checkAllPill,
        ])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        row.translatesAutoresizingMaskIntoConstraints = false
        return row
    }

    @objc private func checkAllTapped() { checkAll() }

    private func checkAll() {
        guard !isCheckingAll else { return }
        isCheckingAll = true
        checkAllPill.isHidden = true
        checkAllProgressBar.isHidden = false
        checkAllProgressLabel.isHidden = false

        let total = rows.count
        checkAllProgressBar.maxValue = Double(total)
        checkAllProgressBar.doubleValue = 0
        checkAllProgressLabel.stringValue = "Checking\u{2026} (0/\(total))"

        var completed = 0
        for row in rows {
            check(row) { [weak self] in
                guard let self else { return }
                completed += 1
                self.checkAllProgressBar.doubleValue = Double(completed)
                self.checkAllProgressLabel.stringValue = "Checking\u{2026} (\(completed)/\(total))"
                if completed == total { self.finishCheckAll() }
            }
        }
    }

    private func finishCheckAll() {
        isCheckingAll = false
        checkAllPill.isHidden = false
        checkAllProgressBar.isHidden = true
        checkAllProgressLabel.isHidden = true
        lastCheckedAt = Date()
        renderStats()

        let updateCount = rows.filter { $0.status.showsUpdateButton }.count
        let message = updateCount > 0
            ? "Checked \(rows.count) tools, \(updateCount) update\(updateCount == 1 ? "" : "s") available"
            : "Checked \(rows.count) tools - all up to date"
        if let container = view.window?.contentView {
            Toast.show(in: container, message: message)
        }
    }

    // MARK: Stats strip

    /// The four-tile summary strip, built from the app's shared `HelmStatTile`
    /// (`HelmDesignSystem.swift`, audit §6.3 component 4). This page's own copy
    /// was the loudest of the three the audit measured - a 19pt **bold** metric
    /// at 15/13 padding on a `surface @ 0.60` fill, 67pt tall against Overview's
    /// 50 - for the same job. Two behaviours are unchanged: the per-tile
    /// neutral/success/warning signal (now a `HelmTint`, and contrast-corrected
    /// rather than painted as the raw hue - audit §5.7), and `renderStats`
    /// writing only the numbers.
    private func buildStatsRow() -> NSView {
        statTiles = [
            HelmStatTile(symbol: "shippingbox", value: "0", caption: "Tools Installed"),
            HelmStatTile(symbol: "checkmark.circle", value: "0", caption: "Up to Date", tint: .good),
            HelmStatTile(symbol: "arrow.up.circle", value: "0", caption: "Updates Available", tint: .warn),
            HelmStatTile(symbol: "clock", value: "0", caption: "Last Checked"),
        ]

        let row = NSStackView(views: statTiles)
        row.orientation = .horizontal
        row.distribution = .fillEqually
        row.spacing = 12
        row.translatesAutoresizingMaskIntoConstraints = false
        return row
    }


    private func renderStats() {
        let total = rows.count
        let upToDate = rows.filter { $0.status == .upToDate }.count
        let needsUpdate = rows.filter { $0.status == .updateAvailable || $0.status == .notInstalled }.count
        guard statTiles.count == 4 else { return }
        statTiles[0].value = "\(total)"
        statTiles[1].value = "\(upToDate)"
        statTiles[2].value = "\(needsUpdate)"
        statTiles[3].value = relativeLastChecked()
    }

    private func relativeLastChecked() -> String {
        guard let lastCheckedAt else { return "\u{2014}" }
        let seconds = max(0, Int(Date().timeIntervalSince(lastCheckedAt)))
        if seconds < 5 { return "just now" }
        if seconds < 60 { return "\(seconds)s ago" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m ago" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h ago" }
        let days = hours / 24
        return "\(days)d ago"
    }

    // MARK: Filtering

    /// Hides rows whose name doesn't match the live search field (case-
    /// insensitive substring) or, when the "Needs attention" segment is
    /// active, whose status isn't one that already surfaces an action
    /// (`DependencyStatus.showsUpdateButton` - the same set the stats strip's
    /// "Updates Available" tile counts) - collapses the separator that would
    /// otherwise sit next to a hidden row, and hides a whole category card
    /// once none of its rows match. An empty query with "All" selected shows
    /// everything.
    private func applyFilter() {
        let q = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        for section in categorySections {
            var anyVisible = false
            for row in section.rows {
                let matchesQuery = q.isEmpty || row.item.name.lowercased().contains(q)
                let matchesMode = filterMode == .all || row.status.showsUpdateButton
                let matches = matchesQuery && matchesMode
                row.rowContainer.isHidden = !matches
                if matches { anyVisible = true }
            }
            section.background.isHidden = !anyVisible
            for i in section.separators.indices {
                let rowVisible = !section.rows[i].rowContainer.isHidden
                let laterVisible = section.rows[(i + 1)...].contains { !$0.rowContainer.isHidden }
                section.separators[i].isHidden = !(rowVisible && laterVisible)
            }
        }
    }

    // MARK: Card chrome

    private func iconFor(category: String) -> String {
        switch category {
        case "npm packages": return "shippingbox"
        case "Homebrew": return "wrench.and.screwdriver"
        case "Other tools": return "gearshape.2"
        case "Documentation": return "book.closed"
        default: return "sailboat"
        }
    }

    /// A per-category tint for each row's `IconTileView` (mirrors the
    /// mockup's blue/red/violet tool-row tiles) - resolved through the shared
    /// `HelmTint` enum (phase 1's `HelmUIComponents.swift`) rather than a raw
    /// hex, so it stays correct across all 8 Helm palettes.
    private func categoryTint(for category: String) -> HelmTint {
        DependencyCatalog.tint(for: category)
    }

    /// One `HelmCard` per tool category - the shared container from
    /// `HelmDesignSystem.swift`, replacing this file's own copy of a card
    /// helper that was byte-for-byte identical in four controllers, plus its
    /// own copy of the theming loop (audit §3.2).
    private func card(icon: String, title: String, rows categoryRows: [UpdateRow]) -> HelmCard {
        var rowViews: [NSView] = []
        var sectionSeparators: [NSView] = []
        for (index, row) in categoryRows.enumerated() {
            rowViews.append(buildRow(row))
            if index < categoryRows.count - 1 {
                let sep = separator()
                rowViews.append(sep)
                sectionSeparators.append(sep)
            }
        }
        let rowsStack = NSStackView(views: rowViews)
        rowsStack.orientation = .vertical
        rowsStack.alignment = .leading
        rowsStack.spacing = 10
        rowsStack.translatesAutoresizingMaskIntoConstraints = false
        for v in rowViews { v.widthAnchor.constraint(equalTo: rowsStack.widthAnchor).isActive = true }

        let card = HelmCard()
        card.setHeader(symbol: icon, tint: DependencyCatalog.tint(for: title), title: title)
        card.setBody(rowsStack, insets: HelmCard.contentInsets)
        cards.append(card)
        categorySections.append(CategorySection(background: card, rows: categoryRows, separators: sectionSeparators))
        return card
    }

    private func separator() -> NSView {
        let v = NSView()
        v.wantsLayer = true
        v.heightAnchor.constraint(equalToConstant: 1).isActive = true
        separators.append(v)
        return v
    }

    // MARK: Row

    private func buildRow(_ row: UpdateRow) -> NSView {
        // Check / Update
        row.checkButton.target = self
        row.checkButton.action = #selector(checkTapped(_:))
        row.checkButton.identifier = NSUserInterfaceItemIdentifier(row.item.id)

        row.updateButton.target = self
        row.updateButton.action = #selector(updateTapped(_:))
        row.updateButton.identifier = NSUserInterfaceItemIdentifier(row.item.id)
        row.updateButton.isHidden = true

        // `.notInstalled` only - `.quiet` + an accent `tint`, so it reads as
        // "navigate elsewhere" and is never confusable with the accent-filled
        // `.primary` `updateButton` used for every other status. Its label
        // colour used to be a hand-rolled `attributedTitle` in `applyThemeToRow`
        // (`contentTintColor` does not colour a string title) - `tint` is that
        // same idea, shared and contrast-corrected.
        row.installInBootstrapButton.tint = .accent
        row.installInBootstrapButton.target = self
        row.installInBootstrapButton.action = #selector(installInBootstrapTapped(_:))
        row.installInBootstrapButton.identifier = NSUserInterfaceItemIdentifier(row.item.id)
        row.installInBootstrapButton.isHidden = true

        // Busy state
        row.spinner.style = .spinning
        row.spinner.controlSize = .small
        row.spinner.isIndeterminate = true
        row.spinner.translatesAutoresizingMaskIntoConstraints = false
        row.progressLabel.font = .systemFont(ofSize: 11, weight: .medium)

        let view = ToolRowLayout.build(
            row.toolRowViews,
            iconSymbol: row.item.kind.symbol,
            tint: categoryTint(for: row.item.category),
            name: row.item.name,
            // Status column: the pill, and the spinner/label that replace
            // it while a check or update runs. Actions stay in their own
            // trailing column (audit §5.4).
            statusViews: [row.pill, row.spinner, row.progressLabel],
            trailingViews: [row.checkButton, row.updateButton, row.installInBootstrapButton],
            detailsTarget: self,
            detailsAction: #selector(detailsTapped(_:)),
            identifier: row.item.id
        )
        row.logContainer.isHidden = true // collapsed until the details chevron is tapped.
        return view
    }

    @objc private func detailsTapped(_ sender: NSButton) {
        guard let row = row(for: sender) else { return }
        row.isLogExpanded.toggle()
        ToolRowLayout.setLogExpanded(row.toolRowViews, expanded: row.isLogExpanded, log: row.log)
    }

    private func row(for sender: NSButton) -> UpdateRow? {
        guard let raw = sender.identifier?.rawValue else { return nil }
        return rows.first { $0.item.id == raw }
    }

    // MARK: Check

    @objc private func checkTapped(_ sender: NSButton) {
        guard let row = row(for: sender) else { return }
        check(row)
    }

    /// `completion` fires on the main queue once this row's check settles -
    /// `checkAll` uses it to drive the header's "Checking… (N/M)" progress
    /// and the completion toast without polling row state.
    private func check(_ row: UpdateRow, completion: (() -> Void)? = nil) {
        guard !row.isBusy else {
            completion?()
            return
        }
        row.status = .checking
        row.detail = "Checking\u{2026}"
        row.checkButton.isEnabled = false
        render(row)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let outcome = UpdatesSource.check(row.item)
            DispatchQueue.main.async {
                guard self != nil else {
                    completion?()
                    return
                }
                row.status = outcome.status
                row.latestLabel = outcome.latestLabel
                row.detail = outcome.detail
                row.log = outcome.log
                row.checkButton.isEnabled = true
                self?.render(row)
                completion?()
            }
        }
    }

    // MARK: Update

    @objc private func updateTapped(_ sender: NSButton) {
        guard let row = row(for: sender) else { return }
        confirmAndUpdate(row)
    }

    @objc private func installInBootstrapTapped(_ sender: NSButton) {
        onNavigateToBootstrap?()
    }

    /// Firstmate's row gets an explicit before-acting summary (commit count +
    /// target) per the safety principle - every other row's summary is
    /// already visible in its subtitle (`row.detail`, e.g. "0.2.3 → 0.2.4"),
    /// so a second confirmation dialog for those would just repeat what Check
    /// already showed with no new information the captain needs to decide.
    private func confirmAndUpdate(_ row: UpdateRow) {
        guard case .firstmate = row.item.kind else {
            update(row)
            return
        }
        let alert = NSAlert()
        if row.status == .notInstalled {
            alert.messageText = "Install firstmate from upstream?"
            alert.informativeText = "\(row.detail)\n\nThis fast-forwards the local default branch to kunchenguid/firstmate's upstream, then pushes the result to origin (your fork). Never forced, never a merge commit."
        } else {
            alert.messageText = "Sync firstmate with upstream?"
            alert.informativeText = "\(row.detail)\n\nThis fast-forwards the local default branch to kunchenguid/firstmate's upstream, then pushes the result to origin (your fork). Never forced, never a merge commit."
        }
        alert.addButton(withTitle: row.status == .notInstalled ? "Install and Push" : "Sync and Push")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .informational
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        update(row)
    }

    private func update(_ row: UpdateRow) {
        guard !row.isBusy else { return }
        row.isBusy = true
        row.status = .updating
        render(row)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let outcome = UpdatesSource.update(row.item)
            DispatchQueue.main.async {
                guard let self else { return }
                row.isBusy = false
                row.log = outcome.log
                if outcome.ok {
                    row.status = .upToDate
                    row.detail = outcome.detail
                    self.showSuccess(row: row, outcome: outcome)
                } else {
                    row.status = .updateFailed
                    row.detail = outcome.detail
                }
                self.render(row)
                // Re-run a real Check right after so the row's status/labels
                // reflect the machine's true state rather than the update
                // command's own self-report - matches every other row's
                // "Check is the source of truth for status" contract.
                if outcome.ok { self.check(row) }
            }
        }
    }

    private func showSuccess(row: UpdateRow, outcome: UpdateOutcome) {
        let message = "\(row.item.name) updated to \(outcome.newVersionLabel ?? "latest")"
        if let container = view.window?.contentView {
            Toast.show(in: container, message: message)
        }
        notify(title: "\(row.item.name) updated", body: message)
    }

    /// Step 4: a macOS notification for the same completion event, so the
    /// captain can tell it finished even while the app isn't focused.
    /// Permission is requested gracefully and a denial only skips the
    /// notification - the toast above already fired regardless.
    private func notify(title: String, body: String) {
        // `UNUserNotificationCenter.current()` throws an uncaught
        // NSException ("bundleProxyForCurrentProcess is nil") when the
        // running process has no real Info.plist/bundle identifier - true
        // for `swift run`/the bare `.build/debug/FirstmateCockpit` binary the
        // README documents as the normal dev workflow. Confirmed live: this
        // crashed every time under that workflow until this guard was added;
        // the packaged app (`build_native_app.sh`'s output, a real bundle)
        // is unaffected either way. The in-app toast already fired
        // regardless, matching the same "denial only skips the
        // notification" fallback this method already applies below.
        guard Bundle.main.bundleIdentifier != nil else { return }
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .authorized, .provisional:
                Self.postNotification(title: title, body: body)
            case .notDetermined:
                center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
                    if granted { Self.postNotification(title: title, body: body) }
                }
            default:
                break // denied - the in-app toast already covered it.
            }
        }
    }

    private static func postNotification(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: "fm.update.\(UUID().uuidString)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    // MARK: Render

    private func render(_ row: UpdateRow) {
        row.detailLabel.stringValue = row.detail
        row.logField.stringValue = row.log.isEmpty ? "No output yet." : row.log

        let (pillText, pillColorHex) = pillVisuals(row.status)
        ToolRowLayout.pill(text: pillText, colorHex: pillColorHex, into: row.pill, label: row.pillLabel)

        let busy = row.status == .checking || row.status == .updating
        row.pill.isHidden = busy
        row.checkButton.isHidden = busy
        // `.notInstalled` shows the distinct "Install in Bootstrap ->" link
        // instead of Update - every other status that `showsUpdateButton`
        // keeps its existing Update button unchanged.
        row.updateButton.isHidden = busy || !row.status.showsUpdateButton || row.status == .notInstalled
        row.installInBootstrapButton.isHidden = busy || row.status != .notInstalled
        row.spinner.isHidden = !busy
        row.progressLabel.isHidden = !busy
        row.progressLabel.stringValue = row.status == .updating ? "Updating\u{2026}" : "Checking\u{2026}"
        if busy { row.spinner.startAnimation(nil) } else { row.spinner.stopAnimation(nil) }

        let disabled = row.isBusy
        row.checkButton.isEnabled = !disabled
        row.updateButton.isEnabled = !disabled
        row.installInBootstrapButton.isEnabled = !disabled
        row.rowContainer.alphaValue = disabled ? 0.6 : 1.0

        applyThemeToRow(row)
        renderStats()
        // A status change can move this row in/out of the "Needs attention"
        // set - keep the current filter's visible rows in sync.
        if !categorySections.isEmpty { applyFilter() }
    }

    private func pillVisuals(_ status: DependencyStatus) -> (String, String) {
        switch status {
        case .unknown: return ("Not Checked", theme.chromeInkHex)
        case .checking, .updating: return ("", theme.chromeInkHex)
        case .upToDate: return ("Up to Date", theme.ansiHex[2])
        case .updateAvailable: return ("Update Available", theme.ansiHex[3])
        case .notInstalled: return ("Not Installed", theme.ansiHex[3])
        case .checkFailed: return ("Check Failed", theme.ansiHex[1])
        case .updateFailed: return ("Update Failed", theme.ansiHex[1])
        }
    }

    // MARK: Theme

    private func applyTheme() {
        subtitleLabel.textColor = HelmTheme.mutedInk(theme)
        let line = HelmTheme.nsColor(theme.chromeLineHex)
        let accent = HelmTheme.nsColor(theme.accentHex)
        checkAllPill.layer?.backgroundColor = accent.cgColor
        // `selectionTextHex` is the text tone already contrast-verified
        // against an opaque `accentHex` fill (SwiftTerm's selected-text
        // color) - the same pairing this pill's fill/text need.
        let onAccent = HelmTheme.nsColor(theme.selectionTextHex)
        checkAllIcon.contentTintColor = onAccent
        checkAllLabel.textColor = onAccent
        checkAllProgressLabel.textColor = HelmTheme.mutedInk(theme)
        filterTabs.applyTheme(theme)
        for card in cards { card.applyTheme(theme) }
        for v in separators {
            v.layer?.backgroundColor = line.withAlphaComponent(0.5).cgColor
        }
        for tile in statTiles { tile.applyTheme(theme) }
        searchField.appearance = NSAppearance(named: theme.mode == .dark ? .darkAqua : .aqua)
        for row in rows { applyThemeToRow(row) }
    }

    private func applyThemeToRow(_ row: UpdateRow) {
        let failed = row.status == .checkFailed || row.status == .updateFailed
        // Reuses `showsUpdateButton` - the exact predicate already driving
        // the "Needs Attention" filter segment above - as "this row is
        // worth a card/accent-bar treatment," and `pillVisuals` for its
        // color, rather than inventing a second notion of "needs attention"
        // (`fm/grandline-setup-attention-row-style`). A healthy row
        // (`.upToDate`, `.unknown`, or a busy `.checking`/`.updating`) keeps
        // the exact flat/compact look it always has.
        let needsAttention = row.status.showsUpdateButton
        let attentionHex = needsAttention ? pillVisuals(row.status).1 : nil
        ToolRowLayout.applyTheme(
            row.toolRowViews, theme: theme, detailFailed: failed,
            cardStyle: needsAttention, attentionHex: attentionHex, accentBar: needsAttention
        )
        row.progressLabel.textColor = HelmTheme.mutedInk(theme)
    }
}

extension UpdatesController: NSSearchFieldDelegate {
    func controlTextDidChange(_ obj: Notification) {
        applyFilter()
    }
}
