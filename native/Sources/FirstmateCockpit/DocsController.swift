// Manjesh Grand Line - native macOS app.
//
// The `.docs` rail destination. `fm/grandline-docs-knowledge-foundation`
// ("Knowledge and speed", phase 1) restructured this from a single embedded
// browser into a 5-tab page - see AGENTS.md's "Knowledge" section for the
// full shape and what's explicitly deferred to later phases. The tab bar
// mirrors Shift's own fixed two-tab switcher (`ShiftController.buildTabRow`)
// - clickable `HoverHighlightView` pills, not `NSSegmentedControl` - since
// these 5 tabs are fixed and always present, not user-creatable/closeable
// like the Tools page's own multi-instance `TabChipView` strip.
//
// Tab 1, Playbook, is byte-for-byte the same locked-down embedded `WKWebView`
// onto the captain's real DevOps Playbook this page always was - none of
// that code changed, only its container. Tabs 2-5 are new: Runbooks (real
// CRUD, git-synced), Postmortems (list/display only - generation is a later
// task), Search (real, scoped to Runbooks + Postmortems), and Command
// Composer (explanatory "coming soon" only - the real composer UI is a
// later, Console-focused task).
//
// Root view follows this app's own documented gotcha #8 (`AGENTS.md`): a
// plain `NSView` with `wantsLayer`/`HelmTheme` background, not
// `NSVisualEffectView` vibrancy.

import AppKit
import WebKit

final class DocsController: NSViewController {

    static let liveSiteURL = URL(string: "https://manjesh-raj.github.io/devops-playbook/")!

    private enum DocsTab: Int, CaseIterable {
        case playbook, runbooks, postmortems, search, composer

        var title: String {
            switch self {
            case .playbook: return "Playbook"
            case .runbooks: return "Runbooks"
            case .postmortems: return "Postmortems"
            case .search: return "Search"
            case .composer: return "Command Composer"
            }
        }
    }

    private var activeTab: DocsTab = .playbook
    private var tabPills: [DocsTab: HoverHighlightView] = [:]
    private var tabLabels: [DocsTab: NSTextField] = [:]
    /// Keeps `ClosureSleeve`/gesture-recognizer targets alive for as long as
    /// the rows they're attached to exist - reset on every full row rebuild.
    private var rowSleeves: [ClosureSleeve] = []

    private let runbookStore = DocsRunbookStore()

    // MARK: Playbook (unchanged from before this task)

    private var webView: WKWebView!
    private let playbookToolbar = NSView()
    private var backButton: NSButton!
    private var forwardButton: NSButton!
    private var reloadButton: NSButton!
    private let openLiveButton = NSButton()
    private let toolbarDivider = NSView()
    private let emptyStateContainer = NSView()
    private let emptyIcon = NSImageView()
    private let emptyTitleLabel = NSTextField(labelWithString: "Docs not synced yet")
    private let emptyBodyLabel = NSTextField(wrappingLabelWithString: "The DevOps Playbook hasn't been synced to this Mac yet. Sync it once to browse it here, fully offline afterward.")
    private let syncButton = NSButton()
    private let syncSpinner = NSProgressIndicator()
    private var isSyncing = false
    private var docsTitleLabel: NSTextField?
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
    private let runbookSaveButton = NSButton()
    private let runbookCancelButton = NSButton()
    private let runbookDeleteButton = NSButton()
    private let runbookEditorTitleLabel = NSTextField(labelWithString: "")

    // MARK: Postmortems

    private let postmortemsContainer = NSView()
    private let postmortemListScroll = NSScrollView()
    private let postmortemListStack = NSStackView()
    private let postmortemDetailScroll = NSScrollView()
    private let postmortemDetailTextView = NSTextView()
    private let postmortemEmptyLabel = NSTextField(wrappingLabelWithString: "No postmortems yet. These will appear here once SRE Lead's \u{201c}Generate Postmortem\u{201d} step is built - a later task.")
    private var selectedPostmortemID: String?

    // MARK: Search

