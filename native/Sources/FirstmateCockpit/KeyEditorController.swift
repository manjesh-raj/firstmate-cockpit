// Firstmate Cockpit - native macOS app.
//
// The New Key sheet (design report Section A1 + Section D Phase 2). Mirrors
// the real Termius keychain form: **Label**, then either **Generate**
// (Ed25519 default, RSA option, optional Passphrase) or **Import** (paste or
// drag-and-drop / file-picker a PEM / OpenSSH / PPK file), an optional
// **Certificate**, and a **derived, read-only** public key with a copy button
// - per the report's accuracy note, the real form has no separate "paste your
// public key" input, so this one doesn't either.
//
// This view never touches the Keychain or `SSHKeyStore` directly. On Save it
// hands the caller (`KeysSidebarController`) either a freshly generated/
// imported `SSHKey` + raw private-key bytes + passphrase (create mode), or an
// updated `SSHKey` + an optional new passphrase (edit mode) - the same
// "editor computes, caller persists" split `HostEditorController` already uses.

import AppKit

final class KeyEditorController: NSViewController {

    /// `nil` for a brand-new key; set for editing an existing one's label,
    /// certificate, and (optionally) passphrase. Edit mode never re-derives or
    /// re-stores the private key itself.
    private let editing: SSHKey?

    /// Create mode: hands back the new key's metadata, its raw private-key
    /// bytes (for the caller to write to the Keychain), and the passphrase
    /// used (if any, so the caller can store it too).
    var onSave: ((SSHKey, Data, String?) -> Void)?
    /// Edit mode: hands back updated metadata and, only if the passphrase
    /// field was actually typed into, a new passphrase to store. `nil` means
    /// "leave the stored passphrase untouched."
    var onUpdate: ((SSHKey, String?) -> Void)?
    var onDelete: ((UUID) -> Void)?
    /// Fired when the sheet is dismissed via Cancel (not Save/Delete) - lets a
    /// caller that changed state just to open this sheet (the host editor's
    /// inline "+ New Key…", Fix 5) revert it.
    var onCancel: (() -> Void)?

    // MARK: Shared fields

    private let labelField = NSTextField()
    private let certificateView = NSTextView()
    private let publicKeyView = NSTextView()
    private let fingerprintLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let saveButton = NSButton()

    // MARK: Create-mode fields

    private let modeSwitch = NSSegmentedControl()
    private let typeSwitch = NSSegmentedControl()
    /// Edit mode's single passphrase field ("leave blank to keep current").
    private let passphraseField = NSSecureTextField()
    /// Generate and Import each need their own passphrase control - one sets
    /// a passphrase on a brand-new key, the other supplies the existing one
    /// to decrypt - so, unlike every other create-mode field, this can't be a
    /// single shared `NSTextField` instance (a view can only live in one
    /// parent at a time; sharing one here silently detaches it from whichever
    /// panel built it first).
    private let generatePassphraseField = NSSecureTextField()
    private let importPassphraseField = NSSecureTextField()
    private let importDropZone = KeyDropZone()
    private let importTextView = NSTextView()
    private let generatePanel = NSView()
    private let importPanel = NSView()

    /// The last successfully generated/verified private-key bytes - `saveButton`
    /// stays disabled until this is non-nil, so a half-filled form can't be saved.
    private var pendingPrivateKey: Data?
    private var pendingPublicKeyLine: String?
    private var pendingFingerprint: String?
    private var pendingType: SSHKeyType = .ed25519
    /// The passphrase in effect for `pendingPrivateKey`, captured at the moment
    /// generate/verify succeeded - not re-read from a field at save time, since
    /// which field is authoritative depends on which mode produced the key.
    private var pendingPassphrase: String?

    // MARK: Init

