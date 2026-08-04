// Firstmate Cockpit - native macOS app.
//
// The Hosts sidebar (design report A2/A3, Section D Phase 1): a Termius-style
// list of saved SSH hosts with per-host icons, a quick-connect field, and add /
// edit / delete. "Connect" hands a `ssh` argv back to the console, which opens it
// as a new tab in the Phase 0 tab collection.
//
// The sidebar is decoupled from the terminal: it takes a `HostStore` and an
// `onConnect` closure. It never touches `ConsoleController` or SwiftTerm.

import AppKit

final class HostsSidebarController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {

    private let store: HostStore

    /// Open an ssh session: (tab label, ssh argv, host accent hex). Wired by the
    /// app delegate to `ConsoleController.openSSH`.
    var onConnect: ((String, [String], String?) -> Void)?

    // MARK: Views

    private let searchField = NSSearchField()
    private let table = NSTableView()
    private var connectButton = NSButton()
    private var editButton = NSButton()
    private var deleteButton = NSButton()

    /// The hosts currently shown (filtered by the search text).
    private var filtered: [Host] = []

    init(store: HostStore) {
        self.store = store
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: Layout

    override func loadView() {
        // A translucent sidebar material so the pane reads as a native source
        // list and adapts to light/dark on its own (independent of the terminal's
        // Helm toggle).
        let root = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: 260, height: 660))
        root.material = .sidebar
        root.blendingMode = .behindWindow
        root.state = .followsWindowActiveState
        view = root

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

            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 6),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -6),
            scroll.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 10),
            scroll.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -8),

            footer.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            footer.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            footer.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -14),
        ])

        store.onChange = { [weak self] in self?.reload() }
        reload()
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
        return menu
    }

    // MARK: Data

    private func reload() {
        applyFilter(searchField.stringValue)
    }

    private func applyFilter(_ query: String) {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if q.isEmpty {
            filtered = store.hosts
        } else {
            filtered = store.hosts.filter { host in
                host.label.lowercased().contains(q)
                    || host.address.lowercased().contains(q)
                    || host.username.lowercased().contains(q)
                    || host.tags.contains { $0.lowercased().contains(q) }
            }
        }
        table.reloadData()
        updateButtons()
    }

    private var selectedHost: Host? {
        let row = table.selectedRow
        guard row >= 0, row < filtered.count else { return nil }
        return filtered[row]
    }

    /// The host targeted by a context-menu click (the clicked row), falling back
    /// to the current selection.
    private var clickedHost: Host? {
        let row = table.clickedRow
        if row >= 0, row < filtered.count { return filtered[row] }
        return selectedHost
    }

    private func updateButtons() {
        let has = selectedHost != nil
        connectButton.isEnabled = has
        editButton.isEnabled = has
        deleteButton.isEnabled = has
    }

    // MARK: NSTableView

    func numberOfRows(in tableView: NSTableView) -> Int { filtered.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("HostRow")
        let cell = (tableView.makeView(withIdentifier: id, owner: self) as? HostRowView) ?? HostRowView()
        cell.identifier = id
        cell.configure(with: filtered[row])
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        updateButtons()
    }

    // MARK: Connect

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
        if filtered.count == 1 {
            connect(filtered[0])
            return
        }
        if let parsed = HostCatalog.parseQuickConnect(raw) {
            onConnect?(parsed.label, parsed.args, nil)
            searchField.stringValue = ""
            applyFilter("")
            return
        }
        NSSound.beep()
    }

    private func connect(_ host: Host) {
        onConnect?(host.label, host.sshArguments(), host.accentHex)
    }

    @objc private func connectSelected() {
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
    @objc private func connectClicked() { if let h = clickedHost { connect(h) } }
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
        let editor = HostEditorController(host: host)
        editor.onSave = { [weak self] saved in
            guard let self else { return }
            if self.store.host(id: saved.id) != nil {
                self.store.update(saved)
            } else {
                self.store.add(saved)
            }
        }
        editor.onDelete = { [weak self] id in
            self?.store.delete(id: id)
        }
        presentAsSheet(editor)
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
