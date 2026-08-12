// Manjesh Grand Line - native macOS app.
//
// "Tools" (cockpit-tools-page-core), phase 1 of 3 of a captain-reviewed
// HTML mockup for everyday DevOps utilities. Six genuinely functional tools:
// YAML validate/beautify, JSON validate/beautify, Base64 encode/decode, JWT
// decode, a Unix timestamp converter, and (phase 2, cockpit-tools-page-diff)
// a Mergely-style diff. A certificate inspector, cron explainer, and
// resource-unit converter (phase 3) are intentionally deferred - not built
// here.
//
// `fm/cockpit-tools-page-multi-session` (phase 4) gave this page a tab strip
// mirroring Console's ([TabModel] + TabChipView, see ConsoleController.swift)
// so a captain can hold several independent instances of a tool open at
// once - three separate Diff sessions comparing different things, each with
// its own inputs/output. `ToolsController` now only owns the tab strip, the
// landing-grid "pick a tool to open" picker, and which tab's view is
// currently shown; each tab's actual tool logic lives in its own
// `ToolInstance` (see ToolInstance.swift) - the same split Console already
// has between `ConsoleController` (tab lifecycle/chrome) and `TabModel`
// (one tab's own state).
//
// The landing grid is reused as the tool picker for New (⌘T): it's shown
// whenever there are no tabs, or after clicking the tab bar's "+" - clicking
// a card there always opens a *new* tab of that kind (never re-selects an
// existing one), matching the literal "open a new browser tab" mental model
// the captain asked for. Duplicate (⌘D) copies the current tab's kind AND
// its current input content into a new tab (`ToolInstance.snapshotContent`/
// `restoreContent`). Close (⌘W) closes one tab; closing the last tab
// returns to the picker - Tools' equivalent of Console's "never leave the
// window empty" rule, since the picker (not a blank tool) is this page's
// natural empty state.

import AppKit

enum ToolKind: String, CaseIterable {
    case yaml, json, base64, jwt, timestamp, diff

    var title: String {
        switch self {
        case .yaml: return "YAML Validate & Beautify"
        case .json: return "JSON Validate & Beautify"
        case .base64: return "Base64 Encode/Decode"
        case .jwt: return "JWT Decoder"
        case .timestamp: return "Unix Timestamp Converter"
        case .diff: return "Diff"
        }
    }

    /// The tab-chip name for the first open instance of this kind - a second
    /// concurrent instance is "\(shortName) 2", a third "\(shortName) 3", etc.
    /// (`ToolsController.defaultName(for:)`).
    var shortName: String {
        switch self {
        case .yaml: return "YAML"
        case .json: return "JSON"
        case .base64: return "Base64"
        case .jwt: return "JWT"
        case .timestamp: return "Timestamp"
        case .diff: return "Diff"
        }
    }

    var description: String {
        switch self {
        case .yaml: return "Check a YAML document (or multi-resource manifest) for errors, or reformat it."
        case .json: return "Check a JSON document for errors, or reformat it with consistent indentation."
        case .base64: return "Encode plain text to Base64, or decode a Base64 string back to text."
        case .jwt: return "Inspect a JWT's header and payload claims - no signature verification."
        case .timestamp: return "Convert a Unix epoch to a human-readable date, and back."
        case .diff: return "Compare two blocks of text side by side, with word-level highlighting."
        }
    }

    var symbol: String {
        switch self {
        case .yaml: return "doc.text"
        case .json: return "curlybraces"
        case .base64: return "textformat.abc"
        case .jwt: return "key"
        case .timestamp: return "clock"
        case .diff: return "arrow.left.arrow.right"
        }
    }

    var tint: HelmTint {
        switch self {
        case .yaml: return .info
        case .json: return .warn
        case .base64: return .good
        case .jwt: return .violet
        case .timestamp: return .accent
        case .diff: return .neutral
        }
    }
}

final class ToolsController: NSViewController {

    private var theme: HelmTheme = ThemeManager.shared.theme

    // MARK: Tabs

    private var tabs: [ToolInstance] = []
    private var currentTab: ToolInstance?
    /// True when the landing-grid picker is what's on screen, rather than a
    /// tab's panel - true whenever there are no open tabs, or right after
    /// the tab bar's "+" is clicked.
    private var pickerShowing = true

    // MARK: Chrome

    private let tabBar = NSView()
    private let tabsStack = NSStackView()
    private var plusButton = NSButton()
    private let tabBarSeparator = NSView()

