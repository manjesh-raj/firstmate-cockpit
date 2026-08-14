// Manjesh Grand Line - native macOS app.
//
// Shared visual helpers for the modern-UI restyle (cockpit-modern-ui-settings,
// phase 1 of a captain-reviewed HTML/CSS mockup - see that task's PR for the
// mockup file). Both pieces here generalize a pattern `UpdatesController`
// already had one copy of (`UpdatesController.tintHex(for:)` + its inline
// icon-tile layout in `buildRow`) into a single reusable location so
// `SettingsController` and later pages (Updates, Bootstrap) don't each grow
// their own copy.
//
// Every color either piece produces traces back to the active `HelmTheme` -
// `HelmTint` picks one of the theme's own hues, and `HoverHighlightView`'s
// callers always pass it a theme-derived `NSColor`, never a literal hex.

import AppKit

/// A semantic tint category for an icon tile, resolved against a theme's own
/// hues rather than a fixed hex - mirrors `UpdatesController.tintHex(for:)`,
/// generalized so any page can pick "this is an info/success/warning/danger/
/// accent-ish thing" and get back whichever hex reads that way in the active
/// Helm palette.
enum HelmTint {
    case accent
    case info
    case good
    case warn
    case critical
    case violet
    case neutral

    func hex(in theme: HelmTheme) -> String {
        switch self {
        case .accent: return theme.accentHex
        case .info: return theme.ansiHex[4]      // blue
        case .good: return theme.ansiHex[2]       // green
        case .warn: return theme.ansiHex[3]       // yellow/amber
        case .critical: return theme.ansiHex[1]   // red
        case .violet: return theme.ansiHex[5]     // magenta ("violet")
        case .neutral: return theme.chromeInkHex
        }
    }
}

/// The shared "icon-in-colored-tile" view (mockup's `.tile` squares): an SF
/// Symbol centered over a ~34x34pt, ~9pt-corner-radius layer-backed square,
/// its background a soft tint of one of the active theme's own hues. Call
/// `configure` once to set the glyph and tint, then `applyTheme` again
/// whenever the active `HelmTheme` changes (callers already have a
/// `ThemeManager.shared.observe` hook for this).
final class IconTileView: NSView {
    private let imageView = NSImageView()
    private var tint: HelmTint = .accent

    init(size: CGFloat = 34, cornerRadius: CGFloat = 9) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = cornerRadius
        translatesAutoresizingMaskIntoConstraints = false
        imageView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(imageView)
        NSLayoutConstraint.activate([
            imageView.centerXAnchor.constraint(equalTo: centerXAnchor),
            imageView.centerYAnchor.constraint(equalTo: centerYAnchor),
            widthAnchor.constraint(equalToConstant: size),
            heightAnchor.constraint(equalToConstant: size),
        ])
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not supported")
    }

    func configure(symbol: String, tint: HelmTint, pointSize: CGFloat = 15) {
        self.tint = tint
        imageView.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: pointSize, weight: .semibold))
        applyTheme(ThemeManager.shared.theme)
    }

    func applyTheme(_ theme: HelmTheme) {
        let color = HelmTheme.nsColor(tint.hex(in: theme))
        layer?.backgroundColor = color.withAlphaComponent(0.16).cgColor
        imageView.contentTintColor = color
    }
}

extension NSColor {
    /// Shifts `self` toward whichever of black/white reads as "hover" for a
    /// given theme mode - lighten on dark palettes, darken on light ones.
    /// Same "blend toward an endpoint chosen by mode" idea `Dimming.swift`
    /// uses for terminal contrast, applied here to derive a hover shade from
    /// a real theme color instead of picking a new literal one.
    func hoverShifted(by fraction: CGFloat, forMode mode: HelmTheme.Mode) -> NSColor {
        let endpoint: NSColor = mode == .dark ? .white : .black
        guard let base = usingColorSpace(.sRGB), let endpoint = endpoint.usingColorSpace(.sRGB) else { return self }
        return base.blended(withFraction: fraction, of: endpoint) ?? self
    }
}

