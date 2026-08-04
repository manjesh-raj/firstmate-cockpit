// Firstmate Cockpit - native macOS app.
//
// The native Settings panel (Fix 3) - rebuilt to match the richer web
// cockpit layout (`backend/static/index.html`'s Settings screen): icon +
// title section headers, generous spacing, and grouped cards rather than a
// flat list of rows. Three sections (Sign-in is skipped - native has no
// login):
//
//   - Connection: the mirror-target field, upgraded with a live "Detect"
//     session picker (`TmuxMirror.listSessions()`) showing every discovered
//     tmux pane as a selectable card (target, command/cwd, a "home" badge
//     when its cwd is inside the firstmate home) - clicking one sets it as
//     the mirror target. The working-directory chooser (previously under
//     "General") lives here too.
//   - Appearance: the 8-theme picker as a wrapping grid of preview cards
//     (colour-bar swatch + name + checkmark), reusing `HelmTheme.allThemes`
//     - the same source of truth the topbar's `ThemeMenu` picker uses.
//   - Terminal: font-size presets (12/13/14/16, routed through
//     `ConsoleController.stepFontSize` via `onFontSizeStep` as before), plus
//     two toggles with real behaviour behind them: "Reconnect automatically"
//     (`AppSettings.autoReconnect`, read by `ConsoleController.
//     processTerminated`) and "Bell & notifications" (`AppSettings.
//     notifyOnNeedsDecision`, driving `FleetNotifier`). Session logging
//     (previously under "General") moves here too, since it's another
//     per-session terminal behaviour.
//
// Like before, fields persist immediately on change rather than batching
// into a Save button.

import AppKit

final class SettingsController: NSViewController {

    /// The Terminal section's font-size presets. Wired by the app delegate to
    /// `ConsoleController.stepFontSize`, since this panel never holds a
    /// direct reference to the console.
    var onFontSizeStep: ((CGFloat) -> Void)?

    private var theme: HelmTheme = ThemeManager.shared.theme

    // Connection
    private let mirrorTargetField = NSTextField()
    private let sessionsStatusLabel = NSTextField(wrappingLabelWithString: "")
    private let sessionsStack = NSStackView()
    private let shellCwdField = NSTextField()

    // Appearance
    private let appearanceContainer = NSStackView()

    // Terminal
    private var fontPresetButtons: [Int: NSButton] = [:]
    private let autoReconnectSwitch = NSSwitch()
    private let notifySwitch = NSSwitch()
    private let sessionLoggingSwitch = NSSwitch()

