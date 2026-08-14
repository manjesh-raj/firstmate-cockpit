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
/// `fm/grandline-rail-setup-group` merged `.updates`/`.bootstrap`'s two
/// standalone rail rows into one "Setup" entry, directly above `.docs`, that
/// opens a small flyout `NSPopover` listing Updates and Bootstrap - so the
/// bottom-anchored group visually reads Tools, Vault, Docs, Setup
/// (-> Updates, Bootstrap flyout), Settings, avatar. Both cases remain real
/// `RailDestination`s for switching purposes - only their rail position/
/// visibility changed; see `IconRailController.buildSetupButton()`/
/// `showSetupFlyout()`.
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
        // fm/grandline-rail-followup-fixes: the captain asked for the menu
        // bar's Shift/Tasks status item to use the same "sailboat" glyph as
        // the app's own logo mark, since that standalone item has no nearby
        // app branding to associate it back to this app (see
        // `ShiftMenuBarController.init`). The rail's own `.shift` row
        // deliberately keeps `checkmark.circle` rather than also switching
        // to `sailboat` - the rail already shows the real sailboat logo mark
        // directly above this row (`IconRailController.loadView`'s `mark`),
        // so a second sailboat a few rows down would read as a duplicate
        // icon rather than a clearer one.
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
        case .shift: return "Tasks"
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

    /// The per-badge constraints `setBadgeCount` re-tunes for a double-digit
    /// (or "99+") count - see that method's doc comment for why a fixed
    /// single-digit sizing overflows once the count grows a second digit.
    private var badgeLabelInsets: [RailDestination: (leading: NSLayoutConstraint, trailing: NSLayoutConstraint)] = [:]
    private var badgeOffsets: [RailDestination: (top: NSLayoutConstraint, trailing: NSLayoutConstraint)] = [:]

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

    /// fm/grandline-rail-setup-group: "Setup" merges the standalone Updates
    /// and Bootstrap rail entries into one entry after a captain-approved
    /// discussion (both are environment/dependency setup concerns, distinct
    /// from Settings' app preferences, which stays its own separate top-level
    /// icon, untouched). `.updates`/`.bootstrap` remain real
    /// `RailDestination` cases with unchanged pages - only their rail
    /// position/visibility changed. Hovering "Setup" reveals them as a small
    /// flyout `NSPopover` anchored to the button's trailing edge (two captain
    /// corrections from the first pass: an in-rail expanding drawer pushed
    /// every row below it up and down as it opened/closed, disrupting the
    /// rail's fixed divider rhythm - a flyout to the side leaves the rail's
    /// own layout untouched; and the flyout should open on hover, Dock/menu-
    /// bar-submenu style, not a click, so the disclosure chevron affordance
    /// a click-to-open control would need is gone too). See
    /// `HoverTrackingButton`, `buildSetupButton()`, `scheduleShowSetupFlyout()`/
    /// `scheduleCloseSetupFlyout()`. "Setup" itself is a pure UI toggle, not a
    /// `RailDestination` - it never calls `onSelect`.
    private let setupButton = HoverTrackingButton()
    private var setupPopover: NSPopover?

    /// Closing the flyout on mouse-exit is delayed slightly (`closeDelay`) so
    /// moving the cursor from the Setup button to the flyout's own content -
    /// two disconnected views with a small gap between them - doesn't close
    /// it out from under the captain; `scheduleShowSetupFlyout` cancels this
    /// timer the moment either view reports the mouse back over it.
    private var setupCloseWorkItem: DispatchWorkItem?
    private static let setupCloseDelay: TimeInterval = 0.2

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
        let dailyUseDestinations = RailDestination.allCases.filter { $0.isDailyUse }
        for (index, dest) in dailyUseDestinations.enumerated() {
            // fm/grandline-rail-followup-fixes: a hairline separator between
            // each daily-use row (Overview | Console | Hosts | Tasks |
            // Review), matching the existing `NSBox(.separator)` style
            // already used above/below the per-host block - captain ask was
            // scoped to this group only, so the per-host and utility groups
            // are untouched.
            if index > 0 {
                let divider = NSBox()
                divider.boxType = .separator
                divider.translatesAutoresizingMaskIntoConstraints = false
                navStack.addArrangedSubview(divider)
                divider.widthAnchor.constraint(equalTo: navStack.widthAnchor, constant: -16).isActive = true
            }
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
        // which sits directly above the "Setup" group (fm/grandline-rail-setup-group
        // - Bootstrap and Updates, collapsed into one entry, see
        // `buildSetupButton()`), which sits directly above Settings - which in
        // turn sits directly above the avatar, per the captain's ask. All of
        // these are still real `RailDestination` cases for switching
        // purposes (Bootstrap/Updates included); only their vertical
        // position moves out of `navStack`.
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

        let setupGroup = buildSetupButton()
        setupGroup.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(setupGroup)

        let settingsButton = railButton(for: .settings)
        buttons[.settings] = settingsButton
        settingsButton.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(settingsButton)

        // fm/grandline-rail-utility-separators: a hairline separator between
        // each utility row (Tools | Vault | Docs | Updates | Bootstrap |
        // Settings), matching the daily-use group's own `NSBox(.separator)`
        // treatment (fm/grandline-rail-followup-fixes) - captain ask, scoped
        // to this group only. These buttons aren't in a stack view (they're
        // individually positioned so the per-host block above them can grow),
        // so each divider is a plain sibling view sized/centered the same way
        // the daily-use dividers are (`navStack.widthAnchor - 16`, i.e.
        // `Self.width - 28` here since these buttons live directly in `root`
        // rather than an inset stack).
        func utilityDivider() -> NSBox {
            let divider = NSBox()
            divider.boxType = .separator
            divider.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(divider)
            divider.widthAnchor.constraint(equalToConstant: Self.width - 28).isActive = true
            divider.centerXAnchor.constraint(equalTo: root.centerXAnchor).isActive = true
            return divider
        }
        let dividerToolsVault = utilityDivider()
        let dividerVaultDocs = utilityDivider()
        let dividerDocsSetup = utilityDivider()
        let dividerSetupSettings = utilityDivider()
        // fm/grandline-vault-header-and-avatar-divider: same treatment,
        // between the last utility row (Settings) and the avatar pinned at
        // the very bottom - the one boundary in this bottom-up chain that
        // didn't have one yet.
        let dividerSettingsAvatar = utilityDivider()

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

            setupGroup.topAnchor.constraint(greaterThanOrEqualTo: dividerBelowHosts.bottomAnchor, constant: 10),
            setupGroup.centerXAnchor.constraint(equalTo: root.centerXAnchor),

            settingsButton.topAnchor.constraint(greaterThanOrEqualTo: dividerBelowHosts.bottomAnchor, constant: 10),
            settingsButton.centerXAnchor.constraint(equalTo: root.centerXAnchor),

            avatar.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -14),
            avatar.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            avatar.widthAnchor.constraint(equalToConstant: 36),
            avatar.heightAnchor.constraint(equalToConstant: 36),
            dividerSettingsAvatar.bottomAnchor.constraint(equalTo: avatar.topAnchor, constant: -10),
            settingsButton.bottomAnchor.constraint(equalTo: dividerSettingsAvatar.topAnchor, constant: -10),
            dividerSetupSettings.bottomAnchor.constraint(equalTo: settingsButton.topAnchor, constant: -4),
            setupGroup.bottomAnchor.constraint(equalTo: dividerSetupSettings.topAnchor, constant: -4),
            dividerDocsSetup.bottomAnchor.constraint(equalTo: setupGroup.topAnchor, constant: -4),
            docsButton.bottomAnchor.constraint(equalTo: dividerDocsSetup.topAnchor, constant: -4),
            dividerVaultDocs.bottomAnchor.constraint(equalTo: docsButton.topAnchor, constant: -4),
            vaultButton.bottomAnchor.constraint(equalTo: dividerVaultDocs.topAnchor, constant: -4),
            dividerToolsVault.bottomAnchor.constraint(equalTo: vaultButton.topAnchor, constant: -4),
            toolsButton.bottomAnchor.constraint(equalTo: dividerToolsVault.topAnchor, constant: -4),
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
        let button = NSButton()
        button.cell = CenteredImageAboveButtonCell()
        button.title = dest.title
        button.target = self
        button.action = #selector(navClicked(_:))
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

    /// Builds the "Setup" rail button (fm/grandline-rail-setup-group): one
    /// entry that reveals a small flyout `NSPopover` on hover (see
    /// `scheduleShowSetupFlyout()`/`scheduleCloseSetupFlyout()`) listing
    /// Updates and Bootstrap. "Setup" has no destination of its own and never
    /// calls `onSelect` directly - it's a plain UI toggle occupying the rail
    /// slot the two standalone icons used to. Otherwise built exactly like
    /// `railButton(for:)`, minus the tag (there's no `RailDestination` case
    /// to dispatch through) and minus a click target/action (hover-driven,
    /// not click-driven - see `HoverTrackingButton`).
    private func buildSetupButton() -> NSButton {
        setupButton.cell = CenteredImageAboveButtonCell()
        setupButton.title = "Setup"
        setupButton.isBordered = false
        setupButton.wantsLayer = true
        setupButton.layer?.cornerRadius = 10
        setupButton.imagePosition = .imageAbove
        setupButton.imageScaling = .scaleProportionallyDown
        setupButton.alignment = .center
        setupButton.font = .systemFont(ofSize: 10, weight: .medium)
        setupButton.lineBreakMode = .byTruncatingTail
        let config = NSImage.SymbolConfiguration(pointSize: 17, weight: .regular)
        // "wrench.adjustable" - wrench-family like Tools' own icon, but a
        // visually distinct glyph so the two never look like duplicates in
        // the rail; also doesn't collide with Settings' `gearshape`.
        setupButton.image = NSImage(systemSymbolName: "wrench.adjustable", accessibilityDescription: "Setup")?
            .withSymbolConfiguration(config)
        setupButton.toolTip = "Setup (Bootstrap, Updates)"
        NSLayoutConstraint.activate([
            setupButton.widthAnchor.constraint(equalToConstant: Self.width - 12),
            setupButton.heightAnchor.constraint(equalToConstant: 52),
        ])
        setupButton.onHoverChange = { [weak self] isHovering in
            isHovering ? self?.scheduleShowSetupFlyout() : self?.scheduleCloseSetupFlyout()
        }
        return setupButton
    }

    /// Cancels any pending close and shows the flyout immediately if it
    /// isn't already showing - called both when the cursor enters the Setup
    /// button and when it enters the flyout's own content (so moving between
    /// the two never triggers a flicker-close in between).
    private func scheduleShowSetupFlyout() {
        setupCloseWorkItem?.cancel()
        setupCloseWorkItem = nil
        guard setupPopover?.isShown != true else { return }
        showSetupFlyout()
    }

    /// Closes the flyout after a short delay (`setupCloseDelay`) rather than
    /// immediately, so leaving the Setup button to cross the small gap into
    /// the flyout's own content doesn't dismiss it before the cursor arrives.
    /// `scheduleShowSetupFlyout` cancels this the moment either view reports
    /// the mouse back over it.
    private func scheduleCloseSetupFlyout() {
        setupCloseWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in self?.setupPopover?.performClose(nil) }
        setupCloseWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.setupCloseDelay, execute: workItem)
    }

    /// Shows the Updates/Bootstrap flyout, anchored to the Setup button's
    /// trailing edge (captain correction from an earlier in-rail expanding
    /// drawer - see the property's doc comment above). `.applicationDefined`
    /// behavior since show/hide is fully hover-driven here, not click-driven
    /// - `NSPopover`'s own `.transient` click-outside dismissal would fight
    /// with that. Selecting a row dispatches through `onSelect`/`setActive`
    /// exactly like clicking either destination's old standalone icon did,
    /// then closes the flyout immediately (no hover-out delay needed once a
    /// choice has actually been made).
    private func showSetupFlyout() {
        let popover = NSPopover()
        popover.behavior = .applicationDefined
        popover.appearance = NSAppearance(named: ThemeManager.shared.theme.mode == .dark ? .darkAqua : .aqua)
        popover.contentViewController = SetupFlyoutViewController(
            destinations: [.updates, .bootstrap],
            onHoverChange: { [weak self] isHovering in
                isHovering ? self?.scheduleShowSetupFlyout() : self?.scheduleCloseSetupFlyout()
            },
            onSelect: { [weak self] dest in
                self?.setupCloseWorkItem?.cancel()
                self?.setupPopover?.performClose(nil)
                self?.setActive(dest)
                self?.onSelect?(dest)
            }
        )
        popover.show(relativeTo: setupButton.bounds, of: setupButton, preferredEdge: .maxX)
        setupPopover = popover
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

        let leadingInset = label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 4)
        let trailingInset = label.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -4)
        let topOffset = container.topAnchor.constraint(equalTo: button.topAnchor, constant: -4)
        let trailingOffset = container.trailingAnchor.constraint(equalTo: button.trailingAnchor, constant: 4)
        NSLayoutConstraint.activate([
            leadingInset,
            trailingInset,
            label.topAnchor.constraint(equalTo: container.topAnchor, constant: 1),
            label.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -1),
            container.heightAnchor.constraint(equalToConstant: 16),
            container.widthAnchor.constraint(greaterThanOrEqualToConstant: 16),
            topOffset,
            trailingOffset,
        ])
        badgeContainers[dest] = container
        badgeLabels[dest] = label
        badgeLabelInsets[dest] = (leadingInset, trailingInset)
        badgeOffsets[dest] = (topOffset, trailingOffset)
    }

    /// Sets the "needs you" count badge for `dest`. `count <= 0` hides the
    /// badge entirely - no badge is ever shown for a zero/no-signal count,
    /// per PRODUCT.md's "quiet until it matters." Callers own deciding what
    /// "needs you" means for their destination (e.g. open PRs on `.review`,
    /// tasks needing a decision on `.overview`) - this view only renders
    /// whatever number it's given.
    ///
    /// A double-digit (or "99+") count needs its own, tighter sizing - a
    /// captain screenshot showed the badge's fixed single-digit padding/
    /// offset (4pt label insets, pinned 4pt past the button's top-trailing
    /// corner) growing the whole pill wide enough, and far enough outside
    /// the button, to visibly overflow past its icon. `label.font`/the
    /// insets/the offsets all shrink specifically once the string is 2+
    /// characters, pulling the badge back in against the icon; a
    /// single-digit count keeps the original sizing untouched.
    func setBadgeCount(_ count: Int, for dest: RailDestination) {
        guard let container = badgeContainers[dest], let label = badgeLabels[dest] else { return }
        container.isHidden = count <= 0
        guard count > 0 else { return }
        let text = count > 99 ? "99+" : "\(count)"
        label.stringValue = text
        let isMultiDigit = text.count > 1
        label.font = .monospacedDigitSystemFont(ofSize: isMultiDigit ? 8 : 9, weight: .bold)
        if let insets = badgeLabelInsets[dest] {
            insets.leading.constant = isMultiDigit ? 3 : 4
            insets.trailing.constant = isMultiDigit ? -3 : -4
        }
        if let offsets = badgeOffsets[dest] {
            offsets.top.constant = isMultiDigit ? -2 : -4
            offsets.trailing.constant = isMultiDigit ? 2 : 4
        }
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
        let button = NSButton()
        button.cell = CenteredImageAboveButtonCell()
        button.title = host.label
        button.target = self
        button.action = #selector(hostClicked(_:))
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
    /// (fm/grandline-sidebar-nav-polish). This fixed the *horizontal*
    /// centering: `NSButton.attributedTitle` lays out its text using the
    /// attributed string's own paragraph alignment, not the button's
    /// `alignment` property, so an attributed title built with no explicit
    /// alignment defaults to natural/left. Re-verified live (fm/grandline-
    /// rail-followup-fixes) via real rendered geometry - `NSButtonCell.
    /// titleRect(forBounds:)`/`imageRect(forBounds:)` on an actually-active
    /// row - and this part is correct: title/image/bounds center-X all
    /// agree exactly (36pt each in an 84pt-wide rail).
    ///
    /// The captain's follow-up report ("still off-center") turned out to be
    /// a *vertical* bug this paragraph-style fix never touched, and PR
    /// #123's own claim to have fully verified it was wrong - a real
    /// rendered bitmap of the active row (not just constraint math) showed
    /// the highlight box with a large empty gap above the icon and the
    /// label crammed against the box's bottom edge. Root cause:
    /// `NSButtonCell`'s built-in `.imageAbove` layout does not vertically
    /// center the image+title content block within the cell's actual
    /// resolved bounds - `imageRect`/`titleRect` anchor the content near a
    /// fixed low offset regardless of how tall the button's bounds actually
    /// are (confirmed live: every row's cell resolves several points taller
    /// than the requested 52pt height - an unrelated `NSButtonCell` quirk
    /// for borderless `.imageAbove` buttons - and 100% of that slack lands
    /// above the content, never split between top and bottom). No amount of
    /// `.paragraphStyle`/`alignment` tuning can fix this, since both of
    /// those only affect the glyph run *within* the rect the cell already
    /// decided on, not the rect itself. Fixed with `CenteredImageAboveButtonCell`
    /// (below), a small `NSButtonCell` subclass that overrides `imageRect`/
    /// `titleRect` to explicitly center the image-above-title block, both
    /// horizontally and vertically, within whatever bounds the button
    /// actually resolves to - verified by re-running the same real-bitmap
    /// render and confirming the gap above the icon and below the label are
    /// now equal.
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

        // "Setup" itself highlights whenever one of its sub-items
        // (Bootstrap/Updates) is the active destination - it has no
        // `RailDestination` of its own, so it isn't covered by the `buttons`
        // loop above.
        let setupIsActive = activeHostID == nil && (active == .updates || active == .bootstrap)
        let setupColor = setupIsActive ? accent : ink.withAlphaComponent(0.65)
        setupButton.contentTintColor = setupColor
        setupButton.attributedTitle = attributedRowTitle("Setup", color: setupColor)
        setupButton.layer?.backgroundColor = (setupIsActive ? accentTint : .clear).cgColor
        avatar.contentTintColor = ink
        avatar.layer?.backgroundColor = HelmTheme.nsColor(theme.chromeLineHex).withAlphaComponent(0.4).cgColor
    }
}

