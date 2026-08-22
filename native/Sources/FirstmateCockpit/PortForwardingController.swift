// Manjesh Grand Line - native macOS app.
//
// The port-forwarding rules sheet (design report Section B1, Section D Phase
// 3): a rules list for a single host's Local (`-L`), Remote (`-R`), and
// Dynamic/SOCKS (`-D`) forwards, opened from the host editor's "Port
// Forwarding\u{2026}" button. Presented as a sheet, edited entirely in
// memory, and handed back to the caller as `[PortForwardRule]` on Save - this
// view never touches `HostStore` itself.

import AppKit

final class PortForwardingController: NSViewController {

    private var rules: [PortForwardRule]
    private var rows: [PortForwardRuleRowView] = []

    /// Called with the edited rule list on Save.
    var onSave: (([PortForwardRule]) -> Void)?

    private let rowsStack = NSStackView()

    init(rules: [PortForwardRule]) {
        self.rules = rules
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Labels carrying `HelmTheme.mutedInk` instead of a fixed system grey -
    /// see `MutedInkLabels` for why a system grey is wrong here (audit §5.3).
    private let mutedLabels = MutedInkLabels()
    /// The rules list's scroll view, kept so its sunken chrome can be
    /// recoloured on a theme change.
    private var rulesScroll: NSScrollView?

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 560, height: 420))
        view = root
        // Theme-audit task: force this sheet's own appearance so any
        // system-semantic color still in its subtree resolves against the
        // active Helm theme's mode instead of whatever the OS happens to be
        // set to. Its own muted text no longer relies on that - it goes
        // through `mutedLabels` (audit §5.3), which is theme-aware rather
        // than merely light/dark-correct.
        ThemeManager.shared.observe { [weak root, weak self] theme in
            root?.appearance = NSAppearance(named: theme.mode == .dark ? .darkAqua : .aqua)
            self?.mutedLabels.apply(theme)
            self?.rowsStack.arrangedSubviews
                .compactMap { $0 as? PortForwardRuleRowView }
                .forEach { $0.applyTheme(theme) }
            if let scroll = self?.rulesScroll { HelmField.applySunken(to: scroll, theme: theme) }
        }

        let title = NSTextField(labelWithString: "Port Forwarding")
        title.font = .systemFont(ofSize: 15, weight: .semibold)

        let caption = NSTextField(wrappingLabelWithString:
            "Local (-L) reaches a remote service from this Mac. Remote (-R) exposes a local "
            + "service to the remote host. Dynamic (-D) opens a SOCKS proxy on the listen port."
        )
        caption.font = .systemFont(ofSize: 11)
        mutedLabels.add(caption)
        caption.translatesAutoresizingMaskIntoConstraints = false

        rowsStack.orientation = .vertical
        rowsStack.alignment = .leading
        rowsStack.spacing = 6
        rowsStack.translatesAutoresizingMaskIntoConstraints = false
        for rule in rules { addRow(for: rule) }

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        // Phase 6 of the UI audit: the shared sunken chrome, not AppKit's own
        // `.bezelBorder` frame. This sheet opens on top of the Host editor,
        // which is now entirely `HelmField`-chromed, so a grey system frame
        // here would be the one stale box in the stack.
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        HelmField.makeSunken(scroll)
        scroll.documentView = rowsStack
        scroll.translatesAutoresizingMaskIntoConstraints = false
        rulesScroll = scroll
        HelmField.applySunken(to: scroll, theme: ThemeManager.shared.theme)
        rowsStack.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor).isActive = true

        let addButton = HelmButton(title: "Add Rule", variant: .secondary, symbol: "plus.circle", target: self, action: #selector(addRuleClicked))

        let cancel = HelmButton(title: "Cancel", variant: .secondary, target: self, action: #selector(cancel))
        cancel.keyEquivalent = "\u{1b}"
        let save = HelmButton(title: "Save", variant: .primary, target: self, action: #selector(save))
        save.keyEquivalent = "\r"
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let bottom = NSStackView(views: [addButton, spacer, cancel, save])
        bottom.orientation = .horizontal
        bottom.spacing = 10
        bottom.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [title, caption, scroll, bottom])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 18),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -18),
            caption.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scroll.heightAnchor.constraint(equalToConstant: 220),
            bottom.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
    }

    private func addRow(for rule: PortForwardRule) {
        let row = PortForwardRuleRowView(rule: rule)
        row.onRemove = { [weak self, weak row] in
            guard let self, let row else { return }
            // GL-33: the other unconfirmed small delete the review named. The
            // rule the row *currently* holds (not the one it was built with -
            // the captain may have edited the fields since) is what gets
            // restored, at the same position.
            let restored = row.currentRule
            let index = self.rows.firstIndex { $0 === row }
            self.rowsStack.removeArrangedSubview(row)
            row.removeFromSuperview()
            self.rows.removeAll { $0 === row }
            Toast.showUndo(in: self.view, message: "Removed a forwarding rule") { [weak self] in
                guard let self else { return }
                self.addRow(for: restored)
                // Put it back where it was rather than at the end.
                if let index, index < self.rows.count - 1, let moved = self.rows.popLast() {
                    self.rows.insert(moved, at: index)
                    self.rowsStack.removeArrangedSubview(moved)
                    self.rowsStack.insertArrangedSubview(moved, at: index)
                }
            }
        }
        rows.append(row)
        rowsStack.addArrangedSubview(row)
    }

    @objc private func addRuleClicked() {
        addRow(for: PortForwardRule())
    }

    /// Finding 5 (cockpit-audit-core): listen/dest ports used to be `Int(text)
    /// ?? 0` with no range check, and a Local/Remote rule could be saved with
    /// an empty dest host - both only failed later, silently, when the ssh
    /// tab actually connected. Validate every row at Save time instead.
    @objc private func save() {
        let rules = rows.map { $0.currentRule }
        for rule in rules {
            guard (1...65535).contains(rule.listenPort) else {
                warn(title: "Invalid listen port", body: "Listen port must be a whole number between 1 and 65535.")
                return
            }
            if rule.kind != .dynamic {
                guard (1...65535).contains(rule.destPort) else {
                    warn(title: "Invalid destination port", body: "Destination port must be a whole number between 1 and 65535.")
                    return
                }
                guard !rule.destHost.isEmpty else {
                    warn(title: "Missing destination host", body: "Local and Remote forwarding rules need a destination host.")
                    return
                }
            }
        }
        onSave?(rules)
        dismiss(self)
    }

    private func warn(title: String, body: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = body
        alert.alertStyle = .warning
        alert.runModal()
    }

    @objc private func cancel() {
        dismiss(self)
    }
}

