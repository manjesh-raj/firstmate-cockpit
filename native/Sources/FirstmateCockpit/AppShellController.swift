// Firstmate Cockpit - native macOS app.
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
    private let review = ReviewController()

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

    init(
        hostsPanel: HostsSidebarController, console: ConsoleController, settings: SettingsController,
        makeHostConsole: @escaping () -> ConsoleController
    ) {
        self.hostsPanel = hostsPanel
        self.console = console
        self.settings = settings
        self.overview = FleetController()
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
        addChild(review)
        addChild(settings)

        for destinationView in [hostsPanel.view, console.view, overview.view, review.view, settings.view] {
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
        case .hosts:
            hostsPanel.view.isHidden = false
            topBar.setTitle("Hosts")
        case .console:
            console.view.isHidden = false
            topBar.setTitle("Console")
        case .review:
            review.view.isHidden = false
            topBar.setTitle("Review")
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
            keyID: host.keyID, startupSnippetID: host.startupSnippetID
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
        review.view.isHidden = true
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