/// The "Setup" flyout's content (fm/grandline-rail-setup-group) - a small,
/// themed popover listing Bootstrap and Updates as icon+label rows,
/// side-by-side rather than icon-above-label (this is a horizontal list, not
/// another rail column). Reuses `IconTileView`/`HoverHighlightView` from
/// `HelmUIComponents.swift`, the same building blocks Settings/Updates/
/// Bootstrap/Vault already use, so the flyout reads as this app's own chrome
/// rather than a generic system menu. Each row is a plain `NSClickGestureRecognizer`
/// on a `HoverHighlightView` containing no nested real control, so there's no
/// hit-testing ambiguity between a gesture recognizer and a button (see the
/// Vault section's header comment on that exact hazard).
private final class SetupFlyoutViewController: NSViewController {
    private let destinations: [RailDestination]
    private let onHoverChange: (Bool) -> Void
    private let onSelect: (RailDestination) -> Void
    private var themeObservation: ThemeObservation?

    init(destinations: [RailDestination], onHoverChange: @escaping (Bool) -> Void, onSelect: @escaping (RailDestination) -> Void) {
        self.destinations = destinations
        self.onHoverChange = onHoverChange
        self.onSelect = onSelect
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not supported")
    }

    deinit {
        if let themeObservation { ThemeManager.shared.unobserve(themeObservation) }
    }

