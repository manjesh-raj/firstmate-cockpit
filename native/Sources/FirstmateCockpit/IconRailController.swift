// Manjesh Grand Line - native macOS app.
//
// The primary nav rail (nav-redesign task, item 1; relabeled to a Slack-
// inspired sectioned/labeled rail by fm/grandline-sidebar-labeled-nav - see
// that task's header comment on `railButton(for:labeled:)` for the shape).
// A narrow, fixed-width column, mirroring the web app's icon rail
// (`backend/static/index.html`, `.rail`/`.nav` - roughly line 706 onward).
// Never resizes and is always visible; the active destination gets a tinted
// background exactly like the web rail's `.nav.on`.
//
// This view knows nothing about hosts, the console, or settings - it only
// reports which destination was clicked (`onSelect`) and reflects whichever
// destination `select(_:)` says is active. `AppShellController` owns the
// mapping from destination to actual content.

import AppKit

/// The rail's eleven destinations. Switching order (captain correction,
/// theme-audit task): Overview, Console, Hosts, then Review, then Settings -
/// overriding fixes4 Fix 2's Console/Hosts-first ordering. Note that this is
/// the *switching* order only - Settings' *visual* position in the rail is
/// moved to after the dynamic per-host icon block (see `loadView`), directly
/// above the avatar. `.updates` (cockpit-native-updates-page) follows the
/// same rule: it is a real `RailDestination` for switching purposes, but its
/// *visual* position is pinned directly above Settings (so above the avatar,
/// below the per-host icon block) regardless of case order here. `.bootstrap`
/// (cockpit-bootstrap-scaffold) follows the identical convention, pinned
/// between `.updates` and `.settings`.
/// `.docs` (cockpit-docs-viewer) follows the identical convention too, pinned
/// directly *above* `.updates` - so the bottom-anchored group reads Docs,
/// Updates, Bootstrap, Settings, avatar.
/// `.tools` (cockpit-tools-page-core) follows the identical convention too,
/// pinned directly *above* `.docs` - so the bottom-anchored group reads
/// Tools, Docs, Updates, Bootstrap, Settings, avatar.
/// `.vault` (fm/grandline-vault-tab) follows the identical convention too,
/// pinned directly *above* `.docs` and below `.tools` - so the bottom-
/// anchored group reads Tools, Vault, Docs, Updates, Bootstrap, Settings,
/// avatar.
/// `.shift` (cockpit-shift-foundation) is different from all of the above:
/// it's a daily-use destination, not a utility, so it is NOT part of the
/// bottom-anchored group - it lives in `navStack` alongside the other fixed
/// destinations. `fm/cockpit-shift-rail-position` moved it from right after
/// `.overview` to right after `.hosts` (captain correction), so `navStack`
/// reads Overview, Console, Hosts, Shift, Review - `loadView`'s `navStack`
/// loop gets this for free just from case order (case order drives
/// `navStack`'s iteration order, same as every other `navStack` member).
///
/// `isDailyUse` (fm/grandline-sidebar-labeled-nav) marks exactly the 5
/// `navStack` members (Overview, Console, Hosts, Shift, Review) as the set
/// that lives in the top `navStack` block rather than the bottom-anchored
/// utility group - `navStack`'s loop and the bottom-anchored `loadView` block
/// both filter on this directly. It no longer selects a *different visual
/// style*: `fm/grandline-sidebar-nav-polish` gave every row (daily-use,
/// utility, and per-host) the same labeled icon-over-text treatment after
/// live captain feedback that icon-only utility rows looked inconsistent
/// once the rest of the rail had labels - see `labeledRailButton(for:)`.
enum RailDestination: CaseIterable {
    case overview, console, hosts, shift, review, tools, vault, docs, updates, bootstrap, settings

    var symbol: String {
        switch self {
        case .overview: return "square.grid.2x2"
        case .shift: return "checkmark.circle"
        case .hosts: return "server.rack"
        case .console: return "terminal"
        case .review: return "arrow.triangle.branch"
        case .tools: return "wrench.and.screwdriver"
        case .vault: return "lock.shield"
        case .docs: return "book.closed"
        case .updates: return "steeringwheel"
        case .bootstrap: return "hammer"
        case .settings: return "gearshape"
        }
    }

