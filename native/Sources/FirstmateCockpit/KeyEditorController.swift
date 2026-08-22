// Manjesh Grand Line - native macOS app.
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
// hands the caller (`HostsController`'s Keys tab) either a freshly generated/
// imported `SSHKey` + raw private-key bytes + passphrase (create mode), or an
// updated `SSHKey` + an optional new passphrase (edit mode) - the same
// "editor computes, caller persists" split `HostEditorController` already uses.
//
// `fm/grandline-hosts-keys-form-redesign` moved this sheet onto the shared
// `HelmFormSheet` scaffold (`HelmForm.swift`) - unlike the other five editors,
// this one had never been migrated by the Phase 6 audit, and still carried an
// `NSGridView`, plain bezeled `NSTextField`/`NSTextView`s, and its own
// `ThemeManager` observer. Built against a captain-approved mockup
// (`data/grandline-hosts-keys-mockup/mockup.html`): a hero header (an
// accent-tinted icon tile beside the editable label, plus a real "Used by N
// hosts" subtitle in edit mode - computed from the real host list, never
// fabricated; there is no "Added today" because `SSHKey` has no creation
// timestamp, so that half of the mockup's subtitle was left out rather than
// invented), the Generate/Import segmented pair and the key-type pill
// (already `HelmSegmentedTabs`, unchanged), a monospace public-key preview, an
// accent-tinted Keychain-security note, and a read-only fingerprint field with
// a copy button. This is presentation only: `generateKey`/`verifyImport`/
// `loadImportFile`/`chooseImportFile`/`copyPublicKey`/`save`/`deleteKey`/
// `cancel` are byte-for-byte the same logic as before.

import AppKit

final class KeyEditorController: NSViewController, NSTextFieldDelegate {

    /// `nil` for a brand-new key; set for editing an existing one's label,
    /// certificate, and (optionally) passphrase. Edit mode never re-derives or
    /// re-stores the private key itself.
    private let editing: SSHKey?

    /// How many saved hosts currently reference this key (`Host.keyID`) - real,
    /// caller-computed data for the edit-mode hero subtitle. Always `0` for a
    /// brand-new key (nothing can reference it yet).
    private let usedByHostCount: Int

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

    private let labelField = HelmTextField(placeholder: "Label (e.g. Prod bastion key)", style: .lead)
    private let heroIconTile = IconTileView(size: 46, cornerRadius: HelmMetrics.rPanel - 1)
    private let certificateView = HelmTextView(height: 60, monospaced: true)
    private let publicKeyView = HelmTextView(height: 56, monospaced: true)
    private let fingerprintField = HelmTextField(placeholder: "")
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private var form: HelmFormSheet!
    private var saveButton: HelmButton!
    /// The edit-mode "Used by N hosts" line under the hero - `addLeadHint`
    /// doesn't colour its own text (a caller-supplied attributed string can
    /// set anything), so this needs its own re-tint on every theme change,
    /// same as `ShiftTaskEditorController`'s own lead hint.
    private var usedByHostsHintLabel: NSTextField?

    // MARK: Create-mode fields

