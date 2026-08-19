// Manjesh Grand Line - native macOS app.
//
// The topbar bell + its dropdown panel (`fm/grandline-notification-center`,
// captain-approved design: `data/grandline-notification-center/design-
// reference.html`). Sits between `TopBarController`'s existing `searchPill`
// and `themeButton` - the design doc's own annotated screenshot shows
// exactly this gap. Structurally mirrors `ConsoleComposerPopover.swift`/
// `QuotaUsagePopover.swift` (transient `NSPopover`, live `ThemeManager`
// observation, a `wantsLayer` root with an explicit theme background per
// AGENTS.md gotcha #8) - the same "small card off a topbar/toolbar icon"
// idiom this app already uses twice, not a new UI pattern.
//
// `NotificationBellButton` is a plain `NSButton` styled like `TopBarController.
// themeButton`, with a small badge overlay reusing `IconRailController.
// attachBadge`'s own fixed white-on-systemRed convention (never a theme-
// tinted badge - "reads as an alert the same way regardless of theme,"
// per that method's own doc comment) rather than inventing a second badge
// visual language.
//
// `fm/grandline-notification-bell-badge-fix` shipped the badge 2pt outside
// the button's own top-right corner (down from an original 5pt) - still not
// enough, per a second captain screenshot: at a 34x34 box with a 9pt corner
// radius, the rounded curve starts well before the flat edges, so *any*
// small overlap positioned at that diagonal corner point cuts across the
// curve itself. This is the exact same lesson `IconRailController.
// attachBadge` already learned the hard way (see its own doc comment/
// AGENTS.md's `fm/grandline-rail-followup-fixes` history) - two overlap-
// tuning attempts there still collided with an icon's ink, and the only fix
// that actually worked was to stop overlapping the icon's box at all.
// `fm/grandline-notification-bell-badge-fix-2` applies that same shape here:
// the *visible bordered square* (`iconBackground`) stays a fixed 34x34 -
// matching `themeButton` exactly - while the button's own overall frame
// (`NotificationBellButton.controlWidth`) is widened so the badge
// (`badgeContainer`) can sit fully to the icon's right (`iconBackground.
// trailingAnchor + 3`, never overlapping its frame) with its vertical
// center pinned near the icon's own top edge, mirroring `attachBadge`'s
// `iconAnchor.trailingAnchor + 3` / `iconAnchor.topAnchor + 2` constants
// exactly. `TopBarController`'s width constant for the bell grew to match;
// its leading/trailing anchor formulas relative to `searchPill`/`themeButton`
// were deliberately left untouched (see that file's own comment) so the
// bell's visible icon square keeps the same 10pt gap to `searchPill` it
// always had - only the reserved zone to the icon's right changed.
//
// The panel itself is a plain `NSStackView` of rows, rebuilt in place on
// every `GrandLineNotificationCenter.observe` firing (the list is always
// small by design - see the design doc's "avoid noise" section - so this
// app's usual `NSTableView`-for-large-lists convention doesn't apply here).
//
// `fm/grandline-notification-row-redesign` restyled each row from a flat,
// borderless dot+title+subtext line into its own bordered "claim card"
// (captain reference: a Slack-RCA claims panel - `data/grandline-
// notification-row-redesign/reference-target.png`) - a colored left accent
// bar, a small round icon badge, a bold uppercase kicker label, the body
// message, and a trailing chip carrying the entry's own source/clear-rule
// text. This is a rendering-only pass: `GrandLineNotificationCenter`'s store,
// the 9 signal adapters (`NotificationSources.swift`), dedup/clear
// semantics, and the bell's badge count are all untouched - only how each
// entry renders inside `rowsStack`. The reference's literal "numbered
// sequence" framing (steps 1-4 of one incident) doesn't apply to an
// unordered notification list, so only the *visual pattern* was carried
// over, not the numbering - see `NotificationRowPresentation` for the per-
// source icon/kicker mapping this needed (derived from each source's
// already-stable `id`, not a new field on `AppNotification`). The card
// border/fill mirrors `ToolRowLayout`'s existing `cardStyle` idiom
// (`HelmUIComponents.swift`, `fm/grandline-vault-row-polish`) rather than a
// second card mechanism, and the trailing chip reuses `ToolRowLayout.pill`
// directly - `ToolRowLayout.build`'s own icon-tile/trailing-stack/chevron/
// log assembly doesn't fit this row's shape (no expandable log, no button
// stack, needs a left accent bar `ToolRowLayout` has no concept of), so the
// row itself stays a bespoke view rather than forcing a mismatched fit.

