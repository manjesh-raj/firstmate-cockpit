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
//
// `fm/grandline-hosts-keys-form-redesign` gave the form a real visual pass
// against a captain-approved mockup
// (`data/grandline-hosts-keys-mockup/mockup.html`) - numbered/kickered
// sections, an accent-tinted Keychain-security note, a DEV/UAT/PROD quick-pick
// row over the existing free-text `Host.group` (no new field - see
// `HostEnvironmentPicker`'s own doc comment), and a real chip-flow Tags input
// matching `ShiftTaskEditorController`'s own tag chips. This is presentation
// only: every field, every validation rule, save/cancel/delete and the inline
// "+ New Key…" flow are unchanged. The mockup's "Test Connection" footer
// button has no backing capability anywhere in this app (no connection-test
// code exists to call) and was deliberately left out rather than invented -
// see the PR description for this task.
//
// Section numbering also picked up a fifth section, "Appearance" (the icon/
// colour pickers), that the mockup itself doesn't show - those pickers are a
// real, already-shipped feature (`Host.iconSymbol`/`accentHex`) with no
// equivalent in the mockup's four sections, and removing them would be a
// functionality regression, not a restyle.

import AppKit

final class HostEditorController: NSViewController, NSTextFieldDelegate {

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
    private let keyIconTile = IconTileView(size: 30, cornerRadius: HelmMetrics.rChip)
    private lazy var keyCard = HelmFieldCard(label: "SSH Key", accessory: keyIconTile)
    private let environmentPicker = HostEnvironmentPicker()
    private let groupField = HelmTextField(placeholder: "e.g. Production")
    private let tagInputField = HelmTextField(placeholder: "Add a tag, press Enter\u{2026}")
    private let tagsChipsFlow = ChipFlowView()
    private var tagChips: [String] = []
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
        self.tagChips = host?.tags ?? []
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
        form.onApplyTheme = { [weak self] theme in
            // The icon/colour swatches carry the host's own chosen accent, not
            // a theme token, but their *unselected* tint is `mutedInk` - so
            // they still have to be re-derived on a theme change. Same for
            // the environment quick-pick row, which is tinted per-option
            // rather than by `mutedLabels`/`fieldCards`.
            self?.styleIconButtons()
            self?.styleColorButtons()
            self?.environmentPicker.applyTheme(theme)
            self?.keyIconTile.applyTheme(theme)
            self?.tagsChipsFlow.subviews.compactMap { $0 as? VocabularyChipView }.forEach { $0.applyTheme(theme) }
        }

        labelField.stringValue = editing?.label ?? ""
        form.addLead(labelField)

        form.addSection("Connection", number: "01")
        addressField.stringValue = editing?.address ?? ""
        form.addField("Address", addressField)
        portField.stringValue = editing.map { String($0.port) } ?? "22"
        portField.formatter = intFormatter()
        usernameField.stringValue = editing?.username ?? ""
        form.addFieldColumns([("Port", portField), ("Username", usernameField)])
        passwordField.stringValue = editing?.password ?? ""
        form.addField("Password", passwordField)
        environmentPicker.onSelect = { [weak self] title in self?.groupField.stringValue = title }
        environmentPicker.select(editing?.group)
        form.addField("Environment", environmentPicker)

        form.addSection("Authentication", number: "02")
        keyIconTile.configure(symbol: "key.fill", tint: .warn, pointSize: 13)
        buildKeyChooser()
        form.addRow(keyCard)
        form.addInfoCard(text: "The private key is resolved from the macOS Keychain when connecting. "
            + "Grand Line never stores the private key material inside the host configuration.")

        form.addSection("Appearance", number: "03")
        form.addRow(form.labelledField("Icon", buildIconPicker()))
        form.addRow(form.labelledField("Colour", buildColorPicker()))

        form.addSection("Organization", number: "04")
        groupField.stringValue = editing?.group ?? ""
        groupField.delegate = self
        let tagsColumn = NSStackView(views: [tagInputField, tagsChipsFlow])
        tagsColumn.orientation = .vertical
        tagsColumn.alignment = .leading
        tagsColumn.spacing = HelmMetrics.s2
        tagsColumn.translatesAutoresizingMaskIntoConstraints = false
        tagInputField.delegate = self
        renderTagChips()
        form.addColumns([form.labelledField("Group", groupField),
                          form.labelledField("Tags", tagsColumn)])

        form.addSection("Advanced", number: "05")
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
                       confirmTitle: editing == nil ? "Create Host" : "Save Changes",
                       confirm: #selector(save),
                       cancel: #selector(cancel),
                       delete: editing == nil ? nil : (title: "Delete Host", action: #selector(deleteHost)))

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

    // MARK: Environment quick-pick + Tags (redesign)

    /// `groupField` can also be typed into directly - keep the quick-pick row
    /// in sync either way, and keep the tag-chip input's Enter-to-commit
    /// behaviour (`ShiftTaskEditorController`'s own established pattern).
    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSTextField else { return }
        if field === groupField {
            environmentPicker.select(groupField.stringValue)
            return
        }
        guard field === tagInputField else { return }
        let text = tagInputField.stringValue
        guard text.hasSuffix(",") else { return }
        let candidate = String(text.dropLast())
        tagInputField.stringValue = ""
        commitTag(candidate)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard control === tagInputField, commandSelector == #selector(NSResponder.insertNewline(_:)) else { return false }
        commitTag(tagInputField.stringValue)
        tagInputField.stringValue = ""
        return true
    }