/// The shared hover-state helper for a row or button-like control: an
/// `NSTrackingArea` swaps `layer.backgroundColor` between `normalColor` and
/// `hoverColor` on mouse enter/exit, animated via `NSAnimationContext` unless
/// the user has "Reduce motion" on (`NSWorkspace.
/// accessibilityDisplayShouldReduceMotion`), in which case the swap is
/// instant. Callers own picking theme-derived colors; this view only owns the
/// tracking + animation mechanics.
final class HoverHighlightView: NSView {
    var normalColor: NSColor = .clear {
        didSet { if !isHovering { setBackground(normalColor, animated: false) } }
    }
    var hoverColor: NSColor = .clear

    var cornerRadius: CGFloat = 0 {
        didSet { layer?.cornerRadius = cornerRadius }
    }

    private var isHovering = false
    private var trackingArea: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not supported")
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovering = true
        setBackground(hoverColor, animated: true)
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
        setBackground(normalColor, animated: true)
    }

    private func setBackground(_ color: NSColor, animated: Bool) {
        guard let layer else { return }
        guard animated, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            layer.backgroundColor = color.cgColor
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            layer.backgroundColor = color.cgColor
        }
    }
}

/// The shared "tool checklist row" layout: an `IconTileView`, a name/detail
/// text stack, a caller-populated trailing-controls stack, a disclosure
/// chevron, and an expandable command-output log panel, all wrapped in a
/// `HoverHighlightView`. `UpdatesController`'s per-tool rows and
/// `BootstrapController`'s software checklist rows both need this exact same
/// assembly (cockpit-bootstrap-software-row-parity) - factored here once so
/// the two pages render rows identically instead of maintaining two
/// divergent copies of the same NSStackView/constraint plumbing.
enum ToolRowLayout {
    /// The concrete view instances a row owns. Callers may create these fresh
    /// on every render (Bootstrap's existing "tear down and rebuild" pattern)
    /// or hold them for the row's whole lifetime and mutate in place
    /// (Updates' existing pattern) - `build`/`applyTheme` don't care which.
    struct Views {
        let iconTile: IconTileView
        let nameLabel: NSTextField
        let detailLabel: NSTextField
        let pill: NSView
        let pillLabel: NSTextField
        let trailingStack: NSStackView
        let detailsButton: NSButton
        let logField: NSTextField
        let logContainer: NSView
        let rowContainer: HoverHighlightView
    }

    /// Assembles `views` into one row and returns the top-level view to place
    /// in a stack. `trailingViews` (e.g. a status pill plus Check/Update/
    /// Install buttons or a spinner) are inserted into `views.trailingStack`
    /// in order, after `views.pill` - callers configure `views.pill`'s
    /// content themselves (see `pill(text:colorHex:into:)`) and pass it as
    /// the first trailing view.
    ///
    /// `showDetails` controls whether the row gets the disclosure chevron +
    /// expandable command-output log (Software checklist's rows, which have a
    /// real `CheckOutcome.log`) or omits both entirely (Bootstrap's "Managed
    /// items"/"Global agent instructions"/"Run full setup" step rows, which
    /// have no log to show) - `detailsTarget`/`detailsAction` are only
    /// meaningful when `showDetails` is true.
    ///
    /// `cardStyle` (default `false`, so every existing caller - Updates,
    /// Bootstrap - is byte-for-byte unchanged) switches the row from
    /// "flat, hover-only highlight" to a clearly bounded card: a persistent
    /// `chromeBackgroundHex` fill + `chromeLineHex` border (the exact tokens
    /// `ShiftPanelView.applyTheme` already uses for its own card look, not a
    /// new color scheme) and roomier internal padding, for a page whose rows
    /// are the primary content rather than a dense checklist (fm/grandline-
    /// vault-row-polish). Pair with `applyTheme(cardStyle:attentionHex:)`.
    static func build(
        _ views: Views,
        iconSymbol: String,
        tint: HelmTint,
        name: String,
        trailingViews: [NSView],
        detailsTarget: AnyObject? = nil,
        detailsAction: Selector? = nil,
        identifier: String,
        showDetails: Bool = true,
        cardStyle: Bool = false
    ) -> NSView {
        views.iconTile.configure(symbol: iconSymbol, tint: tint, pointSize: 14)
        views.iconTile.setContentHuggingPriority(.required, for: .horizontal)
        views.iconTile.setContentCompressionResistancePriority(.required, for: .horizontal)

        views.nameLabel.stringValue = name
        views.nameLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        views.nameLabel.lineBreakMode = .byTruncatingTail
        views.nameLabel.maximumNumberOfLines = 1

        views.detailLabel.font = .systemFont(ofSize: 10.5)
        views.detailLabel.lineBreakMode = .byTruncatingTail
        views.detailLabel.maximumNumberOfLines = 1

        let textStack = NSStackView(views: [views.nameLabel, views.detailLabel])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 2
        textStack.setContentHuggingPriority(.defaultLow, for: .horizontal)
        textStack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        views.trailingStack.orientation = .horizontal
        views.trailingStack.spacing = 8
        views.trailingStack.alignment = .centerY
        views.trailingStack.translatesAutoresizingMaskIntoConstraints = false
        // NSStackView's own horizontal hugging priority defaults lower than
        // any arranged-subview priority set on its children, so without this
        // the stack itself (not `textStack`) can end up absorbing `topRow`'s
        // slack width - leaving the chevron short of the trailing edge.
        views.trailingStack.setContentHuggingPriority(.required, for: .horizontal)
        views.trailingStack.setContentCompressionResistancePriority(.required, for: .horizontal)
        for v in trailingViews {
            v.setContentHuggingPriority(.required, for: .horizontal)
            v.setContentCompressionResistancePriority(.required, for: .horizontal)
            views.trailingStack.addArrangedSubview(v)
        }

        var topRowViews: [NSView] = [views.iconTile, textStack, views.trailingStack]
        if showDetails {
            views.detailsButton.title = ""
            views.detailsButton.isBordered = false
            views.detailsButton.image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: "Show details")
            views.detailsButton.imageScaling = .scaleProportionallyDown
            views.detailsButton.target = detailsTarget
            views.detailsButton.action = detailsAction
            views.detailsButton.identifier = NSUserInterfaceItemIdentifier(identifier)
            views.detailsButton.translatesAutoresizingMaskIntoConstraints = false
            views.detailsButton.setContentHuggingPriority(.required, for: .horizontal)
            views.detailsButton.toolTip = "Show command output"
            topRowViews.append(views.detailsButton)
        } else {
            views.detailsButton.isHidden = true
        }

