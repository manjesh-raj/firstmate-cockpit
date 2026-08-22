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
    /// A labeled `HelmButton(.quiet)`, matching the prototype's own page
    /// header (and every other page's refresh action) rather than the bare
    /// borderless glyph tucked beside the greeting this page used to have.
    private let refreshButton = HelmButton(title: "Refresh", variant: .quiet, symbol: "arrow.clockwise")

    /// The answer banner is the app's shared `HelmAccentRow` now, not a
    /// hand-rolled tinted slab with a text glyph in it. The prototype renders
    /// it exactly like every other alert card in the app - a 3pt accent bar, a
    /// round badge, an uppercase kicker ("ALL CLEAR" / "NEEDS YOU"), the
    /// headline and a meta line - and the audit's whole point was that this
    /// page had its own private version of an idea the design system already
    /// owns.
    private let bannerRow = HelmAccentRow(hover: false)

    private let statsRow = NSStackView()

    /// A plain section heading (round glyph + title + count chip), not a
    /// `HelmCard` wrapper. The prototype puts "In flight" rows straight on the
    /// page: they are `HelmAccentRow` cards already, so a card around a list
    /// of cards is a second border for nothing.
    private let inFlightHeader = NSTextField(labelWithString: "")
    private let inFlightCountChip = NSView()
    private let inFlightCountLabel = NSTextField(labelWithString: "")
    private let inFlightGlyph = IconTileView(size: 22, cornerRadius: 11)
    private let inFlightStack = NSStackView()

    /// Shown in place of the data sections above until the first
    /// `render(...)` lands - see the loading-state note on `buildLoadingState`.
    private let loadingContainer = NSView()
    private let loadingSpinner = NSProgressIndicator()
    private let loadingLabel = NSTextField(labelWithString: "Loading fleet data\u{2026}")
    private var inFlightSectionView: NSView!
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

    /// GL-31: firstmate home not being configured is a *setup* state, not a
    /// fleet state - so Overview says so and offers the one action that fixes
    /// it, instead of printing a raw environment-variable name as UI copy and
    /// leaving the captain to find the Setup flyout on their own.
    var onNavigateToSetup: (() -> Void)?

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
        buildStatsRow()
        let loadingSection = buildLoadingState()
        let inFlightSection = buildSection(title: "In flight")
        inFlightSectionView = inFlightSection

        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = 20
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        contentStack.addArrangedSubview(header)
        contentStack.addArrangedSubview(loadingSection)
        contentStack.addArrangedSubview(bannerRow)
        contentStack.addArrangedSubview(statsRow)
        contentStack.addArrangedSubview(inFlightSection)

        // The data sections stay hidden behind the loading skeleton until the
        // first successful `render(...)` - see `buildLoadingState`.
        bannerRow.isHidden = true
        statsRow.isHidden = true
        inFlightSection.isHidden = true

        content.addSubview(contentStack)
        NSLayoutConstraint.activate([
            contentStack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: HelmMetrics.pageGutter),
            contentStack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -HelmMetrics.pageGutter),
            contentStack.topAnchor.constraint(equalTo: content.topAnchor, constant: 24),
            contentStack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -28),
            headerRow.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
            loadingSection.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
            bannerRow.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
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
        greetingLabel.font = HelmType.pageTitle(.serif)
        greetingLabel.translatesAutoresizingMaskIntoConstraints = false

        subtitleLabel.font = .systemFont(ofSize: 12)
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false

        refreshButton.target = self
        refreshButton.action = #selector(refreshTapped)
        refreshButton.toolTip = "Refresh fleet data"
        refreshButton.setContentHuggingPriority(.required, for: .horizontal)
        refreshButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        refreshButton.translatesAutoresizingMaskIntoConstraints = false

        let textStack = NSStackView(views: [greetingLabel, subtitleLabel])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 4
        textStack.translatesAutoresizingMaskIntoConstraints = false
        textStack.setHuggingPriority(.defaultLow, for: .horizontal)

        // `.fill` plus a flexible spacer, so Refresh sits at the page's own
        // trailing edge (prototype `.phead .row`) instead of hugging the
        // greeting. See AGENTS.md gotcha (10)/(12): a nested stack has no
        // intrinsic size, so the spacer - not the text stack - is what carries
        // the low hugging priority the distribution actually stretches.
        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        spacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let row = NSStackView(views: [textStack, spacer, refreshButton])
        row.orientation = .horizontal
        row.alignment = .lastBaseline
        row.distribution = .fill
        row.spacing = 12
        row.translatesAutoresizingMaskIntoConstraints = false
        headerRow = row
        return row
    }

    /// Kept so `loadView` can pin it to the content column's full width -
    /// without that the row shrinks to its content and Refresh stops being at
    /// the page's trailing edge.
    private var headerRow: NSStackView!

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

    /// One `HelmStatTile` - the app's shared stat tile
    /// (`HelmDesignSystem.swift`, audit §6.3 component 4). This page's own copy
    /// was one of three (four, counting Shift's duplicate) differing in metric
    /// size, padding, fill opacity and height for the same "one big number and
    /// a caption" job; its click support is what the shared component adopted.
    ///
    /// `onClick` is a plain closure on the tile - no nested real control, so no
    /// hit-testing hazard (matching `SettingsController`'s theme/session cards
    /// and `ShiftProjectViews`' project cards, the same clickable-plain-view
    /// pattern used throughout this app). fm/grandline-overview-drop-duplicate-
    /// pr-list: this is how the "ready to merge" tile jumps straight to
    /// `.review`'s full list, after removing this page's own duplicate
    /// itemized copy of it.
    private func statTile(icon: String, value: String, label: String, tint: HelmTint? = nil, onClick: (() -> Void)? = nil) -> NSView {
        let tile = HelmStatTile(symbol: icon, value: value, caption: label, tint: tint)
        if let onClick {
            tile.onClick = onClick
            tile.toolTip = "View in Review"
        }
        statTiles.append(tile)
        return tile
    }

    /// Rebuilt from scratch on every refresh, so this list is cleared and
    /// repopulated in `rebuildStats`. Each tile themes itself; this only exists
    /// so `applyTheme` can hand every live tile the new theme.
    private var statTiles: [HelmStatTile] = []

    /// The "In flight" section: a plain heading (round glyph + title + count
    /// chip) over the rows, exactly as the prototype's `h2.sect` renders it -
    /// **not** a `HelmCard`.
    ///
    /// The rows below are `HelmAccentRow` cards, each with its own fill and
    /// border, so wrapping them in a second card put a border around a list of
    /// borders and made Overview read as one uniform slab. Review keeps its
    /// cards because those group PRs *by forge*; there is one group here.
    private func buildSection(title: String) -> NSView {
        inFlightHeader.stringValue = title
        inFlightHeader.font = HelmType.sectionTitle()
        inFlightHeader.translatesAutoresizingMaskIntoConstraints = false

        inFlightGlyph.configure(symbol: "clock", tint: .accent, pointSize: 11)
        inFlightGlyph.setContentHuggingPriority(.required, for: .horizontal)

        inFlightCountLabel.font = HelmType.metric(11, weight: .medium)
        inFlightCountLabel.translatesAutoresizingMaskIntoConstraints = false
        inFlightCountChip.wantsLayer = true
        inFlightCountChip.layer?.cornerRadius = 5
        inFlightCountChip.translatesAutoresizingMaskIntoConstraints = false
        inFlightCountChip.addSubview(inFlightCountLabel)
        NSLayoutConstraint.activate([
            inFlightCountLabel.leadingAnchor.constraint(equalTo: inFlightCountChip.leadingAnchor, constant: 6),
            inFlightCountLabel.trailingAnchor.constraint(equalTo: inFlightCountChip.trailingAnchor, constant: -6),
            inFlightCountLabel.topAnchor.constraint(equalTo: inFlightCountChip.topAnchor, constant: 1),
            inFlightCountLabel.bottomAnchor.constraint(equalTo: inFlightCountChip.bottomAnchor, constant: -1),
        ])
        inFlightCountChip.setContentHuggingPriority(.required, for: .horizontal)

        let headingSpacer = NSView()
        headingSpacer.translatesAutoresizingMaskIntoConstraints = false
        headingSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let heading = NSStackView(views: [inFlightGlyph, inFlightHeader, inFlightCountChip, headingSpacer])
        heading.orientation = .horizontal
        heading.alignment = .centerY
        heading.distribution = .fill
        heading.spacing = HelmMetrics.s2
        heading.translatesAutoresizingMaskIntoConstraints = false

        inFlightStack.orientation = .vertical
        inFlightStack.alignment = .leading
        inFlightStack.spacing = HelmMetrics.s2
        inFlightStack.translatesAutoresizingMaskIntoConstraints = false

        let section = NSStackView(views: [heading, inFlightStack])
        section.orientation = .vertical
        section.alignment = .leading
        section.spacing = HelmMetrics.s3
        section.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            heading.widthAnchor.constraint(equalTo: section.widthAnchor),
            inFlightStack.widthAnchor.constraint(equalTo: section.widthAnchor),
        ])
        return section
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
            let fetched = OpenPRsSource.fetchDetailed()
            let merged = FleetDataSource.mergedPRs(openPRs: fetched.prs, tasks: snapshot.tasks)
            DispatchQueue.main.async {
                guard let self else { return }
                self.isLoading = false
                self.refreshButton.isEnabled = true
                self.render(snapshot: snapshot, mergedPRs: merged, prFetchFailure: fetched.failureSummary)
            }
        }
    }

    // MARK: Rendering

    /// `mergedPRs == nil` means the (slow) PR fetch hasn't finished yet -
    /// every other field from `snapshot` still renders immediately, and the
    /// "ready to merge" stat tile shows 0 until this method is called again
    /// once the fetch completes.
    /// `prFetchFailure` (GL-14) is a short reason string when the PR scan did
    /// not fully succeed. Overview's "ready to merge" tile is a
    /// should-I-act-on-something instrument, so a failed scan must read as
    /// "unknown", not as a confident `0`.
    private func render(snapshot: FleetSnapshot, mergedPRs: [MergedPR]?, prFetchFailure: String? = nil) {
        if !hasLoadedOnce {
            hasLoadedOnce = true
            loadingSpinner.stopAnimation(nil)
            loadingContainer.isHidden = true
            bannerRow.isHidden = false
            statsRow.isHidden = false
            inFlightSectionView.isHidden = false
        }

        accentRows.removeAll()
        emptyStates.removeAll()

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
            : "Setup isn't finished yet"

        renderBanner(needs: needs, working: working, readyCount: mergedPRs?.count ?? 0,
                     prFetchFailure: prFetchFailure, homeOk: snapshot.homeOk)
        rebuildStats(working: working.count, ready: mergedPRs?.count ?? 0, snapshot: snapshot,
                     prFetchFailure: prFetchFailure)
        rebuildTaskRows(into: inFlightStack, tasks: working, emptyTitle: "All hands idle", emptyBody: "No crew are working right now. Send your first mate a task from the console and this board lights up.")
        inFlightHeader.stringValue = "In flight"
        inFlightCountLabel.stringValue = "\(working.count)"

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

    /// The answer banner, as the shared `HelmAccentRow`. Same two states and
    /// same copy as before; only the presentation changed - the accent bar,
    /// the round badge and the uppercase kicker come from the component now
    /// rather than being absent.
    private func renderBanner(needs: [FleetTask], working: [FleetTask], readyCount: Int,
                              prFetchFailure: String? = nil, homeOk: Bool = true) {
        let content: HelmAccentRow.Content
        // GL-31: with no firstmate home resolved there is no fleet to report
        // on, and every number below it is zero for a reason that has nothing
        // to do with the fleet. Say the real thing, and make it actionable.
        if !homeOk {
            content = HelmAccentRow.Content(
                tint: .info,
                kicker: "Finish setup",
                title: "Point Manjesh Grand Line at your firstmate home",
                meta: "Nothing was found at \(FirstmateHome.root.path). Open Setup to choose the directory firstmate keeps its projects, backlog and crew state in.",
                badgeSymbol: "wrench.and.screwdriver.fill",
                chipText: "Open Setup")
            bannerRow.configure(content, theme: theme)
            bannerRow.onClick = { [weak self] in self?.onNavigateToSetup?() }
            return
        }
        bannerRow.onClick = nil
        if needs.isEmpty {
            // GL-14: an "all clear" banner must not assert something this
            // refresh could not actually verify. With a failed PR scan the
            // banner still reports what it does know (crew, decisions) and
            // says the PR half is unknown, rather than printing "0 PRs ready".
            let prPhrase = prFetchFailure == nil
                ? "\(readyCount) PR\(readyCount == 1 ? "" : "s") ready to merge"
                : "PR status unavailable"
            content = HelmAccentRow.Content(
                tint: prFetchFailure == nil ? .good : .warn,
                kicker: prFetchFailure == nil ? "All clear" : "Partly unknown",
                title: prFetchFailure == nil ? "Nothing needs you right now" : "Nothing known needs you right now",
                meta: "\(working.count) crew working \u{00B7} \(prPhrase) \u{00B7} nobody is parked on a decision.",
                badgeSymbol: prFetchFailure == nil ? "checkmark" : "wifi.exclamationmark")
        } else {
            let decisions = needs.filter { $0.status == "needs_decision" }.count
            let blocked = needs.filter { $0.status == "blocked" }.count
            var bits: [String] = []
            if decisions > 0 { bits.append("\(decisions) decision\(decisions > 1 ? "s" : "") waiting") }
            if blocked > 0 { bits.append("\(blocked) blocked") }
            content = HelmAccentRow.Content(
                tint: .warn,
                kicker: "Needs you",
                title: "\(needs.count) task\(needs.count > 1 ? "s" : "") need your call",
                meta: bits.joined(separator: " \u{00B7} ") + " - the crew is holding for you.",
                badgeSymbol: "exclamationmark.triangle.fill")
        }
        bannerRow.configure(content, theme: theme)
    }

    private func rebuildStats(working: Int, ready: Int, snapshot: FleetSnapshot,
                              prFetchFailure: String? = nil) {
        for v in statsRow.arrangedSubviews {
            statsRow.removeArrangedSubview(v)
            v.removeFromSuperview()
        }
        statTiles.removeAll()

        let watcherLabel: String
        switch snapshot.watcher.status {
        case "healthy": watcherLabel = "watcher healthy"
        case "stale": watcherLabel = "watcher stale"
        default: watcherLabel = "watcher off"
        }

        // Tinted by meaning, not uniformly ink - the prototype's own stat row.
        // A tint only ever means "this number is itself a signal": ready-to-
        // merge is the one actionable count and the only clickable tile, done-
        // today is a good outcome, and the watcher's own health decides its
        // own colour. Working / queued / projects stay plain, because a
        // coloured number there would be colour with nothing to say.
        // `HelmStatTile` runs every tint through `HelmContrast` (§5.7), so
        // none of these is the raw hue as text.
        let watcherTint: HelmTint
        switch snapshot.watcher.status {
        case "healthy": watcherTint = .good
        case "stale": watcherTint = .warn
        default: watcherTint = .neutral
        }
        statsRow.addArrangedSubview(statTile(icon: "clock", value: "\(working)", label: "working"))
        // GL-14: "\u{2014}" (an em dash), not "0", when the scan failed - the
        // tile is still clickable so the captain can go to Review and see the
        // real reason there.
        statsRow.addArrangedSubview(statTile(
            icon: prFetchFailure == nil ? "arrow.triangle.pull" : "wifi.exclamationmark",
            value: prFetchFailure == nil ? "\(ready)" : "\u{2014}",
            label: prFetchFailure == nil ? "ready to merge" : "PRs unavailable",
            tint: prFetchFailure == nil ? .accent : .warn,
            onClick: { [weak self] in self?.onNavigateToReview?() }))
        statsRow.addArrangedSubview(statTile(icon: "line.3.horizontal", value: "\(snapshot.queuedCount)", label: "queued"))
        statsRow.addArrangedSubview(statTile(icon: "checkmark.circle", value: "\(snapshot.doneCount)", label: "done today", tint: .good))
        statsRow.addArrangedSubview(statTile(icon: "shippingbox", value: "\(snapshot.projectsCount)", label: "projects"))
        statsRow.addArrangedSubview(statTile(icon: "waveform.path.ecg", value: snapshot.watcher.status == "healthy" ? "OK" : "\u{2014}", label: watcherLabel, tint: watcherTint))
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

    /// One `HelmEmptyState` - the app's shared empty state
    /// (`HelmDesignSystem.swift`, audit §6.3 component 5). `boxed: true` because
    /// this page's list sits directly on the page background with no card around
    /// it, so the empty state needs a container of its own to read as an object;
    /// that container is now `HelmCard`'s own fill and border rather than this
    /// page's third border alpha (§4.2 measured two on one page).
    private func emptyStateView(icon: String, title: String, body: String) -> NSView {
        let empty = HelmEmptyState(symbol: icon, title: title, body: body, size: .standard, boxed: true)
        emptyStates.append(empty)
        return empty
    }

    /// Rebuilt with the lists on every render; each state themes itself, so this
    /// only exists to reach the live ones from `applyTheme`.
    private var emptyStates: [HelmEmptyState] = []

    /// One "In flight" row, built from the app's shared `HelmAccentRow`
    /// (`HelmDesignSystem.swift`, audit §6.3 component 2). The audit (§4.2)
    /// found this row already had the badge and the status pill but neither
    /// the accent bar nor the kicker, so it read as almost - but not quite -
    /// the same object as a notification card or a Shift task; converging it
    /// was called "nearly free". The tint, glyph and pill text still come
    /// from `taskVisuals` below, i.e. from the crew state, unchanged.
    ///
    /// `hover: false` and no `onClick`: these rows are a read-only readout,
    /// exactly as before this migration.
    private func taskRowView(_ task: FleetTask) -> NSView {
        let visuals = taskVisuals(task)
        let row = HelmAccentRow(hover: false)
        let detail = task.detail.isEmpty ? "source: \(task.source)" : task.detail
        row.configure(HelmAccentRow.Content(
            tint: visuals.tint,
            // The repo is this row's "which thing is this about" line, the
            // same job the project name does on a Shift task row.
            kicker: task.repo ?? task.kind,
            title: task.id,
            meta: detail,
            badgeSymbol: visuals.symbol,
            chipText: visuals.label
        ), theme: theme)
        accentRows.append(row)
        return row
    }

    /// Live `HelmAccentRow`s, so a theme change re-tints them. They are
    /// rebuilt on every `render()`, so this is cleared alongside the stack.
    private var accentRows: [HelmAccentRow] = []

    /// Returns a `HelmTint` rather than a raw hex: the row's accent bar,
    /// badge and chip are all resolved from it by `HelmAccentRow`, and the
    /// chip in particular now goes through `ToolRowLayout.pill`'s
    /// contrast-corrected path (audit §5.7) instead of this file's own
    /// hue-on-a-wash-of-itself pill, which was another instance of that bug.
    private func taskVisuals(_ task: FleetTask) -> (symbol: String, tint: HelmTint, label: String) {
        switch task.status {
        case "needs_decision": return ("exclamationmark.triangle.fill", .warn, "needs you")
        case "blocked": return ("xmark.octagon.fill", .critical, "blocked")
        case "failed": return ("xmark.octagon.fill", .critical, "failed")
        case "done": return ("checkmark.circle.fill", .good, "done")
        case "working": return ("clock.fill", .accent, "working")
        default: return ("circle.dashed", .neutral, "idle")
        }
    }

    // MARK: Actions

    // MARK: Theme

    private func applyTheme() {
        view.layer?.backgroundColor = HelmTheme.nsColor(theme.backgroundHex).cgColor
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
        // `refreshButton` is a `HelmButton` and themes itself - never set
        // `contentTintColor` on one, `restyle()` owns that property.

        loadingContainer.layer?.backgroundColor = surface.cgColor
        loadingContainer.layer?.borderWidth = 1
        loadingContainer.layer?.borderColor = line.withAlphaComponent(0.4).cgColor
        loadingLabel.textColor = muted

        bannerRow.applyTheme(theme)
        inFlightHeader.textColor = ink
        inFlightGlyph.applyTheme(theme)
        inFlightCountChip.layer?.backgroundColor = ink.withAlphaComponent(0.08).cgColor
        inFlightCountLabel.textColor = muted

        for tile in statTiles { tile.applyTheme(theme) }
        for empty in emptyStates { empty.applyTheme(theme) }
        // Each row owns its own tint-derived chrome; it only needs the new
        // theme handed to it.
        for row in accentRows { row.applyTheme(theme) }
    }
}
