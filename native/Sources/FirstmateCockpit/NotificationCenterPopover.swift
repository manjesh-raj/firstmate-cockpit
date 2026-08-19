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
// The panel itself is a plain `NSStackView` of rows, rebuilt in place on
// every `GrandLineNotificationCenter.observe` firing (the list is always
// small by design - see the design doc's "avoid noise" section - so this
// app's usual `NSTableView`-for-large-lists convention doesn't apply here).

import AppKit

/// The bell icon itself - lives in `TopBarController`, badge count driven by
/// `NotificationCenterController`.
final class NotificationBellButton: NSButton {
    private let badgeContainer = NSView()
    private let badgeLabel = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        title = ""
        isBordered = false
        wantsLayer = true
        layer?.cornerRadius = 9
        image = NSImage(systemSymbolName: "bell", accessibilityDescription: "Notifications")?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 14, weight: .regular))
        toolTip = "Notifications"
        translatesAutoresizingMaskIntoConstraints = false

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
            badgeLabel.leadingAnchor.constraint(equalTo: badgeContainer.leadingAnchor, constant: 4),
            badgeLabel.trailingAnchor.constraint(equalTo: badgeContainer.trailingAnchor, constant: -4),
            badgeLabel.topAnchor.constraint(equalTo: badgeContainer.topAnchor, constant: 1),
            badgeLabel.bottomAnchor.constraint(equalTo: badgeContainer.bottomAnchor, constant: -1),
            badgeContainer.heightAnchor.constraint(equalToConstant: 16),
            badgeContainer.widthAnchor.constraint(greaterThanOrEqualToConstant: 16),
            // Only a small (2pt) protrusion past the button's own corner -
            // the bar gives this button just 9pt of headroom above it and
            // 10pt of gap to the neighboring theme button (TopBarController's
            // own `height`/spacing constants), so a badge overlapping 5pt on
            // each side (the original value) ate most of both margins at
            // once and read as crowded/misaligned. See the rail's own
            // `attachBadge` history in AGENTS.md for the same class of fix.
            badgeContainer.topAnchor.constraint(equalTo: topAnchor, constant: -2),
            badgeContainer.trailingAnchor.constraint(equalTo: trailingAnchor, constant: 2),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    func setBadgeCount(_ count: Int) {
        badgeContainer.isHidden = count <= 0
        guard count > 0 else { return }
        badgeLabel.stringValue = count > 99 ? "99+" : "\(count)"
    }

    func applyTheme(ink: NSColor, line: NSColor, surface: NSColor) {
        contentTintColor = ink.withAlphaComponent(0.75)
        layer?.backgroundColor = surface.cgColor
        layer?.borderWidth = 1
        layer?.borderColor = line.withAlphaComponent(0.5).cgColor
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
            popover.show(relativeTo: bell.bounds, of: bell, preferredEdge: .minY)
        }
    }

    func popoverDidClose(_ notification: Notification) {}
}

/// The panel content: a header ("Notifications" + "Mark all read"), one row
/// per entry, and an empty state when there is nothing to show.
private final class NotificationPanelViewController: NSViewController {
    private var theme = ThemeManager.shared.theme

    static let width: CGFloat = 320

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
        rowsStack.spacing = 0
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
        for (index, entry) in entries.enumerated() {
            let row = NotificationRowView(entry: entry, showsBottomDivider: index < entries.count - 1)
            row.translatesAutoresizingMaskIntoConstraints = false
            row.onClick = { [weak self] in
                entry.navigate()
                self?.onRequestClose?()
            }
            rowsStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: rowsStack.widthAnchor).isActive = true
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
        for case let row as NotificationRowView in rowsStack.arrangedSubviews {
            row.applyTheme(theme)
        }
    }
}

/// One notification row - a colored dot, a title, and a subtext line
/// stating its own clear-rule (matching the panel mock's copy exactly),
/// wrapped in a `HoverHighlightView` per this app's standing row convention.
private final class NotificationRowView: NSView {
    private let hover = HoverHighlightView()
    private let dot = NSView()
    private let titleLabel = NSTextField(wrappingLabelWithString: "")
    private let subtextLabel = NSTextField(wrappingLabelWithString: "")
    private let bottomDivider = NSView()
    private let tint: HelmTint
    private let showsBottomDivider: Bool

    var onClick: (() -> Void)?

    init(entry: AppNotification, showsBottomDivider: Bool) {
        self.tint = entry.tint
        self.showsBottomDivider = showsBottomDivider
        super.init(frame: .zero)

        hover.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hover)

        dot.wantsLayer = true
        dot.layer?.cornerRadius = 4
        dot.translatesAutoresizingMaskIntoConstraints = false
        dot.setContentHuggingPriority(.required, for: .horizontal)
        dot.setContentCompressionResistancePriority(.required, for: .horizontal)

        titleLabel.font = .systemFont(ofSize: 12, weight: .medium)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        subtextLabel.font = .systemFont(ofSize: 10.5)
        subtextLabel.translatesAutoresizingMaskIntoConstraints = false
        subtextLabel.stringValue = entry.subtext
        subtextLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        titleLabel.stringValue = entry.title

        let textStack = NSStackView(views: [titleLabel, subtextLabel])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 2
        textStack.translatesAutoresizingMaskIntoConstraints = false

        bottomDivider.wantsLayer = true
        bottomDivider.translatesAutoresizingMaskIntoConstraints = false
        bottomDivider.isHidden = !showsBottomDivider

        addSubview(bottomDivider)
        hover.addSubview(dot)
        hover.addSubview(textStack)

        NSLayoutConstraint.activate([
            hover.leadingAnchor.constraint(equalTo: leadingAnchor),
            hover.trailingAnchor.constraint(equalTo: trailingAnchor),
            hover.topAnchor.constraint(equalTo: topAnchor),
            hover.bottomAnchor.constraint(equalTo: bottomAnchor),

            dot.widthAnchor.constraint(equalToConstant: 8),
            dot.heightAnchor.constraint(equalToConstant: 8),
            dot.leadingAnchor.constraint(equalTo: hover.leadingAnchor, constant: 14),
            dot.topAnchor.constraint(equalTo: hover.topAnchor, constant: 16),

            textStack.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 10),
            textStack.trailingAnchor.constraint(equalTo: hover.trailingAnchor, constant: -14),
            textStack.topAnchor.constraint(equalTo: hover.topAnchor, constant: 10),
            textStack.bottomAnchor.constraint(equalTo: hover.bottomAnchor, constant: -10),

            bottomDivider.leadingAnchor.constraint(equalTo: leadingAnchor),
            bottomDivider.trailingAnchor.constraint(equalTo: trailingAnchor),
            bottomDivider.bottomAnchor.constraint(equalTo: bottomAnchor),
            bottomDivider.heightAnchor.constraint(equalToConstant: 1),
        ])

        addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(clicked)))
        applyTheme(ThemeManager.shared.theme)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    @objc private func clicked() { onClick?() }

    func applyTheme(_ theme: HelmTheme) {
        let ink = HelmTheme.nsColor(theme.chromeInkHex)
        let muted = HelmTheme.mutedInk(theme)
        let line = HelmTheme.nsColor(theme.chromeLineHex)
        dot.layer?.backgroundColor = HelmTheme.nsColor(tint.hex(in: theme)).cgColor
        titleLabel.textColor = ink
        subtextLabel.textColor = muted
        bottomDivider.layer?.backgroundColor = line.withAlphaComponent(0.5).cgColor
        hover.normalColor = .clear
        hover.hoverColor = line.withAlphaComponent(0.15)
    }
}
