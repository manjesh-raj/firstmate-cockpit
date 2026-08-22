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
/// `.dictation` (fm/grandline-dictation-mvp, phase 1) follows the identical
/// convention too, pinned directly *above* `.docs` and below `.vault` - so
/// the bottom-anchored group reads Tools, Vault, Dictation, Docs, Setup
/// (-> Updates, Bootstrap, Automation flyout), avatar.
/// `fm/grandline-rail-setup-group` merged `.updates`/`.bootstrap`'s two
/// standalone rail rows into one "Setup" entry, directly above `.docs`, that
/// opens a small flyout `NSPopover` listing Updates and Bootstrap - so the
/// bottom-anchored group visually reads Tools, Vault, Docs, Setup
/// (-> Updates, Bootstrap flyout), avatar. Both cases remain real
/// `RailDestination`s for switching purposes - only their rail position/
/// visibility changed; see `IconRailController.buildSetupButton()`/
/// `showSetupFlyout()`. `.automation` (fm/grandline-automation-pipeline)
/// follows the identical convention: a third real `RailDestination` with no
/// rail row of its own, reachable only as the Setup flyout's third entry,
/// below Updates and Bootstrap. `.githubSync` (fm/grandline-setup-github-sync)
/// follows the identical convention too: a fourth real `RailDestination` with
/// no rail row of its own, reachable only as the Setup flyout's fourth entry,
/// below Automation.
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
/// `isDailyUse` (fm/grandline-sidebar-labeled-nav) marks the 6
/// `navStack` members (Overview, Console, Hosts, Shift, Review, Log
/// Analyzer - the last added by `fm/grandline-log-analyzer-build`) as the set
/// that lives in the top `navStack` block rather than the bottom-anchored
/// utility group - `navStack`'s loop and the bottom-anchored `loadView` block
/// both filter on this directly. It no longer selects a *different visual
/// style*: `fm/grandline-sidebar-nav-polish` gave every row (daily-use,
/// utility, and per-host) the same labeled icon-over-text treatment after
/// live captain feedback that icon-only utility rows looked inconsistent
/// once the rest of the rail had labels - see `labeledRailButton(for:)`.
enum RailDestination: CaseIterable {
    case overview, console, hosts, shift, review, logAnalyzer, tools, vault, dictation, docs, updates, bootstrap, automation, githubSync, settings

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
        // `fm/grandline-log-analyzer-build`: a magnifier over lines - the
        // "read this output" idea, distinct from `.review`'s branch glyph
        // and from Console's bare terminal.
        case .logAnalyzer: return "text.magnifyingglass"
        case .tools: return "wrench.and.screwdriver"
        case .vault: return "lock.shield"
        case .dictation: return "waveform"
        case .docs: return "book.closed"
        case .updates: return "steeringwheel"
        case .bootstrap: return "hammer"
        case .automation: return "bolt.fill"
        case .githubSync: return "arrow.2.squarepath"
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
        case .logAnalyzer: return "Log Analyzer"
        case .tools: return "Tools"
        case .vault: return "Vault"
        case .dictation: return "Dictation"
        case .docs: return "Docs"
        case .updates: return "Updates"
        case .bootstrap: return "Bootstrap"
        case .automation: return "Automation"
        case .githubSync: return "GitHub Sync"
        case .settings: return "Settings"
        }
    }

    /// The hue this destination's icon carries wherever it is drawn as an
    /// `IconTileView` rather than a bare rail glyph - today that is the Setup
    /// flyout's four rows (`SetupFlyoutViewController`).
    ///
    /// `fm/grandline-sre-lead-and-setup-icons`: every one of those rows used
    /// to pass a hardcoded `.accent`, so all four rendered the identical
    /// teal tile and the flyout read as one undifferentiated block - measured
    /// in a real render, all four glyphs sampled the same `rgb(165,218,229)`.
    /// The captain's own proposed mockup assigns each row a distinct hue, and
    /// sampling that mockup's pixels resolves each one to a `HelmTint` this
    /// app already has: blue `.info` for Updates, amber `.warn` for
    /// Bootstrap, the theme accent for Automation, magenta `.violet` for
    /// GitHub Sync. Semantic tints, not literals, so all 12 palettes resolve
    /// their own hues.
    ///
    /// Every other destination keeps `.accent` - the rail's own rows are
    /// plain tinted glyphs with no tile behind them, and this property is
    /// only consulted where a tile is actually drawn.
    ///
    /// **Measured caveat, recorded rather than hidden:** `.accent` for
    /// Automation resolves to the *same hue as a neighbouring row* in 3 of
    /// the 12 palettes, because those palettes genuinely define their accent
    /// as that hue - `tokyo-night-dark`/`-light` set `accentHex` to their own
    /// blue (`ansiHex[4]`, so Updates and Automation match) and
    /// `rose-pine-main` sets it to its own magenta (`ansiHex[5]`, so
    /// Automation and GitHub Sync match). Swapping Automation to `.good`
    /// removes every collision (measured: zero in all 12), but `.good` is
    /// green in `helm-dark` where the captain's own reference mockup shows
    /// the accent cyan - and the brief names those screenshots as ground
    /// truth. Exact fidelity in the reference palette was chosen over
    /// collision-freedom in three others; this is still a strict improvement
    /// everywhere, since before this all four rows shared one hue in all 12.
    /// Revisit by adding a genuinely distinct semantic `HelmTint` case, not
    /// by hardcoding a literal here.
    var flyoutTint: HelmTint {
        switch self {
        case .updates: return .info
        case .bootstrap: return .warn
        case .automation: return .accent
        case .githubSync: return .violet
        case .overview, .console, .hosts, .shift, .review, .logAnalyzer,
             .tools, .vault, .dictation, .docs, .settings: return .accent
        }
    }

    var isDailyUse: Bool {
        switch self {
        case .overview, .console, .hosts, .shift, .review, .logAnalyzer: return true
        case .tools, .vault, .dictation, .docs, .updates, .bootstrap, .automation, .githubSync, .settings: return false
        }
    }
}

