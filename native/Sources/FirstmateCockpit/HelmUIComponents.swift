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

/// The shared selected-row background for this app's `NSTableView` lists.
///
/// **Why this exists:** `table.style = .sourceList` paired with
/// `selectionHighlightStyle = .regular` hands selection rendering to AppKit's
/// private, vibrancy-backed `NSTableRowSidebarSelectionView`, which has no
/// layer fill of its own and draws from the **system accent colour** - not
/// from `HelmTheme`. So a selected host / key / snippet rendered macOS blue
/// (`controlAccentColor` #007aff, `selectedContentBackgroundColor` #0059d1)
/// on Gruvbox's orange, Catppuccin's violet and every other palette; forcing
/// `root.appearance` does not help, because the wrong thing being resolved is
/// the *accent*, not light-vs-dark (audit §5.2). The fix is to take selection
/// rendering back: `selectionHighlightStyle = .none` on the table (which is
/// what stops that private view being installed at all) plus this row view,
/// which paints a wash of the active theme's own accent instead.
///
/// Deliberately a translucent wash with a stronger stroke, not an opaque
/// accent fill: a wash leaves the row's existing text contrast essentially
/// untouched, so this stays a colour fix rather than turning into a
/// selected-row typography change.
final class HelmTableRowView: NSTableRowView {
    /// The theme accent to paint with. Set by the owning table's
    /// `tableView(_:rowViewForRow:)`, which knows the active theme.
    var accentHex: String = ThemeManager.shared.theme.accentHex {
        didSet { if isSelected { needsDisplay = true } }
    }

    /// With `selectionHighlightStyle = .none` AppKit never calls
    /// `drawSelection(in:)`, and does not repaint on its own when selection
    /// changes - both are on us.
    override var isSelected: Bool {
        didSet { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard isSelected else { return }
        let accent = HelmTheme.nsColor(accentHex)
        let rect = bounds.insetBy(dx: 4, dy: 1)
        let path = NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6)
        accent.withAlphaComponent(0.24).setFill()
        path.fill()
        accent.withAlphaComponent(0.65).setStroke()
        path.lineWidth = 1
        path.stroke()
    }
}

/// A live registry of labels that carry `HelmTheme.mutedInk` - the app's one
/// muted/secondary text tone - so a window whose theme observer has no other
/// per-label repaint path can still re-tint them on every theme change.
///
/// **Why this exists rather than `.secondaryLabelColor`/`.tertiaryLabelColor`:**
/// those are fixed system greys. They know nothing about which of the 12 Helm
/// palettes is active, so they are both off-palette (hue-neutral grey where
/// every theme's own muted ink is tinted - catppuccin-mocha's is blue-violet,
/// gruvbox-light's is warm) and, for `.tertiaryLabelColor`, below the 4.5:1
/// contrast floor this codebase holds itself to in **every** theme, measured
/// as low as 1.86:1. Forcing `root.appearance` (`ThemeManager.swift`'s
/// checklist rule 2) only picks the right *side* of light/dark for them; it
/// cannot make a system grey theme-aware. The full-app UI audit found 33 such
/// text sites across 10 files (§5.3); this is what replaced them.
///
/// `add` applies the current theme immediately, so a label is correct the
/// moment it is built - which also sidesteps `ThemeManager.swift`'s checklist
/// rule 4 (a theme observer's synchronous first firing sees an empty
/// registry when the labels are built further down the same `loadView`).
final class MutedInkLabels {
    private var labels: [NSTextField] = []

    /// Registers `label`, tints it for the active theme now, and returns it
    /// so it can be used inline at a construction site.
    @discardableResult
    func add(_ label: NSTextField) -> NSTextField {
        labels.append(label)
        label.textColor = HelmTheme.mutedInk(ThemeManager.shared.theme)
        return label
    }

    /// Re-tints every registered label. Call from the owner's
    /// `ThemeManager.shared.observe` closure.
    func apply(_ theme: HelmTheme) {
        let muted = HelmTheme.mutedInk(theme)
        labels.forEach { $0.textColor = muted }
    }
}

