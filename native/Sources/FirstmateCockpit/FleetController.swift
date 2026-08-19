// Manjesh Grand Line - native macOS app.
//
// Fix 1: the real Fleet dashboard for the Overview rail destination,
// replacing the "coming soon" `PlaceholderViewController`. Structure mirrors
// `backend/static/index.html`'s Fleet view: a greeting header, an answer
// banner that goes calm/loud depending on whether anything needs the
// captain, a row of quiet stat readouts, and an "In flight" section of
// working crew. All data comes from `FleetData.swift`, which reads this
// machine's real firstmate home - nothing here is fabricated.
//
// fm/grandline-overview-drop-duplicate-pr-list: this page used to also carry
// a full itemized "Ready to merge" list (one row per PR, its own Review/
// Merge actions) built from the exact same `OpenPRsSource.fetch()` +
// `FleetDataSource.mergedPRs` data `.review` (`ReviewController.swift`)
// already presents, grouped by forge - a captain-flagged triplication (stat
// tile + this list + Review's own list). That list is gone; the "ready to
// merge" stat tile is the one signal left here, and it's clickable straight
// through to `.review` via `onNavigateToReview`.

import AppKit

final class FleetController: NSViewController {

    private let scroll = NSScrollView()
    private let contentStack = NSStackView()

    private let greetingLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let refreshButton = NSButton()

    private let bannerView = NSView()
    private let bannerGlyph = NSTextField(labelWithString: "")
    private let bannerTitle = NSTextField(labelWithString: "")
    private let bannerBody = NSTextField(wrappingLabelWithString: "")

    private let statsRow = NSStackView()

    private let inFlightHeader = NSTextField(labelWithString: "")
    private let inFlightStack = NSStackView()

    /// Shown in place of the data sections above until the first
    /// `render(...)` lands - see the loading-state note on `buildLoadingState`.
    private let loadingContainer = NSView()
    private let loadingSpinner = NSProgressIndicator()
    private let loadingLabel = NSTextField(labelWithString: "Loading fleet data\u{2026}")
    private var inFlightSectionView: NSView!
    /// Every `HelmCard` on this page, re-themed together. Replaces this
    /// file's own copy of the card theming loop (audit §3.2).
    private var cards: [HelmCard] = []
    private var hasLoadedOnce = false

    private var theme: HelmTheme = ThemeManager.shared.theme
    private var isLoading = false

    /// fm/grandline-sidebar-badges: fires every time `render` recomputes the
    /// banner's "needs your call" set (`needs_decision`/`blocked` tasks) -
    /// the exact same signal the banner text above already surfaces, not a
    /// new count invented for the rail. `AppShellController` forwards this
    /// straight to `IconRailController.setBadgeCount(_:for: .overview)`.
    var onNeedsDecisionCountChanged: ((Int) -> Void)?

