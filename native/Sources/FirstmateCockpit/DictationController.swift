// Manjesh Grand Line - native macOS app.
//
// The "Dictation" rail destination (fm/grandline-dictation-mvp, phase 1): a
// deliberately minimal page for this phase - real permission status, the
// fixed phase-1 shortcut, and nothing else. No history list, no personal-
// vocabulary editor, no shortcut recorder, no "polish"/cleanup toggle - all
// explicitly phase 2/3, out of scope here (see `CLAUDE.md`'s "Dictation"
// section). Follows the same "hide, don't rebuild" body-child convention
// every other destination uses (`AppShellController`), and the same
// Settings-styled card layout `VaultController`/`ShiftPanelView` already
// established rather than inventing new visual language.
//
// Status is read fresh from `DictationPermissions` on every `viewWillAppear`
// (matching `VaultController`/`ReviewController`'s own "refresh on appear,
// no polling" convention - PRODUCT.md's "quiet until it matters") and again
// live whenever the shared `DictationEngine` reports a state change while
// this page happens to be visible, so a captain watching this page while
// dictating sees "Recording…"/"Transcribing…" for real, not a static label.

import AppKit

final class DictationController: NSViewController {

    private let scroll = NSScrollView()
    private let contentStack = NSStackView()

    private let subtitleLabel = NSTextField(labelWithString: "")
    private let refreshButton = NSButton()

    private let statusPanel = ShiftPanelView()
    private let statusIconTile = IconTileView(size: 40, cornerRadius: 10)
    private let statusTitleLabel = NSTextField(labelWithString: "")
    private let statusDetailLabel = NSTextField(wrappingLabelWithString: "")
    private let statusActionButton = NSButton()

    private let shortcutPanel = ShiftPanelView()
    private let shortcutKeyLabel = NSTextField(labelWithString: "Right ⌥ Option")
    private let shortcutDetailLabel = NSTextField(wrappingLabelWithString: "")

    private let footnoteLabel = NSTextField(wrappingLabelWithString: "")

