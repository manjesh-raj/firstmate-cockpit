// Firstmate Cockpit - native macOS app.
//
// The Hosts sidebar (design report A2/A3, Section D Phase 1): a Termius-style
// list of saved SSH hosts with per-host icons, a quick-connect field, and add /
// edit / delete. "Connect" hands a `ssh` argv back to the console, which opens it
// as a new tab in the Phase 0 tab collection.
//
// The sidebar is decoupled from the terminal: it takes a `HostStore` and an
// `onConnect` closure. It never touches `ConsoleController` or SwiftTerm.
//
// Phase 3 (design report Section B4, Section D Phase 3) adds groups and tags:
// hosts are grouped into labeled sections in the list, and a row of tag
// chips beneath the search field filters the list to hosts carrying the
// tapped tag(s) (in addition to the search field already matching tags by
// text). Connect now also resolves the full Phase 3 argv (agent forwarding,
// jump chain, port forwards - `Host.sshArguments(allHosts:)`) and passes the
// host's startup snippet id through, since that also only makes sense at
// connect time.

import AppKit

/// One row in the host list: a group section header, a saved host, or the
/// pinned built-in "Firstmate" entry (Fix 4 - unifies the old always-open
/// Shell/Mirror tabs into the Hosts list). Kept as a flat array (rather than
/// switching to `NSOutlineView`) so the rest of the table plumbing -
/// selection, double-click, context menu - stays exactly as it was before
/// groups existed.
private enum HostListRow {
    case pinned
    case header(String)
    case host(Host)
}

final class HostsSidebarController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate, NSMenuDelegate {

    private let store: HostStore

    /// Open an ssh session: (saved host id - `nil` for an ad-hoc quick
    /// connect with no saved identity, tab label, ssh argv, host accent hex,
    /// saved-key id, startup-snippet id). Fix 1: wired by the app delegate to
    /// the same per-host dedicated-page connect the rail's pinned host icons
    /// use, so this list's own "Connect" reaches the exact same page rather
    /// than a second, inconsistent path into the shared Console. An ad-hoc
    /// quick connect (no saved host, so no id to pin a page to) still opens
    /// as a plain tab in the shared Firstmate console.
    var onConnect: ((UUID?, String, [String], String?, UUID?, UUID?) -> Void)?

    /// Connect the pinned "Firstmate" entry (Fix 4). Wired by the app
    /// delegate to `ConsoleController.openFirstmateHost`.
    var onConnectPinned: (() -> Void)?

    /// Add ("+"/⌘N) or edit (double-click/Edit) a host - `nil` for a new
    /// host, a host for editing. Nav-redesign task, item 3: the editor is now
    /// a dedicated full-page window (`AppDelegate.presentHostEditor`), not a
    /// sheet cramped into this ~240pt-wide panel, so this view no longer
    /// constructs `HostEditorController` itself.
    var onAddOrEdit: ((Host?) -> Void)?

    // MARK: Views

    private let searchField = NSSearchField()
    private let tagsScroll = NSScrollView()
    private let tagsStack = NSStackView()
    private let table = NSTableView()
    private var connectButton = NSButton()
    private var editButton = NSButton()
    private var deleteButton = NSButton()

    /// The rows currently shown (filtered by search text + selected tags,
    /// then grouped into header/host rows).
    private var rows: [HostListRow] = []
    /// Tags currently toggled on in the chip row; a host must carry at least
    /// one to pass (in addition to the text filter).
    private var selectedTags: Set<String> = []
    private var tagButtons: [String: NSButton] = [:]

    init(store: HostStore) {
        self.store = store
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: Layout

    override func loadView() {
        // Fix 6 (fixes4): this used to be a narrow, translucent sidebar
        // material (`.sidebar` + `.behindWindow`) from when Hosts was a
        // ~240pt panel living inside a split view alongside opaque terminal
        // content. Now that Hosts is a full-width standalone destination
        // rendered directly in the body container (see `AppShellController`),
        // that blend-behind-the-window material has nothing correct to blend
        // against and can render as a mismatched/incorrect tint. A plain,
        // theme-driven solid background - exactly what Settings and the
        // terminal already use - is what a full-page destination needs.
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 660))
        root.wantsLayer = true
        view = root
        ThemeManager.shared.observe { [weak root] theme in
            root?.appearance = NSAppearance(named: theme.mode == .dark ? .darkAqua : .aqua)
            root?.layer?.backgroundColor = HelmTheme.nsColor(theme.backgroundHex).cgColor
        }