    init(key: SSHKey?) {
        self.editing = key
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: Layout

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 520, height: 620))
        view = root

        let title = NSTextField(labelWithString: editing == nil ? "New Key" : "Edit Key")
        title.font = .systemFont(ofSize: 15, weight: .semibold)

        configure(labelField, placeholder: "Label (e.g. Prod bastion key)", value: editing?.label)

        let stack: NSStackView
        if let key = editing {
            stack = buildEditLayout(for: key)
        } else {
            stack = buildCreateLayout()
        }

        let top = NSStackView(views: [title, labelField])
        top.orientation = .vertical
        top.alignment = .leading
        top.spacing = 12
        top.translatesAutoresizingMaskIntoConstraints = false

        let full = NSStackView(views: [top, stack])
        full.orientation = .vertical
        full.alignment = .leading
        full.spacing = 16
        full.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(full)

        NSLayoutConstraint.activate([
            full.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            full.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),
            full.topAnchor.constraint(equalTo: root.topAnchor, constant: 20),
            full.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -20),
            labelField.widthAnchor.constraint(equalTo: full.widthAnchor),
            stack.widthAnchor.constraint(equalTo: full.widthAnchor),
        ])
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(labelField)
    }

    // MARK: Create layout (Generate / Import)

    private func buildCreateLayout() -> NSStackView {
        modeSwitch.segmentCount = 2
        modeSwitch.setLabel("Generate", forSegment: 0)
        modeSwitch.setLabel("Import", forSegment: 1)
        modeSwitch.selectedSegment = 0
        modeSwitch.target = self
        modeSwitch.action = #selector(modeChanged)
        modeSwitch.translatesAutoresizingMaskIntoConstraints = false

        buildGeneratePanel()
        buildImportPanel()
        importPanel.isHidden = true

        let certBox = labeledBox("Certificate (optional)", view: scrollable(certificateView, height: 60))
        certificateView.string = ""
        certificateView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        certificateView.isEditable = true

        let publicKeyBox = buildPublicKeyPreview()

        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .systemRed
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        let bottom = buildBottomBar(showDelete: false)

        let stack = NSStackView(views: [
            modeSwitch, generatePanel, importPanel, certBox, publicKeyBox, statusLabel, bottom,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            generatePanel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            importPanel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            certBox.widthAnchor.constraint(equalTo: stack.widthAnchor),
            publicKeyBox.widthAnchor.constraint(equalTo: stack.widthAnchor),
            statusLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            bottom.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        updateSaveEnabled()
        return stack
    }

    private func buildGeneratePanel() {
        typeSwitch.segmentCount = 2
        typeSwitch.setLabel("Ed25519", forSegment: 0)
        typeSwitch.setLabel("RSA", forSegment: 1)
        typeSwitch.selectedSegment = 0
        typeSwitch.translatesAutoresizingMaskIntoConstraints = false

        configure(generatePassphraseField, placeholder: "Passphrase (optional)", value: nil)
        let generate = NSButton(title: "Generate", target: self, action: #selector(generateKey))
        generate.bezelStyle = .rounded

        let grid = NSGridView(views: [
            [rowLabel("Type"), typeSwitch],
            [rowLabel("Passphrase"), generatePassphraseField],
            [NSView(), generate],
        ])
        grid.rowSpacing = 10
        grid.columnSpacing = 12
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).xPlacement = .fill
        grid.translatesAutoresizingMaskIntoConstraints = false

        generatePanel.translatesAutoresizingMaskIntoConstraints = false
        generatePanel.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.leadingAnchor.constraint(equalTo: generatePanel.leadingAnchor),
            grid.trailingAnchor.constraint(equalTo: generatePanel.trailingAnchor),
            grid.topAnchor.constraint(equalTo: generatePanel.topAnchor),
            grid.bottomAnchor.constraint(equalTo: generatePanel.bottomAnchor),
        ])
    }

    private func buildImportPanel() {
        importDropZone.onDropFile = { [weak self] url in self?.loadImportFile(url) }
        importDropZone.translatesAutoresizingMaskIntoConstraints = false

        let hint = NSTextField(labelWithString: "Drop a private key file here")
        hint.font = .systemFont(ofSize: 12)
        hint.textColor = .tertiaryLabelColor
        hint.translatesAutoresizingMaskIntoConstraints = false
        importDropZone.addSubview(hint)
        NSLayoutConstraint.activate([
            hint.centerXAnchor.constraint(equalTo: importDropZone.centerXAnchor),
            hint.centerYAnchor.constraint(equalTo: importDropZone.centerYAnchor),
            importDropZone.heightAnchor.constraint(equalToConstant: 44),
        ])

        let chooseFile = NSButton(title: "Import from Key File…", target: self, action: #selector(chooseImportFile))
        chooseFile.bezelStyle = .rounded

        importTextView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        importTextView.isEditable = true
        let pasteBox = labeledBox("Or paste the private key", view: scrollable(importTextView, height: 70))

        configure(importPassphraseField, placeholder: "Passphrase (if the key needs one)", value: nil)
        let verify = NSButton(title: "Verify", target: self, action: #selector(verifyImport))
        verify.bezelStyle = .rounded
        let verifyRow = NSStackView(views: [rowLabel("Passphrase"), importPassphraseField, verify])
        verifyRow.orientation = .horizontal
        verifyRow.spacing = 10

        let stack = NSStackView(views: [importDropZone, chooseFile, pasteBox, verifyRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false

        importPanel.translatesAutoresizingMaskIntoConstraints = false
        importPanel.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: importPanel.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: importPanel.trailingAnchor),
            stack.topAnchor.constraint(equalTo: importPanel.topAnchor),
            stack.bottomAnchor.constraint(equalTo: importPanel.bottomAnchor),
            importDropZone.widthAnchor.constraint(equalTo: stack.widthAnchor),
            pasteBox.widthAnchor.constraint(equalTo: stack.widthAnchor),
            verifyRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
    }

    // MARK: Edit layout

    private func buildEditLayout(for key: SSHKey) -> NSStackView {
        let typeLabel = NSTextField(labelWithString: key.type.displayName)
        typeLabel.textColor = .secondaryLabelColor

        publicKeyView.string = key.publicKey
        let publicKeyBox = buildPublicKeyPreview()
        fingerprintLabel.stringValue = key.fingerprint
        pendingPublicKeyLine = key.publicKey
        pendingFingerprint = key.fingerprint
        pendingType = key.type

        certificateView.string = key.certificate ?? ""
        certificateView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        certificateView.isEditable = true
        let certBox = labeledBox("Certificate (optional)", view: scrollable(certificateView, height: 60))

        configure(passphraseField, placeholder: key.hasPassphrase ? "Leave blank to keep current passphrase" : "Passphrase (optional)", value: nil)

        let grid = NSGridView(views: [
            [rowLabel("Type"), typeLabel],
            [rowLabel("Passphrase"), passphraseField],
        ])
        grid.rowSpacing = 10
        grid.columnSpacing = 12
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).xPlacement = .fill
        grid.translatesAutoresizingMaskIntoConstraints = false

        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .systemRed
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        let bottom = buildBottomBar(showDelete: true)

        let stack = NSStackView(views: [grid, certBox, publicKeyBox, statusLabel, bottom])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            grid.widthAnchor.constraint(equalTo: stack.widthAnchor),
            certBox.widthAnchor.constraint(equalTo: stack.widthAnchor),
            publicKeyBox.widthAnchor.constraint(equalTo: stack.widthAnchor),
            statusLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            bottom.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        saveButton.isEnabled = true
        return stack
    }

    // MARK: Public key preview

    private func buildPublicKeyPreview() -> NSView {
        publicKeyView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        publicKeyView.isEditable = false
        publicKeyView.textColor = .secondaryLabelColor
        let box = scrollable(publicKeyView, height: 50)

        let copy = NSButton(title: "Copy", target: self, action: #selector(copyPublicKey))
        copy.bezelStyle = .rounded
        fingerprintLabel.font = .systemFont(ofSize: 11)
        fingerprintLabel.textColor = .tertiaryLabelColor

        let footer = NSStackView(views: [fingerprintLabel, NSView(), copy])
        footer.orientation = .horizontal
        footer.translatesAutoresizingMaskIntoConstraints = false
        fingerprintLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

        return labeledBox("Public key (derived, read-only)", view: box, footer: footer)
    }

    // MARK: Actions - Generate

    @objc private func modeChanged() {
        let importing = modeSwitch.selectedSegment == 1
        generatePanel.isHidden = importing
        importPanel.isHidden = !importing
        statusLabel.stringValue = ""
    }

    @objc private func generateKey() {
        let label = labelField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty else { flag(labelField); return }
        let type: SSHKeyType = typeSwitch.selectedSegment == 0 ? .ed25519 : .rsa
        let passphrase = generatePassphraseField.stringValue
        do {
            let generated = try SSHKeyGenerator.generate(type: type, label: label, passphrase: passphrase)
            pendingPrivateKey = generated.privateKey
            pendingPublicKeyLine = generated.publicKeyLine
            pendingFingerprint = generated.fingerprint
            pendingType = type
            pendingPassphrase = passphrase.isEmpty ? nil : passphrase
            publicKeyView.string = generated.publicKeyLine
            fingerprintLabel.stringValue = generated.fingerprint
            statusLabel.stringValue = ""
        } catch {
            statusLabel.stringValue = error.localizedDescription
        }
        updateSaveEnabled()
    }

    // MARK: Actions - Import

    @objc private func chooseImportFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose a private key file (PEM or OpenSSH)."
        panel.showsHiddenFiles = true
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh")
        if panel.runModal() == .OK, let url = panel.url {
            loadImportFile(url)
        }
    }

    private func loadImportFile(_ url: URL) {
        guard let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8) else {
            statusLabel.stringValue = "Couldn't read that file as text."
            return
        }
        importTextView.string = text
        verifyImport()
    }

    @objc private func verifyImport() {
        let text = importTextView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let data = text.data(using: .utf8) else {
            statusLabel.stringValue = "Paste a private key, or drop/import a key file."
            return
        }
        let passphrase = importPassphraseField.stringValue
        do {
            let imported = try SSHKeyGenerator.inspect(privateKey: data, passphrase: passphrase)
            pendingPrivateKey = data
            pendingPublicKeyLine = imported.publicKeyLine
            pendingFingerprint = imported.fingerprint
            pendingType = imported.type
            pendingPassphrase = passphrase.isEmpty ? nil : passphrase
            publicKeyView.string = imported.publicKeyLine
            fingerprintLabel.stringValue = imported.fingerprint
            statusLabel.stringValue = "Verified \(imported.type.displayName) key."
            statusLabel.textColor = .systemGreen
        } catch {
            pendingPrivateKey = nil
            statusLabel.textColor = .systemRed
            statusLabel.stringValue = error.localizedDescription
        }
        updateSaveEnabled()
    }

    @objc private func copyPublicKey() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(publicKeyView.string, forType: .string)
    }

    // MARK: Save / Delete / Cancel

    private func buildBottomBar(showDelete: Bool) -> NSView {
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancel.bezelStyle = .rounded
        cancel.keyEquivalent = "\u{1b}"
        saveButton.title = "Save"
        saveButton.bezelStyle = .rounded
        saveButton.keyEquivalent = "\r"
        saveButton.target = self
        saveButton.action = #selector(save)

        var views: [NSView] = []
        if showDelete {
            let del = NSButton(title: "Delete", target: self, action: #selector(deleteKey))
            del.bezelStyle = .rounded
            del.contentTintColor = .systemRed
            views.append(del)
        }
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        views += [spacer, cancel, saveButton]
        let bar = NSStackView(views: views)
        bar.orientation = .horizontal
        bar.spacing = 10
        bar.translatesAutoresizingMaskIntoConstraints = false
        return bar
    }

    private func updateSaveEnabled() {
        saveButton.isEnabled = editing != nil || pendingPrivateKey != nil
    }

    @objc private func save() {
        let label = labelField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty else { flag(labelField); return }

        if let editing {
            var key = editing
            key.label = label
            let cert = certificateView.string.trimmingCharacters(in: .whitespacesAndNewlines)
            key.certificate = cert.isEmpty ? nil : cert
            let newPassphrase = passphraseField.stringValue.isEmpty ? nil : passphraseField.stringValue
            if newPassphrase != nil { key.hasPassphrase = true }
            onUpdate?(key, newPassphrase)
        } else {
            guard let privateKey = pendingPrivateKey, let publicKey = pendingPublicKeyLine, let fingerprint = pendingFingerprint else {
                return
            }
            let cert = certificateView.string.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = SSHKey(
                label: label,
                type: pendingType,
                publicKey: publicKey,
                fingerprint: fingerprint,
                certificate: cert.isEmpty ? nil : cert,
                hasPassphrase: pendingPassphrase != nil
            )
            onSave?(key, privateKey, pendingPassphrase)
        }
        dismiss(self)
    }

    @objc private func deleteKey() {
        guard let id = editing?.id else { return }
        onDelete?(id)
        dismiss(self)
    }

    @objc private func cancel() {
        onCancel?()
        dismiss(self)
    }

    // MARK: Small view helpers

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

    /// A plain programmatic `NSTextView` needs this setup to actually wrap and
    /// track its scroll view's width instead of keeping its zero-size initial
    /// frame - AppKit does not default it for you outside Interface Builder.
    private func scrollable(_ textView: NSTextView, height: CGFloat) -> NSView {
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainerInset = NSSize(width: 4, height: 4)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)

        let scroll = NSScrollView()
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.borderType = .lineBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.heightAnchor.constraint(equalToConstant: height).isActive = true
        return scroll
    }

    private func labeledBox(_ caption: String, view boxed: NSView, footer: NSView? = nil) -> NSView {
        let label = NSTextField(labelWithString: caption)
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        var views: [NSView] = [label, boxed]
        if let footer { views.append(footer) }
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        boxed.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        footer?.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        return stack
    }

    private func flag(_ field: NSTextField) {
        view.window?.makeFirstResponder(field)
        NSSound.beep()
    }
}

// MARK: - Drag-and-drop import zone

/// A dashed drop target that hands the caller a dropped file's URL. Used by
/// the Import panel above; the captain's explicit ask was drag-and-drop *or*
/// file-picker import, so this class only handles the drop half - the picker
/// half is a plain `NSOpenPanel` call alongside it.
final class KeyDropZone: NSView {
    var onDropFile: ((URL) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
        wantsLayer = true
        layer?.borderWidth = 1.5
        layer?.borderColor = NSColor.tertiaryLabelColor.cgColor
        layer?.cornerRadius = 8
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        sender.draggingPasteboard.canReadObject(forClasses: [NSURL.self], options: nil) ? .copy : []
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL],
              let url = urls.first else { return false }
        onDropFile?(url)
        return true
    }
}
