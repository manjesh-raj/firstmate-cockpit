// Manjesh Grand Line - native macOS app.
//
// The window's root content view controller: a fixed `IconRailController` on
// the left, and to its right a `TopBarController` (always visible) above a
// body area that swaps between five destinations:
//
//   - .overview shows `FleetController` (Fix 1): the real fleet/PR dashboard.
//   - .hosts shows `HostsSidebarController` (Fix 2) as its own full
//     destination - no longer nested inside Console, so it's reachable
//     exactly like Settings is.
//   - .console shows `ConsoleController` alone: just the terminal/tabs area,
//     with no Hosts panel required to be visible alongside it.
//   - .review shows `ReviewController` (Fix 3, theme-audit task): the real,
//     data-backed PR review list, replacing the earlier "coming soon"
//     `PlaceholderViewController`.
//   - .settings shows `SettingsController` directly, in the body area rather
//     than a separate floating window, matching how the web app's Settings
//     is a `view`, not a window.
//
// Fix 1 (dedicated host pages) adds a sixth kind of destination that isn't
// part of the fixed `RailDestination` enum: one independent `ConsoleController`
// per connected host, holding only that host's own ssh tab(s) - never mixed
// with the Firstmate console's Mirror/Shell tabs. These are built lazily via
// `makeHostConsole` the first time `connectHost` sees a given host id, then
// kept around (and re-shown, not re-opened) for as long as that host stays
// saved - see `connectHost`/`removeHostConsole` below.
//
// Every destination view - the five fixed ones and any host page - is added
// as a child up front (or lazily for host pages) and just has its `isHidden`
// flipped, never rebuilt, so nothing here can drop a running terminal session
// or its tabs.

import AppKit

final class AppShellController: NSViewController {

    let rail = IconRailController()
    let topBar = TopBarController()
    private let hostsPanel: HostsSidebarController
    private let console: ConsoleController
    private let settings: SettingsController
    private let overview: FleetController
    private let shift: ShiftController
    private let review = ReviewController()
    private let tools = ToolsController()
    private let vault = VaultController()
    private let docs = DocsController()
    private let updates = UpdatesController()
    private let bootstrap: BootstrapController

    /// Fix 1: builds a fresh, host-scoped `ConsoleController` (no Mirror/
    /// Shell tabs - see `ConsoleController.init(opensFirstmateOnLaunch:)`).
    /// Injected so this controller doesn't need to know about
    /// `SSHKeyStore`/`SnippetStore`, matching how it already knows nothing
    /// about host persistence (see `onPresentHostEditor` below).
    private let makeHostConsole: () -> ConsoleController

    /// One dedicated page per connected host, keyed by `Host.id`. Built
    /// lazily by `connectHost`, torn down by `removeHostConsole` when a host
    /// is deleted from the store.
    private var hostConsoles: [UUID: ConsoleController] = [:]

    /// The body area every destination view (fixed or host page) is added
    /// to - a stored property (rather than a `loadView`-local `let`) so
    /// `connectHost`/`removeHostConsole` can add and remove host pages after
    /// the initial layout pass.
    private let bodyContainer = NSView()

    /// Set while a host's dedicated page is showing; `nil` whenever a fixed
    /// `RailDestination` is current. Mirrors `IconRailController.activeHostID`
    /// so `removeHostConsole` knows whether to navigate away.
    private var activeHostID: UUID?

    /// Add/Edit Host, requested from the Hosts panel - forwarded to whoever
    /// owns the host store (the app delegate), since this controller only
    /// arranges views and knows nothing about persistence.
    var onPresentHostEditor: ((Host?) -> Void)?

    // MARK: App-level password lock (fm/grandline-app-lock)

    private let lockScreen = LockScreenController()

    /// Fired once a correct password is entered - the app delegate's
    /// `AppLockController` owns turning this into "unlocked" state (and
    /// starting its own idle/hard-logout timers from this moment); this
    /// controller only knows "the form was accepted."
    var onUnlocked: (() -> Void)?

    /// Fired whenever the lock overlay's visibility changes, `true` while
    /// locked - the app delegate uses this to disable the main menu's
    /// content-bearing items (see `AppDelegate.setContentMenusEnabled`) so a
    /// keyboard shortcut like ⌘N can't reach a hidden destination's action
    /// while the overlay is covering it.
    var onLockStateChanged: ((Bool) -> Void)?

