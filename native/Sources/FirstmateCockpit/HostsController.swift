// Manjesh Grand Line - native macOS app.
//
// The Hosts destination: saved SSH hosts, SSH keys and command snippets, as
// three tabs of one full-width page.
//
// **Why this file replaces three.** The full-app UI audit
// (`data/grandline-full-ui-audit/report.md`, §4.4/§4.5, §6.4 and §7's Phase 5)
// found Hosts, SSH Keys and Snippets were "three views of one concern in three
// different presentation modes": a rail destination that was still laid out as
// the 220-260pt Termius-style sidebar it had been before
// `fm/cockpit-native-ui-fixes2` promoted it to a full-size body destination,
// plus a 380x520 floating window and a 360x480 floating window. The two
// windows (`KeysSidebarController`, `SnippetsController`) were near-identical
// twins - same footer-button helper, same table setup, same title/caption
// treatment - and the Hosts page was the audit's single worst-rendering
// surface, with three ~370pt `.fillEqually` footer buttons and one 78pt row
// above ~800pt of empty space.
//
// The captain approved the structural change (registered decision
// `grandline-full-ui-audit-decision-hosts-keys-snippets-merge`): the two
// windows are gone, and their content is a `HelmSegmentedTabs` tab inside this
// destination. Everything they did still happens here - add/edit/delete a
// host, key or snippet; connect; quick-connect; key generation and import;
// snippet run; the pinned "Firstmate" entry's connect - only the presentation
// changed.
//
// **What it is built out of.** Nothing new: the page is Phase 1-4's shared
// components (`HelmDesignSystem.swift`) assembled - `HelmSegmentedTabs` for
// the tab row, one `HelmCard` per tab, `HelmAccentRow` cards for every list
// row, `HelmEmptyState` for every "nothing here yet", `HelmButton` for every
// action. The three per-list bodies are one `HostsListSection`, fed a
// `[HostsListSection.Item]` array, which is what actually deletes the
// duplication rather than moving it.
//
// **Where the actions went.** The footer strip is gone. A row's own actions
// (Connect / Edit / Run, plus an overflow menu carrying the rest) live in that
// row, in `HelmAccentRow`'s `trailingAccessory` slot; the "add" action lives
// in its card's header. So no action is ever a 370pt-wide button, and no
// action depends on the list having a selection first.
//
// This view stays decoupled from the terminal exactly as its three
// predecessors were: it takes the three stores plus `onConnect` /
// `onConnectPinned` / `onAddOrEdit` / `onRunSnippet` closures, and never
// touches `ConsoleController` or SwiftTerm.

import AppKit

/// Which of the destination's three tabs is showing. Raw values are the ids
/// `HelmSegmentedTabs` deals in (the component switches nothing itself - it
/// hands an id back and this controller's own switch does the work).
enum HostsTab: String, CaseIterable {
    case hosts, keys, snippets

    var title: String {
        switch self {
        case .hosts: return "Hosts"
        case .keys: return "SSH Keys"
        case .snippets: return "Snippets"
        }
    }
}

final class HostsController: NSViewController, NSSearchFieldDelegate {

    private let hostStore: HostStore
    private let keyStore: SSHKeyStore
    private let snippetStore: SnippetStore

    // MARK: Callbacks (unchanged from the three controllers this replaces)

    /// Open an ssh session: (saved host id - `nil` for an ad-hoc quick
    /// connect with no saved identity, tab label, ssh argv, host accent hex,
    /// saved-key id, startup-snippet id). Wired by the app delegate to the
    /// same per-host dedicated-page connect the rail's pinned host icons use.
    var onConnect: ((UUID?, String, [String], String?, UUID?, UUID?) -> Void)?

    /// Connect the pinned "Firstmate" entry. Wired to
    /// `ConsoleController.openFirstmateHost`.
    var onConnectPinned: (() -> Void)?

    /// Add (`nil`) or edit (a host) - the host editor is a dedicated window
    /// owned by the app delegate, not a sheet on this page.
    var onAddOrEdit: ((Host?) -> Void)?

