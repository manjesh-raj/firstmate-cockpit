// Manjesh Grand Line - native macOS app.
//
// "GitHub Sync" - a new `.githubSync` rail destination, reachable only via the
// Setup flyout's fourth row (alongside Updates, Bootstrap, Automation - see
// `IconRailController.showSetupFlyout()`). Pulls the latest upstream changes
// into each of the captain's personal forks from inside the app, rather than
// by hand per repo (`git fetch upstream && git merge` per clone).
//
// Visual/interaction pattern copied deliberately, not invented:
//   - Page shape (subtitle + a "sync all" action card + a repo-list card, both
//     built with the same rounded `card(icon:title:content:)` chrome, inside
//     a `FlippedView` + `NSScrollView` for the "empty gap above the header"
//     fix): `AutomationController.swift:179-241` (`loadView`) and its `card`
//     helper at `AutomationController.swift:258-296`.
//   - Per-repo row: `ToolRowLayout` (`HelmUIComponents.swift:176-408`), the
//     exact shared "icon tile + name/detail text + trailing pill/buttons +
//     expandable command-output log" assembly `UpdatesController`'s per-tool
//     rows already use (`UpdatesController.swift:643-692` builds a row;
//     `UpdatesController.swift:715-740`/`778-805` is the check/update
//     busy-state and re-check-after-action pattern this file's `check(_:)`/
//     `sync(_:)` mirror for check/sync instead).
//   - "Sync all" progress reporting: `UpdatesController.checkAll()`
//     (`UpdatesController.swift:389-428`) - a running "N/M" count while a
//     bulk action is in flight, then a `Toast` summary on completion.
//
// Every actual GitHub operation goes through `GitHubSyncSource`
// (`GitHubSyncData.swift`) - this file only renders state and dispatches
// background-queue calls, exactly like `UpdatesController`/`FleetController`.

import AppKit

private final class GitHubSyncRow {
    let repo: GitHubSyncRepoConfig
    var status: GitHubSyncStatus = .unknown
    var upstreamFullName: String?
    var detail: String = "Not checked yet"
    var log: String = ""
    var isLogExpanded = false
    /// True while either a check or a sync is running for this row - guards
    /// against double-firing the same row from two places (a row's own
    /// button and "Sync all" running concurrently).
    var isBusy = false

    let iconTile = IconTileView()
    let nameLabel = NSTextField(labelWithString: "")
    let detailLabel = NSTextField(labelWithString: "")
    let pill = NSView()
    let pillLabel = NSTextField(labelWithString: "")
    let spinner = NSProgressIndicator()
    let progressLabel = NSTextField(labelWithString: "")
    let syncButton = HelmButton(title: "", variant: .secondary)
    let detailsButton = NSButton()
    let logField = NSTextField(wrappingLabelWithString: "")
    let logContainer = NSView()
    let rowContainer = HoverHighlightView()
    let trailingStack = NSStackView()

    var toolRowViews: ToolRowLayout.Views {
        ToolRowLayout.Views(
            iconTile: iconTile, nameLabel: nameLabel, detailLabel: detailLabel,
            pill: pill, pillLabel: pillLabel, trailingStack: trailingStack,
            detailsButton: detailsButton, logField: logField, logContainer: logContainer,
            rowContainer: rowContainer
        )
    }

    init(repo: GitHubSyncRepoConfig) { self.repo = repo }
}

final class GitHubSyncController: NSViewController {

    private var rows: [GitHubSyncRow] = GitHubSyncCatalog.repos.map(GitHubSyncRow.init)
    private var theme: HelmTheme = ThemeManager.shared.theme
    private var scrollView: NSScrollView!
    private var cards: [HelmCard] = []
    private var separators: [NSView] = []
    private var hasCheckedOnce = false
    private var isSyncingAll = false

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

        let subtitle = NSTextField(wrappingLabelWithString: "Pulls the latest upstream changes into each of your personal forks - fast-forward only, via \u{201c}gh repo sync\u{201d} for a real GitHub fork, or a small local scratch clone for a repo with a manually declared upstream. A repo with commits of its own that upstream doesn\u{2019}t have is left untouched, never force-synced.")
        subtitle.font = .systemFont(ofSize: 12)
        subtitle.preferredMaxLayoutWidth = 560
        subtitle.translatesAutoresizingMaskIntoConstraints = false