    /// Generate-vs-Import and Ed25519-vs-RSA are both "pick one of two", and
    /// as stock `NSSegmentedControl`s they were the last two system-chrome
    /// controls on this sheet - the audit called this file "the single most
    /// system-chrome-dependent file in the app" (§4.5). They are the app's own
    /// `HelmSegmentedTabs` now (Phase 4's component), which is the same
    /// affordance in the theme's own colours. `.compact` for the type picker,
    /// which sits in a form grid row rather than above a panel.
    private let modeSwitch = HelmSegmentedTabs(
        items: [.init(id: "generate", title: "Generate"), .init(id: "import", title: "Import")],
        selected: "generate")
    private let typeSwitch = HelmSegmentedTabs(
        items: [.init(id: SSHKeyType.ed25519.rawValue, title: SSHKeyType.ed25519.displayName),
                .init(id: SSHKeyType.rsa.rawValue, title: SSHKeyType.rsa.displayName)],
        selected: SSHKeyType.ed25519.rawValue,
        size: .compact)
    /// Edit mode's single passphrase field ("leave blank to keep current").
    /// `lazy` so its placeholder can read `editing` (set earlier in `init`).
    private lazy var passphraseField = HelmSecureTextField(
        placeholder: (editing?.hasPassphrase ?? false) ? "Leave blank to keep current passphrase" : "Passphrase (optional)")
    /// Generate and Import each need their own passphrase control - one sets
    /// a passphrase on a brand-new key, the other supplies the existing one
    /// to decrypt - so, unlike every other create-mode field, this can't be a
    /// single shared `NSTextField` instance (a view can only live in one
    /// parent at a time; sharing one here silently detaches it from whichever
    /// panel built it first).
    private let generatePassphraseField = HelmSecureTextField(placeholder: "Optional")
    private let importPassphraseField = HelmSecureTextField(placeholder: "Only if the key is encrypted")
    private let importDropZone = KeyDropZone()
    private let importTextView = HelmTextView(height: 70, monospaced: true)
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

