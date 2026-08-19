// Manjesh Grand Line - native macOS app.
//
// The `.automation` rail destination (fm/grandline-automation-pipeline),
// reachable only via the Setup flyout's third row (alongside Updates and
// Bootstrap - see `IconRailController.showSetupFlyout()`). One page, one
// idea: a single "Run Automation" button that sequences all five setup
// steps Bootstrap's own stepper already knows about (Firstmate home,
// Dotfiles & machine config, Agent instructions, Software checklist, and -
// unlike Bootstrap's own "Run full setup," which deliberately excludes it -
// Restore Grand Line config too, with its own real file-picker pause), skips
// whatever's already satisfied, and stops cleanly on the first failure.
//
// This page does not reimplement any check or install action. Every "is this
// step done" decision goes through `SetupStepChecks` (`SetupStepChecks.swift`)
// - the exact same functions `BootstrapController.stepIsDone(_:)` now
// delegates to, so the two pages can never disagree about what "done" means.
// Every actual check/install call goes straight to the same data-source
// layer Bootstrap's own cards call: `FirstmateHome`, `DotfilesSource`,
// `UpdatesSource`/`DependencyCatalog`, and `BackupUI`. This controller keeps
// its own cached copies of those checks' results (mirroring how
// `UpdatesController` and `BootstrapController` already each keep an
// independent cache of the same `DependencyCatalog` checks rather than
// sharing one mutable cache) rather than reaching into Bootstrap's own view-
// bound private state.
//
// `BootstrapController.swift`'s own page, cards, and "Run full setup" button
// are untouched by this task - this is a new, separate destination, not an
// edit to that page.

import AppKit

/// One step's live run state for this page's own sequencer - distinct from
/// `BootstrapController.SetupStepStatus` (private to that file), since this
/// page adds a captain-facing pause state (`.waitingForCaptain`) Bootstrap's
/// own sequencer has no equivalent for (it deliberately excludes the restore
/// step that needs one).
private enum AutomationStepStatus: Equatable {
    case pending, checking, running, waitingForCaptain, done, skipped, failed(String)
}

/// A small numbered/checkmark stepper dot, deliberately a fresh, minimal copy
/// rather than reusing `BootstrapController`'s private `StepDotView` - that
/// type is UI chrome scoped to Bootstrap's own file, not shared business
/// logic, so duplicating this ~40-line view (not a check/install action) is
/// the right call per this task's "no duplicate logic" scope.
private final class AutomationStepDotView: NSView {
    private let numberLabel = NSTextField(labelWithString: "")
    private let checkImageView = NSImageView()
    private let xImageView = NSImageView()
    private let diameter: CGFloat = 28

    override init(frame frameRect: NSRect) {
        super.init(frame: .zero)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        layer?.cornerRadius = diameter / 2

        numberLabel.font = .systemFont(ofSize: 12, weight: .bold)
        numberLabel.alignment = .center
        numberLabel.translatesAutoresizingMaskIntoConstraints = false

        checkImageView.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 11, weight: .bold))
        checkImageView.translatesAutoresizingMaskIntoConstraints = false

        xImageView.image = NSImage(systemSymbolName: "exclamationmark", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 11, weight: .bold))
        xImageView.translatesAutoresizingMaskIntoConstraints = false

        addSubview(numberLabel)
        addSubview(checkImageView)
        addSubview(xImageView)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: diameter),
            heightAnchor.constraint(equalToConstant: diameter),
            numberLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            numberLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            checkImageView.centerXAnchor.constraint(equalTo: centerXAnchor),
            checkImageView.centerYAnchor.constraint(equalTo: centerYAnchor),
            xImageView.centerXAnchor.constraint(equalTo: centerXAnchor),
            xImageView.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    func configure(number: Int, status: AutomationStepStatus, theme: HelmTheme) {
        numberLabel.isHidden = true
        checkImageView.isHidden = true
        xImageView.isHidden = true
        layer?.borderWidth = 0

        switch status {
        case .done, .skipped:
            checkImageView.isHidden = false
            checkImageView.contentTintColor = HelmTheme.nsColor(theme.selectionTextHex)
            layer?.backgroundColor = HelmTheme.nsColor(theme.ansiHex[2]).cgColor
        case .failed:
            xImageView.isHidden = false
            xImageView.contentTintColor = HelmTheme.nsColor(theme.selectionTextHex)
            layer?.backgroundColor = HelmTheme.nsColor(theme.ansiHex[1]).cgColor
        case .checking, .running, .waitingForCaptain:
            numberLabel.isHidden = false
            numberLabel.stringValue = "\(number)"
            numberLabel.textColor = HelmTheme.nsColor(theme.selectionTextHex)
            layer?.backgroundColor = HelmTheme.nsColor(theme.accentHex).cgColor
            layer?.borderWidth = 3
            layer?.borderColor = HelmTheme.nsColor(theme.accentHex).withAlphaComponent(0.25).cgColor
        case .pending:
            numberLabel.isHidden = false
            numberLabel.stringValue = "\(number)"
            numberLabel.textColor = HelmTheme.mutedInk(theme)
            layer?.backgroundColor = HelmTheme.nsColor(theme.chromeLineHex).withAlphaComponent(0.25).cgColor
        }
    }
}