    var title: String {
        switch self {
        case .overview: return "Overview"
        case .shift: return "Shift"
        case .hosts: return "Hosts"
        case .console: return "Console"
        case .review: return "Review"
        case .tools: return "Tools"
        case .vault: return "Vault"
        case .docs: return "Docs"
        case .updates: return "Updates"
        case .bootstrap: return "Bootstrap"
        case .settings: return "Settings"
        }
    }

    var isDailyUse: Bool {
        switch self {
        case .overview, .console, .hosts, .shift, .review: return true
        case .tools, .vault, .docs, .updates, .bootstrap, .settings: return false
        }
    }
}

final class IconRailController: NSViewController {

    /// Rail width (fm/grandline-sidebar-labeled-nav): widened from the prior
    /// icon-only 60pt to fit an icon + a text label stacked vertically for
    /// the daily-use rows without wrapping the longest label ("Overview") -
    /// a normal macOS sidebar width, comparable to Mail.app/Xcode, not a
    /// drastic change.
    static let width: CGFloat = 84

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

    /// "Needs you" count badges (fm/grandline-sidebar-badges) - a small red/
    /// white pill overlaid on a rail button's top-trailing corner, matching
    /// macOS's own fixed-red badge convention (Dock icon badges, Mail's
    /// unread count) rather than a theme-tinted pill, so it reads as an
    /// alert regardless of the active Helm theme. Keyed by destination;
    /// `setBadgeCount` is the only mutator and hides the badge whenever the
    /// count is zero, per PRODUCT.md's "quiet until it matters."
    private var badgeContainers: [RailDestination: NSView] = [:]
    private var badgeLabels: [RailDestination: NSTextField] = [:]

    /// The saved hosts currently pinned to the rail, and the vertical stack
    /// they render into - below the fixed destinations, above the utility
    /// group. Rebuilt wholesale on every `setHosts` call (via
    /// `HostStore.observe`), which keeps this trivially correct on
    /// add/rename/delete at the cost of a full rebuild - fine for the
    /// handful of hosts a rail like this is meant to hold.
    private var hosts: [Host] = []
    private let hostsStack = NSStackView()
    private var hostButtons: [UUID: NSButton] = [:]

    /// fm/grandline-sidebar-labeled-nav: a small muted "HOSTS" section label
    /// above the per-host icon block, and hairline dividers bracketing it -
    /// makes the per-host section read as visually distinct from both the
    /// daily-use group above and the utility group below, without inventing
    /// new visual language (a plain `NSBox` separator, per the captain's own
    /// "simple --- line" ask).
    private let hostsSectionLabel = NSTextField(labelWithString: "HOSTS")
    private let hostsSectionLabelWrapper = NSView()
    private let dividerAboveHosts = NSBox()
    private let dividerBelowHosts = NSBox()

    /// fm/grandline-sidebar-nav-polish: a hairline divider between the logo
    /// mark and the first daily-use row (Overview) - the captain noticed the
    /// mark/nav boundary had no divider while every other section boundary
    /// (above/below the per-host block) already does. Same `NSBox(.separator)`
    /// style as those two, for visual consistency.
    private let dividerAboveNav = NSBox()

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
        let root = NSView(frame: NSRect(x: 0, y: 0, width: Self.width, height: 760))
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

        dividerAboveNav.boxType = .separator
        dividerAboveNav.translatesAutoresizingMaskIntoConstraints = false
        dividerAboveHosts.boxType = .separator
        dividerAboveHosts.translatesAutoresizingMaskIntoConstraints = false
        dividerBelowHosts.boxType = .separator
        dividerBelowHosts.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(dividerAboveNav)
        root.addSubview(dividerAboveHosts)
        root.addSubview(dividerBelowHosts)