final class IconRailController: NSViewController, NSPopoverDelegate {

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
    /// button type `setupButton`/`hostsButton` already use)
    /// rather than a plain `NSButton`, so the avatar's accent ring can
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

    /// The saved hosts currently pinned to the rail - no longer rendered as
    /// their own permanent icon column (the hosts-flyout redesign
    /// replaced that, and its "more hosts" overflow flyout, with a single
    /// "Hosts" rail row that opens `HostsFlyoutViewController` listing every
    /// saved host on demand). `setHosts` just keeps this array current so the
    /// flyout always shows live content the next time it's opened.
    private var hosts: [Host] = []

    /// the hosts-flyout redesign: "Hosts" is a single rail row,
    /// positioned inside `navStack` right where the old per-host icon block
    /// used to sit (see `loadView`'s daily-use loop) - it opens a small
    /// flyout `NSPopover` on click, reusing the exact `SetupFlyoutViewController`/
    /// click-to-toggle mechanism `buildSetupButton()`/`setupClicked()` already
    /// established, rather than a second interaction pattern. It is not a
    /// `RailDestination` of its own for dispatch purposes - `.hosts` still is
    /// (for `AppShellController.show(.hosts)`/`setActive(.hosts)`), but its
    /// rail row no longer calls `onSelect` directly; the flyout's own
    /// "Manage Hosts & Keys…" row does that instead.
    private let hostsButton = HoverTrackingButton()
    private var hostsPopover: NSPopover?

    /// fm/grandline-sidebar-nav-polish: a hairline divider between the logo
    /// mark and the first daily-use row (Overview) - the captain noticed the
    /// mark/nav boundary had no divider while every other section boundary
    /// (above/below the per-host block) already does.
    ///
    /// This used to be an `NSBox(.separator)`, matching what every OTHER divider in this file
    /// (`navStackDivider()`'s rows, `dividerSetupAvatar`) also used - but
    /// `.separator`-typed `NSBox`es unconditionally draw AppKit's own system
    /// separator color and silently IGNORE any `.fillColor` set on them
    /// (confirmed live: setting `.fillColor = .red` on a `.separator` box
    /// produced no visible change at all - a real, verified AppKit fact, not
    /// an assumption). Since none of this file's dividers ever set
    /// `.fillColor` either, every rail divider was relying purely on the
    /// system separator color against this file's own custom dark chrome
    /// background - measured live (a temporary bitmap-sampling probe) at
    /// only a ~0.09 RGB delta from the background, a barely-perceptible
    /// hairline. This is the actual root cause of the captain's "no visible
    /// divider between Setup and the avatar" report: every rail divider was
    /// already this faint, it just happened to be most noticeable in that
    /// specific spot (an otherwise-blank gap with no neighboring content to
    /// visually anchor it), unlike this divider's own neighbor (the mark) or
    /// the inter-row dividers (framed by icon rows on both sides). Every
    /// OTHER divider throughout this app (Settings/Bootstrap/Shift/Docs/
    /// Review/Fleet/ToolRowLayout, etc.) is a plain layer-backed `NSView`
    /// with an explicit `theme.chromeLineHex`-derived `layer.backgroundColor`
    /// - genuinely visible, unlike this file's `NSBox(.separator)`s. Fixed by
    /// switching every divider in this file (this one, `navStackDivider()`'s,
    /// and `dividerSetupAvatar`) to that same working pattern via
    /// `makeThemedDivider()`/`railDividers`, rather than leaving this one
    /// divider newly bright while its siblings stay invisible.
    private let dividerAboveNav = NSView()

    /// Every hairline divider in this rail (`dividerAboveNav`, each
    /// `navStackDivider()`-built row separator, and `dividerSetupAvatar`) is
    /// collected here so the `ThemeManager.shared.observe` callback can give
    /// them all a real, visible `theme.chromeLineHex` fill - see
    /// `dividerAboveNav`'s own doc comment above for why a plain `NSBox
    /// (.separator)` (this file's old pattern) can never be made visible via
    /// `.fillColor` at all.
    private var railDividers: [NSView] = []

    /// Builds one themed hairline divider and registers it in `railDividers`
    /// so it gets re-colored on every theme change - the same "plain
    /// layer-backed `NSView`, no `NSBox`" pattern every other divider outside
    /// this file already uses (see `dividerAboveNav`'s doc comment). Callers
    /// still need to give it an explicit 1pt height constraint themselves,
    /// since (unlike `NSBox(.separator)`) a plain `NSView` has no intrinsic
    /// thickness of its own.
    private func makeThemedDivider() -> NSView {
        let line = NSView()
        line.wantsLayer = true
        line.translatesAutoresizingMaskIntoConstraints = false
        railDividers.append(line)
        return line
    }

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

