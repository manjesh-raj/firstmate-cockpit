// Manjesh Grand Line - native macOS app.
//
// The host-details editor (design report A2/A3, Section D Phase 1). The
// Termius "New Host" fields - Label, Address, Port, Username, a credentials
// section, and the A3 icon/colour pickers. Add, edit, and delete all route
// back to the caller via closures; this view knows nothing about the host
// store. Presented as its own top-level window (`AppDelegate.presentHostEditor`)
// with the same visual weight as Settings, not a sheet on the Hosts panel.
//
// Phase 2 replaces the raw "key file path" field with a "Choose a key" popup
// sourced from the saved-keys Keychain (`SSHKeyStore`) - the host now carries
// a `keyID` reference, never a path, per design report Section A2/C3.
//
// Phase 3 (Section B1/B2/B4, Section D Phase 3) adds: Group + Tags (B4);
// Agent Forwarding and Jump Via (B1); a "Port Forwarding\u{2026}" button that
// opens `PortForwardingController` as a nested sheet (B1); and a Startup
// Snippet popup sourced from `SnippetStore` (B2/B5).
//
// Fix 5 adds a "+ New Key…" entry at the bottom of the key chooser, so a key
// can be created without leaving this form: it opens the Phase-2
// `KeyEditorController` sheet, persists through `SSHKeyStore.addNew` on
// save, and rebuilds the chooser selecting the new key. This is why it holds a
// live `SSHKeyStore` rather than a one-time snapshot of `keys` - unlike the
// icon/colour catalogues, it has to reflect a key created while this very sheet
// is still open.
//
// Phase 6 of the full-app UI audit moved the form onto the shared scaffold
// (`HelmForm.swift`, the scrolling variant). This was the biggest of the six
// migrations: a flat 15-row `NSGridView` with a 130pt label column, 7 stock
// bezeled fields, 2 stock popups and 2 unlabelled checkboxes sitting in empty
// grid cells became four kickered sections of the same field language the task
// editor uses. **The window presentation is unchanged** - it is still a
// top-level window, `closeEditor()` still closes it directly (`dismiss(self)`
// is a documented no-op here, see that method), and the capped/centred column
// is still built from inequalities rather than a required `==` width tie
// (AGENTS.md's host-editor gotcha (3)), now inside `HelmFormSheet.cappedColumn`.
// Every field, every validation rule and the inline "+ New Key…" flow behave
// exactly as before.

import AppKit

final class HostEditorController: NSViewController {

    /// The form's content column never grows past this, regardless of window
    /// width - a typical macOS dialog reading width, centred in whatever space
    /// the window actually has.
    private static let maxContentWidth: CGFloat = 520

    /// The host being edited; `nil` for a brand-new host.
    private let editing: Host?

    /// The saved-keys Keychain (Phase 2) - read to populate the key chooser,
    /// and written to by the inline "+ New Key…" flow (Fix 5).
    private let keyStore: SSHKeyStore

    /// Saved snippets to offer in the startup-snippet chooser - a snapshot
    /// taken when the sheet opens (matches how the icon/colour catalogues
    /// are snapshotted too; a snippet added while this sheet is open won't
    /// appear until reopened - unlike `keyStore`, nothing in this sheet can
    /// create a new snippet).
    private let snippets: [Snippet]

    /// Every other saved host's label (never including `editing`'s own, and
    /// never the pinned "Firstmate" entry's fixed display name - see
    /// `save()`), used only to warn on a duplicate label at Save time
    /// (Finding 5, cockpit-audit-core) - quick-connect resolves an ambiguous
    /// exact-label match with a plain `first(where:)`, so two hosts sharing a
    /// label can silently connect to the wrong one.
    private let existingLabels: Set<String>

    /// Called with the assembled host on Save. The caller persists it.
    var onSave: ((Host) -> Void)?
    /// Called with the host id on Delete (only offered when editing).
    var onDelete: ((UUID) -> Void)?

    // MARK: Fields

