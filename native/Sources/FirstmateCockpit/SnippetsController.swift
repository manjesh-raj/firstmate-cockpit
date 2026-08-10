// Manjesh Grand Line - native macOS app.
//
// The "Snippets" screen (design report Section B2 + B5, Section D Phase 3): a
// saved-command library, managed from its own window in the same visual
// language as the Hosts/Keys sidebars. "Run" sends the snippet's command text
// plus Enter to the console's active tab via `onRun`; the console itself
// knows nothing about this store.

import AppKit

final class SnippetsController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {

    private let store: SnippetStore

    /// Run a snippet in the console's active/frontmost tab. Wired by the app
    /// delegate to `ConsoleController.runSnippetInActiveTab`.
    var onRun: ((Snippet) -> Void)?

    private let table = NSTableView()
    private var runButton = NSButton()
    private var editButton = NSButton()
    private var deleteButton = NSButton()

    init(store: SnippetStore) {
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
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 480))
        root.wantsLayer = true
        view = root
        ThemeManager.shared.observe { [weak root] theme in
            root?.appearance = NSAppearance(named: theme.mode == .dark ? .darkAqua : .aqua)
            root?.layer?.backgroundColor = HelmTheme.nsColor(theme.chromeBackgroundHex).cgColor
        }

        let title = NSTextField(labelWithString: "Snippets")
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        title.translatesAutoresizingMaskIntoConstraints = false

        let addButton = NSButton(title: "", target: self, action: #selector(newSnippet))
        addButton.isBordered = false
        addButton.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "New Snippet")
        addButton.toolTip = "New Snippet"
        addButton.translatesAutoresizingMaskIntoConstraints = false

        let caption = NSTextField(wrappingLabelWithString: "Run sends a snippet's command to the active terminal tab.")
        caption.font = .systemFont(ofSize: 11)
        caption.textColor = .tertiaryLabelColor
        caption.translatesAutoresizingMaskIntoConstraints = false

        table.headerView = nil
        table.style = .sourceList
        table.rowHeight = 42
        table.backgroundColor = .clear
        table.selectionHighlightStyle = .regular
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(runSelected)
        table.menu = rowMenu()
        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("snippet"))
        col.resizingMask = .autoresizingMask
        table.addTableColumn(col)

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false

        runButton = footerButton("Run", symbol: "play.fill", action: #selector(runSelected))
        editButton = footerButton("Edit", symbol: "pencil", action: #selector(editSelected))
        deleteButton = footerButton("Delete", symbol: "trash", action: #selector(deleteSelected))
        let footer = NSStackView(views: [runButton, editButton, deleteButton])
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
        menu.addItem(NSMenuItem(title: "Run", action: #selector(runClicked), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Edit\u{2026}", action: #selector(editClicked), keyEquivalent: ""))
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

    private var selectedSnippet: Snippet? {
        let row = table.selectedRow
        guard row >= 0, row < store.snippets.count else { return nil }
        return store.snippets[row]
    }

    private var clickedSnippet: Snippet? {
        let row = table.clickedRow
        if row >= 0, row < store.snippets.count { return store.snippets[row] }
        return selectedSnippet
    }

    private func updateButtons() {
        let has = selectedSnippet != nil
        runButton.isEnabled = has
        editButton.isEnabled = has
        deleteButton.isEnabled = has
    }

    // MARK: NSTableView

    func numberOfRows(in tableView: NSTableView) -> Int { store.snippets.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("SnippetRow")
        let cell = (tableView.makeView(withIdentifier: id, owner: self) as? SnippetRowView) ?? SnippetRowView()
        cell.identifier = id
        cell.configure(with: store.snippets[row])
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        updateButtons()
    }

    // MARK: Actions

    /// The "+" button / Snippets menu -> New Snippet\u{2026}.
    @objc func newSnippet() {
        presentEditor(for: nil)
    }

    @objc private func runSelected() { if let s = selectedSnippet { onRun?(s) } }
    @objc private func editSelected() { if let s = selectedSnippet { presentEditor(for: s) } }
    @objc private func deleteSelected() { if let s = selectedSnippet { confirmDelete(s) } }

    @objc private func runClicked() { if let s = clickedSnippet { onRun?(s) } }
    @objc private func editClicked() { if let s = clickedSnippet { presentEditor(for: s) } }
    @objc private func deleteClicked() { if let s = clickedSnippet { confirmDelete(s) } }

    private func confirmDelete(_ snippet: Snippet) {
        let alert = NSAlert()
        alert.messageText = "Delete \"\(snippet.label)\"?"
        alert.informativeText = "Any host using this as its startup snippet will fall back to no startup command."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        if alert.runModal() == .alertFirstButtonReturn {
            store.delete(id: snippet.id)
        }
    }

    private func presentEditor(for snippet: Snippet?) {
        let editor = SnippetEditorController(snippet: snippet)
        editor.onSave = { [weak self] saved in
            guard let self else { return }
            if self.store.snippet(id: saved.id) != nil {
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
}

// MARK: - Snippet row

/// One snippet row: a "terminal" glyph, the label, and a truncated command preview.
final class SnippetRowView: NSTableCellView {

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
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 16, weight: .regular)
        icon.contentTintColor = .secondaryLabelColor
        icon.image = NSImage(systemSymbolName: "chevron.left.forwardslash.chevron.right", accessibilityDescription: "Snippet")

        title.font = .systemFont(ofSize: 13, weight: .medium)
        title.lineBreakMode = .byTruncatingTail
        title.translatesAutoresizingMaskIntoConstraints = false

        subtitle.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        subtitle.textColor = .secondaryLabelColor
        subtitle.lineBreakMode = .byTruncatingTail
        subtitle.translatesAutoresizingMaskIntoConstraints = false

        addSubview(icon)
        addSubview(title)
        addSubview(subtitle)

        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 20),
            icon.heightAnchor.constraint(equalToConstant: 20),

            title.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10),
            title.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            title.topAnchor.constraint(equalTo: topAnchor, constant: 5),

            subtitle.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            subtitle.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            subtitle.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 1),
        ])
    }

    func configure(with snippet: Snippet) {
        title.stringValue = snippet.label
        subtitle.stringValue = snippet.subtitle
    }
}
