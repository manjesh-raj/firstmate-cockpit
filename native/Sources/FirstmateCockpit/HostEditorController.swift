// Firstmate Cockpit - native macOS app.
//
// The host-details editor (design report A2/A3, Section D Phase 1). A sheet with
// the Termius "New Host" fields - Label, Address, Port, Username, a credentials
// section (session password + on-disk key path), and the A3 icon/colour pickers.
// Add, edit, and delete all route back to the sidebar via closures; this view
// knows nothing about the store.

import AppKit

final class HostEditorController: NSViewController {

    /// The host being edited; `nil` for a brand-new host.
    private let editing: Host?

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
    private let keyPathField = NSTextField()

    /// Current icon/colour selection, seeded from the host (or the defaults).
    private var selectedIcon: String
    private var selectedAccent: String
    private var iconButtons: [NSButton] = []
    private var colorButtons: [NSButton] = []

    // MARK: Init

    init(host: Host?) {
        self.editing = host
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
        configure(keyPathField, placeholder: "Private key path (optional)", value: editing?.keyPath)

        let chooseKey = NSButton(title: "Choose…", target: self, action: #selector(chooseKeyFile))
        chooseKey.bezelStyle = .rounded
        let keyRow = NSStackView(views: [keyPathField, chooseKey])
        keyRow.orientation = .horizontal
        keyRow.spacing = 8
        keyPathField.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let credCaption = caption("Password is used for this session only and never written to disk. "
            + "A key path or the system ssh agent is the persisted credential.")

        let iconRow = buildIconPicker()
        let colorRow = buildColorPicker()

        let grid = NSGridView(views: [
            [rowLabel("Label"), labelField],
            [rowLabel("Address"), addressField],
            [rowLabel("Port"), portField],
            [rowLabel("Username"), usernameField],
            [rowLabel("Password"), passwordField],
            [rowLabel("Key file"), keyRow],
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

    @objc private func chooseKeyFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose a private key file (referenced by path; not copied)."
        // ~/.ssh is where keys usually live; show hidden files so it is reachable.
        panel.showsHiddenFiles = true
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh")
        if panel.runModal() == .OK, let url = panel.url {
            keyPathField.stringValue = url.path
        }
    }

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
        let kp = keyPathField.stringValue.trimmingCharacters(in: .whitespaces)
        host.keyPath = kp.isEmpty ? nil : kp
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