    /// `fm/grandline-rail-unify-and-mark-polish`: a subtle accent-tinted
    /// gradient tile behind the sailboat glyph, replacing its previous plain
    /// template-color rendering (the one thing making the mark read "bland"
    /// per captain feedback) - the same "flat color -> theme accent"
    /// `CAGradientLayer` + soft ring treatment `restyleAvatar`/
    /// `avatarGradientLayer` already established, reused rather than
    /// inventing a second visual language. Sized once in `loadView` (the
    /// mark's own 34x34 bounds are fixed, so the layer's frame never needs
    /// re-laying-out); `restyleMark` re-tunes its colors on every theme
    /// change, same as `restyleAvatar`. The existing bob animation
    /// (`setUnlocked`) and lock/unlock weight change are untouched - this
    /// only changes the mark's background/tint, never its transform or
    /// symbol weight logic.
    private let markGradientLayer = CAGradientLayer()

    /// `fm/grandline-rail-unify-and-mark-polish`: whether each flyout-driven
    /// row's own popover is currently showing - a rail row that opens a
    /// flyout (Hosts/Setup) previously showed no active/pressed state at
    /// all while its flyout was open, unlike a real destination like Console,
    /// which highlights for as long as it's the shown page. Fed into
    /// `restyle(_:)`'s existing active-state coloring for these rows;
    /// set on `show*Flyout()` and cleared via `NSPopoverDelegate.popoverDidClose(_:)`
    /// (not just the `*Clicked()` performClose branch) so a `.transient`
    /// popover dismissed by an outside click - which never goes through
    /// `hostsClicked()`/`setupClicked()` at all - still clears
    /// the highlight.
    private var isHostsFlyoutOpen = false
    private var isSetupFlyoutOpen = false

    /// Margin the top group (logo mark) keeps from the window's top edge,
    /// and the bottom group (avatar) keeps from the window's bottom edge -
    /// see the two-anchor-groups layout doc comment on `loadView` below.
    private static let railEdgeMargin: CGFloat = 14

    /// `fm/grandline-rail-unify-and-mark-polish` **supersedes the two-anchor-
    /// groups design** `fm/grandline-rail-unified-rework` established (the
    /// doc comment this replaces described a top-pinned group - logo mark,
    /// daily-use rows, HOSTS section - and an independently bottom-pinned
    /// group - utility rows + avatar - joined by one `>=` connector). Real
    /// captain screenshots showed that split reading as two visually
    /// different gaps: more space above "Tools" than below it (the connector
    /// itself), and more space after "Setup" than between any other pair of
    /// rows (the old bottom group's own fixed `sectionGap`/`rowSpacing`
    /// rhythm happened to read differently once nothing else on the page
    /// used exactly that gap). The captain's own framing: stop treating
    /// daily-use and utility as two groups at all - one continuous, evenly-
    /// spaced list, Overview through Setup, with a divider between every
    /// consecutive pair (including the previously-missing one after Review),
    /// and only the profile/avatar visually separated at the very bottom.
    ///
    /// The fix is smaller than a full redesign, per the captain's own hint:
    /// `navStack` already held the daily-use rows as arranged subviews with
    /// a uniform `rowSpacing`/divider rhythm (`navStackDivider()`) - the
    /// utility rows (Tools/Vault/Dictation/Docs/Setup) used to be
    /// individually-positioned `root` subviews instead, specifically so the
    /// old per-host icon *block* above them (a variable-height `NSStackView`
    /// with no height constraint of its own) could grow/shrink freely
    /// without disturbing them. the hosts-flyout redesign
    /// already removed that variable-height block (replaced by the fixed-
    /// height "Hosts" flyout-trigger row, itself an ordinary `navStack`
    /// arranged subview) - so the original reason to keep the utility rows
    /// out of `navStack` no longer applies. They now simply
    /// continue `navStack`'s own loop, separated by the exact same
    /// `navStackDivider()` calls the daily-use rows already use - one list,
    /// one spacing rhythm, no group boundary anywhere inside it.
    ///
    /// Only the avatar keeps its own independent anchor, pinned to `root`'s
    /// *bottom* edge exactly as before, with its own divider
    /// (`dividerSetupAvatar`) above it - the one deliberate visual exception
    /// the captain confirmed. The one remaining flex point is the connector
    /// between the end of the unified list and that divider: a required
    /// `>=` inequality (`dividerSetupAvatar.topAnchor >= navStack.bottomAnchor
    /// + sectionGap`), mirroring the old design's own connector reasoning -
    /// both endpoints are already fully, independently determined (`navStack`
    /// top-anchored from `root.topAnchor`; the divider/avatar pair bottom-
    /// anchored from `root.bottomAnchor`), so this is genuinely just "however
    /// much room is left between two fixed points," never a stretchy spacer
    /// view competing for slack the way `hostsStack` once accidentally did
    /// (see the fullheight-fix history above this comment for why that
    /// distinction matters). In practice, any leftover height in a tall
    /// window collects in exactly the gap that already read as "more space
    /// after Setup" before this change - this task tightens and relabels
    /// that single flexible point rather than inventing a new one.
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

