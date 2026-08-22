// Manjesh Grand Line - native macOS app.
//
// Fix 3 (theme-audit task): the real Review destination, replacing the
// "coming soon" `PlaceholderViewController`. Same data source as Overview's
// "Ready to merge" section (`OpenPRsSource.fetch()` + `FleetDataSource.
// mergedPRs`, the native port of `backend/openprs.py`) - that call already
// returns the complete, de-duplicated union of every open PR discovered
// across the captain's project clones and every PR a tracked task points
// at, so nothing here narrows it further. Rows are grouped by forge
// (github/bitbucket), matching the web cockpit's Review view
// (`backend/static/index.html`), each with title, repo, PR number, checks
// state, and the same Review/Merge actions Overview's list already wires up.
//
// fm/grandline-review-page-redesign: brought this page up to the same design
// language `FleetController`/`VaultController`/every other card-bearing
// destination already uses, closing the gap a captain-supplied Lavish
// prototype flagged (this page was still a flat list of plain pill-and-
// button rows with no page header, no stats and no colour-by-status
// styling). Every piece below maps to an existing Helm* primitive:
//   - a `HelmType.pageTitle(.serif)` hero + a live subtitle + a quiet
//     `HelmButton` refresh, mirroring `FleetController.buildHeader` exactly
//     (the hero title carries real information - "Ready to merge" - rather
//     than restating the destination's own name, which is the distinction
//     `HelmType.pageTitle`'s own doc comment draws and the reason Phase 7
//     removed this page's *old* literal "Review" title in the first place).
//   - a `statsRow` of three `HelmStatTile`s (open / ready-to-merge / checks
//     running), the same "tint only when the number is itself a signal" rule
//     `FleetController.rebuildStats` already follows.
//   - each PR row is now a `HelmAccentRow` (chip below the body, Review/
//     Merge in `trailingAccessory`) instead of a hand-rolled tinted pill
//     row, colour-and-chip-mapped from the PR's own `checks` state - the
//     same real field this page already read, just finally driving the
//     row's colour instead of only a muted "no checks" label everywhere.
//   - each forge's `HelmCard` header gained a plain, neutral count badge
//     (the prototype's `.count` span) instead of baking the number into the
//     title string, plus a subtitle naming the account/org the PRs in that
//     section belong to (the prototype's "manjesh-raj" under "GitHub"),
//     derived from a real PR's own already-fetched URL rather than a
//     hardcoded name.
// No new data source, no invented colours/fonts/spacing - everything below
// is `HelmTheme`/`HelmMetrics`/`HelmType` tokens already in this codebase.

import AppKit

final class ReviewController: NSViewController {

    private let scroll = NSScrollView()
    private let contentStack = NSStackView()

    /// The hero title. "Ready to merge" is real information (which PRs need
    /// the captain, not just "here is the Review page") - not a restatement
    /// of the destination's own name, which is the bar `HelmType.pageTitle`'s
    /// doc comment sets and the reason Phase 7 removed this page's old
    /// literal "Review" title. Serif voice, matching every other page hero
    /// in the app (`FleetController`'s greeting, Shift's project name).
    private let heroLabel = NSTextField(labelWithString: "Ready to merge")
    /// Seeded rather than left blank: `render` does not fill it in until the
    /// background PR fetch returns - so an empty string here left the header
    /// row with nothing under the hero for the first second or two.
    private let subtitleLabel = NSTextField(labelWithString: "Open pull requests across your projects")
    /// A labelled `HelmButton(.quiet)`, matching every other page's own
    /// refresh action (`FleetController`, `VaultController`, `UpdatesController`)
    /// instead of a bare borderless glyph.
    private let refreshButton = HelmButton(title: "Refresh", variant: .quiet, symbol: "arrow.clockwise")
    /// Kept so `loadView` can pin it to the content column's full width -
    /// without that the row shrinks to its content and Refresh stops being
    /// at the page's trailing edge.
    private var headerRow: NSStackView!