        let title = NSTextField(labelWithString: "Hosts")
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        title.translatesAutoresizingMaskIntoConstraints = false

        let addButton = NSButton(title: "", target: self, action: #selector(newHost))
        addButton.isBordered = false
        addButton.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "Add Host")
        addButton.toolTip = "Add Host (⌘N)"
        addButton.translatesAutoresizingMaskIntoConstraints = false

        searchField.placeholderString = "Find a host or ssh user@host"
        searchField.delegate = self
        searchField.translatesAutoresizingMaskIntoConstraints = false
        // Typing filters the list live (`controlTextDidChange`); Return connects
        // (`control(_:textView:doCommandBy:)`). Deliberately no target/action -
        // an NSSearchField would otherwise fire it mid-typing.

        // Tag filter chips (B4) - a horizontally scrolling row of toggle
        // buttons, one per distinct tag across all hosts. Rebuilt on every
        // `reload()` since the tag set changes as hosts are edited.
        tagsStack.orientation = .horizontal
        tagsStack.spacing = 4
        tagsStack.translatesAutoresizingMaskIntoConstraints = false
        tagsScroll.documentView = tagsStack
        tagsScroll.hasHorizontalScroller = false
        tagsScroll.hasVerticalScroller = false
        tagsScroll.drawsBackground = false
        tagsScroll.translatesAutoresizingMaskIntoConstraints = false
        // No trailing constraint - the stack sizes to its content (the
        // buttons built in `rebuildTagChips`) and the clip view scrolls
        // horizontally once that content is wider than the visible row.
        NSLayoutConstraint.activate([
            tagsStack.leadingAnchor.constraint(equalTo: tagsScroll.contentView.leadingAnchor),
            tagsStack.topAnchor.constraint(equalTo: tagsScroll.contentView.topAnchor),
            tagsStack.bottomAnchor.constraint(equalTo: tagsScroll.contentView.bottomAnchor),
        ])

