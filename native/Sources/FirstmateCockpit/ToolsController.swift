// Manjesh Grand Line - native macOS app.
//
// "Tools" (cockpit-tools-page-core), phase 1 of 3 of a captain-reviewed
// HTML mockup for everyday DevOps utilities. Nine genuinely functional
// tools: YAML validate/beautify, JSON validate/beautify, Base64
// encode/decode, JWT decode, a Unix timestamp converter, a Mergely-style
// diff (phase 2, cockpit-tools-page-diff), and - phase 3,
// cockpit-tools-page-specialist - a certificate inspector, a cron next-run
// explainer, and a Kubernetes resource-unit converter, closing out the
// originally-scoped three-phase Tools page. Each kind-specific tool's own
// UI/logic lives in `ToolInstance.swift`, not here - see that file's
// "MARK: Certificate"/"MARK: Cron"/"MARK: Resource units" sections for the
// three phase-3 tools, plus `CertInspector.swift`/`CronExplainer.swift`/
// `ResourceUnits.swift` for their pure logic.
//
// `fm/cockpit-tools-page-multi-session` merged before phase 3 landed and
// gave this page a tab strip
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
    case yaml, json, base64, jwt, timestamp, diff, cert, cron, resource, vpn

    /// `fm/grandline-vpn-toggle-integration`: unlike every other tool here,
    /// VPN status is global singleton state (the same two real VPNs the
    /// rail's toggles drive), not something that makes sense to duplicate
    /// into multiple concurrent tabs the way a Diff/YAML session can - two
    /// "VPN" tabs would just be two views onto the identical live state,
    /// with no independent content of their own. `ToolsController.toolCardClicked`/
    /// `duplicateTab` special-case this kind: clicking the VPN card (or
    /// trying to duplicate its tab) reveals/focuses the existing VPN tab
    /// instead of opening a second one - a deliberate, documented deviation
    /// from this page's usual "New always opens another tab" rule.
    var isSingleton: Bool { self == .vpn }

    var title: String {
        switch self {
        case .yaml: return "YAML Validate & Beautify"
        case .json: return "JSON Validate & Beautify"
        case .base64: return "Base64 Encode/Decode"
        case .jwt: return "JWT Decoder"
        case .timestamp: return "Unix Timestamp Converter"
        case .diff: return "Diff"
        case .cert: return "Certificate Inspector"
        case .cron: return "Cron Next-Run Explainer"
        case .resource: return "Resource Unit Converter"
        case .vpn: return "VPN"
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
        case .cert: return "Cert"
        case .cron: return "Cron"
        case .resource: return "Resource"
        case .vpn: return "VPN"
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
        case .cert: return "Paste a PEM certificate to see its subject, issuer, validity, serial, and SANs."
        case .cron: return "Paste a cron expression to see what it means in plain English and its next run times."
        case .resource: return "Convert CPU millicores/cores and Kubernetes memory quantities between units."
        case .vpn: return "Barracuda and OpenVPN status, profile, and connect/disconnect - the same VPNs the rail's toggles control."
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
        case .cert: return "checkmark.seal"
        case .cron: return "calendar.badge.clock"
        case .resource: return "gauge.with.dots.needle.50percent"
        case .vpn: return "network"
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
        case .cert: return .good
        case .cron: return .info
        case .resource: return .warn
        case .vpn: return .accent
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

        // Rebuild the grid's column count whenever the window resizes - a
        // live resize (drag or `setContentSize`) doesn't reliably re-invoke
        // this child view controller's own `viewDidLayout()` (only the
        // window's own content view controller is guaranteed that hook, and
        // this page is a body child of `AppShellController`, not that
        // controller itself), so this listens for the window's own resize
        // notification instead, registered lazily once the view actually has
        // a window (`viewDidAppear`).
        NotificationCenter.default.addObserver(self, selector: #selector(containerWidthMayHaveChanged), name: NSWindow.didResizeNotification, object: nil)

        ThemeManager.shared.observe { [weak root, weak self] theme in
            root?.appearance = NSAppearance(named: theme.mode == .dark ? .darkAqua : .aqua)
            root?.layer?.backgroundColor = HelmTheme.nsColor(theme.backgroundHex).cgColor
            self?.theme = theme
            self?.applyTheme()
        }

        // Every open tab's monospace text follows the same font-size source
        // terminal tabs do (`fm/cockpit-tools-page-ui-polish`) - a change
        // from Settings' presets while a Tools tab is already open updates
        // it live, not just at next construction.
        FontSizeManager.shared.observe { [weak self] size in
            for tab in self?.tabs ?? [] { tab.applyFontSize(size) }
        }

        showPicker()
        applyTheme()
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        scrollToTop()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        // The grid's very first build (in `loadView`) happens before the view
        // has a real width to measure, so it falls back to a guess - refine
        // it against the real width the moment the view is actually on
        // screen, rather than waiting for the first resize.
        containerWidthMayHaveChanged()
    }

    /// Real container width the grid last laid itself out against -
    /// `rebuildGrid()` re-runs whenever this drifts by more than a point, so
    /// resizing the window live re-flows the column count instead of it
    /// being fixed at launch size.
    private var lastGridWidth: CGFloat = 0

    @objc private func containerWidthMayHaveChanged(_ note: Notification? = nil) {
        if let note, let win = note.object as? NSWindow, win !== view.window { return }
        // Root-caused perf regression (fm/cockpit-tools-yaml-order-perf-fix -
        // see that PR for the live measurements): this handler is registered
        // globally (`object: nil`) and used to force a full Auto Layout
        // resolve of `view`'s ENTIRE subtree on every single window resize
        // notification, unconditionally - and every open Tools tab's full
        // panel (`pageStack.addArrangedSubview(instance.view)`, see
        // `addTab`) lives as a sibling of the picker's own `gridContainer`
        // inside that same subtree, hidden but still fully participating in
        // Auto Layout. With 20 open tabs, a live window resize measured
        // ~20ms/frame here versus ~11ms/frame with 0 tabs open - and that
        // cost was paid on EVERY resize regardless of whether Tools was even
        // the visible destination, since nothing gated it on visibility. The
        // column count this method computes only matters while the picker's
        // grid is actually on screen, so skip the forced layout and the
        // rebuild entirely otherwise - resizing while on another page, or
        // while looking at a specific open tab rather than the picker, no
        // longer touches this page's (potentially large) subtree at all.
        guard !view.isHidden, pickerShowing else { return }
        // Force Auto Layout to fully resolve the new window size down
        // through `content`/`pageStack`/`gridContainer`'s width chain before
        // reading it back - the resize notification can otherwise fire
        // slightly ahead of that propagation finishing.
        view.layoutSubtreeIfNeeded()
        let width = gridContainer.frame.width
        guard width > 0, abs(width - lastGridWidth) > 1 else { return }
        lastGridWidth = width
        rebuildGrid()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
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

    /// A real wrapping grid, sized to the space `gridContainer` actually has -
    /// the fixed `columnsPerRow = 3` + a hardcoded `268pt` card width this
    /// replaced (`fm/cockpit-tools-page-ui-polish`) hugged the left edge on
    /// any window wider than ~900pt, since neither the column count nor the
    /// card width ever responded to the container's real width. Measured live
    /// (a temporary debug probe, `FM_DEBUG_TOOLS_GRID=1`) before this fix:
    /// at a 1220pt window the container was 1120pt wide but 3 fixed 268pt
    /// cards only filled 824pt of it (~300pt wasted); at 1600pt the same 3
    /// fixed-width cards filled 824pt of a 1500pt container (~700pt wasted).
    /// `containerWidthMayHaveChanged()` calls this again whenever
    /// `gridContainer`'s width changes, so resizing the window re-flows the
    /// column count live -
    /// the same "recompute on layout, don't just size once" approach
    /// `SettingsController.rebuildAppearanceGrid` uses for a fixed column
    /// count, extended here to a column count derived from real width.
    private static let minCardWidth: CGFloat = 300
    private static let cardSpacing: CGFloat = 14
    private static let cardPadding: CGFloat = 16

    private func rebuildGrid() {
        for v in gridContainer.arrangedSubviews {
            gridContainer.removeArrangedSubview(v)
            v.removeFromSuperview()
        }
        cardIconTiles.removeAll()
        cardBorderViews.removeAll()
        mutedLabels.removeAll()

        let containerWidth = gridContainer.frame.width > 0 ? gridContainer.frame.width : 860
        let columnsPerRow = max(1, Int((containerWidth + Self.cardSpacing) / (Self.minCardWidth + Self.cardSpacing)))
        let cardWidth = (containerWidth - Self.cardSpacing * CGFloat(columnsPerRow - 1)) / CGFloat(columnsPerRow)

        for chunk in ToolKind.allCases.chunked(into: columnsPerRow) {
            // `.fillEqually` divides a row's width across however many
            // arranged subviews it has - a partial last row (fewer cards
            // than `columnsPerRow`) would otherwise stretch its lone card(s)
            // to fill the whole row width instead of matching a full row's
            // card width. Pad the row out to a fixed `columnsPerRow` slots
            // with invisible spacers so `.fillEqually` always divides by the
            // same column count, and the real cards stay the same width as
            // every other row.
            var views = chunk.map { toolCard($0, width: cardWidth) }
            while views.count < columnsPerRow {
                let spacer = NSView()
                spacer.translatesAutoresizingMaskIntoConstraints = false
                views.append(spacer)
            }
            let row = NSStackView(views: views)
            row.orientation = .horizontal
            row.spacing = Self.cardSpacing
            row.distribution = .fillEqually
            row.translatesAutoresizingMaskIntoConstraints = false
            gridContainer.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: gridContainer.widthAnchor).isActive = true
        }
        applyTheme()
    }

    private func showPicker() {
        pickerShowing = true
        gridContainer.isHidden = false
        for tab in tabs { tab.view.isHidden = true }
        styleChips()
        // The grid's column count is only kept up to date (via
        // `containerWidthMayHaveChanged`) while the picker is showing, so a
        // resize that happened while a tab was open instead needs to be
        // picked up now that the picker is back on screen.
        containerWidthMayHaveChanged()
    }

    private func showTab(_ tab: ToolInstance) {
        pickerShowing = false
        gridContainer.isHidden = true
        for t in tabs { t.view.isHidden = (t !== tab) }
        styleChips()
    }

    @objc private func toolCardClicked(_ sender: NSClickGestureRecognizer) {
        guard let raw = sender.view?.identifier?.rawValue, let kind = ToolKind(rawValue: raw) else { return }
        // `ToolKind.isSingleton` (VPN only, as of fm/grandline-vpn-toggle-integration):
        // reveal/focus the one already-open tab of this kind instead of
        // opening a second one - see that property's own doc comment for
        // why VPN status doesn't make sense duplicated across tabs.
        if kind.isSingleton, let existing = tabs.first(where: { $0.kind == kind }) {
            selectTab(id: existing.id)
            return
        }
        openNewTab(kind: kind)
    }

    // MARK: Landing grid card

    private func toolCard(_ kind: ToolKind, width: CGFloat) -> NSView {
        let tile = IconTileView()
        tile.configure(symbol: kind.symbol, tint: kind.tint)
        cardIconTiles.append(tile)

        let titleLabel = NSTextField(labelWithString: kind.title)
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail

        let descLabel = NSTextField(wrappingLabelWithString: kind.description)
        descLabel.font = .systemFont(ofSize: 11)
        // Card width varies with the container (see `rebuildGrid`), so this is
        // recomputed on every rebuild rather than a fixed guess - a stale
        // `preferredMaxLayoutWidth` from a previous, differently-sized layout
        // would otherwise leave the label's computed intrinsic height wrong
        // (too tall on a wider re-flow, clipped on a narrower one).
        descLabel.preferredMaxLayoutWidth = width - Self.cardPadding * 2 - 34 - 10
        mutedLabels.append(descLabel)

        let textStack = NSStackView(views: [titleLabel, descLabel])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 4
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
            row.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: Self.cardPadding),
            row.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -Self.cardPadding),
            row.topAnchor.constraint(equalTo: card.topAnchor, constant: Self.cardPadding),
            row.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -Self.cardPadding),
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
        // A singleton kind (VPN) has no independent content to duplicate
        // into a second tab - see `ToolKind.isSingleton`'s doc comment.
        guard !src.kind.isSingleton else { return }
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