// MARK: - One rule row

/// One editable rule: a Kind popup, bind/listen fields, an arrow, dest
/// host/port fields (hidden for `.dynamic`, which has no destination), and a
/// remove button. A dumb view - `PortForwardingController` reads
/// `currentRule` back on Save rather than being told about every keystroke.
private final class PortForwardRuleRowView: NSView {

    private let kindPopup = HelmPopUpButton()
    private let bindField = NSTextField()
    private let listenField = NSTextField()
    private let arrow = NSTextField(labelWithString: "\u{2192}")
    private let destHostField = NSTextField()
    private let destPortField = NSTextField()
    private let removeButton = NSButton()

    var onRemove: (() -> Void)?

    init(rule: PortForwardRule) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        kindPopup.translatesAutoresizingMaskIntoConstraints = false
        for kind in PortForwardRule.Kind.allCases {
            kindPopup.addItem(withTitle: kind.displayName)
        }
        kindPopup.selectItem(at: PortForwardRule.Kind.allCases.firstIndex(of: rule.kind) ?? 0)
        kindPopup.target = self
        kindPopup.action = #selector(kindChanged)

        configure(bindField, placeholder: "bind (optional)", value: rule.bindAddress, width: 100)
        configure(listenField, placeholder: "listen port", value: String(rule.listenPort), width: 74)
        configure(destHostField, placeholder: "dest host", value: rule.destHost, width: 110)
        configure(destPortField, placeholder: "dest port", value: String(rule.destPort), width: 64)
        applyTheme(ThemeManager.shared.theme)

        removeButton.isBordered = false
        removeButton.image = NSImage(systemSymbolName: "minus.circle", accessibilityDescription: "Remove")
        removeButton.target = self
        removeButton.action = #selector(removeClicked)
        removeButton.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [kindPopup, bindField, listenField, arrow, destHostField, destPortField, removeButton])
        stack.orientation = .horizontal
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 3),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3),
        ])

        applyDynamicVisibility()
    }

    /// The row's own muted arrow glyph, re-derived from the active theme -
    /// it used to be `.tertiaryLabelColor`, a fixed system grey that is both
    /// off-palette and below the contrast floor in every theme (audit §5.3).
    func applyTheme(_ theme: HelmTheme) {
        arrow.textColor = HelmTheme.mutedInk(theme)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func configure(_ field: NSTextField, placeholder: String, value: String, width: CGFloat) {
        field.placeholderString = placeholder
        field.stringValue = value
        field.translatesAutoresizingMaskIntoConstraints = false
        field.widthAnchor.constraint(equalToConstant: width).isActive = true
    }

    @objc private func kindChanged() {
        applyDynamicVisibility()
    }

    @objc private func removeClicked() {
        onRemove?()
    }

    /// A dynamic/SOCKS rule has no destination - grey the dest fields out
    /// rather than hide them, so the row's width (and the column alignment
    /// above it) stays stable while flipping the popup.
    private func applyDynamicVisibility() {
        let isDynamic = currentKind == .dynamic
        destHostField.isEnabled = !isDynamic
        destPortField.isEnabled = !isDynamic
    }

    private var currentKind: PortForwardRule.Kind {
        PortForwardRule.Kind.allCases[kindPopup.indexOfSelectedItem]
    }

    var currentRule: PortForwardRule {
        var rule = PortForwardRule()
        rule.kind = currentKind
        rule.bindAddress = bindField.stringValue.trimmingCharacters(in: .whitespaces)
        rule.listenPort = Int(listenField.stringValue) ?? 0
        rule.destHost = destHostField.stringValue.trimmingCharacters(in: .whitespaces)
        rule.destPort = Int(destPortField.stringValue) ?? 0
        return rule
    }
}