    /// Three `HelmStatTile`s: open PRs (accent), ready to merge (good), and
    /// checks running (warn) - the same three numbers the per-row chips
    /// below already carry, just totalled. Rebuilt on every render like
    /// `FleetController.rebuildStats`.
    private let statsRow = NSStackView()
    private var statTiles: [HelmStatTile] = []

    private let githubHeader = NSTextField(labelWithString: "")
    private let githubSubtitle = NSTextField(wrappingLabelWithString: "")
    private let githubCountLabel = NSTextField(labelWithString: "0")
    private let githubStack = NSStackView()
    private let bitbucketHeader = NSTextField(labelWithString: "")
    private let bitbucketSubtitle = NSTextField(wrappingLabelWithString: "")
    private let bitbucketCountLabel = NSTextField(labelWithString: "0")
    private let bitbucketStack = NSStackView()
    private let otherHeader = NSTextField(labelWithString: "")
    private let otherSubtitle = NSTextField(wrappingLabelWithString: "")
    private let otherCountLabel = NSTextField(labelWithString: "0")
    private let otherStack = NSStackView()
    /// The "Other" section (forge-less, task-tracked PRs the forge scan
    /// hasn't matched yet) only renders when non-empty - unlike GitHub/
    /// Bitbucket, which always show (matching `FleetController`'s "In
    /// flight"/"Ready to merge" sections, always visible with their own
    /// empty-state card), this bucket has no meaning for a shop that only
    /// uses supported forges and would otherwise be permanent visual noise.
    private var otherSection = NSView()

    /// Shown in place of the three forge sections above until the first
    /// `render(...)` lands - see the loading-state note on `buildLoadingState`.
    private let loadingContainer = NSView()
    private let loadingSpinner = NSProgressIndicator()
    private let loadingLabel = NSTextField(labelWithString: "Loading open PRs\u{2026}")
    private var githubSectionView: NSView!
    /// Every `HelmCard` on this page, re-themed together. Replaces this
    /// file's own copy of the card theming loop (audit §3.2).
    private var cards: [HelmCard] = []
    private var bitbucketSectionView: NSView!
    private var hasLoadedOnce = false

    /// Each forge card's neutral "N" badge - the prototype's `.count` span
    /// (mono, muted, a faint ink wash) - and the label it wraps, paired so
    /// `applyTheme` can re-colour both without a second lookup.
    private var countBadges: [(container: NSView, label: NSTextField)] = []

    private var theme: HelmTheme = ThemeManager.shared.theme
    private var isLoading = false

