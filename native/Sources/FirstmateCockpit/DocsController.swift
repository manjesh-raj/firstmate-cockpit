// Manjesh Grand Line - native macOS app.
//
// The `.docs` rail destination. `fm/grandline-docs-knowledge-foundation`
// ("Knowledge and speed", phase 1) restructured this from a single embedded
// browser into a multi-tab page - see AGENTS.md's "Knowledge" section for the
// full shape and what's explicitly deferred to later phases. The tab bar
// mirrors Shift's own fixed two-tab switcher (`ShiftController.buildTabRow`)
// - clickable `HoverHighlightView` pills, not `NSSegmentedControl` - since
// these 4 tabs are fixed and always present, not user-creatable/closeable
// like the Tools page's own multi-instance `TabChipView` strip.
//
// Tab 1, Playbook, is still the same locked-down embedded `WKWebView` onto
// the captain's real DevOps Playbook this page always was - Phase 7 of the
// UI audit moved its back/forward/reload/Open-Live-Site cluster out of a
// second 40pt bar of its own and into the one shared `HelmPageToolbar` (see
// `buildTabBar()`), but the web view, its navigation delegate, and the
// local-only load path are untouched. Tabs 2-3 are new: Runbooks (real
// CRUD, git-synced) and Postmortems (list/display only - generation is a
// later task). The original phase-1 build also shipped a 5th "Command
// Composer" tab that only ever showed an explanatory pointer at the real
// feature (Console's own "✨ Compose" toolbar button, see
// `ConsoleCommandComposer.swift` / `ConsoleComposerPopover.swift`) -
// `fm/grandline-composer-cleanup-and-polish` removed it outright once the
// captain confirmed it added nothing beyond that redirect message. This
// page's own in-page "Search" tab (real, scoped to Runbooks + Postmortems)
// was removed the same way by `fm/grandline-unified-search-fixes`, once
// phase 4's real, working `⌘K` unified search palette (`UnifiedSearch.swift`)
// made it a second, weaker entry point to the exact same content - the
// underlying `DocsKnowledgeSearch`/`UnifiedSearchIndex` logic that `⌘K`
// depends on is untouched, only this page's own duplicate UI is gone.
//
// Root view follows this app's own documented gotcha #8 (`AGENTS.md`): a
// plain `NSView` with `wantsLayer`/`HelmTheme` background, not
// `NSVisualEffectView` vibrancy.

import AppKit
import WebKit

final class DocsController: NSViewController {

    static let liveSiteURL = URL(string: "https://manjesh-raj.github.io/devops-playbook/")!

    /// `String`-backed so it can be the id `HelmSegmentedTabs` hands back - the
    /// shared component deals in caller-owned ids rather than indices.
    private enum DocsTab: String, CaseIterable {
        case playbook, runbooks, postmortems

        var title: String {
            switch self {
            case .playbook: return "Playbook"
            case .runbooks: return "Runbooks"
            case .postmortems: return "Postmortems"
            }
        }
    }

    private var activeTab: DocsTab = .playbook

    /// The shared page toolbar (Phase 7) - see `buildTabBar()`.
    private let pageToolbar = HelmPageToolbar()
    /// The active tab's own actions, in that toolbar's trailing slot.
    private let playbookActions = NSStackView()
    private let runbooksActions = NSStackView()
    /// The tab switcher, now the app's shared `HelmSegmentedTabs`
    /// (`HelmDesignSystem.swift`, audit §6.3 component 6). This page used to
    /// build **bare pills** on a 44pt divider bar - and the audit's finding was
    /// that the pill construction here and Shift's segmented capsule were
    /// already byte-for-byte identical code (12pt medium label, radius 7, 10/6
    /// insets, accent wash when active); only the wrapper differed, so one
    /// recipe rendered as two different-looking controls a rail click apart.
    /// Adopting the capsule is §6.4's own recommended direction for this page.
    private let tabs = HelmSegmentedTabs(items: DocsTab.allCases.map {
        .init(id: $0.rawValue, title: $0.title)
    }, selected: DocsTab.playbook.rawValue)
    /// Keeps `ClosureSleeve`/gesture-recognizer targets alive for as long as
    /// the rows they're attached to exist - reset on every full row rebuild.
    private var rowSleeves: [ClosureSleeve] = []
    /// The compact card containers built by `buildDocCard`, one list per tab
    /// so reloading one tab's list never drops the other's theming refs -
    /// kept so `applyTheme()` can re-tint their border, matching
    /// `ToolsController.cardBorderViews`'s own convention. Each list is reset
    /// on its own tab's full row rebuild alongside `rowSleeves`.
    private var runbookRowCards: [HoverHighlightView] = []
    private var postmortemRowCards: [HoverHighlightView] = []

    private let runbookStore = DocsRunbookStore()

    // MARK: Playbook (unchanged from before this task)

    private var webView: WKWebView!
    private var backButton: HelmButton!
    private var forwardButton: HelmButton!
    private var reloadButton: HelmButton!
    private let openLiveButton = HelmButton(title: "", variant: .secondary, symbol: "arrow.up.forward.square")
    private let emptyStateContainer = NSView()
    private var playbookEmptyState: HelmEmptyState?
    private let syncButton = HelmButton(title: "", variant: .primary)
    private let syncSpinner = NSProgressIndicator()
    private var isSyncing = false
    private let playbookContainer = NSView()

    // MARK: Runbooks

    private let runbooksContainer = NSView()
    private let runbookListScroll = NSScrollView()
    private let runbookListStack = NSStackView()
    private let runbooksHeaderCountLabel = NSTextField(labelWithString: "")
    /// `nil` = showing the list. `.some(id)` = editing an existing runbook.
    /// A brand-new (unsaved) runbook is represented separately - see
    /// `editingIsNew`.
    private var editingRunbookID: String?
    private var editingIsNew = false
    private let runbookEditorContainer = NSView()
    private let runbookTitleField = NSTextField()
    private let runbookBodyScroll = NSScrollView()
    private let runbookBodyTextView = NSTextView()
    private let runbookSaveButton = HelmButton(title: "", variant: .primary)
    private let runbookCancelButton = HelmButton(title: "", variant: .secondary)
    private let runbookDeleteButton = HelmButton(title: "", variant: .destructive)
    private let runbookEditorTitleLabel = NSTextField(labelWithString: "")
    /// The list-state container (header row + scrollable list) - kept as a
    /// property so it can be hidden whenever `runbookEditorContainer` is
    /// shown (and vice versa). Both are pinned to the same full-bleed
    /// anchors inside `runbooksContainer`, so without this the two views
    /// render on top of each other - see `fm/grandline-docs-runbook-editor-
    /// overlap-fix`'s AGENTS.md note for the real captain-reported bug this
    /// fixed (doubled title text, list content faintly visible under the
    /// editor).
    private let runbookListContainerStack = NSStackView()

