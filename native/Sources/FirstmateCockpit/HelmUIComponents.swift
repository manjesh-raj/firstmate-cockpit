// Firstmate Cockpit - native macOS app.
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