/// The contrast layer behind every tinted chip/pill/tile in this app.
///
/// **The design-system rule this file exists to enforce:** a `HelmTint` hue is
/// safe as a *fill* or a *bar*, and is **not** automatically safe as *text*.
/// Every `HelmTint` hue is chosen so it reads well as a solid block against
/// the theme's own surfaces - nothing about that choice makes the same hue
/// legible when it is *also* used as the label sitting on a faint wash of
/// itself, because a wash of a hue over the surface lands very close to that
/// hue's own luminance whenever the hue and the surface are close to begin
/// with. Measured across all 12 real palettes x the 5 `HelmTint` ANSI hues
/// plus `accentHex`, the old "label = hue, fill = hue @ 0.15" recipe fell
/// below the 4.5:1 WCAG floor in **44 of 72** pairs, worst case 1.93:1
/// (Rosé Pine Dawn, amber) - see `data/grandline-full-ui-audit/report.md` §5.7
/// for the full per-theme table.
///
/// **So: any new component that puts a tint hue on a wash of itself must route
/// through `tintedSurface` below rather than setting both colors to the raw
/// hue.** `ToolRowLayout.pill` and `IconTileView.applyTheme` both do.
/// `NotificationRowView` already gets this right a different way - its kicker
/// is `HelmTheme.mutedInk`, never the tint. `SRELeadChatView.sectionLabel`
/// was the app's one remaining violation (a tint-coloured label on its own
/// `accentCard`'s tint wash) and now routes through here too, pinning the
/// card's existing wash so only the label colour moves.
enum HelmContrast {
    /// WCAG AA for normal-size text - the floor this codebase already holds
    /// itself to (`HelmTheme.swift`'s header, `Dimming.targetContrastRatio`).
    static let textTarget: Double = 4.5
    /// WCAG AA for a non-text UI component (an icon glyph, a bar) - a lower,
    /// deliberately different bar, not a relaxation of the text one.
    static let nonTextTarget: Double = 3.0

    /// Wash opacities tried in order, strongest first. A fainter wash lowers
    /// the fill toward the surface, which buys the label more room; stepping
    /// down is only reached when re-coloring the label alone cannot clear the
    /// target (measured: needed by Solarized Dark's green/amber/blue/accent,
    /// which cap out at 3.92-4.11 at 0.15 because that palette's own ink is
    /// barely brighter than the wash).
    static let pillWashSteps: [CGFloat] = [0.15, 0.12, 0.10, 0.08, 0.06, 0.04]
    /// `IconTileView`'s own historical wash, kept as the first step so a tile
    /// that already clears the (lower) icon bar renders exactly as before.
    static let tileWashSteps: [CGFloat] = [0.16, 0.13, 0.11, 0.09, 0.07, 0.05]

    // MARK: WCAG maths
    //
    // Same sRGB -> linear -> 0.2126R + 0.7152G + 0.0722B formula
    // `HelmTheme.swift`'s header and `Dimming.swift` both document; repeated
    // here rather than shared because `Dimming` lives inside the vendored
    // SwiftTerm target and is not visible to this module.

    private static func srgbToLinear(_ c: Double) -> Double {
        c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    }

    /// WCAG relative luminance of a straight (un-premultiplied) sRGB triple.
    static func relativeLuminance(_ rgb: (Double, Double, Double)) -> Double {
        0.2126 * srgbToLinear(rgb.0) + 0.7152 * srgbToLinear(rgb.1) + 0.0722 * srgbToLinear(rgb.2)
    }

    /// WCAG contrast ratio between two straight sRGB triples.
    static func ratio(_ a: (Double, Double, Double), _ b: (Double, Double, Double)) -> Double {
        let l1 = relativeLuminance(a), l2 = relativeLuminance(b)
        let hi = max(l1, l2), lo = min(l1, l2)
        return (hi + 0.05) / (lo + 0.05)
    }

    /// Contrast ratio between two opaque `NSColor`s - the entry point the
    /// self-test and any live probe use.
    static func ratio(_ a: NSColor, _ b: NSColor) -> Double {
        ratio(components(a), components(b))
    }

    /// `NSColor` -> straight sRGB triple. Anything that cannot be converted to
    /// sRGB (a pattern/catalog color) falls back to mid-grey rather than
    /// trapping, since this is only ever used for a contrast estimate.
    static func components(_ color: NSColor) -> (Double, Double, Double) {
        guard let c = color.usingColorSpace(.sRGB) else { return (0.5, 0.5, 0.5) }
        return (Double(c.redComponent), Double(c.greenComponent), Double(c.blueComponent))
    }