    /// Card-ish containers that need per-theme restyling, rebuilt each time
    /// their section refreshes.
    private var cardBackgroundViews: [NSView] = []

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 620, height: 720))
        root.wantsLayer = true
        view = root
        ThemeManager.shared.observe { [weak root, weak self] theme in
            root?.appearance = NSAppearance(named: theme.mode == .dark ? .darkAqua : .aqua)
            root?.layer?.backgroundColor = HelmTheme.nsColor(theme.backgroundHex).cgColor
            self?.theme = theme
            self?.refreshFromSettings()
        }

        let connection = card(icon: "network", title: "Connection", content: buildConnectionSection())
        let appearance = card(icon: "paintpalette", title: "Appearance", content: buildAppearanceSection())
        let terminal = card(icon: "terminal", title: "Terminal", content: buildTerminalSection())

        let stack = NSStackView(views: [connection, appearance, terminal])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 18
        stack.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 22),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -24),
            connection.widthAnchor.constraint(equalTo: stack.widthAnchor),
            appearance.widthAnchor.constraint(equalTo: stack.widthAnchor),
            terminal.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])

        let scroll = NSScrollView()
        scroll.documentView = content
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: root.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            content.widthAnchor.constraint(equalTo: scroll.widthAnchor),
        ])

        refreshFromSettings()
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        refreshFromSettings()
    }

    // MARK: Card chrome

    /// A section's card shell: an icon + title header, then its content,
    /// generously padded and given a rounded, bordered background - matching
    /// the web app's `.card` visual weight rather than a flat sparse list.
    private func card(icon: String, title: String, content: NSView) -> NSView {
        let iconView = NSImageView()
        iconView.image = NSImage(systemSymbolName: icon, accessibilityDescription: title)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 14, weight: .semibold))
        iconView.translatesAutoresizingMaskIntoConstraints = false

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 14.5, weight: .semibold)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        let header = NSStackView(views: [iconView, titleLabel])
        header.orientation = .horizontal
        header.spacing = 8
        header.alignment = .firstBaseline
        header.translatesAutoresizingMaskIntoConstraints = false

        content.translatesAutoresizingMaskIntoConstraints = false

        let inner = NSStackView(views: [header, content])
        inner.orientation = .vertical
        inner.alignment = .leading
        inner.spacing = 16
        inner.translatesAutoresizingMaskIntoConstraints = false
        content.widthAnchor.constraint(equalTo: inner.widthAnchor).isActive = true

        let background = NSView()
        background.wantsLayer = true
        background.layer?.cornerRadius = 13
        background.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(inner)
        NSLayoutConstraint.activate([
            inner.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 18),
            inner.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -18),
            inner.topAnchor.constraint(equalTo: background.topAnchor, constant: 16),
            inner.bottomAnchor.constraint(equalTo: background.bottomAnchor, constant: -18),
        ])
        cardBackgroundViews.append(background)
        return background
    }

    private func rowLabel(_ text: String) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.font = .systemFont(ofSize: 12)
        l.textColor = .secondaryLabelColor
        return l
    }

    private func descRow(title: String, desc: String, trailing: NSView) -> NSView {
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 12.5, weight: .medium)
        let descLabel = NSTextField(wrappingLabelWithString: desc)
        descLabel.font = .systemFont(ofSize: 11)
        descLabel.textColor = .secondaryLabelColor
        descLabel.preferredMaxLayoutWidth = 360

        let textStack = NSStackView(views: [titleLabel, descLabel])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 2
        textStack.setContentHuggingPriority(.defaultLow, for: .horizontal)

        trailing.translatesAutoresizingMaskIntoConstraints = false
        trailing.setContentHuggingPriority(.required, for: .horizontal)

        let row = NSStackView(views: [textStack, trailing])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 14
        row.translatesAutoresizingMaskIntoConstraints = false
        return row
    }

    private func pillView(text: String, colorHex: String) -> NSView {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 9.5, weight: .semibold)
        label.textColor = HelmTheme.nsColor(colorHex)
        label.translatesAutoresizingMaskIntoConstraints = false
        let container = NSView()
        container.wantsLayer = true
        container.layer?.cornerRadius = 7
        container.layer?.backgroundColor = HelmTheme.nsColor(colorHex).withAlphaComponent(0.15).cgColor
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 6),
            label.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -6),
            label.topAnchor.constraint(equalTo: container.topAnchor, constant: 2),
            label.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -2),
        ])
        return container
    }

    // MARK: Connection

    private func buildConnectionSection() -> NSView {
        let label = NSTextField(labelWithString: "Mirror target")
        label.font = .systemFont(ofSize: 12.5, weight: .medium)

        let desc = NSTextField(wrappingLabelWithString: "The tmux target the console's Mirror tab attaches to. Detect lists every discovered session below - click one to select it.")
        desc.font = .systemFont(ofSize: 11)
        desc.textColor = .secondaryLabelColor
        desc.preferredMaxLayoutWidth = 520

        configure(mirrorTargetField, placeholder: "firstmate")
        let detectButton = NSButton(title: "Detect", target: self, action: #selector(detectClicked))
        detectButton.bezelStyle = .rounded
        detectButton.image = NSImage(systemSymbolName: "arrow.triangle.2.circlepath", accessibilityDescription: "Detect")
        detectButton.imagePosition = .imageLeading

        let fieldRow = NSStackView(views: [mirrorTargetField, detectButton])
        fieldRow.orientation = .horizontal
        fieldRow.spacing = 8
        mirrorTargetField.setContentHuggingPriority(.defaultLow, for: .horizontal)

        sessionsStatusLabel.font = .systemFont(ofSize: 11)
        sessionsStatusLabel.textColor = .secondaryLabelColor

        sessionsStack.orientation = .vertical
        sessionsStack.alignment = .leading
        sessionsStack.spacing = 6
        sessionsStack.translatesAutoresizingMaskIntoConstraints = false

        let mirrorGroup = NSStackView(views: [label, desc, fieldRow, sessionsStatusLabel, sessionsStack])
        mirrorGroup.orientation = .vertical
        mirrorGroup.alignment = .leading
        mirrorGroup.spacing = 8
        fieldRow.widthAnchor.constraint(equalTo: mirrorGroup.widthAnchor).isActive = true
        sessionsStack.widthAnchor.constraint(equalTo: mirrorGroup.widthAnchor).isActive = true

        let chooseCwd = NSButton(title: "Choose\u{2026}", target: self, action: #selector(chooseShellCwd))
        chooseCwd.bezelStyle = .rounded
        configure(shellCwdField, placeholder: "~ (Home)")
        shellCwdField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let cwdRow = NSStackView(views: [shellCwdField, chooseCwd])
        cwdRow.orientation = .horizontal
        cwdRow.spacing = 8

        let cwdGroup = descRow(title: "Working directory", desc: "Where new Shell/Firstmate tabs open.", trailing: cwdRow)
        cwdRow.widthAnchor.constraint(lessThanOrEqualToConstant: 300).isActive = true

        let section = NSStackView(views: [mirrorGroup, separator(), cwdGroup])
        section.orientation = .vertical
        section.alignment = .leading
        section.spacing = 16
        mirrorGroup.widthAnchor.constraint(equalTo: section.widthAnchor).isActive = true
        cwdGroup.widthAnchor.constraint(equalTo: section.widthAnchor).isActive = true
        return section
    }

    private func separator() -> NSView {
        let v = NSView()
        v.wantsLayer = true
        v.heightAnchor.constraint(equalToConstant: 1).isActive = true
        separatorViews.append(v)
        return v
    }

    private var separatorViews: [NSView] = []

    @objc private func detectClicked() {
        refreshSessions()
    }

    private func refreshSessions() {
        for v in sessionsStack.arrangedSubviews {
            sessionsStack.removeArrangedSubview(v)
            v.removeFromSuperview()
        }
        guard let sessions = TmuxMirror.listSessions() else {
            sessionsStatusLabel.stringValue = "No tmux server running - start your first mate in tmux, then Detect."
            sessionsStatusLabel.isHidden = false
            return
        }
        if sessions.isEmpty {
            sessionsStatusLabel.stringValue = "No tmux panes found."
            sessionsStatusLabel.isHidden = false
            return
        }
        sessionsStatusLabel.isHidden = true
        let current = AppSettings.shared.mirrorTarget ?? ""
        for s in sessions {
            let card = sessionCard(s, isSelected: s.target == current)
            sessionsStack.addArrangedSubview(card)
            card.widthAnchor.constraint(equalTo: sessionsStack.widthAnchor).isActive = true
        }
    }

    private func sessionCard(_ s: TmuxMirror.SessionInfo, isSelected: Bool) -> NSView {
        let targetLabel = NSTextField(labelWithString: s.target)
        targetLabel.font = .monospacedSystemFont(ofSize: 12, weight: .semibold)

        var titleViews: [NSView] = [targetLabel]
        if s.isHome { titleViews.append(pillView(text: "home", colorHex: theme.accentHex)) }
        let titleRow = NSStackView(views: titleViews)
        titleRow.orientation = .horizontal
        titleRow.spacing = 6
        titleRow.alignment = .firstBaseline

        var subBits = [s.command]
        if !s.path.isEmpty { subBits.append(s.path) }
        let subLabel = NSTextField(labelWithString: subBits.joined(separator: " \u{00B7} "))
        subLabel.font = .monospacedSystemFont(ofSize: 10.5, weight: .regular)
        subLabel.textColor = .secondaryLabelColor
        subLabel.lineBreakMode = .byTruncatingMiddle

        let textStack = NSStackView(views: [titleRow, subLabel])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 2
        textStack.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let check = NSImageView()
        check.image = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: nil)
        check.contentTintColor = HelmTheme.nsColor(theme.accentHex)
        check.isHidden = !isSelected
        check.translatesAutoresizingMaskIntoConstraints = false
        check.setContentHuggingPriority(.required, for: .horizontal)

        let row = NSStackView(views: [textStack, check])
        row.orientation = .horizontal
        row.spacing = 10
        row.alignment = .centerY
        row.translatesAutoresizingMaskIntoConstraints = false

        let card = NSView()
        card.wantsLayer = true
        card.layer?.cornerRadius = 9
        card.layer?.borderWidth = isSelected ? 1.5 : 1
        card.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 12),
            row.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -12),
            row.topAnchor.constraint(equalTo: card.topAnchor, constant: 9),
            row.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -9),
        ])
        card.layer?.backgroundColor = HelmTheme.nsColor(theme.chromeBackgroundHex).cgColor
        card.layer?.borderColor = (isSelected ? HelmTheme.nsColor(theme.accentHex) : HelmTheme.nsColor(theme.chromeLineHex).withAlphaComponent(0.5)).cgColor

        let click = NSClickGestureRecognizer(target: self, action: #selector(sessionCardClicked(_:)))
        card.addGestureRecognizer(click)
        card.identifier = NSUserInterfaceItemIdentifier(s.target)
        return card
    }

    @objc private func sessionCardClicked(_ sender: NSClickGestureRecognizer) {
        guard let id = sender.view?.identifier?.rawValue else { return }
        mirrorTargetField.stringValue = id
        AppSettings.shared.mirrorTarget = id
        refreshSessions()
    }

    @objc private func chooseShellCwd() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose the default working directory for new Shell/Firstmate tabs."
        if let current = AppSettings.shared.defaultShellCwd {
            panel.directoryURL = URL(fileURLWithPath: (current as NSString).expandingTildeInPath)
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        shellCwdField.stringValue = url.path
        AppSettings.shared.defaultShellCwd = url.path
    }

    // MARK: Appearance

    private func buildAppearanceSection() -> NSView {
        let desc = NSTextField(wrappingLabelWithString: "A curated set of light and dark instrument-panel palettes, each contrast-verified to WCAG AA.")
        desc.font = .systemFont(ofSize: 11)
        desc.textColor = .secondaryLabelColor
        desc.preferredMaxLayoutWidth = 520

        appearanceContainer.orientation = .vertical
        appearanceContainer.alignment = .leading
        appearanceContainer.spacing = 10
        appearanceContainer.translatesAutoresizingMaskIntoConstraints = false

        let section = NSStackView(views: [desc, appearanceContainer])
        section.orientation = .vertical
        section.alignment = .leading
        section.spacing = 12
        appearanceContainer.widthAnchor.constraint(equalTo: section.widthAnchor).isActive = true
        return section
    }

    private func rebuildAppearanceGrid() {
        for v in appearanceContainer.arrangedSubviews {
            appearanceContainer.removeArrangedSubview(v)
            v.removeFromSuperview()
        }
        let activeID = ThemeManager.shared.theme.id
        for group in [HelmTheme.allThemes.filter { $0.mode == .dark }, HelmTheme.allThemes.filter { $0.mode == .light }] {
            let row = NSStackView(views: group.map { themeCard($0, active: $0.id == activeID) })
            row.orientation = .horizontal
            row.spacing = 12
            row.translatesAutoresizingMaskIntoConstraints = false
            appearanceContainer.addArrangedSubview(row)
        }
    }

    private func themeCard(_ t: HelmTheme, active: Bool) -> NSView {
        let preview = NSView()
        preview.wantsLayer = true
        preview.layer?.backgroundColor = HelmTheme.nsColor(t.chromeBackgroundHex).cgColor
        preview.translatesAutoresizingMaskIntoConstraints = false

        let bar1 = NSView()
        bar1.wantsLayer = true
        bar1.layer?.cornerRadius = 3
        bar1.layer?.backgroundColor = HelmTheme.nsColor(t.chromeInkHex).withAlphaComponent(0.35).cgColor
        bar1.translatesAutoresizingMaskIntoConstraints = false
        let bar2 = NSView()
        bar2.wantsLayer = true
        bar2.layer?.cornerRadius = 3
        bar2.layer?.backgroundColor = HelmTheme.nsColor(t.accentHex).cgColor
        bar2.translatesAutoresizingMaskIntoConstraints = false

        preview.addSubview(bar1)
        preview.addSubview(bar2)
        NSLayoutConstraint.activate([
            bar1.leadingAnchor.constraint(equalTo: preview.leadingAnchor, constant: 9),
            bar1.trailingAnchor.constraint(equalTo: preview.trailingAnchor, constant: -9),
            bar1.topAnchor.constraint(equalTo: preview.topAnchor, constant: 10),
            bar1.heightAnchor.constraint(equalToConstant: 7),
            bar2.leadingAnchor.constraint(equalTo: preview.leadingAnchor, constant: 9),
            bar2.trailingAnchor.constraint(equalTo: preview.trailingAnchor, constant: -34),
            bar2.topAnchor.constraint(equalTo: bar1.bottomAnchor, constant: 6),
            bar2.heightAnchor.constraint(equalToConstant: 7),
            preview.heightAnchor.constraint(equalToConstant: 52),
        ])

        let nameLabel = NSTextField(labelWithString: t.name)
        nameLabel.font = .systemFont(ofSize: 11.5, weight: .semibold)
        nameLabel.translatesAutoresizingMaskIntoConstraints = false

        let check = NSImageView()
        check.image = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: nil)
        check.contentTintColor = HelmTheme.nsColor(t.accentHex)
        check.isHidden = !active
        check.translatesAutoresizingMaskIntoConstraints = false

        let nameRow = NSView()
        nameRow.translatesAutoresizingMaskIntoConstraints = false
        nameRow.addSubview(nameLabel)
        nameRow.addSubview(check)
        NSLayoutConstraint.activate([
            nameLabel.leadingAnchor.constraint(equalTo: nameRow.leadingAnchor, constant: 10),
            nameLabel.centerYAnchor.constraint(equalTo: nameRow.centerYAnchor),
            check.trailingAnchor.constraint(equalTo: nameRow.trailingAnchor, constant: -10),
            check.centerYAnchor.constraint(equalTo: nameRow.centerYAnchor),
            check.widthAnchor.constraint(equalToConstant: 14),
            check.heightAnchor.constraint(equalToConstant: 14),
            nameRow.heightAnchor.constraint(equalToConstant: 30),
        ])

        let stack = NSStackView(views: [preview, nameRow])
        stack.orientation = .vertical
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false

        let card = NSView()
        card.wantsLayer = true
        card.layer?.cornerRadius = 11
        card.layer?.borderWidth = active ? 1.5 : 1
        card.layer?.borderColor = (active ? HelmTheme.nsColor(t.accentHex) : HelmTheme.nsColor(theme.chromeLineHex).withAlphaComponent(0.5)).cgColor
        card.layer?.masksToBounds = true
        card.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            stack.topAnchor.constraint(equalTo: card.topAnchor),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor),
            card.widthAnchor.constraint(equalToConstant: 138),
        ])

        let click = NSClickGestureRecognizer(target: self, action: #selector(themeCardClicked(_:)))
        card.addGestureRecognizer(click)
        card.identifier = NSUserInterfaceItemIdentifier(t.id)
        return card
    }

    @objc private func themeCardClicked(_ sender: NSClickGestureRecognizer) {
        guard let id = sender.view?.identifier?.rawValue, let t = HelmTheme.theme(id: id) else { return }
        ThemeManager.shared.setTheme(t)
        // `refreshFromSettings()` also runs via the `ThemeManager.observe`
        // callback registered in `loadView`, so nothing else is needed here.
    }

    // MARK: Terminal

    private func buildTerminalSection() -> NSView {
        let sizes = [12, 13, 14, 16]
        let buttons = sizes.map { size -> NSButton in
            let b = NSButton(title: "\(size)", target: self, action: #selector(fontPresetClicked(_:)))
            b.bezelStyle = .rounded
            b.tag = size
            fontPresetButtons[size] = b
            return b
        }
        let presetRow = NSStackView(views: buttons)
        presetRow.orientation = .horizontal
        presetRow.spacing = 6
        let fontRow = descRow(title: "Default font size", desc: "Also adjustable live with \u{2318}+ / \u{2318}\u{2212} in the console.", trailing: presetRow)

        autoReconnectSwitch.target = self
        autoReconnectSwitch.action = #selector(autoReconnectToggled)
        let reconnectRow = descRow(title: "Reconnect automatically", desc: "If a tab's connection drops, restore it silently rather than waiting for \u{2318}R.", trailing: autoReconnectSwitch)

        notifySwitch.target = self
        notifySwitch.action = #selector(notifyToggled)
        let notifyRow = descRow(title: "Bell & notifications", desc: "Surface a desktop notification the moment a crewmate needs your decision.", trailing: notifySwitch)

        sessionLoggingSwitch.target = self
        sessionLoggingSwitch.action = #selector(sessionLoggingToggled)
        let loggingRow = descRow(title: "Log sessions by default", desc: "Every newly started tab begins writing a plain-text transcript automatically.", trailing: sessionLoggingSwitch)

        let section = NSStackView(views: [fontRow, separator(), reconnectRow, separator(), notifyRow, separator(), loggingRow])
        section.orientation = .vertical
        section.alignment = .leading
        section.spacing = 14
        for row in [fontRow, reconnectRow, notifyRow, loggingRow] {
            row.widthAnchor.constraint(equalTo: section.widthAnchor).isActive = true
        }
        return section
    }

    @objc private func fontPresetClicked(_ sender: NSButton) {
        let target = CGFloat(sender.tag)
        onFontSizeStep?(target - AppSettings.shared.fontSize)
        refreshFromSettings()
    }

    @objc private func autoReconnectToggled() {
        AppSettings.shared.autoReconnect = autoReconnectSwitch.state == .on
    }

    @objc private func notifyToggled() {
        let on = notifySwitch.state == .on
        AppSettings.shared.notifyOnNeedsDecision = on
        FleetNotifier.shared.setEnabled(on)
    }

    @objc private func sessionLoggingToggled() {
        AppSettings.shared.sessionLoggingDefault = sessionLoggingSwitch.state == .on
    }

    // MARK: Shared field plumbing

    private func configure(_ field: NSTextField, placeholder: String) {
        field.placeholderString = placeholder
        field.translatesAutoresizingMaskIntoConstraints = false
        field.target = self
        field.action = #selector(textFieldChanged(_:))
        field.delegate = self
    }

    @objc private func textFieldChanged(_ sender: NSTextField) {
        let value = sender.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        switch sender {
        case shellCwdField:
            AppSettings.shared.defaultShellCwd = value.isEmpty ? nil : value
        case mirrorTargetField:
            AppSettings.shared.mirrorTarget = value.isEmpty ? nil : value
            refreshSessions()
        default:
            break
        }
    }

    // MARK: Sync

    private func refreshFromSettings() {
        guard isViewLoaded else { return }
        mirrorTargetField.stringValue = AppSettings.shared.mirrorTarget ?? ""
        shellCwdField.stringValue = AppSettings.shared.defaultShellCwd ?? ""
        for size in [12, 13, 14, 16] {
            fontPresetButtons[size]?.state = Int(AppSettings.shared.fontSize) == size ? .on : .off
        }
        autoReconnectSwitch.state = AppSettings.shared.autoReconnect ? .on : .off
        notifySwitch.state = AppSettings.shared.notifyOnNeedsDecision ? .on : .off
        sessionLoggingSwitch.state = AppSettings.shared.sessionLoggingDefault ? .on : .off

        rebuildAppearanceGrid()
        refreshSessions()
        applyTheme()
    }

    private func applyTheme() {
        let surface = HelmTheme.nsColor(theme.chromeBackgroundHex)
        let line = HelmTheme.nsColor(theme.chromeLineHex)
        for v in cardBackgroundViews {
            v.layer?.backgroundColor = surface.withAlphaComponent(0.6).cgColor
            v.layer?.borderWidth = 1
            v.layer?.borderColor = line.withAlphaComponent(0.5).cgColor
        }
        for v in separatorViews {
            v.layer?.backgroundColor = line.withAlphaComponent(0.5).cgColor
        }
    }
}

extension SettingsController: NSTextFieldDelegate {
    func controlTextDidEndEditing(_ obj: Notification) {
        guard let field = obj.object as? NSTextField else { return }
        textFieldChanged(field)
    }
}
