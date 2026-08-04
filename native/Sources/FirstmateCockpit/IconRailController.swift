// Firstmate Cockpit - native macOS app.
//
// The primary nav rail (nav-redesign task, item 1): a narrow, fixed-width
// icon-only column, mirroring the web app's icon rail
// (`backend/static/index.html`, `.rail`/`.nav` - roughly line 706 onward).
// Never resizes and is always visible; the active destination gets a tinted
// background exactly like the web rail's `.nav.on`.
//
// This view knows nothing about hosts, the console, or settings - it only
// reports which destination was clicked (`onSelect`) and reflects whichever
// destination `select(_:)` says is active. `AppShellController` owns the
// mapping from destination to actual content.

import AppKit

/// The rail's five destinations. Switching order (captain correction,
/// theme-audit task): Overview, Console, Hosts, then Review, then Settings -
/// overriding fixes4 Fix 2's Console/Hosts-first ordering. Note that this is
/// the *switching* order only - Settings' *visual* position in the rail is
/// moved to after the dynamic per-host icon block (see `loadView`), directly
/// above the avatar.
enum RailDestination: CaseIterable {
    case overview, console, hosts, review, settings

    var symbol: String {
        switch self {
        case .overview: return "square.grid.2x2"
        case .hosts: return "server.rack"
        case .console: return "terminal"
        case .review: return "arrow.triangle.branch"
        case .settings: return "gearshape"
        }
    }

    var title: String {
        switch self {
        case .overview: return "Overview"
        case .hosts: return "Hosts"
        case .console: return "Console"
        case .review: return "Review"
        case .settings: return "Settings"
        }
    }
}

final class IconRailController: NSViewController {

    /// Fixed rail width - the web rail is 66px; this app's rail runs 60pt,
    /// within the 56-64pt range asked for.
    static let width: CGFloat = 60

    var onSelect: ((RailDestination) -> Void)?

    /// Fix 3 (fixes4): clicking a saved host's pinned rail icon connects to
    /// it directly, same as the Hosts list's own Connect action.
    var onConnectHost: ((Host) -> Void)?

    private(set) var active: RailDestination = .console

    /// Fix 1 (dedicated host pages): set instead of `active` while a host's
    /// own page is showing, so `restyle` can un-highlight every fixed
    /// destination and highlight that host's icon instead. `nil` whenever a
    /// fixed `RailDestination` is current.
    private(set) var activeHostID: UUID?
    private var buttons: [RailDestination: NSButton] = [:]
    private let avatar = NSButton()

    /// The saved hosts currently pinned to the rail, and the vertical stack
    /// they render into - below the fixed destinations, above the avatar.
    /// Rebuilt wholesale on every `setHosts` call (via `HostStore.observe`),
    /// which keeps this trivially correct on add/rename/delete at the cost
    /// of a full rebuild - fine for the handful of hosts a rail like this is
    /// meant to hold.
    private var hosts: [Host] = []
    private let hostsStack = NSStackView()
    private var hostButtons: [UUID: NSButton] = [:]

