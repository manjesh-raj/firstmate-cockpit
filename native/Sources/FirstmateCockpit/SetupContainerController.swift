// Manjesh Grand Line - native macOS app.
//
// The Setup destination's in-page tab switcher (fm/grandline-design-fidelity-
// fixes).
//
// **Why this exists.** `.updates`, `.bootstrap`, `.automation` and
// `.githubSync` are four real `RailDestination` cases that share one rail row
// - the Setup flyout (`IconRailController.showSetupFlyout`). Once the captain
// picked one, there was no way to reach the other three without going back to
// the rail and reopening the flyout: four sibling pages of one concern with no
// sibling navigation. The audit prototype shows them as a single Setup
// destination with a `HelmSegmentedTabs` capsule across the top
// (`03-proposed-setup-tabs.png`), which is exactly the shape Hosts already
// uses for its own three tabs (Phase 5).
//
// **What it does NOT change.** Each of the four pages is the same controller
// instance it always was - constructed by `AppShellController` (which still
// owns every one of their callbacks: `onRunCommand`, `onRunCommandTracked`,
// `onNavigateToBootstrap`, …) and handed here only to be parented. This
// container adds a tab row and re-parents; it does not know what any of the
// four pages do, and none of them knows it exists. `show(.bootstrap)` etc.
// still work exactly as before - `AppShellController.show` now routes them
// through `select(tab:)` instead of unhiding four separate body children.
//
// Built from the shared components, not hand-rolled: `HelmSegmentedTabs` for
// the tab row (caller-owned string ids, as everywhere else), a plain
// layer-backed theme-filled root (AGENTS.md gotcha #8 - never an
// `NSVisualEffectView` for a full-size destination), and the four pages'
// views pinned edge to edge below the tabs and toggled with `isHidden`, which
// is this app's standing "hide, never rebuild" convention for a permanently
// mounted destination.

import AppKit

/// Which Setup sub-page is showing. Raw values are the ids `HelmSegmentedTabs`
/// deals in; the mapping to `RailDestination` is one switch, in one place, so
/// the rail flyout and this tab row can never disagree about what "Bootstrap"
/// means.
enum SetupTab: String, CaseIterable {
    case updates, bootstrap, automation, githubSync

    var title: String {
        switch self {
        case .updates: return "Updates"
        case .bootstrap: return "Bootstrap"
        case .automation: return "Automation"
        case .githubSync: return "GitHub Sync"
        }
    }

    var destination: RailDestination {
        switch self {
        case .updates: return .updates
        case .bootstrap: return .bootstrap
        case .automation: return .automation
        case .githubSync: return .githubSync
        }
    }

    init?(destination: RailDestination) {
        switch destination {
        case .updates: self = .updates
        case .bootstrap: self = .bootstrap
        case .automation: self = .automation
        case .githubSync: self = .githubSync
        default: return nil
        }
    }
}

final class SetupContainerController: NSViewController {

    let updates: UpdatesController
    let bootstrap: BootstrapController
    let automation: AutomationController
    let githubSync: GitHubSyncController

    private var tabs: HelmSegmentedTabs!
    private var activeTab: SetupTab = .updates

    /// Fired whenever the captain switches tabs from the tab row itself, so
    /// the shell can keep the rail highlight and the top-bar title in sync -
    /// the same signal `show(_:)` would have carried had the switch come from
    /// the rail's flyout instead. Forwarding rather than owning, matching
    /// `AppShellController`'s own convention for everything it doesn't own.
    var onTabSelected: ((RailDestination) -> Void)?

    init(updates: UpdatesController,
         bootstrap: BootstrapController,
         automation: AutomationController,
         githubSync: GitHubSyncController) {
        self.updates = updates
        self.bootstrap = bootstrap
        self.automation = automation
        self.githubSync = githubSync
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private var pageViews: [SetupTab: NSView] {
        [.updates: updates.view, .bootstrap: bootstrap.view,
         .automation: automation.view, .githubSync: githubSync.view]
    }

    override func loadView() {
        // A plain, layer-backed, theme-filled root - never an
        // `NSVisualEffectView` (AGENTS.md gotcha #8), exactly like every other
        // full-size destination.
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 1136, height: 660))
        root.wantsLayer = true
        view = root

        tabs = HelmSegmentedTabs(items: SetupTab.allCases.map { .init(id: $0.rawValue, title: $0.title) },
                                 selected: activeTab.rawValue)
        tabs.onSelect = { [weak self] id in
            guard let tab = SetupTab(rawValue: id) else { return }
            self?.select(tab: tab, moveTabControl: false)
            self?.onTabSelected?(tab.destination)
        }
        root.addSubview(tabs)
        NSLayoutConstraint.activate([
            tabs.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: HelmMetrics.pageGutter),
            tabs.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -HelmMetrics.pageGutter),
            tabs.topAnchor.constraint(equalTo: root.topAnchor, constant: HelmMetrics.s4),
        ])

        // Each page keeps its own internal gutters and scroll view; this only
        // parents it and reserves the tab row's height above it.
        for (tab, page) in pageViews {
            addChild(childController(for: tab))
            page.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(page)
            NSLayoutConstraint.activate([
                page.leadingAnchor.constraint(equalTo: root.leadingAnchor),
                page.trailingAnchor.constraint(equalTo: root.trailingAnchor),
                page.topAnchor.constraint(equalTo: tabs.bottomAnchor, constant: HelmMetrics.s3),
                page.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            ])
        }

        ThemeManager.shared.observe { [weak self] theme in self?.applyTheme(theme) }
        select(tab: activeTab, moveTabControl: true)
        applyTheme(ThemeManager.shared.theme)
    }

    private func childController(for tab: SetupTab) -> NSViewController {
        switch tab {
        case .updates: return updates
        case .bootstrap: return bootstrap
        case .automation: return automation
        case .githubSync: return githubSync
        }
    }

    /// Switch tabs. `moveTabControl` is false when the switch came *from* the
    /// tab control itself (it has already moved its own pill) - the same
    /// convention `HostsController.select(tab:)` uses.
    func select(tab: SetupTab, moveTabControl: Bool = true) {
        activeTab = tab
        if moveTabControl { tabs?.select(tab.rawValue) }
        for (candidate, page) in pageViews {
            page.isHidden = candidate != tab
        }
    }

    var currentTab: SetupTab { activeTab }

    private func applyTheme(_ theme: HelmTheme) {
        view.layer?.backgroundColor = HelmTheme.nsColor(theme.backgroundHex).cgColor
        tabs?.applyTheme(theme)
    }
}
