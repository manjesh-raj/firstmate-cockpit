// Manjesh Grand Line - native macOS app.
//
// The `.bootstrap` rail destination. Phase 1 (cockpit-bootstrap-scaffold,
// merged) was scaffold-only: a single "Firstmate home" card, laid out with
// the same card chrome `SettingsController` established (icon + title
// header, rounded bordered background, `FlippedView` + scrollToTop for the
// same empty-gap-above-header fix that page and `FleetController`/
// `ReviewController` carry).
//
// Phase 2 (cockpit-bootstrap-dotfiles) added two more sections below it, both
// driven by live checks against this machine's real files - see
// `DotfilesData.swift` for the model side:
//   - "Dotfiles & machine config": detects `~/.dotfiles` (the captain's Nix
//     flake, nix-darwin + home-manager + nix-homebrew), or offers to clone
//     and bootstrap one if absent; shows repo path/branch/dirty-status, a
//     live-parsed macOS username field, a managed-items table, and the
//     Run rebuild.sh action.
//   - "Global agent instructions": read-only verification of the three
//     harness-expected filenames (`~/.claude/CLAUDE.md`, `~/.codex/AGENTS.md`,
//     `~/.config/opencode/AGENTS.md`) that `home.nix` symlinks to one shared
//     `<dotfiles>/home/AGENTS.md`.
//
// Phase 3 (cockpit-bootstrap-software, this file) adds a fourth section:
//   - "Software checklist": one row per `DependencyCatalog.items`
//     (`UpdatesData.swift`), grouped by `DependencyCatalog.categoryOrder`,
//     checked with the exact same `UpdatesSource.check`/`.update` the Updates
//     page uses - no separate catalog or check logic lives here. A
//     `.notInstalled` row gets an "Install" button (`UpdatesSource.update`,
//     the same idempotent install-or-upgrade action Updates' own "Update"
//     button calls for that case), re-checked on completion. This is also
//     the destination the Updates page's `.notInstalled` rows now link to
//     instead of installing inline - see `UpdatesController`'s row-render
//     code and `AppShellController.show(.bootstrap)`.
// Phase 4 (cockpit-bootstrap-full-setup, this file) adds the "Run full setup"
// card at the top of the page: a single button that sequences the three
// sections below for the true blank-machine case, showing a shared ordered
// progress list (pending/running/done/skipped/failed) rather than requiring
// the captain to click each card's own action in order. It is a sequencer,
// not a reimplementation - every step calls the exact same method its card's
// own standalone button already calls:
//   1. Firstmate home - a pure status check (`FirstmateHome.homeOk`); if not
//      already OK, the sequence stops here and points at the home card's own
//      Save & Verify flow rather than guessing a path.
//   2. Dotfiles & machine config - always runs (rebuild.sh/bootstrap.sh are
//      idempotent): clones if `~/.dotfiles` is absent, else runs rebuild.sh.
//      Both reuse `onRunCommandTracked` (a completion-carrying sibling of
//      `onRunCommand`) so the sequencer waits for the real Console tab exit
//      before continuing, never a fixed timer.
//   3. Global agent instructions - a re-check only, since it resolves itself
//      once step 2's home-manager run has completed.
//   4. Software checklist - runs the card's new "Install everything missing"
//      action (`installAllMissing`, added in this phase alongside its
//      per-row Install, both funneling through the same `performInstall`)
//      only if a row is still `.notInstalled` after checking.
// A step failure stops the sequence there; it never silently continues past
// a failed step. Section 5 ("secrets/keys/GitHub auth", not part of this
// page) never gets a button in this chain - it stays permanently manual.
//
// Any action that can invoke `darwin-rebuild switch` (clone+bootstrap.sh,
// rebuild.sh, and Part B's "Create link", which just re-runs rebuild.sh)
// needs `sudo`'s interactive TTY prompt, so all three go through
// `onRunCommand`, wired by `AppShellController.runInConsole` to open a real
// Console tab - never a silent background `Process` (see
// `ConsoleController.openCommandTab`).
//
// "Make local state portable" roadmap, part 3 of 3 (parts 1-2 - export/import
// with GitHub support, and this page's "Restore Grand Line config" step -
// shipped in PR #85/#86): the "Drift check" card, below the setup stepper,
// re-runs each of the five steps' own `stepIsDone` check on demand and
// reports anything that's no longer satisfied. It adds no new detection
// logic - `stepIsDone`/`refreshDotfiles`/`checkAllSoftware` are the exact
// same functions the stepper itself already calls. It is a "card, rebuilt in
// place" section like Dotfiles/Agent/Software (`rebuildDriftSection`), not
// mutated-in-place like the stepper rows, since its row count varies with how
// many steps have drifted and there's no persistent inner view (like a
// stepper row's `stepContentBox`) at risk of being reparented.
//
// Deliberately on-demand only, not polled on a timer: the initial status
// shown when the page loads is *seeded for free* from the same background
// checks `refreshDotfiles`/`checkAllSoftware` already run for the stepper
// (`maybeSeedInitialDriftStatus`, called once both finish) - no extra
// process/network calls happen just by visiting this page. Only clicking
// "Re-check now" re-runs those checks a second time. A periodic auto-poll
// was considered and rejected: re-running `git`/`brew`/`npm` checks in the
// background on a timer is exactly the kind of surprise background work this
// project's own guidance says to avoid by default.
//
// The Firstmate-home card lets the captain see and override
// `FirstmateHome.root` - which is a `static let`, resolved once at process
// launch (see that file) - so a change here can only take effect after a
// restart. Save & Verify never live-repoints already-resolved paths; it
// persists the candidate to `AppSettings.fmHome` and asks for a restart.

import AppKit

/// One step's live wizard state (cockpit-modern-ui-bootstrap) - distinct from
/// `BootstrapController.SetupStepStatus`, which tracks the transient
/// "Run full setup" sequencer's running/failed/etc state for one pass. This
/// tracks whether a step is *configured* at all, derived fresh from the same
/// checks (`FirstmateHome.homeOk`, `dotfilesRepoPath`, `agentItems`,
/// `softwareRows`) every other part of this page already reads - never
/// hardcoded.
private enum StepperDotState: Equatable {
    case done, current, pending
}

/// The mockup's numbered/checkmark stepper dot (`.step-dot`) - a plain
/// layer-backed circle, deliberately simpler than `IconTileView` (a square
/// SF-Symbol tile) since a step dot is either a number or a checkmark, never
/// an arbitrary glyph.
private final class StepDotView: NSView {
    private let numberLabel = NSTextField(labelWithString: "")
    private let checkImageView = NSImageView()
    private let diameter: CGFloat = 30

    override init(frame frameRect: NSRect) {
        super.init(frame: .zero)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        layer?.cornerRadius = diameter / 2

        numberLabel.font = .systemFont(ofSize: 12.5, weight: .bold)
        numberLabel.alignment = .center
        numberLabel.translatesAutoresizingMaskIntoConstraints = false

        checkImageView.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 12, weight: .bold))
        checkImageView.translatesAutoresizingMaskIntoConstraints = false

        addSubview(numberLabel)
        addSubview(checkImageView)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: diameter),
            heightAnchor.constraint(equalToConstant: diameter),
            numberLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            numberLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            checkImageView.centerXAnchor.constraint(equalTo: centerXAnchor),
            checkImageView.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not supported")
    }

    func configure(number: Int, state: StepperDotState, theme: HelmTheme) {
        switch state {
        case .done:
            numberLabel.isHidden = true
            checkImageView.isHidden = false
            checkImageView.contentTintColor = HelmTheme.nsColor(theme.selectionTextHex)
            layer?.backgroundColor = HelmTheme.nsColor(theme.ansiHex[2]).cgColor
            layer?.borderWidth = 0
        case .current:
            numberLabel.isHidden = false
            checkImageView.isHidden = true
            numberLabel.stringValue = "\(number)"
            numberLabel.textColor = HelmTheme.nsColor(theme.selectionTextHex)
            layer?.backgroundColor = HelmTheme.nsColor(theme.accentHex).cgColor
            layer?.borderWidth = 3
            layer?.borderColor = HelmTheme.nsColor(theme.accentHex).withAlphaComponent(0.25).cgColor
        case .pending:
            numberLabel.isHidden = false
            checkImageView.isHidden = true
            numberLabel.stringValue = "\(number)"
            numberLabel.textColor = HelmTheme.mutedInk(theme)
            layer?.backgroundColor = HelmTheme.nsColor(theme.chromeLineHex).withAlphaComponent(0.25).cgColor
            layer?.borderWidth = 0
        }
    }
}

/// Whether "Run full setup" (Part D) should sequence this step. This one is
/// deliberately excluded: unlike the other four, restoring a config requires
/// the captain to pick a real file via `NSOpenPanel` - there's nothing to
/// automate, and forcing an import prompt into an unattended sequence would
/// violate "never force an import when there's nothing to restore from." It
/// still appears as the fifth step in the main vertical stepper below, just
/// outside the automated chain. Bootstrap-specific and unchanged by
/// fm/grandline-automation-pipeline - `AutomationController`'s own sequencer
/// always runs all five steps, including restore config.
extension SetupStepKind {
    var isPartOfFullSetupSequence: Bool { self != .restoreConfig }
}

final class BootstrapController: NSViewController {

    /// The three stores the "Restore Grand Line config" step reads/writes
    /// through the shared `BackupUI.importFlow` (fm/cockpit-local-state-
    /// portable) - injected the same way `AppShellController` stays ignorant
    /// of `HostStore` via `onPresentHostEditor`.
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

    private let subtitleLabel = NSTextField(labelWithString: "Machine setup and environment bootstrap - stored locally on this machine.")

    private let currentPathLabel = NSTextField(labelWithString: "")
    private let pathField = NSTextField()
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let saveButton = NSButton()
    private let restartButton = NSButton()

    /// Set by `AppShellController` (mirrors `onPresentHostEditor`'s wiring
    /// pattern) so this controller can ask for a command to run in the
    /// shared Console tab, without knowing anything about `ConsoleController`
    /// itself.
    var onRunCommand: ((String, String) -> Void)?

    /// Same wiring as `onRunCommand`, but for callers (the "Run full setup"
    /// sequencer below) that need to know when the command's Console tab
    /// actually exits, not just that it was started.
    var onRunCommandTracked: ((String, String, @escaping (Bool) -> Void) -> Void)?

    private var cardBackgroundViews: [NSView] = []
    private var scrollView: NSScrollView!

    // MARK: Dotfiles state (Part A + B)

    private var dotfilesRepoPath: String?
    private var repoState: DotfilesRepoState?
    private var managedItems: [ManagedItem] = []
    private var agentItems: [AgentInstructionsItem] = []
    private var isLoadingDotfiles = true

    private let dotfilesStack = NSStackView()
    private let agentStack = NSStackView()
    private let clonePathField = NSTextField(string: DotfilesSource.defaultClonePath)
    private let usernameField = NSTextField()
    private let dotfilesStatusLabel = NSTextField(wrappingLabelWithString: "")

    // MARK: Software checklist state (Part C)

    /// Mutable per-row state for one `DependencyItem` - mirrors
    /// `UpdatesController`'s private `UpdateRow`. The views are recreated
    /// fresh on every `rebuildSoftwareSection()` call (this card's existing
    /// tear-down-and-rebuild convention, unlike Updates' build-once-mutate-
    /// in-place rows), so `log`/`isLogExpanded` persist here on the row
    /// itself and get fed back into the freshly-built views each rebuild.
    private final class SoftwareRowState {
        let item: DependencyItem
        var status: DependencyStatus = .unknown
        var detail: String = "Not checked yet"
        var log: String = ""
        var isLogExpanded = false
        var isBusy = false
        init(item: DependencyItem) { self.item = item }
    }

    private var softwareRows: [SoftwareRowState] = DependencyCatalog.items.map(SoftwareRowState.init)
    private var isLoadingSoftware = true
    private var hasCheckedSoftwareOnce = false
    private let softwareStack = NSStackView()

    // MARK: Restore Grand Line config state (fm/cockpit-local-state-portable)

    private let restoreStack = NSStackView()
    private let restoreStatusLabel = NSTextField(wrappingLabelWithString: "")

    // MARK: Drift check state (fm/cockpit-bootstrap-drift-check)

    private var driftResults: [SetupStepKind: Bool?] = [:]
    private var driftLastChecked: Date?
    private var isDriftChecking = false
    private let driftStack = NSStackView()
    private let driftDescLabel = NSTextField(wrappingLabelWithString: "Re-runs each setup step's own check to confirm nothing has drifted since setup - a dotfile that got unlinked, a tool that got uninstalled, or a config that got reverted.")
    private let driftStatusLabel = NSTextField(labelWithString: "")
    private let driftLastCheckedLabel = NSTextField(labelWithString: "")
    private let driftRecheckButton = NSButton()

