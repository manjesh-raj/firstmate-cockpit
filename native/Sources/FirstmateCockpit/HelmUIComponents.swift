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

/// Selected-row rendering note (audit §5.2, Phase 0 -> Phase 5).
///
/// This file used to hold `HelmTableRowView`, an `NSTableRowView` that painted
/// a wash of the active theme's accent behind a selected row - Phase 0's fix
/// for the Hosts / Keys / Snippets lists, which had handed selection to
/// AppKit's private, vibrancy-backed `NSTableRowSidebarSelectionView` and so
/// rendered macOS blue on every palette.
///
/// Phase 5 turned all three of those lists into `HelmAccentRow` cards, and a
/// card is opaque: a wash painted *behind* it is invisible. Selection moved
/// onto the card itself (`HelmAccentRow.isRowSelected`, same accent-wash +
/// accent-stroke recipe), and those three lists were this class's only
/// callers, so it is gone rather than left as dead code. The rule it encoded
/// still stands and is stronger now: those tables are `.fullWidth`, not
/// `.sourceList`, so the private selection material is never installed at all.

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
/// `HelmAccentRow` already gets this right a different way - its kicker
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

    /// `base` if it already clears the text floor against `surface`, else
    /// `base` blended toward whichever of white/black it can reach the most
    /// contrast against, by the smallest step that clears it.
    ///
    /// The direction has to be chosen by evaluating both endpoints rather than
    /// assumed from the theme's mode - a tone already close to one extreme has
    /// almost no headroom left in that direction. Same reasoning as the
    /// vendored `NSColor.legibleColor(against:)` truecolor patch
    /// (`Vendor/SwiftTerm/README.md`, "Second patch").
    ///
    /// Lived on `HelmButton` until Phase 6, which needed it from `HelmField`
    /// as well; this is where a contrast correction belongs.
    static func legible(_ base: NSColor, over surface: NSColor) -> NSColor {
        if ratio(base, surface) >= textTarget { return base }
        let endpoint: NSColor = relativeLuminance(components(surface)) > 0.35 ? .black : .white
        for step in stride(from: 0.05, through: 1.0, by: 0.05) {
            guard let blended = base.blended(withFraction: CGFloat(step), of: endpoint) else { break }
            if ratio(blended, surface) >= textTarget { return blended }
        }
        return endpoint
    }

    /// A tint hue used as **text** on an already-known opaque fill, corrected
    /// to clear `textTarget` by the smallest blend toward the theme's own ink.
    ///
    /// The counterpart to `tintedSurface` for the case where the fill is
    /// already decided and only the label can move - a `HelmButton`'s tinted
    /// label, a `HelmStatTile`'s tinted metric. Blending toward `chromeInkHex`
    /// rather than toward black/white (which is what `legible`
    /// does) preserves as much of the hue as the floor allows, so an "overdue"
    /// number still reads red rather than collapsing to near-ink.
    ///
    /// Promoted here in Phase 4 from `HelmButton`'s own private copy: two of
    /// the three stat-tile implementations this phase replaced set their value
    /// label to `HelmTheme.nsColor(tint.hex(in: theme))` directly, which is
    /// exactly the §5.7 "a hue is safe as a fill, not automatically as text"
    /// mistake, so the correction had to be reachable from more than one
    /// component.
    static func legibleTintedText(tintHex: String, over surface: NSColor, theme: HelmTheme) -> NSColor {
        legibleTintedText(tintHex: tintHex, overAnyOf: [surface], theme: theme)
    }

    /// The same, for a component that does not know which of several fills its
    /// label will land on and has to clear the floor on all of them - the way
    /// `tintedSurface` already satisfies both `chromeBackgroundHex` and
    /// `backgroundHex`. `HelmSegmentedTabs`' active pill needs this: its wash
    /// composites over a *translucent* capsule, so the real fill differs
    /// depending on whether the capsule sits on a card or the bare page.
    static func legibleTintedText(tintHex: String, overAnyOf surfaces: [NSColor], theme: HelmTheme) -> NSColor {
        let hue = HelmTheme.nsColor(tintHex)
        func clearsAll(_ color: NSColor) -> Bool {
            surfaces.allSatisfy { ratio(color, $0) >= textTarget }
        }
        if clearsAll(hue) { return hue }
        let ink = HelmTheme.nsColor(theme.chromeInkHex)
        for step in stride(from: 0.05, through: 1.0, by: 0.05) {
            guard let blended = hue.blended(withFraction: CGFloat(step), of: ink) else { break }
            if clearsAll(blended) { return blended }
        }
        // Even pure ink may not clear the floor against an unusual fill; fall
        // back to the black/white correction against the worst surface, which
        // always can.
        let worst = surfaces.min { ratio(ink, $0) < ratio(ink, $1) } ?? (surfaces.first ?? .white)
        return legible(ink, over: worst)
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
class HoverHighlightView: NSView {
    var normalColor: NSColor = .clear {
        didSet { if !isHovering { setBackground(normalColor, animated: false) } }
    }
    var hoverColor: NSColor = .clear

    var cornerRadius: CGFloat = 0 {
        didSet { layer?.cornerRadius = cornerRadius }
    }

    private var isHovering = false
    private var trackingArea: NSTrackingArea?

    // MARK: Accessibility and keyboard (GL-16)

    /// An explicit VoiceOver label. Left `nil`, the view derives one from the
    /// text of its own descendant labels, which is what makes the ~40
    /// recognizer-driven controls in this app readable without touching a
    /// single call site: a row built out of `NSTextField`s already carries
    /// the words a captain would read aloud.
    var accessibilityLabelOverride: String?

    /// Announced role. Defaults to `.button` for an activatable view; a
    /// caller whose control is really one-of-many (`HelmSegmentedTabs`' pills)
    /// sets `.radioButton` and pairs it with `accessibilityValueOverride`.
    var accessibilityRoleOverride: NSAccessibility.Role?

    /// The value VoiceOver reads after the label - "selected" for the active
    /// pill of a segmented control.
    var accessibilityValueOverride: String?

    /// Activation for a caller whose click handling does *not* go through a
    /// click recognizer attached to this view. When nil (the common case),
    /// pressing this view replays its own recognizer's target/action, so
    /// every existing call site is covered without change.
    var onAccessibilityPress: (() -> Void)?

    /// Consulted before this view's own `keyDown` handling; return `true` to
    /// say the event was handled. `HelmSegmentedTabs` uses it for arrow-key
    /// movement between pills.
    var onKeyDown: ((NSEvent) -> Bool)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        // A real system focus ring, drawn from this view's own rounded rect
        // (see `drawFocusRingMask`). ~12 sites in this app set
        // `focusRingType = .none` on real controls, which is why even the
        // focusable ones showed nothing; a view that is a button by role has
        // to show where the keyboard is.
        focusRingType = .exterior
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not supported")
    }

    /// The one definition of "this view does something when pressed": an
    /// explicit press handler, or an enabled click recognizer someone
    /// attached. A decorative `HoverHighlightView` (a card that only
    /// highlights) stays invisible to VoiceOver and out of the key view loop,
    /// which is the difference between fixing accessibility and flooding it.
    var isActivatable: Bool {
        onAccessibilityPress != nil || primaryClickRecognizer() != nil
    }

    private func primaryClickRecognizer() -> NSClickGestureRecognizer? {
        gestureRecognizers.lazy
            .compactMap { $0 as? NSClickGestureRecognizer }
            .first { $0.isEnabled && $0.action != nil && $0.target != nil }
    }

    /// Fires this view's primary action the same way a real click does.
    /// Returns whether anything was actually invoked.
    @discardableResult
    func performPrimaryAction() -> Bool {
        if let onAccessibilityPress {
            onAccessibilityPress()
            return true
        }
        guard let recognizer = primaryClickRecognizer(),
              let action = recognizer.action,
              let target = recognizer.target else { return false }
        // `from: recognizer`, not `from: self`: several handlers in this app
        // read `sender.view` off the recognizer to know which row was hit
        // (`HelmSegmentedTabs.pillClicked` is the clearest case), so the
        // sender has to be the recognizer a real click would have passed.
        return NSApp.sendAction(action, to: target, from: recognizer)
    }

    override func isAccessibilityElement() -> Bool { isActivatable }

    override func accessibilityRole() -> NSAccessibility.Role? {
        guard isActivatable else { return super.accessibilityRole() }
        return accessibilityRoleOverride ?? .button
    }

    override func accessibilityLabel() -> String? {
        if let accessibilityLabelOverride { return accessibilityLabelOverride }
        guard isActivatable else { return super.accessibilityLabel() }
        let words = Self.readableText(in: self)
        return words.isEmpty ? super.accessibilityLabel() : words.joined(separator: ", ")
    }

    override func accessibilityValue() -> Any? {
        accessibilityValueOverride ?? super.accessibilityValue()
    }

    override func accessibilityChildren() -> [Any]? {
        // Once this view *is* a button, its own labels are the button's
        // title - exposing them as separate elements makes VoiceOver read
        // each fragment twice.
        isActivatable ? [] : super.accessibilityChildren()
    }

    override func accessibilityPerformPress() -> Bool { performPrimaryAction() }

    /// Every non-empty string a descendant label/button shows, in view order.
    private static func readableText(in view: NSView) -> [String] {
        var out: [String] = []
        for sub in view.subviews {
            if let field = sub as? NSTextField {
                let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { out.append(text) }
            } else if let button = sub as? NSButton, !button.title.isEmpty {
                out.append(button.title)
            } else {
                out.append(contentsOf: readableText(in: sub))
            }
        }
        return out
    }

    // MARK: Keyboard

    override var acceptsFirstResponder: Bool { isActivatable }
    override var canBecomeKeyView: Bool { isActivatable && !isHiddenOrHasHiddenAncestor }

    override func becomeFirstResponder() -> Bool {
        noteFocusRingMaskChanged()
        return super.becomeFirstResponder()
    }

    override func resignFirstResponder() -> Bool {
        noteFocusRingMaskChanged()
        return super.resignFirstResponder()
    }

    override var focusRingMaskBounds: NSRect { bounds }

    override func drawFocusRingMask() {
        let radius = max(cornerRadius, 2)
        NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()
    }

    override func keyDown(with event: NSEvent) {
        if onKeyDown?(event) == true { return }
        // 36 = Return, 76 = keypad Enter, 49 = Space: the three keys AppKit
        // itself treats as "press this control".
        if event.keyCode == 36 || event.keyCode == 76 || event.keyCode == 49 {
            if performPrimaryAction() { return }
        }
        super.keyDown(with: event)
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

/// The app's one table view (GL-16): an `NSTableView` whose selected row can
/// be activated from the keyboard.
///
/// Arrow keys already move an `NSTableView`'s selection, but this app's row
/// activation is `doubleAction` throughout - so before this, every list here
/// (hosts, tasks, follow-ups, a project's tasks) could be *navigated* without
/// a mouse and not *used* without one.
///
/// The one subtlety worth knowing: all four of this app's `doubleAction`
/// handlers read `clickedRow`, which AppKit leaves at `-1` when nothing was
/// clicked. Rather than rewrite four handlers to consult a different property
/// depending on how they were invoked (and leave the next one to get it
/// wrong), `clickedRow` reports the selected row for the duration of a
/// keyboard activation - so a handler is genuinely indifferent to which input
/// device reached it.
final class HelmTableView: NSTableView {
    private var keyboardActivatedRow: Int?

    override var clickedRow: Int { keyboardActivatedRow ?? super.clickedRow }

    override func keyDown(with event: NSEvent) {
        // 36 = Return, 76 = keypad Enter, 49 = Space.
        let isActivation = event.keyCode == 36 || event.keyCode == 76 || event.keyCode == 49
        if isActivation, selectedRow >= 0, let action = doubleAction, let target = self.target {
            keyboardActivatedRow = selectedRow
            defer { keyboardActivatedRow = nil }
            NSApp.sendAction(action, to: target, from: self)
            return
        }
        super.keyDown(with: event)
    }
}

/// The app's one "chat-style composer" card - the shared shape behind SRE
/// Lead's question box and the Console Composer's intent box
/// (`fm/grandline-input-composer-redesign`). Both used to be a bare sunken
/// field with no surrounding chrome, which is what the captain's own
/// screenshots flagged as "looks bad": no card, no toolbar, no sense that
/// typing here was a distinct, considered interaction rather than an
/// afterthought bolted onto the bottom of the pane.
///
/// This component owns only the *card* - a rounded, sunken-fill, bordered
/// container whose border visibly brightens (plus a soft accent glow) while a
/// text control inside it has focus. It does not own a text field, a toolbar,
/// or a footer: SRE Lead's chat box and the Command Composer's intent box
/// need genuinely different content inside the card (a compact single-row
/// toolbar with a send button vs. a wider footer with a shortcut hint and a
/// labelled "Generate" button) - per the captain's own framing, "related, but
/// not identical." Each caller builds its own content as subviews of
/// `contentContainer`.
///
/// **Why the glow needs two layers.** `contentContainer` clips
/// (`masksToBounds`) so its own rounded corners stay clean, but a clipped
/// layer cannot also cast a shadow outside its own bounds - so the shadow
/// that makes the focus state read as a glow (rather than just a slightly
/// brighter border) lives on `self`, the un-clipped wrapper, with an explicit
/// `shadowPath` kept in sync with `contentContainer`'s rounded rect in
/// `layout()` (`ConsoleCardChrome.layout()` establishes the same
/// override-and-resync pattern for a geometry-derived layer property).
///
/// **Deliberately does not self-observe `ThemeManager`**, unlike `HelmButton`
/// - both current callers (`SRELeadChatView`, `ConsoleComposerViewController`)
/// already own exactly one theme observer of their own and call
/// `applyTheme(_:)` from it, so a second observer here would just be another
/// instance of the repeated-observer bug class `ThemeManager.swift`'s
/// checklist warns about, for no benefit.
final class HelmComposerCard: NSView {
    /// The actual bordered/filled surface. Callers add their own content as
    /// subviews of this, never of `self`.
    let contentContainer = NSView()

    private var isFocused = false
    private var lastTheme: HelmTheme?

    var cornerRadius: CGFloat {
        didSet {
            guard cornerRadius != oldValue else { return }
            contentContainer.layer?.cornerRadius = cornerRadius
            needsLayout = true
        }
    }

    init(cornerRadius: CGFloat = HelmMetrics.rRow) {
        self.cornerRadius = cornerRadius
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true

        contentContainer.wantsLayer = true
        contentContainer.layer?.masksToBounds = true
        contentContainer.layer?.cornerRadius = cornerRadius
        contentContainer.translatesAutoresizingMaskIntoConstraints = false
        addSubview(contentContainer)
        NSLayoutConstraint.activate([
            contentContainer.leadingAnchor.constraint(equalTo: leadingAnchor),
            contentContainer.trailingAnchor.constraint(equalTo: trailingAnchor),
            contentContainer.topAnchor.constraint(equalTo: topAnchor),
            contentContainer.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override func layout() {
        super.layout()
        // An un-clipped layer's shadow otherwise falls back to its full
        // rectangular bounds rather than the rounded rect `contentContainer`
        // actually draws - without this the glow would show square corners
        // poking out past the card's own rounded ones.
        layer?.shadowPath = CGPath(roundedRect: bounds, cornerWidth: cornerRadius,
                                   cornerHeight: cornerRadius, transform: nil)
    }

    /// Toggle the focused look - driven by whichever text control inside
    /// `contentContainer` currently has focus. Re-applies whatever theme was
    /// last given to `applyTheme(_:)` rather than requiring the caller to
    /// re-call it on every focus change.
    func setFocused(_ focused: Bool) {
        guard focused != isFocused else { return }
        isFocused = focused
        if let lastTheme { applyTheme(lastTheme) }
    }

    func applyTheme(_ theme: HelmTheme) {
        lastTheme = theme
        contentContainer.layer?.backgroundColor = HelmField.fill(theme).cgColor
        let accent = HelmTheme.nsColor(theme.accentHex)
        if isFocused {
            contentContainer.layer?.borderWidth = 1.5
            contentContainer.layer?.borderColor = accent.withAlphaComponent(0.7).cgColor
            layer?.shadowColor = accent.cgColor
            layer?.shadowOpacity = Float(theme.mode == .dark ? 0.35 : 0.22)
            layer?.shadowRadius = 8
            layer?.shadowOffset = .zero
        } else {
            contentContainer.layer?.borderWidth = 1
            contentContainer.layer?.borderColor = HelmField.border(theme).cgColor
            layer?.shadowOpacity = 0
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
    /// same colored-strip idiom `HelmAccentRow` uses to flag "this one needs
    /// a look" (`HelmDesignSystem.swift`). Exposed as a standalone helper, not baked only into
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

    /// The floor the name/detail column degrades to on a genuinely narrow row.
    ///
    /// It is only a floor now. Audit §5.4 originally made this column a
    /// *fixed* 42%-of-the-row slot (clamped to [200, 520]) because the status
    /// pill sat immediately after the name label and therefore tracked the
    /// name's length - a ragged diagonal, measured at a 64pt pill-x spread
    /// over five real Updates rows. Pinning the column pinned the pill.
    ///
    /// That fix worked and then cost more than it bought, in two ways the
    /// captain hit live:
    ///
    /// - **The detail line truncated flush against the pill.** With the
    ///   column capped at 520pt (~443pt on this app's real ~1056pt rows), a
    ///   longer-than-the-column detail - Updates' `firstmate` row, "main
    ///   carries 24 commit(s) of its own and is 7 behind upstream/main; run
    ///   without --check to merge up..." - ran out of room 8pt short of the
    ///   "Update Available" pill and truncated there, with ~500pt of unused
    ///   row to its right. Reads as the two fighting for the same space,
    ///   which is exactly how it was reported ("the context and the upgrade
    ///   available is conflicting... it's blocking the context").
    /// - **A row with short details left a dead gap.** GitHub Sync's rows all
    ///   read "In sync with kunchenguid/<repo>" - well under the column - so
    ///   its pill sat at 42% with roughly half the row empty between it and
    ///   the right-anchored chevron ("let us have the status to the right
    ///   side").
    ///
    /// Both are the same defect: the status column was positioned from the
    /// *leading* edge. It is now positioned from the **trailing** edge - see
    /// `statusColumnTrailingReserve` - so the status + actions cluster is
    /// right-anchored and the text column gets every remaining point,
    /// truncating far from the pill instead of against it.
    static let nameColumnMinWidth: CGFloat = 200

    /// How much room is reserved to the right of the status column for a
    /// row's action buttons - and therefore where the status pill's trailing
    /// edge lands, measured back from the row's own trailing edge.
    ///
    /// **This is what keeps the pill a column** now that it is no longer
    /// anchored to a fixed name column. §5.4's doc comment argued that
    /// measuring back from the trailing edge "cannot work, because one row's
    /// actions are 'Check' and another's are 'Check' plus 'Install in
    /// Bootstrap ->'". That is true of measuring back from the actions
    /// *themselves*; it is not true of measuring back from a reserved slot.
    /// The pill's trailing edge sits at
    /// `rowTrailing - max(statusColumnTrailingReserve, actualActionsWidth)`,
    /// so every row whose actions fit the reserve shares one pill x exactly,
    /// and only a genuinely wider-than-reserve action set shifts left.
    ///
    /// It measures from the status column's trailing edge to the chevron's
    /// leading edge, so it has to cover the row's own inter-column spacing
    /// (3 x `topRow.spacing` = 24pt) as well as the buttons themselves.
    ///
    /// Sized from the real buttons, measured rather than guessed (the probe
    /// that set it prints them): "Check" 59pt, "Check" + "Update" 131pt,
    /// "Sync now" 77pt, and GitHub Sync's in-sync rows 0pt - their button is
    /// hidden, and a hidden arranged subview leaves an `NSStackView`'s layout
    /// entirely. So the widest common set needs 24 + 131 = 155, and 160 gives
    /// it a little air: every one of Updates' 13 real rows and every one of
    /// GitHub Sync's 8 real rows then shares one pill x exactly (measured:
    /// 0.0pt spread on both real pages).
    ///
    /// Two row shapes deliberately exceed it and shift left together -
    /// Updates' rare `.notInstalled` row ("Check" + "Install in Bootstrap
    /// ->", 208pt, so 232) and Vault's two-button rows. Reserving for *those*
    /// would put every ordinary row's pill 250pt from the row's end, which is
    /// re-creating the dead gap this constant exists to close. A row that is
    /// wide because it genuinely carries more is the better thing to make
    /// special.
    static let statusColumnTrailingReserve: CGFloat = 160

    /// The minimum air between the name/detail column and the status column.
    ///
    /// Without it the two are separated only by `topRow.spacing` (8pt), which
    /// is what a *long* detail line collapses to the moment the row is narrow
    /// enough that the text wants all of its space - measured at 6pt of
    /// visible gap on a 1026pt row, i.e. the original "conflicting / blocking
    /// the context" reading returning at small window sizes even with the
    /// column right-anchored. `leadingGap` is a real spacer view, so the text
    /// column's own required `label.width <= textStack.width` caps make the
    /// detail truncate rather than close the gap.
    static let statusColumnLeadingGap: CGFloat = 16

    /// Holds a nested `NSStackView` tight to its own content.
    ///
    /// **This is not the same thing as `setContentHuggingPriority`**, and the
    /// difference is what caused §5.4. Content hugging only constrains a view
    /// against its *intrinsic content size*, and an `NSStackView` has none
    /// (`NSView.noIntrinsicMetric` on both axes) - its size comes from
    /// constraints to its arranged subviews. So `setContentHuggingPriority(
    /// .required, ...)` on a nested stack is a **no-op**, and a parent stack
    /// at `.fill` distribution happily picks that nested stack as the view to
    /// stretch even though its children are all `.required`. Measured live:
    /// the trailing stack absorbed 919pt of a 1056pt row while the text stack
    /// it was supposed to yield to stayed at its natural 69pt.
    /// `NSStackView.setHuggingPriority(_:for:)` is the API that actually
    /// holds a stack to its content, so it is what every nested stack here
    /// uses. Related to, but distinct from, AGENTS.md gotcha #10.
    private static func columnHugging(_ stack: NSStackView) {
        stack.setHuggingPriority(.required, for: .horizontal)
        stack.setClippingResistancePriority(.required, for: .horizontal)
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
    ///
    /// **Columns (audit §5.4, repositioned in `fm/grandline-visual-polish-
    /// round2`).** The row is a real three-column table, measured from the
    /// **trailing** edge: the name/detail column takes every point left over
    /// and truncates within it, then flexible space, then the status column
    /// (`statusViews` - `views.pill` by default, plus any spinner/progress
    /// label that replaces it while a check runs), then the actions
    /// (`trailingViews`) and the chevron pinned to the trailing edge. What
    /// makes the status column a column is `statusColumnTrailingReserve`, not
    /// a fixed name column - read that constant before touching any of this.
    static func build(
        _ views: Views,
        iconSymbol: String,
        tint: HelmTint,
        name: String,
        statusViews: [NSView]? = nil,
        trailingViews: [NSView] = [],
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
        textStack.translatesAutoresizingMaskIntoConstraints = false
        // Stack-level priorities, not content-level - see `columnHugging`.
        textStack.setHuggingPriority(.defaultLow, for: .horizontal)
        textStack.setClippingResistancePriority(.defaultLow, for: .horizontal)
        // **Cap both labels at the column's own width.**
        //
        // `setClippingResistancePriority(.defaultLow, ...)` above is precisely
        // the priority of the stack's internal "I am at least as wide as my
        // widest arranged subview" constraint - so whenever anything else
        // wins (the 42% column cap this used to be paired with, or today the
        // row's own trailing-anchored status column), the stack is allowed to
        // be *narrower than its own content*, and an `NSStackView` does not
        // clip. A long detail line therefore rendered at its full intrinsic
        // width, straight across the status column: measured live before this
        // fix, Updates' `firstmate` row ("main carries 24 commit(s)... push
        // to origin") reached x=751 while the "Update Available" pill started
        // at x=598 - a real 153pt overlap, and exactly the captain-reported
        // bug at the time.
        //
        // The labels already carry `.byTruncatingTail`; it simply never fired,
        // because nothing had ever made their *frames* narrower than their
        // text. These two required caps are what does that, and they can only
        // ever shrink a label - never widen the row.
        for label in [views.nameLabel, views.detailLabel] {
            label.translatesAutoresizingMaskIntoConstraints = false
            label.widthAnchor.constraint(lessThanOrEqualTo: textStack.widthAnchor).isActive = true
            // **And drop their compression resistance to match.**
            //
            // An `NSTextField`'s default horizontal compression resistance is
            // 750 - above `NSLayoutPriorityWindowSizeStayPut` (500) - so a
            // label whose text is genuinely long imposes that text's full
            // intrinsic width as a *floor* on its row, and therefore on the
            // window. The 42% column this replaced hid that: its required
            // `textStack.width <= 520` cap outranked the labels, so they were
            // always free to truncate. Removing the cap without this line
            // handed the floor straight to the window - measured, on the real
            // `firstmate` detail string ("main carries 24 commit(s)..."): a
            // window asked for 1064pt came back 1103pt wide, with the row at
            // 1055 instead of the 1016 its container offered.
            //
            // 250 puts them at the same priority as `textStack`'s own
            // clipping resistance, so the whole text column compresses
            // together and `.byTruncatingTail` does what it is there for.
            // `checkRowDoesNotResizeWindow` covers this case explicitly.
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }

        // The status column: the pill, plus whatever replaces it while a
        // check runs (a spinner and its label). Its own hugging is set with
        // `setHuggingPriority`, NSStackView's own API - see `columnHugging`.
        let statusColumn = NSStackView(views: statusViews ?? [views.pill])
        statusColumn.orientation = .horizontal
        statusColumn.alignment = .centerY
        statusColumn.spacing = 8
        statusColumn.distribution = .fill
        statusColumn.translatesAutoresizingMaskIntoConstraints = false
        columnHugging(statusColumn)
        for v in statusColumn.arrangedSubviews {
            v.setContentHuggingPriority(.required, for: .horizontal)
            v.setContentCompressionResistancePriority(.required, for: .horizontal)
        }

        views.trailingStack.orientation = .horizontal
        views.trailingStack.spacing = 8
        views.trailingStack.alignment = .centerY
        views.trailingStack.distribution = .fill
        views.trailingStack.translatesAutoresizingMaskIntoConstraints = false
        columnHugging(views.trailingStack)
        for v in trailingViews {
            v.setContentHuggingPriority(.required, for: .horizontal)
            v.setContentCompressionResistancePriority(.required, for: .horizontal)
            views.trailingStack.addArrangedSubview(v)
        }

        // The gap between the text column and the status column - and the one
        // view whose priorities decide which of the two absorbs the row's
        // slack, i.e. whether the status column ends up on the left or the
        // right of the row.
        //
        // **`setContentHuggingPriority` on this view is a no-op, and taking
        // it at face value is what made the first attempt at this fix render
        // exactly like the bug it was fixing.** A plain `NSView()` has no
        // intrinsic content size (`NSView.noIntrinsicMetric` on both axes),
        // and a content-priority API only ever constrains a view *against*
        // its intrinsic size - so there is nothing for the priority to
        // prioritise. This is the same trap as AGENTS.md gotcha (12), which
        // records it for `NSStackView`; it is true of any view with no
        // intrinsic metric, a bare spacer very much included. Measured: with
        // the fixed 42% name-column constraint removed and this spacer left
        // at `.defaultHigh` *content* hugging, the spacer happily absorbed
        // 1024pt of a 1352pt row while `textStack` sat at its 200pt floor and
        // the pill stayed at x=254 - the pre-fix geometry, to the point.
        //
        // A real width constraint is what actually expresses "stay collapsed
        // unless something makes you grow": `== 0` at 499, which outranks
        // `textStack`'s own `.defaultLow` (250) stack-level hugging, so the
        // solver would rather stretch the text column than open this gap. The
        // required `statusColumnTrailingReserve` inequality below still beats
        // it, which is how the reserve gets opened when a row's actions are
        // narrower than it.
        //
        // 499, not `.defaultHigh` (750), for the reason spelled out on that
        // reserve constraint: nothing horizontal in this row belongs above
        // `NSLayoutPriorityWindowSizeStayPut` (500) unless it is *meant* to
        // drive the window's size, and `checkRowDoesNotResizeWindow` fails
        // the build on any that is.
        //
        // There are **two** of them, and both are needed. The reserve below
        // is expressed as "the status column's trailing edge sits at least
        // `statusColumnTrailingReserve` short of the chevron", and the only
        // way a solver can honour that is by widening something *after* the
        // status column - so `reserveGap` has to exist. And the guaranteed
        // air in front of the status column has to come from a view too: the
        // stack's own 8pt spacing is not adjustable, and a
        // `textStack.trailing <= statusColumn.leading - 16` constraint is
        // simply unsatisfiable against it (the stack pins that distance at
        // exactly its spacing), so it would break rather than hold.
        let leadingGap = NSView()
        let reserveGap = NSView()
        var gapConstraints: [NSLayoutConstraint] = []
        for (gap, minimum) in [(leadingGap, statusColumnLeadingGap), (reserveGap, 0)] {
            gap.translatesAutoresizingMaskIntoConstraints = false
            let collapse = gap.widthAnchor.constraint(equalToConstant: minimum)
            collapse.priority = NSLayoutConstraint.Priority(rawValue: 499)
            gapConstraints += [gap.widthAnchor.constraint(greaterThanOrEqualToConstant: minimum), collapse]
        }
        NSLayoutConstraint.activate(gapConstraints)

        var topRowViews: [NSView] = [views.iconTile, textStack, leadingGap, statusColumn, reserveGap, views.trailingStack]
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

        // **The status column, positioned from the trailing edge.**
        //
        // This replaces §5.4's `textStack.width == 42% of the row` (clamped
        // to [200, 520]) - see `nameColumnMinWidth` for the two live-reported
        // defects that fixed-from-the-leading-edge column caused, and
        // `statusColumnTrailingReserve` for why measuring back from a
        // *reserved slot* keeps the pill a column when measuring back from
        // the actions themselves could not.
        //
        // `<=` is the whole trick: the pill may sit further left than the
        // reserve (a row whose actions genuinely need more room) but never
        // further right. Because `reserveGap` above prefers its own minimum
        // at 499 - which outranks `textStack`'s 250 stack-level hugging - the
        // solver keeps it collapsed and lets `textStack` take the slack, so
        // in the common case this inequality is tight and every row's pill
        // lands on the same x.
        //
        // Required priority is safe here, and deliberately chosen over the
        // 499 the old constraint needed. A window only holds its own size at
        // `NSLayoutPriorityWindowSizeStayPut` (500), so a content constraint
        // above that can resize the window - which is exactly what the old
        // pairing did: `.defaultHigh + 1` (751) on the 42% multiplier plus a
        // *required* `<= 520` cap capped the whole app window at
        // `520 / 0.42` + the row, card and page insets = **1410pt**, on every
        // page carrying these rows. Measured live on a 1512x982 screen: the
        // window refused to grow past 1410, reported `isZoomed == true`
        // there, and even genuine full screen rendered 1410pt wide, centred,
        // with a black bar down each side.
        //
        // That was a *maximum* on the content's width, so it propagated
        // outward as a maximum on the window's. This is a `<=` on a trailing
        // *position* with a flexible gap view absorbing it, and its only
        // outward effect is on the row's **minimum** width (icon + status +
        // reserve + chevron, ~300pt) - a floor no real window is anywhere
        // near, and a floor can never stop a window growing.
        // `checkRowDoesNotResizeWindow` proves that empirically rather than
        // taking this paragraph's word for it.
        let statusColumnRightEdge = showDetails ? views.detailsButton.leadingAnchor : topRow.trailingAnchor
        let nameFloor = textStack.widthAnchor.constraint(greaterThanOrEqualToConstant: nameColumnMinWidth)
        // Below stay-put as well, and below the required reserve, so a row
        // narrower than icon + 200 + status + reserve degrades by truncating
        // the text rather than by breaking the column it is meant to protect.
        nameFloor.priority = NSLayoutConstraint.Priority(rawValue: 499)
        NSLayoutConstraint.activate([
            nameFloor,
            statusColumn.trailingAnchor.constraint(lessThanOrEqualTo: statusColumnRightEdge,
                                                   constant: -statusColumnTrailingReserve),
        ])

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
        // The detail line now genuinely truncates at the name column's width
        // (see `build`'s label caps), so keep the whole string reachable on
        // hover. Set here rather than at each caller's `stringValue =` site
        // because every caller already calls this method after changing a
        // row's status text - Updates and GitHub Sync mutate their rows in
        // place, Bootstrap and Automation rebuild them.
        views.nameLabel.toolTip = views.nameLabel.stringValue
        views.detailLabel.toolTip = views.detailLabel.stringValue.isEmpty ? nil : views.detailLabel.stringValue
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