    private var status: DictationStatus = DictationPermissions.currentStatus()
    private var theme: HelmTheme = ThemeManager.shared.theme
    private var hasLoadedOnce = false

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 720, height: 560))
        root.wantsLayer = true
        view = root

        // FlippedView - see VaultController/ReviewController's identical
        // comment for why a plain NSView here would leave a blank gap above
        // the header until the first real render lands.
        let content = FlippedView()
        content.translatesAutoresizingMaskIntoConstraints = false

        let header = buildHeader()
        _ = buildStatusSection()
        _ = buildShortcutSection()
        buildFootnote()

        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = 20
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        contentStack.addArrangedSubview(header)
        contentStack.addArrangedSubview(statusPanel)
        contentStack.addArrangedSubview(shortcutPanel)
        contentStack.addArrangedSubview(footnoteLabel)

        content.addSubview(contentStack)
        NSLayoutConstraint.activate([
            contentStack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 28),
            contentStack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -28),
            contentStack.topAnchor.constraint(equalTo: content.topAnchor, constant: 24),
            contentStack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -28),
            statusPanel.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
            shortcutPanel.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
            footnoteLabel.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
        ])

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
            content.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
        ])

        ThemeManager.shared.observe { [weak self, weak root] theme in
            self?.theme = theme
            root?.appearance = NSAppearance(named: theme.mode == .dark ? .darkAqua : .aqua)
            self?.applyTheme()
        }
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        hasLoadedOnce = true
        view.layoutSubtreeIfNeeded()
        scroll.contentView.scroll(to: .zero)
        scroll.reflectScrolledClipView(scroll.contentView)
        refresh()
    }

    /// Re-reads real permission state and re-renders. Called on every page
    /// visit, after the captain returns from a system permission dialog
    /// (there is no completion callback for "the user closed System
    /// Settings," so re-checking on next appear is the same honest approach
    /// `SudoTouchIDController`/`VaultController` already use for their own
    /// OS-level checks), and after `setEngineStatus` reports a change.
    func refresh() {
        setStatus(DictationPermissions.currentStatus())
    }

    /// Called by the app delegate whenever the shared `DictationEngine`
    /// reports a status change (e.g. recording started/stopped) - keeps this
    /// page truthful in real time while it's visible. A no-op while the page
    /// isn't loaded yet.
    func setEngineStatus(_ status: DictationStatus) {
        guard isViewLoaded else { return }
        setStatus(status)
    }

    private func setStatus(_ status: DictationStatus) {
        self.status = status
        render()
    }

    // MARK: Building the static chrome

    private func buildHeader() -> NSView {
        subtitleLabel.font = .systemFont(ofSize: 12)
        subtitleLabel.stringValue = "A first-party, in-process dictation pipeline - no third-party app required."
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false

        refreshButton.title = ""
        refreshButton.isBordered = false
        refreshButton.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "Refresh")
        refreshButton.target = self
        refreshButton.action = #selector(refreshTapped)
        refreshButton.toolTip = "Re-check Dictation permissions"
        refreshButton.translatesAutoresizingMaskIntoConstraints = false

        // No in-page "Dictation" title - the top bar already shows the
        // destination name, matching Tools/Vault/Updates/Bootstrap/Settings/
        // Overview, which likewise show only a subtitle here rather than
        // repeating the destination name.
        let row = NSStackView(views: [subtitleLabel, refreshButton])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 12
        row.translatesAutoresizingMaskIntoConstraints = false
        return row
    }

    private func buildStatusSection() -> NSView {
        let sectionLabel = NSTextField(labelWithString: "Status")
        sectionLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        sectionLabel.translatesAutoresizingMaskIntoConstraints = false
        statusPanel.setHeader(sectionLabel)

        statusTitleLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        statusTitleLabel.translatesAutoresizingMaskIntoConstraints = false

        statusDetailLabel.font = .systemFont(ofSize: 11.5)
        statusDetailLabel.preferredMaxLayoutWidth = 520
        statusDetailLabel.translatesAutoresizingMaskIntoConstraints = false

        let textStack = NSStackView(views: [statusTitleLabel, statusDetailLabel])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 3
        textStack.setContentHuggingPriority(.defaultLow, for: .horizontal)
        textStack.translatesAutoresizingMaskIntoConstraints = false

        statusActionButton.bezelStyle = .rounded
        statusActionButton.controlSize = .regular
        statusActionButton.target = self
        statusActionButton.action = #selector(statusActionTapped)
        statusActionButton.setContentHuggingPriority(.required, for: .horizontal)
        statusActionButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        statusActionButton.translatesAutoresizingMaskIntoConstraints = false

        let row = NSStackView(views: [statusIconTile, textStack, statusActionButton])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 14
        row.translatesAutoresizingMaskIntoConstraints = false

        statusPanel.setBody(paddedBody(row))
        return statusPanel
    }

    private func buildShortcutSection() -> NSView {
        let sectionLabel = NSTextField(labelWithString: "Shortcut")
        sectionLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        sectionLabel.translatesAutoresizingMaskIntoConstraints = false
        shortcutPanel.setHeader(sectionLabel)

        let keyTile = IconTileView(size: 40, cornerRadius: 10)
        keyTile.configure(symbol: "waveform", tint: .accent)

        shortcutKeyLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        shortcutKeyLabel.translatesAutoresizingMaskIntoConstraints = false

        shortcutDetailLabel.font = .systemFont(ofSize: 11.5)
        shortcutDetailLabel.stringValue = "Hold to start recording anywhere on the Mac. Release to stop and paste the transcribed text at your cursor. This shortcut isn't configurable yet - a shortcut recorder is planned for a later phase."
        shortcutDetailLabel.preferredMaxLayoutWidth = 520
        shortcutDetailLabel.translatesAutoresizingMaskIntoConstraints = false

        let textStack = NSStackView(views: [shortcutKeyLabel, shortcutDetailLabel])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 3
        textStack.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let row = NSStackView(views: [keyTile, textStack])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 14
        row.translatesAutoresizingMaskIntoConstraints = false

        shortcutPanel.setBody(paddedBody(row))
        return shortcutPanel
    }

    /// `ShiftPanelView.setBody` (unlike `setHeader`) has no `insets` param -
    /// wraps `content` in a plain padded container so both card bodies get
    /// the same breathing room as the header row.
    private func paddedBody(_ content: NSView) -> NSView {
        let wrapper = NSView()
        wrapper.translatesAutoresizingMaskIntoConstraints = false
        content.translatesAutoresizingMaskIntoConstraints = false
        wrapper.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: wrapper.leadingAnchor, constant: 16),
            content.trailingAnchor.constraint(equalTo: wrapper.trailingAnchor, constant: -16),
            content.topAnchor.constraint(equalTo: wrapper.topAnchor, constant: 16),
            content.bottomAnchor.constraint(equalTo: wrapper.bottomAnchor, constant: -16),
        ])
        return wrapper
    }

    private func buildFootnote() {
        footnoteLabel.stringValue = "More settings - personal vocabulary, a configurable shortcut, and a sentence-cleanup pass - are coming soon."
        footnoteLabel.font = .systemFont(ofSize: 11)
        footnoteLabel.preferredMaxLayoutWidth = 620
        footnoteLabel.translatesAutoresizingMaskIntoConstraints = false
    }

    // MARK: Rendering

    private func render() {
        statusIconTile.configure(symbol: status.symbol, tint: status.tint)
        statusTitleLabel.stringValue = status.title
        statusDetailLabel.stringValue = status.detail

        switch status {
        case .needsMicrophone:
            statusActionButton.title = "Request Microphone Access"
            statusActionButton.isHidden = false
        case .needsSpeechRecognition:
            statusActionButton.title = "Request Speech Recognition Access"
            statusActionButton.isHidden = false
        case .needsAccessibility:
            statusActionButton.title = "Request Accessibility Access"
            statusActionButton.isHidden = false
        case .ready, .recording, .transcribing, .didNotCatchThat:
            statusActionButton.isHidden = true
        }
        applyTheme()
    }

    private func applyTheme() {
        statusPanel.applyTheme(theme)
        shortcutPanel.applyTheme(theme)
        statusIconTile.applyTheme(theme)
        statusTitleLabel.textColor = HelmTheme.nsColor(theme.chromeInkHex)
        statusDetailLabel.textColor = HelmTheme.mutedInk(theme)
        subtitleLabel.textColor = HelmTheme.mutedInk(theme)
        refreshButton.contentTintColor = HelmTheme.mutedInk(theme)
        shortcutKeyLabel.textColor = HelmTheme.nsColor(theme.chromeInkHex)
        shortcutDetailLabel.textColor = HelmTheme.mutedInk(theme)
        footnoteLabel.textColor = HelmTheme.mutedInk(theme)
    }

    // MARK: Actions

    @objc private func refreshTapped() {
        refresh()
    }

    /// Requests each permission directly via `DictationPermissions`' static
    /// system calls the first time it's genuinely needed - there's no
    /// engine/hotkey instance state involved in a permission *request*
    /// (unlike actually recording), so this page doesn't need anything
    /// forwarded from the app delegate to do it. Re-reads real status
    /// afterward either way (a denial still needs to be reflected honestly).
    @objc private func statusActionTapped() {
        switch status {
        case .needsMicrophone:
            DictationPermissions.requestMicrophone { [weak self] _ in self?.refresh() }
        case .needsSpeechRecognition:
            DictationPermissions.requestSpeechRecognition { [weak self] _ in self?.refresh() }
        case .needsAccessibility:
            DictationPermissions.requestAccessibility()
            // No completion callback exists for the Accessibility prompt -
            // the captain has to grant it in System Settings and come back;
            // `viewWillAppear`'s own refresh (on next visit) is what catches
            // a grant made while this page wasn't frontmost. Re-check now
            // too, in case it was already granted (a no-op prompt).
            refresh()
        case .ready, .recording, .transcribing, .didNotCatchThat:
            break
        }
    }
}
