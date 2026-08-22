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
// layout `VaultController`/`HelmCard` already established rather than
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
    private let refreshButton = HelmButton(symbol: "arrow.clockwise", variant: .quiet)

    private let statusPanel = HelmCard()
    private let statusIconTile = IconTileView(size: 40, cornerRadius: 10)
    private let statusTitleLabel = NSTextField(labelWithString: "")
    private let statusDetailLabel = NSTextField(wrappingLabelWithString: "")
    private var statusTextStack = NSStackView()
    private let statusActionButton = HelmButton(title: "", variant: .primary)
    // fm/grandline-dictation-page-redesign: the trailing chip the reviewed
    // prototype's Status card-head shows ("On device") once every
    // permission is granted and no action button is needed - mutually
    // exclusive with `statusActionButton` (see `render()`).
    private let statusChip = NSView()
    private let statusChipLabel = NSTextField(labelWithString: "")

    private let shortcutPanel = HelmCard()
    private let shortcutRecorder: DictationShortcutRecorderView
    private let shortcutResetButton = HelmButton(title: "", variant: .secondary)
    private let shortcutDetailLabel = NSTextField(wrappingLabelWithString: "")
    private var shortcutTextStack = NSStackView()

    private let cleanupPanel = HelmCard()
    private let cleanupSwitch = NSSwitch()
    private let cleanupTitleLabel = NSTextField(labelWithString: "")
    private let cleanupDetailLabel = NSTextField(wrappingLabelWithString: "")
    private var cleanupTextStack = NSStackView()

    private let localWhisperPanel = HelmCard()
    private let localWhisperSwitch = NSSwitch()
    private let localWhisperTitleLabel = NSTextField(labelWithString: "")
    private let localWhisperDetailLabel = NSTextField(wrappingLabelWithString: "")
    private var localWhisperTextStack = NSStackView()
    private let modelStatusLabel = NSTextField(labelWithString: "")
    // The reviewed prototype's "Model ready" chip - shown in place of
    // `modelStatusLabel`'s plain text only for the terse `.ready` state (the
    // one state the prototype actually depicts); every other state
    // (downloading/failed/not-downloaded) keeps the existing plain label,
    // since those messages are longer and dynamic, not a fixed short word.
    private let modelReadyPill = NSView()
    private let modelReadyPillLabel = NSTextField(labelWithString: "")
    private let modelActionButton = HelmButton(title: "", variant: .primary)
    /// GL-35: 547MB is not a footprint to strand. Only shown while the model
    /// is actually on disk.
    private let modelDeleteButton = HelmButton(title: "Delete Model", variant: .destructive)
    private let modelProgressBar = NSProgressIndicator()
    private var modelState: WhisperModelState = .notDownloaded

    private let vocabularyPanel = HelmCard()
    private let vocabularyCountLabel = NSTextField(labelWithString: "")
    private let explainerLabel = NSTextField(wrappingLabelWithString: "")
    private var vocabularyColumn = NSStackView()
    private let vocabularyChipFlow = ChipFlowView()
    private let vocabularyInputField = NSTextField()
    private let vocabularyAddButton = HelmButton(title: "", variant: .secondary)

    private let historyPanel = HelmCard()
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
            contentStack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: HelmMetrics.pageGutter),
            contentStack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -HelmMetrics.pageGutter),
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

    /// Keeps every card's wrapping description label sized to the row's
    /// real, currently-rendered available width instead of the fixed
    /// `preferredMaxLayoutWidth` constants each label starts with, which
    /// stayed a hardcoded number regardless of how wide the card - and
    /// therefore the row up to its trailing tile/switch/button - actually
    /// resolved to.
    ///
    /// This is the fix for the captain-reported "text cramped to the first
    /// half of the card, with a big empty gap before the toggle/button"
    /// bug. It is the same class of defect `ToolRowLayout`'s own history
    /// documents (`HelmUIComponents.swift`'s "status column jitters...
    /// because textStack keeps its natural width") and AGENTS.md's AppKit
    /// gotcha catalogue covers twice over:
    ///
    /// - Gotcha #10: each row here used to be left at the default
    ///   `.gravityAreas` distribution, which lays every arranged view out
    ///   at its own natural size and resolves leftover width by Auto
    ///   Layout's own tie-breaking - never by any view's hugging priority.
    ///   Every row-building method below now sets `distribution = .fill`.
    /// - Gotcha #12: `setContentHuggingPriority`/
    ///   `setContentCompressionResistancePriority` are no-ops on an
    ///   `NSStackView` (it has no intrinsic content size for a
    ///   content-priority API to constrain against) - each row's vertical
    ///   title/description text stack used exactly that no-op call, so
    ///   even with `.fill` distribution nothing told the row that the text
    ///   stack, not the tile or the trailing control, should absorb the
    ///   row's leftover width. `ToolRowLayout.columnHugging`'s stack-level
    ///   `setHuggingPriority`/`setClippingResistancePriority` is the API
    ///   that actually does this, and every text stack below now uses it.
    ///
    /// Those two fixes make each text stack's own `bounds.width` correctly
    /// reflect the row's real leftover space - but a *wrapping* label's
    /// intrinsic width still comes from its own `preferredMaxLayoutWidth`,
    /// which those fixes don't touch. This is the other half:
    /// `HelmEmptyState.layout()`'s already-established pattern (see its own
    /// doc comment) of reading back a container's real resolved width on
    /// every layout pass and feeding it to the wrapping label directly, so
    /// the label always wraps at the row's actual available width - a
    /// window resize included - rather than a hardcoded constant. The
    /// `preferredMaxLayoutWidth` values set at construction time are only
    /// the safe *initial* seed for the very first layout pass, before any
    /// real width is known; every pass after that overwrites them here.
    override func viewDidLayout() {
        super.viewDidLayout()
        for (stack, label) in [
            (statusTextStack, statusDetailLabel),
            (shortcutTextStack, shortcutDetailLabel),
            (cleanupTextStack, cleanupDetailLabel),
            (localWhisperTextStack, localWhisperDetailLabel),
            (vocabularyColumn, explainerLabel),
        ] {
            let available = stack.bounds.width
            guard available > 0, label.preferredMaxLayoutWidth != available else { continue }
            label.preferredMaxLayoutWidth = available
            label.invalidateIntrinsicContentSize()
        }
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
        sectionLabel.font = HelmType.sectionTitle()
        sectionLabel.translatesAutoresizingMaskIntoConstraints = false
        statusPanel.setHeader(sectionLabel)

        statusTitleLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        statusTitleLabel.translatesAutoresizingMaskIntoConstraints = false

        statusDetailLabel.font = .systemFont(ofSize: 11.5)
        statusDetailLabel.preferredMaxLayoutWidth = 520
        statusDetailLabel.translatesAutoresizingMaskIntoConstraints = false

        statusTextStack = NSStackView(views: [statusTitleLabel, statusDetailLabel])
        statusTextStack.orientation = .vertical
        statusTextStack.alignment = .leading
        statusTextStack.spacing = 3
        statusTextStack.translatesAutoresizingMaskIntoConstraints = false
        // Stack-level, not content-level - see `viewDidLayout`'s doc
        // comment (AGENTS.md gotcha #12): this is what actually lets the
        // text column absorb the row's leftover width.
        statusTextStack.setHuggingPriority(.defaultLow, for: .horizontal)
        statusTextStack.setClippingResistancePriority(.defaultLow, for: .horizontal)

        statusActionButton.controlSize = .regular
        statusActionButton.target = self
        statusActionButton.action = #selector(statusActionTapped)
        statusActionButton.setContentHuggingPriority(.required, for: .horizontal)
        statusActionButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        statusActionButton.translatesAutoresizingMaskIntoConstraints = false

        statusChip.setContentHuggingPriority(.required, for: .horizontal)
        statusChip.setContentCompressionResistancePriority(.required, for: .horizontal)
        statusChip.isHidden = true

        let row = NSStackView(views: [statusIconTile, statusTextStack, statusChip, statusActionButton])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 14
        // AGENTS.md gotcha #10: the default `.gravityAreas` distribution
        // lays every arranged view out at its own natural size and
        // resolves leftover width by Auto Layout's own tie-breaking, which
        // is what left the text column confined to its own natural width
        // with a large blank gap before the trailing chip/button instead of
        // flowing to fill the row. `.fill` is what makes `statusTextStack`'s
        // hugging priority matter at all.
        row.distribution = .fill
        row.translatesAutoresizingMaskIntoConstraints = false

        statusPanel.setBody(row, insets: HelmCard.contentInsets)
        return statusPanel
    }

    private func buildShortcutSection() -> NSView {
        let sectionLabel = NSTextField(labelWithString: "Shortcut")
        sectionLabel.font = HelmType.sectionTitle()
        sectionLabel.translatesAutoresizingMaskIntoConstraints = false
        shortcutPanel.setHeader(sectionLabel)

        let keyTile = IconTileView(size: 40, cornerRadius: 10)
        keyTile.configure(symbol: "waveform", tint: .accent)

        shortcutRecorder.onChange = { [weak self] newShortcut in
            self?.shortcutChanged(newShortcut)
        }

        shortcutResetButton.title = "Reset to Right ⌥ Option"
        shortcutResetButton.controlSize = .small
        shortcutResetButton.target = self
        shortcutResetButton.action = #selector(resetShortcutTapped)
        shortcutResetButton.translatesAutoresizingMaskIntoConstraints = false

        shortcutDetailLabel.font = .systemFont(ofSize: 11.5)
        // Tightened to match the reviewed prototype's terser card-head
        // copy - the release-to-paste behavior is still covered by the
        // page's own footnote and the live status card's own detail text.
        shortcutDetailLabel.stringValue = "Click the field, then hold the key or combo you want."
        shortcutDetailLabel.preferredMaxLayoutWidth = 460
        shortcutDetailLabel.translatesAutoresizingMaskIntoConstraints = false

        let recorderRow = NSStackView(views: [shortcutRecorder, shortcutResetButton])
        recorderRow.orientation = .horizontal
        recorderRow.alignment = .centerY
        recorderRow.spacing = 8
        recorderRow.translatesAutoresizingMaskIntoConstraints = false

        shortcutTextStack = NSStackView(views: [recorderRow, shortcutDetailLabel])
        shortcutTextStack.orientation = .vertical
        shortcutTextStack.alignment = .leading
        shortcutTextStack.spacing = 6
        shortcutTextStack.translatesAutoresizingMaskIntoConstraints = false
        shortcutTextStack.setHuggingPriority(.defaultLow, for: .horizontal)
        shortcutTextStack.setClippingResistancePriority(.defaultLow, for: .horizontal)

        let row = NSStackView(views: [keyTile, shortcutTextStack])
        row.orientation = .horizontal
        row.alignment = .top
        row.spacing = 14
        row.distribution = .fill
        row.translatesAutoresizingMaskIntoConstraints = false

        shortcutPanel.setBody(row, insets: HelmCard.contentInsets)
        return shortcutPanel
    }

    private func buildCleanupSection() -> NSView {
        let sectionLabel = NSTextField(labelWithString: "Cleanup")
        sectionLabel.font = HelmType.sectionTitle()
        sectionLabel.translatesAutoresizingMaskIntoConstraints = false
        cleanupPanel.setHeader(sectionLabel)

        let sparkleTile = IconTileView(size: 40, cornerRadius: 10)
        sparkleTile.configure(symbol: "sparkles", tint: .violet)

        cleanupTitleLabel.stringValue = "Clean up my sentences"
        cleanupTitleLabel.font = .systemFont(ofSize: 12.5, weight: .medium)
        cleanupTitleLabel.translatesAutoresizingMaskIntoConstraints = false

        // Tightened to the reviewed prototype's one-line phrasing - the
        // network/fallback nuance is still covered by the page's footnote
        // ("only the optional \"Clean up my sentences\" rewrite above needs
        // network access").
        cleanupDetailLabel.stringValue = "Rewrites each dictation into a well-formed sentence before pasting."
        cleanupDetailLabel.font = .systemFont(ofSize: 11)
        cleanupDetailLabel.preferredMaxLayoutWidth = 460
        cleanupDetailLabel.translatesAutoresizingMaskIntoConstraints = false

        cleanupTextStack = NSStackView(views: [cleanupTitleLabel, cleanupDetailLabel])
        cleanupTextStack.orientation = .vertical
        cleanupTextStack.alignment = .leading
        cleanupTextStack.spacing = 3
        cleanupTextStack.translatesAutoresizingMaskIntoConstraints = false
        cleanupTextStack.setHuggingPriority(.defaultLow, for: .horizontal)
        cleanupTextStack.setClippingResistancePriority(.defaultLow, for: .horizontal)

        cleanupSwitch.target = self
        cleanupSwitch.action = #selector(cleanupToggled)
        cleanupSwitch.setContentHuggingPriority(.required, for: .horizontal)
        cleanupSwitch.setContentCompressionResistancePriority(.required, for: .horizontal)
        cleanupSwitch.translatesAutoresizingMaskIntoConstraints = false

        let row = NSStackView(views: [sparkleTile, cleanupTextStack, cleanupSwitch])
        row.orientation = .horizontal
        row.alignment = .top
        row.spacing = 14
        row.distribution = .fill
        row.translatesAutoresizingMaskIntoConstraints = false

        cleanupPanel.setBody(row, insets: HelmCard.contentInsets)
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
        sectionLabel.font = HelmType.sectionTitle()
        sectionLabel.translatesAutoresizingMaskIntoConstraints = false
        localWhisperPanel.setHeader(sectionLabel)

        let waveTile = IconTileView(size: 40, cornerRadius: 10)
        waveTile.configure(symbol: "cpu", tint: .info)

        localWhisperTitleLabel.stringValue = "Use local Whisper engine"
        localWhisperTitleLabel.font = .systemFont(ofSize: 12.5, weight: .medium)
        localWhisperTitleLabel.translatesAutoresizingMaskIntoConstraints = false

        // Tightened to the reviewed prototype's terser spec-line copy - the
        // Apple Speech fallback is still covered by `modelStatusLabel`'s own
        // dynamic states and the page's footnote.
        localWhisperDetailLabel.stringValue = "whisper.cpp large-v3-turbo, Metal-accelerated, fully offline once downloaded."
        localWhisperDetailLabel.font = .systemFont(ofSize: 11)
        localWhisperDetailLabel.preferredMaxLayoutWidth = 460
        localWhisperDetailLabel.translatesAutoresizingMaskIntoConstraints = false

        localWhisperTextStack = NSStackView(views: [localWhisperTitleLabel, localWhisperDetailLabel])
        localWhisperTextStack.orientation = .vertical
        localWhisperTextStack.alignment = .leading
        localWhisperTextStack.spacing = 3
        localWhisperTextStack.translatesAutoresizingMaskIntoConstraints = false
        localWhisperTextStack.setHuggingPriority(.defaultLow, for: .horizontal)
        localWhisperTextStack.setClippingResistancePriority(.defaultLow, for: .horizontal)

        localWhisperSwitch.target = self
        localWhisperSwitch.action = #selector(localWhisperToggled)
        localWhisperSwitch.setContentHuggingPriority(.required, for: .horizontal)
        localWhisperSwitch.setContentCompressionResistancePriority(.required, for: .horizontal)
        localWhisperSwitch.translatesAutoresizingMaskIntoConstraints = false

        let toggleRow = NSStackView(views: [waveTile, localWhisperTextStack, localWhisperSwitch])
        toggleRow.orientation = .horizontal
        toggleRow.alignment = .top
        toggleRow.spacing = 14
        toggleRow.distribution = .fill
        toggleRow.translatesAutoresizingMaskIntoConstraints = false

        modelStatusLabel.font = .systemFont(ofSize: 11.5)
        modelStatusLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        modelStatusLabel.translatesAutoresizingMaskIntoConstraints = false

        modelReadyPill.setContentHuggingPriority(.required, for: .horizontal)
        modelReadyPill.setContentCompressionResistancePriority(.required, for: .horizontal)
        modelReadyPill.isHidden = true

        modelProgressBar.style = .bar
        modelProgressBar.isIndeterminate = false
        modelProgressBar.minValue = 0
        modelProgressBar.maxValue = 1
        modelProgressBar.controlSize = .small
        modelProgressBar.isHidden = true
        modelProgressBar.translatesAutoresizingMaskIntoConstraints = false
        modelProgressBar.widthAnchor.constraint(equalToConstant: 160).isActive = true

        modelActionButton.controlSize = .small
        modelActionButton.target = self
        modelActionButton.action = #selector(modelActionTapped)
        modelActionButton.setContentHuggingPriority(.required, for: .horizontal)
        modelActionButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        modelActionButton.translatesAutoresizingMaskIntoConstraints = false

        modelDeleteButton.controlSize = .small
        modelDeleteButton.target = self
        modelDeleteButton.action = #selector(modelDeleteTapped)
        modelDeleteButton.toolTip = "Remove the downloaded model from disk"
        modelDeleteButton.isHidden = true
        modelDeleteButton.setContentHuggingPriority(.required, for: .horizontal)
        modelDeleteButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        modelDeleteButton.translatesAutoresizingMaskIntoConstraints = false

        let modelRow = NSStackView(views: [modelStatusLabel, modelReadyPill, modelProgressBar, modelDeleteButton, modelActionButton])
        modelRow.orientation = .horizontal
        modelRow.alignment = .centerY
        modelRow.spacing = 10
        // Same gotcha #10 fix as every other row on this page - without
        // `.fill`, this row's button drifted with sibling content instead
        // of sitting pinned at the row's trailing edge.
        modelRow.distribution = .fill
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

        localWhisperPanel.setBody(column, insets: HelmCard.contentInsets)
        return localWhisperPanel
    }

    private func buildVocabularySection() -> NSView {
        let sectionLabel = NSTextField(labelWithString: "Words I use often")
        sectionLabel.font = HelmType.sectionTitle()
        vocabularyCountLabel.font = .monospacedSystemFont(ofSize: 10.5, weight: .medium)
        let headerRow = NSStackView(views: [sectionLabel, vocabularyCountLabel])
        headerRow.orientation = .horizontal
        headerRow.spacing = 6
        headerRow.translatesAutoresizingMaskIntoConstraints = false
        vocabularyPanel.setHeader(headerRow)

        // Tightened to the reviewed prototype's terser card-head phrasing -
        // the per-engine nuance (Apple's per-phrase hint vs. Whisper's
        // softer whole-list nudge) is still available on hover via the
        // label's own tooltip.
        explainerLabel.stringValue = "Biases recognition toward your own vocabulary - added here, it's used as a hint on your next recording."
        explainerLabel.toolTip = "This is a soft nudge, not a guarantee: Apple's on-device recognizer treats each phrase individually, while the local Whisper engine (if enabled) treats the whole list as a softer style hint."
        explainerLabel.font = .systemFont(ofSize: 11)
        explainerLabel.preferredMaxLayoutWidth = 520
        explainerLabel.translatesAutoresizingMaskIntoConstraints = false

        vocabularyChipFlow.translatesAutoresizingMaskIntoConstraints = false

        vocabularyInputField.placeholderString = "Add a word or phrase…"
        vocabularyInputField.delegate = self
        vocabularyInputField.translatesAutoresizingMaskIntoConstraints = false

        vocabularyAddButton.title = "Add"
        vocabularyAddButton.controlSize = .small
        vocabularyAddButton.target = self
        vocabularyAddButton.action = #selector(addVocabularyWordTapped)
        vocabularyAddButton.setContentHuggingPriority(.required, for: .horizontal)
        vocabularyAddButton.translatesAutoresizingMaskIntoConstraints = false

        let addRow = NSStackView(views: [vocabularyInputField, vocabularyAddButton])
        addRow.orientation = .horizontal
        addRow.spacing = 8
        addRow.translatesAutoresizingMaskIntoConstraints = false

        vocabularyColumn = NSStackView(views: [explainerLabel, vocabularyChipFlow, addRow])
        vocabularyColumn.orientation = .vertical
        vocabularyColumn.alignment = .leading
        vocabularyColumn.spacing = 10
        vocabularyColumn.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            vocabularyChipFlow.widthAnchor.constraint(equalTo: vocabularyColumn.widthAnchor),
            addRow.widthAnchor.constraint(equalTo: vocabularyColumn.widthAnchor),
        ])

        vocabularyPanel.setBody(vocabularyColumn, insets: HelmCard.contentInsets)
        return vocabularyPanel
    }

    private func buildHistorySection() -> NSView {
        let sectionLabel = NSTextField(labelWithString: "Recent Dictations")
        sectionLabel.font = HelmType.sectionTitle()
        historyCountLabel.font = .monospacedSystemFont(ofSize: 10.5, weight: .medium)
        let headerRow = NSStackView(views: [sectionLabel, historyCountLabel])
        headerRow.orientation = .horizontal
        headerRow.spacing = 6
        headerRow.translatesAutoresizingMaskIntoConstraints = false
        historyPanel.setHeader(headerRow)

        // GL-35: a single entry can be removed, not only "clear everything".
        historyListView.onDeleteEntry = { [weak self] entry in
            guard let self else { return }
            self.store.removeHistoryEntry(date: entry.date, text: entry.text)
            self.renderHistory()
            if let container = self.view.window?.contentView {
                Toast.showUndo(in: container, message: "Deleted transcription") { [weak self] in
                    guard let self else { return }
                    self.store.restoreHistoryEntry(entry)
                    self.renderHistory()
                }
            }
        }
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
            statusChip.isHidden = true
        case .needsSpeechRecognition:
            statusActionButton.title = "Request Speech Recognition Access"
            statusActionButton.isHidden = false
            statusChip.isHidden = true
        case .needsAccessibility:
            statusActionButton.title = "Request Accessibility Access"
            statusActionButton.isHidden = false
            statusChip.isHidden = true
        case .ready:
            // The reviewed prototype's "On device" chip - shown only once
            // ready, since `.cleaningUp` genuinely does reach the network
            // (the claude CLI rewrite pass) and would make the claim false.
            statusActionButton.isHidden = true
            statusChip.isHidden = false
        case .recording, .transcribing, .cleaningUp, .didNotCatchThat, .systemDictationDisabled:
            statusActionButton.isHidden = true
            statusChip.isHidden = true
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
        ToolRowLayout.pill(text: "On device", colorHex: HelmTint.good.hex(in: theme),
                          into: statusChip, label: statusChipLabel, theme: theme)
        subtitleLabel.textColor = HelmTheme.mutedInk(theme)
        shortcutRecorder.applyTheme(theme)
        shortcutDetailLabel.textColor = HelmTheme.mutedInk(theme)
        cleanupPanel.applyTheme(theme)
        cleanupTitleLabel.textColor = HelmTheme.nsColor(theme.chromeInkHex)
        cleanupDetailLabel.textColor = HelmTheme.mutedInk(theme)
        localWhisperPanel.applyTheme(theme)
        localWhisperTitleLabel.textColor = HelmTheme.nsColor(theme.chromeInkHex)
        localWhisperDetailLabel.textColor = HelmTheme.mutedInk(theme)
        modelStatusLabel.textColor = HelmTheme.mutedInk(theme)
        ToolRowLayout.pill(text: "Model ready", colorHex: HelmTint.good.hex(in: theme),
                          into: modelReadyPill, label: modelReadyPillLabel, theme: theme)
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
            modelStatusLabel.isHidden = false
            modelReadyPill.isHidden = true
            modelProgressBar.isHidden = true
            modelActionButton.title = "Download Model"
            modelActionButton.isEnabled = true
            modelDeleteButton.isHidden = true
        case .downloading(let progress):
            modelStatusLabel.stringValue = "Downloading… \(Int(progress * 100))%"
            modelStatusLabel.isHidden = false
            modelReadyPill.isHidden = true
            modelProgressBar.isHidden = false
            modelProgressBar.doubleValue = progress
            modelActionButton.title = "Cancel"
            modelActionButton.isEnabled = true
            modelDeleteButton.isHidden = true
        case .ready:
            // The reviewed prototype's "Model ready" chip - this is the one
            // state it actually depicts, so it's the one state that gets
            // the pill treatment; every other state keeps the existing
            // plain (longer, dynamic) text.
            modelStatusLabel.isHidden = true
            modelReadyPill.isHidden = false
            modelProgressBar.isHidden = true
            modelActionButton.title = "Re-download"
            modelActionButton.isEnabled = true
            modelDeleteButton.isHidden = false
        case .failed(let message):
            modelStatusLabel.stringValue = "Download failed: \(message)"
            modelStatusLabel.isHidden = false
            modelReadyPill.isHidden = true
            modelProgressBar.isHidden = true
            modelActionButton.title = "Retry Download"
            modelActionButton.isEnabled = true
            // A failed *download* leaves nothing on disk; a failed delete does
            // - so this follows the file, not the state's name.
            modelDeleteButton.isHidden = WhisperModelManager.shared.downloadedByteCount == nil
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
                guard let self else { return }
                self.store.removeVocabularyWord(word)
                // GL-33: this delete had no confirmation and no way back - one
                // of the two the review named specifically.
                if let container = self.view.window?.contentView {
                    Toast.showUndo(in: container, message: "Removed \u{201C}\(word)\u{201D}") { [weak self] in
                        self?.store.addVocabularyWord(word)
                    }
                }
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

    /// GL-35. Confirmed, because it is a ~547MB re-download to undo and this
    /// app's convention is that a destructive action asks first.
    @objc private func modelDeleteTapped() {
        let bytes = WhisperModelManager.shared.downloadedByteCount
        let size = bytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "the downloaded model"
        let alert = NSAlert()
        alert.messageText = "Delete the local Whisper model?"
        alert.informativeText = "This frees \(size). Dictation falls back to Apple's Speech framework, "
            + "and you can download the model again at any time."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        if WhisperModelManager.shared.deleteDownloadedModel(),
           let container = view.window?.contentView {
            Toast.show(in: container, message: "Local Whisper model deleted")
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
