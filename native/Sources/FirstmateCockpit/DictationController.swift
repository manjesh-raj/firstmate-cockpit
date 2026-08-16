// Manjesh Grand Line - native macOS app.
//
// The "Dictation" rail destination. Phase 1 (fm/grandline-dictation-mvp)
// shipped a deliberately minimal page - real permission status and the fixed
// Right ⌥ Option shortcut, nothing else. Phase 2
// (fm/grandline-dictation-phase2) adds the three things phase 1 explicitly
// deferred: a transcription history list, a personal vocabulary editor, and
// a real shortcut recorder replacing the fixed combo. Phase 3
// (fm/grandline-dictation-phase3) adds the "Clean up my sentences" toggle -
// see `CLAUDE.md`'s "Dictation" section for the full phase split (all three
// originally-planned phases are now complete).
// Follows the same "hide, don't rebuild" body-child convention every other
// destination uses (`AppShellController`), and the same Settings-styled card
// layout `VaultController`/`ShiftPanelView` already established rather than
// inventing new visual language.
//
// Status is read fresh from `DictationPermissions` on every `viewWillAppear`
// (matching `VaultController`/`ReviewController`'s own "refresh on appear,
// no polling" convention - PRODUCT.md's "quiet until it matters") and again
// live whenever the shared `DictationEngine` reports a state change while
// this page happens to be visible, so a captain watching this page while
// dictating sees "Recording…"/"Transcribing…" for real, not a static label.
// History/vocabulary are similarly re-read from `DictationStore` on every
// appear and on every `DictationStore.observe` notification (a dictation
// completed while this page happens to be open updates the list live).

import AppKit

final class DictationController: NSViewController, NSTextFieldDelegate {

    private let store: DictationStore

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
    private let shortcutRecorder: DictationShortcutRecorderView
    private let shortcutResetButton = NSButton()
    private let shortcutDetailLabel = NSTextField(wrappingLabelWithString: "")

    private let cleanupPanel = ShiftPanelView()
    private let cleanupSwitch = NSSwitch()
    private let cleanupTitleLabel = NSTextField(labelWithString: "")
    private let cleanupDetailLabel = NSTextField(wrappingLabelWithString: "")

    private let localWhisperPanel = ShiftPanelView()
    private let localWhisperSwitch = NSSwitch()
    private let localWhisperTitleLabel = NSTextField(labelWithString: "")
    private let localWhisperDetailLabel = NSTextField(wrappingLabelWithString: "")
    private let modelStatusLabel = NSTextField(labelWithString: "")
    private let modelActionButton = NSButton()
    private let modelProgressBar = NSProgressIndicator()
    private var modelState: WhisperModelState = .notDownloaded

    private let vocabularyPanel = ShiftPanelView()
    private let vocabularyCountLabel = NSTextField(labelWithString: "")
    private let vocabularyChipFlow = ChipFlowView()
    private let vocabularyInputField = NSTextField()
    private let vocabularyAddButton = NSButton()

    private let historyPanel = ShiftPanelView()
    private let historyCountLabel = NSTextField(labelWithString: "")
    private let historyListView = DictationHistoryListView()
    private let historyListScroll = NSScrollView()

    private let footnoteLabel = NSTextField(wrappingLabelWithString: "")

    private var status: DictationStatus = DictationPermissions.currentStatus()
    private var theme: HelmTheme = ThemeManager.shared.theme
    private var hasLoadedOnce = false

    /// Forwarded to `AppShellController` -> the app delegate, which is what
    /// actually owns the live `DictationHotkey` instance - this controller
    /// only edits the persisted preference and reports the change, matching
    /// how `SettingsController.onFontSizeStep` forwards rather than owning
    /// the live console it affects.
    var onShortcutChanged: ((DictationShortcut) -> Void)?

