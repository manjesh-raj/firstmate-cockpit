// Firstmate Cockpit - native macOS app.
//
// The host-details editor (design report A2/A3, Section D Phase 1). A sheet with
// the Termius "New Host" fields - Label, Address, Port, Username, a credentials
// section, and the A3 icon/colour pickers. Add, edit, and delete all route back
// to the sidebar via closures; this view knows nothing about the host store.
//
// Phase 2 replaces the raw "key file path" field with a "Choose a key" popup
// sourced from the saved-keys Keychain (`SSHKeyStore`) - the host now carries
// a `keyID` reference, never a path, per design report Section A2/C3.

import AppKit

final class HostEditorController: NSViewController {

    /// The host being edited; `nil` for a brand-new host.
    private let editing: Host?

    /// Saved keys to offer in the "Choose a key" popup - a snapshot taken when
    /// the sheet opens (matches how the icon/colour catalogues are snapshotted
    /// too; a key added while this sheet is open won't appear until reopened).
    private let keys: [SSHKey]

    /// Called with the assembled host on Save. The caller persists it.
    var onSave: ((Host) -> Void)?
    /// Called with the host id on Delete (only offered when editing).
    var onDelete: ((UUID) -> Void)?

    // MARK: Fields

    private let labelField = NSTextField()
    private let addressField = NSTextField()
    private let portField = NSTextField()
    private let usernameField = NSTextField()
    private let passwordField = NSSecureTextField()
    private let keyPopup = NSPopUpButton()

    /// Current icon/colour selection, seeded from the host (or the defaults).
    private var selectedIcon: String
    private var selectedAccent: String
    private var iconButtons: [NSButton] = []
    private var colorButtons: [NSButton] = []

    // MARK: Init

