// Manjesh Grand Line - native macOS app.
//
// The window's root content view controller: a fixed `IconRailController` on
// the left, and to its right a `TopBarController` (always visible) above a
// body area that swaps between five destinations:
//
//   - .overview shows `FleetController` (Fix 1): the real fleet/PR dashboard.
//   - .hosts shows `HostsController` (Fix 2) as its own full destination -
//     no longer nested inside Console, so it's reachable exactly like
//     Settings is. As of Phase 5 of the full-app UI audit that destination
//     also owns SSH Keys and Snippets as segmented tabs, so the two floating
//     windows those used to live in no longer exist.
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

    private var chromeTextScaleObservation: ChromeTextScaleObservation?

    let rail = IconRailController()
    let topBar = TopBarController()
    private let hostsPanel: HostsController
    private let console: ConsoleController
    private let settings: SettingsController
    private let overview: FleetController
    private let shift: ShiftController
    private let review = ReviewController()
    /// `fm/grandline-log-analyzer-build`: the Log / Output Analyzer page.
    /// Owns its own `CommandLibraryStore`/`DocsRunbookStore`/
    /// `LogAnalyzerStore`, so this controller needs to know nothing about
    /// any of them - the same forward-don't-own convention every other
    /// destination here follows.
    private let logAnalyzer: LogAnalyzerController
    private let tools = ToolsController()
    private let vault = VaultController()
    private let dictation: DictationController
    private let docs = DocsController()
    private let updates = UpdatesController()
    private let bootstrap: BootstrapController
    private let automation: AutomationController
    private let githubSync = GitHubSyncController()
    /// fm/grandline-design-fidelity-fixes: the four pages above are one Setup
    /// destination with a `HelmSegmentedTabs` row across the top, so the
    /// captain can move between them without going back out to the rail's
    /// Setup flyout. They are still four independent `RailDestination` cases
    /// and four independent controllers - this only parents them and switches
    /// which one is visible. See `SetupContainerController`.
    private var setup: SetupContainerController!

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

    /// `fm/grandline-live-gap-rootcause-scout`: named (rather than anonymous,
    /// like every other constraint activated in `loadView`) so
    /// `reassertBodyContainerWidthTie()` can check/repair them on every
    /// window resize - see that method's own doc comment for why a plain
    /// `equalTo:` tie alone was not enough to guarantee this stays correct.
    private var bodyLeadingConstraint: NSLayoutConstraint!
    private var bodyTrailingConstraint: NSLayoutConstraint!

    /// Fires on every window resize (registered globally, `object: nil`,
    /// matching `ToolsController.containerWidthMayHaveChanged`'s own
    /// convention - see AGENTS.md) so `bodyContainer` never settles at a
    /// width that no longer matches the window's current content area.
    private var windowResizeObserver: NSObjectProtocol?

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

    /// Fired whenever the Dictation page's shortcut recorder captures a new
    /// combo - the app delegate is what actually owns the live
    /// `DictationHotkey` instance, matching `onFontSizeStep`'s own
    /// forward-don't-own convention.
    var onDictationShortcutChanged: ((DictationShortcut) -> Void)? {
        get { dictation.onShortcutChanged }
        set { dictation.onShortcutChanged = newValue }
    }

    /// Phase 4 ("Knowledge and speed"): the topbar Search pill's click,
    /// forwarded to whoever owns the unified `⌘K` search palette (the app
    /// delegate, mirroring `onPresentHostEditor`'s own forward-don't-own
    /// convention) rather than presented here.
    var onSearchTapped: (() -> Void)?

    init(
        hostsPanel: HostsController, console: ConsoleController, settings: SettingsController,
        hostStore: HostStore, keyStore: SSHKeyStore, snippetStore: SnippetStore, shiftStore: ShiftStore,
        dictationStore: DictationStore, commandLibraryStore: CommandLibraryStore,
        makeHostConsole: @escaping () -> ConsoleController
    ) {
        self.hostsPanel = hostsPanel
        self.console = console
        self.settings = settings
        self.overview = FleetController()
        self.dictation = DictationController(store: dictationStore)
        // Phase 5 (cockpit-shift-power-features): `shiftStore` is now built
        // once by the app delegate and shared with the menu bar item, the
        // search palette, and quick capture - all of which need to read/
        // write the same tasks/follow-ups this page shows, not a second
        // independent store instance.
        self.shift = ShiftController(store: shiftStore, commandLibraryStore: commandLibraryStore)
        // GL-23: the same instance the Tasks page uses.
        self.logAnalyzer = LogAnalyzerController(commandLibrary: commandLibraryStore)
        self.bootstrap = BootstrapController(hostStore: hostStore, keyStore: keyStore, snippetStore: snippetStore, dictationStore: dictationStore)
        self.automation = AutomationController(hostStore: hostStore, keyStore: keyStore, snippetStore: snippetStore, dictationStore: dictationStore)
        self.makeHostConsole = makeHostConsole
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 1220, height: 720))
        view = root

        // GL-32: one place turns a chrome-text-scale change into the app-wide
        // repaint every page already knows how to do. See
        // `ThemeManager.reapplyCurrentTheme`'s own note on why this rides the
        // theme observer rather than adding a second fan-out of its own. The
        // token is discarded deliberately - this controller is the window's
        // root and lives for the process.
        chromeTextScaleObservation = ChromeTextScale.shared.observe { [weak self] _ in
            guard let self, self.isViewLoaded else { return }
            ThemeManager.shared.reapplyCurrentTheme()
            self.view.layoutSubtreeIfNeeded()
        }

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
        // Phase 4 ("Knowledge and speed") superseded Fix 4's original mapping
        // here (an in-terminal find stand-in, since there was no real global
        // search yet) - the topbar Search pill (and its `⌘K` badge) now opens
        // the real unified search palette, forwarded to the app delegate via
        // `onSearchTapped` (see that property's own doc comment) rather than
        // owned by this controller. Plain find-in-terminal is unaffected -
        // it's still reachable via the console toolbar's own magnifying-glass
        // icon (`ConsoleController.showFind`) and the Edit menu's `⌘F`.
        topBar.onSearchTapped = { [weak self] in self?.onSearchTapped?() }

        addChild(hostsPanel)
        addChild(console)
        addChild(overview)
        addChild(shift)
        addChild(review)
        addChild(logAnalyzer)
        addChild(tools)
        addChild(vault)
        addChild(dictation)
        addChild(docs)
        // The four Setup pages become children of `setup`, not of this
        // controller - `SetupContainerController.loadView` calls `addChild`
        // for each of them.
        setup = SetupContainerController(updates: updates, bootstrap: bootstrap,
                                         automation: automation, githubSync: githubSync)
        setup.onTabSelected = { [weak self] dest in
            // The tab row moved itself; only the rail highlight still needs to
            // follow. The top bar keeps saying "Setup" - the tab row directly
            // below it is what names the active sub-page, exactly as in the
            // prototype (`03-proposed-setup-tabs.png`), and as Hosts already
            // does for its own three tabs.
            self?.rail.setActive(dest)
        }
        addChild(setup)
        addChild(settings)

        for destinationView in [hostsPanel.view, console.view, overview.view, shift.view, review.view, logAnalyzer.view, tools.view, vault.view, dictation.view, docs.view, setup.view, settings.view] {
            embed(destinationView)
        }

        bodyLeadingConstraint = bodyContainer.leadingAnchor.constraint(equalTo: rail.view.trailingAnchor)
        bodyTrailingConstraint = bodyContainer.trailingAnchor.constraint(equalTo: root.trailingAnchor)

        NSLayoutConstraint.activate([
            rail.view.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            rail.view.topAnchor.constraint(equalTo: root.topAnchor),
            rail.view.bottomAnchor.constraint(equalTo: root.bottomAnchor),

            bodyLeadingConstraint,
            bodyTrailingConstraint,
            bodyContainer.topAnchor.constraint(equalTo: root.topAnchor),
            bodyContainer.bottomAnchor.constraint(equalTo: root.bottomAnchor),

            topBar.view.leadingAnchor.constraint(equalTo: bodyContainer.leadingAnchor),
            topBar.view.trailingAnchor.constraint(equalTo: bodyContainer.trailingAnchor),
            topBar.view.topAnchor.constraint(equalTo: bodyContainer.topAnchor),
            topBar.view.heightAnchor.constraint(equalToConstant: TopBarController.height),
        ])

        // `fm/grandline-live-gap-rootcause-scout`: a real, live-captured
        // instance of this app showed `bodyContainer` (and every destination
        // mounted inside it) frozen at a width matching the *screen's* width
        // minus the rail - 1428pt, i.e. `1512 - 84` - while the window's
        // real, current frame was only 1033pt wide. `root` (this window's
        // own `contentView`) tracked the real window width correctly the
        // whole time (contentView's frame is kept in sync with the window's
        // content rect unconditionally by the OS, independent of Auto
        // Layout), so the tie above (`bodyTrailingConstraint`, a required
        // `==` to `root.trailingAnchor`) was declared correctly - the bug is
        // that nothing re-asserts it live. `main.swift`'s launch sequence
        // resizes this same window twice before it's ever shown
        // (`setFrame(defaultWindowFrame(), display: false)`, screen-sized,
        // then `setFrameAutosaveName` silently restoring the captain's own
        // smaller saved frame on top of it) with `display: false` both
        // times, and neither `ToolsController`'s own grid nor this window
        // has any other resize-driven correctness check the way
        // `ToolsController.containerWidthMayHaveChanged`/`SettingsController`
        // already do for their own content (see AGENTS.md) - `bodyContainer`
        // was the one major structural container with *no* such defensive
        // re-derivation at all. `reassertBodyContainerWidthTie()` closes
        // that gap: called once here (covering the window's still-off-screen
        // launch-time resizes above) and on every subsequent
        // `NSWindow.didResizeNotification`, so a stale/never-relaid-out
        // frame - or, per AGENTS.md gotcha (13)'s own documented class of
        // required-constraint conflict, a tie that AppKit silently
        // deactivated after losing to some other required constraint deep in
        // a (possibly hidden - gotcha (11)) destination view - can't survive
        // past the very next resize.
        reassertBodyContainerWidthTie()
        windowResizeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let self, (note.object as? NSWindow) === self.view.window else { return }
            self.reassertBodyContainerWidthTie()
        }

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
        // fm/grandline-automation-pipeline: the automation pipeline's own
        // dotfiles step needs the exact same real Console-tab/completion
        // wiring as Bootstrap's - it runs the identical clone/rebuild command
        // (`DotfilesRunCommand`, shared by both pages).
        automation.onRunCommandTracked = { [weak self] label, command, completion in
            self?.runInConsole(label: label, command: command, completion: completion)
        }
        // cockpit-bootstrap-software: a `.notInstalled` row on the Updates
        // page no longer installs inline - it links to the Bootstrap page's
        // own Software checklist card instead (same catalog, same install
        // action, just relocated).
        updates.onNavigateToBootstrap = { [weak self] in self?.show(.bootstrap) }
        // fm/grandline-overview-drop-duplicate-pr-list: Overview's own
        // itemized "Ready to merge" list was removed as a duplicate of
        // `.review`'s - the stat tile that's left jumps straight there.
        overview.onNavigateToReview = { [weak self] in self?.show(.review) }
        // GL-31: Overview's unconfigured banner leads straight into the
        // Bootstrap stepper, which is where firstmate home is actually set.
        overview.onNavigateToSetup = { [weak self] in self?.show(.bootstrap) }
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
        // fm/grandline-devops-command-library-phase2: the Command Library's
        // "Send to Terminal" types straight into whichever console tab is
        // currently in front - not a new one-shot command tab (`runInConsole`
        // above), the exact same "type this into the active tab" behavior
        // Snippets' own "Run" already uses.
        shift.onSendCommandToTerminal = { [weak self] text in self?.console.sendCommandLibraryTextToActiveTab(text) }

        // `fm/grandline-log-analyzer-build`: the Log Analyzer forwards the
        // same two things Shift's Command Library already does - "run this
        // command" goes to whichever console tab is in front, and a runbook
        // or postmortem it just wrote opens in Docs. It owns neither.
        logAnalyzer.onSendCommandToTerminal = { [weak self] text in
            self?.console.sendCommandLibraryTextToActiveTab(text)
        }
        logAnalyzer.onOpenRunbook = { [weak self] id in self?.openDocsRunbook(id: id) }
        logAnalyzer.onOpenConsole = { [weak self] in self?.show(.console) }

        // fm/grandline-sidebar-badges: forward each page's own already-
        // computed "needs you" count straight to its rail icon - no new
        // signal invented here, just the counts these two pages already
        // render every time they refresh.
        // fm/grandline-notification-center: these two signals already
        // recompute on every Overview/Review refresh (page visit, manual
        // refresh, and the `refreshIfNeeded()` calls just below) - piggy-
        // backing on the existing count callbacks means no new detection
        // logic and no new poll for either signal.
        overview.onNeedsDecisionCountChanged = { [weak self] count in
            self?.rail.setBadgeCount(count, for: .overview)
            NotificationSources.setFleetDecisions(count: count) { self?.show(.overview) }
        }
        // GL-11/GL-30: the two failure signals (a background service failing
        // repeatedly, a save that did not reach disk) are raised from
        // background queues that know nothing about destinations, so they get
        // their navigation from here - the same forward-don't-own split every
        // other signal in `NotificationSources` uses. Set once; both entries
        // point at Settings, where the Health card lives.
        NotificationSources.navigateToHealth = { [weak self] in self?.show(.settings) }

        review.onOpenPRCountChanged = { [weak self] count in
            self?.rail.setBadgeCount(count, for: .review)
            NotificationSources.setPRReady(count: count) { self?.show(.review) }
        }
        // Trigger both pages' own refresh once at launch so the badges have
        // a real count before the captain ever visits Overview or Review -
        // every later update comes from those pages' existing refresh
        // triggers (page visit, manual refresh, a merge action), not a new
        // poll loop.
        overview.refreshIfNeeded()
        review.refreshIfNeeded()

        // GL-31: a machine with no firstmate home resolved lands on Setup, not
        // on a Console tab in front of an Overview that can only report
        // zeroes. `FirstmateHome.root` is resolved once at launch, so this is
        // a one-time decision and cannot flap.
        //
        // Deliberately only this one condition: the app is genuinely usable
        // with no saved hosts, no Shift data and no Vault password beyond the
        // lock screen's own, so none of those should redirect a captain who
        // knows where they were going.
        if FirstmateHome.homeOk() {
            show(.console)
        } else {
            AppLog.lifecycle.info("firstmate home not configured - opening Setup instead of the console")
            show(.bootstrap)
        }

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
        // fm/grandline-vault-bootstrap-fix: "Install Automic Vault" on the
        // `.avUnavailable` state - a plain Homebrew-cask install
        // (`VaultSource.updateInstall()`, the same mechanism the
        // Updates/Vault pages already use for this catalog entry), so it
        // needs no prior unlock and is safe to trigger straight from here.
        lockScreen.onInstallAutomicVault = { completion in
            DispatchQueue.global(qos: .userInitiated).async {
                let outcome = VaultSource.updateInstall()
                DispatchQueue.main.async {
                    let message = outcome.ok
                        ? "Installed. Set a password with \u{201c}av save GRANDLINE_APP_PASSWORD\u{201d}, then relaunch Manjesh Grand Line."
                        : "Install failed: \(outcome.detail)"
                    completion(outcome.ok, message)
                }
            }
        }
    }

    // MARK: App-level password lock (fm/grandline-app-lock)

    /// Shows the lock overlay for `reason`, re-checking whether
    /// `GRANDLINE_APP_PASSWORD` is actually configured in Automic Vault
    /// (never cached - the captain could set it between one lock and the
    /// next) before deciding which of the lock screen's two states to show.
    func showLock(reason: AppLockReason) {
        lockScreen.view.isHidden = false
        // GL-09: the overlay only covers this window. Everything that lives
        // outside it - the menu-bar status item, ⌥Space quick capture, the
        // dictation hotkey, an already-open Host Editor - consults
        // `AppLockGate`, and this is the one place it is set. Set *before*
        // anything else in this method, so there is no window in which the
        // overlay is up but a global hotkey still fires.
        AppLockGate.shared.setLocked(true)
        onLockStateChanged?(true)
        // fm/grandline-lock-and-rail-fixes: the rail's own sailboat mark goes
        // back to inert/static the instant the app locks, regardless of
        // whether it was mid-bob.
        rail.setUnlocked(false)
        // Optimistic default so the overlay never shows a blank subtitle for
        // the fraction of a second the background `av list` check takes -
        // corrected below once that check actually resolves.
        let optimisticSubtitle = reason == .sessionExpired
            ? "Your session expired - please log in again."
            : "Manjesh Grand Line is locked."
        lockScreen.apply(.locked(subtitle: optimisticSubtitle))
        lockScreen.focusPasswordField()
        // fm/grandline-vault-bootstrap-fix: proactively try to start Automic
        // Vault's own background approval service before the very first
        // check - avoids ever hitting the "service not running" state below
        // on an ordinary launch where the captain just hasn't opened the
        // menu-bar app yet (e.g. right after a reboot). Fire-and-forget on
        // the same background queue as the check that follows.
        DispatchQueue.global(qos: .userInitiated).async {
            VaultSource.ensureServiceRunning()
        }
        checkAppPasswordAvailability(reason: reason)
    }

    /// Re-checks `VaultSource.checkAppPasswordConfigured()` and updates the
    /// lock screen's content state. When the service genuinely isn't running
    /// yet (`.serviceNotRunning`), retries on a short timer rather than
    /// immediately settling on a message - `ensureServiceRunning()` above
    /// usually resolves this before the first attempt even lands; this is
    /// the fallback for a slower start (e.g. right after a reboot).
    private func checkAppPasswordAvailability(reason: AppLockReason) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let availability = VaultSource.checkAppPasswordConfigured()
            DispatchQueue.main.async {
                guard let self else { return }
                self.applyPasswordAvailability(availability, reason: reason)
            }
        }
    }

    private func applyPasswordAvailability(_ availability: VaultSource.AppPasswordAvailability, reason: AppLockReason) {
        switch availability {
        case .configured:
            let subtitle = reason == .sessionExpired
                ? "Your session expired - please log in again."
                : "Manjesh Grand Line is locked."
            lockScreen.apply(.locked(subtitle: subtitle))
            lockScreen.focusPasswordField()
        case .notConfigured:
            lockScreen.apply(.noPasswordConfigured)
            lockScreen.focusPasswordField()
        case .avUnavailable:
            lockScreen.apply(.avUnavailable)
        case .serviceNotRunning:
            lockScreen.apply(.serviceNotRunning)
            scheduleAppPasswordAvailabilityRetry(reason: reason)
        case .transientFailure:
            // Any `av list` failure/timeout that isn't the specific
            // `.serviceNotRunning` marker text (fm/grandline-vault-wake-
            // recheck-fix) - live-confirmed that a suspended/unresponsive
            // approval helper (e.g. right after a long sleep/wake) can make
            // `av list` fail or hang in a way that previously fell through
            // to a hard, misleading `.avUnavailable` state with no retry at
            // all, even though `av` is genuinely installed and the
            // password secret genuinely exists. Retried on the same cadence
            // as `.serviceNotRunning` below.
            lockScreen.apply(.transientFailure)
            scheduleAppPasswordAvailabilityRetry(reason: reason)
        }
    }

    /// Retry every 1.5s indefinitely while the lock screen is up - there's
    /// nothing else useful to show, and the retry itself is a cheap
    /// subprocess call, not a real cost. Shared by `.serviceNotRunning` and
    /// `.transientFailure` above.
    private func scheduleAppPasswordAvailabilityRetry(reason: AppLockReason) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self, !self.lockScreen.view.isHidden else { return }
            self.checkAppPasswordAvailability(reason: reason)
        }
    }

    private func hideLock() {
        lockScreen.view.isHidden = true
        AppLockGate.shared.setLocked(false)
        onLockStateChanged?(false)
        // fm/grandline-lock-and-rail-fixes: bold + bob the rail's own
        // sailboat mark now that the captain is actually in the app - a
        // small "welcome back, the ship is sailing" touch.
        rail.setUnlocked(true)
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

    /// `fm/grandline-live-gap-rootcause-scout`: re-derives `bodyContainer`'s
    /// width from `root`'s (this window's `contentView`'s) actual current
    /// bounds, on demand - called once at launch (from `loadView`, before the
    /// window is ever shown) and again on every `NSWindow.didResizeNotification`
    /// for this window. Two independent, cheap safeguards, not one:
    ///   1. Reactivate `bodyLeadingConstraint`/`bodyTrailingConstraint` if
    ///      either was ever deactivated - required constraints that lose a
    ///      genuine conflict against some other required constraint
    ///      elsewhere (possibly deep in a hidden destination view - see
    ///      AGENTS.md gotcha (11)) get silently disabled by AppKit and do
    ///      not reactivate themselves once the conflict is gone.
    ///   2. Force a real `layoutSubtreeIfNeeded()` - a resize that happens
    ///      with `display: false` (as `main.swift`'s launch sequence does,
    ///      twice, before the window is ever shown) only marks the affected
    ///      views `needsLayout`; it does not itself flush that into an
    ///      updated `.frame` the way a direct `.frame` read after this call
    ///      does.
    ///
    /// GL-20: step 2 used to run unconditionally on every resize *frame*, which
    /// resolves every mounted destination's whole view tree plus every per-host
    /// console - defeating the visibility gates those child controllers each
    /// added for exactly this reason (see `ToolsController`'s and
    /// `SettingsController`'s own measured regressions).
    ///
    /// The gate is a cheap staleness check rather than a debounce. `root` is
    /// this window's `contentView`, whose frame the OS keeps in sync with the
    /// window unconditionally (confirmed live by the scout task), so comparing
    /// `bodyContainer`'s *current* frame against what the constraints say it
    /// should be costs two frame reads and no layout. Only when those disagree
    /// - or when a constraint was found deactivated - does the expensive
    /// resolve run. A debounce was tried first and is wrong here: the whole
    /// point of #231's fix is that the frame is correct *immediately* after a
    /// resize, and `AppShellBodyWidthSelfTest` asserts exactly that
    /// synchronously.
    private func reassertBodyContainerWidthTie() {
        var needsLayout = false
        if let bodyLeadingConstraint, !bodyLeadingConstraint.isActive {
            bodyLeadingConstraint.isActive = true
            needsLayout = true
            AppLog.ui.error("bodyContainer leading tie had been deactivated by AppKit - reactivated")
        }
        if let bodyTrailingConstraint, !bodyTrailingConstraint.isActive {
            bodyTrailingConstraint.isActive = true
            needsLayout = true
            AppLog.ui.error("bodyContainer trailing tie had been deactivated by AppKit - reactivated")
        }
        if !needsLayout, bodyContainerWidthIsStale() {
            needsLayout = true
        }
        guard needsLayout else { return }
        view.layoutSubtreeIfNeeded()
    }

    /// `bodyContainer` spans from the rail's trailing edge to `root`'s trailing
    /// edge, so its correct width is exactly `root.bounds.width - rail width`.
    /// A half-point tolerance covers the non-integral widths AppKit produces on
    /// a Retina display.
    private func bodyContainerWidthIsStale() -> Bool {
        let expected = view.bounds.width - IconRailController.width
        guard expected > 0 else { return false }
        return abs(bodyContainer.frame.width - expected) > 0.5
    }

    deinit {
        if let windowResizeObserver {
            NotificationCenter.default.removeObserver(windowResizeObserver)
        }
    }

    // MARK: Test hooks (`fm/grandline-live-gap-rootcause-scout`)

    /// `AppShellBodyWidthSelfTest` reads this rather than `bodyContainer`
    /// directly, since that property stays `private` - everything else in
    /// this controller only ever needs to add/remove/toggle a destination
    /// view, never measure the container itself.
    var bodyContainerFrameForTests: NSRect { bodyContainer.frame }

    /// Simulates the exact failure this task's scout report captured live:
    /// AppKit (for whatever internal reason - a transient required-
    /// constraint conflict elsewhere, or simply a resize that happened with
    /// no layout pass ever following it) leaves the width tie inactive.
    /// `reassertBodyContainerWidthTie()` is what's supposed to notice and
    /// repair this on the next resize; this hook exists so a test can force
    /// that exact starting condition without needing to actually reproduce
    /// the underlying AppKit conflict (which requires runtime conditions
    /// this scout task could not otherwise pin down - see
    /// `data/grandline-live-gap-rootcause-scout/report.md`).
    func debugBreakBodyWidthTieForTests() {
        bodyLeadingConstraint.isActive = false
        bodyTrailingConstraint.isActive = false
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
        case .logAnalyzer:
            logAnalyzer.view.isHidden = false
            topBar.setTitle("Log Analyzer")
        case .tools:
            tools.view.isHidden = false
            topBar.setTitle("Tools")
        case .vault:
            vault.view.isHidden = false
            topBar.setTitle("Vault")
        case .dictation:
            dictation.view.isHidden = false
            topBar.setTitle("Dictation")
        case .docs:
            docs.view.isHidden = false
            topBar.setTitle("Docs")
        case .updates, .bootstrap, .automation, .githubSync:
            // One destination view with four tabs - the rail flyout still
            // names a specific one, which just selects that tab.
            setup.view.isHidden = false
            if let tab = SetupTab(destination: dest) { setup.select(tab: tab) }
            // "Setup", not the sub-page's own name: the tab row below names
            // the sub-page, and the rail row the captain came from says
            // "Setup" too.
            topBar.setTitle("Setup")
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

        // fm/grandline-notification-center: reassigned on every call (not
        // just the first) so a renamed host label is always current in the
        // notification's own subtext - cheap, and `host.label` is only read
        // at the moment a reply actually lands, not cached earlier than
        // that either.
        let hostID = host.id
        let hostLabel = host.label
        controller.onSRELeadReplyWhileBackground = { [weak self, weak controller] tab in
            guard let self else { return }
            NotificationSources.setSRELeadReply(tabID: tab.id, tabName: tab.name, hostLabel: hostLabel) { [weak self, weak controller] in
                guard let self, let controller else { return }
                self.hideAllDestinations()
                controller.view.isHidden = false
                self.topBar.setTitle(hostLabel)
                self.activeHostID = hostID
                self.rail.setActiveHost(hostID)
                controller.selectAndFocusTab(id: tab.id)
            }
        }

        // `fm/grandline-log-analyzer-build`: reassigned on every call for
        // the same reason `onSRELeadReplyWhileBackground` above is - a
        // renamed host should show its current label on the imported
        // evidence, and the closure only reads it when a capture actually
        // happens.
        controller.onAnalyzeLogs = { [weak self] capture, tabName in
            guard let self else { return }
            self.openLogAnalyzer(with: capture, hostLabel: "\(hostLabel) · \(tabName)")
        }

        hideAllDestinations()
        controller.view.isHidden = false
        topBar.setTitle(host.label)
        activeHostID = host.id
        rail.setActiveHost(host.id)
        controller.focusCurrentTab()
        // fm/grandline-notification-center: this page coming back on screen
        // (via the rail icon or the Hosts list, not necessarily through a
        // notification click) also counts as "the captain is looking at the
        // currently-selected tab now" - clears its own SRE Lead unread
        // entry, if any, the same as an in-page tab switch already does.
        controller.markCurrentTabAsRead()
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
        logAnalyzer.view.isHidden = true
        tools.view.isHidden = true
        vault.view.isHidden = true
        dictation.view.isHidden = true
        docs.view.isHidden = true
        setup.view.isHidden = true
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

    /// Wired by the app delegate: the Snippets tab's "Run" sends a snippet to
    /// the console's active tab. Forwarded rather than owned, matching
    /// `onPresentHostEditor` - this controller knows nothing about snippets.
    var onRunSnippet: ((Snippet) -> Void)? {
        get { hostsPanel.onRunSnippet }
        set { hostsPanel.onRunSnippet = newValue }
    }

    /// The Edit menu's "Find in Terminal" (no longer ⌘K as of phase 4 - see
    /// main.swift's Edit menu comment; ⌘K now opens the unified search
    /// palette instead): invoke the exact same find action the console
    /// toolbar's magnifying-glass icon uses, on whichever console is actually
    /// on screen. Fix 1: if a host's dedicated page is showing, find there
    /// rather than yanking the captain over to the unrelated shared
    /// Firstmate console just because that's this method's historical
    /// default - otherwise this action would silently navigate away from the
    /// session being read and search the wrong terminal. With no host page
    /// active, the original behaviour holds: bring Console forward (so the
    /// find bar it triggers is visible) first.
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
        hostsPanel.select(tab: .hosts)
    }

    /// The Keys menu's "Manage Keys…" (⌘⇧K). Phase 5 of the full-app UI audit
    /// folded the SSH Keys window into the Hosts destination as a tab, so
    /// this now selects that destination and that tab rather than opening a
    /// second window.
    @objc func selectKeys() {
        show(.hosts)
        hostsPanel.select(tab: .keys)
    }

    /// The Snippets menu's "Manage Snippets…" (⌘⌥P) - same shape as
    /// `selectKeys`.
    @objc func selectSnippets() {
        show(.hosts)
        hostsPanel.select(tab: .snippets)
    }

    /// The Keys menu's "New Key…" (⌘⇧N): reveal the Keys tab and open the key
    /// editor sheet on it, regardless of which destination was showing.
    @objc func newKeyFromMenu() {
        show(.hosts)
        hostsPanel.newKey()
    }

    /// The Snippets menu's "New Snippet…" (⌘⌥N) - same shape.
    @objc func newSnippetFromMenu() {
        show(.hosts)
        hostsPanel.newSnippet()
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

    // MARK: Unified search navigation (phase 4, "Knowledge and speed")

    /// The `⌘K` unified search palette's own entry point for a Runbook/
    /// Postmortem result - switches to `.docs` first, exactly like every
    /// other `open*(id:)` wrapper above, so the item has somewhere to open
    /// into.
    func openDocsRunbook(id: String) {
        show(.docs)
        docs.openRunbook(id: id)
    }

    func openDocsPostmortem(id: String) {
        show(.docs)
        docs.openPostmortem(id: id)
    }

    // MARK: Log Analyzer (`fm/grandline-log-analyzer-build`)

    /// ⌘⇧L / the Log Analyzer menu's "Open Log Analyzer" - switches to the
    /// destination and focuses its input so a paste lands immediately (spec
    /// §24's own success-criteria flow: ⌘⇧L → paste → ⌘↵).
    @objc func showLogAnalyzer() {
        show(.logAnalyzer)
        logAnalyzer.focusForPaste()
    }

    /// The clipboard quick action (spec §2).
    @objc func analyzeClipboardInLogAnalyzer() {
        show(.logAnalyzer)
        logAnalyzer.analyzeClipboard()
    }

    /// Spec §2's terminal bridge. Called from the app delegate, which owns
    /// the host consoles' `onAnalyzeLogs` closure - the capture decision
    /// itself is made in `ConsoleController` (which has the tab, its block
    /// tracker and its selection) via `LogTerminalCaptureBuilder`, so this
    /// only routes an already-built capture to the page.
    func openLogAnalyzer(with capture: LogTerminalCapture, hostLabel: String) {
        show(.logAnalyzer)
        logAnalyzer.importTerminalCapture(capture, hostLabel: hostLabel)
    }

    /// The remaining spec §24 shortcuts, all routed through the destination
    /// so they behave identically whether they came from the menu or the
    /// page's own buttons.
    @objc func logAnalyzerCopyAnalysis() { showThenRun { $0.menuCopyAnalysis() } }
    @objc func logAnalyzerSendToTerminal() { showThenRun { $0.menuSendToTerminal() } }
    @objc func logAnalyzerInvestigateFurther() { showThenRun { $0.menuInvestigateFurther() } }
    @objc func logAnalyzerCreateRCA() { showThenRun { $0.menuCreateRCA() } }

    private func showThenRun(_ body: (LogAnalyzerController) -> Void) {
        show(.logAnalyzer)
        body(logAnalyzer)
    }

    /// Fix 5: a host save closes its own (separate) editor window
    /// immediately, so the confirmation has to live somewhere that's still
    /// around afterward - the main window, regardless of which destination
    /// happens to be showing.
    func showToast(_ message: String) {
        Toast.show(in: view, message: message)
    }

    /// fm/grandline-dictation-mvp: forwards the shared `DictationEngine`'s
    /// live state (recording/transcribing/back to a real permission-derived
    /// status) to the Dictation page, so it reflects reality in real time
    /// while visible rather than only on each `viewWillAppear`. A no-op if
    /// the page hasn't been visited yet - `DictationController.setEngineStatus`
    /// itself guards on `isViewLoaded`.
    func setDictationEngineStatus(_ status: DictationStatus) {
        dictation.setEngineStatus(status)
    }

    /// Fix 1: mirrors what `AppDelegate.applicationWillTerminate` already
    /// does for the shared Firstmate `console` - tear down every host
    /// page's mirrors and materialized keys on quit, not just the
    /// destination that happened to be visible.
    func shutdownAllHostConsoles() {
        for controller in hostConsoles.values { controller.shutdown() }
    }
}
