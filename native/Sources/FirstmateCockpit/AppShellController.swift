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
//   - .review shows a `PlaceholderViewController` (no native content source
//     yet).
//   - .settings shows `SettingsController` directly, in the body area rather
//     than a separate floating window, matching how the web app's Settings
//     is a `view`, not a window.
//
// All five destination views are added as children up front and just have
// their `isHidden` flipped - never rebuilt - so nothing here can drop a
// running terminal session or its tabs.

import AppKit

final class AppShellController: NSViewController {

    let rail = IconRailController()
    let topBar = TopBarController()
    private let hostsPanel: HostsSidebarController
    private let console: ConsoleController
    private let settings: SettingsController
    private let overview: FleetController
    private let review = PlaceholderViewController(
        symbol: "arrow.triangle.branch",
        title: "Review",
        subtitle: "Pull-request review lives in the web cockpit today. This destination is reserved for when that view lands natively."
    )

    /// Add/Edit Host, requested from the Hosts panel - forwarded to whoever
    /// owns the host store (the app delegate), since this controller only
    /// arranges views and knows nothing about persistence.
    var onPresentHostEditor: ((Host?) -> Void)?

    init(hostsPanel: HostsSidebarController, console: ConsoleController, settings: SettingsController) {
        self.hostsPanel = hostsPanel
        self.console = console
        self.settings = settings
        self.overview = FleetController()
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

        let bodyContainer = NSView()
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
            destinationView.translatesAutoresizingMaskIntoConstraints = false
            bodyContainer.addSubview(destinationView)
            NSLayoutConstraint.activate([
                destinationView.leadingAnchor.constraint(equalTo: bodyContainer.leadingAnchor),
                destinationView.trailingAnchor.constraint(equalTo: bodyContainer.trailingAnchor),
                destinationView.topAnchor.constraint(equalTo: topBar.view.bottomAnchor),
                destinationView.bottomAnchor.constraint(equalTo: bodyContainer.bottomAnchor),
            ])
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

    // MARK: Destination switching

    /// Internal (not `private`): the app delegate also calls this directly
    /// after connecting a host, so the new tab is visible immediately
    /// instead of landing silently in the background Console destination.
    func show(_ dest: RailDestination) {
        hostsPanel.view.isHidden = true
        console.view.isHidden = true
        overview.view.isHidden = true
        review.view.isHidden = true
        settings.view.isHidden = true

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

    /// The Hosts menu's "Quick Connect" (⌘K): reveal the Hosts destination
    /// and focus its quick-connect field, regardless of which destination
    /// was active. No longer shared with the topbar Search control (Fix 4).
    @objc func revealHostsQuickConnect() {
        show(.hosts)
        hostsPanel.focusQuickConnect()
    }

    /// The topbar Search pill / its own ⌘K: bring Console forward (so the
    /// find bar it triggers is actually visible) and invoke the exact same
    /// find action the console toolbar's magnifying-glass icon uses.
    @objc func activateConsoleFind() {
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
}