    /// Theme-audit task: this used to be `NSVisualEffectView(.sidebar,
    /// .behindWindow)` - the exact material/blending pair `HostsSidebarController`
    /// already diagnosed and ripped out (its Fix 6 comment) for rendering an
    /// incorrect tint, since `.behindWindow` blending composites against
    /// whatever is behind the *window* (desktop/other apps), not other
    /// content inside it. That's what the captain's screenshot caught here:
    /// the rail rendering peach/salmon instead of the active Helm theme. A
    /// plain, theme-driven solid background - what every other full-size
    /// destination in this app already uses - is the fix.
    private let edgeLine = NSView()

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: Self.width, height: 660))
        root.wantsLayer = true
        view = root
        edgeLine.wantsLayer = true
        edgeLine.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(edgeLine)
        NSLayoutConstraint.activate([
            edgeLine.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            edgeLine.topAnchor.constraint(equalTo: root.topAnchor),
            edgeLine.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            edgeLine.widthAnchor.constraint(equalToConstant: 1),
        ])
        ThemeManager.shared.observe { [weak self, weak root] theme in
            root?.appearance = NSAppearance(named: theme.mode == .dark ? .darkAqua : .aqua)
            root?.layer?.backgroundColor = HelmTheme.nsColor(theme.chromeBackgroundHex).cgColor
            self?.edgeLine.layer?.backgroundColor = HelmTheme.nsColor(theme.chromeLineHex).withAlphaComponent(0.5).cgColor
            self?.restyle(theme)
        }

        let mark = NSImageView()
        mark.image = NSImage(systemSymbolName: "sailboat", accessibilityDescription: "Firstmate Cockpit")
        mark.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 17, weight: .medium)
        mark.wantsLayer = true
        mark.layer?.cornerRadius = 10
        mark.imageScaling = .scaleProportionallyDown
        mark.translatesAutoresizingMaskIntoConstraints = false

        let navStack = NSStackView()
        navStack.orientation = .vertical
        navStack.spacing = 4
        navStack.translatesAutoresizingMaskIntoConstraints = false
        for dest in RailDestination.allCases where dest != .settings {
            let button = railButton(for: dest)
            buttons[dest] = button
            navStack.addArrangedSubview(button)
        }

        hostsStack.orientation = .vertical
        hostsStack.spacing = 4
        hostsStack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(hostsStack)

        // Settings sits below the dynamic per-host icon block, directly
        // above the avatar - the captain wants it last among the rail's
        // clickable destinations regardless of how many hosts are pinned.
        // Still a `RailDestination` case for switching purposes; only its
        // vertical position moves out of `navStack`.
        let settingsButton = railButton(for: .settings)
        buttons[.settings] = settingsButton
        settingsButton.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(settingsButton)

        avatar.title = "M"
        avatar.isBordered = false
        avatar.wantsLayer = true
        avatar.layer?.cornerRadius = 18
        avatar.font = .systemFont(ofSize: 13, weight: .semibold)
        avatar.target = self
        avatar.action = #selector(avatarClicked)
        avatar.toolTip = "Firstmate Cockpit"
        avatar.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(mark)
        root.addSubview(navStack)
        root.addSubview(avatar)

        NSLayoutConstraint.activate([
            view.widthAnchor.constraint(equalToConstant: Self.width),

            mark.topAnchor.constraint(equalTo: root.topAnchor, constant: 14),
            mark.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            mark.widthAnchor.constraint(equalToConstant: 34),
            mark.heightAnchor.constraint(equalToConstant: 34),

            navStack.topAnchor.constraint(equalTo: mark.bottomAnchor, constant: 14),
            navStack.centerXAnchor.constraint(equalTo: root.centerXAnchor),

            hostsStack.topAnchor.constraint(equalTo: navStack.bottomAnchor, constant: 10),
            hostsStack.centerXAnchor.constraint(equalTo: root.centerXAnchor),

            settingsButton.topAnchor.constraint(greaterThanOrEqualTo: hostsStack.bottomAnchor, constant: 10),
            settingsButton.centerXAnchor.constraint(equalTo: root.centerXAnchor),

            avatar.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -14),
            avatar.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            avatar.widthAnchor.constraint(equalToConstant: 36),
            avatar.heightAnchor.constraint(equalToConstant: 36),
            settingsButton.bottomAnchor.constraint(equalTo: avatar.topAnchor, constant: -14),
        ])

        restyle(ThemeManager.shared.theme)
        setActive(active)
    }

    private func railButton(for dest: RailDestination) -> NSButton {
        let button = NSButton(title: "", target: self, action: #selector(navClicked(_:)))
        button.isBordered = false
        button.wantsLayer = true
        button.layer?.cornerRadius = 11
        button.imageScaling = .scaleProportionallyDown
        let config = NSImage.SymbolConfiguration(pointSize: 16, weight: .regular)
        button.image = NSImage(systemSymbolName: dest.symbol, accessibilityDescription: dest.title)?
            .withSymbolConfiguration(config)
        button.toolTip = dest.title
        button.tag = RailDestination.allCases.firstIndex(of: dest) ?? 0
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 44),
            button.heightAnchor.constraint(equalToConstant: 40),
        ])
        return button
    }

    @objc private func navClicked(_ sender: NSButton) {
        let dest = RailDestination.allCases[sender.tag]
        setActive(dest)
        onSelect?(dest)
    }

    /// Fix 3 (fixes4): rebuild the per-host icon list. Called once at
    /// startup and on every `HostStore.observe` firing (add/rename/delete),
    /// so the rail never drifts from the Hosts list.
    func setHosts(_ hosts: [Host]) {
        self.hosts = hosts
        for v in hostsStack.arrangedSubviews {
            hostsStack.removeArrangedSubview(v)
            v.removeFromSuperview()
        }
        hostButtons.removeAll()
        for host in hosts {
            let button = hostRailButton(for: host)
            hostButtons[host.id] = button
            hostsStack.addArrangedSubview(button)
        }
        restyle(ThemeManager.shared.theme)
    }

    private func hostRailButton(for host: Host) -> NSButton {
        let button = NSButton(title: "", target: self, action: #selector(hostClicked(_:)))
        button.isBordered = false
        button.wantsLayer = true
        button.layer?.cornerRadius = 11
        button.imageScaling = .scaleProportionallyDown
        let config = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
        button.image = (NSImage(systemSymbolName: host.iconSymbol, accessibilityDescription: host.label)
            ?? NSImage(systemSymbolName: HostCatalog.defaultIcon, accessibilityDescription: host.label))?
            .withSymbolConfiguration(config)
        button.toolTip = host.label
        button.identifier = NSUserInterfaceItemIdentifier(host.id.uuidString)
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 44),
            button.heightAnchor.constraint(equalToConstant: 36),
        ])
        return button
    }

    @objc private func hostClicked(_ sender: NSButton) {
        guard let idString = sender.identifier?.rawValue,
              let id = UUID(uuidString: idString),
              let host = hosts.first(where: { $0.id == id }) else { return }
        onConnectHost?(host)
    }

    @objc private func avatarClicked() {
        NSApp.orderFrontStandardAboutPanel(nil)
    }

    /// Called by `AppShellController` both on a rail click and when it wants
    /// to programmatically land on a destination (e.g. at launch).
    func setActive(_ dest: RailDestination) {
        active = dest
        activeHostID = nil
        restyle(ThemeManager.shared.theme)
    }

    /// Fix 1: a host's dedicated page is showing - highlight its icon
    /// instead of any fixed destination.
    func setActiveHost(_ id: UUID) {
        activeHostID = id
        restyle(ThemeManager.shared.theme)
    }

    private func restyle(_ theme: HelmTheme) {
        let ink = HelmTheme.nsColor(theme.chromeInkHex)
        let accent = HelmTheme.nsColor(theme.accentHex)
        let accentTint = accent.withAlphaComponent(theme.mode == .dark ? 0.20 : 0.14)
        for (dest, button) in buttons {
            let isActive = activeHostID == nil && dest == active
            button.contentTintColor = isActive ? accent : ink.withAlphaComponent(0.65)
            button.layer?.backgroundColor = (isActive ? accentTint : .clear).cgColor
        }
        for host in hosts {
            guard let button = hostButtons[host.id] else { continue }
            let hostAccent = HelmTheme.nsColor(host.accentHex)
            let isActive = host.id == activeHostID
            button.contentTintColor = hostAccent
            button.layer?.backgroundColor = (isActive ? hostAccent.withAlphaComponent(theme.mode == .dark ? 0.20 : 0.14) : .clear).cgColor
        }
        avatar.contentTintColor = ink
        avatar.layer?.backgroundColor = HelmTheme.nsColor(theme.chromeLineHex).withAlphaComponent(0.4).cgColor
    }
}
