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

import AppKit

final class ReviewController: NSViewController {

    private let scroll = NSScrollView()
    private let contentStack = NSStackView()

    private let titleLabel = NSTextField(labelWithString: "Review")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let refreshButton = NSButton()

    private let githubHeader = NSTextField(labelWithString: "")
    private let githubStack = NSStackView()
    private let bitbucketHeader = NSTextField(labelWithString: "")
    private let bitbucketStack = NSStackView()
    private let otherHeader = NSTextField(labelWithString: "")
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
        let loadingSection = buildLoadingState()
        let githubSection = buildSection(header: githubHeader, iconSymbol: "chevron.left.forwardslash.chevron.right", title: "GitHub", stack: githubStack)
        let bitbucketSection = buildSection(header: bitbucketHeader, iconSymbol: "water.waves", title: "Bitbucket", stack: bitbucketStack)
        otherSection = buildSection(header: otherHeader, iconSymbol: "arrow.triangle.branch", title: "Other", stack: otherStack)
        githubSectionView = githubSection
        bitbucketSectionView = bitbucketSection

        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = 22
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        contentStack.addArrangedSubview(header)
        contentStack.addArrangedSubview(loadingSection)
        contentStack.addArrangedSubview(githubSection)
        contentStack.addArrangedSubview(bitbucketSection)
        contentStack.addArrangedSubview(otherSection)

        // The three forge sections stay hidden behind the loading skeleton
        // until the first successful `render(...)` - see `buildLoadingState`.
        githubSection.isHidden = true
        bitbucketSection.isHidden = true
        otherSection.isHidden = true