    /// fm/grandline-sidebar-badges: fires every time `render` recomputes the
    /// full open-PR list - the same `mergedPRs` this page already shows, not
    /// a narrower or invented filter. `AppShellController` forwards this
    /// straight to `IconRailController.setBadgeCount(_:for: .review)`.
    var onOpenPRCountChanged: ((Int) -> Void)?

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 940, height: 720))
        root.wantsLayer = true
        view = root

        // `FlippedView` (not a plain `NSView`), matching `SettingsController`'s
        // established Fix 4 pattern and now `FleetController`'s: a non-flipped
        // document view puts y=0 at its *bottom*, so before data arrives -
        // while content is still shorter than the viewport, since every
        // forge stack starts with zero arranged subviews - AppKit rests it
        // against the bottom of the clip view, leaving a blank gap the size
        // of the shortfall sitting above it, with the header pushed down
        // into (or past) that gap. Once rows are added and the content
        // grows, it snaps back up - exactly the "empty area above the
        // header for several seconds" bug. A flipped document view pins
        // y=0 to the top always, so the header never moves.
        let content = FlippedView()
        content.translatesAutoresizingMaskIntoConstraints = false

        let header = buildHeader()
        buildStatsRow()
        let loadingSection = buildLoadingState()
        let githubSection = buildSection(header: githubHeader, subtitle: githubSubtitle, countLabel: githubCountLabel,
                                         iconSymbol: "chevron.left.forwardslash.chevron.right",
                                         title: "GitHub", stack: githubStack)
        let bitbucketSection = buildSection(header: bitbucketHeader, subtitle: bitbucketSubtitle, countLabel: bitbucketCountLabel,
                                            iconSymbol: "water.waves", title: "Bitbucket", stack: bitbucketStack)
        otherSection = buildSection(header: otherHeader, subtitle: otherSubtitle, countLabel: otherCountLabel,
                                    iconSymbol: "arrow.triangle.branch", title: "Other", stack: otherStack)
        githubSectionView = githubSection
        bitbucketSectionView = bitbucketSection

        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = 20
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        contentStack.addArrangedSubview(header)
        contentStack.addArrangedSubview(loadingSection)
        contentStack.addArrangedSubview(statsRow)
        contentStack.addArrangedSubview(githubSection)
        contentStack.addArrangedSubview(bitbucketSection)
        contentStack.addArrangedSubview(otherSection)

        // The stats row and three forge sections stay hidden behind the
        // loading skeleton until the first successful `render(...)` - see
        // `buildLoadingState`.
        statsRow.isHidden = true
        githubSection.isHidden = true
        bitbucketSection.isHidden = true
        otherSection.isHidden = true

        content.addSubview(contentStack)
        NSLayoutConstraint.activate([
            contentStack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: HelmMetrics.pageGutter),
            contentStack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -HelmMetrics.pageGutter),
            contentStack.topAnchor.constraint(equalTo: content.topAnchor, constant: 24),
            contentStack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -28),
            headerRow.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
            loadingSection.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
            statsRow.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
            githubSection.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
            bitbucketSection.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
            otherSection.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
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
            root?.appearance = NSAppearance(named: theme.mode == .dark ? .darkAqua : .aqua)
            self?.applyTheme()
        }
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        // cockpit-native-fixes5: force the pending Auto Layout pass before
        // touching scroll position - see FleetController.viewWillAppear's
        // matching comment for why this matters specifically on the very
        // first appearance (isHidden was true, so this view was never laid
        // out until right now, in the same tick as this call).
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
        heroLabel.font = HelmType.pageTitle(.serif)
        heroLabel.translatesAutoresizingMaskIntoConstraints = false

        subtitleLabel.font = HelmType.body()
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false

        refreshButton.target = self
        refreshButton.action = #selector(refreshTapped)
        refreshButton.toolTip = "Refresh open PRs"
        refreshButton.setContentHuggingPriority(.required, for: .horizontal)
        refreshButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        refreshButton.translatesAutoresizingMaskIntoConstraints = false

        let textStack = NSStackView(views: [heroLabel, subtitleLabel])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 4
        textStack.translatesAutoresizingMaskIntoConstraints = false
        textStack.setHuggingPriority(.defaultLow, for: .horizontal)

        // `.fill` plus a flexible spacer, so Refresh sits at the page's own
        // trailing edge (prototype `.phead .row`) instead of hugging the
        // hero text. See AGENTS.md gotcha (10)/(12): a nested stack has no
        // intrinsic size, so the spacer - not the text stack - is what
        // carries the low hugging priority the distribution actually
        // stretches.
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

    private func buildStatsRow() {
        statsRow.orientation = .horizontal
        statsRow.distribution = .fillEqually
        statsRow.spacing = 10
        statsRow.translatesAutoresizingMaskIntoConstraints = false
    }

    /// A skeleton that occupies the content area under the header from the
    /// very first frame - the GitHub/Bitbucket/Other sections stay hidden
    /// (and animation-free) until the first `render(...)` lands, so there is
    /// never an interval where the page shows nothing but a collapsed,
    /// empty-looking stack of cards while `refresh()`'s background fetch
    /// (real `gh`/Bitbucket network calls) is in flight.
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

    /// One `HelmStatTile` - the app's shared stat tile. Mirrors
    /// `FleetController.statTile` exactly: the tile themes itself, this only
    /// tracks the live instance so a theme change can reach it.
    private func statTile(icon: String, value: String, label: String, tint: HelmTint? = nil) -> NSView {
        let tile = HelmStatTile(symbol: icon, value: value, caption: label, tint: tint)
        statTiles.append(tile)
        return tile
    }

    /// One `HelmCard` per section - the shared container from
    /// `HelmDesignSystem.swift`. The caller keeps its own title/subtitle
    /// labels, since neither's text is fixed at build time: the title never
    /// changes per render now that the live count moved into its own neutral
    /// badge (the prototype's `.count` span) rather than being baked into the
    /// title string, and the subtitle (the prototype's account/org name
    /// under "GitHub") is only known once the first PR in that forge has
    /// actually loaded - see `render`'s `subtitle(for:)` call.
    private func buildSection(header: NSTextField, subtitle: NSTextField, countLabel: NSTextField, iconSymbol: String, title: String, stack: NSStackView) -> HelmCard {
        header.stringValue = title
        subtitle.stringValue = ""
        subtitle.isHidden = true

        countLabel.font = HelmType.metric(11, weight: .medium)
        countLabel.translatesAutoresizingMaskIntoConstraints = false

        let badge = NSView()
        badge.wantsLayer = true
        badge.layer?.cornerRadius = 5
        badge.translatesAutoresizingMaskIntoConstraints = false
        badge.addSubview(countLabel)
        NSLayoutConstraint.activate([
            countLabel.leadingAnchor.constraint(equalTo: badge.leadingAnchor, constant: 6),
            countLabel.trailingAnchor.constraint(equalTo: badge.trailingAnchor, constant: -6),
            countLabel.topAnchor.constraint(equalTo: badge.topAnchor, constant: 1),
            countLabel.bottomAnchor.constraint(equalTo: badge.bottomAnchor, constant: -1),
        ])
        countBadges.append((container: badge, label: countLabel))

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false

        let card = HelmCard()
        card.setHeader(symbol: iconSymbol, titleLabel: header, subtitleLabel: subtitle, actions: [badge])
        card.setBody(stack, insets: HelmCard.contentInsets)
        cards.append(card)
        return card
    }

    // MARK: Refresh

    @objc private func refreshTapped() { refresh() }

    /// fm/grandline-sidebar-badges: lets `AppShellController` trigger this
    /// page's own existing refresh at app launch, so the rail's Review badge
    /// has a real count before the captain ever visits this destination -
    /// not a new poll loop, just an earlier call to the one that already
    /// exists (also fired again by every `viewWillAppear` visit and the
    /// manual refresh button, unchanged).
    func refreshIfNeeded() { refresh() }

    private func refresh() {
        guard !isLoading else { return }
        isLoading = true
        refreshButton.isEnabled = false
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let tasks = FleetDataSource.parseTasks()
            let openPRs = OpenPRsSource.fetch()
            let merged = FleetDataSource.mergedPRs(openPRs: openPRs, tasks: tasks)
            DispatchQueue.main.async {
                guard let self else { return }
                self.isLoading = false
                self.refreshButton.isEnabled = true
                self.render(merged)
            }
        }
    }

    // MARK: Rendering

    private func render(_ prs: [MergedPR]) {
        if !hasLoadedOnce {
            hasLoadedOnce = true
            loadingSpinner.stopAnimation(nil)
            loadingContainer.isHidden = true
            statsRow.isHidden = false
            githubSectionView.isHidden = false
            bitbucketSectionView.isHidden = false
        }

        onOpenPRCountChanged?(prs.count)

        let sorted = prs.sorted { ($0.repo, $0.number ?? 0) < ($1.repo, $1.number ?? 0) }
        let github = sorted.filter { $0.forge == "github" }
        let bitbucket = sorted.filter { $0.forge == "bitbucket" }
        let other = sorted.filter { $0.forge != "github" && $0.forge != "bitbucket" }

        if prs.isEmpty {
            subtitleLabel.stringValue = "No open pull requests right now"
        } else {
            let forgesRepresented = [github, bitbucket, other].filter { !$0.isEmpty }.count
            subtitleLabel.stringValue = "\(prs.count) open pull request\(prs.count == 1 ? "" : "s") "
                + "across \(forgesRepresented) forge\(forgesRepresented == 1 ? "" : "s")"
        }

        rebuildStats(prs)

        rebuildRows(into: githubStack, prs: github)
        githubCountLabel.stringValue = "\(github.count)"
        applyAccountSubtitle(githubSubtitle, prs: github)
        rebuildRows(into: bitbucketStack, prs: bitbucket)
        bitbucketCountLabel.stringValue = "\(bitbucket.count)"
        applyAccountSubtitle(bitbucketSubtitle, prs: bitbucket)
        otherSection.isHidden = other.isEmpty
        if !other.isEmpty {
            rebuildRows(into: otherStack, prs: other)
            otherCountLabel.stringValue = "\(other.count)"
            applyAccountSubtitle(otherSubtitle, prs: other)
        }

        applyTheme()

        // cockpit-native-fixes5: the loading skeleton's content is much
        // shorter than the real data, so the first successful render() here
        // can grow the document's height substantially while the view is
        // already visible - re-pin the scroll position defensively, matching
        // FleetController.render's identical fix.
        view.layoutSubtreeIfNeeded()
        scrollToTop()
    }

    /// The three headline numbers: open PRs (accent - every PR here is one
    /// the captain has waiting on them), ready to merge (good - checks have
    /// passed) and checks running (warn) - the same `checks` state each row's
    /// own chip already reads, just totalled. A tint only ever means "this
    /// number is itself a signal" (`FleetController.rebuildStats`'s rule):
    /// the open-PR count and the two status counts qualify, so all three are
    /// tinted here, unlike a page mixing signal and plain counts.
    private func rebuildStats(_ prs: [MergedPR]) {
        for v in statsRow.arrangedSubviews {
            statsRow.removeArrangedSubview(v)
            v.removeFromSuperview()
        }
        statTiles.removeAll()

        let ready = prs.filter { $0.checks == "green" }.count
        let running = prs.filter { $0.checks == "pending" }.count

        statsRow.addArrangedSubview(statTile(icon: "arrow.triangle.branch", value: "\(prs.count)", label: "open PRs", tint: .accent))
        statsRow.addArrangedSubview(statTile(icon: "checkmark.circle", value: "\(ready)", label: "ready to merge", tint: .good))
        statsRow.addArrangedSubview(statTile(icon: "clock", value: "\(running)", label: "checks running", tint: .warn))
    }

    private func rebuildRows(into stack: NSStackView, prs: [MergedPR]) {
        for v in stack.arrangedSubviews {
            stack.removeArrangedSubview(v)
            v.removeFromSuperview()
        }
        if prs.isEmpty {
            stack.addArrangedSubview(emptyStateView(title: "No open PRs here", body: "This forge has nothing waiting on you right now."))
            return
        }
        for pr in prs {
            let row = prRowView(pr)
            stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
    }

    /// One `HelmEmptyState` - the app's shared empty state
    /// (`HelmDesignSystem.swift`, audit §6.3 component 5). This page's own copy
    /// was the odd one out among the six the audit found: **left-aligned, with
    /// no icon at all**, on a radius-9 container, while every other list in the
    /// app centred an icon over its copy. Since this page shows the same PR
    /// domain Overview summarises, it now renders identically to Overview's
    /// (§6.4: "share Overview's section chrome and empty-state treatment").
    private func emptyStateView(title: String, body: String) -> NSView {
        let empty = HelmEmptyState(symbol: "checkmark.seal", title: title, body: body,
                                   size: .standard, boxed: true)
        emptyStates.append(empty)
        return empty
    }

    /// Rebuilt with the forge sections on every render; each state themes
    /// itself, so this only exists to reach the live ones from `applyTheme`.
    private var emptyStates: [HelmEmptyState] = []

    /// One `HelmAccentRow` per PR - the app's shared accent-bar card
    /// (`HelmDesignSystem.swift`, audit §6.3 component 2), coloured and
    /// chipped from the PR's own `checks` state (`checksVisuals` below) -
    /// replacing this page's own hand-rolled tinted pill row, which only ever
    /// coloured a "no checks" label and left every row the same flat grey
    /// otherwise. `chipPlacement: .belowBody` puts the status chip under the
    /// title (the prototype's `.col` div), and Review/Merge live in
    /// `trailingAccessory` - the identical actions Overview's "Ready to
    /// merge" list already wired up (`reviewPR`/`mergePR` below mirror
    /// `FleetController`'s one-for-one), just relocated onto the shared row.
    private func prRowView(_ pr: MergedPR) -> NSView {
        let visuals = checksVisuals(pr.checks)

        var kickerParts: [String] = []
        if !pr.repo.isEmpty { kickerParts.append(pr.repo) }
        kickerParts.append(pr.number != nil ? "PR #\(pr.number!)" : "PR")
        let heading = pr.title.isEmpty ? (pr.number != nil ? "PR #\(pr.number!)" : "PR") : pr.title

        let reviewButton = HelmButton(title: "Review", variant: .secondary, size: .small, target: self, action: #selector(reviewPR(_:)))
        reviewButton.identifier = NSUserInterfaceItemIdentifier(pr.url)

        // Merge only ever shows for a PR that is both (a) genuinely ready -
        // `checks == "green"`, the same definition `rebuildStats`'s "ready to
        // merge" tile already uses, so a PR with checks still running or
        // failing never gets a Merge button, just its status chip - and (b)
        // actually mergeable through this action at all: `fm-pr-merge.sh`
        // takes `<task-id> <pr-url>` and validates the task id, so a PR the
        // forge scan found with no tracked task behind it (`pr.taskID ==
        // nil`) has no working merge path here regardless of its checks
        // state. Before this fix the gate was only (b) - a task-tracked PR
        // showed Merge even while its checks were still pending, which is
        // the "checks running but Merge is offered anyway" bug this page's
        // redesign didn't catch since it never combined the two.
        var trailing: [NSView] = [reviewButton]
        if pr.checks == "green", let taskID = pr.taskID {
            let mergeButton = HelmButton(title: "Merge", variant: .primary, size: .small, target: self, action: #selector(mergePR(_:)))
            mergeButton.identifier = NSUserInterfaceItemIdentifier("\(taskID)\u{0}\(pr.url)")
            trailing.append(mergeButton)
        }
        let actionsRow = NSStackView(views: trailing)
        actionsRow.orientation = .horizontal
        actionsRow.spacing = 6

        let row = HelmAccentRow(chipPlacement: .belowBody, trailingAccessory: actionsRow, hover: false)
        row.configure(HelmAccentRow.Content(
            tint: visuals.tint,
            kicker: kickerParts.joined(separator: " \u{00B7} "),
            title: heading,
            badgeSymbol: "arrow.triangle.pull",
            chipText: visuals.chipLabel
        ), theme: theme)
        accentRows.append(row)
        return row
    }

    /// Live `HelmAccentRow`s, so a theme change re-tints them. They are
    /// rebuilt on every `render()`, so this is cleared alongside the stacks.
    private var accentRows: [HelmAccentRow] = []

    /// The prototype's forge-card subtitle (`manjesh-raj` under "GitHub") -
    /// the account/org the PRs in that section actually belong to, derived
    /// from a real PR's own already-fetched `url` rather than a hardcoded
    /// name. Hidden (not left blank) when the section is empty or no PR's
    /// URL parses, matching this page's existing "hide, don't show empty
    /// chrome" convention for the "Other" section above.
    private func applyAccountSubtitle(_ label: NSTextField, prs: [MergedPR]) {
        guard let account = prs.compactMap({ accountName(from: $0.url) }).first else {
            label.isHidden = true
            label.stringValue = ""
            return
        }
        label.stringValue = account
        label.isHidden = false
    }

    /// Pulls the account/org/workspace segment out of a PR's own URL -
    /// `github.com/<account>/<repo>/pull/<n>` or
    /// `bitbucket.org/<account>/<repo>/pull-requests/<n>` both put it as the
    /// first path component right after the host.
    private func accountName(from urlString: String) -> String? {
        guard let url = URL(string: urlString) else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }
        return parts.first
    }

    /// Maps a PR's real `checks` state (green / red / pending / none) to the
    /// row's tint and chip text. `.good` reads "Ready to merge" rather than
    /// merely "checks pass" because that is the state a captain can actually
    /// act on - green checks with no other blocker is what this page treats
    /// as ready, matching `rebuildStats`'s identical definition.
    private func checksVisuals(_ checks: String) -> (tint: HelmTint, chipLabel: String) {
        switch checks {
        case "green": return (.good, "Ready to merge")
        case "red": return (.critical, "Checks failing")
        case "pending": return (.warn, "Checks running")
        default: return (.neutral, "No checks")
        }
    }

    // MARK: Actions (identical to `FleetController.reviewPR`/`mergePR`)

    @objc private func reviewPR(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue, let url = URL(string: raw) else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func mergePR(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue else { return }
        let parts = raw.components(separatedBy: "\u{0}")
        guard parts.count == 2 else { return }
        let prURL = parts[1]

        let alert = NSAlert()
        alert.messageText = "Merge this PR?"
        alert.informativeText = prURL
        alert.addButton(withTitle: "Merge")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .informational
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        sender.isEnabled = false
        sender.title = "Merging\u{2026}"
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = FleetDataSource.mergePR(url: prURL)
            DispatchQueue.main.async {
                if result.ok {
                    self?.refresh()
                } else {
                    sender.isEnabled = true
                    sender.title = "Merge"
                    let failAlert = NSAlert()
                    failAlert.messageText = "Merge failed"
                    failAlert.informativeText = result.message
                    failAlert.alertStyle = .warning
                    failAlert.runModal()
                }
            }
        }
    }

    // MARK: Theme

    private func applyTheme() {
        view.layer?.backgroundColor = HelmTheme.nsColor(theme.backgroundHex).cgColor
        for card in cards { card.applyTheme(theme) }
        let ink = HelmTheme.nsColor(theme.chromeInkHex)
        let surface = HelmTheme.nsColor(theme.chromeBackgroundHex)
        let line = HelmTheme.nsColor(theme.chromeLineHex)
        let muted = HelmTheme.mutedInk(theme)

        heroLabel.textColor = ink
        subtitleLabel.textColor = muted
        // `refreshButton` is a `HelmButton` and themes itself - never set
        // `contentTintColor` on one, `restyle()` owns that property.

        loadingContainer.layer?.backgroundColor = surface.cgColor
        loadingContainer.layer?.borderWidth = 1
        loadingContainer.layer?.borderColor = line.withAlphaComponent(0.4).cgColor
        loadingLabel.textColor = muted

        for tile in statTiles { tile.applyTheme(theme) }
        for row in accentRows { row.applyTheme(theme) }
        for empty in emptyStates { empty.applyTheme(theme) }
        for (container, label) in countBadges {
            container.layer?.backgroundColor = ink.withAlphaComponent(0.08).cgColor
            label.textColor = muted
        }
    }
}