import AppKit

/// The bell icon itself - lives in `TopBarController`, badge count driven by
/// `NotificationCenterController`.
///
/// The button's own frame (`NotificationBellButton.controlWidth` wide) is
/// deliberately wider than the visible icon square: `iconBackground` is the
/// real, bordered 34x34 surface (matching `themeButton` exactly, so the two
/// read as the same shape), pinned to the button's leading edge, and the
/// badge lives entirely in the extra width to its right - see the file
/// header comment for why an overlapping badge can never look clean at this
/// corner radius. The whole widened frame stays the click target (same as
/// before this fix, when the whole 34x34 square was one button) - clicking
/// in the reserved badge zone still opens the panel.
final class NotificationBellButton: NSButton {
    /// The visible, bordered icon square's fixed size - matches
    /// `TopBarController.themeButton` exactly.
    static let iconSize: CGFloat = 34
    /// Real clearance between the icon square's own trailing edge and the
    /// badge, mirroring `IconRailController.attachBadge`'s `+ 3` gap.
    private static let badgeGap: CGFloat = 3
    /// Reserved width for the badge zone - comfortably fits "99+" at the
    /// badge's own 9pt bold monospaced-digit font with room to spare, so the
    /// badge never needs to grow into (or short of) exactly this space.
    /// Measured live: a real "99+" badge (4pt padding each side) renders
    /// ~31pt wide - 32pt leaves a hair of clearance with no overflow past
    /// the button's own declared frame.
    private static let badgeZoneWidth: CGFloat = 32
    /// The button's total width: the icon square, the gap, and the reserved
    /// badge zone. `TopBarController` sizes the bell to exactly this.
    static let controlWidth: CGFloat = iconSize + badgeGap + badgeZoneWidth

    private let iconBackground = NSView()
    private let iconImageView = NSImageView()
    private let badgeContainer = NSView()
    private let badgeLabel = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        title = ""
        isBordered = false
        image = nil
        toolTip = "Notifications"
        setAccessibilityLabel("Notifications")
        translatesAutoresizingMaskIntoConstraints = false

        iconBackground.wantsLayer = true
        iconBackground.layer?.cornerRadius = 9
        iconBackground.translatesAutoresizingMaskIntoConstraints = false
        // Decorative only - clicks are handled by the button itself, and
        // this view never needs to intercept them ahead of that.
        addSubview(iconBackground)

