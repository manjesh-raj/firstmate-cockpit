// Manjesh Grand Line - native macOS app.
//
// `fm/grandline-log-analyzer-build`: the `.logAnalyzer` rail destination -
// the Log / Output Analyzer's page, and the one place this feature's flow
// lives (collect → analyze → identify → correlate → explain → next steps →
// investigate further → create incident/runbook/ticket).
//
// Everything it *renders* lives in `LogAnalyzerViews.swift`; everything it
// *computes* lives in the pure-logic files (`LogRedactor`,
// `LogSourceDetector`, `LogErrorExtractor`, `LogTimelineBuilder`,
// `LogCorrelationBuilder`, `LogAnalyzerAI`, `LogAnalyzerCommandMatcher`,
// `LogAnalyzerArtifacts`, `LogAnalyzerStore`). Read
// `LogAnalyzerModels.swift`'s header first - it explains the two-layer split
// (local vs. AI) that the whole page is arranged around.
//
// Two rules this controller is responsible for enforcing, both of them
// security-relevant rather than cosmetic:
//
//   1. **Redaction happens on the way in, once** (`addEvidence`). Raw text is
//      a local `let` in that method and is never stored on the model, so no
//      later code path - analysis, storage, copy, artifacts, the terminal
//      bridge - can reach an unredacted string. Spec §14.
//   2. **Nothing is written to disk unless the captain picked a storage
//      option other than the default.** `LogStorageChoice.doNotSave` is the
//      initial value and `persistIfNeeded` is the only writer. Spec §15.
//
// The page never talks to Kubernetes, AWS, a database, or any other
// infrastructure (spec §26). Its only external calls are `claude -p` (via
// `LogAnalyzerAI`, always on already-redacted text) and reads of this app's
// own stores.

import AppKit
import UniformTypeIdentifiers

final class LogAnalyzerController: NSViewController {

    // MARK: Injected collaborators

    /// Spec §11 - the captain's own saved commands, preferred over anything
    /// the model writes. A fresh instance, matching this app's established
    /// "each page keeps an independent copy of the same underlying store"
    /// convention (`UpdatesController`/`BootstrapController` do the same for
    /// `DependencyCatalog`, `CommandLibraryPageView` for `DocsRunbookStore`).
    private let commandLibrary = CommandLibraryStore()
    /// Spec §18 - "Create Runbook" writes into the real Docs → Runbooks
    /// store, not a private copy of the concept.
    private let runbookStore = DocsRunbookStore()
    /// Spec §15/§23/§25.
    private let store = LogAnalyzerStore()

    // MARK: Forwarded actions (the page owns none of these itself)

    /// Spec §11's "[Terminal]" action - forwarded exactly like Shift's
    /// Command Library does (`ShiftController.onSendCommandToTerminal`),
    /// since this page knows nothing about the console.
    var onSendCommandToTerminal: ((String) -> Void)?
    /// Spec §18 - after writing a runbook, offer to jump to it in Docs.
    var onOpenRunbook: ((String) -> Void)?
    /// Spec §12's third "add more evidence" action, "Send Terminal Output":
    /// this page has no terminal of its own, so the honest affordance is to
    /// take the captain to the Console, where the "Analyze Logs" toolbar
    /// button sends output straight back here.
    var onOpenConsole: (() -> Void)?

    // MARK: State

    private var investigation = LogInvestigation()
    /// The redactions found in the most recently added evidence - what the
    /// review strip shows (spec §14's "allow the user to review before
    /// sending to AI").
    private var redactions: [LogRedaction] = []
    private var sourceOverride: LogSourceKind?
    private var mode: LogAnalysisMode = .analyze
    private var comparison: LogAnalyzerArtifacts.ComparisonResult?
    private var isAnalyzing = false
    private var theme: HelmTheme = ThemeManager.shared.theme
    private var historyVisible = false
    private var redactionsExpanded = false
    /// Set when the current input arrived from a host's Console page - drives
    /// the "Imported from" badge (spec §2's "Send from Terminal").
    private var importSourceLabel: String?
    /// Spec §1: the page transitions from the input card into the split
    /// analysis workspace once there is an analysis to show. The input card
    /// comes back when the captain asks for it ("Paste More Logs", Clear, or
    /// a fresh investigation) - `updateFlowVisibility` owns both directions,
    /// so no other path can leave the page showing both or neither.
    private var inputForcedVisible = false
    /// Spec §12's panel is opt-in - it only appears once the captain presses
    /// "Investigate Further". Kept as state (rather than the card's own
    /// `isHidden`) so a re-render re-derives its contents from the *current*
    /// analysis instead of leaving a stale list on screen after more
    /// evidence is added.
    private var neededEvidenceVisible = false

    // MARK: Chrome

    private let scroll = NSScrollView()
    private let contentStack = NSStackView()
    private var headerRow: NSStackView!
    private let heroLabel = NSTextField(labelWithString: "Log Analyzer")
    private let subtitleLabel = NSTextField(labelWithString:
        "Paste raw logs or terminal output and get a structured read on what happened.")
    private var historyToggleButton: HelmButton!
    private var newInvestigationButton: HelmButton!

    private let importBadge = NSView()
    private let importBadgeLabel = NSTextField(labelWithString: "")

    private var inputCard: HelmCard!
    private var dropZone: LogDropZoneView!
    private let inputTextView = HelmTextView(height: 210, monospaced: true)
    private let sourcePopup = HelmPopUpButton()
    private let modePopup = HelmPopUpButton()
    private var analyzeButton: HelmButton!
    private var clearButton: HelmButton!
    private var clipboardButton: HelmButton!
    private var fileButton: HelmButton!
    private let inputHintLabel = NSTextField(labelWithString: "")

    private let analyzingRow = NSStackView()
    private let analyzingSpinner = NSProgressIndicator()
    private let analyzingLabel = NSTextField(labelWithString: "Analyzing output\u{2026}")

    private let detectionStrip = NSView()
    private let detectionLabel = NSTextField(labelWithString: "")
    private let overridePopup = HelmPopUpButton()

    private var redactionCard: HelmCard!
    private let redactionSummaryLabel = NSTextField(labelWithString: "")
    private var redactionToggleButton: HelmButton!
    private let redactionListStack = NSStackView()

    private var tabs: HelmSegmentedTabs!
    private let tabContainer = NSStackView()
    private var tabViews: [String: NSView] = [:]

    // Analysis tab
    private let rawPane = LogRawPaneView()
    private var rawPaneCard: HelmCard!
    private let rawPaneCountLabel = NSTextField(labelWithString: "")
    private var findingsList: LogAccentRowListView!
    private var findingsCard: HelmCard!
    private var rootCauseCard: HelmCard!
    private let rootCauseSummaryLabel = NSTextField(wrappingLabelWithString: "")
    private let rootCauseExplanationLabel = NSTextField(wrappingLabelWithString: "")
    private let rootCauseConfidencePill = NSView()
    private let rootCauseConfidenceLabel = NSTextField(labelWithString: "")
    private let evidenceStack = NSStackView()
    private let missingEvidenceStack = NSStackView()
    private var nextStepsCard: HelmCard!
    private let nextStepsStack = NSStackView()
    private var commandsCard: HelmCard!
    private let commandsStack = NSStackView()
    private let summaryLabel = NSTextField(wrappingLabelWithString: "")
    private var summaryCard: HelmCard!
    private let aiNoticeLabel = NSTextField(wrappingLabelWithString: "")
    private var aiNoticeCard: HelmCard!

    // Other tabs
    private let groupsList = LogErrorGroupListView()
    private let timelineList = LogTimelineListView()
    private let correlationList = LogCorrelationListView()
    private var evidenceList: LogAccentRowListView!
    private let compareBefore = HelmTextView(height: 150, monospaced: true)
    private let compareAfter = HelmTextView(height: 150, monospaced: true)
    private let compareSummaryLabel = NSTextField(wrappingLabelWithString: "")
    private let compareDiff = DiffResultView()
    private let compareDiffScroll = NSScrollView()
    private var comparePopupBefore: HelmPopUpButton!
    private var comparePopupAfter: HelmPopUpButton!

    // Storage + actions
    private var storageCard: HelmCard!
    private var storageRows: [(view: HoverHighlightView, indicator: NSView, choice: LogStorageChoice)] = []
    private var actionBar: NSStackView!
    private var investigateButton: HelmButton!

    // Investigate-further results
    private var neededEvidenceCard: HelmCard!
    private let neededEvidenceStack = NSStackView()

    // History rail (spec §23)
    private let historyRail = NSView()
    private var historyRailWidth: NSLayoutConstraint!
    private var historyList: LogAccentRowListView!
    private var historyEntries: [LogAnalyzerStore.HistoryEntry] = []
    /// An Investigate-Further answer produced when there was no AI analysis
    /// object to hang it on (a local-only analysis) - see
    /// `renderNeededEvidence`.
    private var pendingNeededEvidence: [String] = []

    /// The suggested-command rows, kept so a theme change can re-apply
    /// their hover fill. Rebuilt (and cleared) on every render of that card
    /// rather than growing unbounded across renders.
    private var commandRowContainers: [HoverHighlightView] = []

    /// Every `HelmCard` on the page, re-themed together (the convention
    /// `ReviewController.cards` established).
    private var cards: [HelmCard] = []
    /// Labels with no other repaint path - see `MutedInkLabels`' own doc
    /// comment on why a registry rather than a system semantic colour.
    private let mutedLabels = MutedInkLabels()