    static func color(_ rgb: (Double, Double, Double)) -> NSColor {
        NSColor(srgbRed: CGFloat(rgb.0), green: CGFloat(rgb.1), blue: CGFloat(rgb.2), alpha: 1)
    }

    /// `a` at `t`, `b` at `1 - t` - a straight linear mix in sRGB space, which
    /// is what alpha compositing a straight color over an opaque backdrop
    /// actually does.
    static func mix(_ a: (Double, Double, Double), _ b: (Double, Double, Double), _ t: Double) -> (Double, Double, Double) {
        (a.0 * t + b.0 * (1 - t), a.1 * t + b.1 * (1 - t), a.2 * t + b.2 * (1 - t))
    }

    // MARK: The helper

    /// What a tinted chip/tile should actually be painted with.
    ///
    /// - `fill`: the hue washed over the surface at `washAlpha`, flattened to
    ///   an opaque color. Callers set this as an opaque layer background
    ///   rather than re-applying alpha, so the contrast guarantee below is
    ///   exact rather than dependent on whatever happened to be underneath.
    /// - `foreground`: the hue blended toward the theme's own
    ///   `chromeInkHex` by the smallest amount that clears `target` against
    ///   the fill. `0` blend (i.e. the raw hue, unchanged from before this
    ///   helper existed) whenever the raw hue already clears it.
    struct TintedSurface {
        let fill: NSColor
        let foreground: NSColor
        let washAlpha: CGFloat
    }

    /// Resolves a tint hue into a legible (fill, foreground) pair for `theme`.
    ///
    /// The guarantee holds against **both** of the surfaces a chip can land on
    /// in this app - a card (`chromeBackgroundHex`) and the bare page
    /// (`backgroundHex`) - because the same shared pill is used on both and it
    /// has no way to know which. The two are identical in three palettes and
    /// close in the rest, so requiring both costs almost nothing.
    ///
    /// Deliberately not memoised: measured at ~14us per call on this machine
    /// (16,800 calls in 240ms across every theme/hue pair), and the common
    /// case - a hue that already clears the target, so the blend search exits
    /// immediately - is far cheaper than that average. A page re-theme with
    /// 50 pills and tiles costs well under a millisecond, against a theme
    /// change that is already doing full `reloadData`s and layout passes.
    ///
    /// Mirrors `Dimming.contrastFixBlendFraction`'s technique (bisect a blend
    /// fraction to a contrast target) with one deliberate difference: it
    /// brackets with a coarse scan first, because contrast against a *fixed*
    /// fill is V-shaped rather than monotonic in the blend fraction whenever
    /// the hue and the ink sit on opposite sides of the fill's own luminance.
    /// Plain bisection would silently pick the wrong side of that valley.
    static func tintedSurface(tintHex: String,
                              theme: HelmTheme,
                              target: Double,
                              washSteps: [CGFloat] = pillWashSteps) -> TintedSurface {
        let tint = components(HelmTheme.nsColor(tintHex))
        let ink = components(HelmTheme.nsColor(theme.chromeInkHex))
        let surfaces = [
            components(HelmTheme.nsColor(theme.chromeBackgroundHex)),
            components(HelmTheme.nsColor(theme.backgroundHex)),
        ]

        var lastFill = mix(tint, surfaces[0], Double(washSteps.last ?? 0.04))
        var lastForeground = ink
        for alpha in washSteps {
            // The chip renders on one surface at a time, but we do not know
            // which, so score every candidate fill and satisfy the worst.
            let fills = surfaces.map { mix(tint, $0, Double(alpha)) }
            let blend = smallestBlend(from: tint, toward: ink, clearing: target, against: fills)
            let foreground = mix(ink, tint, blend)
            let worst = fills.map { ratio(foreground, $0) }.min() ?? 0
            lastFill = fills[0]
            lastForeground = foreground
            // A hair of slack: the scan below lands within one step of the
            // true crossing, and a chip that measures 4.4999 is not a defect.
            if worst >= target - 0.01 {
                return TintedSurface(fill: color(fills[0]), foreground: color(foreground), washAlpha: alpha)
            }
        }
        // Nothing cleared the target even at the faintest wash with a pure-ink
        // label. Return that faintest, most-legible combination rather than
        // falling back to the raw hue, which is strictly worse.
        return TintedSurface(fill: color(lastFill),
                             foreground: color(lastForeground),
                             washAlpha: washSteps.last ?? 0.04)
    }

