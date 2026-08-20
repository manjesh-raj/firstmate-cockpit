// Manjesh Grand Line - native macOS app.
//
// The bordered-terminal-card chrome Console paints over its terminal area
// while the current tab has SRE Lead active (`fm/grandline-sre-lead-app-
// feel`, from the captain's own reference mockup at
// `data/grandline-sre-lead-app-feel/reference-mockup.html`): the terminal
// reads as a rounded, bordered, elevated card floating on a workspace floor
// beside the SRE Lead panel, instead of a raw terminal butted flush against a
// side pane.
//
// **Why this is a drawn overlay and not a container view.** The obvious
// implementation - wrap the terminal in a card view and inset/resize that
// card when the pane opens - is exactly the bug `fm/cockpit-sre-lead-ux-fixes`
// already fixed once: any frame change on a SwiftTerm `TerminalView` triggers
// `resize(cols:rows:)`, which reflows the buffer at the new column count and
// can truncate scrollback a captain had already built up logging into a
// bastion. `ConsoleController`'s own layout comment spells that out, which is
// why the pane *overlays* `content` rather than pushing it.
//
// So the card look is achieved without moving the terminal at all:
//
//   * Every terminal on a host page is inset from `content` by a **permanent**
//     `pad` on all four sides (`ConsoleController.terminalInset`), fixed for
//     the controller's whole lifetime. That inset is what gives the card its
//     margin, and because it never changes, toggling SRE Lead is a pure
//     appearance change - this view's `isHidden`/`needsDisplay`, nothing else.
//   * With the pane closed the inset band is filled by `content`'s own
//     `backgroundHex` - the terminal's own background colour - so it reads as
//     ordinary terminal padding, not as a card.
//   * With the pane open this view (the topmost subview of `content`, and
//     hit-test transparent) paints the workspace floor over everything outside
//     the card, plus the card's rounded border and its drop shadow. The
//     terminal keeps its full width underneath; the strip between the card's
//     drawn trailing edge and the pane is simply covered, exactly as the pane
//     itself already covers the 380pt beneath it.
//
// The one visible cost of that trade: the card's drawn trailing edge sits
// `gap` points left of the pane, so the terminal's rightmost ~1.5 columns are
// hidden while SRE Lead is open - alongside the ~45 columns the pane itself
// has always covered. Nothing is hidden on the leading/top/bottom edges,
// because the terminal is genuinely inset there.

import AppKit

final class ConsoleCardChrome: NSView {

    /// Distance from `content`'s edges to the card. `ConsoleController` insets
    /// every terminal by this *plus* its own `cardInnerPadding`, so the drawn
    /// border sits just outside the terminal's own edge instead of on top of
    /// its first glyph column.
    var pad: CGFloat = HelmMetrics.s3

    /// The workspace gap between the terminal card's trailing edge and the
    /// SRE Lead pane's leading edge.
    var gap: CGFloat = HelmMetrics.s3

    /// Width of the SRE Lead pane strip overlaying this view's trailing edge,
    /// or `nil` when no pane is open (in which case the card spans the full
    /// content width). `ConsoleController` only ever shows this view while a
    /// pane is open, so `nil` is the degenerate case, kept so the geometry
    /// below has one definition rather than two.
    var paneStripWidth: CGFloat? {
        didSet { if paneStripWidth != oldValue { needsDisplay = true } }
    }