    // MARK: - Lifecycle

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 1100, height: 760))
        root.wantsLayer = true
        view = root

        buildHistoryRail()
        buildMainColumn()

        // Explicit constraints rather than a horizontal `NSStackView`: a
        // horizontal stack has no "fill" alignment, so its children only
        // stretch vertically if something else constrains them - a scroll
        // view in one would collapse to its content height. Both columns are
        // pinned to the full height here instead.
        root.addSubview(scroll)
        root.addSubview(historyRail)
        historyRailWidth = historyRail.widthAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.topAnchor.constraint(equalTo: root.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            scroll.trailingAnchor.constraint(equalTo: historyRail.leadingAnchor),

            historyRail.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            historyRail.topAnchor.constraint(equalTo: root.topAnchor),
            historyRail.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            historyRailWidth,
        ])
        // Collapsed to zero width as well as hidden: an ordinary hidden
        // `NSView`'s constraints still participate in layout (AGENTS.md
        // gotcha (11)), so `isHidden` alone would leave a 320pt dead gutter
        // where the rail used to be.
        historyRail.isHidden = true

        ThemeManager.shared.observe { [weak self, weak root] theme in
            self?.theme = theme
            root?.appearance = NSAppearance(named: theme.mode == .dark ? .darkAqua : .aqua)
            self?.applyTheme()
        }
        applyTheme()
        renderInvestigation()
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        // AGENTS.md gotcha (9): force the pending layout pass before touching
        // the scroll position, so the very first appearance (isHidden was
        // true until now) doesn't rest the short document against the bottom
        // of the clip view.
        view.layoutSubtreeIfNeeded()
        scrollToTop()
        reloadHistory()
    }

    private func scrollToTop() {
        scroll.contentView.scroll(to: .zero)
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    // MARK: - Building: main column

    private func buildMainColumn() {
        // `FlippedView`, not a plain `NSView` - AGENTS.md gotcha (9).
        let content = FlippedView()
        content.translatesAutoresizingMaskIntoConstraints = false

        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = 18
        contentStack.translatesAutoresizingMaskIntoConstraints = false

        let header = buildHeader()
        buildImportBadge()
        let input = buildInputCard()
        buildAnalyzingRow()
        buildDetectionStrip()
        let redaction = buildRedactionCard()
        buildTabs()
        buildTabContent()
        let needed = buildNeededEvidenceCard()
        let storage = buildStorageCard()
        let actions = buildActionBar()

        for view in [header, importBadge, input, analyzingRow, detectionStrip, redaction,
                     tabs as NSView, tabContainer, needed, storage, actions] {
            contentStack.addArrangedSubview(view)
        }

        content.addSubview(contentStack)
        var constraints: [NSLayoutConstraint] = [
            contentStack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: HelmMetrics.pageGutter),
            contentStack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -HelmMetrics.pageGutter),
            contentStack.topAnchor.constraint(equalTo: content.topAnchor, constant: 24),
            contentStack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -28),
        ]
        // Every section fills the column - a stack's arranged subviews
        // otherwise size to their own content at `.leading` alignment.
        // Deliberately not `tabs`: `HelmSegmentedTabs` is a capsule that
        // sizes to its own pills on every other page that uses it (Shift,
        // Docs, Hosts, Setup) - stretching it across the full column would
        // make this one page's sub-nav look unlike all of them.
        for view in [headerRow as NSView, importBadge, input, detectionStrip, redaction,
                     tabContainer, needed, storage, actions] {
            constraints.append(view.widthAnchor.constraint(equalTo: contentStack.widthAnchor))
        }
        NSLayoutConstraint.activate(constraints)

        scroll.documentView = content
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        // AGENTS.md gotcha (4): the clip view, never the outer scroll view.
        NSLayoutConstraint.activate([
            content.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
        ])
    }

    private func buildHeader() -> NSView {
        heroLabel.font = HelmType.pageTitle(.serif)
        heroLabel.translatesAutoresizingMaskIntoConstraints = false
        subtitleLabel.font = HelmType.body()
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        _ = mutedLabels.add(subtitleLabel)

        let textStack = NSStackView(views: [heroLabel, subtitleLabel])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 4
        textStack.translatesAutoresizingMaskIntoConstraints = false
        textStack.setHuggingPriority(.defaultLow, for: .horizontal)

        historyToggleButton = HelmButton(title: "History", variant: .quiet, symbol: "clock.arrow.circlepath",
                                         target: self, action: #selector(toggleHistory))
        historyToggleButton.toolTip = "Show past investigations"
        newInvestigationButton = HelmButton(title: "New", variant: .quiet, symbol: "plus",
                                            target: self, action: #selector(newInvestigation))
        newInvestigationButton.toolTip = "Start a fresh investigation"

        // AGENTS.md gotcha (12): a spacer with no intrinsic size needs a real
        // low-priority zero-width constraint, not a hugging priority, to be
        // the thing that stretches.
        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        spacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        for button in [historyToggleButton!, newInvestigationButton!] {
            button.setContentHuggingPriority(.required, for: .horizontal)
            button.setContentCompressionResistancePriority(.required, for: .horizontal)
        }

        let row = NSStackView(views: [textStack, spacer, newInvestigationButton, historyToggleButton])
        row.orientation = .horizontal
        row.alignment = .lastBaseline
        row.distribution = .fill
        row.spacing = 10
        row.translatesAutoresizingMaskIntoConstraints = false
        headerRow = row
        return row
    }

    /// Spec §2's terminal bridge shows where the current input came from.
    private func buildImportBadge() {
        importBadge.wantsLayer = true
        importBadge.layer?.cornerRadius = HelmMetrics.rChip
        importBadge.translatesAutoresizingMaskIntoConstraints = false
        importBadgeLabel.font = HelmType.caption()
        importBadgeLabel.lineBreakMode = .byWordWrapping
        importBadgeLabel.maximumNumberOfLines = 3
        importBadgeLabel.translatesAutoresizingMaskIntoConstraints = false

        let tile = IconTileView(size: HelmMetrics.tileSmall, cornerRadius: HelmMetrics.tileSmall / 2)
        tile.configure(symbol: "terminal", tint: .violet, pointSize: 11)

        let row = NSStackView(views: [tile, importBadgeLabel])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.distribution = .fill
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false
        tile.setContentHuggingPriority(.required, for: .horizontal)
        importBadgeLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        importBadge.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: importBadge.leadingAnchor, constant: 10),
            row.trailingAnchor.constraint(equalTo: importBadge.trailingAnchor, constant: -10),
            row.topAnchor.constraint(equalTo: importBadge.topAnchor, constant: 8),
            row.bottomAnchor.constraint(equalTo: importBadge.bottomAnchor, constant: -8),
        ])
        importBadge.isHidden = true
    }

    private func buildInputCard() -> NSView {
        inputCard = HelmCard()
        _ = inputCard.setHeader(symbol: "text.magnifyingglass", tint: .accent, title: "Analyze output",
                                subtitle: "Paste logs, terminal output, stack traces or errors — or drop a .log/.txt/.json/.yaml file here.")

        inputTextView.textView.delegate = self

        for popup in [sourcePopup, modePopup] {
            popup.translatesAutoresizingMaskIntoConstraints = false
            popup.setContentHuggingPriority(.required, for: .horizontal)
            popup.setContentCompressionResistancePriority(.required, for: .horizontal)
        }
        sourcePopup.addItem(withTitle: "Source: Auto Detect")
        for kind in LogSourceKind.pickerOrder { sourcePopup.addItem(withTitle: "Source: \(kind.displayName)") }
        sourcePopup.target = self
        sourcePopup.action = #selector(sourceChanged)

        for analysisMode in LogAnalysisMode.allCases { modePopup.addItem(withTitle: analysisMode.displayName) }
        modePopup.target = self
        modePopup.action = #selector(modeChanged)
        modePopup.toolTip = "Analysis mode — changes what the analysis emphasises (spec §22)"

        analyzeButton = HelmButton(title: "Analyze", variant: .primary, symbol: "sparkles",
                                   target: self, action: #selector(analyzeTapped))
        // Spec §24's ⌘Enter. `keyEquivalent` on an unbordered `HelmButton`
        // keeps the shortcut without the system-blue default-button look -
        // see `HelmButton`'s own header.
        analyzeButton.keyEquivalent = "\r"
        analyzeButton.keyEquivalentModifierMask = [.command]
        clearButton = HelmButton(title: "Clear", variant: .secondary, target: self, action: #selector(clearTapped))
        clipboardButton = HelmButton(title: "Analyze Clipboard", variant: .secondary, symbol: "list.clipboard",
                                     target: self, action: #selector(analyzeClipboard))
        fileButton = HelmButton(title: "Add File", variant: .secondary, symbol: "doc.badge.plus",
                                target: self, action: #selector(addFileTapped))

        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        spacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        for button in [clipboardButton!, fileButton!, clearButton!, analyzeButton!] {
            button.setContentHuggingPriority(.required, for: .horizontal)
            button.setContentCompressionResistancePriority(.required, for: .horizontal)
        }

        let controls = NSStackView(views: [sourcePopup, modePopup, spacer,
                                           clipboardButton, fileButton, clearButton, analyzeButton])
        controls.orientation = .horizontal
        controls.alignment = .centerY
        controls.distribution = .fill
        controls.spacing = 8
        controls.translatesAutoresizingMaskIntoConstraints = false

        inputHintLabel.font = HelmType.caption()
        inputHintLabel.stringValue = "⌘↵ analyze · ⌘⇧C copy analysis · ⌘⇧T send top command to terminal · "
            + "⌘⇧I investigate further · ⌘⇧A create RCA · Esc clear"
        inputHintLabel.lineBreakMode = .byTruncatingTail
        inputHintLabel.translatesAutoresizingMaskIntoConstraints = false
        _ = mutedLabels.add(inputHintLabel)

        let body = NSStackView(views: [inputTextView, controls, inputHintLabel])
        body.orientation = .vertical
        body.alignment = .leading
        body.spacing = 10
        body.translatesAutoresizingMaskIntoConstraints = false

        dropZone = LogDropZoneView()
        dropZone.onDropFiles = { [weak self] urls in self?.importFiles(urls) }
        dropZone.translatesAutoresizingMaskIntoConstraints = false
        dropZone.addSubview(body)
        NSLayoutConstraint.activate([
            body.leadingAnchor.constraint(equalTo: dropZone.leadingAnchor),
            body.trailingAnchor.constraint(equalTo: dropZone.trailingAnchor),
            body.topAnchor.constraint(equalTo: dropZone.topAnchor),
            body.bottomAnchor.constraint(equalTo: dropZone.bottomAnchor),
            inputTextView.widthAnchor.constraint(equalTo: body.widthAnchor),
            controls.widthAnchor.constraint(equalTo: body.widthAnchor),
            inputHintLabel.widthAnchor.constraint(equalTo: body.widthAnchor),
        ])

        inputCard.setBody(dropZone, insets: HelmCard.contentInsets)
        cards.append(inputCard)
        return inputCard
    }

    private func buildAnalyzingRow() {
        analyzingSpinner.style = .spinning
        analyzingSpinner.isIndeterminate = true
        analyzingSpinner.controlSize = .small
        analyzingSpinner.translatesAutoresizingMaskIntoConstraints = false
        analyzingLabel.font = HelmType.body()
        analyzingLabel.translatesAutoresizingMaskIntoConstraints = false
        _ = mutedLabels.add(analyzingLabel)

        analyzingRow.orientation = .horizontal
        analyzingRow.alignment = .centerY
        analyzingRow.distribution = .fill
        analyzingRow.spacing = 10
        analyzingRow.translatesAutoresizingMaskIntoConstraints = false
        analyzingRow.addArrangedSubview(analyzingSpinner)
        analyzingRow.addArrangedSubview(analyzingLabel)
        analyzingRow.isHidden = true
    }

    /// Spec §3's detection strip, with the override control beside it.
    private func buildDetectionStrip() {
        detectionStrip.wantsLayer = true
        detectionStrip.layer?.cornerRadius = HelmMetrics.rControl
        detectionStrip.translatesAutoresizingMaskIntoConstraints = false

        detectionLabel.font = HelmType.body()
        detectionLabel.lineBreakMode = .byTruncatingTail
        detectionLabel.translatesAutoresizingMaskIntoConstraints = false
        detectionLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        overridePopup.translatesAutoresizingMaskIntoConstraints = false
        overridePopup.addItem(withTitle: "Auto Detect")
        for kind in LogSourceKind.pickerOrder { overridePopup.addItem(withTitle: kind.displayName) }
        overridePopup.target = self
        overridePopup.action = #selector(overrideChanged)
        overridePopup.setContentHuggingPriority(.required, for: .horizontal)
        overridePopup.setContentCompressionResistancePriority(.required, for: .horizontal)

        let tile = IconTileView(size: HelmMetrics.tileSmall, cornerRadius: HelmMetrics.tileSmall / 2)
        tile.configure(symbol: "scope", tint: .info, pointSize: 11)
        tile.setContentHuggingPriority(.required, for: .horizontal)

        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        spacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let row = NSStackView(views: [tile, detectionLabel, spacer, overridePopup])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.distribution = .fill
        row.spacing = 10
        row.translatesAutoresizingMaskIntoConstraints = false

        detectionStrip.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: detectionStrip.leadingAnchor, constant: 12),
            row.trailingAnchor.constraint(equalTo: detectionStrip.trailingAnchor, constant: -12),
            row.topAnchor.constraint(equalTo: detectionStrip.topAnchor, constant: 8),
            row.bottomAnchor.constraint(equalTo: detectionStrip.bottomAnchor, constant: -8),
        ])
        detectionStrip.isHidden = true
    }

    /// Spec §14's review affordance: the count, plus an expandable
    /// before/after list. Nothing here shows a secret value - the "before"
    /// side is a non-reversible fingerprint (see `LogRedaction`).
    private func buildRedactionCard() -> NSView {
        redactionCard = HelmCard()
        redactionSummaryLabel.font = HelmType.body()
        redactionSummaryLabel.lineBreakMode = .byWordWrapping
        redactionSummaryLabel.maximumNumberOfLines = 3
        redactionSummaryLabel.translatesAutoresizingMaskIntoConstraints = false
        redactionToggleButton = HelmButton(title: "View Redactions", variant: .secondary, size: .small,
                                           target: self, action: #selector(toggleRedactions))
        redactionToggleButton.setContentHuggingPriority(.required, for: .horizontal)

        _ = redactionCard.setHeader(symbol: "eye.slash", tint: .warn,
                                    titleLabel: redactionSummaryLabel,
                                    subtitleLabel: nil,
                                    actions: [redactionToggleButton])

        redactionListStack.orientation = .vertical
        redactionListStack.alignment = .leading
        redactionListStack.spacing = 8
        redactionListStack.translatesAutoresizingMaskIntoConstraints = false
        redactionCard.setBody(redactionListStack, insets: HelmCard.contentInsets)
        redactionCard.isHidden = true
        cards.append(redactionCard)
        return redactionCard
    }

    private func buildTabs() {
        tabs = HelmSegmentedTabs(items: [
            .init(id: "analysis", title: "Analysis"),
            .init(id: "groups", title: "Error Groups"),
            .init(id: "timeline", title: "Timeline"),
            .init(id: "correlation", title: "Correlation"),
            .init(id: "compare", title: "Compare"),
            .init(id: "evidence", title: "Evidence"),
        ], selected: "analysis")
        tabs.onSelect = { [weak self] id in self?.selectTab(id) }
        tabs.translatesAutoresizingMaskIntoConstraints = false
    }

    private func buildTabContent() {
        // An `NSStackView`, not a plain container: a hidden *arranged
        // subview* is excluded from layout entirely, whereas an ordinary
        // hidden `NSView` still participates (AGENTS.md gotcha (11)) - which
        // would leave every short tab rendering inside a container as tall
        // as the 620pt Analysis tab.
        tabContainer.orientation = .vertical
        tabContainer.alignment = .leading
        tabContainer.spacing = 0
        tabContainer.translatesAutoresizingMaskIntoConstraints = false

        let analysis = buildAnalysisTab()
        let groups = buildSimpleTab(symbol: "list.bullet.rectangle", tint: .critical,
                                    title: "Grouped patterns",
                                    subtitle: "Repeated lines collapsed into one pattern — click a pattern to see its matching lines.",
                                    body: groupsList)
        let timeline = buildSimpleTab(symbol: "clock", tint: .info,
                                      title: "Event timeline",
                                      subtitle: "Reconstructed only from timestamps present in the provided output.",
                                      body: timelineList)
        let correlation = buildCorrelationTab()
        let compare = buildCompareTab()
        let evidence = buildEvidenceTab()

        tabViews = ["analysis": analysis, "groups": groups, "timeline": timeline,
                    "correlation": correlation, "compare": compare, "evidence": evidence]

        // Fixed order, so the rendered stack doesn't depend on dictionary
        // iteration order (only one is ever visible, but a stable order
        // keeps a probe or a future multi-visible mode predictable).
        for id in ["analysis", "groups", "timeline", "correlation", "compare", "evidence"] {
            guard let tabView = tabViews[id] else { continue }
            tabView.translatesAutoresizingMaskIntoConstraints = false
            tabContainer.addArrangedSubview(tabView)
            tabView.widthAnchor.constraint(equalTo: tabContainer.widthAnchor).isActive = true
            tabView.isHidden = id != "analysis"
        }
    }

    private func buildSimpleTab(symbol: String, tint: HelmTint, title: String, subtitle: String, body: NSView) -> NSView {
        let card = HelmCard()
        _ = card.setHeader(symbol: symbol, tint: tint, title: title, subtitle: subtitle)
        card.setBody(body, insets: HelmCard.contentInsets)
        cards.append(card)
        return card
    }

    private func buildAnalysisTab() -> NSView {
        // Left: the raw input pane.
        rawPaneCard = HelmCard()
        rawPaneCountLabel.font = HelmType.caption()
        rawPaneCountLabel.translatesAutoresizingMaskIntoConstraints = false
        rawPaneCountLabel.setContentHuggingPriority(.required, for: .horizontal)
        _ = mutedLabels.add(rawPaneCountLabel)
        _ = rawPaneCard.setHeader(symbol: "doc.plaintext", tint: .neutral, title: "Provided output",
                                  subtitle: "Read-only · secrets already redacted",
                                  actions: [rawPaneCountLabel])
        let paneHost = NSView()
        paneHost.translatesAutoresizingMaskIntoConstraints = false
        paneHost.addSubview(rawPane)
        NSLayoutConstraint.activate([
            rawPane.leadingAnchor.constraint(equalTo: paneHost.leadingAnchor),
            rawPane.trailingAnchor.constraint(equalTo: paneHost.trailingAnchor),
            rawPane.topAnchor.constraint(equalTo: paneHost.topAnchor),
            rawPane.bottomAnchor.constraint(equalTo: paneHost.bottomAnchor),
            paneHost.heightAnchor.constraint(equalToConstant: 620),
        ])
        rawPaneCard.setBody(paneHost, insets: NSEdgeInsets())
        cards.append(rawPaneCard)

        // Right: the structured read.
        summaryCard = HelmCard()
        summaryLabel.font = HelmType.body()
        summaryLabel.translatesAutoresizingMaskIntoConstraints = false
        _ = summaryCard.setHeader(symbol: "text.alignleft", tint: .info, title: "Summary")
        summaryCard.setBody(summaryLabel, insets: HelmCard.contentInsets)
        cards.append(summaryCard)

        aiNoticeCard = HelmCard()
        aiNoticeLabel.font = HelmType.body()
        aiNoticeLabel.translatesAutoresizingMaskIntoConstraints = false
        _ = aiNoticeCard.setHeader(symbol: "exclamationmark.triangle", tint: .warn, title: "AI analysis unavailable")
        aiNoticeCard.setBody(aiNoticeLabel, insets: HelmCard.contentInsets)
        aiNoticeCard.isHidden = true
        cards.append(aiNoticeCard)

        findingsList = LogAccentRowListView(rowHeight: 72, emptySymbol: "checkmark.seal",
                                            emptyTitle: "No findings yet",
                                            emptyBody: "Paste output above and press Analyze.")
        findingsCard = HelmCard()
        _ = findingsCard.setHeader(symbol: "exclamationmark.octagon", tint: .critical, title: "Findings",
                                   subtitle: "Highest severity first")
        findingsCard.setBody(findingsList, insets: HelmCard.contentInsets)
        cards.append(findingsCard)

        rootCauseCard = buildRootCauseCard()
        nextStepsCard = buildNextStepsCard()
        commandsCard = buildCommandsCard()

        let rightColumn = NSStackView(views: [summaryCard, aiNoticeCard, findingsCard,
                                              rootCauseCard, nextStepsCard, commandsCard])
        rightColumn.orientation = .vertical
        rightColumn.alignment = .leading
        rightColumn.spacing = 14
        rightColumn.translatesAutoresizingMaskIntoConstraints = false
        for card in [summaryCard!, aiNoticeCard!, findingsCard!, rootCauseCard!, nextStepsCard!, commandsCard!] {
            card.widthAnchor.constraint(equalTo: rightColumn.widthAnchor).isActive = true
        }

        let split = NSStackView(views: [rawPaneCard, rightColumn])
        split.orientation = .horizontal
        split.distribution = .fill
        split.alignment = .top
        split.spacing = 14
        split.translatesAutoresizingMaskIntoConstraints = false
        // The raw pane takes a fixed proportion; the analysis column absorbs
        // the rest. `.defaultHigh` (not required) so a very narrow window
        // can still resolve without breaking - and well under
        // `NSLayoutPriorityWindowSizeStayPut` (500), per AGENTS.md gotcha (13):
        // no content constraint on this page may drive the window's own size.
        let proportion = rawPaneCard.widthAnchor.constraint(equalTo: split.widthAnchor, multiplier: 0.38)
        proportion.priority = NSLayoutConstraint.Priority(499)
        proportion.isActive = true
        rawPaneCard.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        rightColumn.setHuggingPriority(.defaultLow, for: .horizontal)
        return split
    }

    private func buildRootCauseCard() -> HelmCard {
        let card = HelmCard()
        rootCauseConfidenceLabel.font = HelmType.kicker()
        rootCauseConfidenceLabel.translatesAutoresizingMaskIntoConstraints = false
        rootCauseConfidencePill.wantsLayer = true
        rootCauseConfidencePill.layer?.cornerRadius = HelmMetrics.rChip
        rootCauseConfidencePill.translatesAutoresizingMaskIntoConstraints = false
        rootCauseConfidencePill.addSubview(rootCauseConfidenceLabel)
        NSLayoutConstraint.activate([
            rootCauseConfidenceLabel.leadingAnchor.constraint(equalTo: rootCauseConfidencePill.leadingAnchor, constant: 8),
            rootCauseConfidenceLabel.trailingAnchor.constraint(equalTo: rootCauseConfidencePill.trailingAnchor, constant: -8),
            rootCauseConfidenceLabel.topAnchor.constraint(equalTo: rootCauseConfidencePill.topAnchor, constant: 3),
            rootCauseConfidenceLabel.bottomAnchor.constraint(equalTo: rootCauseConfidencePill.bottomAnchor, constant: -3),
        ])
        rootCauseConfidencePill.setContentHuggingPriority(.required, for: .horizontal)

        let copyButton = HelmButton(title: "Copy", variant: .quiet, size: .small, symbol: "doc.on.doc",
                                    target: self, action: #selector(copyRootCause))
        copyButton.toolTip = "Copy Root Cause"
        copyButton.setContentHuggingPriority(.required, for: .horizontal)

        _ = card.setHeader(symbol: "target", tint: .accent, title: "Probable root cause",
                           actions: [rootCauseConfidencePill, copyButton])

        rootCauseSummaryLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        rootCauseSummaryLabel.translatesAutoresizingMaskIntoConstraints = false
        rootCauseExplanationLabel.font = HelmType.body()
        rootCauseExplanationLabel.translatesAutoresizingMaskIntoConstraints = false
        _ = mutedLabels.add(rootCauseExplanationLabel)

        for stack in [evidenceStack, missingEvidenceStack] {
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.spacing = 4
            stack.translatesAutoresizingMaskIntoConstraints = false
        }

        let body = NSStackView(views: [rootCauseSummaryLabel, rootCauseExplanationLabel,
                                       evidenceStack, missingEvidenceStack])
        body.orientation = .vertical
        body.alignment = .leading
        body.spacing = 10
        body.translatesAutoresizingMaskIntoConstraints = false
        for sub in [rootCauseSummaryLabel as NSView, rootCauseExplanationLabel, evidenceStack, missingEvidenceStack] {
            sub.widthAnchor.constraint(equalTo: body.widthAnchor).isActive = true
        }
        card.setBody(body, insets: HelmCard.contentInsets)
        cards.append(card)
        return card
    }

    private func buildNextStepsCard() -> HelmCard {
        let card = HelmCard()
        let copyButton = HelmButton(title: "Copy", variant: .quiet, size: .small, symbol: "doc.on.doc",
                                    target: self, action: #selector(copyNextSteps))
        copyButton.toolTip = "Copy Next Steps"
        copyButton.setContentHuggingPriority(.required, for: .horizontal)
        _ = card.setHeader(symbol: "list.number", tint: .good, title: "Recommended next steps",
                           actions: [copyButton])
        nextStepsStack.orientation = .vertical
        nextStepsStack.alignment = .leading
        nextStepsStack.spacing = 6
        nextStepsStack.translatesAutoresizingMaskIntoConstraints = false
        card.setBody(nextStepsStack, insets: HelmCard.contentInsets)
        cards.append(card)
        return card
    }

    private func buildCommandsCard() -> HelmCard {
        let card = HelmCard()
        _ = card.setHeader(symbol: "chevron.left.forwardslash.chevron.right", tint: .violet,
                           title: "Suggested commands",
                           subtitle: "Your own saved commands are preferred over generated ones.")
        commandsStack.orientation = .vertical
        commandsStack.alignment = .leading
        commandsStack.spacing = 8
        commandsStack.translatesAutoresizingMaskIntoConstraints = false
        card.setBody(commandsStack, insets: HelmCard.contentInsets)
        cards.append(card)
        return card
    }

    private func buildCorrelationTab() -> NSView {
        let card = HelmCard()
        _ = card.setHeader(symbol: "arrow.triangle.branch", tint: .warn, title: "Correlation chain",
                           subtitle: "What the provided output confirms, versus what is inferred or still unknown.")

        let legend = NSStackView(views: LogCorrelationKind.allCases.map { legendChip(for: $0) })
        legend.orientation = .horizontal
        legend.alignment = .centerY
        legend.distribution = .fill
        legend.spacing = 10
        legend.translatesAutoresizingMaskIntoConstraints = false

        let body = NSStackView(views: [legend, correlationList])
        body.orientation = .vertical
        body.alignment = .leading
        body.spacing = 12
        body.translatesAutoresizingMaskIntoConstraints = false
        correlationList.widthAnchor.constraint(equalTo: body.widthAnchor).isActive = true
        card.setBody(body, insets: HelmCard.contentInsets)
        cards.append(card)
        return card
    }

    private var legendChips: [(pill: NSView, label: NSTextField, kind: LogCorrelationKind)] = []

    private func legendChip(for kind: LogCorrelationKind) -> NSView {
        let pill = NSView()
        pill.translatesAutoresizingMaskIntoConstraints = false
        let label = NSTextField(labelWithString: "\(kind.displayName) — \(kind.detail)")
        label.font = HelmType.caption()
        label.translatesAutoresizingMaskIntoConstraints = false
        ToolRowLayout.pill(text: "\(kind.displayName) — \(kind.detail)",
                           colorHex: kind.tint.hex(in: theme),
                           into: pill, label: label, theme: theme)
        legendChips.append((pill, label, kind))
        pill.setContentHuggingPriority(.required, for: .horizontal)
        return pill
    }

    /// Spec §20/§21. Reuses `DiffEngine` (via `LogAnalyzerArtifacts.compare`)
    /// and the Tools page's own `DiffResultView` renderer - no second diff.
    private func buildCompareTab() -> NSView {
        let card = HelmCard()
        _ = card.setHeader(symbol: "arrow.left.arrow.right", tint: .info, title: "Compare two outputs",
                           subtitle: "Before vs. after a deploy, healthy vs. unhealthy pod, prod vs. UAT — the analyzer reports which errors are new, resolved, or worse.")

        comparePopupBefore = HelmPopUpButton()
        comparePopupAfter = HelmPopUpButton()
        for popup in [comparePopupBefore!, comparePopupAfter!] {
            popup.translatesAutoresizingMaskIntoConstraints = false
            popup.setContentHuggingPriority(.required, for: .horizontal)
            popup.target = self
            popup.action = #selector(comparePickerChanged(_:))
        }

        let beforeLabel = fieldLabel("Before")
        let afterLabel = fieldLabel("After")

        let compareButton = HelmButton(title: "Analyze Differences", variant: .primary, symbol: "arrow.left.arrow.right",
                                       target: self, action: #selector(runCompare))
        let copyButton = HelmButton(title: "Copy comparison", variant: .quiet, size: .small, symbol: "doc.on.doc",
                                    target: self, action: #selector(copyComparison))
        for button in [compareButton, copyButton] {
            button.setContentHuggingPriority(.required, for: .horizontal)
        }

        compareSummaryLabel.font = HelmType.body()
        compareSummaryLabel.stringValue = "Paste or pick two outputs, then press Analyze Differences."
        compareSummaryLabel.translatesAutoresizingMaskIntoConstraints = false
        _ = mutedLabels.add(compareSummaryLabel)

        compareDiffScroll.documentView = compareDiff.tableView
        compareDiffScroll.hasVerticalScroller = true
        compareDiffScroll.drawsBackground = false
        compareDiffScroll.borderType = .noBorder
        compareDiffScroll.translatesAutoresizingMaskIntoConstraints = false
        compareDiffScroll.heightAnchor.constraint(equalToConstant: 300).isActive = true

        let beforeColumn = NSStackView(views: [beforeLabel, comparePopupBefore, compareBefore])
        let afterColumn = NSStackView(views: [afterLabel, comparePopupAfter, compareAfter])
        for column in [beforeColumn, afterColumn] {
            column.orientation = .vertical
            column.alignment = .leading
            column.spacing = 6
            column.translatesAutoresizingMaskIntoConstraints = false
        }
        compareBefore.widthAnchor.constraint(equalTo: beforeColumn.widthAnchor).isActive = true
        compareAfter.widthAnchor.constraint(equalTo: afterColumn.widthAnchor).isActive = true
        comparePopupBefore.widthAnchor.constraint(equalTo: beforeColumn.widthAnchor).isActive = true
        comparePopupAfter.widthAnchor.constraint(equalTo: afterColumn.widthAnchor).isActive = true

        let columns = NSStackView(views: [beforeColumn, afterColumn])
        columns.orientation = .horizontal
        columns.distribution = .fillEqually
        columns.alignment = .top
        columns.spacing = 12
        columns.translatesAutoresizingMaskIntoConstraints = false

        let buttonSpacer = NSView()
        buttonSpacer.translatesAutoresizingMaskIntoConstraints = false
        buttonSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let buttonRow = NSStackView(views: [compareButton, copyButton, buttonSpacer])
        buttonRow.orientation = .horizontal
        buttonRow.distribution = .fill
        buttonRow.alignment = .centerY
        buttonRow.spacing = 8
        buttonRow.translatesAutoresizingMaskIntoConstraints = false

        let body = NSStackView(views: [columns, buttonRow, compareSummaryLabel, compareDiffScroll])
        body.orientation = .vertical
        body.alignment = .leading
        body.spacing = 12
        body.translatesAutoresizingMaskIntoConstraints = false
        for sub in [columns as NSView, buttonRow, compareSummaryLabel, compareDiffScroll] {
            sub.widthAnchor.constraint(equalTo: body.widthAnchor).isActive = true
        }
        card.setBody(body, insets: HelmCard.contentInsets)
        cards.append(card)
        return card
    }

    /// Spec §13's multi-input investigation.
    private func buildEvidenceTab() -> NSView {
        let card = HelmCard()
        let addPaste = HelmButton(title: "Add pasted text", variant: .secondary, size: .small, symbol: "plus",
                                  target: self, action: #selector(addCurrentInputAsEvidence))
        let addFile = HelmButton(title: "Add file", variant: .secondary, size: .small, symbol: "doc.badge.plus",
                                 target: self, action: #selector(addFileTapped))
        let addClipboard = HelmButton(title: "Add clipboard", variant: .secondary, size: .small, symbol: "list.clipboard",
                                      target: self, action: #selector(addClipboardAsEvidence))
        // Spec §16's "[Copy Evidence]".
        let copyEvidenceButton = HelmButton(title: "Copy", variant: .quiet, size: .small, symbol: "doc.on.doc",
                                            target: self, action: #selector(copyEvidence))
        copyEvidenceButton.toolTip = "Copy Evidence"
        for button in [addPaste, addFile, addClipboard, copyEvidenceButton] {
            button.setContentHuggingPriority(.required, for: .horizontal)
        }
        _ = card.setHeader(symbol: "tray.full", tint: .violet, title: "Evidence",
                           subtitle: "Every piece keeps its own source. Analysis runs over the combined set.",
                           actions: [addPaste, addFile, addClipboard, copyEvidenceButton])

        evidenceList = LogAccentRowListView(rowHeight: 74, emptySymbol: "tray",
                                            emptyTitle: "No evidence yet",
                                            emptyBody: "Paste output above, drop a file, or send output from a host's Console page.")
        evidenceList.onSelect = { [weak self] index in self?.removeEvidence(at: index) }
        card.setBody(evidenceList, insets: HelmCard.contentInsets)
        cards.append(card)
        return card
    }

    /// Spec §12's answer panel - hidden until "Investigate Further" runs.
    private func buildNeededEvidenceCard() -> NSView {
        neededEvidenceCard = HelmCard()
        let pasteMore = HelmButton(title: "Paste More Logs", variant: .secondary, size: .small,
                                   target: self, action: #selector(focusInput))
        let addFile = HelmButton(title: "Add File", variant: .secondary, size: .small,
                                 target: self, action: #selector(addFileTapped))
        let fromClipboard = HelmButton(title: "Add Clipboard", variant: .secondary, size: .small,
                                       target: self, action: #selector(addClipboardAsEvidence))
        let fromTerminal = HelmButton(title: "Send Terminal Output", variant: .secondary, size: .small,
                                      target: self, action: #selector(goToConsole))
        fromTerminal.toolTip = "Open the Console — its \u{201C}Analyze Logs\u{201D} button sends output back here"
        for button in [pasteMore, addFile, fromClipboard, fromTerminal] {
            button.setContentHuggingPriority(.required, for: .horizontal)
        }
        _ = neededEvidenceCard.setHeader(symbol: "questionmark.circle", tint: .info,
                                         title: "To confirm the root cause, this is what's still needed",
                                         actions: [pasteMore, addFile, fromClipboard, fromTerminal])
        neededEvidenceStack.orientation = .vertical
        neededEvidenceStack.alignment = .leading
        neededEvidenceStack.spacing = 6
        neededEvidenceStack.translatesAutoresizingMaskIntoConstraints = false
        neededEvidenceCard.setBody(neededEvidenceStack, insets: HelmCard.contentInsets)
        neededEvidenceCard.isHidden = true
        cards.append(neededEvidenceCard)
        return neededEvidenceCard
    }

    /// Spec §15 - three options, defaulting to "Do not save".
    private func buildStorageCard() -> NSView {
        storageCard = HelmCard()
        _ = storageCard.setHeader(symbol: "externaldrive", tint: .neutral, title: "Save this investigation?",
                                  subtitle: "Nothing leaves this machine unless you choose to keep it.")

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false

        for choice in LogStorageChoice.allCases {
            let row = storageOptionRow(choice)
            stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        storageCard.setBody(stack, insets: HelmCard.contentInsets)
        cards.append(storageCard)
        return storageCard
    }

    /// A clickable styled row rather than a stock `NSButton(.radio)` - the
    /// same "hand-rolled selectable card" pattern `SettingsController.themeCard`
    /// established, so it themes with the app instead of rendering system
    /// chrome next to a page full of `HelmCard`s.
    private func storageOptionRow(_ choice: LogStorageChoice) -> HoverHighlightView {
        let container = HoverHighlightView()
        container.cornerRadius = HelmMetrics.rRow
        container.translatesAutoresizingMaskIntoConstraints = false

        let indicator = NSView()
        indicator.wantsLayer = true
        indicator.layer?.cornerRadius = 7
        indicator.layer?.borderWidth = 1.5
        indicator.translatesAutoresizingMaskIntoConstraints = false
        indicator.setContentHuggingPriority(.required, for: .horizontal)

        let title = NSTextField(labelWithString: choice.displayName)
        title.font = HelmType.rowTitle()
        title.translatesAutoresizingMaskIntoConstraints = false
        let detail = NSTextField(wrappingLabelWithString: choice.detail)
        detail.font = HelmType.caption()
        detail.translatesAutoresizingMaskIntoConstraints = false
        _ = mutedLabels.add(detail)

        let text = NSStackView(views: [title, detail])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 2
        text.translatesAutoresizingMaskIntoConstraints = false
        text.setHuggingPriority(.defaultLow, for: .horizontal)

        let row = NSStackView(views: [indicator, text])
        row.orientation = .horizontal
        row.alignment = .top
        row.distribution = .fill
        row.spacing = 10
        row.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(row)
        NSLayoutConstraint.activate([
            indicator.widthAnchor.constraint(equalToConstant: 14),
            indicator.heightAnchor.constraint(equalToConstant: 14),
            row.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 10),
            row.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -10),
            row.topAnchor.constraint(equalTo: container.topAnchor, constant: 8),
            row.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -8),
        ])

        let click = NSClickGestureRecognizer(target: self, action: #selector(storageRowClicked(_:)))
        container.addGestureRecognizer(click)
        container.identifier = NSUserInterfaceItemIdentifier(choice.rawValue)
        storageRows.append((container, indicator, choice))
        return container
    }

    /// Spec §16-§21's action row.
    private func buildActionBar() -> NSView {
        investigateButton = HelmButton(title: "Investigate Further", variant: .primary, symbol: "magnifyingglass",
                                       target: self, action: #selector(investigateFurther))
        let incident = HelmButton(title: "Create Incident", variant: .secondary, symbol: "doc.text",
                                  target: self, action: #selector(createIncident))
        let runbook = HelmButton(title: "Create Runbook", variant: .secondary, symbol: "book.closed",
                                 target: self, action: #selector(createRunbook))
        let ticket = HelmButton(title: "Create Ticket", variant: .secondary, symbol: "ticket",
                                target: self, action: #selector(createTicket))
        let copyAll = HelmButton(title: "Copy Full Analysis", variant: .quiet, symbol: "doc.on.doc",
                                 target: self, action: #selector(copyFullAnalysis))
        let compareShortcut = HelmButton(title: "Compare", variant: .quiet, symbol: "arrow.left.arrow.right",
                                         target: self, action: #selector(showCompareTab))

        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        spacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let buttons: [HelmButton] = [investigateButton, incident, runbook, ticket, compareShortcut, copyAll]
        for button in buttons {
            button.setContentHuggingPriority(.required, for: .horizontal)
            button.setContentCompressionResistancePriority(.required, for: .horizontal)
        }

        let bar = NSStackView(views: buttons.map { $0 as NSView } + [spacer])
        bar.orientation = .horizontal
        bar.alignment = .centerY
        bar.distribution = .fill
        bar.spacing = 8
        bar.translatesAutoresizingMaskIntoConstraints = false
        actionBar = bar
        return bar
    }

    // MARK: - Building: history rail (spec §23)

    private func buildHistoryRail() {
        historyRail.wantsLayer = true
        historyRail.translatesAutoresizingMaskIntoConstraints = false
        // `historyRailWidth` is created and activated in `loadView`,
        // alongside the two columns' own pinning - see the note there on why
        // it collapses to 0 rather than only hiding.

        let title = NSTextField(labelWithString: "Investigation history")
        title.font = HelmType.sectionTitle()
        title.translatesAutoresizingMaskIntoConstraints = false

        let close = HelmButton(symbol: "chevron.right", variant: .quiet, size: .small,
                               target: self, action: #selector(toggleHistory))
        close.toolTip = "Hide history"
        close.setContentHuggingPriority(.required, for: .horizontal)

        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let headerRow = NSStackView(views: [title, spacer, close])
        headerRow.orientation = .horizontal
        headerRow.distribution = .fill
        headerRow.alignment = .centerY
        headerRow.spacing = 8
        headerRow.translatesAutoresizingMaskIntoConstraints = false

        historyList = LogAccentRowListView(rowHeight: 74, emptySymbol: "clock",
                                           emptyTitle: "No saved investigations",
                                           emptyBody: "Investigations are only kept when you choose a storage option other than \u{201C}Do not save\u{201D}.")
        historyList.onSelect = { [weak self] index in self?.openHistoryEntry(at: index) }

        let historyScroll = NSScrollView()
        let historyContent = FlippedView()
        historyContent.translatesAutoresizingMaskIntoConstraints = false
        let column = NSStackView(views: [headerRow, historyList])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 12
        column.translatesAutoresizingMaskIntoConstraints = false
        historyContent.addSubview(column)
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: historyContent.leadingAnchor, constant: 14),
            column.trailingAnchor.constraint(equalTo: historyContent.trailingAnchor, constant: -14),
            column.topAnchor.constraint(equalTo: historyContent.topAnchor, constant: 20),
            column.bottomAnchor.constraint(equalTo: historyContent.bottomAnchor, constant: -20),
            headerRow.widthAnchor.constraint(equalTo: column.widthAnchor),
            historyList.widthAnchor.constraint(equalTo: column.widthAnchor),
        ])
        historyScroll.documentView = historyContent
        historyScroll.hasVerticalScroller = true
        historyScroll.drawsBackground = false
        historyScroll.translatesAutoresizingMaskIntoConstraints = false
        historyRail.addSubview(historyScroll)
        NSLayoutConstraint.activate([
            historyScroll.leadingAnchor.constraint(equalTo: historyRail.leadingAnchor),
            historyScroll.trailingAnchor.constraint(equalTo: historyRail.trailingAnchor),
            historyScroll.topAnchor.constraint(equalTo: historyRail.topAnchor),
            historyScroll.bottomAnchor.constraint(equalTo: historyRail.bottomAnchor),
            historyContent.widthAnchor.constraint(equalTo: historyScroll.contentView.widthAnchor),
        ])
    }

    private func fieldLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text.uppercased())
        label.font = HelmType.kicker()
        label.translatesAutoresizingMaskIntoConstraints = false
        _ = mutedLabels.add(label)
        return label
    }
}

// MARK: - Evidence, input and the analysis run

extension LogAnalyzerController: NSTextViewDelegate {

    /// Live source detection as the captain types/pastes (spec §3's strip
    /// resolves with no latency and no network - see `LogSourceDetector`'s
    /// header for why detection is local rather than an AI call).
    func textDidChange(_ notification: Notification) {
        guard (notification.object as? NSTextView) === inputTextView.textView else { return }
        refreshDetectionStripFromInput()
    }

    private func refreshDetectionStripFromInput() {
        let text = inputTextView.string
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            if investigation.evidence.isEmpty { detectionStrip.isHidden = true }
            return
        }
        let detection = LogSourceDetector.detect(text, override: sourceOverride)
        detectionLabel.stringValue = "Detected · " + detection.summary
        detectionStrip.isHidden = false
    }

    // MARK: Adding evidence (spec §2, §13, §14)

    /// **The single redaction boundary.** `raw` is a parameter and a local
    /// `let` from here on - the redacted text is what lands on the model, so
    /// no later code path has an unredacted copy to leak. Spec §14.
    @discardableResult
    private func addEvidence(raw: String, label: String, origin: LogEvidenceOrigin, sourceDetail: String? = nil) -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        let result = LogRedactor.redact(raw)
        let detection = LogSourceDetector.detect(result.text, override: sourceOverride)
        let item = LogEvidenceItem(label: label, origin: origin, sourceDetail: sourceDetail,
                                   text: result.text, detection: detection,
                                   redactionCount: result.count)
        investigation.evidence.append(item)
        investigation.updatedAt = Date()
        if investigation.title == "Untitled investigation" {
            investigation.title = Self.derivedTitle(from: result.text, fallback: label)
        }
        redactions.append(contentsOf: result.redactions)
        // Once the captain has added the extra evidence they came back for,
        // the input card steps aside again on the next render.
        inputForcedVisible = false

        renderInvestigation()
        return true
    }

    /// A short, human title for an investigation, taken from the first
    /// genuinely error-ish line rather than the first line (which is usually
    /// a command echo or a header row).
    static func derivedTitle(from text: String, fallback: String) -> String {
        let lines = text.components(separatedBy: "\n").prefix(400)
        if let worst = lines.first(where: { LogErrorExtractor.severity(forLine: $0) >= .high }) {
            return LogErrorExtractor.shortLabel(worst, limit: 70)
        }
        if let first = lines.first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) {
            return LogErrorExtractor.shortLabel(first, limit: 70)
        }
        return fallback
    }

    // MARK: Input actions

    @objc func analyzeTapped() {
        // Anything still sitting in the input box is folded into the
        // evidence set first, so pressing Analyze after typing behaves the
        // same as pressing "Add pasted text" and then Analyze.
        let pending = inputTextView.string
        if !pending.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let label = importSourceLabel.map { "Terminal output — \($0)" } ?? "Pasted output"
            let origin: LogEvidenceOrigin = importSourceLabel == nil ? .pasted : .terminal
            addEvidence(raw: pending, label: label, origin: origin, sourceDetail: importSourceLabel)
            inputTextView.string = ""
        }
        runAnalysis()
    }

    @objc func clearTapped() {
        inputTextView.string = ""
        newInvestigation()
    }

    @objc func newInvestigation() {
        investigation = LogInvestigation()
        redactions = []
        comparison = nil
        importSourceLabel = nil
        redactionsExpanded = false
        inputForcedVisible = false
        neededEvidenceVisible = false
        pendingNeededEvidence = []
        inputTextView.string = ""
        compareBefore.string = ""
        compareAfter.string = ""
        compareSummaryLabel.stringValue = "Paste or pick two outputs, then press Analyze Differences."
        compareDiff.setRows([])
        detectionStrip.isHidden = true
        renderInvestigation()
        scrollToTop()
    }

    @objc func analyzeClipboard() {
        guard let text = NSPasteboard.general.string(forType: .string),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            Toast.show(in: view, message: "Clipboard is empty")
            return
        }
        addEvidence(raw: text, label: "Clipboard", origin: .clipboard)
        runAnalysis()
    }

    @objc func addClipboardAsEvidence() {
        guard let text = NSPasteboard.general.string(forType: .string),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            Toast.show(in: view, message: "Clipboard is empty")
            return
        }
        addEvidence(raw: text, label: "Clipboard", origin: .clipboard)
        Toast.show(in: view, message: "Clipboard added as evidence")
    }

    @objc func addCurrentInputAsEvidence() {
        let text = inputTextView.string
        guard addEvidence(raw: text, label: "Pasted output", origin: .pasted) else {
            Toast.show(in: view, message: "Nothing to add")
            return
        }
        inputTextView.string = ""
        Toast.show(in: view, message: "Added as evidence")
    }

    @objc func addFileTapped() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.message = "Choose log or output files to analyze"
        // Spec §2's list, plus plain-text as a catch-all so an extension-less
        // capture still opens.
        panel.allowedContentTypes = LogDropZoneView.acceptedContentTypes
        panel.begin { [weak self] response in
            guard response == .OK, let self else { return }
            self.importFiles(panel.urls)
        }
    }

    /// Spec §2's drag & drop and file picker share this one path.
    func importFiles(_ urls: [URL]) {
        var added = 0
        for url in urls {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else {
                Toast.show(in: view, message: "Could not read \(url.lastPathComponent) as text")
                continue
            }
            if addEvidence(raw: text, label: url.lastPathComponent, origin: .file, sourceDetail: url.path) {
                added += 1
            }
        }
        guard added > 0 else { return }
        Toast.show(in: view, message: added == 1 ? "Added 1 file" : "Added \(added) files")
    }

    /// Spec §12's "[Paste More Logs]" - reveals the input card again (it is
    /// hidden once the split workspace takes over, see `updateFlowVisibility`)
    /// and puts the caret in it.
    @objc func focusInput() {
        inputForcedVisible = true
        updateFlowVisibility()
        view.layoutSubtreeIfNeeded()
        view.window?.makeFirstResponder(inputTextView.textView)
    }

    @objc func goToConsole() {
        guard let onOpenConsole else {
            Toast.show(in: view, message: "No console is available")
            return
        }
        onOpenConsole()
    }

    @objc func sourceChanged() {
        let index = sourcePopup.indexOfSelectedItem
        sourceOverride = index <= 0 ? nil : LogSourceKind.pickerOrder[index - 1]
        overridePopup.selectItem(at: index)
        refreshDetectionStripFromInput()
    }

    @objc func overrideChanged() {
        let index = overridePopup.indexOfSelectedItem
        sourceOverride = index <= 0 ? nil : LogSourceKind.pickerOrder[index - 1]
        sourcePopup.selectItem(at: index)
        // Re-detect every evidence item under the new override, so the
        // analysis prompt and every badge agree with what the strip says.
        for index in investigation.evidence.indices {
            investigation.evidence[index].detection =
                LogSourceDetector.detect(investigation.evidence[index].text, override: sourceOverride)
        }
        renderInvestigation()
        refreshDetectionStripFromInput()
    }

    @objc func modeChanged() {
        let index = modePopup.indexOfSelectedItem
        guard index >= 0, index < LogAnalysisMode.allCases.count else { return }
        mode = LogAnalysisMode.allCases[index]
    }

    // MARK: The analysis run

    /// Local layer first (always), AI layer second (when available). See
    /// `LogAnalyzerModels.swift`'s header for why the two are kept apart.
    func runAnalysis() {
        guard !investigation.evidence.isEmpty else {
            Toast.show(in: view, message: "Nothing to analyze yet")
            return
        }
        guard !isAnalyzing else { return }

        let combined = investigation.combinedText
        let local = Self.buildLocalAnalysis(text: combined, override: sourceOverride)
        // A fresh analysis supersedes any earlier "what's still needed"
        // answer - that list was about the older evidence set.
        neededEvidenceVisible = false
        pendingNeededEvidence = []

        // Render the local half immediately - a big log's grouping/timeline
        // is genuinely useful on its own, and the captain shouldn't stare at
        // a spinner for it while a network call runs.
        investigation.analysis = LogAnalysis(local: local, ai: nil, aiFailure: nil,
                                             mode: mode, analyzedAt: Date())
        renderInvestigation()

        guard LogAnalyzerAI.isAvailable else {
            investigation.analysis?.aiFailure = "claude is not installed or not on PATH, so only the local "
                + "analysis (source detection, severity, grouped patterns and the timeline) is shown."
            renderInvestigation()
            persistIfNeeded()
            return
        }

        setAnalyzing(true, message: "Analyzing output — grouping errors, checking correlation…")
        LogAnalyzerAI.analyze(mode: mode, local: local, body: combined) { [weak self] result in
            guard let self else { return }
            self.setAnalyzing(false, message: "")
            switch result {
            case .failure(let error):
                self.investigation.analysis?.aiFailure = error.message
            case .success(var ai):
                // Spec §11, resolved after the fact - see
                // `LogAnalyzerCommandMatcher`'s header.
                var commands = LogAnalyzerCommandMatcher.resolve(ai.suggestedCommands,
                                                                 against: self.commandLibrary.commands)
                if commands.isEmpty {
                    commands = LogAnalyzerCommandMatcher.libraryFallback(for: local.detection.kind,
                                                                         in: self.commandLibrary.commands)
                }
                ai.suggestedCommands = commands
                self.investigation.analysis?.ai = ai
                self.investigation.analysis?.aiFailure = nil
            }
            self.investigation.updatedAt = Date()
            self.renderInvestigation()
            self.persistIfNeeded()
        }
    }

    /// The whole local layer, in one place so the self-test can drive it
    /// exactly as the page does.
    static func buildLocalAnalysis(text: String, override: LogSourceKind?) -> LogLocalAnalysis {
        let detection = LogSourceDetector.detect(text, override: override)
        let groups = LogErrorExtractor.groups(in: text)
        let timeline = LogTimelineBuilder.build(text: text, groups: groups)
        let observed = LogCorrelationBuilder.observed(groups: groups, timeline: timeline)
        return LogLocalAnalysis(
            detection: detection,
            groups: groups,
            timeline: timeline,
            observedCorrelation: observed,
            lineCount: text.isEmpty ? 0 : text.components(separatedBy: "\n").count,
            findings: LogErrorExtractor.findings(from: groups)
        )
    }

    private func setAnalyzing(_ analyzing: Bool, message: String) {
        isAnalyzing = analyzing
        analyzingRow.isHidden = !analyzing
        analyzeButton.isEnabled = !analyzing
        investigateButton.isEnabled = !analyzing
        if analyzing {
            analyzingLabel.stringValue = message
            analyzingSpinner.startAnimation(nil)
        } else {
            analyzingSpinner.stopAnimation(nil)
        }
    }

    // MARK: Spec §12 - Investigate Further

    @objc func investigateFurther() {
        guard !investigation.evidence.isEmpty else {
            Toast.show(in: view, message: "Add some output first")
            return
        }
        // If the analysis already carries a needed-evidence list, show it
        // straight away rather than paying for a second call.
        if let needed = investigation.analysis?.ai?.neededEvidence, !needed.isEmpty {
            neededEvidenceVisible = true
            renderNeededEvidence()
            Toast.show(in: view, message: "Showing what's still needed")
            return
        }
        guard LogAnalyzerAI.isAvailable else {
            Toast.show(in: view, message: "claude is not available for this step")
            return
        }
        guard !isAnalyzing else { return }

        let detection = investigation.analysis?.local.detection
            ?? LogSourceDetector.detect(investigation.combinedText, override: sourceOverride)
        setAnalyzing(true, message: "Working out what other evidence would settle this…")
        LogAnalyzerAI.investigateFurther(detection: detection,
                                         rootCause: investigation.analysis?.ai?.rootCause,
                                         body: investigation.combinedText) { [weak self] result in
            guard let self else { return }
            self.setAnalyzing(false, message: "")
            switch result {
            case .failure(let error):
                Toast.show(in: self.view, message: error.message)
            case .success(let needed):
                if self.investigation.analysis?.ai != nil {
                    self.investigation.analysis?.ai?.neededEvidence = needed
                } else {
                    self.pendingNeededEvidence = needed
                }
                self.neededEvidenceVisible = true
                self.renderNeededEvidence()
            }
        }
    }
}

// MARK: - Actions: copy, artifacts, compare, storage, history

extension LogAnalyzerController {

    private func copy(_ text: String, what: String) {
        guard !text.isEmpty else {
            Toast.show(in: view, message: "Nothing to copy yet")
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        Toast.show(in: view, message: "\(what) copied")
    }

    @objc func copyRootCause() { copy(LogAnalyzerArtifacts.rootCauseText(investigation), what: "Root cause") }
    @objc func copyNextSteps() { copy(LogAnalyzerArtifacts.nextStepsText(investigation), what: "Next steps") }
    @objc func copyEvidence() { copy(LogAnalyzerArtifacts.evidenceText(investigation), what: "Evidence") }

    @objc func copyFullAnalysis() {
        guard investigation.analysis != nil else {
            Toast.show(in: view, message: "Run an analysis first")
            return
        }
        copy(LogAnalyzerArtifacts.fullAnalysisText(investigation), what: "Full analysis")
    }

    @objc func copyComparison() {
        guard let comparison else {
            Toast.show(in: view, message: "Run a comparison first")
            return
        }
        copy(LogAnalyzerArtifacts.comparisonText(comparison, beforeLabel: "Before", afterLabel: "After"),
             what: "Comparison")
    }

    /// Spec §24's ⌘⇧T - the top suggested command, sent to the console.
    @objc func sendTopCommandToTerminal() {
        guard let command = investigation.analysis?.ai?.suggestedCommands.first else {
            Toast.show(in: view, message: "No suggested command yet")
            return
        }
        sendToTerminal(command.command)
    }

    private func sendToTerminal(_ command: String) {
        guard let onSendCommandToTerminal else {
            Toast.show(in: view, message: "No terminal is available")
            return
        }
        onSendCommandToTerminal(command)
        Toast.show(in: view, message: "Sent to terminal")
    }

    // MARK: Spec §17 / §18 / §19

    @objc func createIncident() {
        guard investigation.analysis != nil else {
            Toast.show(in: view, message: "Run an analysis first")
            return
        }
        let body = LogAnalyzerArtifacts.incidentMarkdown(investigation)
        presentArtifact(title: "Incident",
                        explanation: "This incident write-up was generated from the current investigation. "
                            + "Copy it, or save it as a postmortem in Docs.",
                        body: body,
                        saveTitle: "Save to Docs → Postmortems") { [weak self] in
            guard let self else { return }
            let created = self.runbookStore.createPostmortem(
                title: "Incident: \(self.investigation.title)", content: body)
            Toast.show(in: self.view, message: "Saved to Docs → Postmortems")
            self.onOpenRunbook?(created.id)
        }
    }

    @objc func createRunbook() {
        guard investigation.analysis != nil else {
            Toast.show(in: view, message: "Run an analysis first")
            return
        }
        let body = LogAnalyzerArtifacts.runbookMarkdown(investigation)
        presentArtifact(title: "Runbook",
                        explanation: "This runbook was generated from the current investigation. Its command "
                            + "steps are fenced in the shape SRE Lead's runbook runner already reads, so it "
                            + "can be run later from a host session.",
                        body: body,
                        saveTitle: "Save to Docs → Runbooks") { [weak self] in
            guard let self else { return }
            let title = self.investigation.analysis?.ai?.rootCause?.summary ?? self.investigation.title
            let created = self.runbookStore.createRunbook(title: title, content: body)
            Toast.show(in: self.view, message: "Saved to Docs → Runbooks")
            self.onOpenRunbook?(created.id)
        }
    }

    /// Spec §19 is explicit: never file an external ticket without
    /// confirmation. This app goes one step further and never files one at
    /// all - it generates the body and puts it on the pasteboard. There is no
    /// tracker client anywhere in this feature.
    @objc func createTicket() {
        guard investigation.analysis != nil else {
            Toast.show(in: view, message: "Run an analysis first")
            return
        }
        let body = LogAnalyzerArtifacts.ticketMarkdown(investigation)
        presentArtifact(title: "Ticket",
                        explanation: "Nothing has been filed anywhere. This is a draft body — copy it into "
                            + "your tracker yourself if it's correct.",
                        body: body,
                        saveTitle: nil,
                        onSave: nil)
    }

    /// One shared review sheet for all three artifacts: shows the generated
    /// text, offers Copy, and (where it applies) an explicit save action.
    private func presentArtifact(title: String, explanation: String, body: String,
                                 saveTitle: String?, onSave: (() -> Void)?) {
        let alert = NSAlert()
        alert.messageText = "\(title) draft"
        alert.informativeText = explanation
        alert.alertStyle = .informational

        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 620, height: 360))
        textView.string = body
        textView.isEditable = false
        textView.font = HelmType.code()
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 620, height: 360))
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        alert.accessoryView = scroll

        alert.addButton(withTitle: "Copy")
        if saveTitle != nil { alert.addButton(withTitle: saveTitle!) }
        alert.addButton(withTitle: "Close")

        let response = alert.runModal()
        switch response {
        case .alertFirstButtonReturn:
            copy(body, what: title)
        case .alertSecondButtonReturn where saveTitle != nil:
            onSave?()
        default:
            break
        }
    }

    // MARK: Spec §20 / §21 - Compare

    @objc func showCompareTab() {
        tabs.select("compare")
        selectTab("compare")
    }

    @objc func comparePickerChanged(_ sender: NSPopUpButton) {
        let index = sender.indexOfSelectedItem - 1
        guard index >= 0, index < investigation.evidence.count else { return }
        let text = investigation.evidence[index].text
        if sender === comparePopupBefore { compareBefore.string = text } else { compareAfter.string = text }
    }

    @objc func runCompare() {
        let before = compareBefore.string
        let after = compareAfter.string
        guard !before.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !after.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            Toast.show(in: view, message: "Provide both a Before and an After")
            return
        }
        // Redacted on the way in here too - Compare accepts raw pasted text
        // directly, so it needs its own pass rather than relying on
        // `addEvidence`'s.
        let redactedBefore = LogRedactor.redact(before)
        let redactedAfter = LogRedactor.redact(after)
        if redactedBefore.count + redactedAfter.count > 0 {
            compareBefore.string = redactedBefore.text
            compareAfter.string = redactedAfter.text
            redactions.append(contentsOf: redactedBefore.redactions + redactedAfter.redactions)
            renderRedactions()
        }

        let result = LogAnalyzerArtifacts.compare(before: redactedBefore.text, after: redactedAfter.text)
        comparison = result
        compareDiff.setRows(result.rows)
        compareDiff.applyTheme(theme)
        let localSummary = LogAnalyzerArtifacts.comparisonText(
            result, beforeLabel: "Before", afterLabel: "After")
        compareSummaryLabel.stringValue = localSummary

        // Spec §21 also asks for the differences a pattern diff can't see -
        // changed configuration, changed values, behavioural differences. The
        // counted new/resolved/worse lists above are exact and are shown
        // immediately; this second pass only *adds* prose underneath, and its
        // absence (no `claude`, offline, a failure) costs nothing already
        // shown.
        guard LogAnalyzerAI.isAvailable, !isAnalyzing else { return }
        let body = """
        ===== BEFORE =====
        \(redactedBefore.text)

        ===== AFTER =====
        \(redactedAfter.text)
        """
        let local = Self.buildLocalAnalysis(text: body, override: sourceOverride)
        setAnalyzing(true, message: "Comparing the two outputs…")
        LogAnalyzerAI.analyze(mode: .compare, local: local, body: body,
                              extraContext: "The counted differences are: \(localSummary)") { [weak self] aiResult in
            guard let self else { return }
            self.setAnalyzing(false, message: "")
            switch aiResult {
            case .failure(let error):
                self.compareSummaryLabel.stringValue = localSummary
                    + "\n(The AI comparison pass did not run: \(error.message))"
            case .success(let ai):
                var text = localSummary
                if !ai.summary.isEmpty { text += "\n\(ai.summary)" }
                for finding in ai.findings {
                    text += "\n• [\(finding.severity.displayName)] \(finding.title)"
                    if !finding.detail.isEmpty { text += " — \(finding.detail)" }
                }
                self.compareSummaryLabel.stringValue = text
            }
        }
    }

    // MARK: Spec §15 - storage

    @objc func storageRowClicked(_ sender: NSClickGestureRecognizer) {
        guard let identifier = sender.view?.identifier?.rawValue,
              let choice = LogStorageChoice(rawValue: identifier) else { return }
        investigation.storage = choice
        renderStorageSelection()
        persistIfNeeded()
    }

    /// The only writer. `.doNotSave` still calls through so that downgrading
    /// an already-saved investigation removes it (see `LogAnalyzerStore.save`).
    private func persistIfNeeded() {
        guard investigation.analysis != nil || investigation.storage != .doNotSave else { return }
        // Spec §23 asks history to carry tags. Derived from what the
        // investigation already established - the detected source, the
        // highest severity reached, and the analysis mode - rather than
        // asking the captain to type them or inventing topical ones.
        var tags = [investigation.sourceKind.rawValue, investigation.severity.rawValue]
        if let mode = investigation.analysis?.mode { tags.append(mode.rawValue) }
        if investigation.evidence.contains(where: { $0.origin == .terminal }) { tags.append("from-terminal") }
        investigation.tags = tags
        store.save(investigation)
        reloadHistory()
    }

    // MARK: Spec §23 - history

    static let historyRailWidthWhenVisible: CGFloat = 320

    @objc func toggleHistory() {
        historyVisible.toggle()
        historyRail.isHidden = !historyVisible
        historyRailWidth.constant = historyVisible ? Self.historyRailWidthWhenVisible : 0
        historyToggleButton.title = historyVisible ? "Hide history" : "History"
        if historyVisible { reloadHistory() }
    }

    func reloadHistory() {
        historyEntries = store.history()
        let contents = historyEntries.map { entry -> HelmAccentRow.Content in
            var content = HelmAccentRow.Content(tint: entry.severity.tint,
                                                kicker: entry.sourceKind.displayName.uppercased(),
                                                title: entry.title)
            content.meta = "\(entry.status) · \(entry.relativeTime)"
            content.badgeSymbol = entry.severity.symbol
            content.chipText = entry.storage == .complete ? "Full" : "Metadata"
            content.chipTint = .neutral
            content.titleWraps = true
            return content
        }
        historyList.setContents(contents, theme: theme)
    }

    private func openHistoryEntry(at index: Int) {
        guard index >= 0, index < historyEntries.count else { return }
        let entry = historyEntries[index]
        guard let loaded = store.load(id: entry.id) else {
            Toast.show(in: view, message: "Could not reopen that investigation")
            return
        }
        investigation = loaded
        redactions = []
        comparison = nil
        importSourceLabel = nil
        // A metadata-only entry has no stored log text, so there is nothing
        // to re-analyze - say so rather than showing an empty raw pane with
        // no explanation.
        if loaded.evidence.allSatisfy({ $0.text.isEmpty }) {
            Toast.show(in: view, message: "Metadata only — the log content wasn't saved")
        } else {
            investigation.analysis = LogAnalysis(
                local: Self.buildLocalAnalysis(text: loaded.combinedText, override: sourceOverride),
                ai: nil, aiFailure: "Reopened from history — press Analyze to run the AI layer again.",
                mode: mode, analyzedAt: loaded.updatedAt)
        }
        renderInvestigation()
        scrollToTop()
    }

    // MARK: Tabs

    func selectTab(_ id: String) {
        for (tabID, tabView) in tabViews { tabView.isHidden = tabID != id }
        view.layoutSubtreeIfNeeded()
    }

    @objc func toggleRedactions() {
        redactionsExpanded.toggle()
        renderRedactions()
    }
}

// MARK: - Rendering

extension LogAnalyzerController {

    /// One render pass over everything the current investigation drives.
    /// Deliberately whole-page rather than incremental: every section is
    /// cheap to rebuild (the three heavy lists are demand-driven tables) and
    /// a single path means two sections can never disagree about what the
    /// current analysis says - the same "rebuild the card, don't patch it"
    /// convention `BootstrapController`/`VaultController` already use.
    func renderInvestigation() {
        updateFlowVisibility()
        renderImportBadge()
        renderDetection()
        renderRedactions()
        renderRawPane()
        renderFindings()
        renderRootCause()
        renderNextSteps()
        renderCommands()
        renderGroups()
        renderTimeline()
        renderCorrelation()
        renderEvidence()
        renderNeededEvidence()
        renderStorageSelection()
        renderComparePickers()
        renderAINotice()
        applyTheme()
    }

    /// Spec §1's two states, in one place.
    ///
    /// Before there is anything to show, the page is just the input card -
    /// a wall of empty tabs, an empty storage choice and a row of disabled-
    /// looking actions is noise, not affordance. Once an analysis exists the
    /// page becomes the split workspace and the input card steps aside,
    /// coming back only when the captain asks for it (`inputForcedVisible`,
    /// set by "Paste More Logs") or a fresh investigation starts.
    private func updateFlowVisibility() {
        let hasAnalysis = investigation.analysis != nil
        let showInput = !hasAnalysis || inputForcedVisible
        inputCard.isHidden = !showInput
        tabs.isHidden = !hasAnalysis
        tabContainer.isHidden = !hasAnalysis
        storageCard.isHidden = !hasAnalysis
        actionBar.isHidden = !hasAnalysis
        // Only meaningful once there is an analysis to add evidence *to*;
        // before that, the whole page is the "add evidence" affordance.
        if !hasAnalysis { neededEvidenceVisible = false }
        clearButton.title = hasAnalysis ? "Discard" : "Clear"
    }

    private func renderImportBadge() {
        guard let label = importSourceLabel else {
            importBadge.isHidden = true
            return
        }
        importBadge.isHidden = false
        importBadgeLabel.stringValue = label
    }

    private func renderDetection() {
        guard let detection = investigation.analysis?.local.detection
            ?? investigation.evidence.first?.detection else {
            refreshDetectionStripFromInput()
            return
        }
        detectionLabel.stringValue = "Detected · " + detection.summary
        detectionStrip.isHidden = false
    }

    /// Spec §14's review panel. The "before" column is a fingerprint, never
    /// the secret - see `LogRedaction`'s doc comment.
    private func renderRedactions() {
        guard !redactions.isEmpty else {
            redactionCard.isHidden = true
            return
        }
        redactionCard.isHidden = false
        let count = redactions.count
        redactionSummaryLabel.stringValue = "\(count) potential secret\(count == 1 ? "" : "s") detected and "
            + "redacted before anything is analyzed or saved."
        redactionToggleButton.title = redactionsExpanded ? "Hide Redactions" : "View Redactions"

        for view in redactionListStack.arrangedSubviews {
            redactionListStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        guard redactionsExpanded else {
            redactionListStack.isHidden = true
            return
        }
        redactionListStack.isHidden = false
        for redaction in redactions.prefix(40) {
            let row = redactionRow(redaction)
            redactionListStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: redactionListStack.widthAnchor).isActive = true
        }
        if redactions.count > 40 {
            let more = NSTextField(labelWithString: "… and \(redactions.count - 40) more")
            more.font = HelmType.caption()
            more.translatesAutoresizingMaskIntoConstraints = false
            _ = mutedLabels.add(more)
            redactionListStack.addArrangedSubview(more)
        }
    }

    private func redactionRow(_ redaction: LogRedaction) -> NSView {
        let kind = NSTextField(labelWithString: redaction.kind)
        kind.font = HelmType.rowTitle()
        kind.translatesAutoresizingMaskIntoConstraints = false
        kind.setContentHuggingPriority(.required, for: .horizontal)

        let line = NSTextField(labelWithString: "line \(redaction.lineNumber) · \(redaction.fingerprint)")
        line.font = HelmType.caption()
        line.translatesAutoresizingMaskIntoConstraints = false
        line.setContentHuggingPriority(.required, for: .horizontal)
        _ = mutedLabels.add(line)

        let masked = NSTextField(labelWithString: redaction.maskedLine)
        masked.font = HelmType.code()
        masked.lineBreakMode = .byTruncatingTail
        masked.translatesAutoresizingMaskIntoConstraints = false
        masked.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let top = NSStackView(views: [kind, line])
        top.orientation = .horizontal
        top.alignment = .firstBaseline
        top.distribution = .fill
        top.spacing = 8
        top.translatesAutoresizingMaskIntoConstraints = false

        let column = NSStackView(views: [top, masked])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 2
        column.translatesAutoresizingMaskIntoConstraints = false
        masked.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
        return column
    }

    private func renderRawPane() {
        let text = investigation.combinedText
        rawPane.setText(text, theme: theme)
        rawPaneCountLabel.stringValue = text.isEmpty ? "" : "\(rawPane.lineCount) lines"
    }

    private func renderFindings() {
        let findings = investigation.analysis?.findings ?? []
        let contents = findings.map { finding -> HelmAccentRow.Content in
            var content = HelmAccentRow.Content(tint: finding.severity.tint,
                                                kicker: finding.severity.displayName.uppercased(),
                                                title: finding.title)
            content.meta = finding.meta ?? finding.detail
            content.badgeSymbol = finding.severity.symbol
            content.titleWraps = true
            return content
        }
        findingsList.setContents(contents, theme: theme)
    }

    private func renderRootCause() {
        guard let root = investigation.analysis?.ai?.rootCause else {
            rootCauseSummaryLabel.stringValue = investigation.analysis == nil
                ? "Run an analysis to get a probable root cause."
                : "No root cause has been established from the provided output yet."
            rootCauseExplanationLabel.stringValue = ""
            rootCauseConfidenceLabel.stringValue = "—"
            clearStack(evidenceStack)
            clearStack(missingEvidenceStack)
            return
        }

        rootCauseSummaryLabel.stringValue = root.summary
        rootCauseExplanationLabel.stringValue = root.explanation
        rootCauseConfidenceLabel.stringValue = "\(root.confidence.displayName) confidence".uppercased()

        clearStack(evidenceStack)
        clearStack(missingEvidenceStack)
        addBulletSection(to: evidenceStack, title: "Evidence", items: root.evidence,
                         symbol: "checkmark", tint: .good)
        addBulletSection(to: missingEvidenceStack, title: "Missing evidence", items: root.missingEvidence,
                         symbol: "minus", tint: .neutral)
        if !root.contradictingEvidence.isEmpty {
            addBulletSection(to: missingEvidenceStack, title: "Contradicting evidence",
                             items: root.contradictingEvidence, symbol: "exclamationmark", tint: .warn)
        }
    }

    private func addBulletSection(to stack: NSStackView, title: String, items: [String],
                                  symbol: String, tint: HelmTint) {
        guard !items.isEmpty else { return }
        let heading = NSTextField(labelWithString: title.uppercased())
        heading.font = HelmType.kicker()
        heading.translatesAutoresizingMaskIntoConstraints = false
        _ = mutedLabels.add(heading)
        stack.addArrangedSubview(heading)

        for item in items {
            let glyph = NSTextField(labelWithString: symbol == "checkmark" ? "✓" : (symbol == "minus" ? "—" : "!"))
            glyph.font = HelmType.caption()
            glyph.textColor = HelmContrast.legibleTintedText(
                tintHex: tint.hex(in: theme),
                over: HelmTheme.nsColor(theme.chromeBackgroundHex),
                theme: theme)
            glyph.translatesAutoresizingMaskIntoConstraints = false
            glyph.setContentHuggingPriority(.required, for: .horizontal)
            glyph.widthAnchor.constraint(equalToConstant: 14).isActive = true

            let text = NSTextField(wrappingLabelWithString: item)
            text.font = HelmType.body()
            text.translatesAutoresizingMaskIntoConstraints = false
            text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            _ = mutedLabels.add(text)

            let row = NSStackView(views: [glyph, text])
            row.orientation = .horizontal
            row.alignment = .top
            row.distribution = .fill
            row.spacing = 6
            row.translatesAutoresizingMaskIntoConstraints = false
            stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
    }

    private func renderNextSteps() {
        clearStack(nextStepsStack)
        let steps = investigation.analysis?.ai?.nextSteps ?? []
        guard !steps.isEmpty else {
            let empty = NSTextField(wrappingLabelWithString: investigation.analysis == nil
                ? "Run an analysis to get recommended next steps."
                : "No next steps were produced for this output.")
            empty.font = HelmType.body()
            empty.translatesAutoresizingMaskIntoConstraints = false
            _ = mutedLabels.add(empty)
            nextStepsStack.addArrangedSubview(empty)
            empty.widthAnchor.constraint(equalTo: nextStepsStack.widthAnchor).isActive = true
            return
        }
        for (index, step) in steps.enumerated() {
            let number = NSTextField(labelWithString: "\(index + 1).")
            number.font = HelmType.metric(12, weight: .semibold)
            number.translatesAutoresizingMaskIntoConstraints = false
            number.setContentHuggingPriority(.required, for: .horizontal)
            number.widthAnchor.constraint(equalToConstant: 20).isActive = true

            let text = NSTextField(wrappingLabelWithString: step)
            text.font = HelmType.body()
            text.translatesAutoresizingMaskIntoConstraints = false
            text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

            let row = NSStackView(views: [number, text])
            row.orientation = .horizontal
            row.alignment = .top
            row.distribution = .fill
            row.spacing = 6
            row.translatesAutoresizingMaskIntoConstraints = false
            nextStepsStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: nextStepsStack.widthAnchor).isActive = true
        }
    }

    /// Spec §11's rows: the command, plus Copy and "send to terminal", plus a
    /// chip when the command came from the captain's own library.
    private func renderCommands() {
        clearStack(commandsStack)
        commandRowContainers.removeAll()
        let commands = investigation.analysis?.ai?.suggestedCommands ?? []
        guard !commands.isEmpty else {
            let empty = NSTextField(wrappingLabelWithString: investigation.analysis == nil
                ? "Run an analysis to get investigation commands."
                : "No investigation commands were suggested for this output.")
            empty.font = HelmType.body()
            empty.translatesAutoresizingMaskIntoConstraints = false
            _ = mutedLabels.add(empty)
            commandsStack.addArrangedSubview(empty)
            empty.widthAnchor.constraint(equalTo: commandsStack.widthAnchor).isActive = true
            return
        }
        for (index, command) in commands.enumerated() {
            let row = commandRow(command, index: index)
            commandsStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: commandsStack.widthAnchor).isActive = true
        }
    }

    /// Kept so the Copy/Send buttons can find their command by tag without a
    /// per-row closure capture that would outlive a re-render.
    private static let commandTagBase = 9000

    private func commandRow(_ command: LogSuggestedCommand, index: Int) -> NSView {
        let title = NSTextField(labelWithString: command.title)
        title.font = HelmType.rowTitle()
        title.lineBreakMode = .byTruncatingTail
        title.translatesAutoresizingMaskIntoConstraints = false
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let commandLabel = NSTextField(labelWithString: command.command)
        commandLabel.font = HelmType.code()
        commandLabel.lineBreakMode = .byTruncatingTail
        commandLabel.translatesAutoresizingMaskIntoConstraints = false
        commandLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        var topViews: [NSView] = [title]
        if command.isFromLibrary {
            let pill = NSView()
            pill.translatesAutoresizingMaskIntoConstraints = false
            let label = NSTextField(labelWithString: "")
            label.translatesAutoresizingMaskIntoConstraints = false
            ToolRowLayout.pill(text: "From your library", colorHex: HelmTint.good.hex(in: theme),
                               into: pill, label: label, theme: theme)
            pill.setContentHuggingPriority(.required, for: .horizontal)
            topViews.append(pill)
        }
        let topSpacer = NSView()
        topSpacer.translatesAutoresizingMaskIntoConstraints = false
        topSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        topViews.append(topSpacer)

        let copyButton = HelmButton(title: "Copy", variant: .secondary, size: .small, symbol: "doc.on.doc",
                                    target: self, action: #selector(copyCommandTapped(_:)))
        copyButton.tag = Self.commandTagBase + index
        let sendButton = HelmButton(title: "Terminal", variant: .secondary, size: .small, symbol: "terminal",
                                    target: self, action: #selector(sendCommandTapped(_:)))
        sendButton.tag = Self.commandTagBase + index
        for button in [copyButton, sendButton] {
            button.setContentHuggingPriority(.required, for: .horizontal)
            button.setContentCompressionResistancePriority(.required, for: .horizontal)
            topViews.append(button)
        }

        let top = NSStackView(views: topViews)
        top.orientation = .horizontal
        top.alignment = .centerY
        top.distribution = .fill
        top.spacing = 8
        top.translatesAutoresizingMaskIntoConstraints = false

        var columnViews: [NSView] = [top, commandLabel]
        if !command.rationale.isEmpty {
            let rationale = NSTextField(wrappingLabelWithString: command.rationale)
            rationale.font = HelmType.caption()
            rationale.translatesAutoresizingMaskIntoConstraints = false
            rationale.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            _ = mutedLabels.add(rationale)
            columnViews.append(rationale)
        }

        let column = NSStackView(views: columnViews)
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 4
        column.translatesAutoresizingMaskIntoConstraints = false

        let container = HoverHighlightView()
        container.cornerRadius = HelmMetrics.rRow
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(column)
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 10),
            column.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -10),
            column.topAnchor.constraint(equalTo: container.topAnchor, constant: 8),
            column.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -8),
        ])
        for sub in columnViews { sub.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true }
        commandRowContainers.append(container)
        return container
    }

    @objc private func copyCommandTapped(_ sender: NSButton) {
        let index = sender.tag - Self.commandTagBase
        guard let command = investigation.analysis?.ai?.suggestedCommands[safe: index] else { return }
        copy(command.command, what: "Command")
        if let id = command.libraryCommandID { commandLibrary.recordUsage(id) }
    }

    @objc private func sendCommandTapped(_ sender: NSButton) {
        let index = sender.tag - Self.commandTagBase
        guard let command = investigation.analysis?.ai?.suggestedCommands[safe: index] else { return }
        sendToTerminal(command.command)
        if let id = command.libraryCommandID { commandLibrary.recordUsage(id) }
    }

    private func renderGroups() {
        groupsList.setGroups(investigation.analysis?.local.groups ?? [], theme: theme)
        groupsList.onRevealLine = { [weak self] line in
            guard let self else { return }
            self.tabs.select("analysis")
            self.selectTab("analysis")
            self.rawPane.reveal(line: line)
        }
    }

    private func renderTimeline() {
        timelineList.setTimeline(investigation.analysis?.local.timeline
            ?? .unavailable(reason: "Timeline unavailable — nothing has been analyzed yet."), theme: theme)
        timelineList.onRevealLine = { [weak self] line in
            guard let self else { return }
            self.tabs.select("analysis")
            self.selectTab("analysis")
            self.rawPane.reveal(line: line)
        }
    }

    private func renderCorrelation() {
        correlationList.setLinks(investigation.analysis?.correlation ?? [], theme: theme)
    }

    private func renderEvidence() {
        let contents = investigation.evidence.map { item -> HelmAccentRow.Content in
            var content = HelmAccentRow.Content(tint: item.detection.severity.tint,
                                                kicker: item.origin.displayName.uppercased(),
                                                title: item.label)
            var meta = "\(item.lineCount) lines · \(item.detection.kind.displayName)"
            if let detail = item.sourceDetail { meta += " · \(detail)" }
            if item.redactionCount > 0 { meta += " · \(item.redactionCount) redacted" }
            content.meta = meta
            content.badgeSymbol = item.origin.symbol
            content.chipText = "Remove"
            content.chipTint = .critical
            content.titleWraps = true
            return content
        }
        evidenceList.setContents(contents, theme: theme)
    }

    private func removeEvidence(at index: Int) {
        guard index >= 0, index < investigation.evidence.count else { return }
        investigation.evidence.remove(at: index)
        investigation.updatedAt = Date()
        renderInvestigation()
        Toast.show(in: view, message: "Evidence removed")
    }

    private func renderComparePickers() {
        for popup in [comparePopupBefore!, comparePopupAfter!] {
            popup.removeAllItems()
            popup.addItem(withTitle: "Paste below, or pick evidence…")
            for item in investigation.evidence { popup.addItem(withTitle: item.label) }
        }
    }

    private func renderStorageSelection() {
        for row in storageRows {
            let selected = row.choice == investigation.storage
            row.indicator.layer?.backgroundColor = selected
                ? HelmTheme.nsColor(theme.accentHex).cgColor
                : NSColor.clear.cgColor
            row.indicator.layer?.borderColor = selected
                ? HelmTheme.nsColor(theme.accentHex).cgColor
                : HelmTheme.nsColor(theme.chromeLineHex).cgColor
        }
    }

    /// Reads its content from the current analysis (falling back to a
    /// standalone Investigate-Further answer produced before any AI analysis
    /// existed), so a later render can never leave a stale list on screen.
    private func renderNeededEvidence() {
        clearStack(neededEvidenceStack)
        let items = investigation.analysis?.ai?.neededEvidence ?? pendingNeededEvidence
        guard neededEvidenceVisible, !items.isEmpty else {
            neededEvidenceCard.isHidden = true
            return
        }
        neededEvidenceCard.isHidden = false
        for (index, item) in items.enumerated() {
            let number = NSTextField(labelWithString: "\(index + 1).")
            number.font = HelmType.metric(12, weight: .semibold)
            number.translatesAutoresizingMaskIntoConstraints = false
            number.setContentHuggingPriority(.required, for: .horizontal)
            number.widthAnchor.constraint(equalToConstant: 20).isActive = true

            let text = NSTextField(wrappingLabelWithString: item)
            text.font = HelmType.body()
            text.translatesAutoresizingMaskIntoConstraints = false
            text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

            let row = NSStackView(views: [number, text])
            row.orientation = .horizontal
            row.alignment = .top
            row.distribution = .fill
            row.spacing = 6
            row.translatesAutoresizingMaskIntoConstraints = false
            neededEvidenceStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: neededEvidenceStack.widthAnchor).isActive = true
        }
    }

    private func renderAINotice() {
        if let summary = investigation.analysis?.ai?.summary, !summary.isEmpty {
            summaryLabel.stringValue = summary
            summaryCard.isHidden = false
        } else if investigation.analysis != nil {
            summaryLabel.stringValue = "Local analysis only — see the findings and grouped patterns below."
            summaryCard.isHidden = false
        } else {
            summaryCard.isHidden = true
        }

        if let failure = investigation.analysis?.aiFailure {
            aiNoticeLabel.stringValue = failure
            aiNoticeCard.isHidden = false
        } else {
            aiNoticeCard.isHidden = true
        }
    }

    private func clearStack(_ stack: NSStackView) {
        for view in stack.arrangedSubviews {
            stack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
    }
}