    /// The avatar's Logout action (double-confirmed inside `IconRailController`
    /// itself) - forwarded to the app delegate's `AppLockController`, which
    /// is what actually flips the lock state, matching how host-editor
    /// presentation is forwarded rather than owned here.
    var onLogoutRequested: (() -> Void)?

    init(
        hostsPanel: HostsSidebarController, console: ConsoleController, settings: SettingsController,
        hostStore: HostStore, keyStore: SSHKeyStore, snippetStore: SnippetStore, shiftStore: ShiftStore,
        makeHostConsole: @escaping () -> ConsoleController
    ) {
        self.hostsPanel = hostsPanel
        self.console = console
        self.settings = settings
        self.overview = FleetController()
        // Phase 5 (cockpit-shift-power-features): `shiftStore` is now built
        // once by the app delegate and shared with the menu bar item, the
        // search palette, and quick capture - all of which need to read/
        // write the same tasks/follow-ups this page shows, not a second
        // independent store instance.
        self.shift = ShiftController(store: shiftStore)
        self.bootstrap = BootstrapController(hostStore: hostStore, keyStore: keyStore, snippetStore: snippetStore)
        self.makeHostConsole = makeHostConsole
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 1220, height: 720))
        view = root

        addChild(rail)
        root.addSubview(rail.view)
        rail.view.translatesAutoresizingMaskIntoConstraints = false
        rail.onSelect = { [weak self] dest in self?.show(dest) }
        rail.onLogoutRequested = { [weak self] in self?.onLogoutRequested?() }

        bodyContainer.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(bodyContainer)

        addChild(topBar)
        bodyContainer.addSubview(topBar.view)
        topBar.view.translatesAutoresizingMaskIntoConstraints = false
        // Fix 4: the topbar Search control performs an in-terminal find
        // (the same action the console toolbar's magnifying-glass icon
        // triggers), not anything host-related.
        topBar.onSearchTapped = { [weak self] in self?.activateConsoleFind() }

        addChild(hostsPanel)
        addChild(console)
        addChild(overview)
        addChild(shift)
        addChild(review)
        addChild(tools)
        addChild(vault)
        addChild(docs)
        addChild(updates)
        addChild(bootstrap)
        addChild(settings)

        for destinationView in [hostsPanel.view, console.view, overview.view, shift.view, review.view, tools.view, vault.view, docs.view, updates.view, bootstrap.view, settings.view] {
            embed(destinationView)
        }

        NSLayoutConstraint.activate([
            rail.view.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            rail.view.topAnchor.constraint(equalTo: root.topAnchor),
            rail.view.bottomAnchor.constraint(equalTo: root.bottomAnchor),

            bodyContainer.leadingAnchor.constraint(equalTo: rail.view.trailingAnchor),
            bodyContainer.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            bodyContainer.topAnchor.constraint(equalTo: root.topAnchor),
            bodyContainer.bottomAnchor.constraint(equalTo: root.bottomAnchor),

            topBar.view.leadingAnchor.constraint(equalTo: bodyContainer.leadingAnchor),
            topBar.view.trailingAnchor.constraint(equalTo: bodyContainer.trailingAnchor),
            topBar.view.topAnchor.constraint(equalTo: bodyContainer.topAnchor),
            topBar.view.heightAnchor.constraint(equalToConstant: TopBarController.height),
        ])

        hostsPanel.onAddOrEdit = { [weak self] host in self?.onPresentHostEditor?(host) }
        // cockpit-bootstrap-dotfiles: every command the Bootstrap page can run
        // that touches `darwin-rebuild switch` (needs an interactive `sudo`
        // TTY) opens as a real tab in the shared Firstmate console rather
        // than a silent background process - see `runInConsole` below.
        bootstrap.onRunCommand = { [weak self] label, command in self?.runInConsole(label: label, command: command) }
        // cockpit-bootstrap-full-setup: the "Run full setup" sequencer needs
        // to know a step's Console command actually finished (not a fixed
        // timer) before starting the next one - same tab, same command
        // string, just with a completion callback threaded through.
        bootstrap.onRunCommandTracked = { [weak self] label, command, completion in
            self?.runInConsole(label: label, command: command, completion: completion)
        }
        // cockpit-bootstrap-software: a `.notInstalled` row on the Updates
        // page no longer installs inline - it links to the Bootstrap page's
        // own Software checklist card instead (same catalog, same install
        // action, just relocated).
        updates.onNavigateToBootstrap = { [weak self] in self?.show(.bootstrap) }
        // cockpit-settings-sudo-touchid: Settings' "Touch ID for sudo" row
        // runs `sudo av harden sudo`, which needs a real interactive `sudo`
        // prompt exactly like Bootstrap's provisioning actions - same
        // one-shot Console command-tab mechanism, just reached from Settings
        // instead.
        settings.onRunCommand = { [weak self] label, command in self?.runInConsole(label: label, command: command) }
        settings.onRunCommandTracked = { [weak self] label, command, completion in
            self?.runInConsole(label: label, command: command, completion: completion)
        }
        // fm/grandline-vault-tab: `av save`/`av inject` both need a real
        // interactive terminal (see `VaultController`'s header) - same
        // one-shot Console command-tab mechanism as every other
        // interactive/sudo action in this app.
        vault.onRunCommand = { [weak self] label, command in self?.runInConsole(label: label, command: command) }
        vault.onRunCommandTracked = { [weak self] label, command, completion in
            self?.runInConsole(label: label, command: command, completion: completion)
        }

        // fm/grandline-sidebar-badges: forward each page's own already-
        // computed "needs you" count straight to its rail icon - no new
        // signal invented here, just the counts these two pages already
        // render every time they refresh.
        overview.onNeedsDecisionCountChanged = { [weak self] count in
            self?.rail.setBadgeCount(count, for: .overview)
        }
        review.onOpenPRCountChanged = { [weak self] count in
            self?.rail.setBadgeCount(count, for: .review)
        }
        // Trigger both pages' own refresh once at launch so the badges have
        // a real count before the captain ever visits Overview or Review -
        // every later update comes from those pages' existing refresh
        // triggers (page visit, manual refresh, a merge action), not a new
        // poll loop.
        overview.refreshIfNeeded()
        review.refreshIfNeeded()

        show(.console)

        // Added last (and therefore topmost in z-order) so it covers the
        // rail as well as the body area - no fleet/secrets/hosts content, or
        // the rail itself, should be visible or reachable while locked.
        addChild(lockScreen)
        root.addSubview(lockScreen.view)
        lockScreen.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            lockScreen.view.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            lockScreen.view.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            lockScreen.view.topAnchor.constraint(equalTo: root.topAnchor),
            lockScreen.view.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        lockScreen.view.isHidden = true
        lockScreen.onAttempt = { typed, completion in
            DispatchQueue.global(qos: .userInitiated).async {
                let ok = VaultSource.verifyAppPassword(typed)
                DispatchQueue.main.async { completion(ok) }
            }
        }
        // Fires only once the success animation has actually played out
        // (see `LockScreenController.playUnlockSuccessAnimation`) - hiding
        // the overlay from `onAttempt`'s own completion instead would cut
        // that animation off before it's visible at all.
        lockScreen.onUnlockAnimationFinished = { [weak self] in
            self?.hideLock()
            self?.onUnlocked?()
        }
    }

    // MARK: App-level password lock (fm/grandline-app-lock)

    /// Shows the lock overlay for `reason`, re-checking whether
    /// `GRANDLINE_APP_PASSWORD` is actually configured in Automic Vault
    /// (never cached - the captain could set it between one lock and the
    /// next) before deciding which of the lock screen's two states to show.
    func showLock(reason: AppLockReason) {
        lockScreen.view.isHidden = false
        onLockStateChanged?(true)
        // Optimistic default so the overlay never shows a blank subtitle for
        // the fraction of a second the background `av list` check takes -
        // corrected below once that check actually resolves.
        let optimisticSubtitle = reason == .sessionExpired
            ? "Your session expired - please log in again."
            : "Manjesh Grand Line is locked."
        lockScreen.apply(.locked(subtitle: optimisticSubtitle))
        lockScreen.focusPasswordField()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let availability = VaultSource.checkAppPasswordConfigured()
            DispatchQueue.main.async {
                guard let self else { return }
                switch availability {
                case .configured:
                    let subtitle = reason == .sessionExpired
                        ? "Your session expired - please log in again."
                        : "Manjesh Grand Line is locked."
                    self.lockScreen.apply(.locked(subtitle: subtitle))
                case .notConfigured, .avUnavailable:
                    self.lockScreen.apply(.noPasswordConfigured)
                }
                self.lockScreen.focusPasswordField()
            }
        }
    }

    private func hideLock() {
        lockScreen.view.isHidden = true
        onLockStateChanged?(false)
    }

    /// Open `command` as a new tab in the shared Firstmate console and bring
    /// Console forward, so its output (and any `sudo` prompt) is visible
    /// immediately - the one path every Bootstrap-page action that can invoke
    /// `darwin-rebuild switch` uses (`bootstrap.sh`, `rebuild.sh`, the initial
    /// clone).
    func runInConsole(label: String, command: String, completion: ((Bool) -> Void)? = nil) {
        console.openCommandTab(label: label, command: command) { exitCode in completion?(exitCode == 0) }
        show(.console)
    }

    /// Pin a destination view to fill `bodyContainer` below the top bar -
    /// the same anchors every fixed destination and every host page use.
    private func embed(_ destinationView: NSView) {
        destinationView.translatesAutoresizingMaskIntoConstraints = false
        bodyContainer.addSubview(destinationView)
        NSLayoutConstraint.activate([
            destinationView.leadingAnchor.constraint(equalTo: bodyContainer.leadingAnchor),
            destinationView.trailingAnchor.constraint(equalTo: bodyContainer.trailingAnchor),
            destinationView.topAnchor.constraint(equalTo: topBar.view.bottomAnchor),
            destinationView.bottomAnchor.constraint(equalTo: bodyContainer.bottomAnchor),
        ])
    }

    // MARK: Destination switching

    /// Internal (not `private`): the app delegate also calls this directly
    /// after connecting the Firstmate console, so the new tab is visible
    /// immediately instead of landing silently in the background.
    func show(_ dest: RailDestination) {
        hideAllDestinations()

        switch dest {
        case .overview:
            overview.view.isHidden = false
            topBar.setTitle("Overview")
        case .shift:
            shift.view.isHidden = false
            topBar.setTitle("Tasks")
        case .hosts:
            hostsPanel.view.isHidden = false
            topBar.setTitle("Hosts")
        case .console:
            console.view.isHidden = false
            topBar.setTitle("Console")
        case .review:
            review.view.isHidden = false
            topBar.setTitle("Review")
        case .tools:
            tools.view.isHidden = false
            topBar.setTitle("Tools")
        case .vault:
            vault.view.isHidden = false
            topBar.setTitle("Vault")
        case .docs:
            docs.view.isHidden = false
            topBar.setTitle("Docs")
        case .updates:
            updates.view.isHidden = false
            topBar.setTitle("Updates")
        case .bootstrap:
            bootstrap.view.isHidden = false
            topBar.setTitle("Bootstrap")
        case .settings:
            settings.view.isHidden = false
            topBar.setTitle("Settings")
        }
        rail.setActive(dest)
    }

    /// Fix 1: connect to `host` (its own dedicated page). The first call for
    /// a given host builds its `ConsoleController` (via `makeHostConsole`),
    /// embeds it, and opens its one ssh tab; every later call for the same
    /// host just brings that already-built page forward and re-focuses its
    /// current tab - `ConsoleController.connectSSHIfNeeded` is what actually
    /// makes the "open a tab" half of that a no-op after the first time.
    /// `args` is the host's resolved `ssh` argv (`Host.sshArguments(allHosts:)`)
    /// - built by the caller, since this controller knows nothing about the
    /// host store, matching `onPresentHostEditor` above.
    func connectHost(_ host: Host, args: [String]) {
        let controller: ConsoleController
        if let existing = hostConsoles[host.id] {
            controller = existing
        } else {
            controller = makeHostConsole()
            hostConsoles[host.id] = controller
            addChild(controller)
            embed(controller.view)
            controller.view.isHidden = true
        }
        controller.connectSSHIfNeeded(
            label: host.label, args: args, accentHex: host.accentHex,
            keyID: host.keyID, startupSnippetID: host.startupSnippetID,
            blockViewOptIn: host.blockViewOptIn
        )

        hideAllDestinations()
        controller.view.isHidden = false
        topBar.setTitle(host.label)
        activeHostID = host.id
        rail.setActiveHost(host.id)
        controller.focusCurrentTab()
    }

    /// A host was deleted from the store - tear down its dedicated page
    /// (if it was ever connected to) so a stale, unreachable-from-the-rail
    /// destination can't linger. Navigates back to the Firstmate console if
    /// the deleted host's page happened to be the one showing.
    func removeHostConsole(id: UUID) {
        guard let controller = hostConsoles.removeValue(forKey: id) else { return }
        controller.shutdown()
        controller.view.removeFromSuperview()
        controller.removeFromParent()
        if activeHostID == id {
            show(.console)
        }
    }

    private func hideAllDestinations() {
        hostsPanel.view.isHidden = true
        console.view.isHidden = true
        overview.view.isHidden = true
        shift.view.isHidden = true
        review.view.isHidden = true
        tools.view.isHidden = true
        vault.view.isHidden = true
        docs.view.isHidden = true
        updates.view.isHidden = true
        bootstrap.view.isHidden = true
        settings.view.isHidden = true
        for controller in hostConsoles.values { controller.view.isHidden = true }
        activeHostID = nil
    }

    /// The Hosts menu's "Quick Connect" (⌘K): reveal the Hosts destination
    /// and focus its quick-connect field, regardless of which destination
    /// was active. No longer shared with the topbar Search control (Fix 4).
    @objc func revealHostsQuickConnect() {
        show(.hosts)
        hostsPanel.focusQuickConnect()
    }

    /// The topbar Search pill / its own ⌘K: invoke the exact same find
    /// action the console toolbar's magnifying-glass icon uses, on whichever
    /// console is actually on screen. Fix 1: if a host's dedicated page is
    /// showing, find there rather than yanking the captain over to the
    /// unrelated shared Firstmate console just because that's this method's
    /// historical default - otherwise a host page's ⌘K would silently
    /// navigate away from the session being read and search the wrong
    /// terminal. With no host page active, the original behaviour holds:
    /// bring Console forward (so the find bar it triggers is visible) first.
    @objc func activateConsoleFind() {
        if let activeHostID, let controller = hostConsoles[activeHostID] {
            controller.showFind()
            return
        }
        show(.console)
        console.showFind()
    }

    /// The App menu's "Settings…" (⌘,): select the Settings rail destination
    /// rather than opening a separate window.
    @objc func selectSettings() {
        show(.settings)
    }

    /// The Hosts menu's "Show Hosts": select the Hosts rail destination.
    @objc func selectHosts() {
        show(.hosts)
    }

    /// The Shift menu's "New Task…" (⌘N) - selects the Shift destination
    /// first so the sheet has something to present over, then opens the New
    /// Task editor regardless of whichever destination was showing before.
    @objc func newShiftTaskFromMenu() {
        show(.shift)
        shift.presentNewTaskEditor()
    }

    /// The Shift menu's "New Follow-up…" (⌘⇧F) - same shape as
    /// `newShiftTaskFromMenu` above.
    @objc func newShiftFollowUpFromMenu() {
        show(.shift)
        shift.presentNewFollowUpEditor()
    }

    /// The Shift menu's "New Project…" (cockpit-fix-shift-new-project) - no
    /// keyboard shortcut, since ⌘⇧P (the pattern ⌘N/⌘⇧F would suggest for a
    /// third Shift creation action) is already claimed by "Search Shift…"
    /// below - same shape as "Weekly Review", which also has no shortcut.
    @objc func newShiftProjectFromMenu() {
        show(.shift)
        shift.presentNewProjectEditor()
    }

    // MARK: Search / menu bar / quick-capture navigation (phase 5)

    /// The Shift menu's "Search Shift…" (⌘⇧P) and the search palette's own
    /// entry point - selects the Shift destination so a result's editor
    /// sheet (below) has somewhere to present over.
    func showShiftDestination() { show(.shift) }

    /// The ⌘⇧P search palette's "Weekly Review" navigation, and the Shift
    /// menu's own "Weekly Review" item.
    @objc func showShiftWeeklyReview() {
        show(.shift)
        shift.showWeeklyReview()
    }

    /// A search-palette or menu-bar-popover selection resolving to a task/
    /// follow-up/project - each opens the same editor sheet the Shift page's
    /// own row click already uses, so there is exactly one "open this task"
    /// behavior regardless of entry point.
    func openShiftTask(id: String) {
        show(.shift)
        shift.openTask(id: id)
    }

    func openShiftFollowUp(id: String) {
        show(.shift)
        shift.openFollowUp(id: id)
    }

    func openShiftProject(id: String) {
        show(.shift)
        shift.openProject(id: id)
    }

    /// Fix 5: a host save closes its own (separate) editor window
    /// immediately, so the confirmation has to live somewhere that's still
    /// around afterward - the main window, regardless of which destination
    /// happens to be showing.
    func showToast(_ message: String) {
        Toast.show(in: view, message: message)
    }

    /// Fix 1: mirrors what `AppDelegate.applicationWillTerminate` already
    /// does for the shared Firstmate `console` - tear down every host
    /// page's mirrors/materialized keys/session logs on quit, not just the
    /// destination that happened to be visible.
    func shutdownAllHostConsoles() {
        for controller in hostConsoles.values { controller.shutdown() }
    }
}