    override func loadView() {
        let root = HoverTrackingView()
        root.wantsLayer = true
        root.onHoverChange = { [weak self] isHovering in self?.onHoverChange(isHovering) }
        view = root

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 6),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -6),
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 6),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -6),
        ])

        var rowIcons: [IconTileView] = []
        for dest in destinations {
            let row = HoverHighlightView()
            row.cornerRadius = 8
            row.translatesAutoresizingMaskIntoConstraints = false

            let icon = IconTileView(size: 26, cornerRadius: 7)
            icon.configure(symbol: dest.symbol, tint: .accent, pointSize: 12)
            rowIcons.append(icon)

            let label = NSTextField(labelWithString: dest.title)
            label.font = .systemFont(ofSize: 12, weight: .medium)

            let rowStack = NSStackView(views: [icon, label])
            rowStack.orientation = .horizontal
            rowStack.spacing = 8
            rowStack.alignment = .centerY
            rowStack.translatesAutoresizingMaskIntoConstraints = false
            row.addSubview(rowStack)
            NSLayoutConstraint.activate([
                rowStack.topAnchor.constraint(equalTo: row.topAnchor, constant: 6),
                rowStack.bottomAnchor.constraint(equalTo: row.bottomAnchor, constant: -6),
                rowStack.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 8),
                rowStack.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -12),
                row.widthAnchor.constraint(equalToConstant: 168),
            ])

            let recognizer = NSClickGestureRecognizer(target: self, action: #selector(rowClicked(_:)))
            row.addGestureRecognizer(recognizer)
            row.identifier = NSUserInterfaceItemIdentifier(String(RailDestination.allCases.firstIndex(of: dest) ?? 0))

            stack.addArrangedSubview(row)
        }

        themeObservation = ThemeManager.shared.observe { [weak root] theme in
            root?.layer?.backgroundColor = HelmTheme.nsColor(theme.chromeBackgroundHex).cgColor
            let ink = HelmTheme.nsColor(theme.chromeInkHex)
            let hoverTint = HelmTheme.nsColor(theme.chromeLineHex).withAlphaComponent(theme.mode == .dark ? 0.25 : 0.5)
            for icon in rowIcons { icon.applyTheme(theme) }
            for case let row as HoverHighlightView in stack.arrangedSubviews {
                row.normalColor = .clear
                row.hoverColor = hoverTint
                for case let rowStack as NSStackView in row.subviews {
                    for case let label as NSTextField in rowStack.arrangedSubviews {
                        label.textColor = ink
                    }
                }
            }
        }
    }

    @objc private func rowClicked(_ sender: NSClickGestureRecognizer) {
        guard let view = sender.view,
              let idString = view.identifier?.rawValue,
              let index = Int(idString) else { return }
        onSelect(RailDestination.allCases[index])
    }

}