final class AutomationController: NSViewController {

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

    private var theme: HelmTheme = ThemeManager.shared.theme

    /// Same wiring convention as `BootstrapController.onRunCommand`/
    /// `onRunCommandTracked` (set by `AppShellController`) - the dotfiles
    /// step's clone/rebuild needs a real interactive `sudo` TTY, so it opens
    /// as a Console tab exactly like Bootstrap's own equivalent action.
    var onRunCommandTracked: ((String, String, @escaping (Bool) -> Void) -> Void)?

    private var scrollView: NSScrollView!
    private var dynamicLabels: [NSTextField] = []

    // MARK: Shared check state (independently cached, same data sources Bootstrap reads)

    private var dotfilesRepoPath: String?
    private var repoState: DotfilesRepoState?
    private var agentItems: [AgentInstructionsItem] = []
    private var isLoadingDotfiles = true

    private final class ToolRowState {
        let item: DependencyItem
        var status: DependencyStatus = .unknown
        var isCurrent = false
        init(item: DependencyItem) { self.item = item }
    }
    private var toolRows: [ToolRowState] = DependencyCatalog.items.map(ToolRowState.init)
    private var isLoadingSoftware = true

    // MARK: Sequencer state

    private struct AutomationStepState {
        let kind: SetupStepKind
        var status: AutomationStepStatus = .pending
    }
    private var steps: [AutomationStepState] = SetupStepKind.allCases.map { AutomationStepState(kind: $0) }
    private var isRunning = false

