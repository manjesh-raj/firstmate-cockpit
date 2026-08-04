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

/// The rail's five destinations, in the same left-to-right/top-to-bottom
/// order as the web app's icon set: Fleet-equivalent, overview, console,
/// review, settings. Unlike the web rail, this one also has a dedicated
/// "Home" (anchor) entry for the pinned Firstmate quick-connect, since that
/// concept has no web-app analogue.
enum RailDestination: CaseIterable {
    case home, overview, console, review, settings

    var symbol: String {
        switch self {
        case .home: return "anchor"
        case .overview: return "square.grid.2x2"
        case .console: return "terminal"
        case .review: return "arrow.triangle.branch"
        case .settings: return "gearshape"
        }
    }

    var title: String {
        switch self {
        case .home: return "Home"
        case .overview: return "Overview"
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

    private(set) var active: RailDestination = .console
    private var buttons: [RailDestination: NSButton] = [:]
    private let avatar = NSButton()

    override func loadView() {
        let root = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: Self.width, height: 660))
        root.material = .sidebar
        root.blendingMode = .behindWindow
        root.state = .followsWindowActiveState
        view = root
        ThemeManager.shared.observe { [weak self, weak root] theme in
            root?.appearance = NSAppearance(named: theme.mode == .dark ? .darkAqua : .aqua)
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
        for dest in RailDestination.allCases {
            let button = railButton(for: dest)
            buttons[dest] = button
            navStack.addArrangedSubview(button)
        }

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

            avatar.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -14),
            avatar.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            avatar.widthAnchor.constraint(equalToConstant: 36),
            avatar.heightAnchor.constraint(equalToConstant: 36),
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

    @objc private func avatarClicked() {
        NSApp.orderFrontStandardAboutPanel(nil)
    }

    /// Called by `AppShellController` both on a rail click and when it wants
    /// to programmatically land on a destination (e.g. at launch).
    func setActive(_ dest: RailDestination) {
        active = dest
        restyle(ThemeManager.shared.theme)
    }

    private func restyle(_ theme: HelmTheme) {
        let ink = HelmTheme.nsColor(theme.chromeInkHex)
        let accent = HelmTheme.nsColor(theme.accentHex)
        let accentTint = accent.withAlphaComponent(theme.mode == .dark ? 0.20 : 0.14)
        for (dest, button) in buttons {
            let isActive = dest == active
            button.contentTintColor = isActive ? accent : ink.withAlphaComponent(0.65)
            button.layer?.backgroundColor = (isActive ? accentTint : .clear).cgColor
        }
        avatar.contentTintColor = ink
        avatar.layer?.backgroundColor = HelmTheme.nsColor(theme.chromeLineHex).withAlphaComponent(0.4).cgColor
    }
}