/// A plain `NSButton` that reports mouse-enter/exit via a closure instead of
/// a click target/action - what the "Setup" rail button uses so its flyout
/// opens on hover (fm/grandline-rail-setup-group). `.activeAlways` rather
/// than `HoverHighlightView`'s own `.activeInKeyWindow` (fine there, since
/// its rows only ever live inside the always-key main window) because this
/// button's hover state has to stay correct even while a separate popover
/// window is transiently key.
private final class HoverTrackingButton: NSButton {
    var onHoverChange: ((Bool) -> Void)?
    private var trackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { onHoverChange?(true) }
    override func mouseExited(with event: NSEvent) { onHoverChange?(false) }
}

/// Same idea as `HoverTrackingButton`, for the flyout's own content root -
/// lets `IconRailController` know when the cursor has moved from the Setup
/// button into the flyout itself, so the hover-out close timer gets
/// cancelled instead of dismissing the flyout out from under the cursor.
private final class HoverTrackingView: NSView {
    var onHoverChange: ((Bool) -> Void)?
    private var trackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { onHoverChange?(true) }
    override func mouseExited(with event: NSEvent) { onHoverChange?(false) }
}

/// See `IconRailController.centeredTitleStyle`'s doc comment for the full
/// investigation. `NSButtonCell`'s stock `.imageAbove` layout anchors the
/// image+title block near a fixed low offset instead of centering it
/// vertically in the cell's actual bounds, so any extra height the button
/// resolves to beyond its own internal "ideal" size shows up entirely as a
/// dead gap above the icon - invisible on an inactive row (no background to
/// reveal it against) but obvious on the active row's tinted highlight.
/// This subclass computes the image+title block's total height itself and
/// centers it directly, both horizontally and vertically, in whatever
/// bounds the button actually has.
private final class CenteredImageAboveButtonCell: NSButtonCell {
    var iconSize: CGFloat = 20
    var contentSpacing: CGFloat = 4

