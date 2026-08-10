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

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 560, height: 420))
        view = root
        // Theme-audit task: force this sheet's own appearance so its
        // system-semantic colors (`.tertiaryLabelColor`) resolve against the
        // active Helm theme's mode instead of whatever the OS happens to be
        // set to.
        ThemeManager.shared.observe { [weak root] theme in
            root?.appearance = NSAppearance(named: theme.mode == .dark ? .darkAqua : .aqua)
        }

        let title = NSTextField(labelWithString: "Port Forwarding")
        title.font = .systemFont(ofSize: 15, weight: .semibold)

        let caption = NSTextField(wrappingLabelWithString:
            "Local (-L) reaches a remote service from this Mac. Remote (-R) exposes a local "
            + "service to the remote host. Dynamic (-D) opens a SOCKS proxy on the listen port."
        )
        caption.font = .systemFont(ofSize: 11)
        caption.textColor = .tertiaryLabelColor
        caption.translatesAutoresizingMaskIntoConstraints = false

        rowsStack.orientation = .vertical
        rowsStack.alignment = .leading
        rowsStack.spacing = 6
        rowsStack.translatesAutoresizingMaskIntoConstraints = false
        for rule in rules { addRow(for: rule) }

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.documentView = rowsStack
        scroll.translatesAutoresizingMaskIntoConstraints = false
        rowsStack.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor).isActive = true

        let addButton = NSButton(title: " Add Rule", target: self, action: #selector(addRuleClicked))
        addButton.image = NSImage(systemSymbolName: "plus.circle", accessibilityDescription: "Add Rule")
        addButton.imagePosition = .imageLeading
        addButton.bezelStyle = .rounded

        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancel.bezelStyle = .rounded
        cancel.keyEquivalent = "\u{1b}"
        let save = NSButton(title: "Save", target: self, action: #selector(save))
        save.bezelStyle = .rounded
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
            self.rowsStack.removeArrangedSubview(row)
            row.removeFromSuperview()
            self.rows.removeAll { $0 === row }
        }
        rows.append(row)
        rowsStack.addArrangedSubview(row)
    }

    @objc private func addRuleClicked() {
        addRow(for: PortForwardRule())
    }

    @objc private func save() {
        onSave?(rows.map { $0.currentRule })
        dismiss(self)
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

    private let kindPopup = NSPopUpButton()
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
        arrow.textColor = .tertiaryLabelColor

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