        hostsSectionLabel.font = .systemFont(ofSize: 9, weight: .semibold)
        hostsSectionLabel.alignment = .center
        hostsSectionLabel.translatesAutoresizingMaskIntoConstraints = false
        hostsSectionLabelWrapper.translatesAutoresizingMaskIntoConstraints = false
        hostsSectionLabelWrapper.addSubview(hostsSectionLabel)
        root.addSubview(hostsSectionLabelWrapper)
        NSLayoutConstraint.activate([
            hostsSectionLabel.leadingAnchor.constraint(equalTo: hostsSectionLabelWrapper.leadingAnchor),
            hostsSectionLabel.trailingAnchor.constraint(equalTo: hostsSectionLabelWrapper.trailingAnchor),
            hostsSectionLabel.topAnchor.constraint(equalTo: hostsSectionLabelWrapper.topAnchor),
            hostsSectionLabel.bottomAnchor.constraint(equalTo: hostsSectionLabelWrapper.bottomAnchor),
        ])

        ThemeManager.shared.observe { [weak self, weak root] theme in
            root?.appearance = NSAppearance(named: theme.mode == .dark ? .darkAqua : .aqua)
            root?.layer?.backgroundColor = HelmTheme.nsColor(theme.chromeBackgroundHex).cgColor
            self?.edgeLine.layer?.backgroundColor = HelmTheme.nsColor(theme.chromeLineHex).withAlphaComponent(0.5).cgColor
            self?.hostsSectionLabel.textColor = HelmTheme.nsColor(theme.chromeInkHex).withAlphaComponent(0.45)
            self?.restyle(theme)
        }