    init(store: DictationStore) {
        self.store = store
        self.shortcutRecorder = DictationShortcutRecorderView(shortcut: AppSettings.shared.dictationShortcut)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

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
        _ = buildCleanupSection()
        _ = buildLocalWhisperSection()
        _ = buildVocabularySection()
        _ = buildHistorySection()
        buildFootnote()

        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = 20
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        contentStack.addArrangedSubview(header)
        contentStack.addArrangedSubview(statusPanel)
        contentStack.addArrangedSubview(shortcutPanel)
        contentStack.addArrangedSubview(cleanupPanel)
        contentStack.addArrangedSubview(localWhisperPanel)
        contentStack.addArrangedSubview(vocabularyPanel)
        contentStack.addArrangedSubview(historyPanel)
        contentStack.addArrangedSubview(footnoteLabel)

        content.addSubview(contentStack)
        NSLayoutConstraint.activate([
            contentStack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 28),
            contentStack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -28),
            contentStack.topAnchor.constraint(equalTo: content.topAnchor, constant: 24),
            contentStack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -28),
            statusPanel.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
            shortcutPanel.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
            cleanupPanel.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
            localWhisperPanel.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
            vocabularyPanel.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
            historyPanel.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
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

        // A dictation completed (or a vocabulary edit made) while this page
        // happens to be visible should show up immediately, not only on the
        // next `viewWillAppear` - matches `HostStore.observe`'s "list of
        // closures" convention for the same reason.
        store.observe { [weak self] in
            guard let self, self.isViewLoaded else { return }
            self.renderHistory()
            self.renderVocabulary()
        }