        iconImageView.image = NSImage(systemSymbolName: "bell", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 14, weight: .regular))
        iconImageView.imageScaling = .scaleProportionallyDown
        iconImageView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(iconImageView)

        badgeLabel.font = .monospacedDigitSystemFont(ofSize: 9, weight: .bold)
        badgeLabel.textColor = .white
        badgeLabel.alignment = .center
        badgeLabel.translatesAutoresizingMaskIntoConstraints = false

        badgeContainer.wantsLayer = true
        badgeContainer.layer?.cornerRadius = 8
        badgeContainer.layer?.backgroundColor = NSColor.systemRed.cgColor
        badgeContainer.translatesAutoresizingMaskIntoConstraints = false
        badgeContainer.isHidden = true
        badgeContainer.addSubview(badgeLabel)
        addSubview(badgeContainer)

        NSLayoutConstraint.activate([
            iconBackground.leadingAnchor.constraint(equalTo: leadingAnchor),
            iconBackground.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconBackground.widthAnchor.constraint(equalToConstant: Self.iconSize),
            iconBackground.heightAnchor.constraint(equalToConstant: Self.iconSize),

            iconImageView.centerXAnchor.constraint(equalTo: iconBackground.centerXAnchor),
            iconImageView.centerYAnchor.constraint(equalTo: iconBackground.centerYAnchor),

            badgeLabel.leadingAnchor.constraint(equalTo: badgeContainer.leadingAnchor, constant: 4),
            badgeLabel.trailingAnchor.constraint(equalTo: badgeContainer.trailingAnchor, constant: -4),
            badgeLabel.topAnchor.constraint(equalTo: badgeContainer.topAnchor, constant: 1),
            badgeLabel.bottomAnchor.constraint(equalTo: badgeContainer.bottomAnchor, constant: -1),
            badgeContainer.heightAnchor.constraint(equalToConstant: 16),
            badgeContainer.widthAnchor.constraint(greaterThanOrEqualToConstant: 16),
            // Entirely to the icon square's right, never overlapping its
            // frame - the same shape as `IconRailController.attachBadge`'s
            // own fix for this exact class of bug (see the file header and
            // that method's own doc comment for the full history).
            badgeContainer.leadingAnchor.constraint(equalTo: iconBackground.trailingAnchor, constant: Self.badgeGap),
            badgeContainer.centerYAnchor.constraint(equalTo: iconBackground.topAnchor, constant: 2),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    /// The visible icon square's frame, in the button's own coordinate space -
    /// used to anchor the popover on the icon itself, not the wider control.
    var visibleIconFrame: NSRect { iconBackground.frame }

    func setBadgeCount(_ count: Int) {
        badgeContainer.isHidden = count <= 0
        guard count > 0 else { return }
        badgeLabel.stringValue = count > 99 ? "99+" : "\(count)"
    }

    func applyTheme(ink: NSColor, line: NSColor, surface: NSColor) {
        iconImageView.contentTintColor = ink.withAlphaComponent(0.75)
        iconBackground.layer?.backgroundColor = surface.cgColor
        iconBackground.layer?.borderWidth = 1
        iconBackground.layer?.borderColor = line.withAlphaComponent(0.5).cgColor
    }
}

/// Owns the popover, the bell's live badge count, and the panel content -
/// the topbar's counterpart to `ConsoleComposerController`/
/// `QuotaUsageController`.
final class NotificationCenterController: NSObject, NSPopoverDelegate {
    let bell = NotificationBellButton()

    private let popover = NSPopover()
    private let content = NotificationPanelViewController()
    private var themeObservation: ThemeObservation?
    private var storeObservation: NotificationCenterObservation?

    override init() {
        super.init()
        popover.contentViewController = content
        popover.behavior = .transient
        popover.delegate = self
        bell.target = self
        bell.action = #selector(bellClicked)
        content.onSizeChanged = { [weak self] size in
            self?.popover.contentSize = size
        }
        content.onRequestClose = { [weak self] in
            self?.popover.performClose(nil)
        }
        themeObservation = ThemeManager.shared.observe { [weak self] theme in
            guard let self else { return }
            self.popover.appearance = NSAppearance(named: theme.mode == .dark ? .darkAqua : .aqua)
            self.content.applyTheme(theme)
        }
        // Fires immediately on registration too, so the bell's badge is
        // correct before the captain ever opens the panel - every source's
        // own initial check (fired on launch/page-visit/poll) lands here
        // the same way.
        storeObservation = GrandLineNotificationCenter.shared.observe { [weak self] in
            guard let self else { return }
            self.bell.setBadgeCount(GrandLineNotificationCenter.shared.badgeCount)
            if self.popover.isShown { self.content.reload() }
        }
    }

    @objc private func bellClicked() {
        if popover.isShown {
            popover.performClose(nil)
        } else {
            content.reload()
            // Anchor on the visible icon square, not the wider control frame
            // (which now includes the reserved badge zone) - keeps the panel
            // lined up under the icon exactly like before this fix.
            popover.show(relativeTo: bell.visibleIconFrame, of: bell, preferredEdge: .minY)
        }
    }

    func popoverDidClose(_ notification: Notification) {}
}

/// The panel content: a header ("Notifications" + "Mark all read"), one row
/// per entry, and an empty state when there is nothing to show.
private final class NotificationPanelViewController: NSViewController {
    private var theme = ThemeManager.shared.theme

    // Widened from the original flat-list width (320) to give the new card
    // treatment (left accent bar + icon badge + trailing chip) room to
    // breathe without feeling cramped - still a modest popover width, not a
    // dramatic widening.
    static let width: CGFloat = 340

    private let titleLabel = NSTextField(labelWithString: "Notifications")
    private let markAllReadLabel = NSTextField(labelWithString: "Mark all read")
    private let emptyStateLabel = NSTextField(wrappingLabelWithString: "You're all caught up.")
    private let rowsStack = NSStackView()
    private let separator = NSView()

    var onSizeChanged: ((NSSize) -> Void)?
    var onRequestClose: (() -> Void)?

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: Self.width, height: 200))
        root.wantsLayer = true
        view = root

        titleLabel.font = .systemFont(ofSize: 13.5, weight: .semibold)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

        markAllReadLabel.font = .systemFont(ofSize: 11, weight: .medium)
        markAllReadLabel.translatesAutoresizingMaskIntoConstraints = false
        markAllReadLabel.setContentHuggingPriority(.required, for: .horizontal)
        markAllReadLabel.addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(markAllReadClicked)))

        let headerRow = NSStackView(views: [titleLabel, markAllReadLabel])
        headerRow.orientation = .horizontal
        headerRow.distribution = .fill
        headerRow.alignment = .centerY
        headerRow.translatesAutoresizingMaskIntoConstraints = false

        separator.wantsLayer = true
        separator.translatesAutoresizingMaskIntoConstraints = false
        separator.heightAnchor.constraint(equalToConstant: 1).isActive = true

        emptyStateLabel.font = .systemFont(ofSize: 11.5)
        emptyStateLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyStateLabel.alignment = .center

        rowsStack.orientation = .vertical
        rowsStack.alignment = .leading
        // Cards are now separated by visible gaps (each has its own border/
        // fill), not a hairline divider baked into each row - see
        // `HelmAccentRow`.
        rowsStack.spacing = 8
        rowsStack.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [headerRow, separator, emptyStateLabel, rowsStack])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.setCustomSpacing(10, after: headerRow)
        stack.setCustomSpacing(10, after: separator)
        root.addSubview(stack)

        NSLayoutConstraint.activate([
            root.widthAnchor.constraint(equalToConstant: Self.width),
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            stack.topAnchor.constraint(equalTo: root.topAnchor),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: root.bottomAnchor),
            headerRow.leadingAnchor.constraint(equalTo: stack.leadingAnchor, constant: 14),
            headerRow.trailingAnchor.constraint(equalTo: stack.trailingAnchor, constant: -14),
            separator.widthAnchor.constraint(equalTo: stack.widthAnchor),
            emptyStateLabel.leadingAnchor.constraint(equalTo: stack.leadingAnchor, constant: 14),
            emptyStateLabel.trailingAnchor.constraint(equalTo: stack.trailingAnchor, constant: -14),
            rowsStack.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        // The header row sits directly against the top edge; give it its
        // own top inset via the stack's own top anchor plus a fixed spacer -
        // simplest is just an explicit constant on the header's containing
        // insets via the stack's edgeInsets.
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 0, bottom: 12, right: 0)

        applyTheme(theme)
        reload()
    }

    /// Rebuilds every row from the current store state - always small (see
    /// this file's header), so a full rebuild on every change is simpler
    /// and cheap, matching `BootstrapController`'s own "card, rebuilt in
    /// place" sections rather than an incremental diff.
    func reload() {
        for view in rowsStack.arrangedSubviews {
            rowsStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        let entries = GrandLineNotificationCenter.shared.entries
        emptyStateLabel.isHidden = !entries.isEmpty
        markAllReadLabel.isHidden = !entries.contains { $0.kind == .informational }
        for entry in entries {
            let row = Self.makeRow(for: entry, theme: theme)
            row.translatesAutoresizingMaskIntoConstraints = false
            row.onClick = { [weak self] in
                entry.navigate()
                self?.onRequestClose?()
            }
            rowsStack.addArrangedSubview(row)
            // Each card gets its own margin from the panel's edges (unlike
            // the old full-bleed row, whose hover fill ran edge to edge) -
            // an explicit leading/trailing offset from `rowsStack`, not a
            // width-equal-to-stack constraint, is what creates that margin.
            NSLayoutConstraint.activate([
                row.leadingAnchor.constraint(equalTo: rowsStack.leadingAnchor, constant: 14),
                row.trailingAnchor.constraint(equalTo: rowsStack.trailingAnchor, constant: -14),
            ])
        }
        applyTheme(theme)
        updateSize()
    }

    private func updateSize() {
        view.layoutSubtreeIfNeeded()
        onSizeChanged?(view.fittingSize)
    }

    @objc private func markAllReadClicked() {
        GrandLineNotificationCenter.shared.markAllRead()
    }

    func applyTheme(_ theme: HelmTheme) {
        self.theme = theme
        let ink = HelmTheme.nsColor(theme.chromeInkHex)
        let muted = HelmTheme.mutedInk(theme)
        let line = HelmTheme.nsColor(theme.chromeLineHex)
        let accent = HelmTheme.nsColor(theme.accentHex)

        view.layer?.backgroundColor = HelmTheme.nsColor(theme.chromeBackgroundHex).cgColor
        titleLabel.textColor = ink
        markAllReadLabel.textColor = accent
        separator.layer?.backgroundColor = line.cgColor
        emptyStateLabel.textColor = muted
        for case let row as HelmAccentRow in rowsStack.arrangedSubviews {
            row.applyTheme(theme)
        }
    }

    /// One notification row, built from the app's shared accent row.
    ///
    /// This row *is* `HelmAccentRow`'s source: the component
    /// (`HelmDesignSystem.swift`, audit §6.3 component 2) is the recipe that
    /// used to live here, promoted so Shift's task and follow-up lists, SRE
    /// Lead's findings and Overview's "In flight" rows could stop
    /// re-implementing it. What is left here is the part that is genuinely
    /// about notifications: which glyph and kicker a given source gets
    /// (`NotificationRowPresentation`), and what the chip says.
    ///
    /// `.belowBody` because this panel is narrow (`Self.width`) - too narrow
    /// for a chip beside wrapping body text.
    static func makeRow(for entry: AppNotification, theme: HelmTheme) -> HelmAccentRow {
        let presentation = NotificationRowPresentation(for: entry)
        let row = HelmAccentRow(chipPlacement: .belowBody)
        row.configure(HelmAccentRow.Content(tint: entry.tint,
                                            kicker: presentation.kicker,
                                            title: entry.title,
                                            badgeSymbol: presentation.icon,
                                            chipText: entry.subtext,
                                            titleWraps: true),
                      theme: theme)
        return row
    }
}