    private func commitTag(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        guard !tagChips.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) else { return }
        tagChips.append(trimmed)
        renderTagChips()
    }

    private func renderTagChips() {
        let theme = ThemeManager.shared.theme
        let chips: [NSView] = tagChips.map { tag in
            let chip = VocabularyChipView(word: tag)
            chip.applyTheme(theme)
            chip.onRemove = { [weak self] in
                self?.tagChips.removeAll { $0 == tag }
                self?.renderTagChips()
            }
            return chip
        }
        tagsChipsFlow.setChips(chips)
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
        host.tags = tagChips
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

// MARK: - Environment quick-pick row

/// The mockup's DEV/UAT/PROD quick-pick row - a convenience over the
/// existing free-text `Host.group` field, **not** a new persisted concept
/// (per this task's own instruction: check `group`/`tags` before inventing a
/// field). Clicking a pill sets `onSelect` with that pill's title, which the
/// host editor writes straight into `groupField`; the row itself highlights
/// whichever pill case-insensitively matches the current `group` text, or
/// none when the group is empty or something else entirely (a host grouped
/// under, say, "Networking" shows no selected pill here, and the free-text
/// Group field in the Organization section is still the source of truth).
final class HostEnvironmentPicker: NSView {
    private struct Option {
        let title: String
        let tint: HelmTint
    }

    private static let options: [Option] = [
        Option(title: "DEV", tint: .info),
        Option(title: "UAT", tint: .warn),
        Option(title: "PROD", tint: .critical),
    ]

    private var pills: [(container: HoverHighlightView, dot: NSView, label: NSTextField, option: Option)] = []

    /// Fires with the clicked pill's title (`"DEV"`/`"UAT"`/`"PROD"`).
    var onSelect: ((String) -> Void)?

    private(set) var selectedTitle: String?

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        var containers: [NSView] = []
        for option in Self.options {
            let container = HoverHighlightView()
            container.cornerRadius = HelmField.cornerRadius
            container.identifier = NSUserInterfaceItemIdentifier(option.title)

            let dot = NSView()
            dot.wantsLayer = true
            dot.layer?.cornerRadius = 3
            dot.translatesAutoresizingMaskIntoConstraints = false

            let label = NSTextField(labelWithString: option.title)
            label.font = .systemFont(ofSize: 10.5, weight: .bold)
            label.translatesAutoresizingMaskIntoConstraints = false

            let row = NSStackView(views: [dot, label])
            row.orientation = .horizontal
            row.alignment = .centerY
            row.spacing = 5
            row.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(row)
            NSLayoutConstraint.activate([
                row.centerXAnchor.constraint(equalTo: container.centerXAnchor),
                row.centerYAnchor.constraint(equalTo: container.centerYAnchor),
                dot.widthAnchor.constraint(equalToConstant: 6),
                dot.heightAnchor.constraint(equalToConstant: 6),
                container.heightAnchor.constraint(equalToConstant: HelmField.controlHeight),
            ])
            container.addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(pillClicked(_:))))
            pills.append((container, dot, label, option))
            containers.append(container)
        }

        let row = NSStackView(views: containers)
        row.orientation = .horizontal
        row.distribution = .fillEqually
        row.spacing = HelmMetrics.s1 + 2
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        applyTheme(ThemeManager.shared.theme)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    @objc private func pillClicked(_ sender: NSClickGestureRecognizer) {
        guard let id = sender.view?.identifier?.rawValue else { return }
        select(id)
        onSelect?(id)
    }

    /// Move the highlight without firing `onSelect` - called whenever the
    /// bound `group` value changes from something other than a pill click
    /// (typing directly into the Group field, or loading an existing host).
    func select(_ groupValue: String?) {
        selectedTitle = Self.options.first { $0.title.caseInsensitiveCompare(groupValue ?? "") == .orderedSame }?.title
        applyTheme(ThemeManager.shared.theme)
    }

    func applyTheme(_ theme: HelmTheme) {
        for (container, dot, label, option) in pills {
            let hue = HelmTheme.nsColor(option.tint.hex(in: theme))
            dot.layer?.backgroundColor = hue.cgColor
            if option.title == selectedTitle {
                let resolved = HelmContrast.tintedSurface(tintHex: option.tint.hex(in: theme),
                                                          theme: theme,
                                                          target: HelmContrast.textTarget)
                container.normalColor = resolved.fill
                container.hoverColor = resolved.fill
                container.layer?.borderWidth = 1
                container.layer?.borderColor = hue.withAlphaComponent(0.55).cgColor
                label.textColor = resolved.foreground
            } else {
                let fill = HelmField.fill(theme)
                container.normalColor = fill
                container.hoverColor = fill.hoverShifted(by: 0.10, forMode: theme.mode)
                container.layer?.borderWidth = 1
                container.layer?.borderColor = HelmField.border(theme).cgColor
                label.textColor = HelmField.mutedInk(theme)
            }
        }
    }
}
