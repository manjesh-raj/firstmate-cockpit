// Manjesh Grand Line - native macOS app.
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
//   - Appearance: the theme picker (12 as of cockpit-theme-overhaul) as a
//     wrapping grid of preview cards (colour-bar swatch + name + checkmark),
//     reusing `HelmTheme.allThemes` - the same source of truth the topbar's
//     `ThemeMenu` picker uses.
//   - Terminal: font-size presets (12/13/14/16, routed through
//     `ConsoleController.stepFontSize` via `onFontSizeStep` as before), plus
//     two toggles with real behaviour behind them: "Reconnect automatically"
//     (`AppSettings.autoReconnect`, read by `ConsoleController.
//     processTerminated`) and "Bell & notifications" (`AppSettings.
//     notifyOnNeedsDecision`, driving `FleetNotifier`).
//
// Like before, fields persist immediately on change rather than batching
// into a Save button.

import AppKit

final class SettingsController: NSViewController {

    /// The four stores the "Backup & Restore" card exports from / imports
    /// into (`BackupUI.swift`) - injected so this controller doesn't need any
    /// persistence logic of its own, matching how `onPresentHostEditor`
    /// keeps `AppShellController` ignorant of `HostStore`.
    private let hostStore: HostStore
    private let keyStore: SSHKeyStore
    private let snippetStore: SnippetStore
    private let dictationStore: DictationStore