        content.addSubview(contentStack)
        NSLayoutConstraint.activate([
            contentStack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: HelmMetrics.pageGutter),
            contentStack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -HelmMetrics.pageGutter),
            contentStack.topAnchor.constraint(equalTo: content.topAnchor, constant: 24),
            contentStack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -28),
            loadingSection.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
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
        titleLabel.font = HelmType.pageTitle()
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        subtitleLabel.font = .systemFont(ofSize: 12)
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false

        refreshButton.title = ""
        refreshButton.isBordered = false
        refreshButton.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "Refresh")
        refreshButton.target = self
        refreshButton.action = #selector(refreshTapped)
        refreshButton.toolTip = "Refresh open PRs"
        refreshButton.translatesAutoresizingMaskIntoConstraints = false

        let textStack = NSStackView(views: [titleLabel, subtitleLabel])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 4

        let row = NSStackView(views: [textStack, refreshButton])
        row.orientation = .horizontal
        row.spacing = 12
        row.translatesAutoresizingMaskIntoConstraints = false
        return row
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

    /// One `HelmCard` per section - the shared container from
    /// `HelmDesignSystem.swift`. This used to be a bare header-row-over-stack
    /// with no chrome at all, near-identical to `FleetController`'s copy and
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
            githubSectionView.isHidden = false
            bitbucketSectionView.isHidden = false
        }

        rowContainers.removeAll()
        emptyStateParts.removeAll()

        onOpenPRCountChanged?(prs.count)

        let sorted = prs.sorted { ($0.repo, $0.number ?? 0) < ($1.repo, $1.number ?? 0) }
        let github = sorted.filter { $0.forge == "github" }
        let bitbucket = sorted.filter { $0.forge == "bitbucket" }
        let other = sorted.filter { $0.forge != "github" && $0.forge != "bitbucket" }

        subtitleLabel.stringValue = "\(prs.count) open pull request\(prs.count == 1 ? "" : "s") across your projects"

        rebuildRows(into: githubStack, prs: github)
        githubHeader.stringValue = "GitHub (\(github.count))"
        rebuildRows(into: bitbucketStack, prs: bitbucket)
        bitbucketHeader.stringValue = "Bitbucket (\(bitbucket.count))"
        otherSection.isHidden = other.isEmpty
        if !other.isEmpty {
            rebuildRows(into: otherStack, prs: other)
            otherHeader.stringValue = "Other (\(other.count))"
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

    private func emptyStateView(title: String, body: String) -> NSView {
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 12, weight: .medium)
        let bodyLabel = NSTextField(labelWithString: body)
        bodyLabel.font = .systemFont(ofSize: 11)
        let stack = NSStackView(views: [titleLabel, bodyLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.wantsLayer = true
        container.layer?.cornerRadius = 9
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 10),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -10),
        ])
        emptyStateParts.append((container, titleLabel, bodyLabel))
        return container
    }

    private var emptyStateParts: [(NSView, NSTextField, NSTextField)] = []

    /// One compact row: title, "repo · PR #N" subtitle, a checks pill, and
    /// Review (always) + Merge (only for a task-tracked PR) - the identical
    /// actions Overview's "Ready to merge" list already wires up
    /// (`reviewPR`/`mergePR` below mirror `FleetController`'s one-for-one).
    private func prRowView(_ pr: MergedPR) -> NSView {
        let iconView = NSImageView()
        iconView.image = NSImage(systemSymbolName: "arrow.triangle.pull", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 14, weight: .medium))
        iconView.contentTintColor = HelmTheme.nsColor(theme.accentHex)
        iconView.translatesAutoresizingMaskIntoConstraints = false

        let heading = pr.title.isEmpty ? (pr.number != nil ? "PR #\(pr.number!)" : "PR") : pr.title
        let titleLabel = NSTextField(labelWithString: heading)
        titleLabel.font = .systemFont(ofSize: 12.5, weight: .medium)
        titleLabel.lineBreakMode = .byTruncatingTail

        var subBits: [String] = []
        if !pr.repo.isEmpty { subBits.append(pr.repo) }
        subBits.append(pr.number != nil ? "PR #\(pr.number!)" : "PR")
        let subLabel = NSTextField(labelWithString: subBits.joined(separator: " \u{00B7} "))
        subLabel.font = .systemFont(ofSize: 10.5)
        subLabel.textColor = HelmTheme.mutedInk(theme)
        subLabel.lineBreakMode = .byTruncatingTail

        let textStack = NSStackView(views: [titleLabel, subLabel])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 2
        textStack.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let (checksLabel, checksColorHex) = checksVisuals(pr.checks)
        let checksPill = pillLabelView(text: checksLabel, colorHex: checksColorHex)

        let reviewButton = HelmButton(title: "Review", variant: .secondary, target: self, action: #selector(reviewPR(_:)))
        reviewButton.identifier = NSUserInterfaceItemIdentifier(pr.url)

        var trailing: [NSView] = [checksPill, reviewButton]
        if pr.source == "work", let taskID = pr.taskID {
            let mergeButton = HelmButton(title: "Merge", variant: .primary, target: self, action: #selector(mergePR(_:)))
            mergeButton.identifier = NSUserInterfaceItemIdentifier("\(taskID)\u{0}\(pr.url)")
            trailing.append(mergeButton)
        }

        let row = NSStackView(views: [iconView, textStack] + trailing)
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        row.translatesAutoresizingMaskIntoConstraints = false
        for t in trailing { t.setContentHuggingPriority(.required, for: .horizontal) }

        return wrapRow(row, minHeight: 40)
    }

    private func checksVisuals(_ checks: String) -> (label: String, colorHex: String) {
        switch checks {
        case "green": return ("checks pass", theme.ansiHex[2])
        case "red": return ("checks failing", theme.ansiHex[1])
        case "pending": return ("checks running", theme.ansiHex[3])
        default: return ("no checks", theme.chromeInkHex)
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
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
            label.topAnchor.constraint(equalTo: container.topAnchor, constant: 3),
            label.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -3),
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
            row.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            row.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            row.topAnchor.constraint(equalTo: container.topAnchor, constant: 7),
            row.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -7),
            container.heightAnchor.constraint(greaterThanOrEqualToConstant: minHeight),
        ])
        rowContainers.append(container)
        return container
    }

    private var rowContainers: [NSView] = []

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

        titleLabel.textColor = ink
        subtitleLabel.textColor = muted
        refreshButton.contentTintColor = ink.withAlphaComponent(0.7)

        loadingContainer.layer?.backgroundColor = surface.cgColor
        loadingContainer.layer?.borderWidth = 1
        loadingContainer.layer?.borderColor = line.withAlphaComponent(0.4).cgColor
        loadingLabel.textColor = muted

        for (container, titleLabel, bodyLabel) in emptyStateParts {
            container.layer?.backgroundColor = surface.cgColor
            container.layer?.borderWidth = 1
            container.layer?.borderColor = line.withAlphaComponent(0.4).cgColor
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
