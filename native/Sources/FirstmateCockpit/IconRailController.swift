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
/// (-> Updates, Bootstrap flyout), avatar. Both cases remain real
/// `RailDestination`s for switching purposes - only their rail position/
/// visibility changed; see `IconRailController.buildSetupButton()`/
/// `showSetupFlyout()`.
/// `fm/grandline-avatar-menu-and-setup-guide` removed `.settings`'s own
/// standalone rail row entirely - it is still a real `RailDestination` for
/// switching purposes (`AppShellController.show(.settings)` is unchanged),
/// but its only entry point now is a "Settings" row inside the avatar
/// popover, alongside "Logout" (see `AvatarLogoutPopoverController`). This
/// continues the same crowding-reduction direction as the Setup group
/// consolidation above - one less item in the bottom-anchored utility group.
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

    /// `fm/grandline-lock-and-rail-fixes`: a rework of the rail's spacing
    /// rhythm after live captain feedback that the rail reads crowded/uneven
    /// at real-world density (all 11 destinations + a HOSTS section + badges,
    /// in both themes) - the density this rail was never actually tuned
    /// against before (earlier tuning passes, e.g. fm/grandline-rail-followup-fixes'
    /// centering/badge/divider work, all happened against a much shorter
    /// rail). Three named constants replace what used to be a scatter of
    /// inconsistent magic numbers (52/4/10/12/14 all doing similar jobs):
    /// `rowHeight` (was a hardcoded 52 on every button type - a touch
    /// generous now that there are this many rows to fit), `rowSpacing`
    /// (the gap between two rows *within* the same group, was an
    /// inconsistent 4 in some places), and `sectionGap` (the gap *between*
    /// groups - mark/nav/hosts/utility/avatar - was inconsistently 10, 12,
    /// or 14 depending on which boundary). Reads as tighter within a group
    /// and more deliberately spaced between groups, rather than the old
    /// near-uniform tightness that made every boundary look the same.
    fileprivate static let rowHeight: CGFloat = 46
    fileprivate static let rowSpacing: CGFloat = 3
    fileprivate static let sectionGap: CGFloat = 14

    /// `fm/grandline-rail-unified-rework`: the icon block's own geometry,
    /// pulled out to `fileprivate` (rather than left as private stored
    /// properties duplicated on `CenteredImageAboveButtonCell`, or a fixed
    /// offset independently guessed for the badge overlay) so the cell that
    /// actually draws the icon and the badge overlay that has to anchor to
    /// it read the exact same numbers. Before this task, three separate row
    /// builders (`railButton(for:)`, `buildSetupButton()`,
    /// `hostRailButton(for:)`) each hand-built an `NSButton` with the same
    /// intent but no shared function enforcing it, which is how Setup's
    /// centering and the badge's anchor point drifted out of sync with the
    /// rest of the rail - see `buildRailRowButton(...)` and `attachBadge(...)`
    /// below.
    fileprivate static let iconSize: CGFloat = 20
    fileprivate static let contentSpacing: CGFloat = 4
    fileprivate static let titleFontSize: CGFloat = 10

    fileprivate static var titleFont: NSFont { .systemFont(ofSize: titleFontSize, weight: .medium) }

    /// Same formula `CenteredImageAboveButtonCell.measuredTitleHeight()` uses
    /// - kept here so both that cell and the badge anchor read one number.
    fileprivate static var titleHeight: CGFloat { ceil(titleFont.ascender - titleFont.descender) }

    fileprivate static var contentHeight: CGFloat { iconSize + contentSpacing + titleHeight }

    /// The icon's own vertical center, expressed as an offset from the row's
    /// vertical center (negative = above center, matching how a positive
    /// `constant` on a `centerYAnchor` equality moves a view *down* in every
    /// other constraint in this file). `attachBadge` anchors its badge to an
    /// invisible guide placed at exactly this offset - the icon's own real
    /// position - rather than a fixed inset off the button's outer bounds
    /// (which are taller than the visible content thanks to the
    /// `NSButtonCell` `.imageAbove` quirk documented on
    /// `CenteredImageAboveButtonCell` below, and were never reliably the same
    /// distance from the icon itself).
    fileprivate static var iconCenterYOffsetFromRowCenter: CGFloat {
        let topGap = (rowHeight - contentHeight) / 2
        let iconCenterFromTop = topGap + iconSize / 2
        return iconCenterFromTop - rowHeight / 2
    }

    /// `fm/grandline-rail-overflow-and-spacing` tried to cap the HOSTS-to-
    /// utility gap with a `[sectionGap, sectionGapMax]` *range* on
    /// `toolsButton`'s top, paired with a soft (priority 800) pin holding
    /// `avatar` near the window's bottom edge. That did not actually fix the
    /// bug (`fm/grandline-rail-spacing-fullheight`, this task): a captain
    /// screenshot on a maximized window still showed a large dead gap - not
    /// between the divider and Tools (that boundary genuinely did stay
    /// capped), but *inside* the HOSTS section itself, below the pinned host
    /// icons. Root cause, confirmed live with a temporary debug probe
    /// (reverted before commit) that laid the real `IconRailController` out
    /// at several window heights with a fresh instance per height: `hostsStack`
    /// has no height constraint of its own, so it isn't actually fixed-size -
    /// its *top* is pinned via a required chain all the way from the
    /// window's top edge (mark -> nav -> hosts label), which necessarily
    /// moves up in absolute terms as the window grows taller, while its
    /// *bottom* (via `dividerBelowHosts`) sits inside the old range
    /// constraint tying it close to `toolsButton`, whose position was
    /// anchored from the *bottom* via the soft avatar pin and therefore
    /// stayed near-fixed regardless of window height. With required
    /// equalities pulling its top up and its bottom staying put, `hostsStack`
    /// itself became the de facto flexible spacer the task brief predicted -
    /// just realized as an unconstrained stack view's own frame stretching,
    /// not a dedicated spacer subview. Measured with 2 pinned hosts (2 fixed-
    /// height buttons, ~103pt of real content): `hostsStack.frame.height` was
    /// 133pt at a 900pt window, 433pt at 1200pt, 833pt at 1600pt, 1433pt at
    /// 2200pt - growing 1:1 with window height, all of it dead space below
    /// the actual host icons.
    ///
    /// The fix removes the range/soft-pin mechanism entirely and makes the
    /// *whole* rail (mark -> nav -> HOSTS -> utility group -> avatar) one
    /// single chain of required, fixed `sectionGap`/`rowSpacing` equalities
    /// anchored only from the window's top edge - exactly like the daily-use
    /// section and the per-host block already were, and like every other
    /// boundary in the rail already reads. With no free segment anywhere in
    /// that chain, nothing can stretch: `avatar`'s position (the chain's last
    /// link) is fully determined top-down, and any slack in a tall window
    /// necessarily appears below it, between `avatar` and the window's
    /// bottom edge - never inside a section. Verified live (same probe,
    /// swept 720/900/1200/1600/2200pt) that `hostsStack`'s height now stays
    /// exactly its natural content size at every height tested, and that the
    /// gap below `avatar` grows 1:1 with window height instead. This also
    /// simplifies away the graceful-degradation tradeoff the old range/soft-
    /// pin design was built around: a too-short window (below the rail's own
    /// required content height, itself a separate, already-documented, still-
    /// open issue - see this file's own header) behaved identically before
    /// and after this change, confirmed by the same probe - the required
    /// top-down chain already overflowed the window in both designs whenever
    /// content didn't fit, so switching to a purely top-anchored chain does
    /// not regress that pre-existing case.

    var onSelect: ((RailDestination) -> Void)?

    /// Fix 3 (fixes4): clicking a saved host's pinned rail icon connects to
    /// it directly, same as the Hosts list's own Connect action.
    var onConnectHost: ((Host) -> Void)?

    /// fm/grandline-app-lock: fired only after both logout confirmations
    /// (see `avatarClicked`/`confirmLogout`) - the app delegate's
    /// `AppLockController` is what actually locks the app.
    var onLogoutRequested: (() -> Void)?

    private(set) var active: RailDestination = .console

    /// Fix 1 (dedicated host pages): set instead of `active` while a host's
    /// own page is showing, so `restyle` can un-highlight every fixed
    /// destination and highlight that host's icon instead. `nil` whenever a
    /// fixed `RailDestination` is current.
    private(set) var activeHostID: UUID?
    private var buttons: [RailDestination: NSButton] = [:]
    /// `fm/grandline-rail-unified-rework`: a `HoverTrackingButton` (the same
    /// hover-feedback mechanism `setupButton`/`hostsOverflowButton` already
    /// use) rather than a plain `NSButton`, so the avatar's accent ring can
    /// brighten on hover - see `avatarGradientLayer`/`avatarRingLayer` below
    /// and `restyle(_:)`'s avatar section. Click behavior (opening
    /// `avatarPopover`) is unchanged; `HoverTrackingButton` only adds hover
    /// tracking on top of ordinary `NSButton` target/action.
    private let avatar = HoverTrackingButton()

    /// A subtle gradient (flat avatar color -> the active theme's accent),
    /// replacing the old flat-fill circle - and a soft accent ring
    /// (`avatar.layer?.borderColor`/`borderWidth`, brightening on hover) per
    /// the captain-approved visual-polish pass. Both are sized once (the
    /// avatar's own width/height are fixed 36pt constraints, so its `bounds`
    /// never change) rather than re-laid-out on every resize.
    private let avatarGradientLayer = CAGradientLayer()
    private var avatarIsHovering = false

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

    /// The saved hosts currently pinned to the rail, and the vertical stack
    /// they render into - below the fixed destinations, above the utility
    /// group. Rebuilt wholesale on every `setHosts` call (via
    /// `HostStore.observe`), which keeps this trivially correct on
    /// add/rename/delete at the cost of a full rebuild - fine for the
    /// handful of hosts a rail like this is meant to hold.
    private var hosts: [Host] = []
    private let hostsStack = NSStackView()
    private var hostButtons: [UUID: NSButton] = [:]

    /// The "more hosts" row (`fm/grandline-lock-and-rail-fixes`) shown in
    /// place of the 2nd+ pinned host - see `setHosts(_:)`'s doc comment.
    /// Same hover-flyout mechanism as `setupButton`/`setupPopover` below.
    private let hostsOverflowButton = HoverTrackingButton()
    private var hostsOverflowPopover: NSPopover?
    private var hostsOverflowCloseWorkItem: DispatchWorkItem?

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
    /// position/visibility changed. Clicking "Setup" reveals them as a small
    /// flyout `NSPopover` anchored to the button's trailing edge - the same
    /// click-to-toggle pattern `avatarClicked`/`avatarPopover` use
    /// (`fm/grandline-rail-unified-rework`, live captain feedback superseding
    /// this button's original hover-to-open design). An in-rail expanding
    /// drawer was rejected even earlier (first pass of this button): it
    /// pushed every row below it up and down as it opened/closed, disrupting
    /// the rail's fixed divider rhythm - a flyout to the side leaves the
    /// rail's own layout untouched, which is still true of the click-driven
    /// version. See `buildSetupButton()`/`setupClicked()`/`showSetupFlyout()`.
    /// "Setup" itself is a pure UI toggle, not a `RailDestination` - it never
    /// calls `onSelect`. `setupButton`'s type (`HoverTrackingButton`) is a
    /// holdover from the earlier hover-driven design - harmless to keep since
    /// it's just an `NSButton` subclass, but its hover callback is unused now.
    private let setupButton = HoverTrackingButton()
    private var setupPopover: NSPopover?

    /// Still used by the "more hosts" overflow flyout below (`hostsOverflowButton`),
    /// which remains hover-driven - only "Setup" moved to click.
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

    /// The rail's own sailboat mark, above `navStack` - stored (rather than a
    /// `loadView`-local `let`) so `setUnlocked(_:)` can restyle/animate it
    /// after the fact. `fm/grandline-lock-and-rail-fixes`: bold + a subtle
    /// continuous bob once the captain is past the lock screen, static/inert
    /// while locked - a small "welcome back, the ship is sailing" touch,
    /// captain-requested after the app lock (PR #129) shipped. Reuses
    /// `LockScreenController.startAnimationsIfNeeded`'s own bob recipe (a
    /// `CAKeyframeAnimation` on `transform`, sine-based offset + a touch of
    /// rotation) rather than inventing a second one - same "gentle bob" the
    /// lock screen's own boat already uses, just smaller-amplitude since this
    /// mark is a fixed 34x34pt rail icon, not a 72pt centerpiece.
    private let mark = NSImageView()
    private var isUnlockedForMark = false

    /// Margin the top group (logo mark) keeps from the window's top edge,
    /// and the bottom group (avatar) keeps from the window's bottom edge -
    /// see the two-anchor-groups layout doc comment on `loadView` below.
    private static let railEdgeMargin: CGFloat = 14

    /// `fm/grandline-rail-unified-rework`: **captain override, live review**
    /// - superseding this task's own original requirement 3 (vertically
    /// centering the whole rail as one block). The captain watched the
    /// centered version running and asked for a different, two-anchor-groups
    /// layout instead: the top group (logo mark, daily-use rows, HOSTS
    /// section) pins to the window's *top* edge exactly as it always has;
    /// the bottom group (utility rows + avatar) pins to the window's
    /// *bottom* edge; any leftover vertical space in a tall window lives
    /// entirely in the one gap *between* those two groups (between the end
    /// of the HOSTS section and the start of the utility group), not
    /// distributed as symmetric centering and not collecting below the
    /// avatar (PR #132's bug, which prompted requirement 3 in the first
    /// place). Each group is its own single rigid chain of required, fixed
    /// equalities - unchanged from the fullheight fix's own reasoning for why
    /// no individual section within a group can stretch (see `sectionGap`'s
    /// doc comment) - anchored independently from the top and the bottom of
    /// `root`. The *only* new piece is the connector between the two groups:
    /// a required `>=` inequality (`toolsButton.topAnchor >= dividerBelowHosts.bottomAnchor
    /// + sectionGap`), not an equality and not a soft/range constraint. Since
    /// both endpoints of that inequality are already fully, independently
    /// determined by their own group's rigid chain, the "flex" is not a
    /// stretchy spacer view competing with anything else for slack - it's
    /// simply whatever room is left between two fixed points, which is what
    /// keeps this from regressing into PR #131/#132's specific bug (where a
    /// range constraint *and* a soft bottom-pin together let `hostsStack`
    /// itself, which has no explicit height, become the thing that absorbed
    /// slack). Here `hostsStack`'s height is never in question - it's fully
    /// pinned within the top group's own rigid chain, independent of window
    /// height.
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

        mark.image = NSImage(systemSymbolName: "sailboat", accessibilityDescription: "Manjesh Grand Line")
        mark.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 17, weight: .medium)
        mark.wantsLayer = true
        mark.layer?.cornerRadius = 10
        mark.imageScaling = .scaleProportionallyDown
        mark.translatesAutoresizingMaskIntoConstraints = false

        let navStack = NSStackView()
        navStack.orientation = .vertical
        navStack.spacing = Self.rowSpacing
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
        hostsStack.spacing = Self.rowSpacing
        hostsStack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(hostsStack)

        // Tools (cockpit-tools-page-core) sits below the dynamic per-host
        // icon block, directly above Vault, which sits directly above Docs,
        // which sits directly above the "Setup" group (fm/grandline-rail-setup-group
        // - Bootstrap and Updates, collapsed into one entry, see
        // `buildSetupButton()`), which in turn sits directly above the
        // avatar - Settings no longer has its own row here at all
        // (fm/grandline-avatar-menu-and-setup-guide moved it into the avatar
        // popover, see `AvatarLogoutPopoverController`). All of these are
        // still real `RailDestination` cases for switching purposes
        // (Bootstrap/Updates/Settings included); only their vertical
        // position (or, for Settings, entry point) moves out of `navStack`.
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

        // fm/grandline-rail-utility-separators: a hairline separator between
        // each utility row (Tools | Vault | Docs | Updates/Bootstrap "Setup"),
        // matching the daily-use group's own `NSBox(.separator)` treatment
        // (fm/grandline-rail-followup-fixes) - captain ask, scoped to this
        // group only. These buttons aren't in a stack view (they're
        // individually positioned so the per-host block above them can grow),
        // so each divider is a plain sibling view sized/centered the same way
        // the daily-use dividers are (`navStack.widthAnchor - 16`, i.e.
        // `Self.width - 28` here since these buttons live directly in
        // `root` rather than an inset stack).
        func utilityDivider() -> NSBox {
            let divider = NSBox()
            divider.boxType = .separator
            divider.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(divider)
            divider.widthAnchor.constraint(equalToConstant: Self.width - 28).isActive = true
            divider.centerXAnchor.constraint(equalTo: root.centerXAnchor).isActive = true
            return divider
        }
        // `fm/grandline-rail-unified-rework`: marks the utility group's own
        // top edge, mirroring `dividerAboveNav`'s role for the daily-use
        // group below the logo mark - without it, the (now potentially
        // large, per the two-anchor-groups layout above) gap between the
        // HOSTS section and Tools had no visual edge at all, reading as a
        // missing divider rather than an intentional flexible gap.
        let dividerAboveTools = utilityDivider()
        let dividerToolsVault = utilityDivider()
        let dividerVaultDocs = utilityDivider()
        let dividerDocsSetup = utilityDivider()
        // fm/grandline-vault-header-and-avatar-divider: same treatment,
        // between the last utility row ("Setup", since
        // fm/grandline-avatar-menu-and-setup-guide moved Settings off this
        // chain) and the avatar pinned at the very bottom - the one boundary
        // in this bottom-up chain that didn't have one yet.
        let dividerSetupAvatar = utilityDivider()

        avatar.title = "M"
        avatar.isBordered = false
        avatar.wantsLayer = true
        avatar.layer?.masksToBounds = true
        avatar.layer?.cornerRadius = 18
        avatar.font = .systemFont(ofSize: 13, weight: .semibold)
        avatar.target = self
        avatar.action = #selector(avatarClicked)
        avatar.toolTip = "Manjesh Grand Line"
        avatar.translatesAutoresizingMaskIntoConstraints = false
        avatar.onHoverChange = { [weak self] isHovering in
            self?.avatarIsHovering = isHovering
            self?.restyleAvatar(ThemeManager.shared.theme)
        }
        // `fm/grandline-rail-unified-rework`: the gradient background
        // (flat avatar color -> the active theme's accent) replaces the old
        // flat `layer?.backgroundColor` fill - inserted once here since the
        // avatar's size is fixed (36x36 via the constraints below, so its
        // bounds never change and the gradient layer's frame never needs
        // re-laying-out). `restyleAvatar` re-tunes its colors on every theme
        // change and hover transition; it never re-adds the layer.
        avatarGradientLayer.frame = CGRect(x: 0, y: 0, width: 36, height: 36)
        avatarGradientLayer.cornerRadius = 18
        avatarGradientLayer.startPoint = CGPoint(x: 0.2, y: 0.9)
        avatarGradientLayer.endPoint = CGPoint(x: 0.9, y: 0.1)
        avatar.layer?.insertSublayer(avatarGradientLayer, at: 0)

        root.addSubview(mark)
        root.addSubview(navStack)
        root.addSubview(avatar)

        NSLayoutConstraint.activate([
            view.widthAnchor.constraint(equalToConstant: Self.width),

            // Top group: pinned to the window's top edge exactly as it
            // always has been - unchanged from before this task.
            mark.topAnchor.constraint(equalTo: root.topAnchor, constant: Self.railEdgeMargin),
            mark.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            mark.widthAnchor.constraint(equalToConstant: 34),
            mark.heightAnchor.constraint(equalToConstant: 34),

            dividerAboveNav.topAnchor.constraint(equalTo: mark.bottomAnchor, constant: Self.sectionGap),
            dividerAboveNav.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
            dividerAboveNav.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14),

            navStack.topAnchor.constraint(equalTo: dividerAboveNav.bottomAnchor, constant: Self.sectionGap),
            navStack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 6),
            navStack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -6),

            // Divider + "HOSTS" label + divider bracket the per-host icon
            // block, reading as a visually distinct section between
            // daily-use (above) and utility (below) - captain ask: simple
            // hairline dividers, no new visual language.
            dividerAboveHosts.topAnchor.constraint(equalTo: navStack.bottomAnchor, constant: Self.sectionGap),
            dividerAboveHosts.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
            dividerAboveHosts.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14),

            hostsSectionLabelWrapper.topAnchor.constraint(equalTo: dividerAboveHosts.bottomAnchor, constant: 8),
            hostsSectionLabelWrapper.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 6),
            hostsSectionLabelWrapper.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -6),

            hostsStack.topAnchor.constraint(equalTo: hostsSectionLabelWrapper.bottomAnchor, constant: 6),
            hostsStack.centerXAnchor.constraint(equalTo: root.centerXAnchor),

            dividerBelowHosts.topAnchor.constraint(equalTo: hostsStack.bottomAnchor, constant: Self.sectionGap),
            dividerBelowHosts.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
            dividerBelowHosts.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14),

            // The one connector between the two groups (captain override,
            // see this method's own doc comment above): a required minimum
            // gap, not an equality - both `dividerBelowHosts.bottomAnchor`
            // (top group, anchored from `root.topAnchor`) and
            // `toolsButton.topAnchor` (bottom group, anchored from
            // `root.bottomAnchor` via `avatar` below) are each already fully
            // determined by their own group's rigid chain, so this
            // inequality never has to resolve any actual stretch - any
            // leftover window height just becomes extra room here.
            dividerAboveTools.topAnchor.constraint(greaterThanOrEqualTo: dividerBelowHosts.bottomAnchor, constant: Self.sectionGap),
            toolsButton.topAnchor.constraint(equalTo: dividerAboveTools.bottomAnchor, constant: Self.sectionGap),

            toolsButton.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            vaultButton.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            docsButton.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            setupGroup.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            avatar.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            avatar.widthAnchor.constraint(equalToConstant: 36),
            avatar.heightAnchor.constraint(equalToConstant: 36),

            // Bottom group: pinned to the window's bottom edge via `avatar`
            // - the one new anchor point this override adds. Everything
            // above it (`setupGroup`, `docsButton`, `vaultButton`,
            // `toolsButton`, and their dividers) is positioned by the same
            // required, fixed bottom-up chain this rail already had, just
            // now anchored from `root.bottomAnchor` instead of transitively
            // from `dividerBelowHosts`.
            avatar.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -Self.railEdgeMargin),
            dividerSetupAvatar.bottomAnchor.constraint(equalTo: avatar.topAnchor, constant: -Self.sectionGap),
            setupGroup.bottomAnchor.constraint(equalTo: dividerSetupAvatar.topAnchor, constant: -Self.sectionGap),
            dividerDocsSetup.bottomAnchor.constraint(equalTo: setupGroup.topAnchor, constant: -Self.rowSpacing),
            docsButton.bottomAnchor.constraint(equalTo: dividerDocsSetup.topAnchor, constant: -Self.rowSpacing),
            dividerVaultDocs.bottomAnchor.constraint(equalTo: docsButton.topAnchor, constant: -Self.rowSpacing),
            vaultButton.bottomAnchor.constraint(equalTo: dividerVaultDocs.topAnchor, constant: -Self.rowSpacing),
            dividerToolsVault.bottomAnchor.constraint(equalTo: vaultButton.topAnchor, constant: -Self.rowSpacing),
            toolsButton.bottomAnchor.constraint(equalTo: dividerToolsVault.topAnchor, constant: -Self.rowSpacing),
        ])

        restyle(ThemeManager.shared.theme)
        setActive(active)
    }

    /// Builds a rail row's `NSButton`: icon above a small text label, both
    /// centered, sized to the full rail content width so the tinted
    /// active-state background reads as a full-width row rather than a small
    /// icon-sized square. Built with `imagePosition = .imageAbove` (not a
    /// separate icon+label stack overlaid on a button) so the existing
    /// single-view `contentTintColor`/`layer?.backgroundColor` restyle path
    /// in `restyle(_:)` covers every row with one mechanism.
    ///
    /// The one function every rail row - daily-use, utility, and per-host
    /// alike - builds through (`fm/grandline-rail-unified-rework`). Before
    /// this task, `railButton(for:)`, `buildSetupButton()`, and
    /// `hostRailButton(for:)` each hand-rolled the same `NSButton` shape
    /// independently; nothing enforced they stayed identical, which is why
    /// Setup's centering could drift from the rest of the rail's rows even
    /// though every row was *meant* to look the same. Callers supply only
    /// what genuinely differs between row kinds (title, symbol, point size,
    /// tooltip, and - for a row with a pre-existing persistent identity like
    /// `setupButton`/`hostsOverflowButton`, which need to keep their own
    /// `HoverTrackingButton` instance across rebuilds - `existingButton`) and
    /// wire up their own target/action/tag/identifier afterward.
    private func buildRailRowButton(
        title: String,
        symbol: String,
        pointSize: CGFloat = 17,
        tooltip: String,
        existingButton: NSButton? = nil
    ) -> NSButton {
        let button = existingButton ?? NSButton()
        button.cell = CenteredImageAboveButtonCell()
        button.title = title
        button.isBordered = false
        button.wantsLayer = true
        button.layer?.cornerRadius = 10
        button.imagePosition = .imageAbove
        button.imageScaling = .scaleProportionallyDown
        button.alignment = .center
        button.font = Self.titleFont
        button.lineBreakMode = .byTruncatingTail
        let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .regular)
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)?
            .withSymbolConfiguration(config)
        button.toolTip = tooltip
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: Self.width - 12),
            button.heightAnchor.constraint(equalToConstant: Self.rowHeight),
        ])
        return button
    }

    /// Every row also gets a "needs you" count badge overlay
    /// (fm/grandline-sidebar-badges) - cheap to attach on all of them (hidden
    /// by default) rather than threading a second "does this destination
    /// want a badge" flag through here; only `setBadgeCount` ever makes one
    /// visible.
    private func railButton(for dest: RailDestination) -> NSButton {
        let button = buildRailRowButton(title: dest.title, symbol: dest.symbol, tooltip: dest.title)
        button.target = self
        button.action = #selector(navClicked(_:))
        button.tag = RailDestination.allCases.firstIndex(of: dest) ?? 0
        attachBadge(to: button, dest: dest)
        return button
    }

    /// Builds the "Setup" rail button (fm/grandline-rail-setup-group,
    /// switched from hover- to click-driven by `fm/grandline-rail-unified-rework`
    /// per live captain feedback - "similar to profile icon", i.e. the same
    /// click-to-toggle pattern `avatarClicked` already uses, superseding the
    /// original hover-to-open design this button shipped with). "Setup" has
    /// no destination of its own and never calls `onSelect` directly - it's a
    /// plain UI toggle occupying the rail slot the two standalone icons used
    /// to. Otherwise built exactly like `railButton(for:)`, minus the tag
    /// (there's no `RailDestination` case to dispatch through).
    private func buildSetupButton() -> NSButton {
        // "wrench.adjustable" - wrench-family like Tools' own icon, but a
        // visually distinct glyph so the two never look like duplicates in
        // the rail; also doesn't collide with Settings' `gearshape`.
        let button = buildRailRowButton(
            title: "Setup",
            symbol: "wrench.adjustable",
            tooltip: "Setup (Bootstrap, Updates)",
            existingButton: setupButton
        )
        button.target = self
        button.action = #selector(setupClicked)
        return button
    }

    /// Toggles the Updates/Bootstrap flyout - the same open-if-closed/
    /// close-if-open click pattern `avatarClicked` uses.
    @objc private func setupClicked() {
        if setupPopover?.isShown == true {
            setupPopover?.performClose(nil)
        } else {
            showSetupFlyout()
        }
    }

    /// Shows the Updates/Bootstrap flyout, anchored to the Setup button's
    /// trailing edge (captain correction from an earlier in-rail expanding
    /// drawer - see the property's doc comment above). `.transient` (an
    /// ordinary click-outside-to-dismiss popover, matching `avatarPopover`'s
    /// own behavior) now that opening is click-driven, not hover-driven.
    /// Selecting a row dispatches through `onSelect`/`setActive` exactly like
    /// clicking either destination's old standalone icon did, then closes
    /// the flyout.
    private func showSetupFlyout() {
        let popover = NSPopover()
        popover.behavior = .transient
        popover.appearance = NSAppearance(named: ThemeManager.shared.theme.mode == .dark ? .darkAqua : .aqua)
        popover.contentViewController = SetupFlyoutViewController(
            destinations: [.updates, .bootstrap],
            onHoverChange: { _ in },
            onSelect: { [weak self] dest in
                self?.setupPopover?.performClose(nil)
                self?.setActive(dest)
                self?.onSelect?(dest)
            }
        )
        popover.show(relativeTo: setupButton.bounds, of: setupButton, preferredEdge: .maxX)
        setupPopover = popover
    }

    /// Pins a small count-badge overlay near the icon's top-trailing corner
    /// (see the anchor's own doc comment below for exactly where and why).
    /// Hidden by default; only `setBadgeCount` ever shows one. Deliberately a
    /// fixed white-on-systemRed pill rather than a theme-derived `HelmTint` -
    /// unlike a status pill elsewhere in this app, an unread/needs-attention
    /// badge is meant to stand out the same way regardless of which of the
    /// 12 Helm themes is active, matching how macOS itself never re-tints a
    /// Dock badge or Mail's unread count to match the current appearance.
    private func attachBadge(to button: NSButton, dest: RailDestination) {
        // `fm/grandline-rail-unified-rework`: an invisible guide sized and
        // positioned exactly where `CenteredImageAboveButtonCell` draws the
        // icon (`Self.iconCenterYOffsetFromRowCenter`/`Self.iconSize` - the
        // same numbers the cell itself uses, not a second copy). The badge
        // used to anchor off `button`'s own top-trailing corner with a fixed
        // guessed inset - since the button's own bounds are taller than the
        // visible content (the `.imageAbove` quirk documented on
        // `CenteredImageAboveButtonCell`), that corner didn't reliably line
        // up with the icon it was meant to badge, which is what let the
        // Review badge clip the highlight's rounded corner. Anchoring to the
        // icon's own real corner fixes that for every row, not just Review.
        let iconAnchor = NSView()
        iconAnchor.translatesAutoresizingMaskIntoConstraints = false
        button.addSubview(iconAnchor)
        NSLayoutConstraint.activate([
            iconAnchor.centerXAnchor.constraint(equalTo: button.centerXAnchor),
            iconAnchor.centerYAnchor.constraint(equalTo: button.centerYAnchor, constant: Self.iconCenterYOffsetFromRowCenter),
            iconAnchor.widthAnchor.constraint(equalToConstant: Self.iconSize),
            iconAnchor.heightAnchor.constraint(equalToConstant: Self.iconSize),
        ])

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
        // Two live-rendered attempts before this one both anchored the
        // badge by *overlapping* the icon's top-trailing corner by some
        // fixed amount (first `-6`/`6`, matched the button's own guessed
        // corner; then `-12`/`12`; then `-20`/`20`) - all still overlapped
        // `.review`'s `arrow.triangle.branch` glyph, whose ink (confirmed by
        // rendering the symbol standalone and inspecting the bitmap) fills
        // *both* top corners of its 20x20 box almost edge-to-edge (it's a
        // literal upward-pointing fork/branch shape) - there is no
        // corner-overlap amount that clears it, and `-20` also overshot the
        // row's own ~6-7pt of headroom above the icon, clipping the badge
        // against the divider above. The fix: don't overlap the icon box at
        // all. `container.leadingAnchor == iconAnchor.trailingAnchor + gap`
        // places the badge entirely to the *right* of the icon's box -
        // since an SF Symbol always draws within the rect it's given, this
        // can never overlap any icon's ink regardless of that icon's shape.
        // `centerYAnchor` near the icon's own top edge keeps it looking like
        // a corner badge without needing any headroom above the row itself
        // (there's no row-clipping risk left, since the badge no longer
        // extends above the icon's own top edge).
        let leadingOffset = container.leadingAnchor.constraint(equalTo: iconAnchor.trailingAnchor, constant: 3)
        let centerYOffset = container.centerYAnchor.constraint(equalTo: iconAnchor.topAnchor, constant: 2)
        NSLayoutConstraint.activate([
            leadingInset,
            trailingInset,
            label.topAnchor.constraint(equalTo: container.topAnchor, constant: 1),
            label.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -1),
            container.heightAnchor.constraint(equalToConstant: 16),
            container.widthAnchor.constraint(greaterThanOrEqualToConstant: 16),
            leadingOffset,
            centerYOffset,
        ])
        badgeContainers[dest] = container
        badgeLabels[dest] = label
        badgeLabelInsets[dest] = (leadingInset, trailingInset)
    }

    /// Sets the "needs you" count badge for `dest`. `count <= 0` hides the
    /// badge entirely - no badge is ever shown for a zero/no-signal count,
    /// per PRODUCT.md's "quiet until it matters." Callers own deciding what
    /// "needs you" means for their destination (e.g. open PRs on `.review`,
    /// tasks needing a decision on `.overview`) - this view only renders
    /// whatever number it's given.
    ///
    /// A double-digit (or "99+") count gets slightly tighter label padding
    /// and a smaller font - the anchor point itself (`attachBadge`'s
    /// leading-from-icon/centerY-on-icon-top scheme) doesn't need to change
    /// with digit count, since a wider badge just extends further into the
    /// row's own open margin to the icon's right, never back toward the icon.
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
    ///
    /// `fm/grandline-lock-and-rail-fixes`: with 2+ pinned hosts, only the
    /// first host gets its own row - every host after it collapses into one
    /// "more hosts" entry in that same slot. `fm/grandline-rail-overflow-and-spacing`
    /// raised the threshold after captain feedback that collapsing at exactly
    /// 2 hosts (1 shown + a "+1" entry) was premature - overflow now only
    /// kicks in at 3+ pinned hosts; exactly 2 hosts show both normally, same
    /// as exactly 1. This reuses the exact hover-flyout mechanism the "Setup"
    /// group already established (`HoverTrackingButton` + an `NSPopover`
    /// shown on hover, closed on a short hover-out delay) rather than a
    /// second interaction pattern - see `scheduleShowHostsOverflowFlyout()`.
    /// Without this, the HOSTS section's height (and therefore the whole
    /// rail's) grows without bound as hosts are pinned, which is the biggest
    /// single contributor to the "crowded at real density" complaint this
    /// task's rail-spacing rework otherwise addresses.
    func setHosts(_ hosts: [Host]) {
        self.hosts = hosts
        for v in hostsStack.arrangedSubviews {
            hostsStack.removeArrangedSubview(v)
            v.removeFromSuperview()
        }
        hostButtons.removeAll()
        hostsOverflowButton.removeFromSuperview()
        let visibleHosts = hosts.count > 2 ? [hosts[0]] : hosts
        for host in visibleHosts {
            let button = hostRailButton(for: host)
            hostButtons[host.id] = button
            hostsStack.addArrangedSubview(button)
        }
        if hosts.count > 2 {
            hostsStack.addArrangedSubview(buildHostsOverflowButton(remainingCount: hosts.count - 1))
        }
        restyle(ThemeManager.shared.theme)
    }

    /// Builds the "more hosts" row shown in place of the 2nd+ pinned host -
    /// same labeled icon-over-text shape as every other rail row, a stacked-
    /// rectangles glyph (distinct from any single host's own icon) and an
    /// "+N" label instead of a host name. Hover-driven, like "Setup" - see
    /// `buildSetupButton()`'s own doc comment for why hover (not click) and a
    /// side flyout (not an in-rail expanding drawer) were the captain's
    /// explicit choices there; this reuses the identical mechanism.
    private func buildHostsOverflowButton(remainingCount: Int) -> NSButton {
        _ = buildRailRowButton(
            title: "+\(remainingCount)",
            symbol: "square.stack.3d.up",
            pointSize: 16,
            tooltip: "\(remainingCount) more host\(remainingCount == 1 ? "" : "s")",
            existingButton: hostsOverflowButton
        )
        hostsOverflowButton.onHoverChange = { [weak self] isHovering in
            isHovering ? self?.scheduleShowHostsOverflowFlyout() : self?.scheduleCloseHostsOverflowFlyout()
        }
        return hostsOverflowButton
    }

    /// Same show/hide timing as `scheduleShowSetupFlyout()`/`scheduleCloseSetupFlyout()`
    /// - see those for why the close is delayed rather than immediate.
    private func scheduleShowHostsOverflowFlyout() {
        hostsOverflowCloseWorkItem?.cancel()
        hostsOverflowCloseWorkItem = nil
        guard hostsOverflowPopover?.isShown != true else { return }
        showHostsOverflowFlyout()
    }

    private func scheduleCloseHostsOverflowFlyout() {
        hostsOverflowCloseWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in self?.hostsOverflowPopover?.performClose(nil) }
        hostsOverflowCloseWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.setupCloseDelay, execute: workItem)
    }

    private func showHostsOverflowFlyout() {
        let overflowHosts = Array(hosts.dropFirst())
        guard !overflowHosts.isEmpty else { return }
        let popover = NSPopover()
        popover.behavior = .applicationDefined
        popover.appearance = NSAppearance(named: ThemeManager.shared.theme.mode == .dark ? .darkAqua : .aqua)
        popover.contentViewController = HostsOverflowFlyoutViewController(
            hosts: overflowHosts,
            onHoverChange: { [weak self] isHovering in
                isHovering ? self?.scheduleShowHostsOverflowFlyout() : self?.scheduleCloseHostsOverflowFlyout()
            },
            onSelect: { [weak self] host in
                self?.hostsOverflowCloseWorkItem?.cancel()
                self?.hostsOverflowPopover?.performClose(nil)
                self?.onConnectHost?(host)
            }
        )
        popover.show(relativeTo: hostsOverflowButton.bounds, of: hostsOverflowButton, preferredEdge: .maxX)
        hostsOverflowPopover = popover
    }

    /// Labeled the same way as `railButton(for:)` (fm/grandline-sidebar-nav-polish
    /// - the captain's screenshot showed pinned hosts with an icon but no
    /// name underneath, inconsistent with the rest of the now fully-labeled
    /// rail). Kept as its own function rather than folded into `railButton`
    /// since a host has no `RailDestination` case/tag - it dispatches
    /// through `hostClicked(_:)` via its `identifier`, not `navClicked(_:)`.
    private func hostRailButton(for host: Host) -> NSButton {
        // `NSImage(systemSymbolName:)` returning `nil` for an unrecognized
        // saved symbol name is resolved before handing the symbol string to
        // the shared builder, which otherwise has no fallback of its own.
        let resolvedSymbol = NSImage(systemSymbolName: host.iconSymbol, accessibilityDescription: nil) != nil
            ? host.iconSymbol
            : HostCatalog.defaultIcon
        let button = buildRailRowButton(title: host.label, symbol: resolvedSymbol, pointSize: 16, tooltip: host.label)
        button.target = self
        button.action = #selector(hostClicked(_:))
        button.identifier = NSUserInterfaceItemIdentifier(host.id.uuidString)
        return button
    }

    @objc private func hostClicked(_ sender: NSButton) {
        guard let idString = sender.identifier?.rawValue,
              let id = UUID(uuidString: idString),
              let host = hosts.first(where: { $0.id == id }) else { return }
        onConnectHost?(host)
    }

    private lazy var avatarPopover: NSPopover = {
        let popover = NSPopover()
        let content = AvatarLogoutPopoverController()
        content.onSettings = { [weak self] in
            self?.avatarPopover.performClose(nil)
            self?.onSelect?(.settings)
        }
        content.onLogout = { [weak self] in
            self?.avatarPopover.performClose(nil)
            self?.logoutClicked()
        }
        popover.contentViewController = content
        popover.behavior = .transient
        return popover
    }()

    /// fm/grandline-app-lock: replaces the old "About This App" panel with a
    /// small themed popover - a bare `NSMenu` here (this task's first draft)
    /// read as unstyled system chrome next to the rest of this app's
    /// deliberately-themed surfaces, per live captain feedback. Follows
    /// `ShiftMenuBarController`'s own `NSPopover` convention (a small
    /// standalone popup off a status-bar-style button) rather than
    /// `ThemeMenu`'s `NSMenu` convention, since this needs the app's own
    /// `HelmTheme` colors, not the system menu chrome `ThemeMenu` already
    /// relies on for its swatch/checkmark rows.
    /// `fm/grandline-avatar-menu-and-setup-guide` added a "Settings" row
    /// above "Logout" (captain-approved: Settings is routine, Logout is
    /// consequential, so routine goes first) - this popover is deliberately
    /// scoped to just these two items, an identity/account-style menu, not a
    /// general dumping ground for other rail destinations.
    @objc private func avatarClicked() {
        if avatarPopover.isShown {
            avatarPopover.performClose(nil)
        } else {
            (avatarPopover.contentViewController as? AvatarLogoutPopoverController)?.applyTheme(ThemeManager.shared.theme)
            avatarPopover.show(relativeTo: avatar.bounds, of: avatar, preferredEdge: .maxX)
        }
    }

    /// `fm/grandline-avatar-menu-and-setup-guide`: collapsed from two
    /// sequential confirmations down to one, per live captain feedback after
    /// using the app-lock feature - too much friction for routine use. Keeps
    /// the second alert's copy, since it states the real stakes (losing
    /// access until the password is re-entered) most clearly.
    @objc private func logoutClicked() {
        let alert = NSAlert()
        alert.messageText = "Log out of Manjesh Grand Line?"
        alert.informativeText = "This locks the app immediately. You'll need your Grand Line password to get back in. Your terminal sessions keep running in the background."
        alert.addButton(withTitle: "Log Out")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        onLogoutRequested?()
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

    /// `fm/grandline-lock-and-rail-fixes`: called by `AppShellController`
    /// whenever the lock overlay's visibility changes - bold + a gentle,
    /// continuous bob once unlocked; back to the plain, static mark the
    /// instant it locks again (a captain stepping away mid-animation
    /// shouldn't see the boat still "sailing" behind the lock screen).
    func setUnlocked(_ unlocked: Bool) {
        guard unlocked != isUnlockedForMark else { return }
        isUnlockedForMark = unlocked
        mark.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 17, weight: unlocked ? .heavy : .medium)
        if unlocked {
            let bob = CAKeyframeAnimation(keyPath: "transform")
            var transforms: [CATransform3D] = []
            for step in 0...8 {
                let t = CGFloat(step) / 8
                let offset = sin(t * .pi * 2) * 1.6
                let rotation = sin(t * .pi * 2) * 0.05
                var transform = CATransform3DMakeTranslation(0, offset, 0)
                transform = CATransform3DRotate(transform, rotation, 0, 0, 1)
                transforms.append(transform)
            }
            bob.values = transforms
            bob.duration = 3.2
            bob.repeatCount = .infinity
            bob.calculationMode = .cubic
            mark.layer?.add(bob, forKey: "bob")
        } else {
            mark.layer?.removeAnimation(forKey: "bob")
            mark.layer?.transform = CATransform3DIdentity
        }
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

        // "more hosts" never highlights as "active" (no single fixed
        // destination or host id it corresponds to) - always the plain
        // inactive ink color, like an inert utility row.
        if hostsOverflowButton.superview != nil {
            let overflowColor = ink.withAlphaComponent(0.65)
            hostsOverflowButton.contentTintColor = overflowColor
            hostsOverflowButton.attributedTitle = attributedRowTitle(hostsOverflowButton.title, color: overflowColor)
            hostsOverflowButton.layer?.backgroundColor = NSColor.clear.cgColor
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
        restyleAvatar(theme)
    }

    /// `fm/grandline-rail-unified-rework`: the avatar's gradient fill + ring
    /// border, split out of `restyle(_:)` since it also needs to re-run on a
    /// hover change (not just a theme change) - see `avatarGradientLayer`'s
    /// doc comment and `avatar.onHoverChange` in `loadView`. The gradient
    /// blends the old flat avatar color into the active theme's accent
    /// (rather than a flat fill); the ring is a soft accent-colored border,
    /// subtle at rest and brightening (higher alpha, slightly thicker) on
    /// hover, using the same `HoverTrackingButton` mechanism `setupButton`/
    /// `hostsOverflowButton` already use rather than a new hover mechanism.
    private func restyleAvatar(_ theme: HelmTheme) {
        let ink = HelmTheme.nsColor(theme.chromeInkHex)
        let accent = HelmTheme.nsColor(theme.accentHex)
        let flat = HelmTheme.nsColor(theme.chromeLineHex).withAlphaComponent(0.4)
        avatar.contentTintColor = ink
        avatarGradientLayer.colors = [flat.cgColor, accent.withAlphaComponent(0.55).cgColor]
        avatar.layer?.borderWidth = avatarIsHovering ? 2 : 1.25
        avatar.layer?.borderColor = accent.withAlphaComponent(avatarIsHovering ? 0.85 : 0.4).cgColor
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

/// The "more hosts" flyout's content (`fm/grandline-lock-and-rail-fixes`) -
/// the same hover-popover shape as `SetupFlyoutViewController` above (icon +
/// label rows in a themed vertical list), listing the pinned hosts beyond
/// the first one. Kept as its own type rather than generalizing
/// `SetupFlyoutViewController` to something generic over "either a
/// `RailDestination` or a `Host`": a host's icon is tinted with its own
/// per-host accent color (`host.accentHex`, matching `hostRailButton`'s own
/// per-host tinting), not one of the fixed `HelmTint` cases every
/// `RailDestination` row uses - the two content types don't actually share a
/// tinting story, so forcing one shared implementation would need a case
/// split anyway.
private final class HostsOverflowFlyoutViewController: NSViewController {
    private let hosts: [Host]
    private let onHoverChange: (Bool) -> Void
    private let onSelect: (Host) -> Void
    private var themeObservation: ThemeObservation?

    init(hosts: [Host], onHoverChange: @escaping (Bool) -> Void, onSelect: @escaping (Host) -> Void) {
        self.hosts = hosts
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

        var rowIcons: [(NSImageView, Host)] = []
        for host in hosts {
            let row = HoverHighlightView()
            row.cornerRadius = 8
            row.translatesAutoresizingMaskIntoConstraints = false

            let iconTile = NSView()
            iconTile.wantsLayer = true
            iconTile.layer?.cornerRadius = 7
            iconTile.translatesAutoresizingMaskIntoConstraints = false
            let icon = NSImageView()
            icon.image = (NSImage(systemSymbolName: host.iconSymbol, accessibilityDescription: host.label)
                ?? NSImage(systemSymbolName: HostCatalog.defaultIcon, accessibilityDescription: host.label))?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold))
            icon.translatesAutoresizingMaskIntoConstraints = false
            iconTile.addSubview(icon)
            NSLayoutConstraint.activate([
                icon.centerXAnchor.constraint(equalTo: iconTile.centerXAnchor),
                icon.centerYAnchor.constraint(equalTo: iconTile.centerYAnchor),
                iconTile.widthAnchor.constraint(equalToConstant: 26),
                iconTile.heightAnchor.constraint(equalToConstant: 26),
            ])
            rowIcons.append((icon, host))

            let label = NSTextField(labelWithString: host.label)
            label.font = .systemFont(ofSize: 12, weight: .medium)

            let rowStack = NSStackView(views: [iconTile, label])
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
            row.identifier = NSUserInterfaceItemIdentifier(host.id.uuidString)

            stack.addArrangedSubview(row)
        }

        themeObservation = ThemeManager.shared.observe { [weak root] theme in
            root?.layer?.backgroundColor = HelmTheme.nsColor(theme.chromeBackgroundHex).cgColor
            let ink = HelmTheme.nsColor(theme.chromeInkHex)
            let hoverTint = HelmTheme.nsColor(theme.chromeLineHex).withAlphaComponent(theme.mode == .dark ? 0.25 : 0.5)
            for (icon, host) in rowIcons {
                let hostAccent = HelmTheme.nsColor(host.accentHex)
                icon.contentTintColor = hostAccent
                icon.superview?.layer?.backgroundColor = hostAccent.withAlphaComponent(0.16).cgColor
            }
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
              let id = UUID(uuidString: idString),
              let host = hosts.first(where: { $0.id == id }) else { return }
        onSelect(host)
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
    /// `fm/grandline-rail-unified-rework`: reads `IconRailController`'s own
    /// `iconSize`/`contentSpacing`/`titleHeight` instead of keeping a second,
    /// independently-defaulted copy of the same numbers - this cell and
    /// `IconRailController.attachBadge`'s icon-anchor guide now derive from
    /// exactly one set of constants, which is what makes the badge's anchor
    /// (see that method) actually line up with where this cell draws the
    /// icon, for every row, including Setup.
    private var iconSize: CGFloat { IconRailController.iconSize }
    private var contentSpacing: CGFloat { IconRailController.contentSpacing }

    private func measuredTitleHeight() -> CGFloat {
        let titleFont = font ?? IconRailController.titleFont
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

/// fm/grandline-app-lock: the avatar's popover content - a single themed,
/// hover-highlighted "Logout" row. A plain `NSViewController` (not a
/// `RailDestination`-style shared page), mirroring
/// `ShiftMenuBarPopoverController`'s own small-popover convention.
/// `fm/grandline-avatar-menu-and-setup-guide`: gained a "Settings" row above
/// "Logout" (Settings' own standalone rail row is gone - see
/// `RailDestination`'s doc comment), separated by a thin divider since one
/// is routine and the other is consequential. Deliberately kept to just
/// these two rows - an identity/account-style menu, not a general dumping
/// ground for other rail items.
private final class AvatarLogoutPopoverController: NSViewController {
    private let settingsRow = HoverHighlightView()
    private let settingsIcon = NSImageView()
    private let settingsLabel = NSTextField(labelWithString: "Settings")
    private let divider = NSBox()
    private let logoutRow = HoverHighlightView()
    private let logoutIcon = NSImageView()
    private let logoutLabel = NSTextField(labelWithString: "Logout")

    var onSettings: (() -> Void)?
    var onLogout: (() -> Void)?

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 160, height: 89))
        view = root

        settingsIcon.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: "Settings")?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 13, weight: .medium))
        settingsIcon.translatesAutoresizingMaskIntoConstraints = false
        settingsLabel.font = .systemFont(ofSize: 13, weight: .medium)
        settingsLabel.translatesAutoresizingMaskIntoConstraints = false
        settingsRow.translatesAutoresizingMaskIntoConstraints = false
        settingsRow.addSubview(settingsIcon)
        settingsRow.addSubview(settingsLabel)
        root.addSubview(settingsRow)
        settingsRow.addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(settingsRowClicked)))

        divider.boxType = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(divider)

        logoutIcon.image = NSImage(systemSymbolName: "rectangle.portrait.and.arrow.right", accessibilityDescription: "Logout")?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 13, weight: .medium))
        logoutIcon.translatesAutoresizingMaskIntoConstraints = false
        logoutLabel.font = .systemFont(ofSize: 13, weight: .medium)
        logoutLabel.translatesAutoresizingMaskIntoConstraints = false
        logoutRow.translatesAutoresizingMaskIntoConstraints = false
        logoutRow.addSubview(logoutIcon)
        logoutRow.addSubview(logoutLabel)
        root.addSubview(logoutRow)
        logoutRow.addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(logoutRowClicked)))

        NSLayoutConstraint.activate([
            settingsRow.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 6),
            settingsRow.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -6),
            settingsRow.topAnchor.constraint(equalTo: root.topAnchor, constant: 6),
            settingsRow.heightAnchor.constraint(equalToConstant: 32),

            settingsIcon.leadingAnchor.constraint(equalTo: settingsRow.leadingAnchor, constant: 10),
            settingsIcon.centerYAnchor.constraint(equalTo: settingsRow.centerYAnchor),
            settingsIcon.widthAnchor.constraint(equalToConstant: 16),

            settingsLabel.leadingAnchor.constraint(equalTo: settingsIcon.trailingAnchor, constant: 8),
            settingsLabel.trailingAnchor.constraint(lessThanOrEqualTo: settingsRow.trailingAnchor, constant: -10),
            settingsLabel.centerYAnchor.constraint(equalTo: settingsRow.centerYAnchor),

            divider.topAnchor.constraint(equalTo: settingsRow.bottomAnchor, constant: 4),
            divider.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 10),
            divider.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -10),

            logoutRow.topAnchor.constraint(equalTo: divider.bottomAnchor, constant: 4),
            logoutRow.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 6),
            logoutRow.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -6),
            logoutRow.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -6),
            logoutRow.heightAnchor.constraint(equalToConstant: 32),

            logoutIcon.leadingAnchor.constraint(equalTo: logoutRow.leadingAnchor, constant: 10),
            logoutIcon.centerYAnchor.constraint(equalTo: logoutRow.centerYAnchor),
            logoutIcon.widthAnchor.constraint(equalToConstant: 16),

            logoutLabel.leadingAnchor.constraint(equalTo: logoutIcon.trailingAnchor, constant: 8),
            logoutLabel.trailingAnchor.constraint(lessThanOrEqualTo: logoutRow.trailingAnchor, constant: -10),
            logoutLabel.centerYAnchor.constraint(equalTo: logoutRow.centerYAnchor),
        ])

        settingsRow.cornerRadius = 8
        logoutRow.cornerRadius = 8
    }

    @objc private func settingsRowClicked() { onSettings?() }
    @objc private func logoutRowClicked() { onLogout?() }

    func applyTheme(_ theme: HelmTheme) {
        view.wantsLayer = true
        view.layer?.backgroundColor = HelmTheme.nsColor(theme.chromeBackgroundHex).cgColor
        divider.fillColor = HelmTheme.nsColor(theme.chromeLineHex)
        settingsIcon.contentTintColor = HelmTheme.nsColor(theme.chromeInkHex)
        settingsLabel.textColor = HelmTheme.nsColor(theme.chromeInkHex)
        settingsRow.normalColor = .clear
        settingsRow.hoverColor = HelmTheme.nsColor(theme.chromeLineHex).withAlphaComponent(0.5)
        logoutIcon.contentTintColor = HelmTheme.nsColor(theme.ansiHex[1]) // red - a destructive-ish action
        logoutLabel.textColor = HelmTheme.nsColor(theme.chromeInkHex)
        logoutRow.normalColor = .clear
        logoutRow.hoverColor = HelmTheme.nsColor(theme.chromeLineHex).withAlphaComponent(0.5)
    }
}