// MARK: - Theming

extension LogAnalyzerController {

    func applyTheme() {
        view.layer?.backgroundColor = HelmTheme.nsColor(theme.backgroundHex).cgColor

        heroLabel.textColor = HelmTheme.nsColor(theme.chromeInkHex)
        rootCauseSummaryLabel.textColor = HelmTheme.nsColor(theme.chromeInkHex)
        summaryLabel.textColor = HelmTheme.nsColor(theme.chromeInkHex)
        aiNoticeLabel.textColor = HelmTheme.nsColor(theme.chromeInkHex)
        detectionLabel.textColor = HelmTheme.nsColor(theme.chromeInkHex)
        redactionSummaryLabel.textColor = HelmTheme.nsColor(theme.chromeInkHex)
        importBadgeLabel.textColor = HelmTheme.nsColor(theme.chromeInkHex)
        mutedLabels.apply(theme)

        for card in cards { card.applyTheme(theme) }
        tabs.applyTheme(theme)

        detectionStrip.layer?.backgroundColor = HelmTheme.nsColor(theme.chromeBackgroundHex).cgColor
        detectionStrip.layer?.borderWidth = 1
        detectionStrip.layer?.borderColor = HelmTheme.nsColor(theme.chromeLineHex)
            .withAlphaComponent(HelmCard.borderAlpha).cgColor

        let violet = HelmTheme.nsColor(HelmTint.violet.hex(in: theme))
        importBadge.layer?.backgroundColor = violet.withAlphaComponent(0.14).cgColor
        importBadge.layer?.borderWidth = 1
        importBadge.layer?.borderColor = violet.withAlphaComponent(0.45).cgColor

        historyRail.layer?.backgroundColor = HelmTheme.nsColor(theme.chromeBackgroundHex).cgColor

        // Root-cause confidence chip - a hue on a wash, so it goes through
        // the shared contrast-corrected pill (AGENTS.md §5.7: a `HelmTint`
        // hue is safe as a fill and is NOT automatically safe as text).
        let confidence = investigation.analysis?.ai?.rootCause?.confidence
        ToolRowLayout.pill(text: rootCauseConfidenceLabel.stringValue.isEmpty
                            ? "—" : rootCauseConfidenceLabel.stringValue,
                           colorHex: (confidence?.tint ?? .neutral).hex(in: theme),
                           into: rootCauseConfidencePill,
                           label: rootCauseConfidenceLabel,
                           theme: theme)

        for chip in legendChips {
            ToolRowLayout.pill(text: "\(chip.kind.displayName) — \(chip.kind.detail)",
                               colorHex: chip.kind.tint.hex(in: theme),
                               into: chip.pill, label: chip.label, theme: theme)
        }

        let hoverFill = HelmTheme.nsColor(theme.chromeLineHex).withAlphaComponent(0.25)
        for row in storageRows {
            row.view.normalColor = .clear
            row.view.hoverColor = hoverFill
        }
        for container in commandRowContainers {
            container.normalColor = HelmField.fill(theme)
            container.hoverColor = HelmField.fill(theme).hoverShifted(by: 0.06, forMode: theme.mode)
        }

        rawPane.applyTheme(theme)
        groupsList.applyTheme(theme)
        timelineList.applyTheme(theme)
        correlationList.applyTheme(theme)
        findingsList.applyTheme(theme)
        evidenceList.applyTheme(theme)
        historyList.applyTheme(theme)
        compareDiff.applyTheme(theme)
        renderStorageSelection()
    }
}