    private let labelField = HelmTextField(placeholder: "Name this host", style: .lead)
    private let addressField = HelmTextField(placeholder: "hostname or IP")
    private let portField = HelmTextField(placeholder: "22")
    private let usernameField = HelmTextField(placeholder: "Username")
    private let passwordField = HelmSecureTextField(placeholder: "Session only")
    private let keyCard = HelmFieldCard(label: "Key")
    private let groupField = HelmTextField(placeholder: "e.g. Production")
    private let tagsField = HelmTextField(placeholder: "e.g. prod, us-east")
    private lazy var agentForwardRow = HelmToggleRow(
        title: "Forward SSH agent",
        subtitle: "Passes -A to ssh, so the remote host can use this machine's agent."
    )
    /// Block view Stage 0 opt-in (`fm/cockpit-block-view-stage0`) - see
    /// `Host.blockViewOptIn`'s doc comment. Only meaningful when
    /// `FM_BLOCK_VIEW_ENABLED` is also set, which the subtitle says.
    private lazy var blockViewRow = HelmToggleRow(
        title: "Render command blocks",
        subtitle: "Stage 0 - also needs FM_BLOCK_VIEW_ENABLED in the environment."
    )
    private let jumpViaField = HelmTextField(placeholder: "Host label or user@bastion")
    private let portForwardingButton = HelmButton(title: "", variant: .secondary)
    private let snippetCard = HelmFieldCard(label: "Startup snippet")

    /// The key chooser's current selection: `nil` is "None (use system ssh
    /// agent)", the same meaning index 0 carried when this was a popup.
    private var selectedKeyID: UUID?
    private var selectedSnippetID: UUID?

    /// Edited in the nested `PortForwardingController` sheet, carried here
    /// until Save.
    private var portForwards: [PortForwardRule]

    /// Current icon/colour selection, seeded from the host (or the defaults).
    private var selectedIcon: String
    private var selectedAccent: String
    private var iconButtons: [NSButton] = []
    private var colorButtons: [NSButton] = []

    // MARK: Init