/// Per-source icon + kicker label for a notification row - derived from each
/// source's own stable `id` (see `NotificationSources.swift`), not a new
/// field on `AppNotification` (this is a rendering-only pass; the store
/// stays untouched). Falls back to a generic bell/kind-based kicker for any
/// id this mapping doesn't recognize, so a future signal added without a
/// matching case here still renders sensibly rather than crashing or
/// showing nothing.
private struct NotificationRowPresentation {
    let icon: String
    let kicker: String

    init(for entry: AppNotification) {
        switch entry.id {
        case NotificationSources.fleetDecisionsID:
            icon = "person.crop.circle.badge.exclamationmark"
            kicker = "Decision Needed"
        case NotificationSources.prReadyID:
            icon = "checkmark.circle.fill"
            kicker = "PR Ready"
        case NotificationSources.toolUpdatesID:
            icon = "arrow.down.circle.fill"
            kicker = "Update Available"
        case NotificationSources.githubSyncID:
            icon = "arrow.triangle.branch"
            kicker = "Fork Behind"
        case NotificationSources.vaultAttentionID:
            icon = "lock.shield.fill"
            kicker = "Needs Attention"
        case NotificationSources.setupDriftID:
            icon = "wrench.and.screwdriver.fill"
            kicker = "Setup Drifted"
        case NotificationSources.shiftDueID:
            icon = "clock.fill"
            kicker = "Due Or Overdue"
        case NotificationSources.fleetFinishedID:
            icon = "flag.checkered"
            kicker = "Task Finished"
        default:
            if entry.id.hasPrefix("sre-lead.") {
                icon = "bubble.left.fill"
                kicker = "SRE Lead Reply"
            } else {
                icon = "bell.fill"
                kicker = entry.kind == .actionNeeded ? "Action Needed" : "Update"
            }
        }
    }
}