    private let subtitleLabel = NSTextField(labelWithString: "Everyday DevOps utilities - everything runs locally, nothing leaves this machine.")
    private let gridContainer = NSStackView()
    private var pageStack: NSStackView!
    private var scrollView: NSScrollView!

    // Re-themed collections for the landing grid only (each open tab themes
    // itself via `ToolInstance.applyTheme`).
    private var cardIconTiles: [IconTileView] = []
    private var cardBorderViews: [HoverHighlightView] = []
    private var mutedLabels: [NSTextField] = []

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 720))
        root.wantsLayer = true
        view = root

        buildTabBar()

        subtitleLabel.font = .systemFont(ofSize: 12)
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false

        gridContainer.orientation = .vertical
        gridContainer.alignment = .leading
        gridContainer.spacing = 10
        gridContainer.translatesAutoresizingMaskIntoConstraints = false
        rebuildGrid()

        let stack = NSStackView(views: [subtitleLabel, gridContainer])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        subtitleLabel.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        gridContainer.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        pageStack = stack

        let content = FlippedView()
        content.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 18),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
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
            scroll.topAnchor.constraint(equalTo: tabBar.bottomAnchor),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            content.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
        ])
        scrollView = scroll

        ThemeManager.shared.observe { [weak root, weak self] theme in
            root?.appearance = NSAppearance(named: theme.mode == .dark ? .darkAqua : .aqua)
            root?.layer?.backgroundColor = HelmTheme.nsColor(theme.backgroundHex).cgColor
            self?.theme = theme
            self?.applyTheme()
        }

        showPicker()
        applyTheme()
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        scrollToTop()
    }

    private func scrollToTop() {
        scrollView?.contentView.scroll(to: .zero)
        scrollView?.reflectScrolledClipView(scrollView.contentView)
    }

    // MARK: Tab bar chrome (mirrors ConsoleController.buildTabBar)

    private func buildTabBar() {
        tabBar.translatesAutoresizingMaskIntoConstraints = false
        tabBar.wantsLayer = true
        view.addSubview(tabBar)

        tabBarSeparator.translatesAutoresizingMaskIntoConstraints = false
        tabBarSeparator.wantsLayer = true
        tabBar.addSubview(tabBarSeparator)

        tabsStack.orientation = .horizontal
        tabsStack.spacing = 4
        tabsStack.alignment = .centerY
        tabsStack.translatesAutoresizingMaskIntoConstraints = false
        tabBar.addSubview(tabsStack)

        plusButton = NSButton(title: "", target: self, action: #selector(newShellTab))
        plusButton.isBordered = false
        plusButton.wantsLayer = true
        plusButton.layer?.cornerRadius = 6
        plusButton.toolTip = "New Tool Tab (⌘T)"
        plusButton.imageScaling = .scaleProportionallyDown
        plusButton.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "New Tool Tab")
        NSLayoutConstraint.activate([
            plusButton.widthAnchor.constraint(equalToConstant: 30),
            plusButton.heightAnchor.constraint(equalToConstant: 26),
        ])

        NSLayoutConstraint.activate([
            tabBar.heightAnchor.constraint(equalToConstant: 42),
            tabBarSeparator.leadingAnchor.constraint(equalTo: tabBar.leadingAnchor),
            tabBarSeparator.trailingAnchor.constraint(equalTo: tabBar.trailingAnchor),
            tabBarSeparator.bottomAnchor.constraint(equalTo: tabBar.bottomAnchor),
            tabBarSeparator.heightAnchor.constraint(equalToConstant: 1),

            tabsStack.leadingAnchor.constraint(equalTo: tabBar.leadingAnchor, constant: 12),
            tabsStack.centerYAnchor.constraint(equalTo: tabBar.centerYAnchor),
            tabsStack.trailingAnchor.constraint(lessThanOrEqualTo: tabBar.trailingAnchor, constant: -12),
        ])
        NSLayoutConstraint.activate([
            tabBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tabBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tabBar.topAnchor.constraint(equalTo: view.topAnchor),
        ])
    }

    private func refreshTabBar() {
        for v in tabsStack.arrangedSubviews {
            tabsStack.removeArrangedSubview(v)
            v.removeFromSuperview()
        }
        for tab in tabs {
            tabsStack.addArrangedSubview(tab.chip)
        }
        tabsStack.addArrangedSubview(plusButton)
        styleChips()
    }

    // MARK: Landing grid <-> tab panel swap

    private func rebuildGrid() {
        for v in gridContainer.arrangedSubviews {
            gridContainer.removeArrangedSubview(v)
            v.removeFromSuperview()
        }
        let columnsPerRow = 3
        for chunk in ToolKind.allCases.chunked(into: columnsPerRow) {
            let row = NSStackView(views: chunk.map { toolCard($0) })
            row.orientation = .horizontal
            row.spacing = 10
            row.translatesAutoresizingMaskIntoConstraints = false
            gridContainer.addArrangedSubview(row)
        }
    }

    private func showPicker() {
        pickerShowing = true
        gridContainer.isHidden = false
        for tab in tabs { tab.view.isHidden = true }
        styleChips()
    }

    private func showTab(_ tab: ToolInstance) {
        pickerShowing = false
        gridContainer.isHidden = true
        for t in tabs { t.view.isHidden = (t !== tab) }
        styleChips()
    }

    @objc private func toolCardClicked(_ sender: NSClickGestureRecognizer) {
        guard let raw = sender.view?.identifier?.rawValue, let kind = ToolKind(rawValue: raw) else { return }
        openNewTab(kind: kind)
    }

    // MARK: Landing grid card

    private func toolCard(_ kind: ToolKind) -> NSView {
        let tile = IconTileView()
        tile.configure(symbol: kind.symbol, tint: kind.tint)
        cardIconTiles.append(tile)

        let titleLabel = NSTextField(labelWithString: kind.title)
        titleLabel.font = .systemFont(ofSize: 12.5, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail

        let descLabel = NSTextField(wrappingLabelWithString: kind.description)
        descLabel.font = .systemFont(ofSize: 10.5)
        descLabel.preferredMaxLayoutWidth = 220
        mutedLabels.append(descLabel)

        let textStack = NSStackView(views: [titleLabel, descLabel])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 3
        textStack.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let row = NSStackView(views: [tile, textStack])
        row.orientation = .horizontal
        row.alignment = .top
        row.spacing = 10
        row.translatesAutoresizingMaskIntoConstraints = false

        let card = HoverHighlightView()
        card.cornerRadius = 10
        card.layer?.borderWidth = 1
        card.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 12),
            row.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -12),
            row.topAnchor.constraint(equalTo: card.topAnchor, constant: 12),
            row.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -12),
            card.widthAnchor.constraint(equalToConstant: 268),
        ])
        cardBorderViews.append(card)

        let click = NSClickGestureRecognizer(target: self, action: #selector(toolCardClicked(_:)))
        card.addGestureRecognizer(click)
        card.identifier = NSUserInterfaceItemIdentifier(kind.rawValue)
        return card
    }

    // MARK: Tab lifecycle

    /// "Diff" for the first open instance of a kind, "Diff 2" for the second
    /// concurrently open one, etc. - counts only currently-open tabs, so
    /// closing "Diff 2" and opening a new Diff tab reuses the name "Diff 2"
    /// rather than climbing to "Diff 3".
    private func defaultName(for kind: ToolKind) -> String {
        let existing = tabs.filter { $0.kind == kind }.count
        return existing == 0 ? kind.shortName : "\(kind.shortName) \(existing + 1)"
    }

    /// The tab bar's "+" (also reachable via the Tab menu's "New Tab" / ⌘T,
    /// which dispatches through the first-responder chain by selector name -
    /// `newShellTab` is `ConsoleController`'s selector for that exact menu
    /// item, and NSMenuItem action dispatch matches by selector, not by
    /// declaring class, so this method must keep that name to be reachable
    /// from the menu while the Tools page - not Console - has focus): show
    /// the picker so the captain can choose which tool to open next. It does
    /// not by itself create a tab.
    @objc func newShellTab() {
        showPicker()
    }

    /// Opens a brand-new, blank tab of `kind` and selects it - the picker's
    /// card-click action, always creating a new tab even if one of this kind
    /// is already open (that's the point: independent concurrent instances).
    @discardableResult
    private func openNewTab(kind: ToolKind) -> ToolInstance {
        let name = defaultName(for: kind)
        let instance = ToolInstance(kind: kind, name: name, theme: theme, toastHost: view)
        addTab(instance)
        return instance
    }

    private func addTab(_ instance: ToolInstance) {
        let chip = TabChipView(tabID: instance.id, name: instance.name)
        let id = instance.id
        chip.onSelect = { [weak self] in self?.selectTab(id: id) }
        chip.onClose = { [weak self] in self?.closeTab(id: id) }
        chip.onDuplicate = { [weak self] in self?.duplicateTab(id: id) }
        chip.onRename = { [weak self] newName in self?.renameTab(id: id, to: newName) }
        instance.chip = chip

        tabs.append(instance)
        instance.view.isHidden = true
        pageStack.addArrangedSubview(instance.view)
        instance.view.widthAnchor.constraint(equalTo: pageStack.widthAnchor).isActive = true

        refreshTabBar()
        selectTab(id: instance.id)
    }

    /// ⌘D: duplicate the current tab - same kind, same input content, a new
    /// independent tab. Never copies the source tab's output; the new tab
    /// recomputes that itself once the captain acts on it.
    @objc func duplicateCurrentTab() {
        if let tab = currentTab { duplicateTab(id: tab.id) }
    }

    private func duplicateTab(id: UUID) {
        guard let src = tabs.first(where: { $0.id == id }) else { return }
        let snapshot = src.snapshotContent()
        let copy = openNewTab(kind: src.kind)
        copy.restoreContent(snapshot)
    }

    /// ⌘W: close the current tab. Closing the last tab returns to the
    /// picker - this page's equivalent of Console's "never leave the window
    /// empty," since the picker is Tools' natural empty state rather than a
    /// blank tool panel.
    @objc func closeCurrentTab() {
        if let tab = currentTab { closeTab(id: tab.id) }
    }

    private func closeTab(id: UUID) {
        guard let idx = tabs.firstIndex(where: { $0.id == id }) else { return }
        let tab = tabs[idx]
        pageStack.removeArrangedSubview(tab.view)
        tab.view.removeFromSuperview()
        tabs.remove(at: idx)

        if tabs.isEmpty {
            currentTab = nil
            refreshTabBar()
            showPicker()
            return
        }

        refreshTabBar()
        if currentTab === tab || currentTab == nil {
            let neighbor = tabs[min(idx, tabs.count - 1)]
            selectTab(id: neighbor.id)
        } else {
            styleChips()
        }
    }

    /// ⌘⇧R / double-click / right-click -> Rename on the current tab's chip.
    @objc func renameCurrentTab() {
        currentTab?.chip.beginRename()
    }

    private func renameTab(id: UUID, to newName: String) {
        guard let tab = tabs.first(where: { $0.id == id }) else { return }
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        tab.name = trimmed.isEmpty ? defaultName(for: tab.kind) : trimmed
        tab.chip.setName(tab.name)
        styleChips()
    }

    /// ⌘1…⌘9: select the Nth open tab (menu items carry a 1-based tag).
    @objc func selectTabByShortcut(_ sender: NSMenuItem) {
        let idx = sender.tag - 1
        guard idx >= 0, idx < tabs.count else { return }
        selectTab(id: tabs[idx].id)
    }

    private func selectTab(id: UUID) {
        guard let tab = tabs.first(where: { $0.id == id }) else { return }
        currentTab = tab
        showTab(tab)
        scrollToTop()
    }

    // MARK: Theme

    private func applyTheme() {
        let ink = HelmTheme.nsColor(theme.chromeInkHex)
        let muted = HelmTheme.mutedInk(theme)
        let line = HelmTheme.nsColor(theme.chromeLineHex)
        let chromeBg = HelmTheme.nsColor(theme.chromeBackgroundHex)

        view.layer?.backgroundColor = HelmTheme.nsColor(theme.backgroundHex).cgColor
        tabBar.layer?.backgroundColor = chromeBg.cgColor
        tabBarSeparator.layer?.backgroundColor = line.cgColor
        plusButton.contentTintColor = ink

        subtitleLabel.textColor = muted

        for tile in cardIconTiles { tile.applyTheme(theme) }
        for label in mutedLabels { label.textColor = muted }
        for card in cardBorderViews {
            card.normalColor = .clear
            card.hoverColor = line.withAlphaComponent(0.18)
            card.layer?.borderColor = line.withAlphaComponent(0.5).cgColor
        }

        for tab in tabs { tab.applyTheme(theme) }
        styleChips()
    }

    private func styleChips() {
        let accent = HelmTheme.nsColor(theme.accentHex)
        let ink = HelmTheme.nsColor(theme.chromeInkHex)
        let muted = ink.withAlphaComponent(0.55)
        for tab in tabs {
            let selected = !pickerShowing && tab === currentTab
            let tint = accent.withAlphaComponent(theme.mode == .dark ? 0.20 : 0.14)
            tab.chip.applyStyle(selected: selected, accent: accent, muted: muted, tint: tint)
        }
        plusButton.contentTintColor = ink
    }
}