    /// fm/grandline-overview-drop-duplicate-pr-list: fired when the captain
    /// clicks the "ready to merge" stat tile - `AppShellController` wires
    /// this to `show(.review)`, the same navigation call every other
    /// cross-page jump in this app already uses.
    var onNavigateToReview: (() -> Void)?

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 940, height: 720))
        root.wantsLayer = true
        view = root

        // `FlippedView` (not a plain `NSView`), matching `SettingsController`'s
        // established Fix 4 pattern: a non-flipped document view puts y=0 at
        // its *bottom*, so before data arrives - while the content is still
        // shorter than the viewport, since `inFlightStack` starts with zero
        // arranged subviews - AppKit rests it against the bottom of
        // the clip view, leaving a blank gap the size of the shortfall sitting
        // above it, with the header pushed down into (or past) that gap. Once
        // rows are added and the content grows, it snaps back up - exactly the
        // "empty area above the header for several seconds" bug. A flipped
        // document view pins y=0 to the top always, so the header never moves.
        let content = FlippedView()
        content.translatesAutoresizingMaskIntoConstraints = false

        let header = buildHeader()
        buildBanner()
        buildStatsRow()
        let loadingSection = buildLoadingState()
        let inFlightSection = buildSection(header: inFlightHeader, iconSymbol: "clock", title: "In flight", stack: inFlightStack)
        inFlightSectionView = inFlightSection

        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = 20
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        contentStack.addArrangedSubview(header)
        contentStack.addArrangedSubview(loadingSection)
        contentStack.addArrangedSubview(bannerView)
        contentStack.addArrangedSubview(statsRow)
        contentStack.addArrangedSubview(inFlightSection)

        // The data sections stay hidden behind the loading skeleton until the
        // first successful `render(...)` - see `buildLoadingState`.
        bannerView.isHidden = true
        statsRow.isHidden = true
        inFlightSection.isHidden = true

        content.addSubview(contentStack)
        NSLayoutConstraint.activate([
            contentStack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: HelmMetrics.pageGutter),
            contentStack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -HelmMetrics.pageGutter),
            contentStack.topAnchor.constraint(equalTo: content.topAnchor, constant: 24),
            contentStack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -28),
            loadingSection.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
            bannerView.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
            statsRow.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
            inFlightSection.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
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

        ThemeManager.shared.observe { [weak self, weak root] theme in
            self?.theme = theme
            // Fix 8 (fixes4): this view never forced its appearance to the
            // active Helm theme, so every system-semantic color used below
            // (`.secondaryLabelColor` on PR/task subtitles) resolved against
            // the OS's actual light/dark setting instead - producing
            // near-invisible text whenever that setting disagreed with the
            // chosen Helm theme (e.g. system Light + a dark Helm theme gives
            // light-mode dark text on a dark background).
            root?.appearance = NSAppearance(named: theme.mode == .dark ? .darkAqua : .aqua)
            self?.applyTheme()
        }
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        // cockpit-native-fixes5: force the pending Auto Layout pass to run
        // before reading/setting scroll position. On the very first
        // appearance this view's constraints resolve for the first time in
        // the same tick the automatic viewWillAppear fires (isHidden was
        // true, so AppKit had no reason to lay it out earlier) - without this,
        // `scrollToTop()` below could act on stale (pre-layout) geometry. On
        // every later appearance this is a cheap no-op (already resolved).
        view.layoutSubtreeIfNeeded()
        scrollToTop()
        refresh()
    }

    /// The document view (`content`, a `FlippedView`) puts y=0 at its top,
    /// but a freshly laid-out `NSScrollView` can still leave the clip view's
    /// bounds wherever the last layout pass settled - so force it back
    /// explicitly on every appearance rather than trusting the default.
    /// Mirrors `SettingsController.scrollToTop`.
    private func scrollToTop() {
        scroll.contentView.scroll(to: .zero)
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    // MARK: Building the static chrome

    private func buildHeader() -> NSView {
        greetingLabel.font = HelmType.pageTitle()
        greetingLabel.translatesAutoresizingMaskIntoConstraints = false

        subtitleLabel.font = .systemFont(ofSize: 12)
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false

        refreshButton.title = ""
        refreshButton.isBordered = false
        refreshButton.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "Refresh")
        refreshButton.target = self
        refreshButton.action = #selector(refreshTapped)
        refreshButton.toolTip = "Refresh fleet data"
        refreshButton.translatesAutoresizingMaskIntoConstraints = false

        let textStack = NSStackView(views: [greetingLabel, subtitleLabel])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 4

        let row = NSStackView(views: [textStack, refreshButton])
        row.orientation = .horizontal
        row.spacing = 12
        row.translatesAutoresizingMaskIntoConstraints = false
        return row
    }

    private func buildBanner() {
        bannerView.wantsLayer = true
        bannerView.layer?.cornerRadius = 12
        bannerView.translatesAutoresizingMaskIntoConstraints = false

        bannerGlyph.font = .systemFont(ofSize: 22)
        bannerGlyph.translatesAutoresizingMaskIntoConstraints = false

        bannerTitle.font = .systemFont(ofSize: 14, weight: .semibold)
        bannerTitle.translatesAutoresizingMaskIntoConstraints = false

        bannerBody.font = .systemFont(ofSize: 12)
        bannerBody.translatesAutoresizingMaskIntoConstraints = false

        let textStack = NSStackView(views: [bannerTitle, bannerBody])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 3
        textStack.translatesAutoresizingMaskIntoConstraints = false

        bannerView.addSubview(bannerGlyph)
        bannerView.addSubview(textStack)
        NSLayoutConstraint.activate([
            bannerGlyph.leadingAnchor.constraint(equalTo: bannerView.leadingAnchor, constant: 16),
            bannerGlyph.centerYAnchor.constraint(equalTo: bannerView.centerYAnchor),
            textStack.leadingAnchor.constraint(equalTo: bannerGlyph.trailingAnchor, constant: 14),
            textStack.trailingAnchor.constraint(lessThanOrEqualTo: bannerView.trailingAnchor, constant: -16),
            textStack.topAnchor.constraint(equalTo: bannerView.topAnchor, constant: 14),
            textStack.bottomAnchor.constraint(equalTo: bannerView.bottomAnchor, constant: -14),
        ])
    }

    private func buildStatsRow() {
        statsRow.orientation = .horizontal
        statsRow.distribution = .fillEqually
        statsRow.spacing = 10
        statsRow.translatesAutoresizingMaskIntoConstraints = false
    }

    /// A skeleton that occupies the content area under the header from the
    /// very first frame - the banner/stats/In flight/Ready to merge sections
    /// stay hidden (and animation-free) until the first `render(...)` lands,
    /// so there is never an interval where the page shows nothing but a
    /// collapsed, empty-looking stack of cards while `refresh()`'s
    /// background fetch (real `gh`/Bitbucket network calls) is in flight.
    private func buildLoadingState() -> NSView {
        loadingSpinner.style = .spinning
        loadingSpinner.isIndeterminate = true
        loadingSpinner.controlSize = .regular
        loadingSpinner.translatesAutoresizingMaskIntoConstraints = false
        loadingSpinner.startAnimation(nil)

        loadingLabel.font = .systemFont(ofSize: 12)
        loadingLabel.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [loadingSpinner, loadingLabel])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false

        loadingContainer.wantsLayer = true
        loadingContainer.layer?.cornerRadius = 10
        loadingContainer.translatesAutoresizingMaskIntoConstraints = false
        loadingContainer.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: loadingContainer.centerXAnchor),
            stack.topAnchor.constraint(equalTo: loadingContainer.topAnchor, constant: 40),
            stack.bottomAnchor.constraint(equalTo: loadingContainer.bottomAnchor, constant: -40),
        ])
        return loadingContainer
    }

    /// `onClick`, when set, wires a plain `NSClickGestureRecognizer` on the
    /// tile's container - no nested real control, so no hit-testing hazard
    /// (matching `SettingsController`'s theme/session cards and
    /// `ShiftProjectViews`' project cards, the same clickable-plain-view
    /// pattern used throughout this app). fm/grandline-overview-drop-
    /// duplicate-pr-list: this is how the "ready to merge" stat tile jumps
    /// straight to `.review`'s full list, after removing this page's own
    /// duplicate itemized copy of it.
    private func statTile(icon: String, value: String, label: String, onClick: Selector? = nil) -> NSView {
        let container = NSView()
        container.wantsLayer = true
        container.layer?.cornerRadius = 10
        container.translatesAutoresizingMaskIntoConstraints = false
        if let onClick {
            container.addGestureRecognizer(NSClickGestureRecognizer(target: self, action: onClick))
            container.toolTip = "View in Review"
        }

        let iconView = NSImageView()
        iconView.image = NSImage(systemSymbolName: icon, accessibilityDescription: label)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 11, weight: .medium))
        iconView.translatesAutoresizingMaskIntoConstraints = false

        let valueLabel = NSTextField(labelWithString: value)
        valueLabel.font = .monospacedDigitSystemFont(ofSize: 15, weight: .semibold)
        valueLabel.translatesAutoresizingMaskIntoConstraints = false

        let nameLabel = NSTextField(labelWithString: label)
        nameLabel.font = .systemFont(ofSize: 9.5)
        nameLabel.translatesAutoresizingMaskIntoConstraints = false

        let topRow = NSStackView(views: [iconView, valueLabel])
        topRow.orientation = .horizontal
        topRow.spacing = 5
        topRow.alignment = .firstBaseline
        topRow.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [topRow, nameLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 3
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 10),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -8),
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 8),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -8),
            container.heightAnchor.constraint(equalToConstant: 50),
        ])
        stashedTileParts.append((container, iconView, valueLabel, nameLabel))
        return container
    }

    /// Stat-tile subviews needing per-theme restyling, kept alongside the
    /// containers built each refresh (the row is rebuilt from scratch every
    /// time, so this list is cleared and repopulated in `rebuildStats`).
    private var stashedTileParts: [(NSView, NSImageView, NSTextField, NSTextField)] = []

    /// One `HelmCard` per section - the shared container from
    /// `HelmDesignSystem.swift`. This used to be a bare header-row-over-stack
    /// with no chrome at all, near-identical to `ReviewController`'s copy and
    /// differing from it only in one stack spacing (audit §3.2). The caller
    /// keeps its own title label, since it rewrites the text with a live
    /// count; the card owns that label's font and colour.
    private func buildSection(header: NSTextField, iconSymbol: String, title: String, stack: NSStackView) -> HelmCard {
        header.stringValue = title

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false

        let card = HelmCard()
        card.setHeader(symbol: iconSymbol, titleLabel: header)
        card.setBody(stack, insets: HelmCard.contentInsets)
        cards.append(card)
        return card
    }

    // MARK: Refresh

    @objc private func refreshTapped() { refresh() }

    /// fm/grandline-sidebar-badges: lets `AppShellController` trigger this
    /// page's own existing refresh at app launch, so the rail's Overview
    /// badge has a real count before the captain ever visits this
    /// destination - not a new poll loop, just an earlier call to the one
    /// that already exists (also fired again by every `viewWillAppear` visit
    /// and the manual refresh button, unchanged).
    func refreshIfNeeded() { refresh() }

    private func refresh() {
        guard !isLoading else { return }
        isLoading = true
        refreshButton.isEnabled = false
        // snapshot() (~0.5s: task/backlog counts, watcher health) and
        // OpenPRsSource.fetch() (the slow, network-bound per-clone PR scan)
        // are independent - render the fast fields the moment snapshot()
        // finishes instead of blocking that on the PR fetch too, then
        // re-render once the PR list itself lands. The "Ready to merge"
        // section/stat tile shows its own loading state in between.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let snapshot = FleetDataSource.snapshot()
            DispatchQueue.main.async {
                guard let self else { return }
                self.render(snapshot: snapshot, mergedPRs: nil)
            }
            let openPRs = OpenPRsSource.fetch()
            let merged = FleetDataSource.mergedPRs(openPRs: openPRs, tasks: snapshot.tasks)
            DispatchQueue.main.async {
                guard let self else { return }
                self.isLoading = false
                self.refreshButton.isEnabled = true
                self.render(snapshot: snapshot, mergedPRs: merged)
            }
        }
    }

    // MARK: Rendering

    /// `mergedPRs == nil` means the (slow) PR fetch hasn't finished yet -
    /// every other field from `snapshot` still renders immediately, and the
    /// "ready to merge" stat tile shows 0 until this method is called again
    /// once the fetch completes.
    private func render(snapshot: FleetSnapshot, mergedPRs: [MergedPR]?) {
        if !hasLoadedOnce {
            hasLoadedOnce = true
            loadingSpinner.stopAnimation(nil)
            loadingContainer.isHidden = true
            bannerView.isHidden = false
            statsRow.isHidden = false
            inFlightSectionView.isHidden = false
        }

        rowContainers.removeAll()
        emptyStateLabels.removeAll()

        let working = snapshot.tasks.filter { $0.status == "working" }
        let needs = snapshot.tasks.filter { $0.status == "needs_decision" || $0.status == "blocked" }
        onNeedsDecisionCountChanged?(needs.count)

        let hour = Calendar.current.component(.hour, from: Date())
        let part = hour < 5 ? "Still up" : hour < 12 ? "Good morning" : hour < 17 ? "Good afternoon" : "Good evening"
        greetingLabel.stringValue = "\(part), \(snapshot.captain)"
        let df = DateFormatter()
        df.setLocalizedDateFormatFromTemplate("EEEE")
        subtitleLabel.stringValue = snapshot.homeOk
            ? "\(df.string(from: Date())) \u{00B7} the fleet is yours"
            : "firstmate home not found at \(FirstmateHome.root.path) - set FM_HOME"

        renderBanner(needs: needs, working: working, readyCount: mergedPRs?.count ?? 0)
        rebuildStats(working: working.count, ready: mergedPRs?.count ?? 0, snapshot: snapshot)
        rebuildTaskRows(into: inFlightStack, tasks: working, emptyTitle: "All hands idle", emptyBody: "No crew are working right now. Send your first mate a task from the console and this board lights up.")
        inFlightHeader.stringValue = "In flight (\(working.count))"

        applyTheme()

        // cockpit-native-fixes5: the loading skeleton's content is much
        // shorter than the real data (header + spinner only), so the first
        // successful render() here can grow the document's height by several
        // hundred points while the view is already visible - nothing else
        // re-pins the scroll position after that resize. Re-run scrollToTop()
        // defensively so a first-appearance visit that's still showing the
        // skeleton when this lands can't end up scrolled anywhere but the top
        // once the real content replaces it.
        view.layoutSubtreeIfNeeded()
        scrollToTop()
    }

    private func renderBanner(needs: [FleetTask], working: [FleetTask], readyCount: Int) {
        if needs.isEmpty {
            bannerGlyph.stringValue = "\u{2713}"
            bannerTitle.stringValue = "All clear - nothing needs you"
            bannerBody.stringValue = "\(working.count) crew working, \(readyCount) PR\(readyCount == 1 ? "" : "s") ready to merge. Nobody is parked on a decision."
            bannerIsAlert = false
        } else {
            let decisions = needs.filter { $0.status == "needs_decision" }.count
            let blocked = needs.filter { $0.status == "blocked" }.count
            var bits: [String] = []
            if decisions > 0 { bits.append("\(decisions) decision\(decisions > 1 ? "s" : "") waiting") }
            if blocked > 0 { bits.append("\(blocked) blocked") }
            bannerGlyph.stringValue = "\u{26A0}\u{FE0F}"
            bannerTitle.stringValue = "\(needs.count) task\(needs.count > 1 ? "s" : "") need your call"
            bannerBody.stringValue = bits.joined(separator: " \u{00B7} ") + " - the crew is holding for you."
            bannerIsAlert = true
        }
    }

    private var bannerIsAlert = false

    private func rebuildStats(working: Int, ready: Int, snapshot: FleetSnapshot) {
        for v in statsRow.arrangedSubviews {
            statsRow.removeArrangedSubview(v)
            v.removeFromSuperview()
        }
        stashedTileParts.removeAll()

        let watcherLabel: String
        switch snapshot.watcher.status {
        case "healthy": watcherLabel = "watcher healthy"
        case "stale": watcherLabel = "watcher stale"
        default: watcherLabel = "watcher off"
        }

        statsRow.addArrangedSubview(statTile(icon: "clock", value: "\(working)", label: "working"))
        statsRow.addArrangedSubview(statTile(icon: "arrow.triangle.pull", value: "\(ready)", label: "ready to merge", onClick: #selector(readyToMergeTileClicked)))
        statsRow.addArrangedSubview(statTile(icon: "line.3.horizontal", value: "\(snapshot.queuedCount)", label: "queued"))
        statsRow.addArrangedSubview(statTile(icon: "checkmark.circle", value: "\(snapshot.doneCount)", label: "done today"))
        statsRow.addArrangedSubview(statTile(icon: "shippingbox", value: "\(snapshot.projectsCount)", label: "projects"))
        statsRow.addArrangedSubview(statTile(icon: "waveform.path.ecg", value: "", label: watcherLabel))
    }

    private func rebuildTaskRows(into stack: NSStackView, tasks: [FleetTask], emptyTitle: String, emptyBody: String) {
        for v in stack.arrangedSubviews {
            stack.removeArrangedSubview(v)
            v.removeFromSuperview()
        }
        if tasks.isEmpty {
            stack.addArrangedSubview(emptyStateView(icon: "tray", title: emptyTitle, body: emptyBody))
            return
        }
        for task in tasks {
            let row = taskRowView(task)
            stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
    }

    private func emptyStateView(icon: String, title: String, body: String) -> NSView {
        let iconView = NSImageView()
        iconView.image = NSImage(systemSymbolName: icon, accessibilityDescription: title)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 24, weight: .light))
        iconView.translatesAutoresizingMaskIntoConstraints = false

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)

        let bodyLabel = NSTextField(wrappingLabelWithString: body)
        bodyLabel.font = .systemFont(ofSize: 11.5)
        bodyLabel.preferredMaxLayoutWidth = 420

        let stack = NSStackView(views: [iconView, titleLabel, bodyLabel])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.wantsLayer = true
        container.layer?.cornerRadius = 10
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 22),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -22),
        ])
        emptyStateLabels.append((container, iconView, titleLabel, bodyLabel))
        return container
    }

    private var emptyStateLabels: [(NSView, NSImageView, NSTextField, NSTextField)] = []

    private func taskRowView(_ task: FleetTask) -> NSView {
        let (symbol, colorHex, pillLabel) = taskVisuals(task)

        let iconView = NSImageView()
        iconView.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 14, weight: .medium))
        iconView.contentTintColor = HelmTheme.nsColor(colorHex)
        iconView.translatesAutoresizingMaskIntoConstraints = false

        let idLabel = NSTextField(labelWithString: task.id)
        idLabel.font = .systemFont(ofSize: 12.5, weight: .medium)
        idLabel.lineBreakMode = .byTruncatingTail
        idLabel.maximumNumberOfLines = 1

        let subBits = [task.repo, task.detail.isEmpty ? "source: \(task.source)" : task.detail].compactMap { $0 }.filter { !$0.isEmpty }
        let subLabel = NSTextField(labelWithString: subBits.joined(separator: " \u{00B7} "))
        subLabel.font = .systemFont(ofSize: 10.5)
        subLabel.textColor = HelmTheme.mutedInk(theme)
        subLabel.lineBreakMode = .byTruncatingTail
        subLabel.maximumNumberOfLines = 1

        let textStack = NSStackView(views: [idLabel, subLabel])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 2
        textStack.setContentHuggingPriority(.defaultLow, for: .horizontal)
        textStack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let pill = pillLabelView(text: pillLabel, colorHex: colorHex)

        let row = NSStackView(views: [iconView, textStack, pill])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false
        // Keep the icon and status pill at their natural size and let the
        // title/subtitle text truncate first under narrow widths, so the pill
        // never gets squeezed into wrapping onto a second line.
        iconView.setContentHuggingPriority(.required, for: .horizontal)
        iconView.setContentCompressionResistancePriority(.required, for: .horizontal)
        pill.setContentHuggingPriority(.required, for: .horizontal)
        pill.setContentCompressionResistancePriority(.required, for: .horizontal)

        return wrapRow(row, minHeight: 38)
    }

    private func taskVisuals(_ task: FleetTask) -> (symbol: String, colorHex: String, label: String) {
        switch task.status {
        case "needs_decision": return ("exclamationmark.triangle.fill", theme.ansiHex[3], "needs you")
        case "blocked": return ("xmark.octagon.fill", theme.ansiHex[1], "blocked")
        case "failed": return ("xmark.octagon.fill", theme.ansiHex[1], "failed")
        case "done": return ("checkmark.circle.fill", theme.ansiHex[2], "done")
        case "working": return ("clock.fill", theme.accentHex, "working")
        default: return ("circle.dashed", theme.chromeInkHex, "idle")
        }
    }

    private func pillLabelView(text: String, colorHex: String) -> NSView {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 10, weight: .semibold)
        label.textColor = HelmTheme.nsColor(colorHex)
        let container = NSView()
        container.wantsLayer = true
        container.layer?.cornerRadius = 8
        container.layer?.backgroundColor = HelmTheme.nsColor(colorHex).withAlphaComponent(0.15).cgColor
        container.translatesAutoresizingMaskIntoConstraints = false
        label.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 7),
            label.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -7),
            label.topAnchor.constraint(equalTo: container.topAnchor, constant: 2),
            label.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -2),
        ])
        return container
    }

    private func wrapRow(_ row: NSStackView, minHeight: CGFloat) -> NSView {
        let container = NSView()
        container.wantsLayer = true
        container.layer?.cornerRadius = 9
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 10),
            row.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -10),
            row.topAnchor.constraint(equalTo: container.topAnchor, constant: 6),
            row.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -6),
            container.heightAnchor.constraint(greaterThanOrEqualToConstant: minHeight),
        ])
        rowContainers.append(container)
        return container
    }

    private var rowContainers: [NSView] = []

    // MARK: Actions

    @objc private func readyToMergeTileClicked() {
        onNavigateToReview?()
    }

    // MARK: Theme

    private func applyTheme() {
        view.layer?.backgroundColor = HelmTheme.nsColor(theme.backgroundHex).cgColor
        for card in cards { card.applyTheme(theme) }
        let ink = HelmTheme.nsColor(theme.chromeInkHex)
        let surface = HelmTheme.nsColor(theme.chromeBackgroundHex)
        let line = HelmTheme.nsColor(theme.chromeLineHex)

        // Fix 8 (fixes4): every "muted" text style below now routes through
        // `HelmTheme.mutedInk`, not its own ad hoc alpha - `0.55`/`0.6` looked
        // fine in the dark palettes but measured below WCAG AA (as low as
        // 3.33:1) in all four light ones. See `mutedInk`'s doc comment for
        // the measured numbers.
        let muted = HelmTheme.mutedInk(theme)
        greetingLabel.textColor = ink
        subtitleLabel.textColor = muted
        refreshButton.contentTintColor = ink.withAlphaComponent(0.7)

        loadingContainer.layer?.backgroundColor = surface.cgColor
        loadingContainer.layer?.borderWidth = 1
        loadingContainer.layer?.borderColor = line.withAlphaComponent(0.4).cgColor
        loadingLabel.textColor = muted

        let bannerColorHex = bannerIsAlert ? theme.ansiHex[3] : theme.ansiHex[2]
        let bannerColor = HelmTheme.nsColor(bannerColorHex)
        bannerView.layer?.backgroundColor = bannerColor.withAlphaComponent(0.12).cgColor
        bannerTitle.textColor = ink
        bannerBody.textColor = muted

        for (container, iconView, valueLabel, nameLabel) in stashedTileParts {
            container.layer?.backgroundColor = surface.cgColor
            container.layer?.borderWidth = 1
            container.layer?.borderColor = line.withAlphaComponent(0.5).cgColor
            iconView.contentTintColor = ink.withAlphaComponent(0.65)
            valueLabel.textColor = ink
            nameLabel.textColor = muted
        }
        for (container, iconView, titleLabel, bodyLabel) in emptyStateLabels {
            container.layer?.backgroundColor = surface.cgColor
            container.layer?.borderWidth = 1
            container.layer?.borderColor = line.withAlphaComponent(0.4).cgColor
            iconView.contentTintColor = ink.withAlphaComponent(0.4)
            titleLabel.textColor = ink
            bodyLabel.textColor = muted
        }
        for container in rowContainers {
            container.layer?.backgroundColor = surface.cgColor
            container.layer?.borderWidth = 1
            container.layer?.borderColor = line.withAlphaComponent(0.4).cgColor
        }
    }
}