        // fm/grandline-dictation-whisper-engine: live download progress -
        // `WhisperModelManager.observe` fires immediately with the current
        // state (matching `DictationStore.observe`'s convention) and again
        // on every state change, so the progress bar/status text update in
        // real time while a download is in flight and this page is visible.
        WhisperModelManager.shared.observe { [weak self] state in
            guard let self, self.isViewLoaded else { return }
            self.modelState = state
            self.renderLocalWhisperSection()
        }
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        hasLoadedOnce = true
        view.layoutSubtreeIfNeeded()
        scroll.contentView.scroll(to: .zero)
        scroll.reflectScrolledClipView(scroll.contentView)
        refresh()
        renderHistory()
        renderVocabulary()
    }

    /// Re-reads real permission state and re-renders. Called on every page
    /// visit, after the captain returns from a system permission dialog
    /// (there is no completion callback for "the user closed System
    /// Settings," so re-checking on next appear is the same honest approach
    /// `SudoTouchIDController`/`VaultController` already use for their own
    /// OS-level checks), and after `setEngineStatus` reports a change.
    func refresh() {
        cleanupSwitch.state = AppSettings.shared.dictationCleanupEnabled ? .on : .off
        localWhisperSwitch.state = AppSettings.shared.dictationLocalWhisperEnabled ? .on : .off
        WhisperModelManager.shared.refreshState()
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

        shortcutRecorder.onChange = { [weak self] newShortcut in
            self?.shortcutChanged(newShortcut)
        }

        shortcutResetButton.title = "Reset to Right ⌥ Option"
        shortcutResetButton.bezelStyle = .rounded
        shortcutResetButton.controlSize = .small
        shortcutResetButton.target = self
        shortcutResetButton.action = #selector(resetShortcutTapped)
        shortcutResetButton.translatesAutoresizingMaskIntoConstraints = false

        shortcutDetailLabel.font = .systemFont(ofSize: 11.5)
        shortcutDetailLabel.stringValue = "Click the field, then press the key or combo you want to hold. Release to stop recording and paste the transcribed text at your cursor."
        shortcutDetailLabel.preferredMaxLayoutWidth = 460
        shortcutDetailLabel.translatesAutoresizingMaskIntoConstraints = false

        let recorderRow = NSStackView(views: [shortcutRecorder, shortcutResetButton])
        recorderRow.orientation = .horizontal
        recorderRow.alignment = .centerY
        recorderRow.spacing = 8
        recorderRow.translatesAutoresizingMaskIntoConstraints = false

        let textStack = NSStackView(views: [recorderRow, shortcutDetailLabel])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 6
        textStack.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let row = NSStackView(views: [keyTile, textStack])
        row.orientation = .horizontal
        row.alignment = .top
        row.spacing = 14
        row.translatesAutoresizingMaskIntoConstraints = false

        shortcutPanel.setBody(paddedBody(row))
        return shortcutPanel
    }

    private func buildCleanupSection() -> NSView {
        let sectionLabel = NSTextField(labelWithString: "Cleanup")
        sectionLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        sectionLabel.translatesAutoresizingMaskIntoConstraints = false
        cleanupPanel.setHeader(sectionLabel)

        let sparkleTile = IconTileView(size: 40, cornerRadius: 10)
        sparkleTile.configure(symbol: "sparkles", tint: .violet)

        cleanupTitleLabel.stringValue = "Clean up my sentences"
        cleanupTitleLabel.font = .systemFont(ofSize: 12.5, weight: .medium)
        cleanupTitleLabel.translatesAutoresizingMaskIntoConstraints = false

        cleanupDetailLabel.stringValue = "Rewrite each dictation into a well-formed sentence before pasting - fixes filler words and rough phrasing, not just typos. Needs network access and your own signed-in claude CLI, unlike the rest of Dictation, which works fully offline. If the rewrite fails for any reason (no network, not signed in), the raw transcript is pasted instead."
        cleanupDetailLabel.font = .systemFont(ofSize: 11)
        cleanupDetailLabel.preferredMaxLayoutWidth = 460
        cleanupDetailLabel.translatesAutoresizingMaskIntoConstraints = false

        let textStack = NSStackView(views: [cleanupTitleLabel, cleanupDetailLabel])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 3
        textStack.setContentHuggingPriority(.defaultLow, for: .horizontal)
        textStack.translatesAutoresizingMaskIntoConstraints = false

        cleanupSwitch.target = self
        cleanupSwitch.action = #selector(cleanupToggled)
        cleanupSwitch.setContentHuggingPriority(.required, for: .horizontal)
        cleanupSwitch.translatesAutoresizingMaskIntoConstraints = false

        let row = NSStackView(views: [sparkleTile, textStack, cleanupSwitch])
        row.orientation = .horizontal
        row.alignment = .top
        row.spacing = 14
        row.translatesAutoresizingMaskIntoConstraints = false

        cleanupPanel.setBody(paddedBody(row))
        return cleanupPanel
    }

    /// fm/grandline-dictation-whisper-engine: an optional local Whisper
    /// engine (vendored whisper.cpp, `large-v3-turbo` quantized model) as an
    /// alternative to the Apple Speech framework path above - same
    /// visual/interaction style as the Cleanup card immediately above it
    /// (icon tile + title/detail text + a switch), plus a model-status row
    /// (download progress/action) since this toggle has a real one-time
    /// setup step the Cleanup toggle doesn't.
    private func buildLocalWhisperSection() -> NSView {
        let sectionLabel = NSTextField(labelWithString: "Local Whisper Engine")
        sectionLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        sectionLabel.translatesAutoresizingMaskIntoConstraints = false
        localWhisperPanel.setHeader(sectionLabel)

        let waveTile = IconTileView(size: 40, cornerRadius: 10)
        waveTile.configure(symbol: "cpu", tint: .info)

        localWhisperTitleLabel.stringValue = "Use local Whisper engine"
        localWhisperTitleLabel.font = .systemFont(ofSize: 12.5, weight: .medium)
        localWhisperTitleLabel.translatesAutoresizingMaskIntoConstraints = false

        localWhisperDetailLabel.stringValue = "Transcribe on-device with whisper.cpp (large-v3-turbo) instead of Apple's Speech framework - generally more accurate, and still fully offline once the model is downloaded. If the model isn't downloaded yet, or ever fails to load, dictation automatically falls back to Apple Speech."
        localWhisperDetailLabel.font = .systemFont(ofSize: 11)
        localWhisperDetailLabel.preferredMaxLayoutWidth = 460
        localWhisperDetailLabel.translatesAutoresizingMaskIntoConstraints = false

        let textStack = NSStackView(views: [localWhisperTitleLabel, localWhisperDetailLabel])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 3
        textStack.setContentHuggingPriority(.defaultLow, for: .horizontal)
        textStack.translatesAutoresizingMaskIntoConstraints = false

        localWhisperSwitch.target = self
        localWhisperSwitch.action = #selector(localWhisperToggled)
        localWhisperSwitch.setContentHuggingPriority(.required, for: .horizontal)
        localWhisperSwitch.translatesAutoresizingMaskIntoConstraints = false

        let toggleRow = NSStackView(views: [waveTile, textStack, localWhisperSwitch])
        toggleRow.orientation = .horizontal
        toggleRow.alignment = .top
        toggleRow.spacing = 14
        toggleRow.translatesAutoresizingMaskIntoConstraints = false

        modelStatusLabel.font = .systemFont(ofSize: 11.5)
        modelStatusLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        modelStatusLabel.translatesAutoresizingMaskIntoConstraints = false

        modelProgressBar.style = .bar
        modelProgressBar.isIndeterminate = false
        modelProgressBar.minValue = 0
        modelProgressBar.maxValue = 1
        modelProgressBar.controlSize = .small
        modelProgressBar.isHidden = true
        modelProgressBar.translatesAutoresizingMaskIntoConstraints = false
        modelProgressBar.widthAnchor.constraint(equalToConstant: 160).isActive = true

        modelActionButton.bezelStyle = .rounded
        modelActionButton.controlSize = .small
        modelActionButton.target = self
        modelActionButton.action = #selector(modelActionTapped)
        modelActionButton.setContentHuggingPriority(.required, for: .horizontal)
        modelActionButton.translatesAutoresizingMaskIntoConstraints = false

        let modelRow = NSStackView(views: [modelStatusLabel, modelProgressBar, modelActionButton])
        modelRow.orientation = .horizontal
        modelRow.alignment = .centerY
        modelRow.spacing = 10
        modelRow.translatesAutoresizingMaskIntoConstraints = false

        let column = NSStackView(views: [toggleRow, modelRow])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 12
        column.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            toggleRow.widthAnchor.constraint(equalTo: column.widthAnchor),
            modelRow.widthAnchor.constraint(equalTo: column.widthAnchor),
        ])

        localWhisperPanel.setBody(paddedBody(column))
        return localWhisperPanel
    }

    private func buildVocabularySection() -> NSView {
        let sectionLabel = NSTextField(labelWithString: "Words I use often")
        sectionLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        vocabularyCountLabel.font = .monospacedSystemFont(ofSize: 10.5, weight: .medium)
        let headerRow = NSStackView(views: [sectionLabel, vocabularyCountLabel])
        headerRow.orientation = .horizontal
        headerRow.spacing = 6
        headerRow.translatesAutoresizingMaskIntoConstraints = false
        vocabularyPanel.setHeader(headerRow)

        let explainerLabel = NSTextField(wrappingLabelWithString: "Bias speech recognition toward names, acronyms, or phrases you say often - added here, they're passed to the recognizer on your next recording.")
        explainerLabel.font = .systemFont(ofSize: 11)
        explainerLabel.preferredMaxLayoutWidth = 520
        explainerLabel.translatesAutoresizingMaskIntoConstraints = false

        vocabularyChipFlow.translatesAutoresizingMaskIntoConstraints = false

        vocabularyInputField.placeholderString = "Add a word or phrase…"
        vocabularyInputField.delegate = self
        vocabularyInputField.translatesAutoresizingMaskIntoConstraints = false

        vocabularyAddButton.title = "Add"
        vocabularyAddButton.bezelStyle = .rounded
        vocabularyAddButton.controlSize = .small
        vocabularyAddButton.target = self
        vocabularyAddButton.action = #selector(addVocabularyWordTapped)
        vocabularyAddButton.setContentHuggingPriority(.required, for: .horizontal)
        vocabularyAddButton.translatesAutoresizingMaskIntoConstraints = false

        let addRow = NSStackView(views: [vocabularyInputField, vocabularyAddButton])
        addRow.orientation = .horizontal
        addRow.spacing = 8
        addRow.translatesAutoresizingMaskIntoConstraints = false

        let column = NSStackView(views: [explainerLabel, vocabularyChipFlow, addRow])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 10
        column.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            vocabularyChipFlow.widthAnchor.constraint(equalTo: column.widthAnchor),
            addRow.widthAnchor.constraint(equalTo: column.widthAnchor),
        ])

        vocabularyPanel.setBody(paddedBody(column))
        return vocabularyPanel
    }

    private func buildHistorySection() -> NSView {
        let sectionLabel = NSTextField(labelWithString: "Recent Dictations")
        sectionLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        historyCountLabel.font = .monospacedSystemFont(ofSize: 10.5, weight: .medium)
        let headerRow = NSStackView(views: [sectionLabel, historyCountLabel])
        headerRow.orientation = .horizontal
        headerRow.spacing = 6
        headerRow.translatesAutoresizingMaskIntoConstraints = false
        historyPanel.setHeader(headerRow)

        historyListScroll.documentView = historyListView.tableView
        historyListScroll.hasVerticalScroller = true
        historyListScroll.hasHorizontalScroller = false
        historyListScroll.borderType = .noBorder
        historyListScroll.drawsBackground = false
        historyListScroll.translatesAutoresizingMaskIntoConstraints = false
        historyListScroll.heightAnchor.constraint(equalToConstant: 220).isActive = true

        historyPanel.setBody(historyListScroll)
        return historyPanel
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
        footnoteLabel.stringValue = "Recording, transcription, and pasting all happen on-device - only the optional \"Clean up my sentences\" rewrite above needs network access."
        footnoteLabel.font = .systemFont(ofSize: 11)
        footnoteLabel.preferredMaxLayoutWidth = 620
        footnoteLabel.translatesAutoresizingMaskIntoConstraints = false
    }

    // MARK: Rendering

    private func render() {
        statusIconTile.configure(symbol: status.symbol, tint: status.tint)
        statusTitleLabel.stringValue = status.title
        statusDetailLabel.stringValue = status.detail(shortcutDisplay: shortcutRecorder.shortcut.displayString)

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
        case .ready, .recording, .transcribing, .cleaningUp, .didNotCatchThat, .systemDictationDisabled:
            statusActionButton.isHidden = true
        }
        applyTheme()
    }

    private func applyTheme() {
        // Bug fix (fm/grandline-dictation-global-hotkey-and-theme-fixes):
        // the root view had `wantsLayer = true` (`loadView`) but this method
        // never gave that layer an explicit background color, unlike every
        // other full-size destination (`VaultController`/`FleetController`/
        // etc. - see AGENTS.md's AppKit gotcha #8). With no background set,
        // the layer stayed transparent and whatever sat behind it in the
        // window showed through as visible seams between the panels' own
        // explicitly-themed `chromeBackgroundHex` fills - a captain
        // screenshot showed this as a mismatched brown/maroon color between
        // cards. Setting it here, matching every sibling page.
        view.layer?.backgroundColor = HelmTheme.nsColor(theme.backgroundHex).cgColor
        statusPanel.applyTheme(theme)
        shortcutPanel.applyTheme(theme)
        vocabularyPanel.applyTheme(theme)
        historyPanel.applyTheme(theme)
        statusIconTile.applyTheme(theme)
        statusTitleLabel.textColor = HelmTheme.nsColor(theme.chromeInkHex)
        statusDetailLabel.textColor = HelmTheme.mutedInk(theme)
        subtitleLabel.textColor = HelmTheme.mutedInk(theme)
        refreshButton.contentTintColor = HelmTheme.mutedInk(theme)
        shortcutRecorder.applyTheme(theme)
        shortcutDetailLabel.textColor = HelmTheme.mutedInk(theme)
        cleanupPanel.applyTheme(theme)
        cleanupTitleLabel.textColor = HelmTheme.nsColor(theme.chromeInkHex)
        cleanupDetailLabel.textColor = HelmTheme.mutedInk(theme)
        localWhisperPanel.applyTheme(theme)
        localWhisperTitleLabel.textColor = HelmTheme.nsColor(theme.chromeInkHex)
        localWhisperDetailLabel.textColor = HelmTheme.mutedInk(theme)
        modelStatusLabel.textColor = HelmTheme.mutedInk(theme)
        vocabularyCountLabel.textColor = HelmTheme.mutedInk(theme)
        historyCountLabel.textColor = HelmTheme.mutedInk(theme)
        historyListView.applyTheme(theme)
        footnoteLabel.textColor = HelmTheme.mutedInk(theme)
    }

    /// Renders the model download/status row from `modelState` - called
    /// immediately on `WhisperModelManager.observe` registration and on
    /// every subsequent state change while this page is visible.
    private func renderLocalWhisperSection() {
        switch modelState {
        case .notDownloaded:
            modelStatusLabel.stringValue = "Model not downloaded (~547MB)"
            modelProgressBar.isHidden = true
            modelActionButton.title = "Download Model"
            modelActionButton.isEnabled = true
        case .downloading(let progress):
            modelStatusLabel.stringValue = "Downloading… \(Int(progress * 100))%"
            modelProgressBar.isHidden = false
            modelProgressBar.doubleValue = progress
            modelActionButton.title = "Cancel"
            modelActionButton.isEnabled = true
        case .ready:
            modelStatusLabel.stringValue = "Model ready"
            modelProgressBar.isHidden = true
            modelActionButton.title = "Re-download"
            modelActionButton.isEnabled = true
        case .failed(let message):
            modelStatusLabel.stringValue = "Download failed: \(message)"
            modelProgressBar.isHidden = true
            modelActionButton.title = "Retry Download"
            modelActionButton.isEnabled = true
        }
        applyTheme()
    }

    /// Re-reads `store.vocabulary` and rebuilds every chip - called on every
    /// appear and on every `DictationStore.observe` notification, matching
    /// the file header's "no stale list" guarantee.
    private func renderVocabulary() {
        let words = store.vocabulary
        vocabularyCountLabel.stringValue = "\(words.count)"
        let chips = words.map { word -> NSView in
            let chip = VocabularyChipView(word: word)
            chip.applyTheme(theme)
            chip.onRemove = { [weak self] in
                self?.store.removeVocabularyWord(word)
            }
            return chip
        }
        vocabularyChipFlow.setChips(chips)
    }

    /// Re-reads `store.history` (already newest-first from `DictationStore`)
    /// and reloads the table - see `renderVocabulary` for when this runs.
    private func renderHistory() {
        historyCountLabel.stringValue = "\(store.history.count)"
        historyListView.setEntries(store.history)
    }

    // MARK: Actions

    @objc private func refreshTapped() {
        refresh()
    }

    private func shortcutChanged(_ newShortcut: DictationShortcut) {
        AppSettings.shared.dictationShortcut = newShortcut
        onShortcutChanged?(newShortcut)
        render()
    }

    @objc private func resetShortcutTapped() {
        shortcutRecorder.shortcut = .defaultShortcut
        shortcutChanged(.defaultShortcut)
    }

    @objc private func cleanupToggled() {
        AppSettings.shared.dictationCleanupEnabled = cleanupSwitch.state == .on
    }

    @objc private func localWhisperToggled() {
        AppSettings.shared.dictationLocalWhisperEnabled = localWhisperSwitch.state == .on
    }

    /// The one download/cancel/retry button for the model row - its exact
    /// action depends on `modelState`, matching `statusActionTapped`'s own
    /// "one button, state decides what it does" shape above.
    @objc private func modelActionTapped() {
        switch modelState {
        case .notDownloaded, .failed:
            WhisperModelManager.shared.startDownload()
        case .downloading:
            WhisperModelManager.shared.cancelDownload()
        case .ready:
            WhisperModelManager.shared.startDownload()
        }
    }

    @objc private func addVocabularyWordTapped() {
        addVocabularyWordFromField()
    }

    private func addVocabularyWordFromField() {
        let text = vocabularyInputField.stringValue
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        store.addVocabularyWord(text)
        vocabularyInputField.stringValue = ""
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard control === vocabularyInputField, commandSelector == #selector(NSResponder.insertNewline(_:)) else {
            return false
        }
        addVocabularyWordFromField()
        return true
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
        case .ready, .recording, .transcribing, .cleaningUp, .didNotCatchThat, .systemDictationDisabled:
            break
        }
    }
}