    private let runButton = HelmButton(title: "", variant: .primary)
    private let progressSummaryLabel = NSTextField(wrappingLabelWithString: "")
    private let stepperStack = NSStackView()
    private var stepContentBoxes: [NSView] = []
    private var cards: [HelmCard] = []
    /// A drifted step (`.failed`/`.waitingForCaptain`) gets the notification-
    /// card-style left accent bar (`fm/grandline-setup-attention-row-style`)
    /// - tracked alongside which theme-derived hex it should show, since a
    /// live theme switch calls `applyTheme()` alone (never `rebuildStepper()`,
    /// see `ThemeManager.shared.observe` below) and the bar's color would
    /// otherwise go stale after that switch.
    private var stepAccentBars: [(bar: NSView, hex: (HelmTheme) -> String)] = []

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 620, height: 720))
        root.wantsLayer = true
        view = root
        ThemeManager.shared.observe { [weak root, weak self] theme in
            root?.appearance = NSAppearance(named: theme.mode == .dark ? .darkAqua : .aqua)
            root?.layer?.backgroundColor = HelmTheme.nsColor(theme.backgroundHex).cgColor
            self?.theme = theme
            self?.applyTheme()
            self?.rebuildStepper()
        }

        let subtitle = NSTextField(wrappingLabelWithString: "Runs every setup step below in order, skipping anything already configured on this machine.")
        subtitle.font = .systemFont(ofSize: 12)
        subtitle.translatesAutoresizingMaskIntoConstraints = false

        let runCard = card(icon: "bolt.fill", title: "Run Automation", content: buildRunSection())

        stepperStack.orientation = .vertical
        stepperStack.alignment = .leading
        stepperStack.spacing = 20
        // Populated by `rebuildStepper()` below, right after this view tree
        // is assembled - not here, to avoid building every row twice.
        let stepperCard = card(icon: "list.number", title: "Pipeline", content: stepperStack)

        let stack = NSStackView(views: [subtitle, runCard, stepperCard])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.setCustomSpacing(16, after: subtitle)

        let content = FlippedView()
        content.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: HelmMetrics.pageGutter),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -HelmMetrics.pageGutter),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 18),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
            subtitle.widthAnchor.constraint(equalTo: stack.widthAnchor),
            runCard.widthAnchor.constraint(equalTo: stack.widthAnchor),
            stepperCard.widthAnchor.constraint(equalTo: stack.widthAnchor),
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

        applyTheme()
        rebuildStepper()
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        if isLoadingDotfiles { refreshDotfiles() }
        if isLoadingSoftware { checkAllSoftware() }
        scrollToTop()
    }

    private func scrollToTop() {
        guard let scroll = scrollView else { return }
        scroll.contentView.scroll(to: .zero)
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    // MARK: Card chrome

    /// One `HelmCard` per page section - the shared container from
    /// `HelmDesignSystem.swift`. This used to be a byte-for-byte copy of
    /// `BootstrapController.card` / `GitHubSyncController.card` (audit §3.2:
    /// three identical copies differing only in a registry variable name),
    /// plus its own copy of the theming loop.
    private func card(icon: String, title: String, content: NSView) -> HelmCard {
        let card = HelmCard()
        card.setHeader(symbol: icon, title: title)
        card.setBody(content, insets: HelmCard.contentInsets)
        cards.append(card)
        return card
    }

    // MARK: Run Automation

    private func buildRunSection() -> NSView {
        runButton.title = "Run Automation"
        runButton.target = self
        runButton.action = #selector(runAutomationClicked)
        runButton.setContentHuggingPriority(.required, for: .horizontal)

        progressSummaryLabel.font = .systemFont(ofSize: 11.5)
        progressSummaryLabel.preferredMaxLayoutWidth = 500

        let section = NSStackView(views: [runButton, progressSummaryLabel])
        section.orientation = .vertical
        section.alignment = .leading
        section.spacing = 8
        progressSummaryLabel.widthAnchor.constraint(equalTo: section.widthAnchor).isActive = true
        return section
    }

    private var progressSummary: String {
        if let runningIndex = steps.firstIndex(where: { if case .checking = $0.status { return true }; if case .running = $0.status { return true }; return false }) {
            var line = "Step \(runningIndex + 1) of \(steps.count) \u{2014} \(steps[runningIndex].kind.title)"
            if steps[runningIndex].kind == .software {
                let checked = toolRows.filter { $0.status != .unknown && $0.status != .checking }.count
                line += " (\(checked)/\(toolRows.count) tools checked)"
            }
            return line
        }
        if let waitingIndex = steps.firstIndex(where: { if case .waitingForCaptain = $0.status { return true }; return false }) {
            return "Step \(waitingIndex + 1) of \(steps.count) \u{2014} \(steps[waitingIndex].kind.title): choose a backup file or skip to continue."
        }
        if let failedIndex = steps.firstIndex(where: { if case .failed = $0.status { return true }; return false }) {
            return "Stopped at \(steps[failedIndex].kind.title) - see below for the reason."
        }
        let allResolved = steps.allSatisfy {
            if case .done = $0.status { return true }
            if case .skipped = $0.status { return true }
            return false
        }
        if allResolved && !isRunning {
            return "Completed."
        }
        return "Runs Firstmate home, dotfiles & machine config, agent instructions, software checklist, then restore config in order."
    }

    private func updateStep(_ kind: SetupStepKind, _ status: AutomationStepStatus) {
        guard let index = steps.firstIndex(where: { $0.kind == kind }) else { return }
        steps[index].status = status
        rebuildStepper()
    }

    @objc private func runAutomationClicked() {
        guard !isRunning else { return }
        isRunning = true
        steps = SetupStepKind.allCases.map { AutomationStepState(kind: $0) }
        rebuildStepper()
        runStep(at: 0)
    }

    private func finishRun() {
        isRunning = false
        rebuildStepper()
    }

    private func runStep(at index: Int) {
        guard index < steps.count else { finishRun(); return }
        let kind = steps[index].kind
        updateStep(kind, .checking)
        refreshCheckData(for: kind) { [weak self] in
            guard let self else { return }
            if self.stepIsDone(kind) == true {
                self.updateStep(kind, .skipped)
                self.runStep(at: index + 1)
                return
            }
            self.performStep(kind, index: index)
        }
    }

    /// Re-runs whichever background check a step's `stepIsDone` decision
    /// depends on, right before deciding skip-vs-run - mirrors
    /// `BootstrapController.runSetupStepDotfiles`'s own "never trust a stale
    /// in-memory result" comment.
    private func refreshCheckData(for kind: SetupStepKind, completion: @escaping () -> Void) {
        switch kind {
        case .firstmateHome, .restoreConfig:
            completion()
        case .dotfiles, .agentInstructions:
            refreshDotfiles(completion: completion)
        case .software:
            checkAllSoftware(completion: completion)
        }
    }

    private func performStep(_ kind: SetupStepKind, index: Int) {
        switch kind {
        case .firstmateHome:
            // No captain-facing action exists here (see `BootstrapController`'s
            // own "Firstmate home" card) - if it's not already set up, stop and
            // point at where to fix it, exactly like Bootstrap's own sequencer
            // does for this same step.
            updateStep(.firstmateHome, .failed("Firstmate home is not set up - use Bootstrap's Firstmate home card to locate or clone one, then run automation again."))
            finishRun()
        case .dotfiles:
            updateStep(.dotfiles, .running)
            guard let onRunCommandTracked else {
                updateStep(.dotfiles, .failed("No console wiring available."))
                finishRun()
                return
            }
            let (label, command) = DotfilesRunCommand.runOrCloneCommand(repoPath: dotfilesRepoPath, clonePathFieldValue: "")
            onRunCommandTracked(label, command) { [weak self] ok in
                guard let self else { return }
                if ok {
                    self.updateStep(.dotfiles, .done)
                    self.runStep(at: index + 1)
                } else {
                    self.updateStep(.dotfiles, .failed("\(label) exited with a non-zero status - see its Console tab for output."))
                    self.finishRun()
                }
            }
        case .agentInstructions:
            updateStep(.agentInstructions, .running)
            refreshDotfiles { [weak self] in
                guard let self else { return }
                self.updateStep(.agentInstructions, .done)
                self.runStep(at: index + 1)
            }
        case .software:
            updateStep(.software, .running)
            installAllMissing { [weak self] allOk in
                guard let self else { return }
                if allOk {
                    self.updateStep(.software, .done)
                    self.runStep(at: index + 1)
                } else {
                    self.updateStep(.software, .failed("One or more installs failed - see the software checklist below for detail."))
                    self.finishRun()
                }
            }
        case .restoreConfig:
            // Real captain interaction required (a file picker) - pause here
            // rather than guessing a file or silently skipping, per this
            // task's brief. `restoreConfigChooseFileClicked`/
            // `restoreConfigSkipClicked` (wired on the step row itself) both
            // call `continueRestoreConfigStep`.
            updateStep(.restoreConfig, .waitingForCaptain)
        }
    }

    private func continueRestoreConfigStep(skipped: Bool) {
        guard let index = steps.firstIndex(where: { $0.kind == .restoreConfig }) else { return }
        steps[index].status = skipped ? .skipped : .done
        rebuildStepper()
        guard isRunning else { return }
        runStep(at: index + 1)
    }

    @objc private func restoreConfigChooseFileClicked() {
        guard steps.first(where: { $0.kind == .restoreConfig })?.status == .waitingForCaptain else { return }
        BackupUI.importFlow(from: self, hostStore: hostStore, keyStore: keyStore, snippetStore: snippetStore, dictationStore: dictationStore) { [weak self] in
            self?.continueRestoreConfigStep(skipped: false)
        }
    }

    @objc private func restoreConfigSkipClicked() {
        guard steps.first(where: { $0.kind == .restoreConfig })?.status == .waitingForCaptain else { return }
        continueRestoreConfigStep(skipped: true)
    }

    // MARK: Same underlying checks Bootstrap reads - see `SetupStepChecks.swift`

    private func stepIsDone(_ kind: SetupStepKind) -> Bool? {
        switch kind {
        case .firstmateHome:
            return SetupStepChecks.firstmateHomeDone()
        case .dotfiles:
            return SetupStepChecks.dotfilesDone(isLoading: isLoadingDotfiles, repoPath: dotfilesRepoPath, state: repoState)
        case .agentInstructions:
            return SetupStepChecks.agentInstructionsDone(isLoading: isLoadingDotfiles, items: agentItems)
        case .software:
            return SetupStepChecks.softwareDone(isLoading: isLoadingSoftware, statuses: toolRows.map { $0.status })
        case .restoreConfig:
            return SetupStepChecks.restoreConfigDone(hostCount: hostStore.hosts.count, snippetCount: snippetStore.snippets.count)
        }
    }

    private func refreshDotfiles(completion: (() -> Void)? = nil) {
        guard isViewLoaded else { completion?(); return }
        isLoadingDotfiles = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let resolved = DotfilesSource.resolvedDotfilesPath()
            var state: DotfilesRepoState?
            var agents: [AgentInstructionsItem] = []
            if let resolved {
                state = DotfilesSource.repoState(at: resolved)
                agents = DotfilesSource.agentInstructionItems(repoPath: resolved)
            } else {
                agents = DotfilesSource.agentInstructionPaths.map {
                    AgentInstructionsItem(label: $0.label, path: $0.path, status: .notLinked)
                }
            }
            DispatchQueue.main.async {
                guard let self else { completion?(); return }
                self.dotfilesRepoPath = resolved
                self.repoState = state
                self.agentItems = agents
                self.isLoadingDotfiles = false
                self.rebuildStepper()
                completion?()
            }
        }
    }

    /// Checks every catalog item via the exact `UpdatesSource.check` the
    /// Updates page and Bootstrap's own Software checklist card use.
    private func checkAllSoftware(completion: (() -> Void)? = nil) {
        isLoadingSoftware = true
        rebuildStepper()
        let items = toolRows.map { $0.item }
        DispatchQueue.global(qos: .userInitiated).async {
            let outcomes = items.map { ($0.id, UpdatesSource.check($0)) }
            DispatchQueue.main.async { [weak self] in
                guard let self else { completion?(); return }
                for (id, outcome) in outcomes {
                    guard let row = self.toolRows.first(where: { $0.item.id == id }) else { continue }
                    row.status = outcome.status
                }
                self.isLoadingSoftware = false
                self.rebuildStepper()
                completion?()
            }
        }
    }

    /// Installs every row currently `.notInstalled`, one at a time - never
    /// concurrently, matching `BootstrapController.installAllMissing`'s own
    /// "don't race two package-manager invocations" reasoning - via the same
    /// `UpdatesSource.update`/`.check` pair. Marks the row it's currently
    /// working on so the chip grid can highlight it live.
    private func installAllMissing(completion: @escaping (Bool) -> Void) {
        let missing = toolRows.filter { $0.status == .notInstalled }
        guard !missing.isEmpty else { completion(true); return }
        var overallOk = true
        func runNext(_ index: Int) {
            guard index < missing.count else { completion(overallOk); return }
            let row = missing[index]
            row.isCurrent = true
            rebuildStepper()
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let outcome = UpdatesSource.update(row.item)
                let recheck = UpdatesSource.check(row.item)
                DispatchQueue.main.async {
                    guard let self else { completion(false); return }
                    row.isCurrent = false
                    row.status = recheck.status
                    if !outcome.ok { overallOk = false }
                    self.rebuildStepper()
                    runNext(index + 1)
                }
            }
        }
        runNext(0)
    }

    // MARK: Stepper rendering

    private func statusVisuals(_ status: AutomationStepStatus) -> (String, String) {
        switch status {
        case .pending: return ("Pending", theme.chromeInkHex)
        case .checking: return ("Checking\u{2026}", theme.chromeInkHex)
        case .running: return ("Running\u{2026}", theme.chromeInkHex)
        case .waitingForCaptain: return ("Needs you", theme.ansiHex[3])
        case .done: return ("Done", theme.ansiHex[2])
        case .skipped: return ("Skipped - already there", theme.ansiHex[2])
        case .failed: return ("Failed", theme.ansiHex[1])
        }
    }

    private func buildStepRow(kind: SetupStepKind, number: Int, isLast: Bool) -> NSView {
        let status = steps.first(where: { $0.kind == kind })?.status ?? .pending

        let dot = AutomationStepDotView()
        dot.configure(number: number, status: status, theme: theme)

        let line = NSView()
        line.wantsLayer = true
        line.translatesAutoresizingMaskIntoConstraints = false
        line.isHidden = isLast

        let leftColumn = NSView()
        leftColumn.translatesAutoresizingMaskIntoConstraints = false
        leftColumn.addSubview(dot)
        leftColumn.addSubview(line)
        NSLayoutConstraint.activate([
            dot.topAnchor.constraint(equalTo: leftColumn.topAnchor),
            dot.centerXAnchor.constraint(equalTo: leftColumn.centerXAnchor),
            leftColumn.widthAnchor.constraint(equalTo: dot.widthAnchor),
            line.widthAnchor.constraint(equalToConstant: 2),
            line.centerXAnchor.constraint(equalTo: dot.centerXAnchor),
            line.topAnchor.constraint(equalTo: dot.bottomAnchor, constant: 4),
            line.bottomAnchor.constraint(equalTo: leftColumn.bottomAnchor),
        ])

        let titleLabel = NSTextField(labelWithString: kind.title)
        titleLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        dynamicLabels.append(titleLabel)

        let pillLabel = NSTextField(labelWithString: "")
        pillLabel.font = .systemFont(ofSize: 10, weight: .semibold)
        pillLabel.translatesAutoresizingMaskIntoConstraints = false
        let pillContainer = NSView()
        pillContainer.wantsLayer = true
        pillContainer.layer?.cornerRadius = 8
        pillContainer.translatesAutoresizingMaskIntoConstraints = false
        pillContainer.addSubview(pillLabel)
        NSLayoutConstraint.activate([
            pillLabel.leadingAnchor.constraint(equalTo: pillContainer.leadingAnchor, constant: 7),
            pillLabel.trailingAnchor.constraint(equalTo: pillContainer.trailingAnchor, constant: -7),
            pillLabel.topAnchor.constraint(equalTo: pillContainer.topAnchor, constant: 2),
            pillLabel.bottomAnchor.constraint(equalTo: pillContainer.bottomAnchor, constant: -2),
        ])
        pillContainer.setContentHuggingPriority(.required, for: .horizontal)
        pillContainer.setContentCompressionResistancePriority(.required, for: .horizontal)

        let (pillText, pillColorHex) = statusVisuals(status)
        pillLabel.stringValue = pillText
        pillLabel.textColor = HelmTheme.nsColor(pillColorHex)
        pillContainer.layer?.backgroundColor = HelmTheme.nsColor(pillColorHex).withAlphaComponent(0.15).cgColor

        let titleRow = NSStackView(views: [titleLabel, pillContainer])
        titleRow.orientation = .horizontal
        titleRow.alignment = .centerY
        titleRow.spacing = 8

        let detailLabel = NSTextField(wrappingLabelWithString: stepDetail(for: kind))
        detailLabel.font = .systemFont(ofSize: 11.5)
        detailLabel.preferredMaxLayoutWidth = 500
        detailLabel.textColor = HelmTheme.mutedInk(theme)
        dynamicLabels.append(detailLabel)

        var bodyViews: [NSView] = [titleRow, detailLabel]

        if kind == .software {
            bodyViews.append(buildSoftwareChecklistGrid())
        }
        if kind == .restoreConfig {
            bodyViews.append(buildRestoreConfigActions(isWaiting: status == .waitingForCaptain))
        }

        let contentBox = stepContentBox(bodyViews: bodyViews)

        // Only `.failed`/`.waitingForCaptain` genuinely need eyes on them -
        // `.pending`/`.checking`/`.running`/`.done`/`.skipped` keep the
        // box's existing plain look untouched
        // (`fm/grandline-setup-attention-row-style`).
        let attentionHex: ((HelmTheme) -> String)?
        switch status {
        case .failed: attentionHex = { $0.ansiHex[1] }
        case .waitingForCaptain: attentionHex = { $0.ansiHex[3] }
        case .pending, .checking, .running, .done, .skipped: attentionHex = nil
        }
        let stepAccentBar = NSView()
        ToolRowLayout.attachAccentBar(stepAccentBar, to: contentBox, verticalInset: 8)
        if let attentionHex {
            ToolRowLayout.setAccentBar(stepAccentBar, colorHex: attentionHex(theme))
            stepAccentBars.append((bar: stepAccentBar, hex: attentionHex))
        } else {
            ToolRowLayout.setAccentBar(stepAccentBar, colorHex: nil)
        }

        let bodyStack = NSStackView(views: [contentBox])
        bodyStack.orientation = .vertical
        bodyStack.alignment = .leading
        bodyStack.spacing = 8
        contentBox.widthAnchor.constraint(equalTo: bodyStack.widthAnchor).isActive = true

        leftColumn.setContentHuggingPriority(.required, for: .horizontal)
        leftColumn.setContentCompressionResistancePriority(.required, for: .horizontal)
        bodyStack.setContentHuggingPriority(.defaultLow, for: .horizontal)
        bodyStack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let row = NSStackView(views: [leftColumn, bodyStack])
        row.orientation = .horizontal
        row.alignment = .top
        row.spacing = 14
        // `.gravityAreas` (the default) ignores hugging priorities for slack
        // width - see this project's CLAUDE.md AppKit-gotchas note (#10) -
        // `.fill` is what makes `bodyStack`/`contentBox` actually absorb the
        // row's available width.
        row.distribution = .fill
        leftColumn.heightAnchor.constraint(equalTo: bodyStack.heightAnchor).isActive = true

        row.identifier = NSUserInterfaceItemIdentifier(kind.title)
        return row
    }

    private func stepContentBox(bodyViews: [NSView]) -> NSView {
        let content = NSStackView(views: bodyViews)
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 8
        content.translatesAutoresizingMaskIntoConstraints = false
        for v in bodyViews { v.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true }

        let box = NSView()
        box.wantsLayer = true
        box.layer?.cornerRadius = 10
        box.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 12),
            content.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -12),
            content.topAnchor.constraint(equalTo: box.topAnchor, constant: 10),
            content.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -10),
        ])
        stepContentBoxes.append(box)
        return box
    }

    /// The one place the software step's per-tool checklist renders - a
    /// small rounded, status-tinted chip per `DependencyCatalog` item, never
    /// collapsed into a single "Software (N tools)" summary line.
    private func buildSoftwareChecklistGrid() -> NSView {
        let columns = 3
        let rows = toolRows.chunked(into: columns)
        let gridStack = NSStackView()
        gridStack.orientation = .vertical
        gridStack.alignment = .leading
        gridStack.spacing = 6
        gridStack.translatesAutoresizingMaskIntoConstraints = false
        for rowItems in rows {
            let rowStack = NSStackView(views: rowItems.map { toolChipView($0) })
            rowStack.orientation = .horizontal
            rowStack.alignment = .centerY
            rowStack.spacing = 6
            gridStack.addArrangedSubview(rowStack)
        }
        return gridStack
    }

    private func toolChipView(_ row: ToolRowState) -> NSView {
        let dot = NSView()
        dot.wantsLayer = true
        dot.translatesAutoresizingMaskIntoConstraints = false
        dot.layer?.cornerRadius = 3.5
        NSLayoutConstraint.activate([
            dot.widthAnchor.constraint(equalToConstant: 7),
            dot.heightAnchor.constraint(equalToConstant: 7),
        ])

        let label = NSTextField(labelWithString: row.item.name)
        label.font = .systemFont(ofSize: 11, weight: .medium)
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        dynamicLabels.append(label)

        let innerStack = NSStackView(views: [dot, label])
        innerStack.orientation = .horizontal
        innerStack.spacing = 6
        innerStack.alignment = .centerY
        innerStack.translatesAutoresizingMaskIntoConstraints = false

        let chip = NSView()
        chip.wantsLayer = true
        chip.layer?.cornerRadius = 9
        chip.translatesAutoresizingMaskIntoConstraints = false
        chip.widthAnchor.constraint(lessThanOrEqualToConstant: 190).isActive = true
        chip.addSubview(innerStack)
        NSLayoutConstraint.activate([
            innerStack.leadingAnchor.constraint(equalTo: chip.leadingAnchor, constant: 10),
            innerStack.trailingAnchor.constraint(equalTo: chip.trailingAnchor, constant: -10),
            innerStack.topAnchor.constraint(equalTo: chip.topAnchor, constant: 6),
            innerStack.bottomAnchor.constraint(equalTo: chip.bottomAnchor, constant: -6),
        ])

        // A fresh chip every call (this whole grid is torn down and rebuilt
        // on every status change, see `rebuildStepper`'s doc comment), so a
        // brand-new accent bar here needs no idempotency guard - `build()`'s
        // `superview !== ...` dance is only needed for a persistent, reused
        // container.
        let accentBar = NSView()
        ToolRowLayout.attachAccentBar(accentBar, to: chip, verticalInset: 4, width: 2.5)
        applyChipTheme(chip: chip, dot: dot, label: label, accentBar: accentBar, row: row)
        return chip
    }

    /// The three visual states the brief asks for - "a soft good tint for
    /// done, a highlighted accent-bordered tint for the one currently
    /// running, muted/plain for pending" - plus a fourth (critical) for a
    /// genuine check/install failure, which the brief's three named states
    /// don't cover but this page still needs to represent honestly. The
    /// failure case is also the one that gets the notification-card-style
    /// left accent bar (`fm/grandline-setup-attention-row-style`) - a
    /// pending/done/running chip already reads calmly via its own fill/dot
    /// color and shouldn't grow extra chrome.
    private func applyChipTheme(chip: NSView, dot: NSView, label: NSTextField, accentBar: NSView, row: ToolRowState) {
        let hex: String
        var borderHex: String?
        let isFailed = row.status == .checkFailed || row.status == .updateFailed
        if row.isCurrent {
            hex = theme.accentHex
            borderHex = theme.accentHex
        } else if isFailed {
            hex = theme.ansiHex[1]
        } else if row.status == .upToDate || row.status == .updateAvailable {
            hex = theme.ansiHex[2]
        } else {
            hex = theme.chromeInkHex
        }
        let color = HelmTheme.nsColor(hex)
        dot.layer?.backgroundColor = color.cgColor
        chip.layer?.backgroundColor = color.withAlphaComponent(row.isCurrent ? 0.16 : 0.10).cgColor
        if let borderHex {
            chip.layer?.borderWidth = 1.5
            chip.layer?.borderColor = HelmTheme.nsColor(borderHex).cgColor
        } else {
            chip.layer?.borderWidth = 0
        }
        label.textColor = HelmTheme.nsColor(theme.chromeInkHex)
        ToolRowLayout.setAccentBar(accentBar, colorHex: isFailed ? theme.ansiHex[1] : nil)
    }

    private func buildRestoreConfigActions(isWaiting: Bool) -> NSView {
        let chooseButton = HelmButton(title: "Choose file\u{2026}", variant: .primary, target: self, action: #selector(restoreConfigChooseFileClicked))
        chooseButton.controlSize = .small
        chooseButton.isEnabled = isWaiting

        let skipButton = HelmButton(title: "Skip", variant: .secondary, target: self, action: #selector(restoreConfigSkipClicked))
        skipButton.controlSize = .small
        skipButton.isEnabled = isWaiting

        let row = NSStackView(views: [chooseButton, skipButton])
        row.orientation = .horizontal
        row.spacing = 8
        row.isHidden = !isWaiting
        return row
    }

    /// Full teardown-and-rebuild on every status change (mirrors
    /// `BootstrapController.rebuildSoftwareSection`'s own "tear down and
    /// rebuild" convention, not the stepper-row-mutated-in-place convention
    /// that file uses elsewhere) - each row is built fresh from the current
    /// `steps` array, so there is no separate pass needed to patch pill/
    /// detail/dot state into an existing view afterward.
    private func rebuildStepper() {
        guard isViewLoaded else { return }
        stepContentBoxes.removeAll()
        stepAccentBars.removeAll()
        dynamicLabels.removeAll()
        for v in stepperStack.arrangedSubviews {
            stepperStack.removeArrangedSubview(v)
            v.removeFromSuperview()
        }
        for (index, step) in steps.enumerated() {
            let row = buildStepRow(kind: step.kind, number: index + 1, isLast: index == steps.count - 1)
            stepperStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: stepperStack.widthAnchor).isActive = true
        }

        runButton.title = isRunning ? "Running\u{2026}" : "Run Automation"
        runButton.isEnabled = !isRunning
        progressSummaryLabel.stringValue = progressSummary
        progressSummaryLabel.textColor = HelmTheme.mutedInk(theme)
        applyTheme()
    }

    private func stepDetail(for kind: SetupStepKind) -> String {
        switch kind {
        case .firstmateHome:
            return FirstmateHome.root.path
        case .dotfiles:
            if isLoadingDotfiles { return "Checking ~/.dotfiles\u{2026}" }
            return dotfilesRepoPath ?? "~/.dotfiles was not found on this machine."
        case .agentInstructions:
            return "Verifies the three harness-expected AGENTS.md/CLAUDE.md symlinks resolve to the dotfiles repo."
        case .software:
            if isLoadingSoftware { return "Checking installed tools\u{2026}" }
            let missing = toolRows.filter { $0.status == .notInstalled }.count
            return missing == 0 ? "All \(toolRows.count) tracked tools installed." : "\(missing) of \(toolRows.count) tracked tools not installed."
        case .restoreConfig:
            return "Import a .glbackup file exported from another machine to bring in its saved hosts, snippets, and preferences here."
        }
    }

    private func applyTheme() {
        guard isViewLoaded else { return }
        let line = HelmTheme.nsColor(theme.chromeLineHex)
        for card in cards { card.applyTheme(theme) }
        for v in stepContentBoxes {
            v.layer?.backgroundColor = line.withAlphaComponent(0.08).cgColor
            v.layer?.borderWidth = 1
            v.layer?.borderColor = line.withAlphaComponent(0.3).cgColor
        }
        for label in dynamicLabels {
            label.textColor = HelmTheme.nsColor(theme.chromeInkHex)
        }
        for (bar, hex) in stepAccentBars {
            ToolRowLayout.setAccentBar(bar, colorHex: hex(theme))
        }
    }
}