    private static let driftTimestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }()

    // MARK: "Not synced here, by design" state (Part E, extended in
    // cockpit-bootstrap-vault-hardeners to add aws/codex/brew alongside gh)

    private var ghHardenStatus: GhHardenState = .checking
    private var isHardeningGh = false
    private var awsHardenStatus: AwsHardenState = .checking
    private var isHardeningAws = false
    private var codexHardenStatus: HardenerStatus = .checking
    private var isHardeningCodex = false
    private var homebrewHardenStatus: HardenerStatus = .checking
    private var isHardeningHomebrew = false
    private var homebrewDisruptionAcknowledged = false
    private var hasCheckedHardenersOnce = false
    private let notSyncedStack = NSStackView()

    // MARK: "Run full setup" sequencer state (Part D)

    // `SetupStepKind` itself (title/symbol) now lives in `SetupStepChecks.swift`
    // - shared with `AutomationController` (fm/grandline-automation-pipeline)
    // so both pages iterate the identical five steps. `isPartOfFullSetupSequence`
    // (below, at file scope since Swift extensions can't nest inside a class
    // body) stays Bootstrap-specific and unchanged - it has no meaning for
    // Automation's own sequencer, which always runs all five steps, including
    // restore config, with its own file-picker pause.

    private enum SetupStepStatus: Equatable {
        case pending, checking, running, done, skipped, failed(String)
    }

    private struct SetupStepState {
        let kind: SetupStepKind
        var status: SetupStepStatus = .pending
    }

    private var setupSteps: [SetupStepState] = SetupStepKind.allCases.filter { $0.isPartOfFullSetupSequence }.map { SetupStepState(kind: $0) }
    private var isRunningFullSetup = false
    private let setupStack = NSStackView()
    private let runFullSetupButton = NSButton()
    private let fullSetupSubtitleLabel = NSTextField(wrappingLabelWithString: "")
    private let progressTrack = NSView()
    private let progressFill = NSView()
    private var progressFillWidthConstraint: NSLayoutConstraint?
    private let progressTrackWidth: CGFloat = 120

    // MARK: Vertical stepper (cockpit-modern-ui-bootstrap)

    /// The four persistent per-row views the stepper mutates in place on every
    /// refresh (`refreshStepperVisuals`) - built once in `loadView`, never torn
    /// down and rebuilt, unlike this file's other dynamic sections. That's a
    /// deliberate departure from the `clearStack`/`dynamicLabels` convention
    /// below: those sections rebuild fresh child views into a persistent
    /// *container* each time, but a stepper row's container itself wraps
    /// another persistent container (`dotfilesStack`/`agentStack`/
    /// `softwareStack`) - recreating the wrapper each refresh would repeatedly
    /// reparent that inner view into a brand-new box, leaving the old box's
    /// now-dangling layout constraints on the inner view. Mutating in place
    /// avoids that entirely.
    private struct StepRowViews {
        let dot: StepDotView
        let line: NSView
        let titleLabel: NSTextField
        let chipContainer: NSView
        let chipLabel: NSTextField
        let detailLabel: NSTextField
    }
    private var stepRowViews: [SetupStepKind: StepRowViews] = [:]
    private var stepContentBackgrounds: [NSView] = []
    private var homeSectionContent: NSView!

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 620, height: 720))
        root.wantsLayer = true
        view = root
        ThemeManager.shared.observe { [weak root, weak self] theme in
            root?.appearance = NSAppearance(named: theme.mode == .dark ? .darkAqua : .aqua)
            root?.layer?.backgroundColor = HelmTheme.nsColor(theme.backgroundHex).cgColor
            self?.theme = theme
            self?.applyTheme()
            self?.rebuildDynamicSections()
        }

        let header = buildHeader()

        setupStack.orientation = .vertical
        setupStack.alignment = .leading
        setupStack.spacing = 8
        let fullSetupCard = card(icon: "checkmark.seal", title: "Run full setup", content: buildFullSetupSection())

        homeSectionContent = buildHomeSection()

        dotfilesStack.orientation = .vertical
        dotfilesStack.alignment = .leading
        dotfilesStack.spacing = 10

        agentStack.orientation = .vertical
        agentStack.alignment = .leading
        agentStack.spacing = 10

        softwareStack.orientation = .vertical
        softwareStack.alignment = .leading
        softwareStack.spacing = 10

        restoreStack.orientation = .vertical
        restoreStack.alignment = .leading
        restoreStack.spacing = 10

        // The five sequenced sections (home, dotfiles, agent instructions,
        // software, restore config) are steps in one connected vertical
        // stepper rather than independent cards - see the `StepRowViews` doc
        // comment.
        let stepperStack = NSStackView()
        stepperStack.orientation = .vertical
        stepperStack.alignment = .leading
        stepperStack.spacing = 20
        let kinds = SetupStepKind.allCases
        for (index, kind) in kinds.enumerated() {
            let content: NSView
            switch kind {
            case .firstmateHome: content = homeSectionContent
            case .dotfiles: content = dotfilesStack
            case .agentInstructions: content = agentStack
            case .software: content = softwareStack
            case .restoreConfig: content = restoreStack
            }
            let row = buildStepRow(kind: kind, number: index + 1, content: content, isLast: index == kinds.count - 1)
            stepperStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: stepperStack.widthAnchor).isActive = true
        }
        let stepperCard = card(icon: "list.number", title: "Setup steps", content: stepperStack)

        driftStack.orientation = .vertical
        driftStack.alignment = .leading
        driftStack.spacing = 10
        let driftCard = card(icon: "arrow.triangle.2.circlepath", title: "Drift check", content: buildDriftSection())

        notSyncedStack.orientation = .vertical
        notSyncedStack.alignment = .leading
        notSyncedStack.spacing = 10
        let notSyncedCard = card(icon: "lock.slash", title: "Not synced here, by design", content: notSyncedStack)

        let stack = NSStackView(views: [header, fullSetupCard, stepperCard, driftCard, notSyncedCard])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.setCustomSpacing(16, after: header)

        let content = FlippedView()
        content.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 18),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
            header.widthAnchor.constraint(equalTo: stack.widthAnchor),
            fullSetupCard.widthAnchor.constraint(equalTo: stack.widthAnchor),
            stepperCard.widthAnchor.constraint(equalTo: stack.widthAnchor),
            driftCard.widthAnchor.constraint(equalTo: stack.widthAnchor),
            notSyncedCard.widthAnchor.constraint(equalTo: stack.widthAnchor),
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
        scrollView = scroll

        refreshFromSettings()
        applyTheme()
        refreshStepperVisuals()
        rebuildSetupSection()
        // rebuildDynamicSections here shows the "Checking…" loading state
        // immediately; refreshDotfiles's own initial call (viewWillAppear,
        // called right after loadView) then kicks off the real background
        // check.
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        refreshFromSettings()
        refreshDotfiles()
        if !hasCheckedSoftwareOnce {
            hasCheckedSoftwareOnce = true
            checkAllSoftware()
        }
        if !hasCheckedHardenersOnce {
            hasCheckedHardenersOnce = true
            checkGhHardening()
            checkAwsHardening()
            checkCodexHardening()
            checkHomebrewHardening()
        }
        scrollToTop()
    }

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

    // MARK: Card chrome (mirrors SettingsController.card)

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
        inner.spacing = 12
        inner.translatesAutoresizingMaskIntoConstraints = false
        content.widthAnchor.constraint(equalTo: inner.widthAnchor).isActive = true

        let background = NSView()
        background.wantsLayer = true
        background.layer?.cornerRadius = 13
        background.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(inner)
        NSLayoutConstraint.activate([
            inner.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 16),
            inner.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -16),
            inner.topAnchor.constraint(equalTo: background.topAnchor, constant: 14),
            inner.bottomAnchor.constraint(equalTo: background.bottomAnchor, constant: -14),
        ])
        cardBackgroundViews.append(background)
        return background
    }

    // MARK: Firstmate home

    private func buildHomeSection() -> NSView {
        let currentLabel = NSTextField(labelWithString: "Currently active")
        currentLabel.font = .systemFont(ofSize: 12.5, weight: .medium)

        currentPathLabel.font = .monospacedSystemFont(ofSize: 11.5, weight: .regular)
        currentPathLabel.lineBreakMode = .byTruncatingMiddle

        let desc = NSTextField(wrappingLabelWithString: "The directory firstmate reads projects, backlog, and crew state from. Checked after the FM_HOME / FIRSTMATE_HOME environment variables. Changing it here requires a restart to take effect.")
        desc.font = .systemFont(ofSize: 11)
        desc.textColor = .secondaryLabelColor
        desc.preferredMaxLayoutWidth = 520

        pathField.placeholderString = "~/manjesh/firstmate"
        pathField.translatesAutoresizingMaskIntoConstraints = false

        let browseButton = NSButton(title: "Browse\u{2026}", target: self, action: #selector(browseClicked))
        browseButton.bezelStyle = .rounded

        let fieldRow = NSStackView(views: [pathField, browseButton])
        fieldRow.orientation = .horizontal
        fieldRow.spacing = 8
        pathField.setContentHuggingPriority(.defaultLow, for: .horizontal)

        saveButton.title = "Save & Verify"
        saveButton.bezelStyle = .rounded
        saveButton.target = self
        saveButton.action = #selector(saveClicked)

        restartButton.title = "Restart Manjesh Grand Line"
        restartButton.bezelStyle = .rounded
        restartButton.target = self
        restartButton.action = #selector(restartClicked)
        restartButton.isHidden = true

        let actionRow = NSStackView(views: [saveButton, restartButton])
        actionRow.orientation = .horizontal
        actionRow.spacing = 8

        statusLabel.font = .systemFont(ofSize: 11.5)
        statusLabel.preferredMaxLayoutWidth = 520
        statusLabel.isHidden = true

        let section = NSStackView(views: [currentLabel, currentPathLabel, desc, fieldRow, actionRow, statusLabel])
        section.orientation = .vertical
        section.alignment = .leading
        section.spacing = 8
        section.setCustomSpacing(2, after: currentLabel)
        section.setCustomSpacing(12, after: desc)
        fieldRow.widthAnchor.constraint(equalTo: section.widthAnchor).isActive = true
        return section
    }

    @objc private func browseClicked() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose the Firstmate home directory."
        let existing = pathField.stringValue.isEmpty ? FirstmateHome.root.path : pathField.stringValue
        panel.directoryURL = URL(fileURLWithPath: (existing as NSString).expandingTildeInPath)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        pathField.stringValue = url.path
    }

    @objc private func saveClicked() {
        let raw = pathField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else {
            showStatus("Enter a path before saving.", isError: true)
            return
        }
        let expanded = (raw as NSString).expandingTildeInPath
        let candidate = URL(fileURLWithPath: expanded).standardizedFileURL
        guard FirstmateHome.homeOk(at: candidate) else {
            showStatus("No bin/fm-crew-state.sh found under \(candidate.path) - not saved.", isError: true)
            restartButton.isHidden = true
            return
        }
        AppSettings.shared.fmHome = candidate.path
        pathField.stringValue = candidate.path
        showStatus("Saved. Restart Manjesh Grand Line for the new home to take effect.", isError: false)
        restartButton.isHidden = false
        Toast.show(in: view, message: "Firstmate home saved")
    }

    @objc private func restartClicked() {
        let url = Bundle.main.bundleURL
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: url, configuration: config, completionHandler: nil)
        NSApp.terminate(nil)
    }

    private func showStatus(_ message: String, isError: Bool) {
        statusLabel.stringValue = message
        statusLabel.textColor = isError ? HelmTheme.nsColor(theme.ansiHex[1]) : HelmTheme.nsColor(theme.ansiHex[2])
        statusLabel.isHidden = false
    }

    // MARK: "Run full setup" sequencer (Part D)

    /// One-line status matching the mockup's `run-full-bar` subtitle - "Step 2
    /// of 4 — applying dotfiles" while running, a stop reason on failure, or
    /// the idle description otherwise. Derived from `setupSteps`, never
    /// hardcoded.
    private var fullSetupSubtitle: String {
        if let runningIndex = setupSteps.firstIndex(where: {
            if case .running = $0.status { return true }
            return false
        }) {
            return "Step \(runningIndex + 1) of \(setupSteps.count) \u{2014} \(setupSteps[runningIndex].kind.title)"
        }
        if let failedIndex = setupSteps.firstIndex(where: {
            if case .failed = $0.status { return true }
            return false
        }) {
            return "Stopped at \(setupSteps[failedIndex].kind.title) - see below for the reason."
        }
        let allResolved = setupSteps.allSatisfy {
            if case .done = $0.status { return true }
            if case .skipped = $0.status { return true }
            return false
        }
        if allResolved && setupSteps.contains(where: { if case .done = $0.status { return true }; return false }) {
            return "Completed."
        }
        return "Runs Firstmate home, dotfiles & machine config, agent instructions, then software in order."
    }

    private func buildFullSetupSection() -> NSView {
        let tile = IconTileView()
        tile.configure(symbol: "checkmark.seal", tint: .accent)

        let titleLabel = NSTextField(labelWithString: "Run full setup")
        titleLabel.font = .systemFont(ofSize: 14.5, weight: .bold)

        fullSetupSubtitleLabel.font = .systemFont(ofSize: 11.5)
        fullSetupSubtitleLabel.preferredMaxLayoutWidth = 320
        fullSetupSubtitleLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        fullSetupSubtitleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let textStack = NSStackView(views: [titleLabel, fullSetupSubtitleLabel])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 2

        progressTrack.wantsLayer = true
        progressTrack.layer?.cornerRadius = 2.5
        progressTrack.translatesAutoresizingMaskIntoConstraints = false
        progressTrack.widthAnchor.constraint(equalToConstant: progressTrackWidth).isActive = true
        progressTrack.heightAnchor.constraint(equalToConstant: 5).isActive = true

        progressFill.wantsLayer = true
        progressFill.layer?.cornerRadius = 2.5
        progressFill.translatesAutoresizingMaskIntoConstraints = false
        progressTrack.addSubview(progressFill)
        progressFillWidthConstraint = progressFill.widthAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            progressFill.leadingAnchor.constraint(equalTo: progressTrack.leadingAnchor),
            progressFill.topAnchor.constraint(equalTo: progressTrack.topAnchor),
            progressFill.bottomAnchor.constraint(equalTo: progressTrack.bottomAnchor),
            progressFillWidthConstraint!,
        ])
        progressTrack.setContentHuggingPriority(.required, for: .horizontal)

        runFullSetupButton.title = "Run full setup"
        runFullSetupButton.bezelStyle = .rounded
        runFullSetupButton.target = self
        runFullSetupButton.action = #selector(runFullSetupClicked)
        runFullSetupButton.setContentHuggingPriority(.required, for: .horizontal)

        let barRow = NSStackView(views: [tile, textStack, progressTrack, runFullSetupButton])
        barRow.orientation = .horizontal
        barRow.alignment = .centerY
        barRow.spacing = 12

        let section = NSStackView(views: [barRow, setupStack])
        section.orientation = .vertical
        section.alignment = .leading
        section.spacing = 12
        barRow.widthAnchor.constraint(equalTo: section.widthAnchor).isActive = true
        setupStack.widthAnchor.constraint(equalTo: section.widthAnchor).isActive = true
        return section
    }

    private func rebuildSetupSection() {
        guard isViewLoaded else { return }
        syncSetupStepsWithLiveState()
        clearStack(setupStack)
        for step in setupSteps {
            let row = setupStepRow(step)
            setupStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: setupStack.widthAnchor).isActive = true
        }
        runFullSetupButton.title = isRunningFullSetup ? "Running\u{2026}" : "Run full setup"
        runFullSetupButton.isEnabled = !isRunningFullSetup
        fullSetupSubtitleLabel.stringValue = fullSetupSubtitle
        fullSetupSubtitleLabel.textColor = HelmTheme.mutedInk(theme)

        let doneCount = setupSteps.filter {
            if case .done = $0.status { return true }
            if case .skipped = $0.status { return true }
            return false
        }.count
        let fraction = CGFloat(doneCount) / CGFloat(setupSteps.count)
        progressFillWidthConstraint?.constant = progressTrackWidth * fraction
        progressTrack.layer?.backgroundColor = HelmTheme.nsColor(theme.chromeLineHex).withAlphaComponent(0.3).cgColor
        progressFill.layer?.backgroundColor = HelmTheme.nsColor(theme.accentHex).cgColor
    }

    /// Same shared `ToolRowLayout` as Software checklist/Managed items/Global
    /// agent instructions (cockpit-bootstrap-row-width-parity) - no chevron/
    /// log here either, since a setup step has nothing to expand. The detail
    /// line reuses `stepDetail(for:)`, the same text the main stepper's own
    /// per-step detail label already shows, rather than inventing new copy.
    private func setupStepRow(_ step: SetupStepState) -> NSView {
        let views = ToolRowLayout.Views(
            iconTile: IconTileView(), nameLabel: NSTextField(labelWithString: ""),
            detailLabel: NSTextField(labelWithString: ""), pill: NSView(),
            pillLabel: NSTextField(labelWithString: ""), trailingStack: NSStackView(),
            detailsButton: NSButton(), logField: NSTextField(wrappingLabelWithString: ""),
            logContainer: NSView(), rowContainer: HoverHighlightView()
        )
        dynamicLabels.append(contentsOf: [views.nameLabel, views.detailLabel])

        let (pillText, pillColor) = setupStatusVisuals(step.status)
        ToolRowLayout.pill(text: pillText, colorHex: pillColor, into: views.pill, label: views.pillLabel)

        let row = ToolRowLayout.build(
            views,
            iconSymbol: step.kind.symbol,
            tint: .neutral,
            name: step.kind.title,
            trailingViews: [views.pill],
            identifier: step.kind.title,
            showDetails: false
        )
        views.detailLabel.stringValue = stepDetail(for: step.kind)
        ToolRowLayout.applyTheme(views, theme: theme, detailFailed: false)

        if case .failed(let reason) = step.status {
            let reasonLabel = NSTextField(wrappingLabelWithString: reason)
            reasonLabel.font = .systemFont(ofSize: 10.5)
            reasonLabel.textColor = HelmTheme.nsColor(theme.ansiHex[1])
            reasonLabel.preferredMaxLayoutWidth = 500
            dynamicLabels.append(reasonLabel)
            let column = NSStackView(views: [row, reasonLabel])
            column.orientation = .vertical
            column.alignment = .leading
            column.spacing = 2
            row.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
            reasonLabel.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
            return column
        }
        return row
    }

    private func setupStatusVisuals(_ status: SetupStepStatus) -> (String, String) {
        switch status {
        case .pending: return ("Pending", theme.chromeInkHex)
        case .checking: return ("Checking\u{2026}", theme.chromeInkHex)
        case .running: return ("Running\u{2026}", theme.chromeInkHex)
        case .done: return ("Done", theme.ansiHex[2])
        case .skipped: return ("Skipped", theme.chromeInkHex)
        case .failed: return ("Failed", theme.ansiHex[1])
        }
    }

    /// Keeps the summary bar's per-step status honest with the live state the
    /// cards below it (and the main stepper's own dots, via `stepIsDone`)
    /// already reflect - without this, a step defaults to `.pending` forever
    /// until an actual "Run full setup" pass sets it, even when the
    /// underlying thing is already done. Only touches steps that aren't
    /// currently showing a real run outcome (`.running`/`.failed`), so an
    /// active or just-stopped run's own status is never clobbered - and only
    /// runs at all when no run is in progress, so it never races
    /// `updateSetupStep`'s own writes mid-run.
    private func syncSetupStepsWithLiveState() {
        guard !isRunningFullSetup else { return }
        for index in setupSteps.indices {
            switch setupSteps[index].status {
            case .running, .failed:
                continue
            default:
                break
            }
            switch stepIsDone(setupSteps[index].kind) {
            case nil: setupSteps[index].status = .checking
            case true?: setupSteps[index].status = .done
            case false?: setupSteps[index].status = .pending
            }
        }
    }

    private func updateSetupStep(_ kind: SetupStepKind, _ status: SetupStepStatus) {
        guard let index = setupSteps.firstIndex(where: { $0.kind == kind }) else { return }
        setupSteps[index].status = status
        rebuildSetupSection()
    }

    @objc private func runFullSetupClicked() {
        guard !isRunningFullSetup else { return }
        isRunningFullSetup = true
        setupSteps = SetupStepKind.allCases.filter { $0.isPartOfFullSetupSequence }.map { SetupStepState(kind: $0) }
        rebuildSetupSection()
        runSetupStepHome()
    }

    private func finishFullSetup() {
        isRunningFullSetup = false
        rebuildSetupSection()
    }

    private func runSetupStepHome() {
        updateSetupStep(.firstmateHome, .running)
        guard FirstmateHome.homeOk(at: FirstmateHome.root) else {
            updateSetupStep(.firstmateHome, .failed("Firstmate home is not set up - use the Firstmate home card below to locate or clone one, then run full setup again."))
            finishFullSetup()
            return
        }
        updateSetupStep(.firstmateHome, .done)
        runSetupStepDotfiles()
    }

    private func runSetupStepDotfiles() {
        updateSetupStep(.dotfiles, .running)
        // Re-check ~/.dotfiles right before deciding clone-vs-rebuild, so a
        // stale in-memory `dotfilesRepoPath` from before this run never picks
        // the wrong branch.
        refreshDotfiles { [weak self] in
            guard let self else { return }
            guard let onRunCommandTracked = self.onRunCommandTracked else {
                self.updateSetupStep(.dotfiles, .failed("No console wiring available."))
                self.finishFullSetup()
                return
            }
            let (label, command) = DotfilesRunCommand.runOrCloneCommand(
                repoPath: self.dotfilesRepoPath,
                clonePathFieldValue: self.clonePathField.stringValue
            )
            onRunCommandTracked(label, command) { [weak self] ok in
                guard let self else { return }
                if ok {
                    self.updateSetupStep(.dotfiles, .done)
                    self.runSetupStepAgentInstructions()
                } else {
                    self.updateSetupStep(.dotfiles, .failed("\(label) exited with a non-zero status - see its Console tab for output."))
                    self.finishFullSetup()
                }
            }
        }
    }

    private func runSetupStepAgentInstructions() {
        updateSetupStep(.agentInstructions, .running)
        refreshDotfiles { [weak self] in
            guard let self else { return }
            self.updateSetupStep(.agentInstructions, .done)
            self.runSetupStepSoftware()
        }
    }

    private func runSetupStepSoftware() {
        updateSetupStep(.software, .running)
        let missing = softwareRows.filter { $0.status == .notInstalled }
        guard !missing.isEmpty else {
            updateSetupStep(.software, .done)
            finishFullSetup()
            return
        }
        installAllMissing { [weak self] allOk in
            guard let self else { return }
            if allOk {
                self.updateSetupStep(.software, .done)
            } else {
                self.updateSetupStep(.software, .failed("One or more installs failed - see the software checklist above for detail."))
            }
            self.finishFullSetup()
        }
    }

    // MARK: Vertical stepper (cockpit-modern-ui-bootstrap)

    /// Whether a step is currently configured/satisfied, read live from the
    /// same state every other part of this page already reads - never a
    /// hardcoded flag. `nil` means "still checking" (the background refresh
    /// for that step hasn't returned yet). Delegates to `SetupStepChecks`
    /// (fm/grandline-automation-pipeline) so the `.automation` destination's
    /// own sequencer can never disagree with this page about whether a step
    /// is done - not `private` for that reason.
    func stepIsDone(_ kind: SetupStepKind) -> Bool? {
        switch kind {
        case .firstmateHome:
            return SetupStepChecks.firstmateHomeDone()
        case .dotfiles:
            return SetupStepChecks.dotfilesDone(isLoading: isLoadingDotfiles, repoPath: dotfilesRepoPath, state: repoState)
        case .agentInstructions:
            return SetupStepChecks.agentInstructionsDone(isLoading: isLoadingDotfiles, items: agentItems)
        case .software:
            return SetupStepChecks.softwareDone(isLoading: isLoadingSoftware, statuses: softwareRows.map { $0.status })
        case .restoreConfig:
            return SetupStepChecks.restoreConfigDone(hostCount: hostStore.hosts.count, snippetCount: snippetStore.snippets.count)
        }
    }

    /// The first not-yet-done step is "current"; anything after it is
    /// "pending"; anything before it is "done". A step still loading counts
    /// as not-done for ordering purposes, so the stepper never claims a step
    /// is finished before its check has actually returned.
    private func stepperDotState(for kind: SetupStepKind) -> StepperDotState {
        let order = SetupStepKind.allCases
        guard let targetIndex = order.firstIndex(of: kind) else { return .pending }
        let doneFlags = order.map { stepIsDone($0) ?? false }
        if doneFlags[targetIndex] { return .done }
        let firstNotDone = doneFlags.firstIndex(of: false) ?? order.count
        return targetIndex == firstNotDone ? .current : .pending
    }

    private func stepChip(for kind: SetupStepKind) -> (String, String)? {
        switch kind {
        case .firstmateHome:
            return stepIsDone(.firstmateHome) == true ? ("Verified", theme.ansiHex[2]) : ("Not set up", theme.ansiHex[3])
        case .dotfiles:
            guard !isLoadingDotfiles else { return nil }
            guard dotfilesRepoPath != nil else { return ("Not found", theme.ansiHex[3]) }
            if let state = repoState, !state.dirtyFiles.isEmpty { return ("Uncommitted changes", theme.ansiHex[3]) }
            if let state = repoState, let behind = state.commitsBehindOrigin, behind > 0 {
                return ("\(behind) behind origin", theme.ansiHex[3])
            }
            return ("Verified", theme.ansiHex[2])
        case .agentInstructions:
            guard !isLoadingDotfiles else { return nil }
            let unresolved = agentItems.filter { $0.status != .linked }.count
            return unresolved == 0 ? ("Linked", theme.ansiHex[2]) : ("\(unresolved) unresolved", theme.ansiHex[3])
        case .software:
            guard !isLoadingSoftware else { return nil }
            let missing = softwareRows.filter { $0.status == .notInstalled }.count
            return missing == 0 ? ("All installed", theme.ansiHex[2]) : ("\(missing) missing", theme.ansiHex[3])
        case .restoreConfig:
            let hostCount = hostStore.hosts.count
            let snippetCount = snippetStore.snippets.count
            guard hostCount > 0 || snippetCount > 0 else { return ("Nothing to show yet", theme.chromeInkHex) }
            return ("\(hostCount) host\(hostCount == 1 ? "" : "s"), \(snippetCount) snippet\(snippetCount == 1 ? "" : "s")", theme.ansiHex[2])
        }
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
            return "\(softwareRows.count) tracked dependencies across \(DependencyCatalog.categoryOrder.count) categories."
        case .restoreConfig:
            return "Import a .glbackup file exported from another machine to bring in its saved hosts, snippets, and preferences here."
        }
    }

    /// The drift card's own detail line for a drifted step - unlike
    /// `stepDetail(for:)` above (a generic "what this step checks" caption
    /// shown on the stepper itself), this names the *specific* thing(s) that
    /// drifted, using data each check already collected. Falls back to
    /// `stepDetail(for:)` for the two steps with no natural itemized
    /// breakdown (`firstmateHome`/`restoreConfig` are plain existence
    /// checks).
    private func driftDetail(for kind: SetupStepKind) -> String {
        switch kind {
        case .dotfiles:
            guard let state = repoState else { return stepDetail(for: kind) }
            var bits: [String] = []
            if !state.dirtyFiles.isEmpty {
                let names = state.dirtyFiles.map { line -> String in
                    // `git status --short` lines are "XY path" (or "XY old -> new"
                    // for a rename) - drop the two-char status code + separating
                    // space to show just the path.
                    line.count > 3 ? String(line.dropFirst(3)) : line
                }
                let shown = names.prefix(3).joined(separator: ", ")
                let more = names.count > 3 ? " +\(names.count - 3) more" : ""
                bits.append("\(names.count) file\(names.count == 1 ? "" : "s") changed: \(shown)\(more)")
            }
            if let behind = state.commitsBehindOrigin, behind > 0 {
                bits.append("\(behind) commit\(behind == 1 ? "" : "s") behind origin")
            }
            return bits.isEmpty ? stepDetail(for: kind) : bits.joined(separator: " \u{00B7} ")
        case .agentInstructions:
            let unresolved = agentItems.filter { $0.status != .linked }
            guard !unresolved.isEmpty else { return stepDetail(for: kind) }
            let names = unresolved.map { item -> String in
                switch item.status {
                case .wrongTarget: return "\(item.label) points elsewhere"
                default: return "\(item.label) not linked"
                }
            }
            return names.joined(separator: ", ")
        case .software:
            let missing = softwareRows.filter { $0.status == .notInstalled }
            guard !missing.isEmpty else { return stepDetail(for: kind) }
            let names = missing.map { $0.item.name }
            return "\(names.joined(separator: ", ")) not installed"
        case .firstmateHome, .restoreConfig:
            return stepDetail(for: kind)
        }
    }

    /// Builds one step's row scaffolding once - see the `StepRowViews` doc
    /// comment for why this isn't torn down and rebuilt like this file's other
    /// dynamic sections.
    private func buildStepRow(kind: SetupStepKind, number: Int, content: NSView, isLast: Bool) -> NSView {
        let dot = StepDotView()

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

        let chipLabel = NSTextField(labelWithString: "")
        chipLabel.font = .systemFont(ofSize: 10, weight: .semibold)
        chipLabel.translatesAutoresizingMaskIntoConstraints = false
        let chipContainer = NSView()
        chipContainer.wantsLayer = true
        chipContainer.layer?.cornerRadius = 8
        chipContainer.translatesAutoresizingMaskIntoConstraints = false
        chipContainer.addSubview(chipLabel)
        NSLayoutConstraint.activate([
            chipLabel.leadingAnchor.constraint(equalTo: chipContainer.leadingAnchor, constant: 7),
            chipLabel.trailingAnchor.constraint(equalTo: chipContainer.trailingAnchor, constant: -7),
            chipLabel.topAnchor.constraint(equalTo: chipContainer.topAnchor, constant: 2),
            chipLabel.bottomAnchor.constraint(equalTo: chipContainer.bottomAnchor, constant: -2),
        ])
        chipContainer.setContentHuggingPriority(.required, for: .horizontal)
        chipContainer.setContentCompressionResistancePriority(.required, for: .horizontal)

        let titleRow = NSStackView(views: [titleLabel, chipContainer])
        titleRow.orientation = .horizontal
        titleRow.alignment = .centerY
        titleRow.spacing = 8

        let detailLabel = NSTextField(wrappingLabelWithString: "")
        detailLabel.font = .systemFont(ofSize: 11.5)
        detailLabel.preferredMaxLayoutWidth = 500

        let contentBox = stepContentBox(content)

        let bodyStack = NSStackView(views: [titleRow, detailLabel, contentBox])
        bodyStack.orientation = .vertical
        bodyStack.alignment = .leading
        bodyStack.spacing = 8
        bodyStack.setCustomSpacing(2, after: titleRow)
        titleRow.widthAnchor.constraint(equalTo: bodyStack.widthAnchor).isActive = true
        detailLabel.widthAnchor.constraint(equalTo: bodyStack.widthAnchor).isActive = true
        contentBox.widthAnchor.constraint(equalTo: bodyStack.widthAnchor).isActive = true

        leftColumn.setContentHuggingPriority(.required, for: .horizontal)
        leftColumn.setContentCompressionResistancePriority(.required, for: .horizontal)
        bodyStack.setContentHuggingPriority(.defaultLow, for: .horizontal)
        bodyStack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let row = NSStackView(views: [leftColumn, bodyStack])
        row.orientation = .horizontal
        row.alignment = .top
        row.spacing = 14
        // Default `.gravityAreas` distribution ignores hugging priorities for
        // filling slack width (see the AppKit-gotchas note in this project's
        // CLAUDE.md) - `.fill` is what makes `bodyStack` (and therefore its
        // `stepContentBox`) actually absorb the row's full available width
        // instead of shrinking to its content's natural size.
        row.distribution = .fill
        leftColumn.heightAnchor.constraint(equalTo: bodyStack.heightAnchor).isActive = true

        stepRowViews[kind] = StepRowViews(dot: dot, line: line, titleLabel: titleLabel, chipContainer: chipContainer, chipLabel: chipLabel, detailLabel: detailLabel)
        return row
    }

    /// Wraps a step's real content (the same field/button/table views the old
    /// standalone cards used) in a nested, slightly recessed panel - the
    /// mockup's `.step-content` box.
    private func stepContentBox(_ content: NSView) -> NSView {
        content.translatesAutoresizingMaskIntoConstraints = false
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
        stepContentBackgrounds.append(box)
        return box
    }

    /// Re-derives every step's dot/chip/detail from live state - called
    /// whenever any of the underlying checks change (see call sites in
    /// `rebuildSoftwareSection`/theme changes) or the active theme changes.
    private func refreshStepperVisuals() {
        for (index, kind) in SetupStepKind.allCases.enumerated() {
            guard let rowViews = stepRowViews[kind] else { continue }
            let state = stepperDotState(for: kind)
            rowViews.dot.configure(number: index + 1, state: state, theme: theme)
            rowViews.titleLabel.textColor = state == .pending ? HelmTheme.mutedInk(theme) : HelmTheme.nsColor(theme.chromeInkHex)
            rowViews.detailLabel.stringValue = stepDetail(for: kind)
            rowViews.detailLabel.textColor = HelmTheme.mutedInk(theme)
            rowViews.line.layer?.backgroundColor = HelmTheme.nsColor(theme.chromeLineHex).withAlphaComponent(0.6).cgColor
            if let (text, colorHex) = stepChip(for: kind) {
                rowViews.chipContainer.isHidden = false
                rowViews.chipLabel.stringValue = text
                rowViews.chipLabel.textColor = HelmTheme.nsColor(colorHex)
                rowViews.chipContainer.layer?.backgroundColor = HelmTheme.nsColor(colorHex).withAlphaComponent(0.15).cgColor
            } else {
                rowViews.chipContainer.isHidden = true
            }
        }
    }

    // MARK: Dotfiles & machine config (Part A)

    /// Re-checks `~/.dotfiles` and the two dependent sections off the main
    /// thread (git/file IO), mirroring `FleetController.refresh`. Shows a
    /// lightweight "Checking…" state first so navigating to the page never
    /// looks frozen while `git` runs.
    private func refreshDotfiles(completion: (() -> Void)? = nil) {
        guard isViewLoaded else { completion?(); return }
        isLoadingDotfiles = true
        rebuildDynamicSections()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let resolved = DotfilesSource.resolvedDotfilesPath()
            var state: DotfilesRepoState?
            var managed: [ManagedItem] = []
            var agents: [AgentInstructionsItem] = []
            if let resolved {
                state = DotfilesSource.repoState(at: resolved)
                managed = DotfilesSource.managedItems(repoPath: resolved)
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
                self.managedItems = managed
                self.agentItems = agents
                self.isLoadingDotfiles = false
                self.usernameField.stringValue = state?.flakeUsername ?? ""
                self.rebuildDynamicSections()
                self.applyTheme()
                completion?()
            }
        }
    }

    /// Rebuilds all three dynamic sections together, since they share the one
    /// `dynamicLabels` re-theming list (see its doc comment) that needs
    /// clearing exactly once per refresh, not once per section.
    private func rebuildDynamicSections() {
        dynamicLabels.removeAll()
        rebuildSetupSection()
        rebuildDotfilesSection()
        rebuildAgentSection()
        rebuildSoftwareSection()
        rebuildRestoreSection()
        rebuildNotSyncedSection()
        maybeSeedInitialDriftStatus()
        rebuildDriftSection()
    }

    // MARK: Restore Grand Line config (fm/cockpit-local-state-portable)

    /// Same import action as Settings' "Backup & Restore" card
    /// (`BackupUI.importFlow`) - not a separate implementation. "Done"-ness
    /// (`stepIsDone(.restoreConfig)`) is derived live from the stores, so a
    /// successful import here just needs to refresh this section and the
    /// stepper's dot/chip, not track any state of its own.
    private func rebuildRestoreSection() {
        clearStack(restoreStack)

        let desc = NSTextField(wrappingLabelWithString: "Bring in saved hosts, snippets, and preferences exported from another machine. SSH private keys never leave the Keychain - a restored host referencing a key not on this machine needs that key re-added from the Keys screen.")
        desc.font = .systemFont(ofSize: 11)
        desc.textColor = HelmTheme.mutedInk(theme)
        desc.preferredMaxLayoutWidth = 520
        dynamicLabels.append(desc)

        let hostCount = hostStore.hosts.count
        let snippetCount = snippetStore.snippets.count
        restoreStatusLabel.stringValue = "Currently saved here: \(hostCount) host\(hostCount == 1 ? "" : "s"), \(snippetCount) snippet\(snippetCount == 1 ? "" : "s")."
        restoreStatusLabel.font = .systemFont(ofSize: 11)
        restoreStatusLabel.textColor = HelmTheme.mutedInk(theme)
        dynamicLabels.append(restoreStatusLabel)

        let importButton = NSButton(title: "Import\u{2026}", target: self, action: #selector(importRestoreConfigClicked))
        importButton.bezelStyle = .rounded

        let section = NSStackView(views: [desc, restoreStatusLabel, importButton])
        section.orientation = .vertical
        section.alignment = .leading
        section.spacing = 8
        restoreStack.addArrangedSubview(section)
        section.widthAnchor.constraint(equalTo: restoreStack.widthAnchor).isActive = true
    }

    @objc private func importRestoreConfigClicked() {
        BackupUI.importFlow(from: self, hostStore: hostStore, keyStore: keyStore, snippetStore: snippetStore, dictationStore: dictationStore) { [weak self] in
            self?.rebuildDynamicSections()
        }
    }

    // MARK: Drift check (fm/cockpit-bootstrap-drift-check)

    private func buildDriftSection() -> NSView {
        driftDescLabel.font = .systemFont(ofSize: 11)
        driftDescLabel.preferredMaxLayoutWidth = 520

        driftStatusLabel.font = .systemFont(ofSize: 12.5, weight: .medium)
        driftStatusLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        driftStatusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        driftLastCheckedLabel.font = .systemFont(ofSize: 11)

        driftRecheckButton.title = "Re-check now"
        driftRecheckButton.bezelStyle = .rounded
        driftRecheckButton.target = self
        driftRecheckButton.action = #selector(driftRecheckClicked)
        driftRecheckButton.setContentHuggingPriority(.required, for: .horizontal)

        let headerRow = NSStackView(views: [driftStatusLabel, driftRecheckButton])
        headerRow.orientation = .horizontal
        headerRow.alignment = .centerY
        headerRow.spacing = 12
        headerRow.distribution = .fill

        let section = NSStackView(views: [driftDescLabel, headerRow, driftLastCheckedLabel, driftStack])
        section.orientation = .vertical
        section.alignment = .leading
        section.spacing = 8
        section.setCustomSpacing(12, after: driftDescLabel)
        headerRow.widthAnchor.constraint(equalTo: section.widthAnchor).isActive = true
        driftLastCheckedLabel.widthAnchor.constraint(equalTo: section.widthAnchor).isActive = true
        driftStack.widthAnchor.constraint(equalTo: section.widthAnchor).isActive = true
        return section
    }

    /// Re-derives every step's live done/not-done state via the exact same
    /// `stepIsDone` the stepper already reads - see this file's header
    /// comment for why this is the one place a background poll was
    /// deliberately not added.
    private func captureDriftSnapshot() {
        var results: [SetupStepKind: Bool?] = [:]
        for kind in SetupStepKind.allCases {
            results[kind] = stepIsDone(kind)
        }
        driftResults = results
        driftLastChecked = Date()
    }

    /// Seeds the card's first status for free from whatever `refreshDotfiles`/
    /// `checkAllSoftware` already fetched for the stepper on page load - no
    /// second round of `git`/`brew`/`npm` calls just from visiting the page.
    private func maybeSeedInitialDriftStatus() {
        guard driftLastChecked == nil, !isDriftChecking, !isLoadingDotfiles, !isLoadingSoftware else { return }
        captureDriftSnapshot()
    }

    @objc private func driftRecheckClicked() {
        guard !isDriftChecking else { return }
        isDriftChecking = true
        rebuildDriftSection()
        // Re-runs the same background checks the stepper/dotfiles/software
        // sections already use - no new detection logic. firstmateHome and
        // restoreConfig are read live and synchronously inside `stepIsDone`,
        // so only dotfiles/agentInstructions (`refreshDotfiles`) and software
        // need an explicit re-fetch first.
        refreshDotfiles { [weak self] in
            guard let self else { return }
            self.checkAllSoftware {
                self.isDriftChecking = false
                self.captureDriftSnapshot()
                self.rebuildDriftSection()
            }
        }
    }

    private func rebuildDriftSection() {
        guard isViewLoaded else { return }
        driftDescLabel.textColor = HelmTheme.mutedInk(theme)
        driftLastCheckedLabel.textColor = HelmTheme.mutedInk(theme)

        clearStack(driftStack)
        if isDriftChecking {
            driftStatusLabel.stringValue = "Checking\u{2026}"
            driftStatusLabel.textColor = HelmTheme.mutedInk(theme)
        } else if driftLastChecked == nil {
            driftStatusLabel.stringValue = "Not checked yet"
            driftStatusLabel.textColor = HelmTheme.mutedInk(theme)
        } else {
            let driftedKinds = SetupStepKind.allCases.filter { driftResults[$0] == false }
            if driftedKinds.isEmpty {
                driftStatusLabel.stringValue = "Everything matches"
                driftStatusLabel.textColor = HelmTheme.nsColor(theme.ansiHex[2])
            } else {
                driftStatusLabel.stringValue = "\(driftedKinds.count) item\(driftedKinds.count == 1 ? "" : "s") drifted"
                driftStatusLabel.textColor = HelmTheme.nsColor(theme.ansiHex[1])
            }
            for kind in driftedKinds {
                let row = driftedItemRow(kind)
                driftStack.addArrangedSubview(row)
                row.widthAnchor.constraint(equalTo: driftStack.widthAnchor).isActive = true
            }
        }

        driftRecheckButton.title = isDriftChecking ? "Checking\u{2026}" : "Re-check now"
        driftRecheckButton.isEnabled = !isDriftChecking

        if let last = driftLastChecked {
            driftLastCheckedLabel.stringValue = "Last checked: \(Self.driftTimestampFormatter.string(from: last))"
            driftLastCheckedLabel.isHidden = false
        } else {
            driftLastCheckedLabel.isHidden = true
        }
    }

    /// One drifted step, reusing the same `ToolRowLayout` chrome as every
    /// other status row on this page - with a remedy button (`driftRemedy`)
    /// where that step already has an obvious one-click fix, so reporting the
    /// problem and acting on it are the same click.
    private func driftedItemRow(_ kind: SetupStepKind) -> NSView {
        let views = ToolRowLayout.Views(
            iconTile: IconTileView(), nameLabel: NSTextField(labelWithString: ""),
            detailLabel: NSTextField(labelWithString: ""), pill: NSView(),
            pillLabel: NSTextField(labelWithString: ""), trailingStack: NSStackView(),
            detailsButton: NSButton(), logField: NSTextField(wrappingLabelWithString: ""),
            logContainer: NSView(), rowContainer: HoverHighlightView()
        )
        dynamicLabels.append(contentsOf: [views.nameLabel, views.detailLabel])

        ToolRowLayout.pill(text: "Drifted", colorHex: theme.ansiHex[1], into: views.pill, label: views.pillLabel)

        var trailingViews: [NSView] = [views.pill]
        if let (title, action) = driftRemedy(for: kind) {
            let button = NSButton(title: title, target: self, action: action)
            button.bezelStyle = .rounded
            button.controlSize = .small
            trailingViews.append(button)
        }

        // Every row this function ever builds is already a drifted item -
        // `rebuildDriftSection` only calls it for `driftedKinds`, never for
        // a step that still matches - so unlike Updates/GitHub Sync/
        // Automation's dense checklists, there's no "mix of healthy and
        // attention rows" to distinguish here: 100% of what's shown belongs
        // in the notification-card treatment
        // (`fm/grandline-setup-attention-row-style`). This card is rebuilt
        // fresh on every `rebuildDriftSection()` call (see `clearStack`
        // above), so it's safe to decide `cardStyle` at `build()` time too,
        // unlike a persistent mutate-in-place row.
        let row = ToolRowLayout.build(
            views,
            iconSymbol: kind.symbol,
            tint: .critical,
            name: kind.title,
            trailingViews: trailingViews,
            identifier: "drift-\(kind.title)",
            showDetails: false,
            cardStyle: true
        )
        views.detailLabel.stringValue = driftDetail(for: kind)
        ToolRowLayout.applyTheme(
            views, theme: theme, detailFailed: true,
            cardStyle: true, attentionHex: theme.ansiHex[1], accentBar: true
        )
        return row
    }

    /// The obvious one-click remedy for a drifted step, where one exists -
    /// the exact same action its own card's button already triggers, never a
    /// new action. `firstmateHome` has no single-click fix (its own card
    /// needs a real path first), so its remedy just jumps there.
    private func driftRemedy(for kind: SetupStepKind) -> (String, Selector)? {
        switch kind {
        case .firstmateHome: return ("Review", #selector(driftReviewHomeClicked))
        case .dotfiles: return ("Create link", #selector(createLinkClicked))
        case .agentInstructions: return ("Create link", #selector(createLinkClicked))
        case .software: return ("Install missing", #selector(installAllMissingClicked))
        case .restoreConfig: return ("Import\u{2026}", #selector(importRestoreConfigClicked))
        }
    }

    @objc private func driftReviewHomeClicked() {
        scrollToStep(.firstmateHome)
    }

    private func scrollToStep(_ kind: SetupStepKind) {
        guard let scroll = scrollView, let documentView = scroll.documentView else { return }
        guard let index = SetupStepKind.allCases.firstIndex(of: kind), index < stepContentBackgrounds.count else { return }
        let target = stepContentBackgrounds[index]
        let rect = target.convert(target.bounds, to: documentView)
        documentView.scrollToVisible(rect)
    }

    private func rebuildDotfilesSection() {
        clearStack(dotfilesStack)
        let content: NSView
        if isLoadingDotfiles {
            content = loadingLabel("Checking ~/.dotfiles\u{2026}")
        } else if let repoPath = dotfilesRepoPath, let state = repoState {
            content = buildDotfilesPresentSection(repoPath: repoPath, state: state)
        } else {
            content = buildDotfilesAbsentSection()
        }
        dotfilesStack.addArrangedSubview(content)
        content.widthAnchor.constraint(equalTo: dotfilesStack.widthAnchor).isActive = true
    }

    private func buildDotfilesAbsentSection() -> NSView {
        let desc = NSTextField(wrappingLabelWithString: "~/.dotfiles was not found on this machine. Clone the captain's dotfiles repo and run its bootstrap script to set one up.")
        desc.font = .systemFont(ofSize: 11)
        desc.textColor = HelmTheme.mutedInk(theme)
        desc.preferredMaxLayoutWidth = 520
        dynamicLabels.append(desc)

        clonePathField.translatesAutoresizingMaskIntoConstraints = false
        let cloneButton = NSButton(title: "Clone & Bootstrap", target: self, action: #selector(cloneAndBootstrapClicked))
        cloneButton.bezelStyle = .rounded
        let fieldRow = NSStackView(views: [clonePathField, cloneButton])
        fieldRow.orientation = .horizontal
        fieldRow.spacing = 8
        clonePathField.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let section = NSStackView(views: [desc, fieldRow])
        section.orientation = .vertical
        section.alignment = .leading
        section.spacing = 10
        fieldRow.widthAnchor.constraint(equalTo: section.widthAnchor).isActive = true
        return section
    }

    private func buildDotfilesPresentSection(repoPath: String, state: DotfilesRepoState) -> NSView {
        var rows: [NSView] = []

        let repoLabel = NSTextField(labelWithString: repoPath)
        repoLabel.font = .monospacedSystemFont(ofSize: 11.5, weight: .regular)
        dynamicLabels.append(repoLabel)
        rows.append(repoLabel)

        var metaBits: [String] = []
        if let branch = state.branch { metaBits.append("branch \(branch)") }
        if let remote = state.remoteURL { metaBits.append(remote) }
        if !metaBits.isEmpty {
            let metaLabel = NSTextField(labelWithString: metaBits.joined(separator: " \u{00B7} "))
            metaLabel.font = .systemFont(ofSize: 11)
            metaLabel.textColor = HelmTheme.mutedInk(theme)
            dynamicLabels.append(metaLabel)
            rows.append(metaLabel)
        }

        if let behind = state.commitsBehindOrigin, behind > 0 {
            rows.append(buildBehindOriginBanner(behind))
        }

        if !state.dirtyFiles.isEmpty {
            rows.append(buildDirtyBanner(state.dirtyFiles))
        }

        rows.append(buildUsernameRow(repoPath: repoPath))

        let rebuildButton = NSButton(title: "Run rebuild.sh", target: self, action: #selector(runRebuildClicked))
        rebuildButton.bezelStyle = .rounded
        rows.append(rebuildButton)

        let managedTitle = NSTextField(labelWithString: "Managed items")
        managedTitle.font = .systemFont(ofSize: 12, weight: .semibold)
        rows.append(managedTitle)
        for item in managedItems {
            rows.append(managedItemRow(item))
        }

        let section = NSStackView(views: rows)
        section.orientation = .vertical
        section.alignment = .leading
        section.spacing = 8
        section.setCustomSpacing(14, after: rebuildButton)
        for row in rows { row.widthAnchor.constraint(equalTo: section.widthAnchor).isActive = true }
        return section
    }

    private func buildBehindOriginBanner(_ count: Int) -> NSView {
        let title = NSTextField(labelWithString: "\(count) commit\(count == 1 ? "" : "s") behind origin")
        title.font = .systemFont(ofSize: 11.5, weight: .semibold)
        title.textColor = HelmTheme.nsColor(theme.ansiHex[3])

        let body = NSTextField(wrappingLabelWithString: "Run rebuild.sh will pull these from GitHub first.")
        body.font = .systemFont(ofSize: 10.5, weight: .regular)
        body.textColor = HelmTheme.mutedInk(theme)
        body.preferredMaxLayoutWidth = 500

        let inner = NSStackView(views: [title, body])
        inner.orientation = .vertical
        inner.alignment = .leading
        inner.spacing = 4
        inner.translatesAutoresizingMaskIntoConstraints = false

        let banner = NSView()
        banner.wantsLayer = true
        banner.layer?.cornerRadius = 9
        banner.layer?.backgroundColor = HelmTheme.nsColor(theme.ansiHex[3]).withAlphaComponent(0.12).cgColor
        banner.translatesAutoresizingMaskIntoConstraints = false
        banner.addSubview(inner)
        NSLayoutConstraint.activate([
            inner.leadingAnchor.constraint(equalTo: banner.leadingAnchor, constant: 10),
            inner.trailingAnchor.constraint(equalTo: banner.trailingAnchor, constant: -10),
            inner.topAnchor.constraint(equalTo: banner.topAnchor, constant: 8),
            inner.bottomAnchor.constraint(equalTo: banner.bottomAnchor, constant: -8),
        ])
        dynamicLabels.append(contentsOf: [title, body])
        return banner
    }

    private func buildDirtyBanner(_ files: [String]) -> NSView {
        let title = NSTextField(labelWithString: "Uncommitted changes")
        title.font = .systemFont(ofSize: 11.5, weight: .semibold)
        title.textColor = HelmTheme.nsColor(theme.ansiHex[1])

        let body = NSTextField(wrappingLabelWithString: "\(files.count) file(s) uncommitted here: a fresh machine bootstrapping from origin right now would miss them.\n" + files.joined(separator: "\n"))
        body.font = .monospacedSystemFont(ofSize: 10.5, weight: .regular)
        body.textColor = HelmTheme.mutedInk(theme)
        body.preferredMaxLayoutWidth = 500

        let inner = NSStackView(views: [title, body])
        inner.orientation = .vertical
        inner.alignment = .leading
        inner.spacing = 4
        inner.translatesAutoresizingMaskIntoConstraints = false

        let banner = NSView()
        banner.wantsLayer = true
        banner.layer?.cornerRadius = 9
        banner.layer?.backgroundColor = HelmTheme.nsColor(theme.ansiHex[1]).withAlphaComponent(0.12).cgColor
        banner.translatesAutoresizingMaskIntoConstraints = false
        banner.addSubview(inner)
        NSLayoutConstraint.activate([
            inner.leadingAnchor.constraint(equalTo: banner.leadingAnchor, constant: 10),
            inner.trailingAnchor.constraint(equalTo: banner.trailingAnchor, constant: -10),
            inner.topAnchor.constraint(equalTo: banner.topAnchor, constant: 8),
            inner.bottomAnchor.constraint(equalTo: banner.bottomAnchor, constant: -8),
        ])
        dynamicLabels.append(contentsOf: [title, body])
        return banner
    }

    private func buildUsernameRow(repoPath: String) -> NSView {
        let label = NSTextField(labelWithString: "macOS username")
        label.font = .systemFont(ofSize: 12, weight: .medium)

        usernameField.translatesAutoresizingMaskIntoConstraints = false
        let save = NSButton(title: "Save", target: self, action: #selector(saveUsernameClicked))
        save.bezelStyle = .rounded

        let row = NSStackView(views: [usernameField, save])
        row.orientation = .horizontal
        row.spacing = 8
        usernameField.setContentHuggingPriority(.defaultLow, for: .horizontal)

        dotfilesStatusLabel.font = .systemFont(ofSize: 11)
        dotfilesStatusLabel.preferredMaxLayoutWidth = 500
        dotfilesStatusLabel.isHidden = true
        dynamicLabels.append(dotfilesStatusLabel)

        let section = NSStackView(views: [label, row, dotfilesStatusLabel])
        section.orientation = .vertical
        section.alignment = .leading
        section.spacing = 4
        row.widthAnchor.constraint(equalTo: section.widthAnchor).isActive = true
        return section
    }

    /// Same shared `ToolRowLayout` (icon tile, name/detail line, pill) as the
    /// Software checklist's rows (cockpit-bootstrap-row-width-parity) - these
    /// items are read-only status with no action, so `showDetails: false`
    /// omits the chevron/log portion `ToolRowLayout` also supports.
    private func managedItemRow(_ item: ManagedItem) -> NSView {
        let views = ToolRowLayout.Views(
            iconTile: IconTileView(), nameLabel: NSTextField(labelWithString: ""),
            detailLabel: NSTextField(labelWithString: ""), pill: NSView(),
            pillLabel: NSTextField(labelWithString: ""), trailingStack: NSStackView(),
            detailsButton: NSButton(), logField: NSTextField(wrappingLabelWithString: ""),
            logContainer: NSView(), rowContainer: HoverHighlightView()
        )
        dynamicLabels.append(contentsOf: [views.nameLabel, views.detailLabel])

        let (pillText, pillColor) = managedStatusVisuals(item.status)
        ToolRowLayout.pill(text: pillText, colorHex: pillColor, into: views.pill, label: views.pillLabel)

        let view = ToolRowLayout.build(
            views,
            iconSymbol: "link",
            tint: .neutral,
            name: item.label,
            trailingViews: [views.pill],
            identifier: item.path,
            showDetails: false
        )
        views.detailLabel.stringValue = item.path
        ToolRowLayout.applyTheme(views, theme: theme, detailFailed: item.status == .missing)
        return view
    }

    private func managedStatusVisuals(_ status: ManagedItemStatus) -> (String, String) {
        switch status {
        case .linked: return ("Linked", theme.ansiHex[2])
        case .notLinked: return ("Not linked", theme.ansiHex[3])
        case .missing: return ("Missing", theme.ansiHex[1])
        }
    }

    // MARK: Global agent instructions (Part B)

    private func rebuildAgentSection() {
        clearStack(agentStack)
        if isLoadingDotfiles {
            let content = loadingLabel("Checking\u{2026}")
            agentStack.addArrangedSubview(content)
            content.widthAnchor.constraint(equalTo: agentStack.widthAnchor).isActive = true
            return
        }
        let desc = NSTextField(wrappingLabelWithString: "Three harness-expected filenames home-manager symlinks to the same shared AGENTS.md in the dotfiles repo.")
        desc.font = .systemFont(ofSize: 11)
        desc.textColor = HelmTheme.mutedInk(theme)
        desc.preferredMaxLayoutWidth = 520
        dynamicLabels.append(desc)
        agentStack.addArrangedSubview(desc)
        desc.widthAnchor.constraint(equalTo: agentStack.widthAnchor).isActive = true

        for item in agentItems {
            let row = agentInstructionRow(item)
            agentStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: agentStack.widthAnchor).isActive = true
        }
    }

    /// Same shared `ToolRowLayout` as `managedItemRow`/Software checklist.
    /// "Create link" now behaves exactly like the Software checklist's
    /// Install button (cockpit-bootstrap-software-row-parity): always
    /// present, only disabled + relabeled once already linked, rather than
    /// vanishing from the row entirely.
    private func agentInstructionRow(_ item: AgentInstructionsItem) -> NSView {
        let views = ToolRowLayout.Views(
            iconTile: IconTileView(), nameLabel: NSTextField(labelWithString: ""),
            detailLabel: NSTextField(labelWithString: ""), pill: NSView(),
            pillLabel: NSTextField(labelWithString: ""), trailingStack: NSStackView(),
            detailsButton: NSButton(), logField: NSTextField(wrappingLabelWithString: ""),
            logContainer: NSView(), rowContainer: HoverHighlightView()
        )
        dynamicLabels.append(contentsOf: [views.nameLabel, views.detailLabel])

        let (pillText, pillColor) = agentStatusVisuals(item.status)
        ToolRowLayout.pill(text: pillText, colorHex: pillColor, into: views.pill, label: views.pillLabel)

        let button = NSButton(title: item.status == .linked ? "Linked" : "Create link", target: self, action: #selector(createLinkClicked))
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.isEnabled = item.status != .linked

        let view = ToolRowLayout.build(
            views,
            iconSymbol: "doc.text",
            tint: .neutral,
            name: item.label,
            trailingViews: [views.pill, button],
            identifier: item.path,
            showDetails: false
        )
        views.detailLabel.stringValue = item.path
        ToolRowLayout.applyTheme(views, theme: theme, detailFailed: item.status == .notLinked)
        return view
    }

    private func agentStatusVisuals(_ status: AgentInstructionsRow) -> (String, String) {
        switch status {
        case .linked: return ("Linked", theme.ansiHex[2])
        case .notLinked: return ("Not linked", theme.ansiHex[1])
        case .wrongTarget: return ("Wrong target", theme.ansiHex[3])
        }
    }

    // MARK: Software checklist (Part C)

    /// Checks every catalog item off the main thread via `UpdatesSource.check`
    /// - the exact same function the Updates page's own automatic check-on-
    /// load uses - then re-renders once. Runs once per page visit (mirrors
    /// `UpdatesController.hasCheckedOnce`), not on every navigation back to
    /// this page, so re-opening Bootstrap doesn't re-shell out to npm/brew/
    /// herdr repeatedly; the card's `Toast`-free rows re-check themselves
    /// individually after a successful Install anyway.
    private func checkAllSoftware(completion: (() -> Void)? = nil) {
        isLoadingSoftware = true
        rebuildSoftwareSection()
        let items = softwareRows.map { $0.item }
        DispatchQueue.global(qos: .userInitiated).async {
            let outcomes = items.map { ($0.id, UpdatesSource.check($0)) }
            DispatchQueue.main.async { [weak self] in
                guard let self else { completion?(); return }
                for (id, outcome) in outcomes {
                    guard let row = self.softwareRows.first(where: { $0.item.id == id }) else { continue }
                    row.status = outcome.status
                    row.detail = outcome.detail
                    row.log = outcome.log
                }
                self.isLoadingSoftware = false
                self.rebuildSoftwareSection()
                // Dotfiles and software load independently (see
                // `refreshDotfiles`) - whichever finishes second is the one
                // that can actually satisfy `maybeSeedInitialDriftStatus`'s
                // "both loaded" guard, so both completion paths need to try
                // seeding, not just `refreshDotfiles`'s.
                self.maybeSeedInitialDriftStatus()
                self.rebuildDriftSection()
                completion?()
            }
        }
    }

    private func rebuildSoftwareSection() {
        // Also refreshes the stepper's dot/chip state, since this is the one
        // rebuild function guaranteed to run on every path that can change
        // whether a step is "done" (initial check, install, and the shared
        // `rebuildDynamicSections` sweep that also covers dotfiles/agent/theme
        // changes) - see the `StepRowViews` doc comment for why the stepper
        // itself isn't rebuilt from scratch here.
        defer { refreshStepperVisuals() }
        clearStack(softwareStack)
        if isLoadingSoftware {
            let content = loadingLabel("Checking installed tools\u{2026}")
            softwareStack.addArrangedSubview(content)
            content.widthAnchor.constraint(equalTo: softwareStack.widthAnchor).isActive = true
            return
        }
        let missingCount = softwareRows.filter { $0.status == .notInstalled }.count
        if missingCount > 0 {
            let button = NSButton(title: "Install everything missing (\(missingCount))", target: self, action: #selector(installAllMissingClicked))
            button.bezelStyle = .rounded
            button.isEnabled = !softwareRows.contains { $0.isBusy }
            softwareStack.addArrangedSubview(button)
            softwareStack.setCustomSpacing(12, after: button)
        }
        for category in DependencyCatalog.categoryOrder {
            let categoryRows = softwareRows.filter { $0.item.category == category }
            guard !categoryRows.isEmpty else { continue }

            let categoryLabel = NSTextField(labelWithString: category)
            categoryLabel.font = .systemFont(ofSize: 12, weight: .semibold)
            dynamicLabels.append(categoryLabel)
            softwareStack.addArrangedSubview(categoryLabel)
            categoryLabel.widthAnchor.constraint(equalTo: softwareStack.widthAnchor).isActive = true

            for row in categoryRows {
                let view = softwareItemRow(row)
                softwareStack.addArrangedSubview(view)
                view.widthAnchor.constraint(equalTo: softwareStack.widthAnchor).isActive = true
            }
        }
    }

    /// Built fresh on every `rebuildSoftwareSection()` call via the shared
    /// `ToolRowLayout` (same icon tile, detail line, pill, and expandable-log
    /// chevron as `UpdatesController`'s per-tool rows, cockpit-bootstrap-
    /// software-row-parity) - the Install button is always present, only its
    /// enabled state and title change with `row.status`/`row.isBusy`, so the
    /// row never visibly reflows between not-installed/installing/installed.
    private func softwareItemRow(_ row: SoftwareRowState) -> NSView {
        let views = ToolRowLayout.Views(
            iconTile: IconTileView(), nameLabel: NSTextField(labelWithString: ""),
            detailLabel: NSTextField(labelWithString: ""), pill: NSView(),
            pillLabel: NSTextField(labelWithString: ""), trailingStack: NSStackView(),
            detailsButton: NSButton(), logField: NSTextField(wrappingLabelWithString: ""),
            logContainer: NSView(), rowContainer: HoverHighlightView()
        )
        dynamicLabels.append(contentsOf: [views.nameLabel, views.detailLabel])

        let (pillText, pillColor) = softwareStatusVisuals(row.status)
        ToolRowLayout.pill(text: pillText, colorHex: pillColor, into: views.pill, label: views.pillLabel)

        let button = NSButton(title: installButtonTitle(row), target: self, action: #selector(installSoftwareClicked(_:)))
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.isEnabled = installButtonEnabled(row)
        button.identifier = NSUserInterfaceItemIdentifier(row.item.id)

        let view = ToolRowLayout.build(
            views,
            iconSymbol: row.item.kind.symbol,
            tint: DependencyCatalog.tint(for: row.item.category),
            name: row.item.name,
            trailingViews: [views.pill, button],
            detailsTarget: self,
            detailsAction: #selector(softwareDetailsTapped(_:)),
            identifier: row.item.id
        )
        views.detailLabel.stringValue = row.detail
        ToolRowLayout.setLogExpanded(views, expanded: row.isLogExpanded, log: row.log)
        ToolRowLayout.applyTheme(views, theme: theme, detailFailed: row.status == .checkFailed || row.status == .updateFailed)
        return view
    }

    /// Enabled + "Install" only while genuinely actionable; every other
    /// status (installed, up to date, check failed, ...) disables the same
    /// button in place with "Installed" rather than hiding it - see the task
    /// brief this fixed (cockpit-bootstrap-software-row-parity): the button
    /// used to only exist in the view hierarchy for `.notInstalled` rows.
    private func installButtonTitle(_ row: SoftwareRowState) -> String {
        if row.isBusy { return "Installing\u{2026}" }
        return row.status == .notInstalled ? "Install" : "Installed"
    }

    private func installButtonEnabled(_ row: SoftwareRowState) -> Bool {
        row.status == .notInstalled && !row.isBusy
    }

    @objc private func softwareDetailsTapped(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue,
              let row = softwareRows.first(where: { $0.item.id == id })
        else { return }
        row.isLogExpanded.toggle()
        rebuildSoftwareSection()
    }

    private func softwareStatusVisuals(_ status: DependencyStatus) -> (String, String) {
        switch status {
        case .unknown: return ("Not checked", theme.chromeInkHex)
        case .checking: return ("Checking\u{2026}", theme.chromeInkHex)
        case .upToDate: return ("Installed", theme.ansiHex[2])
        case .updateAvailable: return ("Update available", theme.ansiHex[3])
        case .notInstalled: return ("Not installed", theme.ansiHex[3])
        case .checkFailed: return ("Check failed", theme.ansiHex[1])
        case .updating: return ("Installing\u{2026}", theme.chromeInkHex)
        case .updateFailed: return ("Install failed", theme.ansiHex[1])
        }
    }

    @objc private func installSoftwareClicked(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue,
              let row = softwareRows.first(where: { $0.item.id == id }),
              !row.isBusy
        else { return }
        performInstall(row) { _ in }
    }

    @objc private func installAllMissingClicked() {
        installAllMissing { _ in }
    }

    /// Installs every row currently `.notInstalled`, one at a time (not
    /// concurrently - avoids racing two `brew`/`npm` invocations against each
    /// other's lock file), re-checking each as it finishes. Used by both the
    /// software card's own "Install everything missing" button and the "Run
    /// full setup" sequencer's software step - same underlying action either
    /// way, just batched.
    private func installAllMissing(completion: @escaping (Bool) -> Void) {
        let missing = softwareRows.filter { $0.status == .notInstalled && !$0.isBusy }
        guard !missing.isEmpty else { completion(true); return }
        var overallOk = true
        func runNext(_ index: Int) {
            guard index < missing.count else { completion(overallOk); return }
            performInstall(missing[index]) { ok in
                if !ok { overallOk = false }
                runNext(index + 1)
            }
        }
        runNext(0)
    }

    /// Shared install-one-row action behind both the per-row "Install"
    /// button and `installAllMissing` - calls the exact same
    /// `UpdatesSource.update`/`.check` pair the Updates page itself uses.
    private func performInstall(_ row: SoftwareRowState, completion: @escaping (Bool) -> Void) {
        row.isBusy = true
        row.status = .updating
        rebuildSoftwareSection()

        let item = row.item
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let outcome = UpdatesSource.update(item)
            let recheck = UpdatesSource.check(item)
            DispatchQueue.main.async {
                guard let self, let row = self.softwareRows.first(where: { $0.item.id == item.id }) else {
                    completion(false)
                    return
                }
                row.isBusy = false
                row.status = recheck.status
                row.detail = recheck.detail
                // Mirrors `UpdatesController.update`'s log handling: on
                // success show the post-install check's own output (real
                // verification), on failure keep the install command's
                // output (why it failed) rather than the recheck's.
                row.log = outcome.ok ? recheck.log : outcome.log
                self.rebuildSoftwareSection()
                if outcome.ok {
                    Toast.show(in: self.view, message: "\(item.name) installed")
                } else {
                    Toast.show(in: self.view, message: "\(item.name) install failed")
                }
                completion(outcome.ok)
            }
        }
    }

    // MARK: Not synced here, by design (Part E)

    /// SSH keys and `.env`/secrets stay permanently static text - no button,
    /// no live check, by design (see this file's header comment and the task
    /// that added this card). GitHub/`gh` auth is the one row with a real
    /// mechanism (`av harden gh`), so it's the only one checked live.
    private func rebuildNotSyncedSection() {
        clearStack(notSyncedStack)

        let intro = NSTextField(wrappingLabelWithString: "This page automates machine setup, but deliberately stops short of syncing credentials between machines. What's static here is static by design, not an oversight.")
        intro.font = .systemFont(ofSize: 11)
        intro.textColor = HelmTheme.mutedInk(theme)
        intro.preferredMaxLayoutWidth = 520
        dynamicLabels.append(intro)
        notSyncedStack.addArrangedSubview(intro)
        intro.widthAnchor.constraint(equalTo: notSyncedStack.widthAnchor).isActive = true

        let sshRow = notSyncedStaticRow(
            title: "SSH private keys",
            body: "The cockpit's own Keychain-backed key store (see the Keys screen) saves keys with ThisDeviceOnly accessibility and never syncs them through iCloud. Re-add a key per machine from the Keys screen."
        )
        notSyncedStack.addArrangedSubview(sshRow)
        sshRow.widthAnchor.constraint(equalTo: notSyncedStack.widthAnchor).isActive = true

        let envRow = notSyncedStaticRow(
            title: ".env / secrets / tokens",
            body: "Never committed to the dotfiles repo - gitignored by design, same as firstmate's own .env. Copy these by hand or from a password manager on each machine."
        )
        notSyncedStack.addArrangedSubview(envRow)
        envRow.widthAnchor.constraint(equalTo: notSyncedStack.widthAnchor).isActive = true

        let ghRow = ghAuthRow()
        notSyncedStack.addArrangedSubview(ghRow)
        ghRow.widthAnchor.constraint(equalTo: notSyncedStack.widthAnchor).isActive = true

        let awsRow = awsAuthRow()
        notSyncedStack.addArrangedSubview(awsRow)
        awsRow.widthAnchor.constraint(equalTo: notSyncedStack.widthAnchor).isActive = true

        let codexRow = codexAuthRow()
        notSyncedStack.addArrangedSubview(codexRow)
        codexRow.widthAnchor.constraint(equalTo: notSyncedStack.widthAnchor).isActive = true

        let homebrewRow = homebrewAuthRow()
        notSyncedStack.addArrangedSubview(homebrewRow)
        homebrewRow.widthAnchor.constraint(equalTo: notSyncedStack.widthAnchor).isActive = true
    }

    private func notSyncedStaticRow(title: String, body: String) -> NSView {
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 12.5, weight: .medium)
        dynamicLabels.append(titleLabel)

        let bodyLabel = NSTextField(wrappingLabelWithString: body)
        bodyLabel.font = .systemFont(ofSize: 11)
        bodyLabel.textColor = HelmTheme.mutedInk(theme)
        bodyLabel.preferredMaxLayoutWidth = 520
        dynamicLabels.append(bodyLabel)

        let section = NSStackView(views: [titleLabel, bodyLabel])
        section.orientation = .vertical
        section.alignment = .leading
        section.spacing = 2
        bodyLabel.widthAnchor.constraint(equalTo: section.widthAnchor).isActive = true
        return section
    }

    /// Shared title/body/trailing-controls chrome for one "Not synced"
    /// hardener row - `extra` inserts additional views (e.g. Homebrew's
    /// disruption warning + confirmation checkbox) between the body text
    /// and the trailing controls row.
    private func notSyncedHardenerRow(title: String, body: String, extra: [NSView] = [], trailing: [NSView] = []) -> NSView {
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 12.5, weight: .medium)
        dynamicLabels.append(titleLabel)

        let bodyLabel = NSTextField(wrappingLabelWithString: body)
        bodyLabel.font = .systemFont(ofSize: 11)
        bodyLabel.textColor = HelmTheme.mutedInk(theme)
        bodyLabel.preferredMaxLayoutWidth = 520
        dynamicLabels.append(bodyLabel)

        var rows: [NSView] = [titleLabel, bodyLabel]
        rows.append(contentsOf: extra)
        if !trailing.isEmpty {
            let trailingRow = NSStackView(views: trailing)
            trailingRow.orientation = .horizontal
            trailingRow.alignment = .centerY
            trailingRow.spacing = 8
            rows.append(trailingRow)
        }

        let section = NSStackView(views: rows)
        section.orientation = .vertical
        section.alignment = .leading
        section.spacing = 4
        for row in rows { row.widthAnchor.constraint(equalTo: section.widthAnchor).isActive = true }
        return section
    }

    private func ghAuthRow() -> NSView {
        let bodyText: String
        var trailing: [NSView] = []
        switch ghHardenStatus {
        case .checking:
            bodyText = "Checking Automic Vault's hardening status\u{2026}"
        case .avNotInstalled:
            bodyText = "Automic Vault (av) isn't installed, so there's nothing to check yet. Install it from the Software checklist card above, then revisit this page."
        case .hardened:
            bodyText = "Already hardened - gh credentials are migrated into Automic Vault's protected storage."
            trailing.append(statusPill(text: "Hardened", colorHex: theme.ansiHex[2]))
        case .notHardened:
            bodyText = "gh credentials are not yet migrated into Automic Vault. \"av harden gh\" moves them into protected storage and requires the patched gh-cli build (brew install automic-vault/isotopes/gh-cli)."
            let button = NSButton(title: isHardeningGh ? "Hardening\u{2026}" : "Harden via Automic Vault", target: self, action: #selector(hardenGhClicked))
            button.bezelStyle = .rounded
            button.isEnabled = !isHardeningGh
            trailing.append(button)
        case .isotopeMissingPlainGhInstalled:
            bodyText = "The plain `gh` formula is installed, but Automic Vault's patched gh-cli isotope isn't - and it conflicts with plain `gh`, so \"av harden gh\" can't just install it for you. Requires swapping `gh` for `automic-vault/isotopes/gh-cli` in your dotfiles' configuration.nix (homebrew.brews), then running rebuild.sh."
            trailing.append(statusPill(text: "Needs dotfiles change", colorHex: theme.ansiHex[3]))
        case .checkFailed(let reason):
            bodyText = "Could not check hardening status: \(reason)"
        }
        return notSyncedHardenerRow(title: "GitHub / gh CLI auth", body: bodyText, trailing: trailing)
    }

    private func awsAuthRow() -> NSView {
        let bodyText: String
        var trailing: [NSView] = []
        switch awsHardenStatus {
        case .checking:
            bodyText = "Checking Automic Vault's hardening status\u{2026}"
        case .avNotInstalled:
            bodyText = "Automic Vault (av) isn't installed, so there's nothing to check yet. Install it from the Software checklist card above, then revisit this page."
        case .hardened:
            bodyText = "Already hardened - the default AWS key pair is migrated into the login keychain behind a protected /usr/local/bin/aws launcher."
            trailing.append(statusPill(text: "Hardened", colorHex: theme.ansiHex[2]))
        case .noLocalCredentials:
            bodyText = "No local AWS credentials found in ~/.aws/credentials - nothing to harden yet. \"av harden aws\" migrates an existing default key pair once one exists on this machine."
            trailing.append(statusPill(text: "Nothing to harden", colorHex: theme.ansiHex[3]))
        case .notHardened:
            bodyText = "A default AWS key pair exists in ~/.aws/credentials and is not yet migrated. \"av harden aws\" moves it into the login keychain and installs a protected /usr/local/bin/aws launcher in front of the real AWS CLI."
            let button = NSButton(title: isHardeningAws ? "Hardening\u{2026}" : "Harden via Automic Vault", target: self, action: #selector(hardenAwsClicked))
            button.bezelStyle = .rounded
            button.isEnabled = !isHardeningAws
            trailing.append(button)
        case .checkFailed(let reason):
            bodyText = "Could not check hardening status: \(reason)"
        }
        return notSyncedHardenerRow(title: "AWS CLI credentials", body: bodyText, trailing: trailing)
    }

    private func codexAuthRow() -> NSView {
        let bodyText: String
        var trailing: [NSView] = []
        switch codexHardenStatus {
        case .checking:
            bodyText = "Checking Automic Vault's hardening status\u{2026}"
        case .avNotInstalled:
            bodyText = "Automic Vault (av) isn't installed, so there's nothing to check yet. Install it from the Software checklist card above, then revisit this page."
        case .hardened:
            bodyText = "Already hardened - Codex CLI credentials are stored in the macOS Keychain instead of a plaintext auth.json."
            trailing.append(statusPill(text: "Hardened", colorHex: theme.ansiHex[2]))
        case .notHardened:
            bodyText = "Codex CLI credentials are still on disk in plaintext auth.json. \"av harden codex\" migrates them into the macOS Keychain. It refuses to run while ChatGPT.app is open, since Codex CLI, its IDE extension, and the ChatGPT desktop app share configuration - quit ChatGPT first."
            let button = NSButton(title: isHardeningCodex ? "Hardening\u{2026}" : "Harden via Automic Vault", target: self, action: #selector(hardenCodexClicked))
            button.bezelStyle = .rounded
            button.isEnabled = !isHardeningCodex
            trailing.append(button)
        case .checkFailed(let reason):
            bodyText = "Could not check hardening status: \(reason)"
        }
        return notSyncedHardenerRow(title: "Codex CLI credentials", body: bodyText, trailing: trailing)
    }

    private func homebrewAuthRow() -> NSView {
        let bodyText: String
        var extra: [NSView] = []
        var trailing: [NSView] = []
        switch homebrewHardenStatus {
        case .checking:
            bodyText = "Checking Automic Vault's hardening status\u{2026}"
        case .avNotInstalled:
            bodyText = "Automic Vault (av) isn't installed, so there's nothing to check yet. Install it from the Software checklist card above, then revisit this page."
        case .hardened:
            bodyText = "Already hardened - only brew itself can alter /opt/homebrew, and installs/upgrades require Automic Vault's approval."
            trailing.append(statusPill(text: "Hardened", colorHex: theme.ansiHex[2]))
        case .notHardened:
            bodyText = "Homebrew is not yet hardened. This is far more disruptive than the other rows on this card: shell completions become unavailable, most Homebrew casks become categorically incompatible (only CLI-only casks from homebrew/cask with a `binary` artifact still work), and it requires reordering PATH plus adding `eval \"$(/usr/local/bin/brew shellenv)\"` to your shell startup."
            let warning = NSTextField(wrappingLabelWithString: "Review that disruption before continuing - it changes how every `brew` command on this machine behaves.")
            warning.font = .systemFont(ofSize: 11, weight: .semibold)
            warning.textColor = HelmTheme.nsColor(theme.ansiHex[3])
            warning.preferredMaxLayoutWidth = 520
            dynamicLabels.append(warning)
            extra.append(warning)

            let checkbox = NSButton(checkboxWithTitle: "I understand the disruption above and want to continue", target: self, action: #selector(homebrewDisruptionToggled))
            checkbox.state = homebrewDisruptionAcknowledged ? .on : .off
            extra.append(checkbox)

            let button = NSButton(title: isHardeningHomebrew ? "Hardening\u{2026}" : "Harden via Automic Vault", target: self, action: #selector(hardenHomebrewClicked))
            button.bezelStyle = .rounded
            button.isEnabled = homebrewDisruptionAcknowledged && !isHardeningHomebrew
            trailing.append(button)
        case .checkFailed(let reason):
            bodyText = "Could not check hardening status: \(reason)"
        }
        return notSyncedHardenerRow(title: "Homebrew", body: bodyText, extra: extra, trailing: trailing)
    }

    @objc private func homebrewDisruptionToggled(_ sender: NSButton) {
        homebrewDisruptionAcknowledged = sender.state == .on
        rebuildNotSyncedSection()
    }

    private func checkGhHardening() {
        ghHardenStatus = .checking
        rebuildNotSyncedSection()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let status = NotSyncedSource.checkGhHardening()
            DispatchQueue.main.async {
                guard let self else { return }
                self.ghHardenStatus = status
                self.rebuildNotSyncedSection()
            }
        }
    }

    private func checkAwsHardening() {
        awsHardenStatus = .checking
        rebuildNotSyncedSection()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let status = NotSyncedSource.checkAwsHardening()
            DispatchQueue.main.async {
                guard let self else { return }
                self.awsHardenStatus = status
                self.rebuildNotSyncedSection()
            }
        }
    }

    private func checkCodexHardening() {
        codexHardenStatus = .checking
        rebuildNotSyncedSection()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let status = NotSyncedSource.checkCodexHardening()
            DispatchQueue.main.async {
                guard let self else { return }
                self.codexHardenStatus = status
                self.rebuildNotSyncedSection()
            }
        }
    }

    private func checkHomebrewHardening() {
        homebrewHardenStatus = .checking
        rebuildNotSyncedSection()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let status = NotSyncedSource.checkHomebrewHardening()
            DispatchQueue.main.async {
                guard let self else { return }
                self.homebrewHardenStatus = status
                self.rebuildNotSyncedSection()
            }
        }
    }

    @objc private func hardenGhClicked() {
        guard !isHardeningGh, let onRunCommandTracked else {
            onRunCommand?("av harden gh", "av harden gh")
            return
        }
        isHardeningGh = true
        rebuildNotSyncedSection()
        onRunCommandTracked("av harden gh", "av harden gh") { [weak self] _ in
            guard let self else { return }
            self.isHardeningGh = false
            self.checkGhHardening()
        }
    }

    @objc private func hardenAwsClicked() {
        guard !isHardeningAws, let onRunCommandTracked else {
            onRunCommand?("av harden aws", "av harden aws")
            return
        }
        isHardeningAws = true
        rebuildNotSyncedSection()
        onRunCommandTracked("av harden aws", "av harden aws") { [weak self] _ in
            guard let self else { return }
            self.isHardeningAws = false
            self.checkAwsHardening()
        }
    }

    @objc private func hardenCodexClicked() {
        guard !isHardeningCodex, let onRunCommandTracked else {
            onRunCommand?("av harden codex", "av harden codex")
            return
        }
        isHardeningCodex = true
        rebuildNotSyncedSection()
        onRunCommandTracked("av harden codex", "av harden codex") { [weak self] _ in
            guard let self else { return }
            self.isHardeningCodex = false
            self.checkCodexHardening()
        }
    }

    @objc private func hardenHomebrewClicked() {
        guard homebrewDisruptionAcknowledged, !isHardeningHomebrew, let onRunCommandTracked else {
            if homebrewDisruptionAcknowledged { onRunCommand?("av harden brew", "av harden brew") }
            return
        }
        isHardeningHomebrew = true
        rebuildNotSyncedSection()
        onRunCommandTracked("av harden brew", "av harden brew") { [weak self] _ in
            guard let self else { return }
            self.isHardeningHomebrew = false
            self.checkHomebrewHardening()
        }
    }

    // MARK: Shared row/label chrome

    /// Labels built by the dynamic sections above are recreated on every
    /// refresh (`clearStack` tears the old ones down), so this app's
    /// existing "re-theme on `ThemeManager.shared.observe`" convention
    /// (see `HelmTheme.swift`) needs a per-refresh list to walk instead of
    /// a fixed set of `@IBOutlet`-style properties.
    private var dynamicLabels: [NSTextField] = []

    private func clearStack(_ stack: NSStackView) {
        for v in stack.arrangedSubviews {
            stack.removeArrangedSubview(v)
            v.removeFromSuperview()
        }
    }

    private func loadingLabel(_ text: String) -> NSView {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 12)
        label.textColor = HelmTheme.mutedInk(theme)
        dynamicLabels.append(label)
        return label
    }

    private func statusPill(text: String, colorHex: String) -> NSView {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 10, weight: .semibold)
        label.textColor = HelmTheme.nsColor(colorHex)
        label.translatesAutoresizingMaskIntoConstraints = false
        let container = NSView()
        container.wantsLayer = true
        container.layer?.cornerRadius = 8
        container.layer?.backgroundColor = HelmTheme.nsColor(colorHex).withAlphaComponent(0.15).cgColor
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 7),
            label.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -7),
            label.topAnchor.constraint(equalTo: container.topAnchor, constant: 2),
            label.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -2),
        ])
        return container
    }

    // MARK: Actions (Part A + B)

    @objc private func cloneAndBootstrapClicked() {
        let raw = clonePathField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let destination = raw.isEmpty ? DotfilesSource.defaultClonePath : raw
        let expanded = (destination as NSString).expandingTildeInPath
        let command = "git clone \(DotfilesSource.cloneURL) \"\(expanded)\" && cd \"\(expanded)\" && ./bootstrap.sh"
        onRunCommand?("Bootstrap", command)
    }

    @objc private func runRebuildClicked() {
        guard let repoPath = dotfilesRepoPath else { return }
        onRunCommand?("rebuild.sh", Self.rebuildCommand(repoPath: repoPath))
    }

    /// Fetches and fast-forwards from `origin` before applying - never a
    /// forced overwrite. `git pull --ff-only` aborts on its own, with a real,
    /// visible error in the Console tab, if the local checkout has diverged
    /// (uncommitted changes or a genuine merge conflict) - `rebuild.sh` never
    /// runs against a repo state that didn't cleanly update from GitHub.
    private static func rebuildCommand(repoPath: String) -> String {
        DotfilesRunCommand.rebuildCommand(repoPath: repoPath)
    }

    @objc private func createLinkClicked() {
        guard let repoPath = dotfilesRepoPath else { return }
        onRunCommand?("rebuild.sh", Self.rebuildCommand(repoPath: repoPath))
    }

    @objc private func saveUsernameClicked() {
        guard let repoPath = dotfilesRepoPath else { return }
        let newUsername = usernameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !newUsername.isEmpty else {
            showDotfilesStatus("Enter a username before saving.", isError: true)
            return
        }
        do {
            try DotfilesSource.writeFlakeUsername(repoPath: repoPath, newUsername: newUsername)
            showDotfilesStatus("Saved. Run rebuild.sh to apply.", isError: false)
            Toast.show(in: view, message: "flake.nix username saved")
        } catch {
            showDotfilesStatus("Could not save: \(error.localizedDescription)", isError: true)
        }
    }

    private func showDotfilesStatus(_ message: String, isError: Bool) {
        dotfilesStatusLabel.stringValue = message
        dotfilesStatusLabel.textColor = isError ? HelmTheme.nsColor(theme.ansiHex[1]) : HelmTheme.nsColor(theme.ansiHex[2])
        dotfilesStatusLabel.isHidden = false
    }

    // MARK: Sync

    private func refreshFromSettings() {
        guard isViewLoaded else { return }
        currentPathLabel.stringValue = FirstmateHome.root.path
        if pathField.stringValue.isEmpty {
            pathField.stringValue = AppSettings.shared.fmHome ?? FirstmateHome.root.path
        }
    }

    private func applyTheme() {
        guard isViewLoaded else { return }
        let surface = HelmTheme.nsColor(theme.chromeBackgroundHex)
        let line = HelmTheme.nsColor(theme.chromeLineHex)
        subtitleLabel.textColor = HelmTheme.mutedInk(theme)
        currentPathLabel.textColor = HelmTheme.mutedInk(theme)
        for v in cardBackgroundViews {
            v.layer?.backgroundColor = surface.withAlphaComponent(0.6).cgColor
            v.layer?.borderWidth = 1
            v.layer?.borderColor = line.withAlphaComponent(0.5).cgColor
        }
        for v in stepContentBackgrounds {
            v.layer?.backgroundColor = line.withAlphaComponent(0.08).cgColor
            v.layer?.borderWidth = 1
            v.layer?.borderColor = line.withAlphaComponent(0.3).cgColor
        }
    }
}