    private let searchContainer = NSView()
    private let searchField = NSSearchField()
    private let searchResultsScroll = NSScrollView()
    private let searchResultsStack = NSStackView()
    private let searchEmptyLabel = NSTextField(labelWithString: "Type to search Runbooks and Postmortems.")

    // MARK: Command Composer

    private let composerContainer = NSView()

    private var theme: HelmTheme = ThemeManager.shared.theme

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 720))
        root.wantsLayer = true
        view = root

        let tabBar = buildTabBar()
        root.addSubview(tabBar)

        buildPlaybookContainer()
        buildRunbooksContainer()
        buildPostmortemsContainer()
        buildSearchContainer()
        buildComposerContainer()

        for container in [playbookContainer, runbooksContainer, postmortemsContainer, searchContainer, composerContainer] {
            container.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(container)
            NSLayoutConstraint.activate([
                container.leadingAnchor.constraint(equalTo: root.leadingAnchor),
                container.trailingAnchor.constraint(equalTo: root.trailingAnchor),
                container.topAnchor.constraint(equalTo: tabBar.bottomAnchor),
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

    // MARK: Tab bar

    private func buildTabBar() -> NSView {
        let bar = NSView()
        bar.translatesAutoresizingMaskIntoConstraints = false
        bar.wantsLayer = true

        let divider = NSView()
        divider.wantsLayer = true
        divider.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(divider)
        self.tabBarDivider = divider

        var items: [NSView] = []
        for tab in DocsTab.allCases {
            let pill = HoverHighlightView()
            let label = NSTextField(labelWithString: tab.title)
            label.font = .systemFont(ofSize: 12, weight: .medium)
            label.translatesAutoresizingMaskIntoConstraints = false
            pill.cornerRadius = 7
            pill.translatesAutoresizingMaskIntoConstraints = false
            pill.addSubview(label)
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: pill.leadingAnchor, constant: 10),
                label.trailingAnchor.constraint(equalTo: pill.trailingAnchor, constant: -10),
                label.topAnchor.constraint(equalTo: pill.topAnchor, constant: 6),
                label.bottomAnchor.constraint(equalTo: pill.bottomAnchor, constant: -6),
            ])
            let sleeve = ClosureSleeve { [weak self] in self?.showTab(tab) }
            rowSleeves.append(sleeve)
            let click = NSClickGestureRecognizer(target: sleeve, action: #selector(ClosureSleeve.invoke))
            pill.addGestureRecognizer(click)
            tabPills[tab] = pill
            tabLabels[tab] = label
            items.append(pill)
        }

        let row = NSStackView(views: items)
        row.orientation = .horizontal
        row.spacing = 6
        row.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(row)

        NSLayoutConstraint.activate([
            bar.heightAnchor.constraint(equalToConstant: 44),
            divider.leadingAnchor.constraint(equalTo: bar.leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: bar.trailingAnchor),
            divider.bottomAnchor.constraint(equalTo: bar.bottomAnchor),
            divider.heightAnchor.constraint(equalToConstant: 1),
            row.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 12),
            row.centerYAnchor.constraint(equalTo: bar.centerYAnchor, constant: -1),
        ])

        bar.topAnchor.constraint(equalTo: view.topAnchor).isActive = true
        bar.leadingAnchor.constraint(equalTo: view.leadingAnchor).isActive = true
        bar.trailingAnchor.constraint(equalTo: view.trailingAnchor).isActive = true
        return bar
    }

    private var tabBarDivider: NSView?

    private func showTab(_ tab: DocsTab) {
        activeTab = tab
        playbookContainer.isHidden = tab != .playbook
        runbooksContainer.isHidden = tab != .runbooks
        postmortemsContainer.isHidden = tab != .postmortems
        searchContainer.isHidden = tab != .search
        composerContainer.isHidden = tab != .composer
        if tab == .runbooks { reloadRunbooksList() }
        if tab == .postmortems { reloadPostmortemsList() }
        applyTheme()
    }

    // MARK: Playbook (unchanged behavior from before this task)

    private func buildPlaybookContainer() {
        let config = WKWebViewConfiguration()
        webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = self
        webView.translatesAutoresizingMaskIntoConstraints = false

        buildPlaybookToolbar()
        buildEmptyState()

        playbookContainer.addSubview(playbookToolbar)
        playbookContainer.addSubview(webView)
        playbookContainer.addSubview(emptyStateContainer)
        playbookToolbar.translatesAutoresizingMaskIntoConstraints = false
        emptyStateContainer.translatesAutoresizingMaskIntoConstraints = false

        toolbarDivider.wantsLayer = true
        toolbarDivider.translatesAutoresizingMaskIntoConstraints = false
        playbookToolbar.addSubview(toolbarDivider)
        NSLayoutConstraint.activate([
            toolbarDivider.leadingAnchor.constraint(equalTo: playbookToolbar.leadingAnchor),
            toolbarDivider.trailingAnchor.constraint(equalTo: playbookToolbar.trailingAnchor),
            toolbarDivider.bottomAnchor.constraint(equalTo: playbookToolbar.bottomAnchor),
            toolbarDivider.heightAnchor.constraint(equalToConstant: 1),
        ])

        NSLayoutConstraint.activate([
            playbookToolbar.leadingAnchor.constraint(equalTo: playbookContainer.leadingAnchor),
            playbookToolbar.trailingAnchor.constraint(equalTo: playbookContainer.trailingAnchor),
            playbookToolbar.topAnchor.constraint(equalTo: playbookContainer.topAnchor),
            playbookToolbar.heightAnchor.constraint(equalToConstant: 40),

            webView.leadingAnchor.constraint(equalTo: playbookContainer.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: playbookContainer.trailingAnchor),
            webView.topAnchor.constraint(equalTo: playbookToolbar.bottomAnchor),
            webView.bottomAnchor.constraint(equalTo: playbookContainer.bottomAnchor),

            emptyStateContainer.leadingAnchor.constraint(equalTo: playbookContainer.leadingAnchor),
            emptyStateContainer.trailingAnchor.constraint(equalTo: playbookContainer.trailingAnchor),
            emptyStateContainer.topAnchor.constraint(equalTo: playbookToolbar.bottomAnchor),
            emptyStateContainer.bottomAnchor.constraint(equalTo: playbookContainer.bottomAnchor),
        ])
    }

    private func buildPlaybookToolbar() {
        backButton = makeIconButton(symbol: "chevron.left", tooltip: "Back", action: #selector(backTapped))
        forwardButton = makeIconButton(symbol: "chevron.right", tooltip: "Forward", action: #selector(forwardTapped))
        reloadButton = makeIconButton(symbol: "arrow.clockwise", tooltip: "Reload (local copy only)", action: #selector(reloadTapped))
        let navTools = NSStackView(views: [backButton, forwardButton, reloadButton])
        navTools.orientation = .horizontal
        navTools.spacing = 2
        navTools.translatesAutoresizingMaskIntoConstraints = false

        let titleLabel = NSTextField(labelWithString: "DevOps Playbook")
        titleLabel.font = .systemFont(ofSize: 12.5, weight: .semibold)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        self.docsTitleLabel = titleLabel

        openLiveButton.title = "Open Live Site"
        openLiveButton.image = NSImage(systemSymbolName: "arrow.up.forward.square", accessibilityDescription: nil)
        openLiveButton.imagePosition = .imageLeading
        openLiveButton.bezelStyle = .rounded
        openLiveButton.controlSize = .small
        openLiveButton.target = self
        openLiveButton.action = #selector(openLiveTapped)
        openLiveButton.translatesAutoresizingMaskIntoConstraints = false

        playbookToolbar.addSubview(navTools)
        playbookToolbar.addSubview(titleLabel)
        playbookToolbar.addSubview(openLiveButton)
        NSLayoutConstraint.activate([
            navTools.leadingAnchor.constraint(equalTo: playbookToolbar.leadingAnchor, constant: 10),
            navTools.centerYAnchor.constraint(equalTo: playbookToolbar.centerYAnchor),

            titleLabel.leadingAnchor.constraint(equalTo: navTools.trailingAnchor, constant: 12),
            titleLabel.centerYAnchor.constraint(equalTo: playbookToolbar.centerYAnchor),

            openLiveButton.trailingAnchor.constraint(equalTo: playbookToolbar.trailingAnchor, constant: -10),
            openLiveButton.centerYAnchor.constraint(equalTo: playbookToolbar.centerYAnchor),
        ])
    }

    private func makeIconButton(symbol: String, tooltip: String, action: Selector) -> NSButton {
        let b = NSButton(title: "", target: self, action: action)
        b.isBordered = false
        b.wantsLayer = true
        b.layer?.cornerRadius = 6
        b.toolTip = tooltip
        b.imageScaling = .scaleProportionallyDown
        b.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)
        NSLayoutConstraint.activate([
            b.widthAnchor.constraint(equalToConstant: 28),
            b.heightAnchor.constraint(equalToConstant: 26),
        ])
        return b
    }

    @objc private func backTapped() { webView.goBack() }
    @objc private func forwardTapped() { webView.goForward() }
    @objc private func reloadTapped() { loadDocsIfAvailable() }
    @objc private func openLiveTapped() { NSWorkspace.shared.open(Self.liveSiteURL) }

    private func updateNavButtons() {
        backButton.isEnabled = webView.canGoBack
        forwardButton.isEnabled = webView.canGoForward
    }

    private func buildEmptyState() {
        emptyIcon.image = NSImage(systemSymbolName: "book.closed", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 34, weight: .light))
        emptyIcon.translatesAutoresizingMaskIntoConstraints = false

        emptyTitleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        emptyTitleLabel.alignment = .center
        emptyTitleLabel.translatesAutoresizingMaskIntoConstraints = false

        emptyBodyLabel.font = .systemFont(ofSize: 12)
        emptyBodyLabel.alignment = .center
        emptyBodyLabel.preferredMaxLayoutWidth = 360
        emptyBodyLabel.translatesAutoresizingMaskIntoConstraints = false

        syncButton.title = "Sync Now"
        syncButton.bezelStyle = .rounded
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

        let stack = NSStackView(views: [emptyIcon, emptyTitleLabel, emptyBodyLabel, actionRow])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.setCustomSpacing(16, after: emptyBodyLabel)

        emptyStateContainer.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: emptyStateContainer.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: emptyStateContainer.centerYAnchor),
            stack.widthAnchor.constraint(lessThanOrEqualTo: emptyStateContainer.widthAnchor, constant: -80),
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
        let header = NSTextField(labelWithString: "Runbooks")
        header.font = .systemFont(ofSize: 15, weight: .semibold)
        header.translatesAutoresizingMaskIntoConstraints = false
        runbooksHeaderCountLabel.font = .systemFont(ofSize: 11, weight: .medium)
        runbooksHeaderCountLabel.translatesAutoresizingMaskIntoConstraints = false

        let newButton = NSButton(title: "+ New Runbook", target: nil, action: nil)
        newButton.bezelStyle = .rounded
        newButton.controlSize = .small
        let newSleeve = ClosureSleeve { [weak self] in self?.beginNewRunbook() }
        rowSleeves.append(newSleeve)
        newButton.target = newSleeve
        newButton.action = #selector(ClosureSleeve.invoke)
        newButton.translatesAutoresizingMaskIntoConstraints = false

        let headerRow = NSStackView(views: [header, runbooksHeaderCountLabel, NSView(), newButton])
        headerRow.orientation = .horizontal
        headerRow.alignment = .centerY
        headerRow.spacing = 8
        headerRow.translatesAutoresizingMaskIntoConstraints = false

        runbookListStack.orientation = .vertical
        runbookListStack.alignment = .leading
        runbookListStack.spacing = 8
        runbookListStack.translatesAutoresizingMaskIntoConstraints = false

        let listContent = NSView()
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
        listContent.widthAnchor.constraint(equalTo: runbookListScroll.contentView.widthAnchor).isActive = true

        let listStack = NSStackView(views: [headerRow, runbookListScroll])
        listStack.orientation = .vertical
        listStack.alignment = .leading
        listStack.spacing = 12
        listStack.translatesAutoresizingMaskIntoConstraints = false

        buildRunbookEditor()

        runbooksContainer.addSubview(listStack)
        runbooksContainer.addSubview(runbookEditorContainer)
        NSLayoutConstraint.activate([
            listStack.leadingAnchor.constraint(equalTo: runbooksContainer.leadingAnchor, constant: 18),
            listStack.trailingAnchor.constraint(equalTo: runbooksContainer.trailingAnchor, constant: -18),
            listStack.topAnchor.constraint(equalTo: runbooksContainer.topAnchor, constant: 16),
            listStack.bottomAnchor.constraint(equalTo: runbooksContainer.bottomAnchor, constant: -16),
            headerRow.widthAnchor.constraint(equalTo: listStack.widthAnchor),
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
        runbookSaveButton.bezelStyle = .rounded
        runbookSaveButton.keyEquivalent = "\r"
        let saveSleeve = ClosureSleeve { [weak self] in self?.saveRunbookEditor() }
        rowSleeves.append(saveSleeve)
        runbookSaveButton.target = saveSleeve
        runbookSaveButton.action = #selector(ClosureSleeve.invoke)
        runbookSaveButton.translatesAutoresizingMaskIntoConstraints = false

        runbookCancelButton.title = "Cancel"
        runbookCancelButton.bezelStyle = .rounded
        let cancelSleeve = ClosureSleeve { [weak self] in self?.cancelRunbookEditor() }
        rowSleeves.append(cancelSleeve)
        runbookCancelButton.target = cancelSleeve
        runbookCancelButton.action = #selector(ClosureSleeve.invoke)
        runbookCancelButton.translatesAutoresizingMaskIntoConstraints = false

        runbookDeleteButton.title = "Delete"
        runbookDeleteButton.bezelStyle = .rounded
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
        runbookListStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let runbooks = runbookStore.listRunbooks()
        runbooksHeaderCountLabel.stringValue = "\(runbooks.count)"
        if runbooks.isEmpty {
            let empty = NSTextField(labelWithString: "No runbooks yet. Create one to get started.")
            empty.textColor = HelmTheme.mutedInk(theme)
            empty.font = .systemFont(ofSize: 12)
            runbookListStack.addArrangedSubview(empty)
        }
        for runbook in runbooks {
            let row = buildDocRow(
                title: runbook.title,
                subtitle: "Updated \(Self.relativeDate(runbook.modifiedAt))",
                icon: "doc.text",
                tint: .info,
                onOpen: { [weak self] in self?.beginEditRunbook(runbook.id) },
                onDelete: { [weak self] in self?.confirmDeleteRunbook(id: runbook.id, title: runbook.title) }
            )
            runbookListStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: runbookListStack.widthAnchor).isActive = true
        }
        applyTheme()
    }

    private func beginNewRunbook() {
        editingIsNew = true
        editingRunbookID = nil
        runbookEditorTitleLabel.stringValue = "New Runbook"
        runbookTitleField.stringValue = ""
        runbookBodyTextView.string = ""
        runbookDeleteButton.isHidden = true
        runbookEditorContainer.isHidden = false
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
        runbookEditorContainer.isHidden = false
    }

    private func cancelRunbookEditor() {
        runbookEditorContainer.isHidden = true
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
        let header = NSTextField(labelWithString: "Postmortems")
        header.font = .systemFont(ofSize: 15, weight: .semibold)
        header.translatesAutoresizingMaskIntoConstraints = false

        postmortemListStack.orientation = .vertical
        postmortemListStack.alignment = .leading
        postmortemListStack.spacing = 8
        postmortemListStack.translatesAutoresizingMaskIntoConstraints = false

        let listContent = NSView()
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
        listContent.widthAnchor.constraint(equalTo: postmortemListScroll.contentView.widthAnchor).isActive = true

        postmortemEmptyLabel.font = .systemFont(ofSize: 12)
        postmortemEmptyLabel.preferredMaxLayoutWidth = 420
        postmortemEmptyLabel.translatesAutoresizingMaskIntoConstraints = false

        postmortemDetailTextView.isEditable = false
        postmortemDetailTextView.isRichText = false
        postmortemDetailTextView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        postmortemDetailTextView.textContainerInset = NSSize(width: 8, height: 8)
        postmortemDetailScroll.documentView = postmortemDetailTextView
        postmortemDetailScroll.hasVerticalScroller = true
        postmortemDetailScroll.borderType = .lineBorder
        postmortemDetailScroll.translatesAutoresizingMaskIntoConstraints = false
        postmortemDetailScroll.isHidden = true

        let stack = NSStackView(views: [header, postmortemEmptyLabel, postmortemListScroll, postmortemDetailScroll])
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
        postmortemListStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let postmortems = runbookStore.listPostmortems()
        postmortemEmptyLabel.isHidden = !postmortems.isEmpty
        postmortemListScroll.isHidden = postmortems.isEmpty
        for postmortem in postmortems {
            let row = buildDocRow(
                title: postmortem.title,
                subtitle: "Updated \(Self.relativeDate(postmortem.modifiedAt))",
                icon: "exclamationmark.triangle",
                tint: .warn,
                onOpen: { [weak self] in self?.showPostmortem(postmortem.id) },
                onDelete: nil
            )
            postmortemListStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: postmortemListStack.widthAnchor).isActive = true
        }
        if selectedPostmortemID == nil {
            postmortemDetailScroll.isHidden = true
        }
        applyTheme()
    }

    private func showPostmortem(_ id: String) {
        guard let postmortem = runbookStore.listPostmortems().first(where: { $0.id == id }) else { return }
        selectedPostmortemID = id
        postmortemDetailTextView.string = postmortem.content
        postmortemDetailScroll.isHidden = false
    }

    // MARK: Search

    private func buildSearchContainer() {
        let header = NSTextField(labelWithString: "Search")
        header.font = .systemFont(ofSize: 15, weight: .semibold)
        header.translatesAutoresizingMaskIntoConstraints = false

        searchField.placeholderString = "Search runbooks and postmortems\u{2026}"
        searchField.target = self
        searchField.action = #selector(searchFieldChanged)
        searchField.delegate = self
        searchField.translatesAutoresizingMaskIntoConstraints = false

        searchEmptyLabel.font = .systemFont(ofSize: 12)
        searchEmptyLabel.translatesAutoresizingMaskIntoConstraints = false

        searchResultsStack.orientation = .vertical
        searchResultsStack.alignment = .leading
        searchResultsStack.spacing = 8
        searchResultsStack.translatesAutoresizingMaskIntoConstraints = false

        let resultsContent = NSView()
        resultsContent.translatesAutoresizingMaskIntoConstraints = false
        resultsContent.addSubview(searchResultsStack)
        NSLayoutConstraint.activate([
            searchResultsStack.leadingAnchor.constraint(equalTo: resultsContent.leadingAnchor),
            searchResultsStack.trailingAnchor.constraint(equalTo: resultsContent.trailingAnchor),
            searchResultsStack.topAnchor.constraint(equalTo: resultsContent.topAnchor),
            searchResultsStack.bottomAnchor.constraint(lessThanOrEqualTo: resultsContent.bottomAnchor),
        ])
        searchResultsScroll.documentView = resultsContent
        searchResultsScroll.hasVerticalScroller = true
        searchResultsScroll.drawsBackground = false
        searchResultsScroll.translatesAutoresizingMaskIntoConstraints = false
        resultsContent.widthAnchor.constraint(equalTo: searchResultsScroll.contentView.widthAnchor).isActive = true

        let stack = NSStackView(views: [header, searchField, searchEmptyLabel, searchResultsScroll])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false

        searchContainer.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: searchContainer.leadingAnchor, constant: 18),
            stack.trailingAnchor.constraint(equalTo: searchContainer.trailingAnchor, constant: -18),
            stack.topAnchor.constraint(equalTo: searchContainer.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(equalTo: searchContainer.bottomAnchor, constant: -16),
            searchField.widthAnchor.constraint(equalTo: stack.widthAnchor),
            searchResultsScroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
    }

    @objc private func searchFieldChanged() { runSearch() }

    private func runSearch() {
        let query = searchField.stringValue
        searchResultsStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let results = DocsKnowledgeSearch.search(query: query, store: runbookStore)
        searchEmptyLabel.stringValue = query.trimmingCharacters(in: .whitespaces).isEmpty
            ? "Type to search Runbooks and Postmortems."
            : "No matches for \u{201c}\(query)\u{201d}."
        searchEmptyLabel.isHidden = !results.isEmpty
        for result in results {
            let row = buildDocRow(
                title: "[\(result.scope.rawValue)] \(result.runbook.title)",
                subtitle: result.snippet,
                icon: result.scope == .runbook ? "doc.text" : "exclamationmark.triangle",
                tint: result.scope == .runbook ? .info : .warn,
                onOpen: { [weak self] in self?.openSearchResult(result) },
                onDelete: nil
            )
            searchResultsStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: searchResultsStack.widthAnchor).isActive = true
        }
        applyTheme()
    }

    private func openSearchResult(_ result: DocsKnowledgeSearchResult) {
        switch result.scope {
        case .runbook:
            showTab(.runbooks)
            beginEditRunbook(result.runbook.id)
        case .postmortem:
            showTab(.postmortems)
            showPostmortem(result.runbook.id)
        }
    }

    // MARK: Command Composer

    private func buildComposerContainer() {
        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: "wand.and.stars", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 34, weight: .light))
        icon.translatesAutoresizingMaskIntoConstraints = false

        let title = NSTextField(labelWithString: "Command Composer")
        title.font = .systemFont(ofSize: 16, weight: .semibold)
        title.alignment = .center
        title.translatesAutoresizingMaskIntoConstraints = false

        let body = NSTextField(wrappingLabelWithString: "Describe your intent, review the generated command, and run it - right in Console, not here. This tab is a preview of what's coming; the composer itself is a separate, Console-focused task.")
        body.font = .systemFont(ofSize: 12.5)
        body.alignment = .center
        body.preferredMaxLayoutWidth = 420
        body.translatesAutoresizingMaskIntoConstraints = false

        let pillLabel = NSTextField(labelWithString: "Coming soon")
        let pill = NSView()
        ToolRowLayout.pill(text: "Coming soon", colorHex: theme.ansiHex[3], into: pill, label: pillLabel)

        let stack = NSStackView(views: [icon, title, body, pill])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.setCustomSpacing(16, after: body)

        composerContainer.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: composerContainer.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: composerContainer.centerYAnchor),
            stack.widthAnchor.constraint(lessThanOrEqualTo: composerContainer.widthAnchor, constant: -80),
        ])
        composerIcon = icon
        composerTitle = title
        composerBody = body
        composerPill = pill
        composerPillLabel = pillLabel
    }

    private var composerIcon: NSImageView?
    private var composerTitle: NSTextField?
    private var composerBody: NSTextField?
    private var composerPill: NSView?
    private var composerPillLabel: NSTextField?

    // MARK: Shared row builder (Runbooks/Postmortems/Search results)

    private func buildDocRow(title: String, subtitle: String, icon: String, tint: HelmTint, onOpen: @escaping () -> Void, onDelete: (() -> Void)?) -> NSView {
        let iconTile = IconTileView()
        iconTile.configure(symbol: icon, tint: tint)

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1

        let subtitleLabel = NSTextField(labelWithString: subtitle)
        subtitleLabel.font = .systemFont(ofSize: 10.5)
        subtitleLabel.lineBreakMode = .byTruncatingTail
        subtitleLabel.maximumNumberOfLines = 1
        subtitleLabel.textColor = HelmTheme.mutedInk(theme)

        let textStack = NSStackView(views: [titleLabel, subtitleLabel])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 2
        textStack.setContentHuggingPriority(.defaultLow, for: .horizontal)
        textStack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        var rowViews: [NSView] = [iconTile, textStack]
        if let onDelete {
            let deleteButton = NSButton(title: "", target: nil, action: nil)
            deleteButton.isBordered = false
            deleteButton.image = NSImage(systemSymbolName: "trash", accessibilityDescription: "Delete")
            let sleeve = ClosureSleeve(onDelete)
            rowSleeves.append(sleeve)
            deleteButton.target = sleeve
            deleteButton.action = #selector(ClosureSleeve.invoke)
            deleteButton.setContentHuggingPriority(.required, for: .horizontal)
            rowViews.append(deleteButton)
        }

        let row = NSStackView(views: rowViews)
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        row.distribution = .fill
        row.translatesAutoresizingMaskIntoConstraints = false

        let container = HoverHighlightView()
        container.cornerRadius = 8
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 10),
            row.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -10),
            row.topAnchor.constraint(equalTo: container.topAnchor, constant: 8),
            row.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -8),
        ])
        let openSleeve = ClosureSleeve(onOpen)
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
        let accent = HelmTheme.nsColor(theme.accentHex)

        for container in [playbookContainer, runbooksContainer, postmortemsContainer, searchContainer, composerContainer] {
            container.wantsLayer = true
            container.layer?.backgroundColor = HelmTheme.nsColor(theme.backgroundHex).cgColor
        }

        playbookToolbar.wantsLayer = true
        playbookToolbar.layer?.backgroundColor = surface.cgColor
        docsTitleLabel?.textColor = ink
        for b in [backButton, forwardButton, reloadButton] {
            b?.contentTintColor = ink.withAlphaComponent(0.75)
        }
        emptyIcon.contentTintColor = muted
        emptyTitleLabel.textColor = ink
        emptyBodyLabel.textColor = muted
        emptyStateContainer.wantsLayer = true
        emptyStateContainer.layer?.backgroundColor = HelmTheme.nsColor(theme.backgroundHex).cgColor
        toolbarDivider.layer?.backgroundColor = line.withAlphaComponent(0.5).cgColor
        tabBarDivider?.layer?.backgroundColor = line.withAlphaComponent(0.5).cgColor

        let accentTint = accent.withAlphaComponent(theme.mode == .dark ? 0.20 : 0.14)
        for tab in DocsTab.allCases {
            guard let pill = tabPills[tab], let label = tabLabels[tab] else { continue }
            let isActive = tab == activeTab
            pill.normalColor = isActive ? accentTint : .clear
            pill.hoverColor = isActive ? accentTint : line.withAlphaComponent(0.25)
            label.textColor = isActive ? accent : muted
            label.font = .systemFont(ofSize: 12, weight: isActive ? .semibold : .medium)
        }

        runbooksHeaderCountLabel.textColor = muted
        runbookEditorTitleLabel.textColor = ink
        runbookBodyTextView.textColor = ink
        runbookBodyTextView.backgroundColor = surface
        postmortemEmptyLabel.textColor = muted
        postmortemDetailTextView.textColor = ink
        postmortemDetailTextView.backgroundColor = surface
        searchEmptyLabel.textColor = muted

        composerIcon?.contentTintColor = muted
        composerTitle?.textColor = ink
        composerBody?.textColor = muted
        if let pill = composerPill, let label = composerPillLabel {
            ToolRowLayout.pill(text: "Coming soon", colorHex: theme.ansiHex[3], into: pill, label: label)
        }

        for stack in [runbookListStack, postmortemListStack, searchResultsStack] {
            for row in stack.arrangedSubviews {
                guard let hover = row as? HoverHighlightView else { continue }
                hover.normalColor = .clear
                hover.hoverColor = line.withAlphaComponent(0.18)
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

extension DocsController: NSSearchFieldDelegate {
    func controlTextDidChange(_ obj: Notification) {
        guard obj.object as? NSSearchField === searchField else { return }
        runSearch()
    }
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