    private func measuredTitleHeight() -> CGFloat {
        let titleFont = font ?? .systemFont(ofSize: 10, weight: .medium)
        return ceil(titleFont.ascender - titleFont.descender)
    }

    /// The smaller-y edge of the vertically-centered image+title block.
    /// Note: for this cell, a *smaller* y renders visually *higher* -
    /// confirmed empirically via a real rendered bitmap (the stock,
    /// un-centered cell placed its image at the smaller-y sub-range and its
    /// title at the larger-y sub-range, and rendered image-above-title as
    /// `.imageAbove` promises) - so the image occupies the low end of this
    /// range and the title the high end, not the other way around.
    private func contentLow(in bounds: NSRect) -> CGFloat {
        let contentHeight = iconSize + contentSpacing + measuredTitleHeight()
        return bounds.midY - contentHeight / 2
    }

    override func imageRect(forBounds theRect: NSRect) -> NSRect {
        let low = contentLow(in: theRect)
        return NSRect(x: theRect.midX - iconSize / 2, y: low, width: iconSize, height: iconSize)
    }

    override func titleRect(forBounds theRect: NSRect) -> NSRect {
        let titleHeight = measuredTitleHeight()
        let low = contentLow(in: theRect) + iconSize + contentSpacing
        return NSRect(x: theRect.minX, y: low, width: theRect.width, height: titleHeight)
    }
}