        dividerAboveNav.wantsLayer = true
        dividerAboveNav.translatesAutoresizingMaskIntoConstraints = false
        railDividers.append(dividerAboveNav)
        root.addSubview(dividerAboveNav)
        dividerAboveNav.heightAnchor.constraint(equalToConstant: 1).isActive = true

        ThemeManager.shared.observe { [weak self, weak root] theme in
            root?.appearance = NSAppearance(named: theme.mode == .dark ? .darkAqua : .aqua)
            root?.layer?.backgroundColor = HelmTheme.nsColor(theme.chromeBackgroundHex).cgColor
            self?.edgeLine.layer?.backgroundColor = HelmTheme.nsColor(theme.chromeLineHex).withAlphaComponent(0.5).cgColor
            self?.restyle(theme)
            self?.restyleMark(theme)
            self?.restyleDividers(theme)
        }

        mark.image = NSImage(systemSymbolName: "sailboat", accessibilityDescription: "Manjesh Grand Line")
        mark.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 17, weight: .medium)
        mark.wantsLayer = true
        mark.layer?.cornerRadius = 10
        mark.layer?.masksToBounds = true
        mark.imageScaling = .scaleProportionallyDown
        mark.translatesAutoresizingMaskIntoConstraints = false
        // `fm/grandline-rail-unify-and-mark-polish`: the same gradient-tile
        // treatment `avatarGradientLayer` uses - sized once since the mark's
        // own bounds are fixed (34x34 via the constraints below).
        markGradientLayer.frame = CGRect(x: 0, y: 0, width: 34, height: 34)
        markGradientLayer.cornerRadius = 10
        markGradientLayer.startPoint = CGPoint(x: 0.2, y: 0.9)
        markGradientLayer.endPoint = CGPoint(x: 0.9, y: 0.1)
        mark.layer?.insertSublayer(markGradientLayer, at: 0)

        let navStack = NSStackView()
        navStack.orientation = .vertical
        navStack.spacing = Self.rowSpacing
        navStack.translatesAutoresizingMaskIntoConstraints = false
        func navStackDivider() {
            let divider = makeThemedDivider()
            navStack.addArrangedSubview(divider)
            divider.widthAnchor.constraint(equalTo: navStack.widthAnchor, constant: -16).isActive = true
            divider.heightAnchor.constraint(equalToConstant: 1).isActive = true
        }

        let dailyUseDestinations = RailDestination.allCases.filter { $0.isDailyUse }
        for (index, dest) in dailyUseDestinations.enumerated() {
            // fm/grandline-rail-followup-fixes: a hairline separator between
            // each daily-use row (Overview | Console | Hosts | Tasks |
            // Review | Log Analyzer), matching the existing separator style
            // already used elsewhere in the rail - captain ask was scoped to
            // this group only, so the utility group is untouched.
            if index > 0 { navStackDivider() }
            if dest == .hosts {
                // the hosts-flyout redesign: "Hosts" is a
                // single flyout-opening row, right where the old per-host
                // icon block used to sit (below Console, above Tasks/Review)
                // - see `buildHostsButton()`'s own doc comment. `.hosts`
                // itself is still the `RailDestination` case that drives
                // this position (case order, `isDailyUse`), it just no
                // longer builds a plain `railButton(for:)`.
                navStack.addArrangedSubview(buildHostsButton())
                continue
            }
            let button = railButton(for: dest)
            buttons[dest] = button
            navStack.addArrangedSubview(button)
        }

        // Tools/Vault/Dictation/Docs/"Setup" (fm/grandline-rail-unify-and-mark-polish)
        // continue `navStack`'s own loop directly - one continuous,
        // evenly-spaced list with the daily-use rows above, separated by the
        // same `navStackDivider()` rhythm, rather than a separately-anchored
        // group. All of these are still real `RailDestination` cases for
        // switching purposes (Bootstrap/Updates/Automation/Settings
        // included); only their vertical position (or, for Settings, entry
        // point) is what moves.
        for dest: RailDestination in [.tools, .vault, .dictation, .docs] {
            navStackDivider()
            let button = railButton(for: dest)
            buttons[dest] = button
            navStack.addArrangedSubview(button)
        }
        navStackDivider()
        let setupGroup = buildSetupButton()
        navStack.addArrangedSubview(setupGroup)

        // The one remaining divider sits between the unified list's last row
        // ("Setup") and the avatar pinned at the very bottom - the one
        // deliberate visual exception the captain confirmed. Built the same
        // way `navStackDivider()`'s dividers are sized (matches width
        // exactly: `navStack`'s width is `Self.width - 12`, so
        // `navStack.widthAnchor - 16` there equals the `Self.width - 28`
        // used here, since this divider lives directly in `root` rather than
        // inside the stack) so it reads as the same divider style, not a
        // visually distinct one.
        let dividerSetupAvatar = makeThemedDivider()
        root.addSubview(dividerSetupAvatar)

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

            // The unified list: pinned to the window's top edge exactly as
            // the daily-use rows always were - unchanged from before this
            // task, just extended to cover every row through "Setup".
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

            avatar.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            avatar.widthAnchor.constraint(equalToConstant: 36),
            avatar.heightAnchor.constraint(equalToConstant: 36),

            // Avatar: pinned to the window's bottom edge, with its own
            // divider above it - the one visual exception to "one continuous
            // list" (see this method's own doc comment above).
            avatar.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -Self.railEdgeMargin),
            dividerSetupAvatar.bottomAnchor.constraint(equalTo: avatar.topAnchor, constant: -Self.sectionGap),
            dividerSetupAvatar.leadingAnchor.constraint(equalTo: navStack.leadingAnchor),
            dividerSetupAvatar.trailingAnchor.constraint(equalTo: navStack.trailingAnchor),
            dividerSetupAvatar.heightAnchor.constraint(equalToConstant: 1),

            // The one remaining flex point: both `navStack.bottomAnchor`
            // (top-anchored from `root.topAnchor`) and
            // `dividerSetupAvatar.bottomAnchor` (bottom-anchored from
            // `root.bottomAnchor` via `avatar`) are each already fully,
            // independently determined - so this required minimum-gap
            // inequality never has to resolve any actual stretch; any
            // leftover window height just becomes extra room here, exactly
            // where the old two-group design's own flex point already sat.
            dividerSetupAvatar.topAnchor.constraint(greaterThanOrEqualTo: navStack.bottomAnchor, constant: Self.sectionGap),
        ])

        restyle(ThemeManager.shared.theme)
        // `restyleMark`'s first run (inside the `ThemeManager.shared.observe`
        // registration above, which fires synchronously at registration
        // time) happens before `mark.wantsLayer`/`markGradientLayer` are set
        // up further down this method, so `mark.layer` is still nil then and
        // the border/gradient set silently no-ops - the same reason
        // `restyleAvatar` needs a second call here via `restyle(_:)` above,
        // now that `mark` needs one too (verified live via a temporary
        // geometry probe: `mark.layer?.borderWidth` read back as 0 without
        // this line).
        restyleMark(ThemeManager.shared.theme)
        // Same reason as `restyleMark` above: the `ThemeManager.shared.observe`
        // registration fires synchronously at registration time, before
        // `navStackDivider()`'s rows and `dividerSetupAvatar` exist yet - so
        // `railDividers` only had `dividerAboveNav` in it on that first run.
        // A second call here, after every divider in this method has been
        // built and appended, is what actually colors all of them.
        restyleDividers(ThemeManager.shared.theme)
        setActive(active)
    }

    /// Gives every hairline in `railDividers` a real, visible
    /// `theme.chromeLineHex` fill - see `dividerAboveNav`'s doc comment for
    /// why this file's dividers need this at all (a plain `NSBox(.separator)`
    /// can never be colored via `.fillColor`, and was rendering at only a
    /// bare ~0.09 RGB delta from this rail's own dark chrome background).
    private func restyleDividers(_ theme: HelmTheme) {
        let color = HelmTheme.nsColor(theme.chromeLineHex).withAlphaComponent(0.5).cgColor
        for divider in railDividers {
            divider.layer?.backgroundColor = color
        }
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

    /// The two rows that open a flyout instead of navigating (`hostsButton`,
    /// `setupButton`), and the small chevron each one carries to say so - held
    /// so `restyle(_:)` can keep that chevron's colour in step with its own
    /// row's active/inactive state.
    private var flyoutIndicators: [(button: NSButton, chevron: NSImageView)] = []

    /// Marks a rail row that **opens something** rather than navigating.
    ///
    /// Phase 7 (audit §7's Phase 7 entry). "Hosts" and "Setup" are the only
    /// two rows in this rail that behave differently from every other row: a
    /// click pops a flyout (`showHostsFlyout()` / `showSetupFlyout()`) instead
    /// of switching the body view. Nothing said so visually - both rendered as
    /// an ordinary icon-over-label row - so the difference was only
    /// discoverable by clicking.
    ///
    /// A small trailing `chevron.right`, the same affordance macOS itself uses
    /// for a submenu, is deliberately the smallest thing that carries that
    /// meaning: it reuses this rail's existing visual language (an SF Symbol
    /// tinted with the row's own colour) and adds no new row shape, no
    /// disclosure control, and no hit target - the whole row stays the one
    /// clickable thing it already was.
    ///
    /// **Where it sits, and why not the corner.** Vertically centred on the
    /// icon (via `iconCenterYOffsetFromRowCenter`, the same real icon position
    /// `attachBadge` anchors to) and pinned to the row's trailing edge, which
    /// is clear of the 20pt icon's own box by ~15pt. It deliberately does not
    /// overlap the icon: see `attachBadge`'s long comment for the three
    /// live-rendered attempts that proved no corner-overlap amount clears
    /// every glyph's ink. Neither of these two rows carries a count badge
    /// (only `RailDestination` rows built through `railButton(for:)` do), so
    /// the badge slot to the icon's right and this chevron never both exist on
    /// one row - but they would not collide even if they did, since the badge
    /// sits at the icon's *top* edge and this at its centre.
    private func attachFlyoutIndicator(to button: NSButton) {
        // `buildSetupButton()`/`buildHostsButton()` can be handed an existing
        // button instance (see `buildRailRowButton`'s `existingButton`), so
        // never attach a second chevron to a row that already has one.
        guard !flyoutIndicators.contains(where: { $0.button === button }) else { return }

        let chevron = NSImageView()
        chevron.image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: "Opens a menu")?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 8, weight: .semibold))
        chevron.translatesAutoresizingMaskIntoConstraints = false
        button.addSubview(chevron)
        NSLayoutConstraint.activate([
            chevron.trailingAnchor.constraint(equalTo: button.trailingAnchor, constant: -4),
            chevron.centerYAnchor.constraint(equalTo: button.centerYAnchor,
                                             constant: Self.iconCenterYOffsetFromRowCenter),
        ])
        flyoutIndicators.append((button, chevron))
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
            tooltip: "Setup (Updates, Bootstrap, Automation, GitHub Sync)",
            existingButton: setupButton
        )
        button.target = self
        button.action = #selector(setupClicked)
        attachFlyoutIndicator(to: button)
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
        popover.delegate = self
        popover.appearance = NSAppearance(named: ThemeManager.shared.theme.mode == .dark ? .darkAqua : .aqua)
        popover.contentViewController = SetupFlyoutViewController(
            destinations: [.updates, .bootstrap, .automation, .githubSync],
            onHoverChange: { _ in },
            onSelect: { [weak self] dest in
                self?.setupPopover?.performClose(nil)
                self?.setActive(dest)
                self?.onSelect?(dest)
            }
        )
        popover.show(relativeTo: setupButton.bounds, of: setupButton, preferredEdge: .maxX)
        setupPopover = popover
        isSetupFlyoutOpen = true
        restyle(ThemeManager.shared.theme)
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

    /// Fix 3 (fixes4), superseded by the hosts-flyout redesign:
    /// keeps the saved-host list current so the "Hosts" flyout (opened on
    /// demand via `hostsClicked`) always shows live content the next time it
    /// opens - there is no persistent per-host rail UI left to rebuild here.
    /// Called once at startup and on every `HostStore.observe` firing
    /// (add/rename/delete), same as before.
    func setHosts(_ hosts: [Host]) {
        self.hosts = hosts
        restyle(ThemeManager.shared.theme)
    }

    /// Builds the "Hosts" rail row - see the `hostsButton` property's doc
    /// comment. Otherwise built exactly like `buildSetupButton()`.
    private func buildHostsButton() -> NSButton {
        let button = buildRailRowButton(
            title: "Hosts",
            symbol: RailDestination.hosts.symbol,
            tooltip: "Hosts (quick-connect, manage)",
            existingButton: hostsButton
        )
        button.target = self
        button.action = #selector(hostsClicked)
        attachFlyoutIndicator(to: button)
        return button
    }

    /// Toggles the Hosts flyout - the same open-if-closed/close-if-open click
    /// pattern `setupClicked()`/`avatarClicked` use.
    @objc private func hostsClicked() {
        if hostsPopover?.isShown == true {
            hostsPopover?.performClose(nil)
        } else {
            showHostsFlyout()
        }
    }

    /// Shows the Hosts flyout, anchored to the Hosts button's trailing edge -
    /// see `HostsFlyoutViewController` for its content. Connecting a host
    /// calls `onConnectHost` exactly like the old pinned per-host icons did;
    /// "Manage Hosts & Keys…" opens the real, unchanged `.hosts` destination
    /// (`HostsSidebarController`) - nothing about either path changed, only
    /// where the entry point lives.
    private func showHostsFlyout() {
        let popover = NSPopover()
        popover.behavior = .transient
        popover.delegate = self
        popover.appearance = NSAppearance(named: ThemeManager.shared.theme.mode == .dark ? .darkAqua : .aqua)
        popover.contentViewController = HostsFlyoutViewController(
            hosts: hosts,
            onConnect: { [weak self] host in
                self?.hostsPopover?.performClose(nil)
                self?.onConnectHost?(host)
            },
            onManage: { [weak self] in
                self?.hostsPopover?.performClose(nil)
                self?.setActive(.hosts)
                self?.onSelect?(.hosts)
            }
        )
        popover.show(relativeTo: hostsButton.bounds, of: hostsButton, preferredEdge: .maxX)
        hostsPopover = popover
        isHostsFlyoutOpen = true
        restyle(ThemeManager.shared.theme)
    }

    /// `fm/grandline-rail-unify-and-mark-polish`: clears whichever
    /// flyout-open flag matches the popover that just closed - fires for
    /// *every* dismissal path (an explicit `performClose(nil)` from
    /// `hostsClicked()`/`setupClicked()`, a row selection, or
    /// a `.transient` popover's own outside-click auto-dismiss, which never
    /// goes through any of those methods), so the triggering row's highlight
    /// always clears in step with the flyout actually closing.
    func popoverDidClose(_ notification: Notification) {
        guard let popover = notification.object as? NSPopover else { return }
        if popover === hostsPopover {
            isHostsFlyoutOpen = false
        } else if popover === setupPopover {
            isSetupFlyoutOpen = false
        } else {
            return
        }
        restyle(ThemeManager.shared.theme)
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
        // "Hosts" itself highlights whenever the full Hosts management page
        // (`.hosts`) is showing, whenever a saved host's own dedicated page
        // is (`activeHostID != nil`), or whenever its own flyout is
        // currently open (`fm/grandline-rail-unify-and-mark-polish` -
        // previously this row showed no active state at all while its
        // flyout was showing, unlike a real destination like Console) -
        // since the rail no longer has a per-host icon of its own to
        // highlight (the hosts-flyout redesign moved that
        // into the flyout), this is the closest equivalent: "one of the
        // things this row leads to is what's showing now," the same idea
        // "Setup" already uses for its own sub-items below.
        let hostsIsActive = active == .hosts || activeHostID != nil || isHostsFlyoutOpen
        let hostsColor = hostsIsActive ? accent : ink.withAlphaComponent(0.65)
        hostsButton.contentTintColor = hostsColor
        hostsButton.attributedTitle = attributedRowTitle("Hosts", color: hostsColor)
        hostsButton.layer?.backgroundColor = (hostsIsActive ? accentTint : .clear).cgColor

        // "Setup" itself highlights whenever one of its sub-items
        // (Bootstrap/Updates/Automation) is the active destination, or
        // whenever its own flyout is open - it has no `RailDestination` of
        // its own, so it isn't covered by the `buttons` loop above.
        // (`.automation` was missing from this check before this task - a
        // pre-existing gap in the same "does this row's own state look
        // active" class of bug the flyout-open fix addresses, fixed
        // alongside it.)
        let setupIsActive = (activeHostID == nil && (active == .updates || active == .bootstrap || active == .automation || active == .githubSync)) || isSetupFlyoutOpen
        let setupColor = setupIsActive ? accent : ink.withAlphaComponent(0.65)
        setupButton.contentTintColor = setupColor
        setupButton.attributedTitle = attributedRowTitle("Setup", color: setupColor)
        setupButton.layer?.backgroundColor = (setupIsActive ? accentTint : .clear).cgColor

        // Each flyout chevron takes its own row's resolved colour, so it
        // brightens to the accent along with the icon and label whenever that
        // row is active (which, for these two, includes "its flyout is open").
        for (button, chevron) in flyoutIndicators {
            let rowColor = button === hostsButton ? hostsColor : setupColor
            chevron.contentTintColor = rowColor
        }
        restyleAvatar(theme)
    }

    /// `fm/grandline-rail-unified-rework`: the avatar's gradient fill + ring
    /// border, split out of `restyle(_:)` since it also needs to re-run on a
    /// hover change (not just a theme change) - see `avatarGradientLayer`'s
    /// doc comment and `avatar.onHoverChange` in `loadView`. The gradient
    /// blends the old flat avatar color into the active theme's accent
    /// (rather than a flat fill); the ring is a soft accent-colored border,
    /// subtle at rest and brightening (higher alpha, slightly thicker) on
    /// hover, using the same `HoverTrackingButton` type `setupButton`/
    /// `hostsButton` already use rather than a new hover
    /// mechanism.
    private func restyleAvatar(_ theme: HelmTheme) {
        let ink = HelmTheme.nsColor(theme.chromeInkHex)
        let accent = HelmTheme.nsColor(theme.accentHex)
        let flat = HelmTheme.nsColor(theme.chromeLineHex).withAlphaComponent(0.4)
        avatar.contentTintColor = ink
        avatarGradientLayer.colors = [flat.cgColor, accent.withAlphaComponent(0.55).cgColor]
        avatar.layer?.borderWidth = avatarIsHovering ? 2 : 1.25
        avatar.layer?.borderColor = accent.withAlphaComponent(avatarIsHovering ? 0.85 : 0.4).cgColor
    }

    /// `fm/grandline-rail-unify-and-mark-polish`: the sailboat mark's own
    /// gradient tile + soft ring, mirroring `restyleAvatar(_:)`'s treatment
    /// (a flat base blending into the active theme's accent, plus a subtle
    /// accent-tinted border) rather than a custom raster asset - keeps the
    /// mark reading as this app's own established "give a plain glyph more
    /// visual weight" convention. Deliberately doesn't touch
    /// `mark.symbolConfiguration`'s weight (still owned by `setUnlocked(_:)`)
    /// or its bob animation - only the background/tint changes here.
    private func restyleMark(_ theme: HelmTheme) {
        let ink = HelmTheme.nsColor(theme.chromeInkHex)
        let accent = HelmTheme.nsColor(theme.accentHex)
        let flat = HelmTheme.nsColor(theme.chromeLineHex).withAlphaComponent(0.4)
        mark.contentTintColor = ink
        markGradientLayer.colors = [flat.cgColor, accent.withAlphaComponent(0.55).cgColor]
        mark.layer?.borderWidth = 1
        mark.layer?.borderColor = accent.withAlphaComponent(0.4).cgColor
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
            icon.configure(symbol: dest.symbol, tint: dest.flyoutTint, pointSize: 12)
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

/// The "Hosts" flyout's content (the hosts-flyout redesign,
/// replacing the old always-visible per-host icon block and its own "more
/// hosts" overflow flyout at 3+ hosts - see this file's header). One row per
/// saved host (quick-connect, same `onConnectHost` path as before - only
/// *where* the list lives changed), followed by a divider and a persistent
/// "Manage Hosts & Keys…" row that opens the real, unchanged `.hosts`
/// destination (`HostsSidebarController`) - add/edit/delete and SSH key
/// assignment are untouched, only reached through this flyout instead of a
/// permanent rail icon of its own. Same row shape/theming as
/// `SetupFlyoutViewController` above (`HoverHighlightView`, a plain
/// `NSClickGestureRecognizer` on a row with no nested real control - see the
/// Vault section's own header comment on that exact hit-testing hazard); a
/// host's icon tile is tinted with its own per-host accent color
/// (`host.accentHex`, matching the old pinned icons' own per-host tinting),
/// not one of the fixed `HelmTint` cases the "Manage Hosts & Keys…" row and
/// `SetupFlyoutViewController`'s rows use - the two content types don't
/// actually share a tinting story, so this stays its own type rather than
/// generalizing `SetupFlyoutViewController` to cover both.
private final class HostsFlyoutViewController: NSViewController {
    private let hosts: [Host]
    private let onConnect: (Host) -> Void
    private let onManage: () -> Void
    private var themeObservation: ThemeObservation?

    private static let rowWidth: CGFloat = 200

    init(hosts: [Host], onConnect: @escaping (Host) -> Void, onManage: @escaping () -> Void) {
        self.hosts = hosts
        self.onConnect = onConnect
        self.onManage = onManage
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not supported")
    }

    deinit {
        if let themeObservation { ThemeManager.shared.unobserve(themeObservation) }
    }

    override func loadView() {
        let root = NSView()
        root.wantsLayer = true
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
        var textLabels: [NSTextField] = []

        if hosts.isEmpty {
            // Was a bare `NSTextField` - one of the four §3.2 called out. At
            // this flyout's 200pt width there is no room for the `.standard`
            // treatment, but `.compact` (a 22pt glyph over centred copy) fits
            // and is the same shape every empty list in the app now shows.
            let empty = HelmEmptyState(symbol: "server.rack",
                                       body: "No saved hosts yet.\nAdd one from Manage Hosts & Keys.")
            empty.applyTheme(ThemeManager.shared.theme)
            empty.widthAnchor.constraint(equalToConstant: Self.rowWidth).isActive = true
            empty.heightAnchor.constraint(equalToConstant: 96).isActive = true
            stack.addArrangedSubview(empty)
        }

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
            label.lineBreakMode = .byTruncatingTail
            textLabels.append(label)

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
                row.widthAnchor.constraint(equalToConstant: Self.rowWidth),
            ])

            let recognizer = NSClickGestureRecognizer(target: self, action: #selector(hostRowClicked(_:)))
            row.addGestureRecognizer(recognizer)
            row.identifier = NSUserInterfaceItemIdentifier(host.id.uuidString)

            stack.addArrangedSubview(row)
        }

        let divider = NSBox()
        divider.boxType = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(divider)
        divider.widthAnchor.constraint(equalToConstant: Self.rowWidth).isActive = true

        let manageRow = HoverHighlightView()
        manageRow.cornerRadius = 8
        manageRow.translatesAutoresizingMaskIntoConstraints = false
        let manageIcon = IconTileView(size: 26, cornerRadius: 7)
        manageIcon.configure(symbol: "gearshape", tint: .neutral, pointSize: 12)
        let manageLabel = NSTextField(labelWithString: "Manage Hosts & Keys\u{2026}")
        manageLabel.font = .systemFont(ofSize: 12, weight: .medium)
        textLabels.append(manageLabel)
        let manageStack = NSStackView(views: [manageIcon, manageLabel])
        manageStack.orientation = .horizontal
        manageStack.spacing = 8
        manageStack.alignment = .centerY
        manageStack.translatesAutoresizingMaskIntoConstraints = false
        manageRow.addSubview(manageStack)
        NSLayoutConstraint.activate([
            manageStack.topAnchor.constraint(equalTo: manageRow.topAnchor, constant: 6),
            manageStack.bottomAnchor.constraint(equalTo: manageRow.bottomAnchor, constant: -6),
            manageStack.leadingAnchor.constraint(equalTo: manageRow.leadingAnchor, constant: 8),
            manageStack.trailingAnchor.constraint(equalTo: manageRow.trailingAnchor, constant: -12),
            manageRow.widthAnchor.constraint(equalToConstant: Self.rowWidth),
        ])
        manageRow.addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(manageClicked)))
        stack.addArrangedSubview(manageRow)

        themeObservation = ThemeManager.shared.observe { [weak root] theme in
            root?.layer?.backgroundColor = HelmTheme.nsColor(theme.chromeBackgroundHex).cgColor
            let ink = HelmTheme.nsColor(theme.chromeInkHex)
            let hoverTint = HelmTheme.nsColor(theme.chromeLineHex).withAlphaComponent(theme.mode == .dark ? 0.25 : 0.5)
            divider.fillColor = HelmTheme.nsColor(theme.chromeLineHex)
            for (icon, host) in rowIcons {
                let hostAccent = HelmTheme.nsColor(host.accentHex)
                icon.contentTintColor = hostAccent
                icon.superview?.layer?.backgroundColor = hostAccent.withAlphaComponent(0.16).cgColor
            }
            manageIcon.applyTheme(theme)
            for label in textLabels { label.textColor = ink }
            for case let row as HoverHighlightView in stack.arrangedSubviews {
                row.normalColor = .clear
                row.hoverColor = hoverTint
            }
            manageRow.normalColor = .clear
            manageRow.hoverColor = hoverTint
        }
    }

    @objc private func hostRowClicked(_ sender: NSClickGestureRecognizer) {
        guard let view = sender.view,
              let idString = view.identifier?.rawValue,
              let id = UUID(uuidString: idString),
              let host = hosts.first(where: { $0.id == id }) else { return }
        onConnect(host)
    }

    @objc private func manageClicked() { onManage() }
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