// MARK: - Public entry points (menu items, the console bridge)

extension LogAnalyzerController {

    /// Spec §2's "Send from Terminal", called by `AppShellController` when a
    /// host page's "Analyze Logs" toolbar button fires. `capture` already
    /// carries the scope decision (`LogTerminalCaptureBuilder` - read its
    /// header for what gets captured and why); this only has to turn it into
    /// evidence and analyze.
    func importTerminalCapture(_ capture: LogTerminalCapture, hostLabel: String) {
        guard !capture.isEmpty else {
            Toast.show(in: view, message: "There was nothing to capture from that tab")
            return
        }
        importSourceLabel = hostLabel
        var badge = "Imported from \(hostLabel) · \(capture.scope.shortLabel). \(capture.scopeDescription)"
        if let notice = capture.fallbackNotice { badge += " \(notice)" }
        importBadgeLabel.stringValue = badge
        importBadge.isHidden = false

        addEvidence(raw: capture.text,
                    label: "\(capture.scope.shortLabel) — \(hostLabel)",
                    origin: .terminal,
                    sourceDetail: hostLabel)
        scrollToTop()
        runAnalysis()
    }

    /// ⌘⇧L lands here: focus the input so the captain can paste immediately.
    func focusForPaste() {
        view.layoutSubtreeIfNeeded()
        scrollToTop()
        focusInput()
    }