        let topRow = NSStackView(views: topRowViews)
        topRow.orientation = .horizontal
        topRow.alignment = .centerY
        topRow.spacing = 8
        // Default `.gravityAreas` distribution doesn't honor per-view hugging
        // priorities to fill slack width - `.fill` is what makes `textStack`'s
        // low hugging priority absorb the row's slack so the chevron stays
        // pinned to the trailing edge.
        topRow.distribution = .fill
        topRow.translatesAutoresizingMaskIntoConstraints = false

        var columnViews: [NSView] = [topRow]
        if showDetails {
            views.logField.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
            views.logField.preferredMaxLayoutWidth = 560
            views.logField.translatesAutoresizingMaskIntoConstraints = false
            views.logContainer.wantsLayer = true
            views.logContainer.layer?.cornerRadius = 6
            views.logContainer.translatesAutoresizingMaskIntoConstraints = false
            if views.logField.superview !== views.logContainer {
                views.logContainer.addSubview(views.logField)
                NSLayoutConstraint.activate([
                    views.logField.leadingAnchor.constraint(equalTo: views.logContainer.leadingAnchor, constant: 8),
                    views.logField.trailingAnchor.constraint(equalTo: views.logContainer.trailingAnchor, constant: -8),
                    views.logField.topAnchor.constraint(equalTo: views.logContainer.topAnchor, constant: 6),
                    views.logField.bottomAnchor.constraint(equalTo: views.logContainer.bottomAnchor, constant: -6),
                ])
            }
            columnViews.append(views.logContainer)
        } else {
            views.logContainer.isHidden = true
        }

        let column = NSStackView(views: columnViews)
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 6
        column.translatesAutoresizingMaskIntoConstraints = false
        topRow.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
        if showDetails {
            views.logContainer.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
        }