        // Host list.
        table.headerView = nil
        table.style = .sourceList
        table.rowHeight = 46
        table.backgroundColor = .clear
        table.selectionHighlightStyle = .regular
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(connectSelected)
        table.menu = rowMenu()
        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("host"))
        col.resizingMask = .autoresizingMask
        table.addTableColumn(col)

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false

        connectButton = footerButton("Connect", symbol: "bolt.fill", action: #selector(connectSelected))
        editButton = footerButton("Edit", symbol: "pencil", action: #selector(editSelected))
        deleteButton = footerButton("Delete", symbol: "trash", action: #selector(deleteSelected))
        let footer = NSStackView(views: [connectButton, editButton, deleteButton])
        footer.orientation = .horizontal
        footer.distribution = .fillEqually
        footer.spacing = 6
        footer.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(title)
        root.addSubview(addButton)
        root.addSubview(searchField)
        root.addSubview(tagsScroll)
        root.addSubview(scroll)
        root.addSubview(footer)

        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            title.topAnchor.constraint(equalTo: root.topAnchor, constant: 16),

            addButton.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14),
            addButton.centerYAnchor.constraint(equalTo: title.centerYAnchor),
            addButton.widthAnchor.constraint(equalToConstant: 24),
            addButton.heightAnchor.constraint(equalToConstant: 24),

            searchField.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            searchField.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            searchField.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 12),

            tagsScroll.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            tagsScroll.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            tagsScroll.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 8),
            tagsScroll.heightAnchor.constraint(equalToConstant: 22),

            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 6),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -6),
            scroll.topAnchor.constraint(equalTo: tagsScroll.bottomAnchor, constant: 8),
            scroll.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -8),

            footer.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            footer.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            footer.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -14),
        ])

        store.observe { [weak self] in self?.reload() }
        reload()
        // Land on the pinned "Firstmate" entry by default (Fix 4) - the
        // console already opens its Shell + Mirror pair unconditionally at
        // startup, so this just makes the sidebar's selection match what's
        // already on screen. Only done once here, not inside `reload()`,
        // which also fires on every host add/edit/delete and must not steal
        // whatever the user has selected at that point.
        table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        updateButtons()
    }

    private func footerButton(_ title: String, symbol: String, action: Selector) -> NSButton {
        let b = NSButton(title: " " + title, target: self, action: action)
        b.bezelStyle = .rounded
        b.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        b.imagePosition = .imageLeading
        b.translatesAutoresizingMaskIntoConstraints = false
        return b
    }

    private func rowMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Connect", action: #selector(connectClicked), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Duplicate…", action: #selector(duplicateClicked), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Edit…", action: #selector(editClicked), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Delete", action: #selector(deleteClicked), keyEquivalent: ""))
        for item in menu.items { item.target = self }
        menu.delegate = self
        return menu
    }

    /// The pinned "Firstmate" entry (Fix 4) can only be connected to - it has
    /// no host record to duplicate, edit, or delete.
    func menuNeedsUpdate(_ menu: NSMenu) {
        let editable = !isPinnedClicked
        for item in menu.items where item.action != #selector(connectClicked) {
            item.isEnabled = editable
        }
    }

    // MARK: Data

    private func reload() {
        rebuildTagChips()
        applyFilter(searchField.stringValue)
    }

    /// One toggle button per distinct tag across all hosts, sorted for a
    /// stable layout. Rebuilding on every `reload()` is cheap (a handful of
    /// hosts, a handful of tags) and keeps this in sync with host edits
    /// without a separate change-tracking path.
    private func rebuildTagChips() {
        for v in tagsStack.arrangedSubviews {
            tagsStack.removeArrangedSubview(v)
            v.removeFromSuperview()
        }
        tagButtons.removeAll()
        let allTags = Set(store.hosts.flatMap(\.tags)).sorted()
        selectedTags.formIntersection(allTags)
        for tag in allTags {
            let b = NSButton(title: tag, target: self, action: #selector(tagChipClicked(_:)))
            b.bezelStyle = .inline
            b.setButtonType(.pushOnPushOff)
            b.state = selectedTags.contains(tag) ? .on : .off
            b.font = .systemFont(ofSize: 10)
            b.identifier = NSUserInterfaceItemIdentifier(tag)
            tagButtons[tag] = b
            tagsStack.addArrangedSubview(b)
        }
        tagsScroll.isHidden = allTags.isEmpty
    }

    @objc private func tagChipClicked(_ sender: NSButton) {
        guard let tag = sender.identifier?.rawValue else { return }
        if sender.state == .on {
            selectedTags.insert(tag)
        } else {
            selectedTags.remove(tag)
        }
        applyFilter(searchField.stringValue)
    }

    /// Text filter (label/address/username/tags) + the tag-chip filter,
    /// grouped into `HostListRow.header`/`.host` rows, with the pinned
    /// "Firstmate" entry (Fix 4) always first and unaffected by either
    /// filter - it is a permanent fixture, not a saved host. Headers are
    /// skipped entirely when every visible host shares the same group - the
    /// common "I haven't set up groups yet" case - so this never adds visual
    /// noise for a flat host list.
    private func applyFilter(_ query: String) {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var hosts = store.hosts
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

        var built: [HostListRow] = [.pinned]
        let groupKeys = Set(hosts.map { $0.group?.trimmingCharacters(in: .whitespacesAndNewlines) }.map { ($0?.isEmpty ?? true) ? nil : $0 })
        if groupKeys.count <= 1 {
            built += hosts.map { .host($0) }
        } else {
            let named = groupKeys.compactMap { $0 }.sorted()
            for name in named {
                built.append(.header(name))
                built += hosts.filter { $0.group?.trimmingCharacters(in: .whitespacesAndNewlines) == name }.map { .host($0) }
            }
            let ungrouped = hosts.filter { ($0.group?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "").isEmpty }
            if !ungrouped.isEmpty {
                built.append(.header("Ungrouped"))
                built += ungrouped.map { .host($0) }
            }
        }
        rows = built

        table.reloadData()
        updateButtons()
    }

    private func host(at row: Int) -> Host? {
        guard row >= 0, row < rows.count, case .host(let h) = rows[row] else { return nil }
        return h
    }

    private func isPinnedRow(_ row: Int) -> Bool {
        guard row >= 0, row < rows.count, case .pinned = rows[row] else { return false }
        return true
    }

    private var selectedHost: Host? { host(at: table.selectedRow) }
    private var isPinnedSelected: Bool { isPinnedRow(table.selectedRow) }

    /// The host targeted by a context-menu click (the clicked row), falling back
    /// to the current selection.
    private var clickedHost: Host? {
        host(at: table.clickedRow) ?? selectedHost
    }

    private var isPinnedClicked: Bool {
        table.clickedRow >= 0 ? isPinnedRow(table.clickedRow) : isPinnedSelected
    }

    private func updateButtons() {
        let has = selectedHost != nil
        connectButton.isEnabled = has || isPinnedSelected
        editButton.isEnabled = has
        deleteButton.isEnabled = has
    }

    // MARK: NSTableView

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        switch rows[row] {
        case .pinned:
            let id = NSUserInterfaceItemIdentifier("FirstmateRow")
            let cell = (tableView.makeView(withIdentifier: id, owner: self) as? FirstmateRowView) ?? FirstmateRowView()
            cell.identifier = id
            return cell
        case .header(let name):
            let id = NSUserInterfaceItemIdentifier("HostSectionHeader")
            let cell = (tableView.makeView(withIdentifier: id, owner: self) as? HostSectionHeaderView) ?? HostSectionHeaderView()
            cell.identifier = id
            cell.configure(name: name)
            return cell
        case .host(let host):
            let id = NSUserInterfaceItemIdentifier("HostRow")
            let cell = (tableView.makeView(withIdentifier: id, owner: self) as? HostRowView) ?? HostRowView()
            cell.identifier = id
            cell.configure(with: host)
            return cell
        }
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        switch rows[row] {
        case .header: return 22
        case .pinned, .host: return 46
        }
    }

    /// Section headers are not selectable rows - the pinned entry and hosts are.
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        host(at: row) != nil || isPinnedRow(row)
    }

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        if case .header = rows[row] { return true }
        return false
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        updateButtons()
    }

    // MARK: Connect

    /// The hosts currently visible (unwrapping `.host` rows, skipping headers).
    private var visibleHosts: [Host] {
        rows.compactMap { row in
            if case .host(let h) = row { return h }
            return nil
        }
    }

    /// Return in the quick-connect field: match a saved host, else parse an
    /// ad-hoc `[user@]host[:port]`.
    @objc private func quickConnectFromField() {
        let raw = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else {
            connectSelected()
            return
        }
        // Exact label match wins; otherwise a single filtered result is treated as
        // the intended host.
        if let exact = store.hosts.first(where: { $0.label.caseInsensitiveCompare(raw) == .orderedSame }) {
            connect(exact)
            return
        }
        let visible = visibleHosts
        if visible.count == 1 {
            connect(visible[0])
            return
        }
        if let parsed = HostCatalog.parseQuickConnect(raw) {
            onConnect?(nil, parsed.label, parsed.args, nil, nil, nil)
            searchField.stringValue = ""
            applyFilter("")
            return
        }
        NSSound.beep()
    }

    private func connect(_ host: Host) {
        onConnect?(host.id, host.label, host.sshArguments(allHosts: store.hosts), host.accentHex, host.keyID, host.startupSnippetID)
    }

    @objc private func connectSelected() {
        if isPinnedSelected { onConnectPinned?(); return }
        guard let host = selectedHost else { NSSound.beep(); return }
        connect(host)
    }

    @objc private func editSelected() {
        guard let host = selectedHost else { return }
        presentEditor(for: host)
    }

    @objc private func deleteSelected() {
        guard let host = selectedHost else { return }
        confirmDelete(host)
    }

    // Context-menu variants act on the clicked row.
    @objc private func connectClicked() {
        if isPinnedClicked { onConnectPinned?(); return }
        if let h = clickedHost { connect(h) }
    }
    @objc private func editClicked() { if let h = clickedHost { presentEditor(for: h) } }
    @objc private func deleteClicked() { if let h = clickedHost { confirmDelete(h) } }
    @objc private func duplicateClicked() {
        guard let h = clickedHost else { return }
        var copy = h
        copy.id = UUID()
        copy.label = h.label + " copy"
        store.add(copy)
    }

    private func confirmDelete(_ host: Host) {
        let alert = NSAlert()
        alert.messageText = "Delete \"\(host.label)\"?"
        alert.informativeText = "This removes the saved host. It does not affect any running session."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        if alert.runModal() == .alertFirstButtonReturn {
            store.delete(id: host.id)
        }
    }

    // MARK: Editor

    /// ⌘N / the "+" button: add a new host.
    @objc func newHost() {
        presentEditor(for: nil)
    }

    /// ⌘K / Quick Connect menu: focus the quick-connect field.
    @objc func focusQuickConnect() {
        view.window?.makeFirstResponder(searchField)
    }

    private func presentEditor(for host: Host?) {
        onAddOrEdit?(host)
    }

    // MARK: NSSearchFieldDelegate

    func controlTextDidChange(_ obj: Notification) {
        applyFilter(searchField.stringValue)
    }

    /// Return in the quick-connect field connects; everything else is left to the
    /// field editor (so typing, arrows, and delete behave normally).
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard control === searchField, commandSelector == #selector(NSResponder.insertNewline(_:)) else {
            return false
        }
        quickConnectFromField()
        return true
    }
}

