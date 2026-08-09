// Firstmate Cockpit - native macOS app.
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
// The Firstmate-home card lets the captain see and override
// `FirstmateHome.root` - which is a `static let`, resolved once at process
// launch (see that file) - so a change here can only take effect after a
// restart. Save & Verify never live-repoints already-resolved paths; it
// persists the candidate to `AppSettings.fmHome` and asks for a restart.

import AppKit

final class BootstrapController: NSViewController {

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
    /// `UpdatesController`'s private `UpdateRow`, but this card only ever
    /// needs status/detail/busy (no expandable log, no spinner chrome) since
    /// it's a compact checklist, not the Updates page's full row UI.
    private final class SoftwareRowState {
        let item: DependencyItem
        var status: DependencyStatus = .unknown
        var detail: String = "Not checked yet"
        var isBusy = false
        init(item: DependencyItem) { self.item = item }
    }

    private var softwareRows: [SoftwareRowState] = DependencyCatalog.items.map(SoftwareRowState.init)
    private var isLoadingSoftware = true
    private var hasCheckedSoftwareOnce = false
    private let softwareStack = NSStackView()

    // MARK: "Not synced here, by design" state (Part E)

    private var ghHardenStatus: GhHardenStatus = .checking
    private var isHardeningGh = false
    private var hasCheckedGhHardeningOnce = false
    private let notSyncedStack = NSStackView()

    // MARK: "Run full setup" sequencer state (Part D)

    private enum SetupStepKind: CaseIterable {
        case firstmateHome, dotfiles, agentInstructions, software

        var title: String {
            switch self {
            case .firstmateHome: return "Firstmate home"
            case .dotfiles: return "Dotfiles & machine config"
            case .agentInstructions: return "Global agent instructions"
            case .software: return "Software checklist"
            }
        }
    }

    private enum SetupStepStatus: Equatable {
        case pending, running, done, skipped, failed(String)
    }

    private struct SetupStepState {
        let kind: SetupStepKind
        var status: SetupStepStatus = .pending
    }

    private var setupSteps: [SetupStepState] = SetupStepKind.allCases.map { SetupStepState(kind: $0) }
    private var isRunningFullSetup = false
    private let setupStack = NSStackView()
    private let runFullSetupButton = NSButton()

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

        let homeCard = card(icon: "folder", title: "Firstmate home", content: buildHomeSection())

        dotfilesStack.orientation = .vertical
        dotfilesStack.alignment = .leading
        dotfilesStack.spacing = 10
        let dotfilesCard = card(icon: "gearshape.2", title: "Dotfiles & machine config", content: dotfilesStack)

        agentStack.orientation = .vertical
        agentStack.alignment = .leading
        agentStack.spacing = 10
        let agentCard = card(icon: "text.badge.checkmark", title: "Global agent instructions", content: agentStack)

        softwareStack.orientation = .vertical
        softwareStack.alignment = .leading
        softwareStack.spacing = 10
        let softwareCard = card(icon: "checklist", title: "Software checklist", content: softwareStack)

        notSyncedStack.orientation = .vertical
        notSyncedStack.alignment = .leading
        notSyncedStack.spacing = 10
        let notSyncedCard = card(icon: "lock.slash", title: "Not synced here, by design", content: notSyncedStack)