    // MARK: Postmortems

    private let postmortemsContainer = NSView()
    private let postmortemListScroll = NSScrollView()
    private let postmortemListStack = NSStackView()
    private let postmortemDetailScroll = NSScrollView()
    private let postmortemDetailTextView = NSTextView()
    private let postmortemEmptyState = HelmEmptyState(
        symbol: "doc.text.magnifyingglass",
        body: "No postmortems yet. Generate one from an SRE Lead investigation and it will appear here.")
    /// Only built while the runbook grid is genuinely empty, so it is optional
    /// rather than a stored instance.
    private var runbookGridEmptyState: HelmEmptyState?
    private var selectedPostmortemID: String?

    private var theme: HelmTheme = ThemeManager.shared.theme

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 720))
        root.wantsLayer = true
        view = root

        root.addSubview(pageToolbar)
        // `pageToolbar`'s own internal constraints are self-contained, but
        // these three reference `root`, so they can only be activated once it
        // is actually a subview - see `buildTabBar()`'s doc comment for the
        // "no common ancestor" exception this file threw once before.
        NSLayoutConstraint.activate([
            pageToolbar.topAnchor.constraint(equalTo: root.topAnchor),
            pageToolbar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            pageToolbar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
        ])
        buildTabBar()

        buildPlaybookContainer()
        buildRunbooksContainer()
        buildPostmortemsContainer()

        for container in [playbookContainer, runbooksContainer, postmortemsContainer] {
            container.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(container)
            NSLayoutConstraint.activate([
                container.leadingAnchor.constraint(equalTo: root.leadingAnchor),
                container.trailingAnchor.constraint(equalTo: root.trailingAnchor),
                container.topAnchor.constraint(equalTo: pageToolbar.bottomAnchor),
                container.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            ])
        }

        ThemeManager.shared.observe { [weak self, weak root] theme in
            root?.appearance = NSAppearance(named: theme.mode == .dark ? .darkAqua : .aqua)
            root?.layer?.backgroundColor = HelmTheme.nsColor(theme.backgroundHex).cgColor
            self?.theme = theme
            self?.applyTheme()
        }

        DocsSyncCenter.observe { [weak self] in
            guard let self, self.isViewLoaded else { return }
            self.loadDocsIfAvailable()
        }

        // Re-flow the Runbooks/Postmortems grids' column count on window
        // resize, mirroring `ToolsController.containerWidthMayHaveChanged` -
        // the window's own resize notification, not `viewDidLayout()`, since
        // this page is a body child of `AppShellController`, not the
        // window's own contentViewController (the only one AppKit guarantees
        // that hook for).
        NotificationCenter.default.addObserver(self, selector: #selector(containerWidthMayHaveChanged), name: NSWindow.didResizeNotification, object: nil)

        applyTheme()
        loadDocsIfAvailable()
        showTab(.playbook)
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        updateNavButtons()
        if activeTab == .runbooks { reloadRunbooksList() }
        if activeTab == .postmortems { reloadPostmortemsList() }
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        // Same reasoning as `ToolsController.viewDidAppear`: the grids'
        // very first build happens before the view has a real width to
        // measure, so refine it against the real width now that the view is
        // actually on screen, rather than waiting for the first resize.
        containerWidthMayHaveChanged()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    /// Real widths the Runbooks/Postmortems grids last laid themselves out
    /// against - `containerWidthMayHaveChanged` re-flows the column count
    /// whenever either drifts by more than a point, tracked separately since
    /// resizing while the grid isn't visible shouldn't force a rebuild.
    private var lastRunbookGridWidth: CGFloat = 0
    private var lastPostmortemGridWidth: CGFloat = 0

    @objc private func containerWidthMayHaveChanged(_ note: Notification? = nil) {
        if let note, let win = note.object as? NSWindow, win !== view.window { return }
        guard !view.isHidden else { return }
        if activeTab == .runbooks {
            view.layoutSubtreeIfNeeded()
            let width = runbookListStack.frame.width
            if width > 0, abs(width - lastRunbookGridWidth) > 1 {
                lastRunbookGridWidth = width
                rebuildRunbookGrid()
            }
        } else if activeTab == .postmortems {
            view.layoutSubtreeIfNeeded()
            let width = postmortemListStack.frame.width
            if width > 0, abs(width - lastPostmortemGridWidth) > 1 {
                lastPostmortemGridWidth = width
                rebuildPostmortemGrid()
            }
        }
    }

    // MARK: Tab bar

    /// Phase 7, audit §3.2's "Page toolbars" / §4.10. Two things changed here,
    /// and the second is why this page ended up with the largest diff of the
    /// three:
    ///
    /// 1. The bar itself is `HelmPageToolbar` - one height, fill, hairline and
    ///    inset shared with Console and Tools, rather than this page's own
    ///    hand-rolled 44pt `NSView` and divider.
    /// 2. **This page's second bar is gone.** The Playbook tab carried its own
    ///    40pt toolbar *inside* the tab (back / forward / reload, a title
    ///    reading "DevOps Playbook", and "Open Live Site"), stacked directly
    ///    under the tab bar - the audit's "Console adds a second horizontal
    ///    chrome bar; Tools adds a third" finding, in its worst form, since
    ///    here both bars belonged to the same page. Those controls now live in
    ///    this one toolbar's trailing slot, shown only while their own tab is
    ///    active (`updateToolbarActions`). The "DevOps Playbook" label went
    ///    with the bar: the tab pill two inches to its left already says
    ///    "Playbook".
    ///
    /// The Runbooks tab's own "+ New Runbook" and count moved the same way,
    /// which is what let its in-page "Runbooks" heading go - a heading that
    /// restated the active tab pill directly above it. Same for Postmortems.
    private func buildTabBar() {
        tabs.onSelect = { [weak self] id in
            guard let self, let tab = DocsTab(rawValue: id) else { return }
            self.showTab(tab)
        }
        pageToolbar.setLeading(tabs)

        buildPlaybookToolbarActions()
        buildRunbooksToolbarActions()

        // Hidden arranged subviews of an `NSStackView` drop out of layout
        // entirely (unlike an ordinary hidden `NSView` - AGENTS.md gotcha
        // (11)), so the inactive tabs' action groups take up no width.
        let actions = NSStackView(views: [playbookActions, runbooksActions])
        actions.orientation = .horizontal
        actions.alignment = .centerY
        actions.spacing = HelmMetrics.s2
        pageToolbar.setTrailing(actions)
        updateToolbarActions()
    }

    /// The Playbook tab's own actions, in the shared toolbar's trailing slot.
    private func buildPlaybookToolbarActions() {
        backButton = HelmPageToolbar.iconButton(symbol: "chevron.left", tooltip: "Back",
                                                target: self, action: #selector(backTapped))
        forwardButton = HelmPageToolbar.iconButton(symbol: "chevron.right", tooltip: "Forward",
                                                   target: self, action: #selector(forwardTapped))
        reloadButton = HelmPageToolbar.iconButton(symbol: "arrow.clockwise",
                                                  tooltip: "Reload (local copy only)",
                                                  target: self, action: #selector(reloadTapped))

        openLiveButton.title = "Open Live Site"
        openLiveButton.controlSize = .small
        openLiveButton.target = self
        openLiveButton.action = #selector(openLiveTapped)
        openLiveButton.translatesAutoresizingMaskIntoConstraints = false

        playbookActions.setViews([backButton, forwardButton, reloadButton, openLiveButton], in: .leading)
        playbookActions.orientation = .horizontal
        playbookActions.alignment = .centerY
        playbookActions.spacing = HelmMetrics.s1
        playbookActions.translatesAutoresizingMaskIntoConstraints = false
    }

    /// The Runbooks tab's own actions - the count and "+ New Runbook" that
    /// used to sit in an in-page header row beside a duplicate "Runbooks"
    /// heading.
    private func buildRunbooksToolbarActions() {
        runbooksHeaderCountLabel.font = HelmType.caption()
        runbooksHeaderCountLabel.translatesAutoresizingMaskIntoConstraints = false

        let newButton = HelmButton(title: "New Runbook", variant: .primary, symbol: "plus")
        newButton.controlSize = .small
        let newSleeve = ClosureSleeve { [weak self] in self?.beginNewRunbook() }
        rowSleeves.append(newSleeve)
        newButton.target = newSleeve
        newButton.action = #selector(ClosureSleeve.invoke)
        newButton.translatesAutoresizingMaskIntoConstraints = false

        runbooksActions.setViews([runbooksHeaderCountLabel, newButton], in: .leading)
        runbooksActions.orientation = .horizontal
        runbooksActions.alignment = .centerY
        runbooksActions.spacing = HelmMetrics.s2
        runbooksActions.translatesAutoresizingMaskIntoConstraints = false
    }

    /// Only the active tab's actions are in the toolbar - and none at all
    /// while the runbook editor is open, since "New Runbook" beside a form
    /// that is already creating one reads as a second, competing action.
    private func updateToolbarActions() {
        playbookActions.isHidden = activeTab != .playbook
        runbooksActions.isHidden = activeTab != .runbooks || !runbookEditorContainer.isHidden
    }

    private func showTab(_ tab: DocsTab) {
        activeTab = tab
        // A no-op on a real pill click (which has already moved it), needed for
        // `openRunbook(id:)`/`openPostmortem(id:)` and the ⌘K palette, which
        // reach a tab without one.
        tabs.select(tab.rawValue)
        playbookContainer.isHidden = tab != .playbook
        runbooksContainer.isHidden = tab != .runbooks
        postmortemsContainer.isHidden = tab != .postmortems
        if tab == .runbooks { reloadRunbooksList() }
        if tab == .postmortems { reloadPostmortemsList() }
        updateToolbarActions()
        applyTheme()
    }

    // MARK: Playbook (unchanged behavior from before this task)

    private func buildPlaybookContainer() {
        let config = WKWebViewConfiguration()
        webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = self
        webView.translatesAutoresizingMaskIntoConstraints = false

        buildEmptyState()

        playbookContainer.addSubview(webView)
        playbookContainer.addSubview(emptyStateContainer)
        emptyStateContainer.translatesAutoresizingMaskIntoConstraints = false

        // The web view now starts at the container's own top edge: this tab's
        // second 40pt toolbar is gone, its controls having moved into the one
        // shared page toolbar (see `buildTabBar()`).
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: playbookContainer.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: playbookContainer.trailingAnchor),
            webView.topAnchor.constraint(equalTo: playbookContainer.topAnchor),
            webView.bottomAnchor.constraint(equalTo: playbookContainer.bottomAnchor),

            emptyStateContainer.leadingAnchor.constraint(equalTo: playbookContainer.leadingAnchor),
            emptyStateContainer.trailingAnchor.constraint(equalTo: playbookContainer.trailingAnchor),
            emptyStateContainer.topAnchor.constraint(equalTo: playbookContainer.topAnchor),
            emptyStateContainer.bottomAnchor.constraint(equalTo: playbookContainer.bottomAnchor),
        ])
    }

    @objc private func backTapped() { webView.goBack() }
    @objc private func forwardTapped() { webView.goForward() }
    @objc private func reloadTapped() { loadDocsIfAvailable() }
    @objc private func openLiveTapped() { NSWorkspace.shared.open(Self.liveSiteURL) }

    private func updateNavButtons() {
        backButton.isEnabled = webView.canGoBack
        forwardButton.isEnabled = webView.canGoForward
    }

    /// The Playbook's own empty state, now the app's shared `HelmEmptyState`
    /// (`HelmDesignSystem.swift`, audit §6.3 component 5). This state was §3.2's
    /// "most complete one" and is what the shared component's `.standard` size
    /// *is* - a 40pt glyph over a real title, body copy and an action. The
    /// action row stays caller-owned, so "Sync Now" is still the same
    /// `HelmButton` this page enables/disables around its own async sync, with
    /// the same spinner beside it.
    private func buildEmptyState() {
        syncButton.title = "Sync Now"
        syncButton.controlSize = .regular
        syncButton.target = self
        syncButton.action = #selector(syncNowTapped)
        syncButton.translatesAutoresizingMaskIntoConstraints = false

        syncSpinner.style = .spinning
        syncSpinner.controlSize = .small
        syncSpinner.isIndeterminate = true
        syncSpinner.isHidden = true
        syncSpinner.translatesAutoresizingMaskIntoConstraints = false

        let actionRow = NSStackView(views: [syncButton, syncSpinner])
        actionRow.orientation = .horizontal
        actionRow.spacing = 10
        actionRow.alignment = .centerY
        actionRow.translatesAutoresizingMaskIntoConstraints = false

        let empty = HelmEmptyState(symbol: "book.closed",
                                   title: "Docs not synced yet",
                                   body: "The DevOps Playbook hasn't been synced to this Mac yet. Sync it once to browse it here, fully offline afterward.",
                                   size: .standard,
                                   accessory: actionRow)
        playbookEmptyState = empty
        emptyStateContainer.addSubview(empty)
        NSLayoutConstraint.activate([
            empty.leadingAnchor.constraint(equalTo: emptyStateContainer.leadingAnchor),
            empty.trailingAnchor.constraint(equalTo: emptyStateContainer.trailingAnchor),
            empty.topAnchor.constraint(equalTo: emptyStateContainer.topAnchor),
            empty.bottomAnchor.constraint(equalTo: emptyStateContainer.bottomAnchor),
        ])
    }

    @objc private func syncNowTapped() {
        guard !isSyncing else { return }
        isSyncing = true
        syncButton.isEnabled = false
        syncSpinner.isHidden = false
        syncSpinner.startAnimation(nil)
        DispatchQueue.global(qos: .userInitiated).async {
            let outcome = DocsSyncSource.update()
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.isSyncing = false
                self.syncButton.isEnabled = true
                self.syncSpinner.isHidden = true
                self.syncSpinner.stopAnimation(nil)
                if outcome.ok {
                    self.loadDocsIfAvailable()
                } else if let container = self.view.window?.contentView {
                    Toast.show(in: container, message: "Docs sync failed: \(outcome.detail)")
                }
            }
        }
    }

    private func loadDocsIfAvailable() {
        guard DocsStore.isSynced else {
            webView.isHidden = true
            emptyStateContainer.isHidden = false
            return
        }
        emptyStateContainer.isHidden = true
        webView.isHidden = false
        if webView.url == nil {
            webView.loadFileURL(DocsStore.indexURL, allowingReadAccessTo: DocsStore.folderURL)
        } else {
            webView.reload()
        }
    }

    // MARK: Runbooks

    private func buildRunbooksContainer() {
        // No in-page "Runbooks" heading: it restated the active tab pill
        // directly above it (audit §4.10 / Phase 7). Its row's two real
        // contents - the count and "New Runbook" - are in the shared page
        // toolbar now, see `buildRunbooksToolbarActions()`.
        runbookListStack.orientation = .vertical
        runbookListStack.alignment = .leading
        runbookListStack.spacing = Self.docCardSpacing
        runbookListStack.translatesAutoresizingMaskIntoConstraints = false

        // `FlippedView`, not a plain `NSView()` - see AGENTS.md's Docs section
        // and AppKit gotcha (9): a non-flipped document view puts y=0 at the
        // *bottom*, so content shorter than the viewport (the common case
        // here) rests against the bottom of the scroll area instead of the
        // top, leaving a large empty gap above the rows.
        let listContent = FlippedView()
        listContent.translatesAutoresizingMaskIntoConstraints = false
        listContent.addSubview(runbookListStack)
        NSLayoutConstraint.activate([
            runbookListStack.leadingAnchor.constraint(equalTo: listContent.leadingAnchor),
            runbookListStack.trailingAnchor.constraint(equalTo: listContent.trailingAnchor),
            runbookListStack.topAnchor.constraint(equalTo: listContent.topAnchor),
            runbookListStack.bottomAnchor.constraint(lessThanOrEqualTo: listContent.bottomAnchor),
        ])

        runbookListScroll.documentView = listContent
        runbookListScroll.hasVerticalScroller = true
        runbookListScroll.drawsBackground = false
        runbookListScroll.translatesAutoresizingMaskIntoConstraints = false
        // `==`, not `>=` - the grid's cards are now sized responsively to
        // whatever width is actually available (`rebuildRunbookGrid`,
        // matching `ToolsController.rebuildGrid`'s own approach), so there's
        // no fixed-width card that could need the document view to grow past
        // the viewport.
        listContent.widthAnchor.constraint(equalTo: runbookListScroll.contentView.widthAnchor).isActive = true

        let listStack = runbookListContainerStack
        listStack.setViews([runbookListScroll], in: .leading)
        listStack.orientation = .vertical
        listStack.alignment = .leading
        listStack.spacing = 12
        listStack.translatesAutoresizingMaskIntoConstraints = false

        buildRunbookEditor()

        // `runbookEditorContainer` is a bare `NSView()` that never had this
        // set - see AGENTS.md's "AppKit gotchas" entry (3)/(11) for the full
        // mechanism: left at its default `true`, AppKit also synthesizes
        // required constraints pinning the view to its zero-size initial
        // frame, which fight the explicit fill constraints below the moment
        // the window tries to grow, and a contentViewController-driven
        // window resolves that by snapping its own frame back down instead
        // of breaking either required constraint.
        runbookEditorContainer.translatesAutoresizingMaskIntoConstraints = false

        runbooksContainer.addSubview(listStack)
        runbooksContainer.addSubview(runbookEditorContainer)
        NSLayoutConstraint.activate([
            listStack.leadingAnchor.constraint(equalTo: runbooksContainer.leadingAnchor, constant: 18),
            listStack.trailingAnchor.constraint(equalTo: runbooksContainer.trailingAnchor, constant: -18),
            listStack.topAnchor.constraint(equalTo: runbooksContainer.topAnchor, constant: 16),
            listStack.bottomAnchor.constraint(equalTo: runbooksContainer.bottomAnchor, constant: -16),
            runbookListScroll.widthAnchor.constraint(equalTo: listStack.widthAnchor),

            runbookEditorContainer.leadingAnchor.constraint(equalTo: runbooksContainer.leadingAnchor, constant: 18),
            runbookEditorContainer.trailingAnchor.constraint(equalTo: runbooksContainer.trailingAnchor, constant: -18),
            runbookEditorContainer.topAnchor.constraint(equalTo: runbooksContainer.topAnchor, constant: 16),
            runbookEditorContainer.bottomAnchor.constraint(equalTo: runbooksContainer.bottomAnchor, constant: -16),
        ])
        runbookEditorContainer.isHidden = true
    }

    private func buildRunbookEditor() {
        runbookEditorTitleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        runbookEditorTitleLabel.translatesAutoresizingMaskIntoConstraints = false

        runbookTitleField.placeholderString = "Title"
        runbookTitleField.font = .systemFont(ofSize: 13)
        runbookTitleField.translatesAutoresizingMaskIntoConstraints = false

        runbookBodyTextView.isRichText = false
        runbookBodyTextView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        runbookBodyTextView.isEditable = true
        runbookBodyTextView.isAutomaticQuoteSubstitutionEnabled = false
        runbookBodyTextView.isAutomaticDashSubstitutionEnabled = false
        runbookBodyTextView.textContainerInset = NSSize(width: 8, height: 8)
        runbookBodyScroll.documentView = runbookBodyTextView
        runbookBodyScroll.hasVerticalScroller = true
        runbookBodyScroll.borderType = .lineBorder
        runbookBodyScroll.translatesAutoresizingMaskIntoConstraints = false

        runbookSaveButton.title = "Save"
        runbookSaveButton.keyEquivalent = "\r"
        let saveSleeve = ClosureSleeve { [weak self] in self?.saveRunbookEditor() }
        rowSleeves.append(saveSleeve)
        runbookSaveButton.target = saveSleeve
        runbookSaveButton.action = #selector(ClosureSleeve.invoke)
        runbookSaveButton.translatesAutoresizingMaskIntoConstraints = false

        runbookCancelButton.title = "Cancel"
        let cancelSleeve = ClosureSleeve { [weak self] in self?.cancelRunbookEditor() }
        rowSleeves.append(cancelSleeve)
        runbookCancelButton.target = cancelSleeve
        runbookCancelButton.action = #selector(ClosureSleeve.invoke)
        runbookCancelButton.translatesAutoresizingMaskIntoConstraints = false

        runbookDeleteButton.title = "Delete"
        let deleteSleeve = ClosureSleeve { [weak self] in self?.confirmDeleteEditingRunbook() }
        rowSleeves.append(deleteSleeve)
        runbookDeleteButton.target = deleteSleeve
        runbookDeleteButton.action = #selector(ClosureSleeve.invoke)
        runbookDeleteButton.translatesAutoresizingMaskIntoConstraints = false

        let buttonRow = NSStackView(views: [runbookDeleteButton, NSView(), runbookCancelButton, runbookSaveButton])
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 8
        buttonRow.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [runbookEditorTitleLabel, runbookTitleField, runbookBodyScroll, buttonRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false

        runbookEditorContainer.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: runbookEditorContainer.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: runbookEditorContainer.trailingAnchor),
            stack.topAnchor.constraint(equalTo: runbookEditorContainer.topAnchor),
            stack.bottomAnchor.constraint(equalTo: runbookEditorContainer.bottomAnchor),
            runbookTitleField.widthAnchor.constraint(equalTo: stack.widthAnchor),
            runbookBodyScroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            runbookBodyScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 320),
            buttonRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
    }

    private func reloadRunbooksList() {
        let runbooks = runbookStore.listRunbooks()
        // Reads as a sentence now that it sits in the toolbar rather than
        // beside a "Runbooks" heading - a bare "6" there says nothing.
        runbooksHeaderCountLabel.stringValue = runbooks.count == 1 ? "1 runbook" : "\(runbooks.count) runbooks"
        runbookGridItems = runbooks.map { runbook in
            // The card's own metadata line - "Kubernetes \u{00B7} 3 steps" -
            // read out of the runbook's own fenced steps
            // (`DocsRunbookMetadata`), matching the prototype
            // (`11-proposed-docs-runbooks.png`). "Updated N ago" is the
            // fallback for a document with no steps yet, and stays on the
            // card's tooltip either way so the timestamp is never lost.
            let updated = "Updated \(Self.relativeDate(runbook.modifiedAt))"
            let subtitle = DocsRunbookMetadata.runbookSubtitle(runbook) ?? updated
            return DocGridItem(
                title: runbook.title,
                subtitle: subtitle,
                tooltip: subtitle == updated ? runbook.title : "\(runbook.title) \u{2014} \(updated)",
                icon: "doc.text",
                tint: .info,
                onOpen: { [weak self] in self?.beginEditRunbook(runbook.id) },
                onDelete: { [weak self] in self?.confirmDeleteRunbook(id: runbook.id, title: runbook.title) }
            )
        }
        rebuildRunbookGrid()
    }

    /// Re-flows `runbookGridItems` into a wrapping multi-column grid, sized
    /// to whatever width `runbookListStack` actually has - the same
    /// columns-from-container-width + `.fillEqually` approach as
    /// `ToolsController.rebuildGrid()`, including its partial-last-row
    /// padding fix (`fm/cockpit-tools-page-partial-row-fix`): a row with
    /// fewer cards than a full row is padded out with invisible spacers so
    /// `.fillEqually` always divides by the same column count and a lone
    /// leftover card never stretches to fill the whole row.
    private func rebuildRunbookGrid() {
        runbookListStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        runbookRowCards.removeAll()
        if runbookGridItems.isEmpty {
            // Was a bare left-aligned `NSTextField` with no icon and no
            // container - one of the four §3.2 called out. This grid is the
            // whole tab body, so it gets the real treatment rather than a
            // sentence floating at the top-left.
            let empty = HelmEmptyState(symbol: "list.bullet.rectangle",
                                       body: "No runbooks yet. Create one to get started.")
            empty.heightAnchor.constraint(equalToConstant: 110).isActive = true
            runbookGridEmptyState = empty
            runbookListStack.addArrangedSubview(empty)
            empty.widthAnchor.constraint(equalTo: runbookListStack.widthAnchor).isActive = true
            applyTheme()
            return
        }
        runbookGridEmptyState = nil
        let (rows, cards) = layoutDocGrid(items: runbookGridItems, containerWidth: runbookListStack.frame.width)
        for row in rows {
            runbookListStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: runbookListStack.widthAnchor).isActive = true
        }
        runbookRowCards = cards
        applyTheme()
    }

    private func beginNewRunbook() {
        editingIsNew = true
        editingRunbookID = nil
        runbookEditorTitleLabel.stringValue = "New Runbook"
        runbookTitleField.stringValue = ""
        runbookBodyTextView.string = ""
        runbookDeleteButton.isHidden = true
        runbookListContainerStack.isHidden = true
        runbookEditorContainer.isHidden = false
        updateToolbarActions()
        view.window?.makeFirstResponder(runbookTitleField)
    }

    private func beginEditRunbook(_ id: String) {
        guard let runbook = runbookStore.listRunbooks().first(where: { $0.id == id }) else { return }
        editingIsNew = false
        editingRunbookID = id
        runbookEditorTitleLabel.stringValue = "Edit Runbook"
        runbookTitleField.stringValue = runbook.title
        runbookBodyTextView.string = runbook.content
        runbookDeleteButton.isHidden = false
        runbookListContainerStack.isHidden = true
        runbookEditorContainer.isHidden = false
        updateToolbarActions()
    }

    private func cancelRunbookEditor() {
        runbookEditorContainer.isHidden = true
        runbookListContainerStack.isHidden = false
        updateToolbarActions()
        editingRunbookID = nil
        editingIsNew = false
    }

    private func saveRunbookEditor() {
        let title = runbookTitleField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = runbookBodyTextView.string
        guard !title.isEmpty else {
            if let container = view.window?.contentView { Toast.show(in: container, message: "A runbook needs a title") }
            return
        }
        // Keep the stored markdown's own leading "# Title" in sync with the
        // title field, so `DocsRunbookStore.titleFromContent` (and this
        // page's list) reflect a rename without a stale heading.
        let content = Self.contentWithHeading(title: title, body: body)
        if editingIsNew {
            runbookStore.createRunbook(title: title, content: content)
        } else if let id = editingRunbookID {
            runbookStore.updateRunbook(id: id, content: content)
        }
        runbookEditorContainer.isHidden = true
        runbookListContainerStack.isHidden = false
        updateToolbarActions()
        editingRunbookID = nil
        editingIsNew = false
        reloadRunbooksList()
        if let container = view.window?.contentView { Toast.show(in: container, message: "Runbook saved") }
    }

    private func confirmDeleteEditingRunbook() {
        guard let id = editingRunbookID else { return }
        confirmDeleteRunbook(id: id, title: runbookTitleField.stringValue, dismissingEditor: true)
    }

    private func confirmDeleteRunbook(id: String, title: String, dismissingEditor: Bool = false) {
        let alert = NSAlert()
        alert.messageText = "Delete \"\(title)\"?"
        alert.informativeText = "This removes the runbook file and syncs the deletion."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        runbookStore.deleteRunbook(id: id)
        if dismissingEditor {
            runbookEditorContainer.isHidden = true
            runbookListContainerStack.isHidden = false
            editingRunbookID = nil
        }
        reloadRunbooksList()
    }

    /// Ensures `content` starts with `# title` - replaces an existing leading
    /// heading, or prepends one if the body has none, so the title field is
    /// always the source of truth for what's shown in the list.
    private static func contentWithHeading(title: String, body: String) -> String {
        var lines = body.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        while let first = lines.first, first.trimmingCharacters(in: .whitespaces).isEmpty {
            lines.removeFirst()
        }
        if let first = lines.first, first.trimmingCharacters(in: .whitespaces).hasPrefix("# ") {
            lines[0] = "# \(title)"
        } else {
            lines.insert("# \(title)", at: 0)
            lines.insert("", at: 1)
        }
        return lines.joined(separator: "\n")
    }

    // MARK: Postmortems

    private func buildPostmortemsContainer() {
        // No in-page "Postmortems" heading either - same reason as Runbooks
        // above.
        postmortemListStack.orientation = .vertical
        postmortemListStack.alignment = .leading
        postmortemListStack.spacing = Self.docCardSpacing
        postmortemListStack.translatesAutoresizingMaskIntoConstraints = false

        // `FlippedView`, not a plain `NSView()` - same top-anchoring fix as
        // the Runbooks list above (AppKit gotcha (9) in AGENTS.md).
        let listContent = FlippedView()
        listContent.translatesAutoresizingMaskIntoConstraints = false
        listContent.addSubview(postmortemListStack)
        NSLayoutConstraint.activate([
            postmortemListStack.leadingAnchor.constraint(equalTo: listContent.leadingAnchor),
            postmortemListStack.trailingAnchor.constraint(equalTo: listContent.trailingAnchor),
            postmortemListStack.topAnchor.constraint(equalTo: listContent.topAnchor),
            postmortemListStack.bottomAnchor.constraint(lessThanOrEqualTo: listContent.bottomAnchor),
        ])
        postmortemListScroll.documentView = listContent
        postmortemListScroll.hasVerticalScroller = true
        postmortemListScroll.drawsBackground = false
        postmortemListScroll.translatesAutoresizingMaskIntoConstraints = false
        // `==`, not `>=` - see the matching comment on the Runbooks list's
        // own document-view width constraint above.
        listContent.widthAnchor.constraint(equalTo: postmortemListScroll.contentView.widthAnchor).isActive = true

        postmortemEmptyState.heightAnchor.constraint(equalToConstant: 110).isActive = true

        postmortemDetailTextView.isEditable = false
        postmortemDetailTextView.isRichText = false
        postmortemDetailTextView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        postmortemDetailTextView.textContainerInset = NSSize(width: 8, height: 8)
        postmortemDetailScroll.documentView = postmortemDetailTextView
        postmortemDetailScroll.hasVerticalScroller = true
        postmortemDetailScroll.borderType = .lineBorder
        postmortemDetailScroll.translatesAutoresizingMaskIntoConstraints = false
        postmortemDetailScroll.isHidden = true

        let stack = NSStackView(views: [postmortemEmptyState, postmortemListScroll, postmortemDetailScroll])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false

        postmortemsContainer.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: postmortemsContainer.leadingAnchor, constant: 18),
            stack.trailingAnchor.constraint(equalTo: postmortemsContainer.trailingAnchor, constant: -18),
            stack.topAnchor.constraint(equalTo: postmortemsContainer.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(equalTo: postmortemsContainer.bottomAnchor, constant: -16),
            postmortemListScroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            postmortemListScroll.heightAnchor.constraint(equalToConstant: 220),
            postmortemDetailScroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
    }

    private func reloadPostmortemsList() {
        let postmortems = runbookStore.listPostmortems()
        postmortemEmptyState.isHidden = !postmortems.isEmpty
        postmortemListScroll.isHidden = postmortems.isEmpty
        postmortemGridItems = postmortems.map { postmortem in
            // A postmortem's own `## Root Cause` section is what its card
            // says (prototype `13-proposed-docs-postmortems.png`); the
            // timestamp falls back in when the document has no root cause
            // written yet.
            let updated = "Updated \(Self.relativeDate(postmortem.modifiedAt))"
            let subtitle = DocsRunbookMetadata.postmortemSubtitle(postmortem) ?? updated
            return DocGridItem(
                title: postmortem.title,
                subtitle: subtitle,
                tooltip: subtitle == updated ? postmortem.title : "\(postmortem.title) \u{2014} \(updated)",
                icon: "exclamationmark.triangle",
                tint: .warn,
                onOpen: { [weak self] in self?.showPostmortem(postmortem.id) },
                onDelete: nil
            )
        }
        rebuildPostmortemGrid()
        if selectedPostmortemID == nil {
            postmortemDetailScroll.isHidden = true
        }
        applyTheme()
    }

    /// Re-flows `postmortemGridItems` - see `rebuildRunbookGrid`'s doc
    /// comment, which this mirrors exactly.
    private func rebuildPostmortemGrid() {
        postmortemListStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        postmortemRowCards.removeAll()
        guard !postmortemGridItems.isEmpty else { return }
        let (rows, cards) = layoutDocGrid(items: postmortemGridItems, containerWidth: postmortemListStack.frame.width)
        for row in rows {
            postmortemListStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: postmortemListStack.widthAnchor).isActive = true
        }
        postmortemRowCards = cards
        applyTheme()
    }

    private func showPostmortem(_ id: String) {
        guard let postmortem = runbookStore.listPostmortems().first(where: { $0.id == id }) else { return }
        selectedPostmortemID = id
        postmortemDetailTextView.string = postmortem.content
        postmortemDetailScroll.isHidden = false
    }

    /// Entry points for the unified `⌘K` search palette
    /// (`UnifiedSearchController`, owned outside this page) - the one "open
    /// this runbook/postmortem" behavior, now that this page's own in-page
    /// Search tab (which used to duplicate this) is gone.
    func openRunbook(id: String) {
        showTab(.runbooks)
        beginEditRunbook(id)
    }

    func openPostmortem(id: String) {
        showTab(.postmortems)
        showPostmortem(id)
    }

    // MARK: Shared grid builder (Runbooks/Postmortems)

    /// One card's content, independent of layout - built fresh from disk on
    /// every `reloadRunbooksList`/`reloadPostmortemsList`, then re-laid-out
    /// (with no disk re-read) by `rebuildRunbookGrid`/`rebuildPostmortemGrid`
    /// on every window resize.
    private struct DocGridItem {
        let title: String
        let subtitle: String
        /// Hover text for the whole card. Carries what the one-line subtitle
        /// no longer has room for once it shows real metadata - the full
        /// title and the "Updated N ago" timestamp.
        var tooltip: String? = nil
        let icon: String
        let tint: HelmTint
        let onOpen: () -> Void
        let onDelete: (() -> Void)?
    }

    private var runbookGridItems: [DocGridItem] = []
    private var postmortemGridItems: [DocGridItem] = []

    /// A compact card - `IconTileView` + title + a short secondary line -
    /// laid out as a wrapping multi-column grid sized to the space actually
    /// available, matching the Tools page's own landing-grid treatment
    /// (`ToolsController.rebuildGrid()`) per the captain's explicit request
    /// to use that page's layout as the reference (`fm/grandline-docs-
    /// runbook-grid-layout`, superseding the prior single-column stacked-
    /// list shape from `fm/grandline-docs-runbook-list-compact-fix`).
    private static let docMinCardWidth: CGFloat = 260
    private static let docCardSpacing: CGFloat = 14
    private static let docCardPadding: CGFloat = 14
    /// A fixed height for every card, tall enough to comfortably fit a
    /// 3-line wrapped title (captain-reported: "Identifying Unhealthy /
    /// NotReady Nodes" truncated to "...Nod…" on a single line) plus the
    /// subtitle line - deliberately NOT content-dependent, so a short title
    /// just leaves empty space below it rather than every card in the grid
    /// growing/shrinking to match its own content (the same "avoid a
    /// scrollable-item's height silently growing" lesson already applied to
    /// this app's other lists - see AGENTS.md's Shift/Diff-tool entries).
    private static let docCardHeight: CGFloat = 100
    /// The card's corner delete glyph, sized like a toolbar icon square
    /// rather than left at a regular button's intrinsic width - see
    /// `buildDocCard`.
    private static let docCardDeleteButtonSide: CGFloat = 24

    /// Lays `items` out as a grid of rows, each row a `.fillEqually`
    /// horizontal stack of cards sized to `containerWidth` - byte-for-byte
    /// the same columns-from-width + partial-last-row-padding approach as
    /// `ToolsController.rebuildGrid()`. Returns the built rows (to add as
    /// arranged subviews of the caller's own vertical list stack) and the
    /// cards themselves (for `applyTheme()`'s re-tint pass).
    /// This page's own copy of Tools' column-count/spacer-padding math (its
    /// original doc comment said as much: "a direct port of
    /// `ToolsController.rebuildGrid`") is gone - Phase 7 moved that one
    /// definition into `HelmResponsiveGrid`. What is left here is what is
    /// genuinely this page's: which card to build, and collecting the built
    /// cards so `applyTheme` can re-tint their borders.
    private func layoutDocGrid(items: [DocGridItem], containerWidth: CGFloat) -> (rows: [NSView], cards: [HoverHighlightView]) {
        var cards: [HoverHighlightView] = []
        let rows = HelmResponsiveGrid.rows(items,
                                           containerWidth: containerWidth,
                                           minItemWidth: Self.docMinCardWidth,
                                           spacing: Self.docCardSpacing) { item, width in
            let card = self.buildDocCard(item, width: width)
            cards.append(card)
            return card
        }
        return (rows, cards)
    }

    private func buildDocCard(_ item: DocGridItem, width: CGFloat) -> HoverHighlightView {
        let iconTile = IconTileView(size: 26, cornerRadius: 7)
        iconTile.configure(symbol: item.icon, tint: item.tint, pointSize: 12)
        iconTile.setContentHuggingPriority(.required, for: .horizontal)

        let titleLabel = NSTextField(wrappingLabelWithString: item.title)
        titleLabel.font = .systemFont(ofSize: 12.5, weight: .semibold)
        titleLabel.maximumNumberOfLines = 3
        // Everything to the title column's right: the delete glyph plus the
        // 10pt gap `row`'s trailing constraint leaves in front of it.
        let deleteColumnWidth: CGFloat = item.onDelete != nil ? Self.docCardDeleteButtonSide + 10 : 0
        // Card width varies with the container (see `layoutDocGrid`), so this
        // is recomputed on every rebuild rather than a fixed guess - matching
        // `ToolsController.toolCard`'s own reasoning for its description
        // label.
        //
        // **It has to be the column's real width, not an over-estimate.** An
        // over-estimate is the dangerous direction: AppKit computes a
        // one-line `intrinsicContentSize` at the estimate, lays the label out
        // one line tall, and the text then wraps to two lines *inside* that
        // one-line frame and draws the second line outside its own bounds -
        // no ellipsis, just a silently missing tail. Measured before this
        // fix: "Debugging High CPU Usage" estimated at 179.6pt, laid out at
        // 167pt, rendered as a bare "Debugging High" (visible in the
        // captain's own `12-live-docs-runbooks.png` too). The old formula
        // missed both the 10pt gap above and the delete button's real width.
        titleLabel.preferredMaxLayoutWidth = max(60, width - Self.docCardPadding * 2 - 26 - 10 - deleteColumnWidth)

        let subtitleLabel = NSTextField(labelWithString: item.subtitle)
        subtitleLabel.font = .systemFont(ofSize: 10.5)
        subtitleLabel.lineBreakMode = .byTruncatingTail
        subtitleLabel.maximumNumberOfLines = 1
        subtitleLabel.textColor = HelmTheme.mutedInk(theme)

        let textStack = NSStackView(views: [titleLabel, subtitleLabel])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 3
        textStack.translatesAutoresizingMaskIntoConstraints = false
        // Stack-level priorities, not the content ones - AGENTS.md gotcha
        // (12): `setContentHuggingPriority` is a no-op on an `NSStackView`,
        // which has no intrinsic size of its own.
        textStack.setHuggingPriority(.defaultLow, for: .horizontal)
        textStack.setClippingResistancePriority(.defaultLow, for: .horizontal)
        // Both labels take exactly the text column's width, so a title that
        // does not fit wraps or truncates instead of being **clipped**.
        // Measured before this fix: "Debugging High CPU Usage" had an
        // intrinsic width of 170.5 inside a 161.5pt text stack in a 373pt
        // card, and rendered as a bare "Debugging High" with no ellipsis -
        // visible in the captain's own live screenshot
        // (`12-live-docs-runbooks.png`) as well as in a real off-screen
        // render. The text stack was that narrow because `row` below was left
        // at `.gravityAreas`.
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            titleLabel.widthAnchor.constraint(equalTo: textStack.widthAnchor),
            subtitleLabel.widthAnchor.constraint(equalTo: textStack.widthAnchor),
        ])

        // The delete button is pinned directly to the container's own
        // top-right corner below, not laid out inside `row` alongside the
        // title - a plain horizontal NSStackView left at its default
        // `.gravityAreas` distribution doesn't stretch to fill leftover
        // width (see AGENTS.md gotcha (10)), so a delete button placed as
        // a trailing arranged subview of `row` used to sit immediately
        // after the title text instead of at the card's fixed corner,
        // drifting left/right and up/down with the title's own length and
        // wrap (`fm/grandline-docs-runbook-delete-icon-corner`).
        let row = NSStackView(views: [iconTile, textStack])
        row.orientation = .horizontal
        row.alignment = .top
        row.spacing = 10
        // `.fill`, explicitly - at the default `.gravityAreas` the text stack
        // was laid out at its own natural width rather than the card's, which
        // is what clipped a long title (see the constraints above).
        row.distribution = .fill
        row.translatesAutoresizingMaskIntoConstraints = false

        let container = HoverHighlightView()
        container.cornerRadius = 9
        container.layer?.borderWidth = 1
        container.toolTip = item.tooltip
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(row)

        var rowTrailingAnchor = container.trailingAnchor
        var rowTrailingConstant: CGFloat = -Self.docCardPadding

        if let onDelete = item.onDelete {
            let deleteButton = HelmButton(symbol: "trash", variant: .quiet, size: .small)
            let sleeve = ClosureSleeve(onDelete)
            rowSleeves.append(sleeve)
            deleteButton.target = sleeve
            deleteButton.action = #selector(ClosureSleeve.invoke)
            deleteButton.toolTip = "Delete"
            deleteButton.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(deleteButton)
            // **A real width, matching the `deleteButtonWidth` the title's own
            // wrap math above already assumes.** Left to its intrinsic size a
            // `HelmButton` carries a regular button's horizontal padding even
            // with an empty title - measured 87pt on a 265pt card, a third of
            // the card, which squeezed the title column to 104pt and clipped
            // any title longer than that. Compensated for the button's own
            // `alignmentRectInsets` exactly as `HelmPageToolbar.iconButton`
            // does, so the visible box really is this size.
            let insets = deleteButton.alignmentRectInsets
            NSLayoutConstraint.activate([
                deleteButton.topAnchor.constraint(equalTo: container.topAnchor, constant: Self.docCardPadding),
                deleteButton.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -Self.docCardPadding),
                deleteButton.widthAnchor.constraint(equalToConstant: Self.docCardDeleteButtonSide - insets.left - insets.right),
                deleteButton.heightAnchor.constraint(equalToConstant: Self.docCardDeleteButtonSide - insets.top - insets.bottom),
            ])
            rowTrailingAnchor = deleteButton.leadingAnchor
            rowTrailingConstant = -10
        }

        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: Self.docCardPadding),
            row.trailingAnchor.constraint(equalTo: rowTrailingAnchor, constant: rowTrailingConstant),
            row.topAnchor.constraint(equalTo: container.topAnchor, constant: Self.docCardPadding),
            container.heightAnchor.constraint(equalToConstant: Self.docCardHeight),
        ])
        let openSleeve = ClosureSleeve(item.onOpen)
        rowSleeves.append(openSleeve)
        let click = NSClickGestureRecognizer(target: openSleeve, action: #selector(ClosureSleeve.invoke))
        container.addGestureRecognizer(click)
        return container
    }

    private static func relativeDate(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    // MARK: Theme

    private func applyTheme() {
        let ink = HelmTheme.nsColor(theme.chromeInkHex)
        let muted = HelmTheme.mutedInk(theme)
        let surface = HelmTheme.nsColor(theme.chromeBackgroundHex)
        let line = HelmTheme.nsColor(theme.chromeLineHex)

        for container in [playbookContainer, runbooksContainer, postmortemsContainer] {
            container.wantsLayer = true
            container.layer?.backgroundColor = HelmTheme.nsColor(theme.backgroundHex).cgColor
        }

        // The page toolbar owns its own fill and hairline, and every button
        // in it is a `HelmButton` that re-derives its own tint - so there is
        // nothing here to re-colour for either.
        pageToolbar.applyTheme(theme)
        playbookEmptyState?.applyTheme(theme)
        emptyStateContainer.wantsLayer = true
        emptyStateContainer.layer?.backgroundColor = HelmTheme.nsColor(theme.backgroundHex).cgColor

        tabs.applyTheme(theme)

        runbooksHeaderCountLabel.textColor = muted
        runbookEditorTitleLabel.textColor = ink
        runbookBodyTextView.textColor = ink
        runbookBodyTextView.backgroundColor = surface
        postmortemEmptyState.applyTheme(theme)
        runbookGridEmptyState?.applyTheme(theme)
        postmortemDetailTextView.textColor = ink
        postmortemDetailTextView.backgroundColor = surface

        for cards in [runbookRowCards, postmortemRowCards] {
            for hover in cards {
                hover.normalColor = .clear
                hover.hoverColor = line.withAlphaComponent(0.18)
                hover.layer?.borderColor = line.withAlphaComponent(0.5).cgColor
                for case let sub as NSStackView in hover.subviews {
                    for view in sub.arrangedSubviews {
                        if let iconTile = view as? IconTileView { iconTile.applyTheme(theme) }
                        if let textStack = view as? NSStackView {
                            for label in textStack.arrangedSubviews.compactMap({ $0 as? NSTextField }) {
                                label.textColor = label === textStack.arrangedSubviews.first ? ink : muted
                            }
                        }
                    }
                }
            }
        }
    }
}

/// Retains a closure so it can be used as an `NSButton`/gesture-recognizer
/// target/action without needing a dedicated `@objc` method per row -
/// callers keep the sleeve alive (e.g. `DocsController.rowSleeves`) for as
/// long as the control it's attached to exists.
final class ClosureSleeve: NSObject {
    private let closure: () -> Void
    init(_ closure: @escaping () -> Void) { self.closure = closure }
    @objc func invoke() { closure() }
}

extension DocsController: WKNavigationDelegate {
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.allow)
            return
        }
        if url.isFileURL {
            let docsPath = DocsStore.folderURL.standardizedFileURL.path
            if url.standardizedFileURL.path.hasPrefix(docsPath) {
                decisionHandler(.allow)
                return
            }
        }
        decisionHandler(.cancel)
        NSWorkspace.shared.open(url)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        updateNavButtons()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        updateNavButtons()
    }
}