    private var theme: HelmTheme = ThemeManager.shared.theme

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not supported")
    }

    func applyTheme(_ theme: HelmTheme) {
        self.theme = theme
        needsDisplay = true
    }

    /// **Load-bearing, not a tidy-up.** This view covers the whole terminal
    /// area, so without it every click, drag-selection and scroll-wheel event
    /// meant for the terminal would land here instead the moment SRE Lead
    /// opened - the terminal would go dead while the pane was up. Returning
    /// `nil` keeps the view purely decorative: AppKit routes mouse and scroll
    /// events by `hitTest`, so they pass straight through to the terminal
    /// underneath.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        // The card's geometry is derived from `bounds` in `draw`, so a window
        // resize has to repaint rather than just re-stretch the last drawing.
        needsDisplay = true
    }

    // MARK: Geometry

    /// The terminal card, in this view's own coordinates. Its leading, top and
    /// bottom edges coincide with the terminal's real inset edges; only the
    /// trailing edge is a drawn boundary, pulled in to leave the workspace gap
    /// before the pane.
    var terminalCardRect: NSRect {
        let trailingInset = paneStripWidth.map { $0 + gap } ?? pad
        let width = bounds.width - pad - trailingInset
        let height = bounds.height - pad * 2
        guard width > 0, height > 0 else { return .zero }
        return NSRect(x: pad, y: pad, width: width, height: height)
    }

    /// The SRE Lead card, in this view's own coordinates - the same rect
    /// `ConsoleController` constrains `sreLeadCard` to inside the pane. This
    /// view never paints its fill or border (that card is a real view, on top
    /// of this one, and owns its own `HelmCard.applyCardSurface` chrome) - only
    /// its shadow, which has to be drawn down here to land on the floor
    /// *outside* the card.
    var paneCardRect: NSRect? {
        guard let strip = paneStripWidth else { return nil }
        let width = strip - pad
        let height = bounds.height - pad * 2
        guard width > 0, height > 0 else { return nil }
        return NSRect(x: bounds.maxX - strip, y: pad, width: width, height: height)
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        let card = terminalCardRect
        guard !card.isEmpty, let ctx = NSGraphicsContext.current?.cgContext else { return }

        let radius = HelmMetrics.rPanel
        let floor = HelmTheme.nsColor(theme.backgroundHex)
        let cardPath = NSBezierPath(roundedRect: card, xRadius: radius, yRadius: radius)

        // 1. The workspace floor, everywhere except inside the card. Even-odd
        //    so the card's own area - and the rounded corner wedges the
        //    terminal's square bounds would otherwise show through - is left
        //    untouched.
        let matte = NSBezierPath(rect: bounds)
        matte.append(cardPath)
        matte.windingRule = .evenOdd
        floor.setFill()
        matte.fill()

        // 2. Both cards' drop shadows. `drawOuterShadow` clips to the region
        //    *outside* the given rect before filling it, so only the shadow
        //    survives - the standard way to cast an outward shadow onto
        //    already-painted pixels without an extra layer or an inner-shadow
        //    artefact inside the card.
        drawOuterShadow(around: cardPath, radius: radius, ctx: ctx)
        if let pane = paneCardRect {
            drawOuterShadow(around: NSBezierPath(roundedRect: pane, xRadius: radius, yRadius: radius),
                            radius: radius, ctx: ctx)
        }

        // 3. The card outline. `HelmCard`'s own tokens: the border carries
        //    real load here, since `chromeBackgroundHex == backgroundHex` in
        //    three of the twelve palettes and the floor is `backgroundHex` -
        //    in those the outline is the only thing separating the terminal
        //    card from the floor around it.
        let stroke = NSBezierPath(roundedRect: card.insetBy(dx: 0.5, dy: 0.5),
                                  xRadius: radius, yRadius: radius)
        stroke.lineWidth = 1
        HelmTheme.nsColor(theme.chromeLineHex)
            .withAlphaComponent(HelmCard.borderAlpha).setStroke()
        stroke.stroke()
    }

    /// Casts `HelmCard.elevation`'s shadow outward from `path`, painting only
    /// the part that falls outside it.
    private func drawOuterShadow(around path: NSBezierPath, radius: CGFloat, ctx: CGContext) {
        ctx.saveGState()
        let outside = NSBezierPath(rect: bounds)
        outside.append(path)
        outside.windingRule = .evenOdd
        outside.addClip()
        HelmCard.elevation(for: theme).set()
        // Any opaque fill will do - the clip removes every pixel of it and
        // keeps only the shadow the fill cast beyond the path.
        NSColor.black.setFill()
        path.fill()
        ctx.restoreGState()
    }
}