    init(key: SSHKey?, usedByHostCount: Int = 0) {
        self.editing = key
        self.usedByHostCount = usedByHostCount
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: Layout

    /// Labels carrying `HelmTheme.mutedInk` instead of a fixed system grey -
    /// see `MutedInkLabels` for why a system grey is wrong here (audit §5.3).
    /// Only the drop-zone hint and the edit-mode read-only type label live
    /// outside the `HelmFormSheet` API (which re-tints its own labels), so
    /// this registry only ever has those two in it.
    private let mutedLabels = MutedInkLabels()
    /// Which hue `statusLabel` is currently showing, so a theme change can
    /// re-derive its colour rather than leaving the previous theme's.
    private var statusTone: HelmTint = .critical

    override func loadView() {
        let form = HelmFormSheet(title: editing == nil ? "New Key" : "Edit Key")
        self.form = form
        view = form
        form.onApplyTheme = { [weak self] theme in
            guard let self else { return }
            self.mutedLabels.apply(theme)
            self.importDropZone.applyTheme(theme)
            self.modeSwitch.applyTheme(theme)
            self.typeSwitch.applyTheme(theme)
            self.heroIconTile.applyTheme(theme)
            self.applyStatusTone(theme)
            if let hint = self.usedByHostsHintLabel {
                hint.attributedStringValue = self.usedByHostsHint(color: HelmTheme.mutedInk(theme))
            }
        }

        // MARK: Hero - icon tile + editable label (+ a real "Used by N hosts"
        // subtitle in edit mode; no "Added today", `SSHKey` has no timestamp)

        heroIconTile.configure(symbol: "key.fill", tint: .warn, pointSize: 18)
        labelField.stringValue = editing?.label ?? ""
        let heroRow = NSStackView(views: [heroIconTile, labelField])
        heroRow.orientation = .horizontal
        heroRow.alignment = .centerY
        heroRow.spacing = HelmMetrics.s3
        heroRow.translatesAutoresizingMaskIntoConstraints = false
        form.addLead(heroRow)
        if editing != nil {
            let label = form.addLeadHint(usedByHostsHint(color: HelmTheme.mutedInk(ThemeManager.shared.theme)))
            usedByHostsHintLabel = label
        }

        let stack: NSStackView
        if let key = editing {
            stack = buildEditLayout(for: key)
        } else {
            stack = buildCreateLayout()
        }
        form.addRow(stack)

        let footer = form.setFooter(target: self,
                                    confirmTitle: "Save Key",
                                    confirm: #selector(save),
                                    cancel: #selector(cancel),
                                    delete: editing == nil ? nil : (title: "Delete", action: #selector(deleteKey)),
                                    hint: "Stored securely in macOS Keychain")
        saveButton = footer.confirm
        updateSaveEnabled()

        form.refreshTheme()
        form.sizeToFitContent()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(labelField)
    }

    /// "Used by N hosts" - real data, computed by the caller (`usedByHostCount`,
    /// from `Host.keyID`), never fabricated. There is no "Added today" half
    /// (the mockup's own subtitle) because `SSHKey` carries no creation
    /// timestamp.
    private func usedByHostsHint(color: NSColor) -> NSAttributedString {
        let hostWord = usedByHostCount == 1 ? "host" : "hosts"
        return NSAttributedString(string: "Used by \(usedByHostCount) \(hostWord)",
                                  attributes: [.font: HelmType.caption(), .foregroundColor: color])
    }

    // MARK: Create layout (Generate / Import)

    private func buildCreateLayout() -> NSStackView {
        modeSwitch.onSelect = { [weak self] _ in self?.modeChanged() }

        buildGeneratePanel()
        buildImportPanel()
        importPanel.isHidden = true

        certificateView.string = ""

        let publicKeyBox = buildPublicKeyPreview()

        statusLabel.font = HelmType.caption()
        setStatusTone(.critical)
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [
            modeSwitch, generatePanel, importPanel, statusLabel,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = HelmMetrics.s4
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            generatePanel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            importPanel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            statusLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        stack.setCustomSpacing(HelmMetrics.s2, after: modeSwitch)

        form.addSection("Public Key", number: "01")
        form.addRow(publicKeyBox)
        form.addSection("Security", number: "02")
        form.addInfoCard(text: "Private keys are stored only in the macOS Keychain. "
            + "The host configuration references this key by id and never contains the private key material.")
        form.addField("Fingerprint", buildFingerprintRow())
        form.addSection("Certificate (optional)", number: "03")
        form.addRow(certificateView)

        updateSaveEnabled()
        return stack
    }

    private func buildGeneratePanel() {
        let generate = HelmButton(title: "Generate", variant: .primary, target: self, action: #selector(generateKey))

        let fieldsRow = NSStackView(views: [
            form.labelledField("Key type", typeSwitch),
            form.labelledField("Passphrase", generatePassphraseField),
        ])
        fieldsRow.orientation = .horizontal
        fieldsRow.distribution = .fillEqually
        fieldsRow.alignment = .top
        fieldsRow.spacing = HelmMetrics.s3 - 2
        fieldsRow.translatesAutoresizingMaskIntoConstraints = false

        let generateRow = NSStackView(views: [NSView(), generate])
        generateRow.orientation = .horizontal
        generateRow.distribution = .fill
        generateRow.translatesAutoresizingMaskIntoConstraints = false
        generateRow.arrangedSubviews[0].setContentHuggingPriority(.defaultLow, for: .horizontal)

        let stack = NSStackView(views: [fieldsRow, generateRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = HelmMetrics.s3
        stack.translatesAutoresizingMaskIntoConstraints = false

        generatePanel.translatesAutoresizingMaskIntoConstraints = false
        generatePanel.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: generatePanel.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: generatePanel.trailingAnchor),
            stack.topAnchor.constraint(equalTo: generatePanel.topAnchor),
            stack.bottomAnchor.constraint(equalTo: generatePanel.bottomAnchor),
            fieldsRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            generateRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
    }

    private func buildImportPanel() {
        importDropZone.onDropFile = { [weak self] url in self?.loadImportFile(url) }
        importDropZone.translatesAutoresizingMaskIntoConstraints = false

        let hint = NSTextField(labelWithString: "Drop a private key file here")
        hint.font = .systemFont(ofSize: 12)
        mutedLabels.add(hint)
        hint.translatesAutoresizingMaskIntoConstraints = false
        importDropZone.addSubview(hint)
        NSLayoutConstraint.activate([
            hint.centerXAnchor.constraint(equalTo: importDropZone.centerXAnchor),
            hint.centerYAnchor.constraint(equalTo: importDropZone.centerYAnchor),
            importDropZone.heightAnchor.constraint(equalToConstant: 44),
        ])

        let chooseFile = HelmButton(title: "Import from Key File…", variant: .secondary, target: self, action: #selector(chooseImportFile))

        let pasteField = form.labelledField("Private key", importTextView)

        let verify = HelmButton(title: "Verify", variant: .secondary, target: self, action: #selector(verifyImport))
        let verifyRow = NSStackView(views: [form.labelledField("Passphrase", importPassphraseField), verify])
        verifyRow.orientation = .horizontal
        verifyRow.alignment = .bottom
        verifyRow.spacing = HelmMetrics.s3 - 2
        verifyRow.translatesAutoresizingMaskIntoConstraints = false
        verify.setContentHuggingPriority(.required, for: .horizontal)

        let stack = NSStackView(views: [importDropZone, chooseFile, pasteField, verifyRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = HelmMetrics.s3
        stack.translatesAutoresizingMaskIntoConstraints = false

        importPanel.translatesAutoresizingMaskIntoConstraints = false
        importPanel.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: importPanel.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: importPanel.trailingAnchor),
            stack.topAnchor.constraint(equalTo: importPanel.topAnchor),
            stack.bottomAnchor.constraint(equalTo: importPanel.bottomAnchor),
            importDropZone.widthAnchor.constraint(equalTo: stack.widthAnchor),
            pasteField.widthAnchor.constraint(equalTo: stack.widthAnchor),
            verifyRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
    }

    // MARK: Edit layout

    private func buildEditLayout(for key: SSHKey) -> NSStackView {
        let typeLabel = NSTextField(labelWithString: key.type.displayName)
        typeLabel.translatesAutoresizingMaskIntoConstraints = false
        mutedLabels.add(typeLabel)

        publicKeyView.string = key.publicKey
        let publicKeyBox = buildPublicKeyPreview()
        fingerprintField.stringValue = key.fingerprint
        pendingPublicKeyLine = key.publicKey
        pendingFingerprint = key.fingerprint
        pendingType = key.type

        certificateView.string = key.certificate ?? ""

        let fieldsRow = NSStackView(views: [
            form.labelledField("Type", typeLabel),
            form.labelledField("Passphrase", passphraseField),
        ])
        fieldsRow.orientation = .horizontal
        fieldsRow.distribution = .fillEqually
        fieldsRow.alignment = .top
        fieldsRow.spacing = HelmMetrics.s3 - 2
        fieldsRow.translatesAutoresizingMaskIntoConstraints = false

        statusLabel.font = HelmType.caption()
        setStatusTone(.critical)
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [fieldsRow, statusLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = HelmMetrics.s3
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            fieldsRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            statusLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])

        form.addSection("Public Key", number: "01")
        form.addRow(publicKeyBox)
        form.addSection("Security", number: "02")
        form.addInfoCard(text: "Private keys are stored only in the macOS Keychain. "
            + "The host configuration references this key by id and never contains the private key material.")
        form.addField("Fingerprint", buildFingerprintRow())
        form.addSection("Certificate (optional)", number: "03")
        form.addRow(certificateView)

        return stack
    }

    // MARK: Public key preview + fingerprint

    private func buildPublicKeyPreview() -> NSView {
        publicKeyView.textView.isEditable = false
        let copy = HelmButton(title: "Copy", variant: .secondary, size: .small,
                              target: self, action: #selector(copyPublicKey))
        let footer = NSStackView(views: [NSView(), copy])
        footer.orientation = .horizontal
        footer.distribution = .fill
        footer.translatesAutoresizingMaskIntoConstraints = false
        footer.arrangedSubviews[0].setContentHuggingPriority(.defaultLow, for: .horizontal)
        copy.setContentHuggingPriority(.required, for: .horizontal)

        let stack = NSStackView(views: [publicKeyView, footer])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = HelmMetrics.s1
        stack.translatesAutoresizingMaskIntoConstraints = false
        footer.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        return stack
    }

    /// A read-only, monospaced fingerprint field with a trailing copy icon
    /// button - the mockup's `.fp-copy` row. Separate from the public key
    /// box's own "Copy" button above (unchanged, pre-existing behaviour) -
    /// this one copies the fingerprint specifically, the mockup's own ask.
    private func buildFingerprintRow() -> NSView {
        fingerprintField.isEditable = false
        fingerprintField.font = HelmType.code()
        let copy = HelmButton(symbol: "doc.on.doc", variant: .secondary, size: .small,
                              target: self, action: #selector(copyFingerprint))
        copy.toolTip = "Copy fingerprint"
        let row = NSStackView(views: [fingerprintField, copy])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.distribution = .fill
        row.spacing = HelmMetrics.s2
        row.translatesAutoresizingMaskIntoConstraints = false
        copy.setContentHuggingPriority(.required, for: .horizontal)
        copy.setContentCompressionResistancePriority(.required, for: .horizontal)
        return row
    }

    // MARK: Actions - Generate

    private func modeChanged() {
        let importing = modeSwitch.selected == "import"
        generatePanel.isHidden = importing
        importPanel.isHidden = !importing
        statusLabel.stringValue = ""
        form.sizeToFitContent()
    }

    @objc private func generateKey() {
        let label = labelField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty else { flag(labelField); return }
        let type = SSHKeyType(rawValue: typeSwitch.selected) ?? .ed25519
        let passphrase = generatePassphraseField.stringValue
        do {
            let generated = try SSHKeyGenerator.generate(type: type, label: label, passphrase: passphrase)
            pendingPrivateKey = generated.privateKey
            pendingPublicKeyLine = generated.publicKeyLine
            pendingFingerprint = generated.fingerprint
            pendingType = type
            pendingPassphrase = passphrase.isEmpty ? nil : passphrase
            publicKeyView.string = generated.publicKeyLine
            fingerprintField.stringValue = generated.fingerprint
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
            fingerprintField.stringValue = imported.fingerprint
            statusLabel.stringValue = "Verified \(imported.type.displayName) key."
            setStatusTone(.good)
        } catch {
            pendingPrivateKey = nil
            setStatusTone(.critical)
            statusLabel.stringValue = error.localizedDescription
        }
        updateSaveEnabled()
    }

    @objc private func copyPublicKey() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(publicKeyView.string, forType: .string)
    }

    @objc private func copyFingerprint() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(fingerprintField.stringValue, forType: .string)
    }

    // MARK: Save / Delete / Cancel

    private func updateSaveEnabled() {
        saveButton?.isEnabled = editing != nil || pendingPrivateKey != nil
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

    /// The status line's hue, re-derived from the *active* theme rather than
    /// pinned to `.systemRed`/`.systemGreen`. Routed through `HelmContrast`
    /// because a `HelmTint` hue is safe as a fill and is not automatically
    /// safe as text (Phase 0's rule, audit §5.7) - the sheet's own background
    /// is what it has to clear here.
    private func setStatusTone(_ tint: HelmTint) {
        statusTone = tint
        applyStatusTone(ThemeManager.shared.theme)
    }

    private func applyStatusTone(_ theme: HelmTheme) {
        statusLabel.textColor = HelmContrast.legibleTintedText(tintHex: statusTone.hex(in: theme),
                                                               over: HelmTheme.nsColor(theme.backgroundHex),
                                                               theme: theme)
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
        layer?.cornerRadius = 8
        applyTheme(ThemeManager.shared.theme)
    }

    /// The drop zone's dashed-looking border used to be
    /// `NSColor.tertiaryLabelColor`, a fixed system grey that knows nothing
    /// about the active palette (audit §5.3). `chromeLineHex` is this app's
    /// own hairline/border token.
    func applyTheme(_ theme: HelmTheme) {
        layer?.borderColor = HelmTheme.nsColor(theme.chromeLineHex).cgColor
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