        let stack = NSStackView(views: [header, fullSetupCard, homeCard, dotfilesCard, agentCard, softwareCard, notSyncedCard])
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
            homeCard.widthAnchor.constraint(equalTo: stack.widthAnchor),
            dotfilesCard.widthAnchor.constraint(equalTo: stack.widthAnchor),
            agentCard.widthAnchor.constraint(equalTo: stack.widthAnchor),
            softwareCard.widthAnchor.constraint(equalTo: stack.widthAnchor),
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
        if !hasCheckedGhHardeningOnce {
            hasCheckedGhHardeningOnce = true
            checkGhHardening()
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

        restartButton.title = "Restart Firstmate Cockpit"
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
        showStatus("Saved. Restart Firstmate Cockpit for the new home to take effect.", isError: false)
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

    private func buildFullSetupSection() -> NSView {
        let desc = NSTextField(wrappingLabelWithString: "Runs the sections below in order for a blank-machine setup: Firstmate home, dotfiles & machine config, agent instructions, then software. A step only skips when it is already satisfied - dotfiles/rebuild always runs, since it is safe to re-run.")
        desc.font = .systemFont(ofSize: 11)
        desc.textColor = .secondaryLabelColor
        desc.preferredMaxLayoutWidth = 520

        runFullSetupButton.title = "Run full setup"
        runFullSetupButton.bezelStyle = .rounded
        runFullSetupButton.target = self
        runFullSetupButton.action = #selector(runFullSetupClicked)

        let section = NSStackView(views: [desc, runFullSetupButton, setupStack])
        section.orientation = .vertical
        section.alignment = .leading
        section.spacing = 10
        desc.widthAnchor.constraint(equalTo: section.widthAnchor).isActive = true
        setupStack.widthAnchor.constraint(equalTo: section.widthAnchor).isActive = true
        return section
    }

    private func rebuildSetupSection() {
        clearStack(setupStack)
        for step in setupSteps {
            let row = setupStepRow(step)
            setupStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: setupStack.widthAnchor).isActive = true
        }
        runFullSetupButton.title = isRunningFullSetup ? "Running\u{2026}" : "Run full setup"
        runFullSetupButton.isEnabled = !isRunningFullSetup
    }