// MARK: - Section header row

/// A group section header (B4): a small-caps label, matching the
/// `NSTableView.style = .sourceList` header look elsewhere in AppKit.
final class HostSectionHeaderView: NSTableCellView {

    private let label = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(name: String) {
        label.stringValue = name.uppercased()
    }
}

// MARK: - Host row

/// One host row: a tinted SF Symbol, the label, and a `user@host[:port]` subtitle.
final class HostRowView: NSTableCellView {

    private let icon = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let subtitle = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        build()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func build() {
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 18, weight: .regular)

        title.font = .systemFont(ofSize: 13, weight: .medium)
        title.lineBreakMode = .byTruncatingTail
        title.translatesAutoresizingMaskIntoConstraints = false

        subtitle.font = .systemFont(ofSize: 11)
        subtitle.textColor = .secondaryLabelColor
        subtitle.lineBreakMode = .byTruncatingTail
        subtitle.translatesAutoresizingMaskIntoConstraints = false

        addSubview(icon)
        addSubview(title)
        addSubview(subtitle)

        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 22),
            icon.heightAnchor.constraint(equalToConstant: 22),

            title.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10),
            title.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            title.topAnchor.constraint(equalTo: topAnchor, constant: 6),

            subtitle.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            subtitle.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            subtitle.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 1),
        ])
    }

    func configure(with host: Host) {
        let symbol = NSImage(systemSymbolName: host.iconSymbol, accessibilityDescription: host.label)
            ?? NSImage(systemSymbolName: HostCatalog.defaultIcon, accessibilityDescription: host.label)
        icon.image = symbol
        icon.contentTintColor = HelmTheme.nsColor(host.accentHex)
        title.stringValue = host.label
        subtitle.stringValue = host.subtitle
    }
}

