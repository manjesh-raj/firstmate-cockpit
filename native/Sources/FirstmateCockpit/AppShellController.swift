// Firstmate Cockpit - native macOS app.
//
// The window's root content view controller for the nav-redesign task: a
// fixed `IconRailController` on the left, and to its right a `TopBarController`
// (always visible) above a body area that swaps between destinations:
//
//   - .home / .console both show the same nested hosts-panel/console split
//     (`ConsoleController` and its running tabs are never torn down when you
//     navigate away - only hidden), just with the hosts panel collapsed for
//     Home and expanded for Console (item 2: "opens... defaults to open when
//     the Console icon is active").
//   - .overview / .review show a `PlaceholderViewController` (item 1: these
//     have no native content source yet).
//   - .settings shows `SettingsController` directly, in the body area rather
//     than a separate floating window - the rail's "destination" model
//     (item 5), matching how the web app's Settings is a `view`, not a window.
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
    private let overview = PlaceholderViewController(
        symbol: "square.grid.2x2",
        title: "Overview",
        subtitle: "A fleet-wide overview lives in the web cockpit today. This destination is reserved for when that view lands natively."
    )
    private let review = PlaceholderViewController(
        symbol: "arrow.triangle.branch",
        title: "Review",
        subtitle: "Pull-request review lives in the web cockpit today. This destination is reserved for when that view lands natively."
    )

    private var consoleSplit: NSSplitViewController!
    private var hostsSplitItem: NSSplitViewItem!

    /// Add/Edit Host, requested from the Hosts panel - forwarded to whoever
    /// owns the host store (the app delegate), since this controller only
    /// arranges views and knows nothing about persistence.
    var onPresentHostEditor: ((Host?) -> Void)?

    init(hostsPanel: HostsSidebarController, console: ConsoleController, settings: SettingsController) {
        self.hostsPanel = hostsPanel
        self.console = console
        self.settings = settings
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
        topBar.onSearchTapped = { [weak self] in self?.revealHostsQuickConnect() }

        consoleSplit = NSSplitViewController()
        let hostsItem = NSSplitViewItem(sidebarWithViewController: hostsPanel)
        // Termius-proportioned panel (PR #14's Fix 1 width, reused here): wide
        // enough for label + subtitle + icon, narrow enough not to crowd the
        // console.
        hostsItem.minimumThickness = 220
        hostsItem.maximumThickness = 260
        hostsItem.canCollapse = true
        hostsItem.holdingPriority = .defaultLow
        hostsSplitItem = hostsItem
        consoleSplit.addSplitViewItem(hostsItem)
        consoleSplit.addSplitViewItem(NSSplitViewItem(viewController: console))
        addChild(consoleSplit)

        addChild(overview)
        addChild(review)
        addChild(settings)

        for destinationView in [consoleSplit.view, overview.view, review.view, settings.view] {
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

    /// Called once after the window is on screen, to pin the nested
    /// hosts/console divider - mirrors PR #14's explicit
    /// `setPosition(240, ofDividerAt: 0)` fix so a fresh launch never shows
    /// whatever width the sidebar's view happened to be created with.
    func pinInitialDividerPosition() {
        consoleSplit.splitView.setPosition(240, ofDividerAt: 0)
    }

    // MARK: Destination switching

    private func show(_ dest: RailDestination) {
        consoleSplit.view.isHidden = true
        overview.view.isHidden = true
        review.view.isHidden = true
        settings.view.isHidden = true

        switch dest {
        case .home:
            consoleSplit.view.isHidden = false
            hostsSplitItem.isCollapsed = true
            topBar.setTitle("Home")
        case .console:
            consoleSplit.view.isHidden = false
            hostsSplitItem.isCollapsed = false
            topBar.setTitle("Console")
        case .overview:
            overview.view.isHidden = false
            topBar.setTitle("Overview")
        case .review:
            review.view.isHidden = false
            topBar.setTitle("Review")
        case .settings:
            settings.view.isHidden = false
            topBar.setTitle("Settings")
        }
        rail.setActive(dest)
    }

    /// The topbar Search pill / ⌘K (Hosts menu "Quick Connect"): make sure
    /// the panel that owns the quick-connect field is actually on screen
    /// before focusing it, regardless of which destination was active.
    @objc func revealHostsQuickConnect() {
        show(.console)
        hostsPanel.focusQuickConnect()
    }

    /// The App menu's "Settings…" (⌘,): select the Settings rail destination
    /// rather than opening a separate window.
    @objc func selectSettings() {
        show(.settings)
    }

    /// "Toggle Hosts Sidebar" (⌘⌃S): only meaningful while the Console
    /// destination is showing the split, but harmless to invoke otherwise.
    @objc func toggleHostsSidebar(_ sender: Any?) {
        consoleSplit.toggleSidebar(sender)
    }
}