    /// Smallest `t` in `[0, 1]` such that `mix(toward, from, t)` clears
    /// `target` against **every** candidate background, or `1` if none does.
    private static func smallestBlend(from: (Double, Double, Double),
                                      toward: (Double, Double, Double),
                                      clearing target: Double,
                                      against backgrounds: [(Double, Double, Double)]) -> Double {
        func clears(_ t: Double) -> Bool {
            let c = mix(toward, from, t)
            return backgrounds.allSatisfy { ratio(c, $0) >= target }
        }
        if clears(0) { return 0 }
        // Coarse scan to bracket the first crossing (the V-shaped-ratio guard
        // above), then bisect inside that bracket for precision.
        let steps = 32
        var lo = 0.0
        var bracketed = false
        for i in 1...steps {
            let t = Double(i) / Double(steps)
            if clears(t) { bracketed = true; break }
            lo = t
        }
        guard bracketed else { return 1 }
        var hi = min(1.0, lo + 1.0 / Double(steps))
        for _ in 0..<20 {
            let mid = (lo + hi) / 2
            if clears(mid) { hi = mid } else { lo = mid }
        }
        return hi
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
        // Same wash-plus-same-hue-glyph shape as `ToolRowLayout.pill`, so it
        // goes through the same helper - see `HelmContrast`'s doc comment for
        // why a tint hue is not automatically safe on a wash of itself. The
        // bar here is `nonTextTarget` (3:1), not the pill's 4.5:1: a glyph is
        // a non-text UI component. Most tiles already clear that at the
        // historical 0.16 wash with the raw hue, in which case this returns
        // exactly the colors this method used to set.
        let resolved = HelmContrast.tintedSurface(tintHex: tint.hex(in: theme),
                                                  theme: theme,
                                                  target: HelmContrast.nonTextTarget,
                                                  washSteps: HelmContrast.tileWashSteps)
        layer?.backgroundColor = resolved.fill.cgColor
        imageView.contentTintColor = resolved.foreground
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
        /// The colored left accent strip a "needs attention" row shows
        /// (`fm/grandline-setup-attention-row-style`) - a stored default so
        /// every pre-existing `Views(...)` call site keeps compiling
        /// unchanged. Geometry is wired up once in `build()` (idempotent,
        /// hidden by default); `applyTheme(accentBar:)` only ever flips its
        /// color/visibility, never its position, so it's safe to toggle on a
        /// persistent, mutate-in-place row (Updates/GitHub Sync) as well as
        /// a torn-down-and-rebuilt one (Bootstrap/Automation).
        let accentBar: NSView = NSView()
    }