        let syncAllCard = card(icon: "arrow.2.squarepath", title: "Sync All", content: buildSyncAllSection())

        var rowViews: [NSView] = []
        for (index, row) in rows.enumerated() {
            rowViews.append(buildRow(row))
            if index < rows.count - 1 {
                rowViews.append(separator())
            }
        }
        let rowsStack = NSStackView(views: rowViews)
        rowsStack.orientation = .vertical
        rowsStack.alignment = .leading
        rowsStack.spacing = 10
        rowsStack.translatesAutoresizingMaskIntoConstraints = false
        for v in rowViews { v.widthAnchor.constraint(equalTo: rowsStack.widthAnchor).isActive = true }

        let reposCard = card(icon: "point.3.connected.trianglepath.dotted", title: "Repos (\(rows.count))", content: rowsStack)

        let stack = NSStackView(views: [subtitle, syncAllCard, reposCard])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.setCustomSpacing(16, after: subtitle)

        let content = FlippedView()
        content.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: HelmMetrics.pageGutter),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -HelmMetrics.pageGutter),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 18),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
            subtitle.widthAnchor.constraint(equalTo: stack.widthAnchor),
            syncAllCard.widthAnchor.constraint(equalTo: stack.widthAnchor),
            reposCard.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])

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
        applyTheme()
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        view.layoutSubtreeIfNeeded()
        scrollToTop()
        if !hasCheckedOnce {
            hasCheckedOnce = true
            checkAll()
        }
    }

    private func scrollToTop() {
        guard let scrollView else { return }
        scrollView.contentView.scroll(to: .zero)
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    // MARK: Card chrome

    /// One `HelmCard` per page section - the shared container from
    /// `HelmDesignSystem.swift`, replacing this file's own copy of a helper
    /// that was byte-for-byte identical in four controllers (audit §3.2).
    private func card(icon: String, title: String, content: NSView) -> HelmCard {
        let card = HelmCard()
        card.setHeader(symbol: icon, title: title)
        card.setBody(content, insets: HelmCard.contentInsets)
        cards.append(card)
        return card
    }

    private func separator() -> NSView {
        let v = NSView()
        v.wantsLayer = true
        v.heightAnchor.constraint(equalToConstant: 1).isActive = true
        separators.append(v)
        return v
    }

    // MARK: Sync All

    private let syncAllButton = HelmButton(title: "", variant: .primary)
    private let syncAllSummaryLabel = NSTextField(wrappingLabelWithString: "")

    private func buildSyncAllSection() -> NSView {
        syncAllButton.title = "Sync All"
        syncAllButton.target = self
        syncAllButton.action = #selector(syncAllTapped)
        syncAllButton.setContentHuggingPriority(.required, for: .horizontal)

        syncAllSummaryLabel.font = .systemFont(ofSize: 11.5)
        syncAllSummaryLabel.preferredMaxLayoutWidth = 500

        let section = NSStackView(views: [syncAllButton, syncAllSummaryLabel])
        section.orientation = .vertical
        section.alignment = .leading
        section.spacing = 8
        syncAllSummaryLabel.widthAnchor.constraint(equalTo: section.widthAnchor).isActive = true
        return section
    }

    @objc private func syncAllTapped() { syncAll() }

    /// Syncs every repo currently showing "behind upstream" - skips a repo
    /// already in sync (nothing to do) and skips (never touches) a diverged
    /// repo, reporting it distinctly rather than silently doing nothing.
    /// Runs one at a time, matching `AutomationController.installAllMissing`'s
    /// own "never race two external-tool invocations concurrently" reasoning.
    private func syncAll() {
        guard !isSyncingAll else { return }
        isSyncingAll = true
        syncAllButton.isEnabled = false
        let targets = rows.filter { $0.status.showsSyncButton }
        guard !targets.isEmpty else {
            isSyncingAll = false
            syncAllButton.isEnabled = true
            syncAllSummaryLabel.stringValue = "Nothing behind upstream right now."
            return
        }
        var synced = 0
        var alreadyInSync = 0
        var refused: [String] = []
        var failed: [String] = []
        func runNext(_ index: Int) {
            guard index < targets.count else {
                isSyncingAll = false
                syncAllButton.isEnabled = true
                var parts: [String] = []
                if synced > 0 { parts.append("\(synced) synced") }
                if alreadyInSync > 0 { parts.append("\(alreadyInSync) already in sync") }
                if !refused.isEmpty { parts.append("\(refused.count) diverged (left untouched)") }
                if !failed.isEmpty { parts.append("\(failed.count) failed") }
                syncAllSummaryLabel.stringValue = parts.isEmpty ? "Nothing to sync." : parts.joined(separator: ", ")
                if let container = view.window?.contentView {
                    Toast.show(in: container, message: "GitHub Sync: \(syncAllSummaryLabel.stringValue)")
                }
                return
            }
            let row = targets[index]
            syncAllSummaryLabel.stringValue = "Syncing \(row.repo.fullName)\u{2026} (\(index + 1)/\(targets.count))"
            sync(row) { ok in
                if ok {
                    if row.status == .inSync { alreadyInSync += 1 } else { synced += 1 }
                } else if row.status.isDiverged {
                    refused.append(row.repo.fullName)
                } else {
                    failed.append(row.repo.fullName)
                }
                runNext(index + 1)
            }
        }
        runNext(0)
    }

    // MARK: Row building

    private func buildRow(_ row: GitHubSyncRow) -> NSView {
        row.syncButton.title = "Sync now"
        row.syncButton.controlSize = .small
        row.syncButton.target = self
        row.syncButton.action = #selector(syncTapped(_:))
        row.syncButton.identifier = NSUserInterfaceItemIdentifier(row.repo.fullName)

        row.spinner.style = .spinning
        row.spinner.controlSize = .small
        row.spinner.isIndeterminate = true
        row.spinner.translatesAutoresizingMaskIntoConstraints = false
        row.progressLabel.font = .systemFont(ofSize: 11, weight: .medium)

        let view = ToolRowLayout.build(
            row.toolRowViews,
            iconSymbol: "point.3.connected.trianglepath.dotted",
            tint: .neutral,
            name: row.repo.fullName,
            trailingViews: [row.pill, row.syncButton, row.spinner, row.progressLabel],
            detailsTarget: self,
            detailsAction: #selector(detailsTapped(_:)),
            identifier: row.repo.fullName
        )
        row.logContainer.isHidden = true
        return view
    }

    @objc private func detailsTapped(_ sender: NSButton) {
        guard let row = row(for: sender) else { return }
        row.isLogExpanded.toggle()
        ToolRowLayout.setLogExpanded(row.toolRowViews, expanded: row.isLogExpanded, log: row.log)
    }

    private func row(for sender: NSButton) -> GitHubSyncRow? {
        guard let raw = sender.identifier?.rawValue else { return nil }
        return rows.first { $0.repo.fullName == raw }
    }

    // MARK: Check

    private func checkAll() {
        for row in rows { check(row) }
    }

    private func check(_ row: GitHubSyncRow, completion: (() -> Void)? = nil) {
        guard !row.isBusy else {
            completion?()
            return
        }
        row.isBusy = true
        row.status = .checking
        row.detail = "Checking\u{2026}"
        render(row)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let outcome = GitHubSyncSource.check(row.repo)
            DispatchQueue.main.async {
                guard self != nil else {
                    completion?()
                    return
                }
                row.isBusy = false
                row.status = outcome.status
                row.upstreamFullName = outcome.upstreamFullName
                row.detail = outcome.detail
                row.log = outcome.log
                self?.render(row)
                completion?()
            }
        }
    }

    @objc private func syncTapped(_ sender: NSButton) {
        guard let row = row(for: sender) else { return }
        sync(row)
    }

    // MARK: Sync

    /// `completion(ok)` fires on the main queue once this row's sync settles;
    /// `syncAll()` uses it to sequence one repo at a time. A real Check runs
    /// right after a successful sync so the row's status reflects the fork's
    /// true, live state rather than the sync command's own self-report -
    /// mirrors `UpdatesController.update(_:)`'s identical "Check is the
    /// source of truth" contract.
    private func sync(_ row: GitHubSyncRow, completion: ((Bool) -> Void)? = nil) {
        guard !row.isBusy else {
            completion?(false)
            return
        }
        row.isBusy = true
        row.status = .syncing
        render(row)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let outcome = GitHubSyncSource.sync(row.repo)
            DispatchQueue.main.async {
                guard let self else {
                    completion?(false)
                    return
                }
                row.isBusy = false
                row.log = outcome.log
                if outcome.ok {
                    row.detail = outcome.detail
                    self.render(row)
                    // Re-check to get the real post-sync ahead/behind numbers.
                    self.check(row) { completion?(true) }
                    return
                }
                row.status = outcome.refusedDiverged ? .diverged(localOnly: 0, upstreamAhead: 0) : .syncFailed
                row.detail = outcome.detail
                self.render(row)
                if outcome.refusedDiverged {
                    // A refusal is a real, meaningful signal, not a silent
                    // no-op - re-check right after so the row shows the
                    // fork's actual diverged-commit counts instead of the
                    // placeholder zeros above.
                    self.check(row) { completion?(false) }
                } else {
                    completion?(false)
                }
            }
        }
    }

    // MARK: Render

    private func render(_ row: GitHubSyncRow) {
        row.detailLabel.stringValue = row.detail
        row.logField.stringValue = row.log.isEmpty ? "No output yet." : row.log

        let (pillText, pillColorHex) = pillVisuals(row.status)
        ToolRowLayout.pill(text: pillText, colorHex: pillColorHex, into: row.pill, label: row.pillLabel)

        let busy = row.status == .checking || row.status == .syncing
        row.pill.isHidden = busy
        row.syncButton.isHidden = busy || !row.status.showsSyncButton
        row.spinner.isHidden = !busy
        row.progressLabel.isHidden = !busy
        row.progressLabel.stringValue = row.status == .syncing ? "Syncing\u{2026}" : "Checking\u{2026}"
        if busy { row.spinner.startAnimation(nil) } else { row.spinner.stopAnimation(nil) }

        row.syncButton.isEnabled = !row.isBusy
        row.rowContainer.alphaValue = row.isBusy ? 0.6 : 1.0

        applyThemeToRow(row)
    }

    private func pillVisuals(_ status: GitHubSyncStatus) -> (String, String) {
        switch status {
        case .unknown: return ("Not Checked", theme.chromeInkHex)
        case .checking, .syncing: return ("", theme.chromeInkHex)
        case .inSync: return ("In Sync", theme.ansiHex[2])
        case .behind(let n): return ("\(n) behind", theme.ansiHex[3])
        case .diverged: return ("Diverged", theme.ansiHex[1])
        case .notAFork: return ("Not a Fork", theme.chromeInkHex)
        case .checkFailed: return ("Check Failed", theme.ansiHex[1])
        case .syncFailed: return ("Sync Failed", theme.ansiHex[1])
        }
    }

    // MARK: Theme

    private func applyThemeToRow(_ row: GitHubSyncRow) {
        let failed = row.status == .checkFailed || row.status == .syncFailed || row.status.isDiverged
        // "Needs attention" = the existing `failed`/diverged signal above,
        // plus `showsSyncButton`'s own `.behind` case - a fork genuinely
        // behind upstream is worth a look even before any sync attempt has
        // failed (`fm/grandline-setup-attention-row-style`). Both
        // predicates already exist; this only composes them, no new
        // detection. `.inSync`/`.notAFork`/`.unknown` (and a busy
        // `.checking`/`.syncing`) keep today's flat/compact look.
        let needsAttention = failed || row.status.showsSyncButton
        let attentionHex = needsAttention ? pillVisuals(row.status).1 : nil
        ToolRowLayout.applyTheme(
            row.toolRowViews, theme: theme, detailFailed: failed,
            cardStyle: needsAttention, attentionHex: attentionHex, accentBar: needsAttention
        )
        row.progressLabel.textColor = HelmTheme.mutedInk(theme)
    }

    private func applyTheme() {
        guard isViewLoaded else { return }
        let line = HelmTheme.nsColor(theme.chromeLineHex)
        for card in cards { card.applyTheme(theme) }
        for v in separators {
            v.layer?.backgroundColor = line.withAlphaComponent(0.5).cgColor
        }
        syncAllSummaryLabel.textColor = HelmTheme.mutedInk(theme)
        for row in rows { applyThemeToRow(row) }
    }
}