        views.rowContainer.cornerRadius = cardStyle ? 10 : 8
        views.rowContainer.translatesAutoresizingMaskIntoConstraints = false
        let inset: CGFloat = cardStyle ? 14 : 4
        let verticalInset: CGFloat = cardStyle ? 12 : 4
        if column.superview !== views.rowContainer {
            views.rowContainer.addSubview(column)
            NSLayoutConstraint.activate([
                column.leadingAnchor.constraint(equalTo: views.rowContainer.leadingAnchor, constant: inset),
                column.trailingAnchor.constraint(equalTo: views.rowContainer.trailingAnchor, constant: -inset),
                column.topAnchor.constraint(equalTo: views.rowContainer.topAnchor, constant: verticalInset),
                column.bottomAnchor.constraint(equalTo: views.rowContainer.bottomAnchor, constant: -verticalInset),
            ])
        }
        return views.rowContainer
    }

    /// Configures a pill's fill/text color and (on first call) its internal
    /// label constraints - callers own the pill/label instances and pass the
    /// pill as one of `build`'s `trailingViews`.
    static func pill(text: String, colorHex: String, into pill: NSView, label: NSTextField) {
        label.stringValue = text
        label.font = .systemFont(ofSize: 10.5, weight: .semibold)
        label.textColor = HelmTheme.nsColor(colorHex)
        label.translatesAutoresizingMaskIntoConstraints = false
        pill.wantsLayer = true
        pill.layer?.cornerRadius = 9
        pill.layer?.backgroundColor = HelmTheme.nsColor(colorHex).withAlphaComponent(0.15).cgColor
        pill.translatesAutoresizingMaskIntoConstraints = false
        if label.superview !== pill {
            pill.addSubview(label)
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: pill.leadingAnchor, constant: 9),
                label.trailingAnchor.constraint(equalTo: pill.trailingAnchor, constant: -9),
                label.topAnchor.constraint(equalTo: pill.topAnchor, constant: 3),
                label.bottomAnchor.constraint(equalTo: pill.bottomAnchor, constant: -3),
            ])
        }
    }

    /// Re-themes the shared chrome. `detailFailed` routes the detail label
    /// through the theme's error color, matching `UpdatesController`'s
    /// existing failed-state treatment.
    ///
    /// `cardStyle` mirrors `build(cardStyle:)` - `false` (the default)
    /// reproduces every existing caller's flat, hover-only look byte for
    /// byte. `attentionHex`, meaningful only when `cardStyle` is true, tints
    /// the card's border instead of the default neutral line - a row with a
    /// real, data-backed "needs attention" state (e.g. Vault's launcher
    /// rows) can call this out without a separate one-off view.
    static func applyTheme(_ views: Views, theme: HelmTheme, detailFailed: Bool, cardStyle: Bool = false, attentionHex: String? = nil) {
        let ink = HelmTheme.nsColor(theme.chromeInkHex)
        let muted = HelmTheme.mutedInk(theme)
        let line = HelmTheme.nsColor(theme.chromeLineHex)
        views.iconTile.applyTheme(theme)
        views.nameLabel.textColor = ink
        views.detailLabel.textColor = detailFailed ? HelmTheme.nsColor(theme.ansiHex[1]) : muted
        views.detailsButton.contentTintColor = ink.withAlphaComponent(0.5)
        views.logField.textColor = muted
        views.logContainer.layer?.backgroundColor = HelmTheme.nsColor(theme.backgroundHex).cgColor
        if cardStyle {
            let cardFill = HelmTheme.nsColor(theme.chromeBackgroundHex)
            views.rowContainer.normalColor = cardFill
            views.rowContainer.hoverColor = cardFill.blended(withFraction: 0.08, of: line) ?? cardFill
            views.rowContainer.layer?.borderWidth = 1
            let borderColor = attentionHex.map { HelmTheme.nsColor($0).withAlphaComponent(0.55) } ?? line.withAlphaComponent(0.6)
            views.rowContainer.layer?.borderColor = borderColor.cgColor
        } else {
            views.rowContainer.normalColor = .clear
            views.rowContainer.hoverColor = line.withAlphaComponent(0.18)
            views.rowContainer.layer?.borderWidth = 0
        }
    }

    /// Toggles the chevron image, the log container's visibility, and the
    /// log field's text together - the one place that decides "expanded and
    /// non-empty" is what actually shows the panel.
    static func setLogExpanded(_ views: Views, expanded: Bool, log: String) {
        views.logContainer.isHidden = !expanded || log.isEmpty
        views.detailsButton.image = NSImage(
            systemSymbolName: expanded ? "chevron.down" : "chevron.right",
            accessibilityDescription: "Show details"
        )
        views.logField.stringValue = log.isEmpty ? "No output yet." : log
    }
}