    // Menu-item targets (spec §24). See `main.swift` for the bindings and
    // which combos were already taken.
    @objc func menuAnalyze() { analyzeTapped() }
    @objc func menuCopyAnalysis() { copyFullAnalysis() }
    @objc func menuSendToTerminal() { sendTopCommandToTerminal() }
    @objc func menuInvestigateFurther() { investigateFurther() }
    @objc func menuCreateRCA() { createIncident() }
    @objc func menuAnalyzeClipboard() { analyzeClipboard() }

    /// Esc clears the current investigation - the spec's "Esc: close" mapped
    /// onto a full-page destination, which has nothing to close.
    override func cancelOperation(_ sender: Any?) {
        clearTapped()
    }
}

// MARK: - Drop zone (spec §2's drag & drop)

/// Accepts the file types spec §2 lists. A plain `NSView` subclass rather
/// than a drop handler on the text view, because `NSTextView` already
/// consumes a text drag itself (which is the behaviour we want for text) -
/// this only intercepts *file* drags.
final class LogDropZoneView: NSView {

    static let acceptedExtensions: Set<String> = ["log", "txt", "json", "yaml", "yml", "out", "trace"]

    static var acceptedContentTypes: [UTType] {
        var types: [UTType] = [.plainText, .text, .json, .yaml, .log, .utf8PlainText]
        for ext in acceptedExtensions {
            if let type = UTType(filenameExtension: ext) { types.append(type) }
        }
        return types
    }

    var onDropFiles: (([URL]) -> Void)?

    private var isHighlighted = false {
        didSet { needsDisplay = true }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    private func urls(from sender: NSDraggingInfo) -> [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        let objects = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: options)
        return (objects as? [URL] ?? []).filter {
            Self.acceptedExtensions.contains($0.pathExtension.lowercased()) || $0.pathExtension.isEmpty
        }
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let accepted = !urls(from: sender).isEmpty
        isHighlighted = accepted
        return accepted ? .copy : []
    }

    override func draggingExited(_ sender: NSDraggingInfo?) { isHighlighted = false }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        isHighlighted = false
        let files = urls(from: sender)
        guard !files.isEmpty else { return false }
        onDropFiles?(files)
        return true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard isHighlighted else { return }
        let accent = HelmTheme.nsColor(ThemeManager.shared.theme.accentHex)
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1),
                                xRadius: HelmMetrics.rControl, yRadius: HelmMetrics.rControl)
        accent.withAlphaComponent(0.10).setFill()
        path.fill()
        accent.withAlphaComponent(0.8).setStroke()
        path.lineWidth = 2
        path.stroke()
    }
}

// MARK: - Small helpers

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