    init(host: Host?, keyStore: SSHKeyStore, snippets: [Snippet], existingLabels: Set<String> = []) {
        self.editing = host
        self.keyStore = keyStore
        self.snippets = snippets
        self.existingLabels = existingLabels
        self.portForwards = host?.portForwards ?? []
        self.selectedIcon = host?.iconSymbol ?? HostCatalog.defaultIcon
        self.selectedAccent = host?.accentHex ?? HostCatalog.defaultAccent
        self.selectedKeyID = host?.keyID
        self.selectedSnippetID = host?.startupSnippetID
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: Layout

    override func loadView() {
        let form = HelmFormSheet(title: editing == nil ? "New Host" : "Edit Host",
                                 scrolls: true,
                                 maxContentWidth: Self.maxContentWidth)
        form.autoresizingMask = [.width, .height]
        form.setFrameSize(NSSize(width: 640, height: 780))
        view = form
        form.onApplyTheme = { [weak self] _ in
            // The icon/colour swatches carry the host's own chosen accent, not
            // a theme token, but their *unselected* tint is `mutedInk` - so
            // they still have to be re-derived on a theme change.
            self?.styleIconButtons()
            self?.styleColorButtons()
        }

        labelField.stringValue = editing?.label ?? ""
        form.addLead(labelField)

        form.addSection("Connection")
        addressField.stringValue = editing?.address ?? ""
        portField.stringValue = editing.map { String($0.port) } ?? "22"
        portField.formatter = intFormatter()
        usernameField.stringValue = editing?.username ?? ""
        passwordField.stringValue = editing?.password ?? ""
        form.addFieldColumns([("Address", addressField), ("Port", portField)])
        form.addFieldColumns([("Username", usernameField), ("Password", passwordField)])
        buildKeyChooser()
        form.addRow(keyCard)
        form.addCaption("Password is used for this session only and never written to disk. "
            + "A chosen key is resolved from the Keychain at connect time (see the SSH Keys tab, \u{2318}\u{21e7}K); "
            + "with no key set, ssh falls back to the system agent.")

        form.addSection("Appearance")
        form.addRow(form.labelledField("Icon", buildIconPicker()))
        form.addRow(form.labelledField("Colour", buildColorPicker()))

        form.addSection("Organisation")
        groupField.stringValue = editing?.group ?? ""
        tagsField.stringValue = editing?.tags.joined(separator: ", ") ?? ""
        form.addFieldColumns([("Group", groupField), ("Tags, comma separated", tagsField)])

        form.addSection("Advanced")
        agentForwardRow.isOn = editing?.agentForward ?? false
        blockViewRow.isOn = editing?.blockViewOptIn ?? false
        form.addRow(agentForwardRow)
        form.addRow(blockViewRow)
        jumpViaField.stringValue = editing?.jumpVia ?? ""
        form.addField("Jump via", jumpViaField)
        portForwardingButton.target = self
        portForwardingButton.action = #selector(editPortForwarding)
        updatePortForwardingButtonTitle()
        let forwardingRow = NSStackView(views: [portForwardingButton, NSView()])
        forwardingRow.orientation = .horizontal
        forwardingRow.distribution = .fill
        forwardingRow.translatesAutoresizingMaskIntoConstraints = false
        forwardingRow.arrangedSubviews[1].setContentHuggingPriority(.defaultLow, for: .horizontal)
        form.addRow(form.labelledField("Port forwarding", forwardingRow))
        buildSnippetChooser()
        form.addRow(snippetCard)
        form.addCaption("Jumping chains through another saved host's own jump host automatically. "
            + "Agent forwarding and port-forwarding rules apply to this host's own connection.")

        form.setFooter(target: self,
                       confirmTitle: editing == nil ? "Create Host" : "Save",
                       confirm: #selector(save),
                       cancel: #selector(cancel),
                       delete: editing == nil ? nil : (title: "Delete", action: #selector(deleteHost)))

        form.refreshTheme()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(labelField)
    }

    // MARK: Field helpers

    private func intFormatter() -> NumberFormatter {
        let f = NumberFormatter()
        f.numberStyle = .none
        f.minimum = 1
        f.maximum = 65_535
        f.allowsFloats = false
        return f
    }

    // MARK: Key chooser (Phase 2, + Fix 5's inline "New Key…")

    /// "None" plus every saved key (by label), then a separator and
    /// "+ New Key…" (Fix 5). Re-callable so a key created inline can be
    /// spliced into the same card - `selectedID` picks up where
    /// `editing?.keyID` otherwise would.
    private func buildKeyChooser(selecting selectedID: UUID? = nil) {
        let ids: [UUID?] = [nil] + keyStore.keys.map { $0.id }
        let titles = ["None (use system ssh agent)"] + keyStore.keys.map { "\($0.label) (\($0.type.displayName))" }
        let target = selectedID ?? selectedKeyID
        let index = target.flatMap { ids.firstIndex(of: $0) } ?? 0
        selectedKeyID = ids.indices.contains(index) ? ids[index] : nil
        keyCard.configureChoices(titles,
                                 selectedIndex: index,
                                 extra: [HelmFieldCard.ExtraItem(title: "+ New Key\u{2026}") { [weak self] in
                                     self?.presentNewKeySheet()
                                 }]) { [weak self] chosen in
            self?.selectedKeyID = ids.indices.contains(chosen) ? ids[chosen] : nil
        }
    }

    /// Fix 5: create a key without leaving the host form. Opens the same
    /// Phase-2 sheet the SSH Keys tab uses; on save, persists through
    /// `SSHKeyStore.addNew` and rebuilds the chooser with the new key selected.
    /// On cancel (or a Keychain failure) the previous selection is left alone -
    /// unlike the old popup, picking "+ New Key…" from a menu never moves the
    /// card's own selection in the first place, so there is nothing to revert.
    private func presentNewKeySheet() {
        let editor = KeyEditorController(key: nil)
        editor.onSave = { [weak self] newKey, privateKeyData, passphrase in
            guard let self else { return }
            do {
                try self.keyStore.addNew(newKey, privateKeyData: privateKeyData, passphrase: passphrase)
                self.buildKeyChooser(selecting: newKey.id)
            } catch {
                self.presentKeyStoreError(error, label: newKey.label)
            }
        }
        presentAsSheet(editor)
    }

    private func presentKeyStoreError(_ error: Error, label: String) {
        let alert = NSAlert()
        alert.messageText = "Couldn't save \"\(label)\" to the Keychain"
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .critical
        alert.runModal()
    }

    // MARK: Snippet chooser + port forwarding (Phase 3)

    /// "None" plus every saved snippet, by label - the same shape as
    /// `buildKeyChooser`, so a startup snippet is picked the same way a key is.
    private func buildSnippetChooser() {
        let ids: [UUID?] = [nil] + snippets.map { $0.id }
        let titles = ["None"] + snippets.map { $0.label }
        let index = selectedSnippetID.flatMap { ids.firstIndex(of: $0) } ?? 0
        selectedSnippetID = ids.indices.contains(index) ? ids[index] : nil
        snippetCard.configureChoices(titles, selectedIndex: index) { [weak self] chosen in
            self?.selectedSnippetID = ids.indices.contains(chosen) ? ids[chosen] : nil
        }
    }

    private func updatePortForwardingButtonTitle() {
        portForwardingButton.title = portForwards.isEmpty
            ? "Port Forwarding\u{2026}"
            : "Port Forwarding (\(portForwards.count))\u{2026}"
    }

    /// Open the rules sheet on top of this one (a sheet-on-sheet, which
    /// AppKit supports); the edited list only lands on `portForwards` - and
    /// therefore on the host - when that sheet's own Save is clicked.
    @objc private func editPortForwarding() {
        let editor = PortForwardingController(rules: portForwards)
        editor.onSave = { [weak self] rules in
            self?.portForwards = rules
            self?.updatePortForwardingButtonTitle()
        }
        presentAsSheet(editor)
    }

    // MARK: Icon + colour pickers (A3)

    private func buildIconPicker() -> NSView {
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.spacing = HelmMetrics.s1
        stack.translatesAutoresizingMaskIntoConstraints = false
        for symbol in HostCatalog.icons {
            let b = NSButton(title: "", target: self, action: #selector(pickIcon(_:)))
            b.isBordered = false
            b.wantsLayer = true
            b.layer?.cornerRadius = HelmMetrics.rChip
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
        stack.spacing = HelmMetrics.s2 - 2
        stack.translatesAutoresizingMaskIntoConstraints = false
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
            b.contentTintColor = isSel ? accent : HelmTheme.mutedInk(ThemeManager.shared.theme)
            b.layer?.backgroundColor = (isSel ? accent.withAlphaComponent(0.18) : .clear).cgColor
        }
    }

    /// Selected swatch gets a ring so the choice is obvious.
    private func styleColorButtons() {
        let ring = HelmTheme.nsColor(ThemeManager.shared.theme.chromeInkHex)
        for b in colorButtons {
            let isSel = b.identifier?.rawValue == selectedAccent
            b.layer?.borderWidth = isSel ? 2.5 : 0
            b.layer?.borderColor = ring.cgColor
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
        guard let port = Int(portField.stringValue), (1...65535).contains(port) else {
            flag(portField)
            warn(title: "Invalid port", body: "Port must be a whole number between 1 and 65535.")
            return
        }

        var host = editing ?? Host(label: "", address: "")
        let resolvedLabel = label.isEmpty ? address : label
        if existingLabels.contains(resolvedLabel) {
            flag(labelField)
            warn(title: "Duplicate label", body: "Another saved host already uses the label \u{201C}\(resolvedLabel)\u{201D}. Quick-connect can't tell them apart - pick a unique label.")
            return
        }
        host.label = resolvedLabel
        host.address = address
        host.port = port
        host.username = usernameField.stringValue.trimmingCharacters(in: .whitespaces)
        let pw = passwordField.stringValue
        host.password = pw.isEmpty ? nil : pw
        host.keyID = selectedKeyID
        let group = groupField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        host.group = group.isEmpty ? nil : group
        host.tags = tagsField.stringValue
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        host.agentForward = agentForwardRow.isOn
        host.blockViewOptIn = blockViewRow.isOn
        let jumpVia = jumpViaField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        host.jumpVia = jumpVia.isEmpty ? nil : jumpVia
        host.portForwards = portForwards
        host.startupSnippetID = selectedSnippetID
        host.iconSymbol = selectedIcon
        host.accentHex = selectedAccent

        onSave?(host)
        closeEditor()
    }

    @objc private func deleteHost() {
        guard let id = editing?.id else { return }
        onDelete?(id)
        closeEditor()
    }

    @objc private func cancel() {
        closeEditor()
    }

    /// Briefly flash a required field's focus ring when it is empty.
    private func flag(_ field: NSTextField) {
        view.window?.makeFirstResponder(field)
        NSSound.beep()
    }

    /// A blocking validation warning at Save time (Finding 5, cockpit-audit-core) -
    /// same `NSAlert` shape as the Keychain-save-failure alert above.
    private func warn(title: String, body: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = body
        alert.alertStyle = .warning
        alert.runModal()
    }

    /// cockpit-native-host-form-fixes, Fix 2: this editor is presented as its
    /// own top-level window (`AppDelegate.presentHostEditor`), not via
    /// `presentAsSheet`/`presentAsModalWindow` from a parent view controller
    /// and not as a document-modal sheet either. `NSViewController.dismiss(_:)`
    /// only acts in those two cases (or the `presentingViewController` case);
    /// for a plain top-level window it is a documented no-op, which is why
    /// Cancel silently did nothing. Closing the window directly works
    /// regardless of how the view controller got there, and - since
    /// `isReleasedWhenClosed` is `false` on this cached, reused window - it
    /// still just orders out rather than deallocating, ready for the next
    /// Add/Edit call to set a fresh `contentViewController` on it.
    private func closeEditor() {
        view.window?.close()
    }
}