    init(host: Host?, keys: [SSHKey]) {
        self.editing = host
        self.keys = keys
        self.selectedIcon = host?.iconSymbol ?? HostCatalog.defaultIcon
        self.selectedAccent = host?.accentHex ?? HostCatalog.defaultAccent
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: Layout

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 480, height: 520))
        view = root

        let title = NSTextField(labelWithString: editing == nil ? "New Host" : "Edit Host")
        title.font = .systemFont(ofSize: 15, weight: .semibold)

        configure(labelField, placeholder: "Label (e.g. Prod bastion)", value: editing?.label)
        configure(addressField, placeholder: "Address (hostname or IP)", value: editing?.address)
        configure(portField, placeholder: "22", value: editing.map { String($0.port) } ?? "22")
        portField.formatter = intFormatter()
        configure(usernameField, placeholder: "Username", value: editing?.username)
        configure(passwordField, placeholder: "Password (optional)", value: editing?.password)
        buildKeyPopup()

        let credCaption = caption("Password is used for this session only and never written to disk. "
            + "A chosen key is resolved from the Keychain at connect time (see the Keys screen, ⌘⇧K); "
            + "with no key set, ssh falls back to the system agent.")

        let iconRow = buildIconPicker()
        let colorRow = buildColorPicker()

        let grid = NSGridView(views: [
            [rowLabel("Label"), labelField],
            [rowLabel("Address"), addressField],
            [rowLabel("Port"), portField],
            [rowLabel("Username"), usernameField],
            [rowLabel("Password"), passwordField],
            [rowLabel("Key"), keyPopup],
            [rowLabel("Icon"), iconRow],
            [rowLabel("Color"), colorRow],
        ])
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.rowSpacing = 12
        grid.columnSpacing = 12
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).xPlacement = .fill
        grid.column(at: 1).width = 320

        // Bottom bar: Delete on the left (editing only), Cancel + Save on the right.
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancel.bezelStyle = .rounded
        cancel.keyEquivalent = "\u{1b}" // Esc
        let save = NSButton(title: "Save", target: self, action: #selector(save))
        save.bezelStyle = .rounded
        save.keyEquivalent = "\r" // Return
        var bottomViews: [NSView] = []
        if editing != nil {
            let del = NSButton(title: "Delete", target: self, action: #selector(deleteHost))
            del.bezelStyle = .rounded
            del.contentTintColor = .systemRed
            bottomViews.append(del)
        }
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        bottomViews += [spacer, cancel, save]
        let bottom = NSStackView(views: bottomViews)
        bottom.orientation = .horizontal
        bottom.spacing = 10

        let stack = NSStackView(views: [title, grid, credCaption, bottom])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -20),
            bottom.widthAnchor.constraint(equalTo: stack.widthAnchor),
            credCaption.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(labelField)
    }

    // MARK: Field helpers

    private func configure(_ field: NSTextField, placeholder: String, value: String?) {
        field.placeholderString = placeholder
        field.stringValue = value ?? ""
        field.translatesAutoresizingMaskIntoConstraints = false
        field.lineBreakMode = .byTruncatingTail
    }

    private func rowLabel(_ text: String) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.font = .systemFont(ofSize: 12)
        l.textColor = .secondaryLabelColor
        return l
    }

    private func caption(_ text: String) -> NSTextField {
        let l = NSTextField(wrappingLabelWithString: text)
        l.font = .systemFont(ofSize: 11)
        l.textColor = .tertiaryLabelColor
        l.translatesAutoresizingMaskIntoConstraints = false
        return l
    }

    private func intFormatter() -> NumberFormatter {
        let f = NumberFormatter()
        f.numberStyle = .none
        f.minimum = 1
        f.maximum = 65_535
        f.allowsFloats = false
        return f
    }

    // MARK: Key popup (Phase 2)

    /// "None" plus every saved key, by label; selection carries the key's
    /// `UUID` as `representedObject` so `save()` reads it back directly.
    private func buildKeyPopup() {
        keyPopup.translatesAutoresizingMaskIntoConstraints = false
        keyPopup.addItem(withTitle: "None (use system ssh agent)")
        for key in keys {
            keyPopup.addItem(withTitle: "\(key.label) (\(key.type.displayName))")
            keyPopup.lastItem?.representedObject = key.id
        }
        if let id = editing?.keyID, let item = keyPopup.itemArray.first(where: { ($0.representedObject as? UUID) == id }) {
            keyPopup.select(item)
        } else {
            keyPopup.selectItem(at: 0)
        }
    }

    // MARK: Icon + colour pickers (A3)

    private func buildIconPicker() -> NSView {
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.spacing = 4
        for symbol in HostCatalog.icons {
            let b = NSButton(title: "", target: self, action: #selector(pickIcon(_:)))
            b.isBordered = false
            b.wantsLayer = true
            b.layer?.cornerRadius = 6
            b.imageScaling = .scaleProportionallyDown
            b.image = NSImage(systemSymbolName: symbol, accessibilityDescription: symbol)
            b.identifier = NSUserInterfaceItemIdentifier(symbol)
            b.toolTip = symbol
            NSLayoutConstraint.activate([
                b.widthAnchor.constraint(equalToConstant: 30),
                b.heightAnchor.constraint(equalToConstant: 28),
            ])
            iconButtons.append(b)
            stack.addArrangedSubview(b)
        }
        styleIconButtons()
        return stack
    }

    private func buildColorPicker() -> NSView {
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.spacing = 6
        for hex in HostCatalog.accents {
            let b = NSButton(title: "", target: self, action: #selector(pickColor(_:)))
            b.isBordered = false
            b.wantsLayer = true
            b.layer?.cornerRadius = 11
            b.layer?.backgroundColor = HelmTheme.nsColor(hex).cgColor
            b.identifier = NSUserInterfaceItemIdentifier(hex)
            b.toolTip = "#\(hex)"
            NSLayoutConstraint.activate([
                b.widthAnchor.constraint(equalToConstant: 22),
                b.heightAnchor.constraint(equalToConstant: 22),
            ])
            colorButtons.append(b)
            stack.addArrangedSubview(b)
        }
        styleColorButtons()
        return stack
    }

    @objc private func pickIcon(_ sender: NSButton) {
        selectedIcon = sender.identifier?.rawValue ?? selectedIcon
        styleIconButtons()
    }

    @objc private func pickColor(_ sender: NSButton) {
        selectedAccent = sender.identifier?.rawValue ?? selectedAccent
        styleIconButtons() // recolour the selected icon preview
        styleColorButtons()
    }

    /// Selected icon reads in the chosen accent and sits on a tinted chip; the
    /// rest are neutral.
    private func styleIconButtons() {
        let accent = HelmTheme.nsColor(selectedAccent)
        for b in iconButtons {
            let isSel = b.identifier?.rawValue == selectedIcon
            b.contentTintColor = isSel ? accent : .secondaryLabelColor
            b.layer?.backgroundColor = (isSel ? accent.withAlphaComponent(0.18) : .clear).cgColor
        }
    }

    /// Selected swatch gets a ring so the choice is obvious.
    private func styleColorButtons() {
        for b in colorButtons {
            let isSel = b.identifier?.rawValue == selectedAccent
            b.layer?.borderWidth = isSel ? 2.5 : 0
            b.layer?.borderColor = NSColor.labelColor.cgColor
        }
    }

    // MARK: Actions

    @objc private func save() {
        let label = labelField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let address = addressField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !address.isEmpty else {
            flag(addressField)
            return
        }
        var host = editing ?? Host(label: "", address: "")
        host.label = label.isEmpty ? address : label
        host.address = address
        host.port = Int(portField.stringValue) ?? 22
        host.username = usernameField.stringValue.trimmingCharacters(in: .whitespaces)
        let pw = passwordField.stringValue
        host.password = pw.isEmpty ? nil : pw
        host.keyID = keyPopup.selectedItem?.representedObject as? UUID
        host.iconSymbol = selectedIcon
        host.accentHex = selectedAccent

        onSave?(host)
        dismiss(self)
    }

    @objc private func deleteHost() {
        guard let id = editing?.id else { return }
        onDelete?(id)
        dismiss(self)
    }

    @objc private func cancel() {
        dismiss(self)
    }

    /// Briefly flash a required field's focus ring when it is empty.
    private func flag(_ field: NSTextField) {
        view.window?.makeFirstResponder(field)
        NSSound.beep()
    }
}