    private func setupStepRow(_ step: SetupStepState) -> NSView {
        let titleLabel = NSTextField(labelWithString: step.kind.title)
        titleLabel.font = .systemFont(ofSize: 11.5)
        titleLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        dynamicLabels.append(titleLabel)

        let (pillText, pillColor) = setupStatusVisuals(step.status)
        let pill = statusPill(text: pillText, colorHex: pillColor)
        pill.setContentHuggingPriority(.required, for: .horizontal)
        pill.setContentCompressionResistancePriority(.required, for: .horizontal)

        let row = NSStackView(views: [titleLabel, pill])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8

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
        case .running: return ("Running\u{2026}", theme.chromeInkHex)
        case .done: return ("Done", theme.ansiHex[2])
        case .skipped: return ("Skipped", theme.chromeInkHex)
        case .failed: return ("Failed", theme.ansiHex[1])
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
        setupSteps = SetupStepKind.allCases.map { SetupStepState(kind: $0) }
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
            let label: String
            let command: String
            if let repoPath = self.dotfilesRepoPath {
                label = "rebuild.sh"
                command = "cd \"\(repoPath)\" && ./rebuild.sh"
            } else {
                let raw = self.clonePathField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                let destination = raw.isEmpty ? DotfilesSource.defaultClonePath : raw
                let expanded = (destination as NSString).expandingTildeInPath
                label = "Bootstrap"
                command = "git clone \(DotfilesSource.cloneURL) \"\(expanded)\" && cd \"\(expanded)\" && ./bootstrap.sh"
            }
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
        rebuildNotSyncedSection()
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

    private func managedItemRow(_ item: ManagedItem) -> NSView {
        let pathLabel = NSTextField(labelWithString: "\(item.label) (\(item.path))")
        pathLabel.font = .systemFont(ofSize: 11.5)
        pathLabel.lineBreakMode = .byTruncatingTail
        pathLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        pathLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        dynamicLabels.append(pathLabel)

        let (pillText, pillColor) = managedStatusVisuals(item.status)
        let pill = statusPill(text: pillText, colorHex: pillColor)

        let row = NSStackView(views: [pathLabel, pill])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        pill.setContentHuggingPriority(.required, for: .horizontal)
        pill.setContentCompressionResistancePriority(.required, for: .horizontal)
        return row
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

    private func agentInstructionRow(_ item: AgentInstructionsItem) -> NSView {
        let pathLabel = NSTextField(labelWithString: "\(item.label) (\(item.path))")
        pathLabel.font = .systemFont(ofSize: 11.5)
        pathLabel.lineBreakMode = .byTruncatingTail
        pathLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        pathLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        dynamicLabels.append(pathLabel)

        let (pillText, pillColor) = agentStatusVisuals(item.status)
        let pill = statusPill(text: pillText, colorHex: pillColor)
        pill.setContentHuggingPriority(.required, for: .horizontal)
        pill.setContentCompressionResistancePriority(.required, for: .horizontal)

        var trailing: [NSView] = [pill]
        if item.status != .linked {
            let button = NSButton(title: "Create link", target: self, action: #selector(createLinkClicked))
            button.bezelStyle = .rounded
            button.controlSize = .small
            button.setContentHuggingPriority(.required, for: .horizontal)
            button.setContentCompressionResistancePriority(.required, for: .horizontal)
            trailing.append(button)
        }

        let row = NSStackView(views: [pathLabel] + trailing)
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        return row
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
    private func checkAllSoftware() {
        isLoadingSoftware = true
        rebuildSoftwareSection()
        let items = softwareRows.map { $0.item }
        DispatchQueue.global(qos: .userInitiated).async {
            let outcomes = items.map { ($0.id, UpdatesSource.check($0)) }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                for (id, outcome) in outcomes {
                    guard let row = self.softwareRows.first(where: { $0.item.id == id }) else { continue }
                    row.status = outcome.status
                    row.detail = outcome.detail
                }
                self.isLoadingSoftware = false
                self.rebuildSoftwareSection()
            }
        }
    }

    private func rebuildSoftwareSection() {
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

    private func softwareItemRow(_ row: SoftwareRowState) -> NSView {
        let nameLabel = NSTextField(labelWithString: row.item.name)
        nameLabel.font = .systemFont(ofSize: 12)
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        dynamicLabels.append(nameLabel)

        let (pillText, pillColor) = softwareStatusVisuals(row.status)
        let pill = statusPill(text: pillText, colorHex: pillColor)
        pill.setContentHuggingPriority(.required, for: .horizontal)
        pill.setContentCompressionResistancePriority(.required, for: .horizontal)

        var trailing: [NSView] = [pill]
        if row.status == .notInstalled {
            let button = NSButton(title: row.isBusy ? "Installing\u{2026}" : "Install", target: self, action: #selector(installSoftwareClicked(_:)))
            button.bezelStyle = .rounded
            button.controlSize = .small
            button.isEnabled = !row.isBusy
            button.identifier = NSUserInterfaceItemIdentifier(row.item.id)
            button.setContentHuggingPriority(.required, for: .horizontal)
            button.setContentCompressionResistancePriority(.required, for: .horizontal)
            trailing.append(button)
        }

        let rowView = NSStackView(views: [nameLabel] + trailing)
        rowView.orientation = .horizontal
        rowView.alignment = .centerY
        rowView.spacing = 8
        return rowView
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

    private func ghAuthRow() -> NSView {
        let titleLabel = NSTextField(labelWithString: "GitHub / gh CLI auth")
        titleLabel.font = .systemFont(ofSize: 12.5, weight: .medium)
        dynamicLabels.append(titleLabel)

        let bodyText: String
        var trailing: [NSView] = []
        switch ghHardenStatus {
        case .checking:
            bodyText = "Checking Automic Vault's hardening status\u{2026}"
        case .avNotInstalled:
            bodyText = "Automic Vault (av) isn't installed, so there's nothing to check yet. Install it from the Software checklist card above, then revisit this page."
        case .hardened:
            bodyText = "Already hardened - gh credentials are migrated into Automic Vault's protected storage."
            let pill = statusPill(text: "Hardened", colorHex: theme.ansiHex[2])
            trailing.append(pill)
        case .notHardened:
            bodyText = "gh credentials are not yet migrated into Automic Vault. \"av harden gh\" moves them into protected storage and requires the patched gh-cli build (brew install automic-vault/isotopes/gh-cli)."
            let button = NSButton(title: isHardeningGh ? "Hardening\u{2026}" : "Harden via Automic Vault", target: self, action: #selector(hardenGhClicked))
            button.bezelStyle = .rounded
            button.isEnabled = !isHardeningGh
            trailing.append(button)
        case .checkFailed(let reason):
            bodyText = "Could not check hardening status: \(reason)"
        }

        let bodyLabel = NSTextField(wrappingLabelWithString: bodyText)
        bodyLabel.font = .systemFont(ofSize: 11)
        bodyLabel.textColor = HelmTheme.mutedInk(theme)
        bodyLabel.preferredMaxLayoutWidth = 520
        dynamicLabels.append(bodyLabel)

        var rows: [NSView] = [titleLabel, bodyLabel]
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
        onRunCommand?("rebuild.sh", "cd \"\(repoPath)\" && ./rebuild.sh")
    }

    @objc private func createLinkClicked() {
        guard let repoPath = dotfilesRepoPath else { return }
        onRunCommand?("rebuild.sh", "cd \"\(repoPath)\" && ./rebuild.sh")
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
    }
}