        let mark = NSImageView()
        mark.image = NSImage(systemSymbolName: "sailboat", accessibilityDescription: "Manjesh Grand Line")
        mark.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 17, weight: .medium)
        mark.wantsLayer = true
        mark.layer?.cornerRadius = 10
        mark.imageScaling = .scaleProportionallyDown
        mark.translatesAutoresizingMaskIntoConstraints = false

        let navStack = NSStackView()
        navStack.orientation = .vertical
        navStack.spacing = 4
        navStack.translatesAutoresizingMaskIntoConstraints = false
        for dest in RailDestination.allCases where dest.isDailyUse {
            let button = railButton(for: dest)
            buttons[dest] = button
            navStack.addArrangedSubview(button)
        }

        hostsStack.orientation = .vertical
        hostsStack.spacing = 4
        hostsStack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(hostsStack)

        // Tools (cockpit-tools-page-core) sits below the dynamic per-host
        // icon block, directly above Vault, which sits directly above Docs,
        // which sits directly above Updates, which sits directly above
        // Bootstrap, which sits directly above Settings - which in turn sits
        // directly above the avatar, per the captain's ask. All six are
        // still real `RailDestination` cases for switching purposes; only
        // their vertical position moves out of `navStack`. This whole group
        // stays compact/icon-only, unlabeled (fm/grandline-sidebar-labeled-nav)
        // - a deliberate decision, not a scope gap.
        let toolsButton = railButton(for: .tools)
        buttons[.tools] = toolsButton
        toolsButton.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(toolsButton)

        let vaultButton = railButton(for: .vault)
        buttons[.vault] = vaultButton
        vaultButton.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(vaultButton)

        let docsButton = railButton(for: .docs)
        buttons[.docs] = docsButton
        docsButton.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(docsButton)

        let updatesButton = railButton(for: .updates)
        buttons[.updates] = updatesButton
        updatesButton.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(updatesButton)

        let bootstrapButton = railButton(for: .bootstrap)
        buttons[.bootstrap] = bootstrapButton
        bootstrapButton.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(bootstrapButton)

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
        avatar.toolTip = "Manjesh Grand Line"
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

            dividerAboveNav.topAnchor.constraint(equalTo: mark.bottomAnchor, constant: 10),
            dividerAboveNav.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
            dividerAboveNav.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14),

            navStack.topAnchor.constraint(equalTo: dividerAboveNav.bottomAnchor, constant: 10),
            navStack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 6),
            navStack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -6),

            // Divider + "HOSTS" label + divider bracket the per-host icon
            // block, reading as a visually distinct section between
            // daily-use (above) and utility (below) - captain ask: simple
            // hairline dividers, no new visual language.
            dividerAboveHosts.topAnchor.constraint(equalTo: navStack.bottomAnchor, constant: 12),
            dividerAboveHosts.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
            dividerAboveHosts.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14),

            hostsSectionLabelWrapper.topAnchor.constraint(equalTo: dividerAboveHosts.bottomAnchor, constant: 8),
            hostsSectionLabelWrapper.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 6),
            hostsSectionLabelWrapper.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -6),

            hostsStack.topAnchor.constraint(equalTo: hostsSectionLabelWrapper.bottomAnchor, constant: 6),
            hostsStack.centerXAnchor.constraint(equalTo: root.centerXAnchor),

            dividerBelowHosts.topAnchor.constraint(equalTo: hostsStack.bottomAnchor, constant: 10),
            dividerBelowHosts.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
            dividerBelowHosts.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14),

            toolsButton.topAnchor.constraint(greaterThanOrEqualTo: dividerBelowHosts.bottomAnchor, constant: 10),
            toolsButton.centerXAnchor.constraint(equalTo: root.centerXAnchor),

            vaultButton.topAnchor.constraint(greaterThanOrEqualTo: dividerBelowHosts.bottomAnchor, constant: 10),
            vaultButton.centerXAnchor.constraint(equalTo: root.centerXAnchor),

            docsButton.topAnchor.constraint(greaterThanOrEqualTo: dividerBelowHosts.bottomAnchor, constant: 10),
            docsButton.centerXAnchor.constraint(equalTo: root.centerXAnchor),

            updatesButton.topAnchor.constraint(greaterThanOrEqualTo: dividerBelowHosts.bottomAnchor, constant: 10),
            updatesButton.centerXAnchor.constraint(equalTo: root.centerXAnchor),

            bootstrapButton.topAnchor.constraint(greaterThanOrEqualTo: dividerBelowHosts.bottomAnchor, constant: 10),
            bootstrapButton.centerXAnchor.constraint(equalTo: root.centerXAnchor),

            settingsButton.topAnchor.constraint(greaterThanOrEqualTo: dividerBelowHosts.bottomAnchor, constant: 10),
            settingsButton.centerXAnchor.constraint(equalTo: root.centerXAnchor),

            avatar.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -14),
            avatar.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            avatar.widthAnchor.constraint(equalToConstant: 36),
            avatar.heightAnchor.constraint(equalToConstant: 36),
            settingsButton.bottomAnchor.constraint(equalTo: avatar.topAnchor, constant: -14),
            bootstrapButton.bottomAnchor.constraint(equalTo: settingsButton.topAnchor, constant: -4),
            updatesButton.bottomAnchor.constraint(equalTo: bootstrapButton.topAnchor, constant: -4),
            docsButton.bottomAnchor.constraint(equalTo: updatesButton.topAnchor, constant: -4),
            vaultButton.bottomAnchor.constraint(equalTo: docsButton.topAnchor, constant: -4),
            toolsButton.bottomAnchor.constraint(equalTo: vaultButton.topAnchor, constant: -4),
        ])

        restyle(ThemeManager.shared.theme)
        setActive(active)
    }

    /// Builds a rail row for `dest`: icon above a small text label, both
    /// centered, inside one clickable `NSButton` sized to the full rail
    /// content width so the tinted active-state background reads as a
    /// full-width row rather than a small icon-sized square. Built as an
    /// `NSButton` with `imagePosition = .imageAbove` (not a separate
    /// icon+label stack overlaid on a button) so the existing single-view
    /// `contentTintColor`/`layer?.backgroundColor` restyle path in
    /// `restyle(_:)` covers every row with one mechanism. Every
    /// `RailDestination` uses this same builder (fm/grandline-sidebar-nav-polish)
    /// - the earlier compact icon-only style for utility destinations is
    /// gone; see `isDailyUse`'s doc comment. Every row also gets a "needs
    /// you" count badge overlay (fm/grandline-sidebar-badges) - cheap to
    /// attach on all of them (hidden by default) rather than threading a
    /// second "does this destination want a badge" flag through here; only
    /// `setBadgeCount` ever makes one visible. `attachBadge` positions the
    /// badge relative to `button`'s own top-trailing corner, so it still
    /// lands correctly now that every row shares this one taller, wider
    /// labeled shape instead of the two different button sizes it originally
    /// had to handle.
    private func railButton(for dest: RailDestination) -> NSButton {
        let button = NSButton(title: dest.title, target: self, action: #selector(navClicked(_:)))
        button.isBordered = false
        button.wantsLayer = true
        button.layer?.cornerRadius = 10
        button.imagePosition = .imageAbove
        button.imageScaling = .scaleProportionallyDown
        button.alignment = .center
        button.font = .systemFont(ofSize: 10, weight: .medium)
        button.lineBreakMode = .byTruncatingTail
        let config = NSImage.SymbolConfiguration(pointSize: 17, weight: .regular)
        button.image = NSImage(systemSymbolName: dest.symbol, accessibilityDescription: dest.title)?
            .withSymbolConfiguration(config)
        button.toolTip = dest.title
        button.tag = RailDestination.allCases.firstIndex(of: dest) ?? 0
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: Self.width - 12),
            button.heightAnchor.constraint(equalToConstant: 52),
        ])
        attachBadge(to: button, dest: dest)
        return button
    }

    /// Pins a small count-badge overlay to `button`'s top-trailing corner.
    /// Hidden by default; only `setBadgeCount` ever shows one. Deliberately a
    /// fixed white-on-systemRed pill rather than a theme-derived `HelmTint` -
    /// unlike a status pill elsewhere in this app, an unread/needs-attention
    /// badge is meant to stand out the same way regardless of which of the
    /// 12 Helm themes is active, matching how macOS itself never re-tints a
    /// Dock badge or Mail's unread count to match the current appearance.
    private func attachBadge(to button: NSButton, dest: RailDestination) {
        let label = NSTextField(labelWithString: "")
        label.font = .monospacedDigitSystemFont(ofSize: 9, weight: .bold)
        label.textColor = .white
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.wantsLayer = true
        container.layer?.cornerRadius = 8
        container.layer?.backgroundColor = NSColor.systemRed.cgColor
        container.translatesAutoresizingMaskIntoConstraints = false
        container.isHidden = true
        container.addSubview(label)
        button.addSubview(container)

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 4),
            label.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -4),
            label.topAnchor.constraint(equalTo: container.topAnchor, constant: 1),
            label.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -1),
            container.heightAnchor.constraint(equalToConstant: 16),
            container.widthAnchor.constraint(greaterThanOrEqualToConstant: 16),
            container.topAnchor.constraint(equalTo: button.topAnchor, constant: -4),
            container.trailingAnchor.constraint(equalTo: button.trailingAnchor, constant: 4),
        ])
        badgeContainers[dest] = container
        badgeLabels[dest] = label
    }

    /// Sets the "needs you" count badge for `dest`. `count <= 0` hides the
    /// badge entirely - no badge is ever shown for a zero/no-signal count,
    /// per PRODUCT.md's "quiet until it matters." Callers own deciding what
    /// "needs you" means for their destination (e.g. open PRs on `.review`,
    /// tasks needing a decision on `.overview`) - this view only renders
    /// whatever number it's given.
    func setBadgeCount(_ count: Int, for dest: RailDestination) {
        guard let container = badgeContainers[dest], let label = badgeLabels[dest] else { return }
        container.isHidden = count <= 0
        guard count > 0 else { return }
        label.stringValue = count > 99 ? "99+" : "\(count)"
    }

    @objc private func navClicked(_ sender: NSButton) {
        let dest = RailDestination.allCases[sender.tag]
        setActive(dest)
        onSelect?(dest)
    }

    /// Fix 3 (fixes4): rebuild the per-host icon list. Called once at
    /// startup and on every `HostStore.observe` firing (add/rename/delete),
    /// so the rail never drifts from the Hosts list. The "HOSTS" section
    /// label and its bracketing dividers stay visible even when there are
    /// no saved hosts (fm/grandline-sidebar-labeled-nav) - an empty section
    /// still reads as "here's where hosts go" rather than disappearing and
    /// shifting the utility group up.
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

    /// Labeled the same way as `railButton(for:)` (fm/grandline-sidebar-nav-polish
    /// - the captain's screenshot showed pinned hosts with an icon but no
    /// name underneath, inconsistent with the rest of the now fully-labeled
    /// rail). Kept as its own function rather than folded into `railButton`
    /// since a host has no `RailDestination` case/tag - it dispatches
    /// through `hostClicked(_:)` via its `identifier`, not `navClicked(_:)`.
    private func hostRailButton(for host: Host) -> NSButton {
        let button = NSButton(title: host.label, target: self, action: #selector(hostClicked(_:)))
        button.isBordered = false
        button.wantsLayer = true
        button.layer?.cornerRadius = 10
        button.imagePosition = .imageAbove
        button.imageScaling = .scaleProportionallyDown
        button.alignment = .center
        button.font = .systemFont(ofSize: 10, weight: .medium)
        button.lineBreakMode = .byTruncatingTail
        let config = NSImage.SymbolConfiguration(pointSize: 16, weight: .regular)
        button.image = (NSImage(systemSymbolName: host.iconSymbol, accessibilityDescription: host.label)
            ?? NSImage(systemSymbolName: HostCatalog.defaultIcon, accessibilityDescription: host.label))?
            .withSymbolConfiguration(config)
        button.toolTip = host.label
        button.identifier = NSUserInterfaceItemIdentifier(host.id.uuidString)
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: Self.width - 12),
            button.heightAnchor.constraint(equalToConstant: 52),
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

    /// Centered paragraph style shared by every labeled row's `attributedTitle`
    /// (fm/grandline-sidebar-nav-polish). This is the actual fix for the
    /// off-center active-highlight bug: `NSButton.attributedTitle` lays out
    /// its text using the attributed string's own paragraph alignment, not
    /// the button's `alignment` property - an attributed title built with no
    /// explicit alignment defaults to natural/left, which then also drags
    /// `imagePosition = .imageAbove`'s icon left (the cell centers the image
    /// over the title's actual (left-aligned) glyph run, not over the full
    /// button width), so both the icon and the label end up shifted left
    /// inside the full-width tinted highlight box. Confirmed by inspection:
    /// this is the only place `attributedTitle` was constructed, and it had
    /// no `.paragraphStyle` attribute at all.
    private static let centeredTitleStyle: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        return style
    }()

    private func attributedRowTitle(_ text: String, color: NSColor) -> NSAttributedString {
        NSAttributedString(
            string: text,
            attributes: [
                .font: NSFont.systemFont(ofSize: 10, weight: .medium),
                .foregroundColor: color,
                .paragraphStyle: Self.centeredTitleStyle,
            ]
        )
    }

    private func restyle(_ theme: HelmTheme) {
        let ink = HelmTheme.nsColor(theme.chromeInkHex)
        let accent = HelmTheme.nsColor(theme.accentHex)
        let accentTint = accent.withAlphaComponent(theme.mode == .dark ? 0.20 : 0.14)
        for (dest, button) in buttons {
            let isActive = activeHostID == nil && dest == active
            let color = isActive ? accent : ink.withAlphaComponent(0.65)
            button.contentTintColor = color
            // Labeled buttons render their title via `NSButton`'s own
            // attributed-title machinery, which resets on every
            // `contentTintColor` set - restate the tinted title here so
            // the label always matches the icon's active/inactive color.
            button.attributedTitle = attributedRowTitle(dest.title, color: color)
            button.layer?.backgroundColor = (isActive ? accentTint : .clear).cgColor
        }
        for host in hosts {
            guard let button = hostButtons[host.id] else { continue }
            let hostAccent = HelmTheme.nsColor(host.accentHex)
            let isActive = host.id == activeHostID
            button.contentTintColor = hostAccent
            button.attributedTitle = attributedRowTitle(host.label, color: hostAccent)
            button.layer?.backgroundColor = (isActive ? hostAccent.withAlphaComponent(theme.mode == .dark ? 0.20 : 0.14) : .clear).cgColor
        }
        avatar.contentTintColor = ink
        avatar.layer?.backgroundColor = HelmTheme.nsColor(theme.chromeLineHex).withAlphaComponent(0.4).cgColor
    }
}