// MARK: - Pinned "Firstmate" row (Fix 4)

/// The permanent, non-deletable first row: an anchor glyph (visually distinct
/// from every user-added host's SF Symbol choice) tinted with the Helm accent
/// rather than a per-host colour, since there is no `Host` behind it.
/// Connecting it opens the same Shell + Mirror pair the console has always
/// opened at startup - see `ConsoleController.openFirstmateHost`.
final class FirstmateRowView: NSTableCellView {

    private let icon = NSImageView()
    private let title = NSTextField(labelWithString: "Firstmate")
    private let subtitle = NSTextField(labelWithString: "Shell + Mirror")

    init() {
        super.init(frame: .zero)
        build()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func build() {
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 18, weight: .regular)
        icon.image = NSImage(systemSymbolName: "anchor", accessibilityDescription: "Firstmate")
        icon.contentTintColor = HelmTheme.nsColor(ThemeManager.shared.theme.accentHex)

        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.lineBreakMode = .byTruncatingTail
        title.translatesAutoresizingMaskIntoConstraints = false

        subtitle.font = .systemFont(ofSize: 11)
        subtitle.textColor = .secondaryLabelColor
        subtitle.lineBreakMode = .byTruncatingTail
        subtitle.translatesAutoresizingMaskIntoConstraints = false

        addSubview(icon)
        addSubview(title)
        addSubview(subtitle)

        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 22),
            icon.heightAnchor.constraint(equalToConstant: 22),

            title.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10),
            title.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            title.topAnchor.constraint(equalTo: topAnchor, constant: 6),

            subtitle.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            subtitle.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            subtitle.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 1),
        ])

        ThemeManager.shared.observe { [weak self] theme in
            self?.icon.contentTintColor = HelmTheme.nsColor(theme.accentHex)
        }
    }
}
