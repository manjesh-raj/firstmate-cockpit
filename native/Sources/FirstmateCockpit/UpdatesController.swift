// Firstmate Cockpit - native macOS app.
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
    let checkButton = NSButton()
    let updateButton = NSButton()
    /// `.notInstalled`-only action, styled deliberately unlike `updateButton`
    /// (inline/link-style rather than a bordered rounded button) so it reads
    /// as "go elsewhere," not "click to install here" - see the file header.
    let installInBootstrapButton = NSButton()
    let detailsButton = NSButton()
    let logField = NSTextField(wrappingLabelWithString: "")
    let logContainer = NSView()
    let rowContainer = HoverHighlightView()
    /// Swapped between [pill, checkButton, updateButton] and
    /// [spinner, progressLabel] depending on `isBusy`.
    let trailingStack = NSStackView()

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

    private enum StatSemantic { case neutral, success, warning }

    private struct StatTile {
        let valueLabel: NSTextField
        let iconView: NSImageView
        let semantic: StatSemantic
    }

    private enum ToolFilterMode { case all, needsAttention }

    private var rows: [UpdateRow] = DependencyCatalog.items.map(UpdateRow.init)
    private var theme: HelmTheme = ThemeManager.shared.theme
    private var scrollView: NSScrollView!
    private var cardBackgrounds: [NSView] = []
    private var separators: [NSView] = []
    private var categorySections: [CategorySection] = []
    private var statTiles: [StatTile] = []
    private let searchField = NSSearchField()
    private var filterMode: ToolFilterMode = .all
    /// The two "All / Needs attention" segments (mockup's `.segmented`),
    /// built as plain clickable views rather than `NSSegmentedControl` to
    /// match how this codebase already builds custom pill controls
    /// (`checkAllPill`, `SettingsController`'s theme/session cards).
    private let allSegment = NSView()
    private let allSegmentLabel = NSTextField(labelWithString: "All")
    private let needsAttentionSegment = NSView()
    private let needsAttentionSegmentLabel = NSTextField(labelWithString: "Needs Attention")
    private let segmentedBackground = NSView()
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
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
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
    private let checkAllPill = NSView()
    private let checkAllIcon = NSImageView()
    private let checkAllLabel = NSTextField(labelWithString: "Refresh")
    private let checkAllProgressBar = NSProgressIndicator()
    private let checkAllProgressLabel = NSTextField(labelWithString: "")
    private var isCheckingAll = false

    /// The mockup's `.toolbar-row`: segmented "All / Needs attention" filter,
    /// the live search field, and the Refresh action (swapped for a progress
    /// bar+label while a check-all is running) pinned to the trailing edge.
    private func buildToolbarRow() -> NSView {
        allSegmentLabel.font = .systemFont(ofSize: 11.5, weight: .semibold)
        needsAttentionSegmentLabel.font = .systemFont(ofSize: 11.5, weight: .semibold)
        for (segment, label, mode): (NSView, NSTextField, ToolFilterMode) in [
            (allSegment, allSegmentLabel, .all),
            (needsAttentionSegment, needsAttentionSegmentLabel, .needsAttention),
        ] {
            segment.wantsLayer = true
            segment.layer?.cornerRadius = 6
            segment.translatesAutoresizingMaskIntoConstraints = false
            label.translatesAutoresizingMaskIntoConstraints = false
            segment.addSubview(label)
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: segment.leadingAnchor, constant: 12),
                label.trailingAnchor.constraint(equalTo: segment.trailingAnchor, constant: -12),
                label.topAnchor.constraint(equalTo: segment.topAnchor, constant: 5),
                label.bottomAnchor.constraint(equalTo: segment.bottomAnchor, constant: -5),
            ])
            let recognizer = NSClickGestureRecognizer(target: self, action: #selector(segmentTapped(_:)))
            segment.addGestureRecognizer(recognizer)
            segment.identifier = NSUserInterfaceItemIdentifier(mode == .all ? "all" : "needsAttention")
        }

        let segmentsStack = NSStackView(views: [allSegment, needsAttentionSegment])
        segmentsStack.orientation = .horizontal
        segmentsStack.spacing = 2
        segmentsStack.translatesAutoresizingMaskIntoConstraints = false

        segmentedBackground.wantsLayer = true
        segmentedBackground.layer?.cornerRadius = 8
        segmentedBackground.translatesAutoresizingMaskIntoConstraints = false
        segmentedBackground.addSubview(segmentsStack)
        NSLayoutConstraint.activate([
            segmentsStack.leadingAnchor.constraint(equalTo: segmentedBackground.leadingAnchor, constant: 2),
            segmentsStack.trailingAnchor.constraint(equalTo: segmentedBackground.trailingAnchor, constant: -2),
            segmentsStack.topAnchor.constraint(equalTo: segmentedBackground.topAnchor, constant: 2),
            segmentsStack.bottomAnchor.constraint(equalTo: segmentedBackground.bottomAnchor, constant: -2),
        ])
        segmentedBackground.setContentHuggingPriority(.required, for: .horizontal)
        segmentedBackground.setContentCompressionResistancePriority(.required, for: .horizontal)

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
            segmentedBackground, searchField, spacer,
            checkAllProgressLabel, checkAllProgressBar, checkAllPill,
        ])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        row.translatesAutoresizingMaskIntoConstraints = false
        updateSegmentedAppearance()
        return row
    }

    @objc private func segmentTapped(_ sender: NSClickGestureRecognizer) {
        guard let id = sender.view?.identifier?.rawValue else { return }
        filterMode = id == "needsAttention" ? .needsAttention : .all
        updateSegmentedAppearance()
        applyFilter()
    }

    private func updateSegmentedAppearance() {
        let activeBg = HelmTheme.nsColor(theme.chromeBackgroundHex)
        let ink = HelmTheme.nsColor(theme.chromeInkHex)
        let muted = HelmTheme.mutedInk(theme)
        for (segment, label, mode): (NSView, NSTextField, ToolFilterMode) in [
            (allSegment, allSegmentLabel, .all),
            (needsAttentionSegment, needsAttentionSegmentLabel, .needsAttention),
        ] {
            let isActive = filterMode == mode
            segment.layer?.backgroundColor = isActive ? activeBg.cgColor : NSColor.clear.cgColor
            label.textColor = isActive ? ink : muted
        }
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

    private func buildStatsRow() -> NSView {
        let installed = statCard(icon: "shippingbox", title: "Tools Installed")
        let upToDate = statCard(icon: "checkmark.circle", title: "Up to Date")
        let updatesAvailable = statCard(icon: "arrow.up.circle", title: "Updates Available")
        let lastChecked = statCard(icon: "clock", title: "Last Checked")

        statTiles = [
            StatTile(valueLabel: installed.valueLabel, iconView: installed.iconView, semantic: .neutral),
            StatTile(valueLabel: upToDate.valueLabel, iconView: upToDate.iconView, semantic: .success),
            StatTile(valueLabel: updatesAvailable.valueLabel, iconView: updatesAvailable.iconView, semantic: .warning),
            StatTile(valueLabel: lastChecked.valueLabel, iconView: lastChecked.iconView, semantic: .neutral),
        ]

        let row = NSStackView(views: [installed.container, upToDate.container, updatesAvailable.container, lastChecked.container])
        row.orientation = .horizontal
        row.distribution = .fillEqually
        row.spacing = 12
        row.translatesAutoresizingMaskIntoConstraints = false
        return row
    }

    /// Same rounded-card chrome as `card(icon:title:content:)`/`SettingsController.card`
    /// (appended to the shared `cardBackgrounds` list so it themes identically)
    /// but laid out as a stat tile: icon + big number on top, label beneath -
    /// mirrors `FleetController.statTile`'s shape at a larger, page-header scale.
    private func statCard(icon: String, title: String) -> (container: NSView, valueLabel: NSTextField, iconView: NSImageView, titleLabel: NSTextField) {
        let iconView = NSImageView()
        iconView.image = NSImage(systemSymbolName: icon, accessibilityDescription: title)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold))
        iconView.translatesAutoresizingMaskIntoConstraints = false

        let valueLabel = NSTextField(labelWithString: "0")
        valueLabel.font = .monospacedDigitSystemFont(ofSize: 19, weight: .bold)
        valueLabel.lineBreakMode = .byTruncatingTail
        valueLabel.maximumNumberOfLines = 1
        valueLabel.translatesAutoresizingMaskIntoConstraints = false

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 10.5, weight: .medium)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        let topRow = NSStackView(views: [iconView, valueLabel])
        topRow.orientation = .horizontal
        topRow.spacing = 6
        topRow.alignment = .firstBaseline
        topRow.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [topRow, titleLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 5
        stack.translatesAutoresizingMaskIntoConstraints = false

        let background = NSView()
        background.wantsLayer = true
        background.layer?.cornerRadius = 10
        background.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 15),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: background.trailingAnchor, constant: -15),
            stack.topAnchor.constraint(equalTo: background.topAnchor, constant: 13),
            stack.bottomAnchor.constraint(equalTo: background.bottomAnchor, constant: -13),
        ])
        cardBackgrounds.append(background)
        statTitleLabels.append(titleLabel)
        return (background, valueLabel, iconView, titleLabel)
    }

    private var statTitleLabels: [NSTextField] = []

    private func renderStats() {
        let total = rows.count
        let upToDate = rows.filter { $0.status == .upToDate }.count
        let needsUpdate = rows.filter { $0.status == .updateAvailable || $0.status == .notInstalled }.count
        guard statTiles.count == 4 else { return }
        statTiles[0].valueLabel.stringValue = "\(total)"
        statTiles[1].valueLabel.stringValue = "\(upToDate)"
        statTiles[2].valueLabel.stringValue = "\(needsUpdate)"
        statTiles[3].valueLabel.stringValue = relativeLastChecked()
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

    // MARK: Card chrome (mirrors SettingsController.card)

    private func iconFor(category: String) -> String {
        switch category {
        case "npm packages": return "shippingbox"
        case "Homebrew": return "wrench.and.screwdriver"
        case "Other tools": return "gearshape.2"
        default: return "sailboat"
        }
    }

    /// A per-category tint for each row's `IconTileView` (mirrors the
    /// mockup's blue/red/violet tool-row tiles) - resolved through the shared
    /// `HelmTint` enum (phase 1's `HelmUIComponents.swift`) rather than a raw
    /// hex, so it stays correct across all 8 Helm palettes.
    private func categoryTint(for category: String) -> HelmTint {
        switch category {
        case "npm packages": return .info
        case "Homebrew": return .warn
        case "Other tools": return .neutral
        case "Security": return .violet
        default: return .accent // Firstmate
        }
    }

    private func card(icon: String, title: String, rows categoryRows: [UpdateRow]) -> NSView {
        let iconView = NSImageView()
        iconView.image = NSImage(systemSymbolName: icon, accessibilityDescription: title)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 14, weight: .semibold))
        iconView.translatesAutoresizingMaskIntoConstraints = false

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 14.5, weight: .semibold)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        let header = NSStackView(views: [iconView, titleLabel])
        header.orientation = .horizontal
        header.spacing = 8
        header.alignment = .firstBaseline
        header.translatesAutoresizingMaskIntoConstraints = false

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

        let inner = NSStackView(views: [header, rowsStack])
        inner.orientation = .vertical
        inner.alignment = .leading
        inner.spacing = 12
        inner.translatesAutoresizingMaskIntoConstraints = false
        rowsStack.widthAnchor.constraint(equalTo: inner.widthAnchor).isActive = true

        let background = NSView()
        background.wantsLayer = true
        background.layer?.cornerRadius = 13
        background.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(inner)
        NSLayoutConstraint.activate([
            inner.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 16),
            inner.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -16),
            inner.topAnchor.constraint(equalTo: background.topAnchor, constant: 14),
            inner.bottomAnchor.constraint(equalTo: background.bottomAnchor, constant: -14),
        ])
        cardBackgrounds.append(background)
        categorySections.append(CategorySection(background: background, rows: categoryRows, separators: sectionSeparators))
        return background
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
        // Shared icon-in-tinted-tile view (phase 1's `HelmUIComponents.swift`)
        // - the native equivalent of the mockup's colored tool-row squares.
        row.iconTile.configure(symbol: row.item.kind.symbol, tint: categoryTint(for: row.item.category), pointSize: 14)
        row.iconTile.setContentHuggingPriority(.required, for: .horizontal)
        row.iconTile.setContentCompressionResistancePriority(.required, for: .horizontal)

        row.nameLabel.stringValue = row.item.name
        row.nameLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        row.nameLabel.lineBreakMode = .byTruncatingTail
        row.nameLabel.maximumNumberOfLines = 1

        row.detailLabel.font = .systemFont(ofSize: 10.5)
        row.detailLabel.lineBreakMode = .byTruncatingTail
        row.detailLabel.maximumNumberOfLines = 1

        let textStack = NSStackView(views: [row.nameLabel, row.detailLabel])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 2
        textStack.setContentHuggingPriority(.defaultLow, for: .horizontal)
        textStack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        // Badge
        row.pillLabel.font = .systemFont(ofSize: 10.5, weight: .semibold)
        row.pillLabel.translatesAutoresizingMaskIntoConstraints = false
        row.pill.wantsLayer = true
        row.pill.layer?.cornerRadius = 9
        row.pill.translatesAutoresizingMaskIntoConstraints = false
        row.pill.addSubview(row.pillLabel)
        NSLayoutConstraint.activate([
            row.pillLabel.leadingAnchor.constraint(equalTo: row.pill.leadingAnchor, constant: 9),
            row.pillLabel.trailingAnchor.constraint(equalTo: row.pill.trailingAnchor, constant: -9),
            row.pillLabel.topAnchor.constraint(equalTo: row.pill.topAnchor, constant: 3),
            row.pillLabel.bottomAnchor.constraint(equalTo: row.pill.bottomAnchor, constant: -3),
        ])

        // Check / Update
        row.checkButton.title = "Check"
        row.checkButton.bezelStyle = .rounded
        row.checkButton.controlSize = .small
        row.checkButton.target = self
        row.checkButton.action = #selector(checkTapped(_:))
        row.checkButton.identifier = NSUserInterfaceItemIdentifier(row.item.id)

        row.updateButton.title = "Update"
        row.updateButton.bezelStyle = .rounded
        row.updateButton.controlSize = .small
        row.updateButton.target = self
        row.updateButton.action = #selector(updateTapped(_:))
        row.updateButton.identifier = NSUserInterfaceItemIdentifier(row.item.id)
        row.updateButton.isHidden = true

        // `.notInstalled` only - inline/link-styled (bordered, no fill) so it
        // visually reads as "navigate elsewhere," never confusable with the
        // rounded, filled `updateButton` used for every other status.
        row.installInBootstrapButton.title = "Install in Bootstrap \u{2192}"
        row.installInBootstrapButton.bezelStyle = .inline
        row.installInBootstrapButton.isBordered = false
        row.installInBootstrapButton.controlSize = .small
        row.installInBootstrapButton.font = .systemFont(ofSize: 11, weight: .semibold)
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

        row.trailingStack.orientation = .horizontal
        row.trailingStack.spacing = 8
        row.trailingStack.alignment = .centerY
        row.trailingStack.translatesAutoresizingMaskIntoConstraints = false
        for v in [row.pill, row.checkButton, row.updateButton, row.installInBootstrapButton, row.spinner, row.progressLabel] {
            v.setContentHuggingPriority(.required, for: .horizontal)
            v.setContentCompressionResistancePriority(.required, for: .horizontal)
        }
        row.trailingStack.addArrangedSubview(row.pill)
        row.trailingStack.addArrangedSubview(row.checkButton)
        row.trailingStack.addArrangedSubview(row.updateButton)
        row.trailingStack.addArrangedSubview(row.installInBootstrapButton)
        row.trailingStack.addArrangedSubview(row.spinner)
        row.trailingStack.addArrangedSubview(row.progressLabel)

        // Details disclosure
        row.detailsButton.title = ""
        row.detailsButton.isBordered = false
        row.detailsButton.image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: "Show details")
        row.detailsButton.imageScaling = .scaleProportionallyDown
        row.detailsButton.target = self
        row.detailsButton.action = #selector(detailsTapped(_:))
        row.detailsButton.identifier = NSUserInterfaceItemIdentifier(row.item.id)
        row.detailsButton.translatesAutoresizingMaskIntoConstraints = false
        row.detailsButton.setContentHuggingPriority(.required, for: .horizontal)
        row.detailsButton.toolTip = "Show command output"

        let topRow = NSStackView(views: [row.iconTile, textStack, row.trailingStack, row.detailsButton])
        topRow.orientation = .horizontal
        topRow.alignment = .centerY
        topRow.spacing = 8
        topRow.translatesAutoresizingMaskIntoConstraints = false

        // Log (expandable, monospace, hidden until toggled)
        row.logField.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        row.logField.preferredMaxLayoutWidth = 560
        row.logField.translatesAutoresizingMaskIntoConstraints = false
        row.logContainer.wantsLayer = true
        row.logContainer.layer?.cornerRadius = 6
        row.logContainer.translatesAutoresizingMaskIntoConstraints = false
        row.logContainer.isHidden = true
        row.logContainer.addSubview(row.logField)
        NSLayoutConstraint.activate([
            row.logField.leadingAnchor.constraint(equalTo: row.logContainer.leadingAnchor, constant: 8),
            row.logField.trailingAnchor.constraint(equalTo: row.logContainer.trailingAnchor, constant: -8),
            row.logField.topAnchor.constraint(equalTo: row.logContainer.topAnchor, constant: 6),
            row.logField.bottomAnchor.constraint(equalTo: row.logContainer.bottomAnchor, constant: -6),
        ])

        let column = NSStackView(views: [topRow, row.logContainer])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 6
        column.translatesAutoresizingMaskIntoConstraints = false
        topRow.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
        row.logContainer.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true

        row.rowContainer.cornerRadius = 8
        row.rowContainer.translatesAutoresizingMaskIntoConstraints = false
        row.rowContainer.addSubview(column)
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: row.rowContainer.leadingAnchor, constant: 4),
            column.trailingAnchor.constraint(equalTo: row.rowContainer.trailingAnchor, constant: -4),
            column.topAnchor.constraint(equalTo: row.rowContainer.topAnchor, constant: 4),
            column.bottomAnchor.constraint(equalTo: row.rowContainer.bottomAnchor, constant: -4),
        ])
        return row.rowContainer
    }

    @objc private func detailsTapped(_ sender: NSButton) {
        guard let row = row(for: sender) else { return }
        row.isLogExpanded.toggle()
        row.logContainer.isHidden = !row.isLogExpanded || row.log.isEmpty
        row.detailsButton.image = NSImage(
            systemSymbolName: row.isLogExpanded ? "chevron.down" : "chevron.right",
            accessibilityDescription: "Show details"
        )
        row.logField.stringValue = row.log.isEmpty ? "No output yet." : row.log
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
        row.pillLabel.stringValue = pillText
        row.pillLabel.textColor = HelmTheme.nsColor(pillColorHex)
        row.pill.layer?.backgroundColor = HelmTheme.nsColor(pillColorHex).withAlphaComponent(0.15).cgColor

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
        let surface = HelmTheme.nsColor(theme.chromeBackgroundHex)
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
        segmentedBackground.layer?.backgroundColor = surface.withAlphaComponent(0.6).cgColor
        segmentedBackground.layer?.borderWidth = 1
        segmentedBackground.layer?.borderColor = line.withAlphaComponent(0.5).cgColor
        updateSegmentedAppearance()
        for v in cardBackgrounds {
            v.layer?.backgroundColor = surface.withAlphaComponent(0.6).cgColor
            v.layer?.borderWidth = 1
            v.layer?.borderColor = line.withAlphaComponent(0.5).cgColor
        }
        for v in separators {
            v.layer?.backgroundColor = line.withAlphaComponent(0.5).cgColor
        }
        for label in statTitleLabels {
            label.textColor = HelmTheme.mutedInk(theme)
        }
        for tile in statTiles {
            let color: NSColor
            switch tile.semantic {
            case .neutral: color = HelmTheme.nsColor(theme.chromeInkHex)
            case .success: color = HelmTheme.nsColor(theme.ansiHex[2])
            case .warning: color = HelmTheme.nsColor(theme.ansiHex[3])
            }
            tile.valueLabel.textColor = color
            tile.iconView.contentTintColor = color.withAlphaComponent(0.85)
        }
        searchField.appearance = NSAppearance(named: theme.mode == .dark ? .darkAqua : .aqua)
        for row in rows { applyThemeToRow(row) }
    }

    private func applyThemeToRow(_ row: UpdateRow) {
        let ink = HelmTheme.nsColor(theme.chromeInkHex)
        let muted = HelmTheme.mutedInk(theme)
        let line = HelmTheme.nsColor(theme.chromeLineHex)
        row.iconTile.applyTheme(theme)
        row.nameLabel.textColor = ink
        row.detailLabel.textColor = row.status == .checkFailed || row.status == .updateFailed ? HelmTheme.nsColor(theme.ansiHex[1]) : muted
        row.progressLabel.textColor = muted
        // `.isBordered = false` buttons don't pick up a text color from
        // `contentTintColor` (that only tints an image) - an attributed
        // title is the one way to make this link-styled button visually
        // read as "accent-colored," distinct from the rounded `updateButton`.
        row.installInBootstrapButton.attributedTitle = NSAttributedString(
            string: row.installInBootstrapButton.title,
            attributes: [.foregroundColor: HelmTheme.nsColor(theme.accentHex), .font: NSFont.systemFont(ofSize: 11, weight: .semibold)]
        )
        row.detailsButton.contentTintColor = ink.withAlphaComponent(0.5)
        row.logField.textColor = muted
        row.logContainer.layer?.backgroundColor = HelmTheme.nsColor(theme.backgroundHex).cgColor
        // Shared hover helper (phase 1): a subtle highlight on mouse
        // enter/exit, both colors theme-derived - mirrors
        // `SettingsController.descRow`'s identical `HoverHighlightView` use.
        row.rowContainer.normalColor = .clear
        row.rowContainer.hoverColor = line.withAlphaComponent(0.18)
    }
}

extension UpdatesController: NSSearchFieldDelegate {
    func controlTextDidChange(_ obj: Notification) {
        applyFilter()
    }
}
