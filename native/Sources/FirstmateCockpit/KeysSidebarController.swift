// Firstmate Cockpit - native macOS app.
//
// The saved-keys "Keychain" screen (design report Section A1, "a keychain
// screen the captain can browse"). Deliberately built to match the Hosts
// sidebar's visual language - same `NSVisualEffectView` sidebar material,
// same source-list table, same footer-button row - but hosted in its own
// window (via `AppDelegate.showKeysWindow`) rather than a third split-view
// pane, since keys are managed far less often than hosts are connected to.
//
// Like `HostsSidebarController`, this view is decoupled from the console: it
// only knows about `SSHKeyStore` (non-secret metadata) and hands persistence
// of the Keychain-backed secrets to the editor's callbacks.

import AppKit

final class KeysSidebarController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {

    private let store: SSHKeyStore

    private let table = NSTableView()
    private var editButton = NSButton()
    private var deleteButton = NSButton()

    init(store: SSHKeyStore) {
        self.store = store
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: Layout

    override func loadView() {
        // Theme-audit task: this was `NSVisualEffectView(.sidebar,
        // .behindWindow)`, the same material/blending pair that rendered an
        // incorrect tint for both the Hosts sidebar (Fix 6, already fixed)
        // and the icon rail (this task) - `.behindWindow` blending composites
        // against whatever is behind the *window*, not other content inside
        // it, which is wrong for a standalone window's own root. A plain,
        // theme-driven solid background matches every other full-size
        // destination/window in this app.
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 380, height: 520))
        root.wantsLayer = true
        view = root
        ThemeManager.shared.observe { [weak root] theme in
            root?.appearance = NSAppearance(named: theme.mode == .dark ? .darkAqua : .aqua)
            root?.layer?.backgroundColor = HelmTheme.nsColor(theme.chromeBackgroundHex).cgColor
        }

        let title = NSTextField(labelWithString: "SSH Keys")
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        title.translatesAutoresizingMaskIntoConstraints = false

        let addButton = NSButton(title: "", target: self, action: #selector(newKey))
        addButton.isBordered = false
        addButton.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "New Key")
        addButton.toolTip = "New Key"
        addButton.translatesAutoresizingMaskIntoConstraints = false

        let caption = NSTextField(wrappingLabelWithString:
            "Private key material and passphrases are stored in the macOS Keychain, gated by Touch ID."
        )
        caption.font = .systemFont(ofSize: 11)
        caption.textColor = .tertiaryLabelColor
        caption.translatesAutoresizingMaskIntoConstraints = false