    /// Adds (idempotently, based on `bar`'s current superview) a colored
    /// left accent strip flush against `container`'s leading edge - the
    /// same colored-strip idiom `NotificationRowView`/`ShiftTaskRowView`
    /// use to flag "this one needs a look" (`NotificationCenterPopover.
    /// swift`). Exposed as a standalone helper, not baked only into
    /// `Views.rowContainer`, so a page with its own bespoke small container
    /// - `AutomationController`'s software-checklist chips, which don't use
    /// `ToolRowLayout` at all - can reuse the exact same visual idiom
    /// instead of hand-rolling a second one. Callers own `bar`'s lifetime (a
    /// fresh view for a page that rebuilds every render, or a persistent
    /// per-row view for a page that mutates rows in place) - this never
    /// allocates the bar itself, so there's no shared mutable registry to
    /// leak or collide.
    static func attachAccentBar(_ bar: NSView, to container: NSView, verticalInset: CGFloat = 6, width: CGFloat = 3) {
        bar.wantsLayer = true
        bar.layer?.cornerRadius = width / 2
        bar.translatesAutoresizingMaskIntoConstraints = false
        if bar.superview !== container {
            container.addSubview(bar)
            NSLayoutConstraint.activate([
                bar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                bar.widthAnchor.constraint(equalToConstant: width),
                bar.topAnchor.constraint(equalTo: container.topAnchor, constant: verticalInset),
                bar.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -verticalInset),
            ])
        }
    }

    /// Shows `bar` tinted `colorHex`, or hides it when `colorHex` is `nil` -
    /// the one place that decides "does this row/chip currently need eyes
    /// on it."
    static func setAccentBar(_ bar: NSView, colorHex: String?) {
        bar.isHidden = colorHex == nil
        if let colorHex {
            bar.layer?.backgroundColor = HelmTheme.nsColor(colorHex).cgColor
        }
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
    /// `HelmCard.applyTheme` already uses for its own card look, not a
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
        // Always wired up (hidden by default) regardless of `cardStyle` -
        // `applyTheme(accentBar:)` is what decides visibility/color, and it
        // needs to be able to flip a persistent, mutate-in-place row
        // (Updates/GitHub Sync, built exactly once) into/out of "needs
        // attention" on every status change, long after this `build()` call
        // returns.
        attachAccentBar(views.accentBar, to: views.rowContainer)
        views.accentBar.isHidden = true
        return views.rowContainer
    }

    /// Configures a pill's fill/text color and (on first call) its internal
    /// label constraints - callers own the pill/label instances and pass the
    /// pill as one of `build`'s `trailingViews`.
    ///
    /// This is the app's one shared status pill, so its contrast behaviour is
    /// load-bearing for nearly every status indicator in the app. It used to
    /// set the label and the wash to the *same* `colorHex`, which fell below
    /// 4.5:1 in 44 of 72 real theme/hue pairs - it now resolves both through
    /// `HelmContrast.tintedSurface`, which keeps the hue for the wash and
    /// nudges the label toward the theme's own ink only as far as the floor
    /// requires. Read `HelmContrast`'s doc comment before adding any other
    /// component that puts a tint hue on a wash of itself.
    ///
    /// `theme` defaults to the active one so no existing caller changed; pass
    /// it explicitly from a caller that already has the theme in hand (or is
    /// re-theming to a theme that is not yet current).
    static func pill(text: String, colorHex: String, into pill: NSView, label: NSTextField,
                     theme: HelmTheme = ThemeManager.shared.theme) {
        let resolved = HelmContrast.tintedSurface(tintHex: colorHex,
                                                  theme: theme,
                                                  target: HelmContrast.textTarget)
        label.stringValue = text
        label.font = .systemFont(ofSize: 10.5, weight: .semibold)
        label.textColor = resolved.foreground
        label.translatesAutoresizingMaskIntoConstraints = false
        pill.wantsLayer = true
        pill.layer?.cornerRadius = 9
        // Opaque, already flattened over the surface - not re-applied as
        // alpha, so the measured contrast above is exactly what renders.
        pill.layer?.backgroundColor = resolved.fill.cgColor
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
    ///
    /// `accentBar` (default `false`, so every pre-existing caller - Vault
    /// included - is unaffected) additionally shows the colored left accent
    /// strip (`attachAccentBar`/`setAccentBar`) whenever `cardStyle` is also
    /// true and `attentionHex` is set - a page whose rows are mostly
    /// "fine" (Updates/Bootstrap/Automation/GitHub Sync's dense checklists,
    /// `fm/grandline-setup-attention-row-style`) passes this only for the
    /// row(s) actually flagged, so a healthy row never grows the fill/
    /// border/bar treatment at all: this is purely additive on top of
    /// `cardStyle`'s existing fill/border, not a new visual mode of its own.
    /// Since this only ever touches `views.rowContainer`'s colors/`
    /// accentBar`'s color+visibility (never `column`'s already-baked
    /// padding constraints from `build()`), it's safe to call repeatedly on
    /// a persistent, mutate-in-place row whose attention state changes
    /// after its one-time `build()` call - the row won't gain the bigger
    /// card padding `build(cardStyle: true)` would have given it if that
    /// had been known up front, but the fill/border/bar signal is real and
    /// live either way.
    static func applyTheme(_ views: Views, theme: HelmTheme, detailFailed: Bool, cardStyle: Bool = false, attentionHex: String? = nil, accentBar: Bool = false) {
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
        setAccentBar(views.accentBar, colorHex: (cardStyle && accentBar) ? attentionHex : nil)
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