    init(hostStore: HostStore, keyStore: SSHKeyStore, snippetStore: SnippetStore, dictationStore: DictationStore) {
        self.hostStore = hostStore
        self.keyStore = keyStore
        self.snippetStore = snippetStore
        self.dictationStore = dictationStore
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// The Terminal section's font-size presets. Wired by the app delegate to
    /// `ConsoleController.stepFontSize`, since this panel never holds a
    /// direct reference to the console.
    var onFontSizeStep: ((CGFloat) -> Void)?

    /// The Security card's "Enable" action, requiring a `sudo` prompt - wired
    /// by the app delegate to the same `AppShellController.runInConsole`
    /// Bootstrap's own provisioning actions use (cockpit-settings-sudo-
    /// touchid), never a silent background process.
    var onRunCommand: ((String, String) -> Void)?

    /// Same wiring as `onRunCommand`, but with a completion callback so the
    /// row can re-check status once the Console tab's `av harden sudo`
    /// actually exits, rather than on a fixed timer.
    var onRunCommandTracked: ((String, String, @escaping (Bool) -> Void) -> Void)?

    private var theme: HelmTheme = ThemeManager.shared.theme

    private var sudoTouchIDStatus: SudoTouchIDStatus = .checking
    private var isHardeningSudo = false

    // Header (Fix 1, cockpit-native-settings-compact): the topbar already
    // shows "Settings" as the destination title, so this only carries the
    // descriptive subtitle - mirrors the web app's page-head `.greet` line
    // without duplicating the title text.
    private let subtitleLabel = NSTextField(labelWithString: "Connection, appearance, and terminal - stored locally on this machine.")

    // Connection
    private let mirrorTargetField = NSTextField()
    private let sessionsStatusLabel = NSTextField(wrappingLabelWithString: "")
    private let sessionsStack = NSStackView()
    private let shellCwdField = NSTextField()

    // Appearance
    private let appearanceContainer = NSStackView()

    // Terminal
    private var fontPresetButtons: [Int: HelmButton] = [:]
    private let autoReconnectSwitch = NSSwitch()
    private let notifySwitch = NSSwitch()

    /// Every `HelmCard` on this page, re-themed together. The card owns its own
    /// header icon tile and subtitle label, so neither needs a registry here.
    private var cards: [HelmCard] = []

    /// Row containers using the shared `HoverHighlightView` hover helper -
    /// re-colored on every theme change alongside `cards`.
    private var hoverRows: [HoverHighlightView] = []

    /// Fix 4: kept so `viewWillAppear` can force the scroll position back to
    /// the top on every visit - see `FlippedView` below for why a fresh
    /// layout can otherwise land scrolled to the bottom.
    private var scrollView: NSScrollView!

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

        let header = buildHeader()
        let connection = card(icon: "network", tint: .info, title: "Connection", subtitle: "Mirror target and working directory", content: buildConnectionSection())
        let appearance = card(icon: "paintpalette", tint: .violet, title: "Appearance", subtitle: "\(HelmTheme.allThemes.count) Helm themes, light and dark", content: buildAppearanceSection())
        let terminal = card(icon: "terminal", tint: .warn, title: "Terminal", subtitle: "Font size and behavior", content: buildTerminalSection())
        let security = card(icon: "lock.shield", tint: .violet, title: "Security", subtitle: "System-level convenience toggles", content: buildSecuritySection())
        let backup = card(icon: "tray.and.arrow.up.fill", tint: .info, title: "Backup & Restore", subtitle: "Move saved hosts, snippets, and preferences between machines", content: buildBackupSection())

        let stack = NSStackView(views: [header, connection, appearance, terminal, security, backup])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.setCustomSpacing(16, after: header)

        let content = FlippedView()
        content.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: HelmMetrics.pageGutter),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -HelmMetrics.pageGutter),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 18),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
            header.widthAnchor.constraint(equalTo: stack.widthAnchor),
            connection.widthAnchor.constraint(equalTo: stack.widthAnchor),
            appearance.widthAnchor.constraint(equalTo: stack.widthAnchor),
            terminal.widthAnchor.constraint(equalTo: stack.widthAnchor),
            security.widthAnchor.constraint(equalTo: stack.widthAnchor),
            backup.widthAnchor.constraint(equalTo: stack.widthAnchor),
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
            // AGENTS.md gotcha #4: pin the document view to the *clip*
            // view, never the outer scroll view. With "Show scroll bars:
            // Always" (the default with a mouse attached) a non-overlay
            // vertical scroller reserves a real ~15pt track that narrows the
            // clip view without narrowing `scroll`'s own frame, so pinning to
            // `scroll.widthAnchor` renders the content's trailing edge
            // underneath that track.
            content.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
        ])
        scrollView = scroll

        // The theme grid's column count now comes from `appearanceContainer`'s
        // real width (Phase 7, see `rebuildAppearanceGrid`), so it has to be
        // recomputed when that width changes. Same hook and same reasoning as
        // `ToolsController.containerWidthMayHaveChanged`: a live window resize
        // does not reliably re-invoke this child view controller's own
        // `viewDidLayout()` (only the window's own content view controller is
        // guaranteed that), so listen for the window's resize notification.
        NotificationCenter.default.addObserver(self,
                                              selector: #selector(containerWidthMayHaveChanged),
                                              name: NSWindow.didResizeNotification,
                                              object: nil)

        refreshFromSettings()
    }

    /// The container width the theme grid was last laid out against, so a
    /// resize that does not actually change it costs nothing.
    private var lastAppearanceGridWidth: CGFloat = 0

    @objc private func containerWidthMayHaveChanged() {
        // Only while this destination is the visible one - every destination is
        // a permanently mounted, `isHidden`-toggled child of
        // `AppShellController`, so an un-gated handler here would rebuild this
        // grid on every resize no matter which page the captain is looking at
        // (the measured regression `fm/cockpit-tools-yaml-quotes-diff-perf`
        // fixed on the Tools page).
        guard !view.isHidden else { return }
        view.window?.contentView?.layoutSubtreeIfNeeded()
        let width = appearanceContainer.frame.width
        guard width > 0, abs(width - lastAppearanceGridWidth) > 0.5 else { return }
        lastAppearanceGridWidth = width
        rebuildAppearanceGrid()
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        refreshFromSettings()
        if !hasCheckedSudoTouchIDOnce {
            hasCheckedSudoTouchIDOnce = true
            checkSudoTouchID()
        }
        scrollToTop()
    }

    /// Guards the initial background PAM-file check to once per app launch
    /// (re-checked explicitly after the Enable action completes) rather than
    /// on every visit to Settings - same convention as Bootstrap's
    /// `hasCheckedGhHardeningOnce`.
    private var hasCheckedSudoTouchIDOnce = false

    /// Fix 4: the document view (`content`, a `FlippedView`) puts y=0 at its
    /// top, but a freshly laid-out `NSScrollView` can still leave the clip
    /// view's bounds wherever the last layout pass settled - so force it
    /// back explicitly on every appearance rather than trusting the default.
    private func scrollToTop() {
        guard let scroll = scrollView else { return }
        scroll.contentView.scroll(to: .zero)
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    // MARK: Header

    private func buildHeader() -> NSView {
        subtitleLabel.font = .systemFont(ofSize: 12)
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        return subtitleLabel
    }

    // MARK: Card chrome

    /// A section's card shell: an icon tile + title/subtitle header, then its
    /// content, generously padded and given a rounded, bordered background -
    /// matching the mockup's `.card`/`.card-head` structure (icon-in-tile
    /// rather than a plain glyph, a muted subtitle under the title).
    /// One `HelmCard` per settings section - the shared container from
    /// `HelmDesignSystem.swift`. The icon-tile + title + subtitle header this
    /// file used to build by hand is now that component's own structured
    /// header, so the tile and the subtitle re-theme themselves and this file
    /// no longer keeps registries for either (audit §6.3 component 1).
    private func card(icon: String, tint: HelmTint, title: String, subtitle: String, content: NSView) -> HelmCard {
        let card = HelmCard()
        card.setHeader(symbol: icon, tint: tint, title: title, subtitle: subtitle)
        card.setBody(content, insets: HelmCard.contentInsets)
        cards.append(card)
        return card
    }

    /// Muted supporting text inside a card's body, re-colored alongside
    /// `cards` on every theme change. A card *header*'s own subtitle is the
    /// `HelmCard`'s business, not this list's.
    private var subtitleViews: [NSTextField] = []

    /// Registers `label` in the shared `subtitleViews` re-theming list **and**
    /// tints it for the current theme right away.
    ///
    /// Both halves matter. Registering alone is not enough: sections that
    /// rebuild rather than re-theme (`rebuildSecuritySection`,
    /// `refreshSessions`) create fresh labels without necessarily re-running
    /// `applyTheme()`, so a label that was only registered would render in
    /// the default `.labelColor` until the next theme change. Tinting alone
    /// is not enough either, since it would then go stale on that change.
    ///
    /// This replaced `.secondaryLabelColor` at every muted-text site in this
    /// file - a fixed system grey knows nothing about which of the 12 Helm
    /// palettes is active, so it is both off-palette and (for the tertiary
    /// variant) below the 4.5:1 contrast floor in every one of them
    /// (audit §5.3).
    @discardableResult
    private func mutedLabel(_ label: NSTextField) -> NSTextField {
        subtitleViews.append(label)
        label.textColor = HelmTheme.mutedInk(theme)
        return label
    }

    private func rowLabel(_ text: String) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.font = .systemFont(ofSize: 12)
        mutedLabel(l)
        return l
    }

    private func descRow(title: String, desc: String, trailing: NSView) -> NSView {
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 12.5, weight: .medium)
        let descLabel = NSTextField(wrappingLabelWithString: desc)
        descLabel.font = .systemFont(ofSize: 11)
        mutedLabel(descLabel)
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
        row.spacing = 12
        row.translatesAutoresizingMaskIntoConstraints = false

        // Shared hover helper (task brief #2): a subtle highlight on mouse
        // enter/exit, both colors theme-derived - see `applyTheme` for the
        // actual color assignment.
        let container = HoverHighlightView()
        container.cornerRadius = 8
        container.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            row.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
            row.topAnchor.constraint(equalTo: container.topAnchor, constant: 6),
            row.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -6),
        ])
        hoverRows.append(container)
        return container
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
        mutedLabel(desc)
        desc.preferredMaxLayoutWidth = 520

        configure(mirrorTargetField, placeholder: "firstmate")
        let detectButton = HelmButton(title: "Detect", variant: .secondary, symbol: "arrow.triangle.2.circlepath", target: self, action: #selector(detectClicked))

        let fieldRow = NSStackView(views: [mirrorTargetField, detectButton])
        fieldRow.orientation = .horizontal
        fieldRow.spacing = 8
        mirrorTargetField.setContentHuggingPriority(.defaultLow, for: .horizontal)

        sessionsStatusLabel.font = .systemFont(ofSize: 11)
        mutedLabel(sessionsStatusLabel)

        sessionsStack.orientation = .vertical
        sessionsStack.alignment = .leading
        sessionsStack.spacing = 4
        sessionsStack.translatesAutoresizingMaskIntoConstraints = false

        let mirrorGroup = NSStackView(views: [label, desc, fieldRow, sessionsStatusLabel, sessionsStack])
        mirrorGroup.orientation = .vertical
        mirrorGroup.alignment = .leading
        mirrorGroup.spacing = 6
        fieldRow.widthAnchor.constraint(equalTo: mirrorGroup.widthAnchor).isActive = true
        sessionsStack.widthAnchor.constraint(equalTo: mirrorGroup.widthAnchor).isActive = true

        let chooseCwd = HelmButton(title: "Choose\u{2026}", variant: .secondary, target: self, action: #selector(chooseShellCwd))
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
        section.spacing = 12
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
        targetLabel.font = .monospacedSystemFont(ofSize: 11.5, weight: .semibold)

        var titleViews: [NSView] = [targetLabel]
        if s.isHome { titleViews.append(pillView(text: "home", colorHex: theme.accentHex)) }
        let titleRow = NSStackView(views: titleViews)
        titleRow.orientation = .horizontal
        titleRow.spacing = 6
        titleRow.alignment = .firstBaseline

        var subBits = [s.command]
        if !s.path.isEmpty { subBits.append(s.path) }
        let subLabel = NSTextField(labelWithString: subBits.joined(separator: " \u{00B7} "))
        subLabel.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        mutedLabel(subLabel)
        subLabel.lineBreakMode = .byTruncatingMiddle

        let textStack = NSStackView(views: [titleRow, subLabel])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 1
        textStack.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let check = NSImageView()
        check.image = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 11, weight: .regular))
        check.contentTintColor = HelmTheme.nsColor(theme.accentHex)
        check.isHidden = !isSelected
        check.translatesAutoresizingMaskIntoConstraints = false
        check.setContentHuggingPriority(.required, for: .horizontal)

        let row = NSStackView(views: [textStack, check])
        row.orientation = .horizontal
        row.spacing = 8
        row.alignment = .centerY
        row.translatesAutoresizingMaskIntoConstraints = false

        let card = HoverHighlightView()
        card.cornerRadius = 8
        card.layer?.borderWidth = isSelected ? 1.5 : 1
        card.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 10),
            row.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -10),
            row.topAnchor.constraint(equalTo: card.topAnchor, constant: 6),
            row.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -6),
        ])
        let base = HelmTheme.nsColor(theme.chromeBackgroundHex)
        card.normalColor = base
        card.hoverColor = base.hoverShifted(by: 0.08, forMode: theme.mode)
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
        mutedLabel(desc)
        desc.preferredMaxLayoutWidth = 520

        appearanceContainer.orientation = .vertical
        appearanceContainer.alignment = .leading
        appearanceContainer.spacing = 8
        appearanceContainer.translatesAutoresizingMaskIntoConstraints = false

        let section = NSStackView(views: [desc, appearanceContainer])
        section.orientation = .vertical
        section.alignment = .leading
        section.spacing = 10
        appearanceContainer.widthAnchor.constraint(equalTo: section.widthAnchor).isActive = true
        return section
    }

    /// The width one theme card will not go below - the only parameter this
    /// page owns in the shared grid math.
    ///
    /// 150, not the 108 this card used to be *fixed* at, and the reason is
    /// measured rather than picked: at 108 the longest theme names
    /// ("Catppuccin Mocha", "Tokyo Night Light") do not fit beside the active
    /// checkmark, and a real render showed one card in the row resolving to
    /// 130pt while its siblings sat at 107 - its own label's compression
    /// resistance winning over `.fillEqually`. 150 is what the widest name
    /// plus the checkmark and the card's insets actually need.
    private static let themeCardMinWidth: CGFloat = 150

    private func rebuildAppearanceGrid() {
        for v in appearanceContainer.arrangedSubviews {
            appearanceContainer.removeArrangedSubview(v)
            v.removeFromSuperview()
        }
        let activeID = ThemeManager.shared.theme.id
        lastAppearanceGridWidth = appearanceContainer.frame.width
        // Phase 7 (audit §4.8 / §6.4's Settings row): this used to chunk into
        // a **fixed** `columnsPerRow = 4` of **fixed** 108pt cards, which is
        // what left the audit's ragged 4/2/4/2 last row and never responded to
        // window width at all. It now runs on `HelmResponsiveGrid` - Tools'
        // own column-count-from-real-width plus partial-row spacer padding,
        // shared rather than re-derived - so the theme grid re-flows on a
        // window resize and its last row's cards stay the same width as every
        // other row's.
        //
        // Still two groups (dark, then light), because that split is a real
        // distinction a captain scans by, not an artefact of the old chunking.
        for group in [HelmTheme.allThemes.filter { $0.mode == .dark }, HelmTheme.allThemes.filter { $0.mode == .light }] {
            let rows = HelmResponsiveGrid.rows(group,
                                               containerWidth: appearanceContainer.frame.width,
                                               minItemWidth: Self.themeCardMinWidth,
                                               spacing: HelmMetrics.s2) { t, _ in
                // This card takes no width: unlike a Tools landing card (whose
                // wrapping description needs a `preferredMaxLayoutWidth` up
                // front) it has only fixed-size content, so the row's
                // `.fillEqually` distribution is the only thing that needs to
                // know how wide it is.
                self.themeCard(t, active: t.id == activeID)
            }
            for row in rows {
                appearanceContainer.addArrangedSubview(row)
                row.widthAnchor.constraint(equalTo: appearanceContainer.widthAnchor).isActive = true
            }
        }
    }

    private func themeCard(_ t: HelmTheme, active: Bool) -> NSView {
        // A 3-color swatch (bg / surface / accent), matching the mockup's
        // `.theme-swatch` structure - all three pulled from this theme's real
        // values, never the mockup's placeholder hexes.
        let preview = NSStackView()
        preview.orientation = .horizontal
        preview.spacing = 0
        preview.distribution = .fillEqually
        preview.wantsLayer = true
        preview.layer?.cornerRadius = 6
        preview.layer?.masksToBounds = true
        preview.translatesAutoresizingMaskIntoConstraints = false
        for hex in [t.backgroundHex, t.chromeBackgroundHex, t.accentHex] {
            let swatch = NSView()
            swatch.wantsLayer = true
            swatch.layer?.backgroundColor = HelmTheme.nsColor(hex).cgColor
            preview.addArrangedSubview(swatch)
        }
        preview.heightAnchor.constraint(equalToConstant: 34).isActive = true

        let nameLabel = NSTextField(labelWithString: t.name)
        nameLabel.font = .systemFont(ofSize: 10.5, weight: .semibold)
        nameLabel.lineBreakMode = .byTruncatingTail
        // Otherwise the longest name's own compression resistance beats the
        // row's `.fillEqually` distribution and that one card comes out wider
        // than its siblings (measured: 130 against 107). A truncated name is
        // the right trade - the swatch identifies the theme too.
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        nameLabel.translatesAutoresizingMaskIntoConstraints = false

        let check = NSImageView()
        check.image = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 11, weight: .regular))
        check.contentTintColor = HelmTheme.nsColor(t.accentHex)
        check.isHidden = !active
        check.translatesAutoresizingMaskIntoConstraints = false

        let nameRow = NSView()
        nameRow.translatesAutoresizingMaskIntoConstraints = false
        nameRow.addSubview(nameLabel)
        nameRow.addSubview(check)
        NSLayoutConstraint.activate([
            nameLabel.leadingAnchor.constraint(equalTo: nameRow.leadingAnchor, constant: 8),
            nameLabel.centerYAnchor.constraint(equalTo: nameRow.centerYAnchor),
            nameLabel.trailingAnchor.constraint(lessThanOrEqualTo: check.leadingAnchor, constant: -4),
            check.trailingAnchor.constraint(equalTo: nameRow.trailingAnchor, constant: -8),
            check.centerYAnchor.constraint(equalTo: nameRow.centerYAnchor),
            check.widthAnchor.constraint(equalToConstant: 12),
            check.heightAnchor.constraint(equalToConstant: 12),
            nameRow.heightAnchor.constraint(equalToConstant: 24),
        ])

        let stack = NSStackView(views: [preview, nameRow])
        stack.orientation = .vertical
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false

        let card = HoverHighlightView()
        card.cornerRadius = 10
        card.layer?.borderWidth = active ? 1.5 : 1
        card.layer?.borderColor = (active ? HelmTheme.nsColor(t.accentHex) : HelmTheme.nsColor(theme.chromeLineHex).withAlphaComponent(0.5)).cgColor
        card.layer?.masksToBounds = true
        let base = HelmTheme.nsColor(theme.chromeBackgroundHex)
        card.normalColor = active ? HelmTheme.nsColor(t.accentHex).withAlphaComponent(0.08) : .clear
        card.hoverColor = base.hoverShifted(by: 0.06, forMode: theme.mode)
        card.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            stack.topAnchor.constraint(equalTo: card.topAnchor),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor),
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
        let buttons = sizes.map { size -> HelmButton in
            let b = HelmButton(title: "\(size)", variant: .secondary, target: self, action: #selector(fontPresetClicked(_:)))
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

        let section = NSStackView(views: [fontRow, separator(), reconnectRow, separator(), notifyRow])
        section.orientation = .vertical
        section.alignment = .leading
        section.spacing = 12
        for row in [fontRow, reconnectRow, notifyRow] {
            row.widthAnchor.constraint(equalTo: section.widthAnchor).isActive = true
        }
        return section
    }

    // MARK: Security

    private let securityStack = NSStackView()

    private func buildSecuritySection() -> NSView {
        securityStack.orientation = .vertical
        securityStack.alignment = .leading
        securityStack.spacing = 12
        securityStack.translatesAutoresizingMaskIntoConstraints = false
        rebuildSecuritySection()
        return securityStack
    }

    /// Rebuilt (not just re-themed) on every status change, since the
    /// trailing control differs by status (a pill, a button, or plain text) -
    /// same convention as Bootstrap's `ghAuthRow`. `descRow` registers a
    /// fresh `HoverHighlightView` into the shared `hoverRows` re-theming list
    /// on every call, so the just-removed row's now-orphaned entry is pruned
    /// first rather than left to accumulate.
    private func rebuildSecuritySection() {
        for v in securityStack.arrangedSubviews {
            securityStack.removeArrangedSubview(v)
            v.removeFromSuperview()
        }
        hoverRows.removeAll { $0.superview == nil }
        let row = sudoTouchIDRow()
        securityStack.addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: securityStack.widthAnchor).isActive = true
        applyTheme()
    }

    private func sudoTouchIDRow() -> NSView {
        var desc = "Use your fingerprint instead of typing your password at a terminal prompt."
        let statusView: NSView
        switch sudoTouchIDStatus {
        case .checking:
            statusView = rowLabel("Checking\u{2026}")
        case .enabled:
            statusView = pillView(text: "Enabled", colorHex: theme.ansiHex[2])
        case .notEnabled:
            let button = HelmButton(title: isHardeningSudo ? "Enabling\u{2026}" : "Enable", variant: .primary, target: self, action: #selector(enableSudoTouchIDClicked))
            button.isEnabled = !isHardeningSudo
            statusView = button
        case .notEnabledNixDarwin:
            desc += " This Mac is managed by nix-darwin, where /etc/pam.d/sudo_local is regenerated from your flake on every rebuild - add `security.pam.services.sudo_local.touchIdAuth = true;` to your dotfiles' configuration.nix, then run rebuild.sh."
            statusView = rowLabel("Needs dotfiles change")
        case .pamNotConfigured:
            desc += " Not available on this Mac - /etc/pam.d/sudo doesn't include sudo_local."
            statusView = rowLabel("Unavailable")
        case .checkFailed(let reason):
            desc += " Could not check status: \(reason)."
            statusView = rowLabel("Unknown")
        }

        // A manual recheck affordance for this one row: the automatic check
        // only ever runs once per app launch (`hasCheckedSudoTouchIDOnce`,
        // see `viewWillAppear`), so a fix made outside the app (editing
        // dotfiles, running `rebuild.sh` in another terminal) leaves this
        // row showing stale status until the captain restarts the whole app.
        // Hidden while a check is already in flight, since re-triggering one
        // mid-check would just race itself.
        let trailing: NSView
        if sudoTouchIDStatus == .checking {
            trailing = statusView
        } else {
            let refreshButton = HelmButton(symbol: "arrow.clockwise", variant: .quiet,
                                           target: self, action: #selector(recheckSudoTouchIDClicked))
            refreshButton.toolTip = "Recheck Touch ID for sudo status"

            let combined = NSStackView(views: [statusView, refreshButton])
            combined.orientation = .horizontal
            combined.alignment = .centerY
            combined.spacing = 6
            trailing = combined
        }
        return descRow(title: "Touch ID for sudo", desc: desc, trailing: trailing)
    }

    @objc private func recheckSudoTouchIDClicked() {
        checkSudoTouchID()
    }

    private func checkSudoTouchID() {
        sudoTouchIDStatus = .checking
        rebuildSecuritySection()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let status = SudoTouchIDSource.checkStatus()
            DispatchQueue.main.async {
                guard let self else { return }
                self.sudoTouchIDStatus = status
                self.rebuildSecuritySection()
            }
        }
    }

    @objc private func enableSudoTouchIDClicked() {
        guard !isHardeningSudo, let onRunCommandTracked else {
            onRunCommand?("av harden sudo", "sudo av harden sudo")
            return
        }
        isHardeningSudo = true
        rebuildSecuritySection()
        onRunCommandTracked("av harden sudo", "sudo av harden sudo") { [weak self] _ in
            guard let self else { return }
            self.isHardeningSudo = false
            self.checkSudoTouchID()
        }
    }

    // MARK: Backup & Restore

    private let backupStatusLabel = NSTextField(wrappingLabelWithString: "")

    /// Export/Import share one implementation (`BackupUI.swift`) with the
    /// Bootstrap page's "Restore Grand Line config" step - this card is just
    /// the two buttons plus a live counts line, never its own logic.
    private func buildBackupSection() -> NSView {
        let desc = NSTextField(wrappingLabelWithString: "Write everything this app knows locally - saved hosts, snippets, and the preferences above - to a single file, or bring one in from another machine. SSH private keys never leave the Keychain; a restored host referencing a key not on this machine needs that key re-added from the Keys screen.")
        desc.font = .systemFont(ofSize: 11)
        mutedLabel(desc)
        desc.preferredMaxLayoutWidth = 520

        backupStatusLabel.font = .systemFont(ofSize: 11)
        mutedLabel(backupStatusLabel)

        let exportButton = HelmButton(title: "Export\u{2026}", variant: .secondary, target: self, action: #selector(exportBackupClicked))
        let importButton = HelmButton(title: "Import\u{2026}", variant: .secondary, target: self, action: #selector(importBackupClicked))

        let buttonRow = NSStackView(views: [exportButton, importButton])
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 8

        let section = NSStackView(views: [desc, backupStatusLabel, buttonRow])
        section.orientation = .vertical
        section.alignment = .leading
        section.spacing = 8
        return section
    }

    private func refreshBackupStatus() {
        let hostCount = hostStore.hosts.count
        let snippetCount = snippetStore.snippets.count
        backupStatusLabel.stringValue = "Currently saved: \(hostCount) host\(hostCount == 1 ? "" : "s"), \(snippetCount) snippet\(snippetCount == 1 ? "" : "s")."
    }

    @objc private func exportBackupClicked() {
        BackupUI.exportFlow(from: self, hostStore: hostStore, keyStore: keyStore, snippetStore: snippetStore, dictationStore: dictationStore)
    }

    @objc private func importBackupClicked() {
        BackupUI.importFlow(from: self, hostStore: hostStore, keyStore: keyStore, snippetStore: snippetStore, dictationStore: dictationStore) { [weak self] in
            self?.refreshFromSettings()
        }
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
            // `NSButton.state`'s on-look was the stock bezel's; the selected
            // preset now reads as the accent-filled `.primary` variant, which
            // is both on-palette and a stronger signal than the bezel ever was.
            fontPresetButtons[size]?.variant = Int(AppSettings.shared.fontSize) == size ? .primary : .secondary
        }
        autoReconnectSwitch.state = AppSettings.shared.autoReconnect ? .on : .off
        notifySwitch.state = AppSettings.shared.notifyOnNeedsDecision ? .on : .off

        rebuildAppearanceGrid()
        refreshSessions()
        refreshBackupStatus()
        applyTheme()
    }

    private func applyTheme() {
        let line = HelmTheme.nsColor(theme.chromeLineHex)
        let muted = HelmTheme.mutedInk(theme)
        subtitleLabel.textColor = muted
        for card in cards { card.applyTheme(theme) }
        // Sections that rebuild rather than re-theme register a fresh label
        // every time, so drop the ones whose view is gone - same convention
        // `rebuildSecuritySection` already applies to `hoverRows`. Safe to do
        // here rather than at each rebuild site because `mutedLabel` tints a
        // label at creation too, so anything dropped early is still correct.
        subtitleViews.removeAll { $0.superview == nil }
        for label in subtitleViews {
            label.textColor = muted
        }
        for row in hoverRows {
            row.normalColor = .clear
            row.hoverColor = line.withAlphaComponent(0.18)
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

/// Fix 4: a plain `NSView` used as a scroll view's document view puts y=0 at
/// the *bottom* (AppKit's default, unflipped coordinate space), so a fresh
/// layout can present as scrolled to the end. Flipping the document view is
/// the standard fix - y=0 becomes the top, matching how the content's own
/// Auto Layout constraints are written (top-down, via `stack.topAnchor`).
/// Not file-private: `HostEditorController`'s scroll view (cockpit-native-
/// host-pages Fix 2) hits the exact same issue and shares this type rather
/// than a second copy.
final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

extension Array {
    /// Split into fixed-size groups, last group possibly shorter. Used by
    /// the Appearance grid to wrap theme cards into bounded-width rows.
    func chunked(into size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min($0 + size, count)]) }
    }
}