        table.headerView = nil
        table.style = .sourceList
        table.rowHeight = 46
        table.backgroundColor = .clear
        table.selectionHighlightStyle = .regular
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(editSelected)
        table.menu = rowMenu()
        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("key"))
        col.resizingMask = .autoresizingMask
        table.addTableColumn(col)

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false

        editButton = footerButton("Edit", symbol: "pencil", action: #selector(editSelected))
        deleteButton = footerButton("Delete", symbol: "trash", action: #selector(deleteSelected))
        let footer = NSStackView(views: [editButton, deleteButton])
        footer.orientation = .horizontal
        footer.distribution = .fillEqually
        footer.spacing = 6
        footer.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(title)
        root.addSubview(addButton)
        root.addSubview(caption)
        root.addSubview(scroll)
        root.addSubview(footer)

        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            title.topAnchor.constraint(equalTo: root.topAnchor, constant: 16),

            addButton.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14),
            addButton.centerYAnchor.constraint(equalTo: title.centerYAnchor),
            addButton.widthAnchor.constraint(equalToConstant: 24),
            addButton.heightAnchor.constraint(equalToConstant: 24),

            caption.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            caption.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            caption.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 8),

            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 6),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -6),
            scroll.topAnchor.constraint(equalTo: caption.bottomAnchor, constant: 10),
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
        menu.addItem(NSMenuItem(title: "Edit…", action: #selector(editClicked), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Copy Public Key", action: #selector(copyPublicKeyClicked), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Delete", action: #selector(deleteClicked), keyEquivalent: ""))
        for item in menu.items { item.target = self }
        return menu
    }

    // MARK: Data

    private func reload() {
        table.reloadData()
        updateButtons()
    }

    private var selectedKey: SSHKey? {
        let row = table.selectedRow
        guard row >= 0, row < store.keys.count else { return nil }
        return store.keys[row]
    }

    private var clickedKey: SSHKey? {
        let row = table.clickedRow
        if row >= 0, row < store.keys.count { return store.keys[row] }
        return selectedKey
    }

    private func updateButtons() {
        let has = selectedKey != nil
        editButton.isEnabled = has
        deleteButton.isEnabled = has
    }

    // MARK: NSTableView

    func numberOfRows(in tableView: NSTableView) -> Int { store.keys.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("KeyRow")
        let cell = (tableView.makeView(withIdentifier: id, owner: self) as? KeyRowView) ?? KeyRowView()
        cell.identifier = id
        cell.configure(with: store.keys[row])
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        updateButtons()
    }

    // MARK: Actions

    /// ⌘N-equivalent for this window / the "+" button: add a new key.
    @objc func newKey() {
        presentEditor(for: nil)
    }

    @objc private func editSelected() {
        guard let key = selectedKey else { return }
        presentEditor(for: key)
    }

    @objc private func deleteSelected() {
        guard let key = selectedKey else { return }
        confirmDelete(key)
    }

    @objc private func editClicked() { if let k = clickedKey { presentEditor(for: k) } }
    @objc private func deleteClicked() { if let k = clickedKey { confirmDelete(k) } }
    @objc private func copyPublicKeyClicked() {
        guard let k = clickedKey else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(k.publicKey, forType: .string)
    }

    private func confirmDelete(_ key: SSHKey) {
        let alert = NSAlert()
        alert.messageText = "Delete \"\(key.label)\"?"
        alert.informativeText = "This removes the key's Keychain entry (private key and passphrase). "
            + "Any host still referencing it will fall back to the system ssh agent."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        if alert.runModal() == .alertFirstButtonReturn {
            store.delete(id: key.id)
        }
    }

    // MARK: Editor

    private func presentEditor(for key: SSHKey?) {
        let editor = KeyEditorController(key: key)
        editor.onSave = { [weak self] newKey, privateKeyData, passphrase in
            self?.persistNewKey(newKey, privateKeyData: privateKeyData, passphrase: passphrase)
        }
        editor.onUpdate = { [weak self] updatedKey, newPassphrase in
            self?.persistUpdatedKey(updatedKey, newPassphrase: newPassphrase)
        }
        editor.onDelete = { [weak self] id in
            self?.store.delete(id: id)
        }
        presentAsSheet(editor)
    }

    /// Create mode: `SSHKeyStore.addNew` writes the Keychain secrets before
    /// adding the metadata.
    private func persistNewKey(_ key: SSHKey, privateKeyData: Data, passphrase: String?) {
        do {
            try store.addNew(key, privateKeyData: privateKeyData, passphrase: passphrase)
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
        store.update(key)
        Toast.show(in: view, message: "\u{201C}\(key.label)\u{201D} saved")
    }

    private func presentError(_ error: Error, context: String) {
        let alert = NSAlert()
        alert.messageText = context
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .critical
        alert.runModal()
    }
}

// MARK: - Key row

/// One key row: a tinted "key.fill" glyph (per-type accent, `SSHKeyType.accentHex`),
/// the label, and a "<Type> · <fingerprint>" subtitle - matching `HostRowView`.
final class KeyRowView: NSTableCellView {

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

    func configure(with key: SSHKey) {
        icon.image = NSImage(systemSymbolName: "key.fill", accessibilityDescription: key.label)
        icon.contentTintColor = HelmTheme.nsColor(key.type.accentHex)
        title.stringValue = key.label
        subtitle.stringValue = key.hasPassphrase ? "\(key.subtitle) · passphrase set" : key.subtitle
    }
}