    /// Run a snippet in the console's active/frontmost tab. Wired to
    /// `ConsoleController.runSnippetInActiveTab`.
    var onRunSnippet: ((Snippet) -> Void)?

    // MARK: Views

    private var tabs: HelmSegmentedTabs!
    private var activeTab: HostsTab = .hosts

    private let hostsTabView = NSView()
    private let keysTabView = NSView()
    private let snippetsTabView = NSView()

    private let searchField = NSSearchField()
    private let tagsScroll = NSScrollView()
    private let tagsStack = NSStackView()
    private var tagButtons: [String: HelmButton] = [:]
    private var selectedTags: Set<String> = []

    private let hostsList = HostsListSection()
    private let keysList = HostsListSection()
    private let snippetsList = HostsListSection()

    private var hostsTitleLabel = NSTextField(labelWithString: HostsTab.hosts.title)
    private var keysTitleLabel = NSTextField(labelWithString: HostsTab.keys.title)
    private var snippetsTitleLabel = NSTextField(labelWithString: HostsTab.snippets.title)

    init(hostStore: HostStore, keyStore: SSHKeyStore, snippetStore: SnippetStore) {
        self.hostStore = hostStore
        self.keyStore = keyStore
        self.snippetStore = snippetStore
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: Layout

    override func loadView() {
        // A plain, layer-backed, theme-filled root - never an
        // `NSVisualEffectView`. AGENTS.md gotcha #8: `.behindWindow` blending
        // composites against what is behind the *window*, which is wrong for
        // a full-size destination.
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 1136, height: 660))
        root.wantsLayer = true
        view = root

        tabs = HelmSegmentedTabs(items: HostsTab.allCases.map { .init(id: $0.rawValue, title: $0.title) },
                                 selected: activeTab.rawValue)
        tabs.onSelect = { [weak self] id in
            guard let tab = HostsTab(rawValue: id) else { return }
            self?.select(tab: tab, moveTabControl: false)
        }
        root.addSubview(tabs)

        buildHostsTab()
        buildKeysTab()
        buildSnippetsTab()

        // The content column: gutter to gutter, exactly like every other
        // card-bearing destination in this app. An `NSLayoutGuide` rather
        // than a spacer view, so nothing renders it and nothing can
        // accidentally pick up a background from it.
        //
        // **There is no width cap any more.** Phase 5 built this column as
        // `leading >= / trailing <= / centerX ==`, floating the page in the
        // middle of a wide window with a mirrored dead gutter either side;
        // `fm/grandline-design-fidelity-fixes` dropped the `centerX` tie so
        // the page is left-aligned, but kept a 1120pt maximum, reasoning that
        // "a very wide window still doesn't stretch a host row's two short
        // strings across 1500pt". Live, that cap is what the captain reported
        // next (`04-hosts-page-right-gap.png`): on a laptop-width window the
        // cards stop about four fifths of the way across and the rest of the
        // page is empty. The reasoning was also already handled one level
        // down - a host row is a `HelmAccentRow` whose Connect / `...`
        // controls sit in its own right-anchored `trailingAccessory` slot, so
        // a wider card puts the extra width *between* the two short strings
        // and the actions rather than stretching either, which is precisely
        // how Updates', GitHub Sync's and Vault's rows already behave at any
        // width.
        //
        // `FleetController`, `ReviewController`, `UpdatesController`,
        // `GitHubSyncController` and `VaultController` all pin
        // `leading == +pageGutter` / `trailing == -pageGutter` with no cap.
        // Hosts was the only exception; it no longer is.
        let column = NSLayoutGuide()
        root.addLayoutGuide(column)

        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: HelmMetrics.pageGutter),
            column.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -HelmMetrics.pageGutter),
            column.topAnchor.constraint(equalTo: root.topAnchor, constant: HelmMetrics.s5),
            column.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -HelmMetrics.pageGutter),

            tabs.leadingAnchor.constraint(equalTo: column.leadingAnchor),
            tabs.trailingAnchor.constraint(lessThanOrEqualTo: column.trailingAnchor),
            tabs.topAnchor.constraint(equalTo: column.topAnchor),
        ])

        for tabView in [hostsTabView, keysTabView, snippetsTabView] {
            tabView.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(tabView)
            NSLayoutConstraint.activate([
                tabView.leadingAnchor.constraint(equalTo: column.leadingAnchor),
                tabView.trailingAnchor.constraint(equalTo: column.trailingAnchor),
                tabView.topAnchor.constraint(equalTo: tabs.bottomAnchor, constant: HelmMetrics.s4),
                tabView.bottomAnchor.constraint(equalTo: column.bottomAnchor),
            ])
        }

        ThemeManager.shared.observe { [weak self] theme in self?.applyTheme(theme) }

        hostStore.observe { [weak self] in self?.reloadHosts() }
        keyStore.onChange = { [weak self] in self?.reloadKeys() }
        snippetStore.onChange = { [weak self] in self?.reloadSnippets() }

        select(tab: .hosts, moveTabControl: true)
        reloadHosts()
        reloadKeys()
        reloadSnippets()
        // The `ThemeManager.observe` closure above fires synchronously at
        // registration - before the lists had any rows - so re-apply once the
        // page is fully built (`ThemeManager.swift`'s checklist item 4, the
        // trap this codebase has now hit four times).
        applyTheme(ThemeManager.shared.theme)
    }

    private func buildHostsTab() {
        searchField.placeholderString = "Find a host, or type ssh user@host to connect"
        searchField.delegate = self
        searchField.translatesAutoresizingMaskIntoConstraints = false
        // Typing filters the list live (`controlTextDidChange`); Return
        // connects (`control(_:textView:doCommandBy:)`). Deliberately no
        // target/action - an NSSearchField would otherwise fire it mid-typing.

        tagsStack.orientation = .horizontal
        tagsStack.spacing = HelmMetrics.s1
        tagsStack.translatesAutoresizingMaskIntoConstraints = false
        tagsScroll.documentView = tagsStack
        tagsScroll.hasHorizontalScroller = false
        tagsScroll.hasVerticalScroller = false
        tagsScroll.drawsBackground = false
        tagsScroll.translatesAutoresizingMaskIntoConstraints = false
        // No trailing constraint - the stack sizes to its content and the clip
        // view scrolls horizontally once that content overflows.
        NSLayoutConstraint.activate([
            tagsStack.leadingAnchor.constraint(equalTo: tagsScroll.contentView.leadingAnchor),
            tagsStack.topAnchor.constraint(equalTo: tagsScroll.contentView.topAnchor),
            tagsStack.bottomAnchor.constraint(equalTo: tagsScroll.contentView.bottomAnchor),
            tagsScroll.heightAnchor.constraint(equalToConstant: 24),
        ])

        // A vertical `NSStackView`, not manual constraints, specifically so
        // hiding the tag row (no tags on any host - the common case) removes
        // it from layout instead of leaving a 24pt gap.
        let top = NSStackView(views: [searchField, tagsScroll])
        top.orientation = .vertical
        top.alignment = .leading
        top.spacing = HelmMetrics.s2
        top.translatesAutoresizingMaskIntoConstraints = false

        let add = HelmButton(title: "Add Host", variant: .primary, size: .small,
                             symbol: "plus", target: self, action: #selector(newHost))
        add.toolTip = "Add Host (⌘N)"
        hostsList.card.setHeader(symbol: "server.rack",
                                 titleLabel: hostsTitleLabel,
                                 subtitleLabel: NSTextField(wrappingLabelWithString:
                                    "Saved SSH connections. Connect opens the host's own page."),
                                 actions: [add])

        hostsTabView.addSubview(top)
        hostsTabView.addSubview(hostsList.card)
        NSLayoutConstraint.activate([
            top.leadingAnchor.constraint(equalTo: hostsTabView.leadingAnchor),
            top.trailingAnchor.constraint(equalTo: hostsTabView.trailingAnchor),
            top.topAnchor.constraint(equalTo: hostsTabView.topAnchor),
            searchField.widthAnchor.constraint(equalTo: top.widthAnchor),
            tagsScroll.widthAnchor.constraint(equalTo: top.widthAnchor),

            hostsList.card.leadingAnchor.constraint(equalTo: hostsTabView.leadingAnchor),
            hostsList.card.trailingAnchor.constraint(equalTo: hostsTabView.trailingAnchor),
            hostsList.card.topAnchor.constraint(equalTo: top.bottomAnchor, constant: HelmMetrics.s3),
            hostsList.card.bottomAnchor.constraint(equalTo: hostsTabView.bottomAnchor),
        ])
    }

    private func buildKeysTab() {
        let add = HelmButton(title: "New Key", variant: .primary, size: .small,
                             symbol: "plus", target: self, action: #selector(newKey))
        add.toolTip = "New Key (⌘⇧N)"
        keysList.card.setHeader(symbol: "key.fill", tint: .violet,
                                titleLabel: keysTitleLabel,
                                subtitleLabel: NSTextField(wrappingLabelWithString:
                                    "Private key material and passphrases are stored in the macOS Keychain, gated by Touch ID."),
                                actions: [add])
        fill(keysTabView, with: keysList.card)
    }

    private func buildSnippetsTab() {
        let add = HelmButton(title: "New Snippet", variant: .primary, size: .small,
                             symbol: "plus", target: self, action: #selector(newSnippet))
        add.toolTip = "New Snippet (⌘⌥N)"
        snippetsList.card.setHeader(symbol: "chevron.left.forwardslash.chevron.right", tint: .info,
                                    titleLabel: snippetsTitleLabel,
                                    subtitleLabel: NSTextField(wrappingLabelWithString:
                                        "Run sends a snippet's command, then Enter, to the active terminal tab."),
                                    actions: [add])
        fill(snippetsTabView, with: snippetsList.card)
    }

    private func fill(_ container: NSView, with child: NSView) {
        container.addSubview(child)
        NSLayoutConstraint.activate([
            child.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            child.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            child.topAnchor.constraint(equalTo: container.topAnchor),
            child.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
    }

    // MARK: Tabs

    /// Switch tabs. `moveTabControl` is false when the switch came *from* the
    /// tab control itself (it has already moved its own pill).
    func select(tab: HostsTab, moveTabControl: Bool = true) {
        activeTab = tab
        if moveTabControl { tabs?.select(tab.rawValue) }
        hostsTabView.isHidden = tab != .hosts
        keysTabView.isHidden = tab != .keys
        snippetsTabView.isHidden = tab != .snippets
    }

    var currentTab: HostsTab { activeTab }

    private func applyTheme(_ theme: HelmTheme) {
        view.layer?.backgroundColor = HelmTheme.nsColor(theme.backgroundHex).cgColor
        // A forced appearance is still right for the one stock control left on
        // this page (the quick-connect `NSSearchField`, which Phase 6's
        // `HelmField` owns) - see `ThemeManager.swift`'s checklist rule 2.
        view.appearance = NSAppearance(named: theme.mode == .dark ? .darkAqua : .aqua)
        tabs?.applyTheme(theme)
        hostsList.applyTheme(theme)
        keysList.applyTheme(theme)
        snippetsList.applyTheme(theme)
    }

    // MARK: Hosts data

    private func reloadHosts() {
        rebuildTagChips()
        applyHostFilter(searchField.stringValue)
    }

    /// One toggle button per distinct tag across all hosts, sorted for a
    /// stable layout. Rebuilt on every reload (a handful of hosts, a handful
    /// of tags) so it stays in sync with host edits with no change tracking.
    private func rebuildTagChips() {
        for v in tagsStack.arrangedSubviews {
            tagsStack.removeArrangedSubview(v)
            v.removeFromSuperview()
        }
        tagButtons.removeAll()
        let allTags = Set(hostStore.hosts.flatMap(\.tags)).sorted()
        selectedTags.formIntersection(allTags)
        for tag in allTags {
            // `.pushOnPushOff` still tracks `state` (which `tagChipClicked`
            // reads), but nothing draws that state now the stock bezel is
            // gone - the `.primary` variant is what shows it.
            let b = HelmButton(title: tag, variant: .secondary, size: .small,
                               target: self, action: #selector(tagChipClicked(_:)))
            b.setButtonType(.pushOnPushOff)
            b.state = selectedTags.contains(tag) ? .on : .off
            b.variant = b.state == .on ? .primary : .secondary
            b.identifier = NSUserInterfaceItemIdentifier(tag)
            tagButtons[tag] = b
            tagsStack.addArrangedSubview(b)
        }
        tagsScroll.isHidden = allTags.isEmpty
    }

    @objc private func tagChipClicked(_ sender: NSButton) {
        guard let tag = sender.identifier?.rawValue else { return }
        if sender.state == .on { selectedTags.insert(tag) } else { selectedTags.remove(tag) }
        (sender as? HelmButton)?.variant = sender.state == .on ? .primary : .secondary
        applyHostFilter(searchField.stringValue)
    }

    /// Text filter (label/address/username/tags) + the tag-chip filter,
    /// grouped into header/host rows, with the pinned "Firstmate" entry always
    /// first and unaffected by either filter - it is a permanent fixture, not
    /// a saved host. Group headers are skipped entirely when every visible
    /// host shares one group (the "I haven't set up groups yet" case), so a
    /// flat host list never gains visual noise.
    private func applyHostFilter(_ query: String) {
        let hosts = filteredHosts(query)
        var items: [HostsListSection.Item] = [pinnedItem()]

        let groupKeys = Set(hosts.map { normalizedGroup($0) })
        if groupKeys.count <= 1 {
            items += hosts.map { hostItem($0) }
        } else {
            for name in groupKeys.compactMap({ $0 }).sorted() {
                items.append(.group(name))
                items += hosts.filter { normalizedGroup($0) == name }.map { hostItem($0) }
            }
            let ungrouped = hosts.filter { normalizedGroup($0) == nil }
            if !ungrouped.isEmpty {
                items.append(.group("Ungrouped"))
                items += ungrouped.map { hostItem($0) }
            }
        }

        if hosts.isEmpty {
            let filtering = !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !selectedTags.isEmpty
            items.append(.empty(
                symbol: filtering ? "line.3.horizontal.decrease.circle" : "server.rack",
                title: filtering ? "No matching hosts" : "No saved hosts yet",
                body: filtering
                    ? "Nothing matches that search or those tags. Clear them to see every saved host."
                    : "Add a host to save its connection details, or type ssh user@host in the field above to connect right now."))
        }

        hostsTitleLabel.stringValue = hostStore.hosts.isEmpty
            ? HostsTab.hosts.title
            : "\(HostsTab.hosts.title) (\(hostStore.hosts.count))"
        hostsList.setItems(items)
    }

    private func filteredHosts(_ query: String) -> [Host] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var hosts = hostStore.hosts
        if !q.isEmpty {
            hosts = hosts.filter { host in
                host.label.lowercased().contains(q)
                    || host.address.lowercased().contains(q)
                    || host.username.lowercased().contains(q)
                    || host.tags.contains { $0.lowercased().contains(q) }
            }
        }
        if !selectedTags.isEmpty {
            hosts = hosts.filter { !$0.tags.isEmpty && !selectedTags.isDisjoint(with: $0.tags) }
        }
        return hosts
    }

    private func normalizedGroup(_ host: Host) -> String? {
        let g = host.group?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return g.isEmpty ? nil : g
    }

    /// The permanent, non-deletable first row. It has no `Host` behind it, so
    /// it can only be connected to - no edit, duplicate or delete. Its glyph
    /// is `sailboat`, the mark this app already uses for itself (and not
    /// `anchor`, which is not an SF Symbol on macOS at all and so rendered as
    /// nothing for as long as this row existed - fixed in Phase 0).
    private func pinnedItem() -> HostsListSection.Item {
        var item = HostsListSection.Item(content: .init(tint: .accent,
                                                        kicker: "Built-in",
                                                        title: "Firstmate",
                                                        meta: "Shell + Mirror",
                                                        badgeSymbol: "sailboat"))
        item.primary = .init(title: "Connect", symbol: "bolt.fill") { [weak self] in self?.onConnectPinned?() }
        item.activate = { [weak self] in self?.onConnectPinned?() }
        return item
    }

    private func hostItem(_ host: Host) -> HostsListSection.Item {
        var content = HelmAccentRow.Content(tint: .accent,
                                            kicker: Self.roleKicker(for: host),
                                            title: host.label,
                                            meta: host.subtitle,
                                            badgeSymbol: host.iconSymbol)
        // A host's accent is picked per host in the host editor, so it is a
        // literal hue rather than a semantic `HelmTint` - see
        // `HelmAccentRow.Content.tintHex`. Together with the role kicker
        // above, that is the prototype's "PREPROD / PROD / CI" row: the bar
        // and badge carry the captain's own colour for that host, the kicker
        // names the role.
        content.tintHex = host.accentHex
        // The first tag is the kicker now, so the chip only carries what the
        // kicker could not - "+2 more". A chip repeating the kicker was the
        // same signal twice.
        if host.tags.count > 1 {
            content.chipText = "+\(host.tags.count - 1) more"
        }
        var item = HostsListSection.Item(content: content)
        item.primary = .init(title: "Connect", symbol: "bolt.fill") { [weak self] in self?.connect(host) }
        item.activate = { [weak self] in self?.connect(host) }
        item.overflow = [
            .init(title: "Edit…") { [weak self] in self?.onAddOrEdit?(host) },
            .init(title: "Duplicate…") { [weak self] in self?.duplicate(host) },
            .init(title: "Delete") { [weak self] in self?.confirmDeleteHost(host) },
        ]
        return item
    }

    /// A host row's kicker: what kind of box this is, in the captain's own
    /// words. The prototype's Hosts page reads LOCAL / PREPROD / PROD / CI
    /// down the left of the list rather than "SSH" four times, and this app
    /// already stores exactly that - a host's first tag, or its group when it
    /// has no tags. Falls back to "SSH" for a host with neither, which is
    /// what every row said before.
    ///
    /// `HelmAccentRow` uppercases and kerns the kicker itself, so this returns
    /// the captain's own casing untouched.
    static func roleKicker(for host: Host) -> String {
        if let tag = host.tags.first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) {
            return tag
        }
        if let group = host.group?.trimmingCharacters(in: .whitespacesAndNewlines), !group.isEmpty {
            return group
        }
        return "SSH"
    }

    // MARK: Keys data

    private func reloadKeys() {
        var items = keyStore.keys.map { keyItem($0) }
        if items.isEmpty {
            items = [.empty(symbol: "key.fill",
                            title: "No saved keys yet",
                            body: "Generate a key, or import an existing PEM or OpenSSH one. Private key material stays in the macOS Keychain.")]
        }
        keysTitleLabel.stringValue = keyStore.keys.isEmpty
            ? HostsTab.keys.title
            : "\(HostsTab.keys.title) (\(keyStore.keys.count))"
        keysList.setItems(items)
    }

    private func keyItem(_ key: SSHKey) -> HostsListSection.Item {
        var content = HelmAccentRow.Content(tint: key.type.tint,
                                            kicker: key.type.displayName,
                                            title: key.label,
                                            meta: key.fingerprint,
                                            badgeSymbol: "key.fill")
        content.metaIsCode = true
        if key.hasPassphrase { content.chipText = "Passphrase" }
        var item = HostsListSection.Item(content: content)
        item.primary = .init(title: "Edit", symbol: "pencil") { [weak self] in self?.presentKeyEditor(for: key) }
        item.activate = { [weak self] in self?.presentKeyEditor(for: key) }
        item.overflow = [
            .init(title: "Copy Public Key") { copyToPasteboard(key.publicKey) },
            .init(title: "Delete") { [weak self] in self?.confirmDeleteKey(key) },
        ]
        return item
    }

    // MARK: Snippets data

    private func reloadSnippets() {
        var items = snippetStore.snippets.map { snippetItem($0) }
        if items.isEmpty {
            items = [.empty(symbol: "chevron.left.forwardslash.chevron.right",
                            title: "No snippets yet",
                            body: "Save a command you run often, then send it to any terminal tab in one click.")]
        }
        snippetsTitleLabel.stringValue = snippetStore.snippets.isEmpty
            ? HostsTab.snippets.title
            : "\(HostsTab.snippets.title) (\(snippetStore.snippets.count))"
        snippetsList.setItems(items)
    }

    private func snippetItem(_ snippet: Snippet) -> HostsListSection.Item {
        var content = HelmAccentRow.Content(tint: .info,
                                            kicker: "Snippet",
                                            title: snippet.label,
                                            meta: snippet.subtitle,
                                            badgeSymbol: "chevron.left.forwardslash.chevron.right")
        content.metaIsCode = true
        var item = HostsListSection.Item(content: content)
        item.primary = .init(title: "Run", symbol: "play.fill") { [weak self] in self?.onRunSnippet?(snippet) }
        item.activate = { [weak self] in self?.onRunSnippet?(snippet) }
        item.overflow = [
            .init(title: "Edit…") { [weak self] in self?.presentSnippetEditor(for: snippet) },
            .init(title: "Copy Command") { copyToPasteboard(snippet.command) },
            .init(title: "Delete") { [weak self] in self?.confirmDeleteSnippet(snippet) },
        ]
        return item
    }

    // MARK: Host actions

    private func connect(_ host: Host) {
        onConnect?(host.id, host.label, host.sshArguments(allHosts: hostStore.hosts),
                   host.accentHex, host.keyID, host.startupSnippetID)
    }

    private func duplicate(_ host: Host) {
        var copy = host
        copy.id = UUID()
        copy.label = host.label + " copy"
        hostStore.add(copy)
    }

    /// ⌘N / the card header's "Add Host": add a new host.
    @objc func newHost() {
        select(tab: .hosts)
        onAddOrEdit?(nil)
    }

    /// The Hosts menu's Quick Connect: focus the quick-connect field.
    @objc func focusQuickConnect() {
        select(tab: .hosts)
        view.window?.makeFirstResponder(searchField)
    }

    /// Return in the quick-connect field: match a saved host, else parse an
    /// ad-hoc `[user@]host[:port]`.
    private func quickConnectFromField() {
        let raw = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { NSSound.beep(); return }
        // Exact label match wins; otherwise a single filtered result is
        // treated as the intended host.
        if let exact = hostStore.hosts.first(where: { $0.label.caseInsensitiveCompare(raw) == .orderedSame }) {
            connect(exact)
            return
        }
        let visible = filteredHosts(raw)
        if visible.count == 1 {
            connect(visible[0])
            return
        }
        if let parsed = HostCatalog.parseQuickConnect(raw) {
            onConnect?(nil, parsed.label, parsed.args, nil, nil, nil)
            searchField.stringValue = ""
            applyHostFilter("")
            return
        }
        NSSound.beep()
    }

    private func confirmDeleteHost(_ host: Host) {
        guard confirm(message: "Delete \u{201C}\(host.label)\u{201D}?",
                      detail: "This removes the saved host. It does not affect any running session.")
        else { return }
        hostStore.delete(id: host.id)
    }

    // MARK: Key actions

    /// ⌘⇧N / the card header's "New Key".
    @objc func newKey() {
        select(tab: .keys)
        presentKeyEditor(for: nil)
    }

    private func presentKeyEditor(for key: SSHKey?) {
        let usedByHostCount = key.map { targetKey in hostStore.hosts.filter { $0.keyID == targetKey.id }.count } ?? 0
        let editor = KeyEditorController(key: key, usedByHostCount: usedByHostCount)
        editor.onSave = { [weak self] newKey, privateKeyData, passphrase in
            self?.persistNewKey(newKey, privateKeyData: privateKeyData, passphrase: passphrase)
        }
        editor.onUpdate = { [weak self] updatedKey, newPassphrase in
            self?.persistUpdatedKey(updatedKey, newPassphrase: newPassphrase)
        }
        editor.onDelete = { [weak self] id in self?.keyStore.delete(id: id) }
        presentAsSheet(editor)
    }

    /// Create mode: `SSHKeyStore.addNew` writes the Keychain secrets before
    /// adding the metadata.
    private func persistNewKey(_ key: SSHKey, privateKeyData: Data, passphrase: String?) {
        do {
            try keyStore.addNew(key, privateKeyData: privateKeyData, passphrase: passphrase)
            Toast.show(in: view, message: "\u{201C}\(key.label)\u{201D} saved")
        } catch {
            presentError(error, context: "Couldn't save \"\(key.label)\" to the Keychain")
        }
    }

    /// Edit mode never touches the private key; a new passphrase (when typed)
    /// overwrites the existing Keychain entry for it.
    private func persistUpdatedKey(_ key: SSHKey, newPassphrase: String?) {
        if let newPassphrase {
            do {
                try KeychainKeyStore.savePassphrase(id: key.id, passphrase: newPassphrase)
            } catch {
                presentError(error, context: "Couldn't update the passphrase for \"\(key.label)\"")
                return
            }
        }
        keyStore.update(key)
        Toast.show(in: view, message: "\u{201C}\(key.label)\u{201D} saved")
    }

    private func confirmDeleteKey(_ key: SSHKey) {
        guard confirm(message: "Delete \u{201C}\(key.label)\u{201D}?",
                      detail: "This removes the key's Keychain entry (private key and passphrase). "
                            + "Any host still referencing it will fall back to the system ssh agent.")
        else { return }
        keyStore.delete(id: key.id)
    }

    // MARK: Snippet actions

    /// ⌘⌥N / the card header's "New Snippet".
    @objc func newSnippet() {
        select(tab: .snippets)
        presentSnippetEditor(for: nil)
    }

    private func presentSnippetEditor(for snippet: Snippet?) {
        let editor = SnippetEditorController(snippet: snippet)
        editor.onSave = { [weak self] saved in
            guard let self else { return }
            if self.snippetStore.snippet(id: saved.id) != nil {
                self.snippetStore.update(saved)
            } else {
                self.snippetStore.add(saved)
            }
        }
        editor.onDelete = { [weak self] id in self?.snippetStore.delete(id: id) }
        presentAsSheet(editor)
    }

    private func confirmDeleteSnippet(_ snippet: Snippet) {
        guard confirm(message: "Delete \u{201C}\(snippet.label)\u{201D}?",
                      detail: "Any host using this as its startup snippet will fall back to no startup command.")
        else { return }
        snippetStore.delete(id: snippet.id)
    }

    // MARK: Shared alerts

    private func confirm(message: String, detail: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = detail
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func presentError(_ error: Error, context: String) {
        let alert = NSAlert()
        alert.messageText = context
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .critical
        alert.runModal()
    }

    // MARK: NSSearchFieldDelegate

    func controlTextDidChange(_ obj: Notification) {
        applyHostFilter(searchField.stringValue)
    }

    /// Return in the quick-connect field connects; everything else is left to
    /// the field editor (so typing, arrows and delete behave normally).
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard control === searchField, commandSelector == #selector(NSResponder.insertNewline(_:)) else {
            return false
        }
        quickConnectFromField()
        return true
    }

    // MARK: Probe / self-test surface

    /// Real, resolved state for a live page, so a probe can assert the merge
    /// without eyeballing a screenshot.
    struct Debug {
        let activeTab: String
        let hostRowCount: Int
        let keyRowCount: Int
        let snippetRowCount: Int
        let hostsCardFrame: NSRect
        let rootWidth: CGFloat
        let hostsTabVisible: Bool
        let keysTabVisible: Bool
        let snippetsTabVisible: Bool
    }

    func debugState() -> Debug {
        view.layoutSubtreeIfNeeded()
        return Debug(activeTab: activeTab.rawValue,
                     hostRowCount: hostsList.debugRowCount,
                     keyRowCount: keysList.debugRowCount,
                     snippetRowCount: snippetsList.debugRowCount,
                     hostsCardFrame: hostsList.card.convert(hostsList.card.bounds, to: view),
                     rootWidth: view.bounds.width,
                     hostsTabVisible: !hostsTabView.isHidden,
                     keysTabVisible: !keysTabView.isHidden,
                     snippetsTabVisible: !snippetsTabView.isHidden)
    }

    func debugList(_ tab: HostsTab) -> HostsListSection {
        switch tab {
        case .hosts: return hostsList
        case .keys: return keysList
        case .snippets: return snippetsList
        }
    }
}

private func copyToPasteboard(_ text: String) {
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(text, forType: .string)
}
