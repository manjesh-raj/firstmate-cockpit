// Manjesh Grand Line - native macOS app.
//
// The app's design system: shared metric/type tokens plus the one card
// container every page's sections are built out of.
//
// **Why this file exists.** The full-app UI audit
// (`data/grandline-full-ui-audit/report.md`) measured what a couple of dozen
// independent per-page redesigns had accumulated: five different card recipes
// visible side by side (radius 10 / 12 / 13 / 14, two fill opacities), the
// same `card(icon:title:content:)` helper copied byte-for-byte into four
// controllers, its theming loop copied verbatim into six, three page gutters
// (18 / 20 / 28pt) and eighteen distinct `systemFont` point sizes with three
// of them all doing "card title". None of that variation encoded a product
// decision - navigating Bootstrap -> Shift changed both the card translucency
// and the page gutter at once for no reason. This file is §6.2 (tokens) and
// §6.3 component 1 (`HelmCard`) of that report's phase 1.
//
// **Nothing here is a new design decision.** Every number below is one of the
// values already in the codebase, promoted to be the single one. `HelmCard`'s
// own chrome is `ShiftPanelView`'s (recipe C - opaque surface, `line @ 0.6`
// border, radius 12, a real header divider), which the audit picked as the
// model, widened with `SettingsController.card`'s icon-tile + title + subtitle
// header. The `ShiftPanelView` name is gone: this is that class, renamed and
// generalised, so there is one card component rather than two under different
// names.
//
// **Adding a new page section?** Build a `HelmCard`, give it a header
// (structured or arbitrary) and a body. Do not hand-roll a rounded background
// view, and do not add another `cardBackgrounds`-style theming registry - a
// `HelmCard` themes itself, including its own icon tile and header labels.

import AppKit

// MARK: - Metrics

/// The app's spacing / radius / size scale.
///
/// Replaces, in order: the ad-hoc 2/3/4/6/8/10/12/14/16/18/20/22/28 spacing
/// sprawl, the 5/6/7/8/9/10/12/13/14/15 radius sprawl, the three page gutters
/// (18/20/28) and the five `IconTileView` sizes (22/26/30/34/40).
enum HelmMetrics {
    // Spacing scale.
    static let s1: CGFloat = 4
    static let s2: CGFloat = 8
    static let s3: CGFloat = 12
    static let s4: CGFloat = 16
    static let s5: CGFloat = 24
    static let s6: CGFloat = 32

    // Corner radii, by role rather than by number.
    static let rChip: CGFloat = 6
    static let rControl: CGFloat = 8
    static let rCard: CGFloat = 12
    static let rPanel: CGFloat = 12

    /// The one page content gutter - the leading/trailing inset from a
    /// destination's scroll clip view to its content column.
    static let pageGutter: CGFloat = 24

    // The one icon-tile scale: three roles, not five sizes.
    /// Inline badge inside a dense row.
    static let tileSmall: CGFloat = 26
    /// The default - a card header, a checklist row.
    static let tileBase: CGFloat = 34
    /// A page-level or empty-state focal tile.
    static let tileLarge: CGFloat = 40
}

// MARK: - Type

/// The app's type scale, by role.
///
/// A rename rather than a redesign: every size below is one already in use,
/// picked as the single value for its role. The one genuine consolidation is
/// `sectionTitle` - card titles ship today at 14, 14.5 *and* 15 across
/// different pages, all doing the same job.
enum HelmType {
    /// The typographic voice a title is set in.
    ///
    /// `serif` (Georgia) exists in the Shift family only today, at four
    /// different sizes. Whether to promote it to the one app-wide page-title
    /// voice or retire it is a registered captain decision
    /// (`grandline-full-ui-audit-decision-page-title-voice`) and deliberately
    /// **not** settled here - this enum only gives that decision somewhere to
    /// land. Until it is answered, `.sans` is what non-Shift pages pass.
    enum Voice {
        case sans
        case serif
    }

    /// A destination's own hero title. 22pt in both voices, which is the size
    /// Overview and Review already use.
    static func pageTitle(_ voice: Voice = .sans) -> NSFont {
        switch voice {
        case .sans: return .systemFont(ofSize: 22, weight: .semibold)
        case .serif: return ShiftFont.serif(22)
        }
    }

    /// A card / section header title. Was 14 / 14.5 / 15 depending on page.
    static func sectionTitle() -> NSFont { .systemFont(ofSize: 15, weight: .semibold) }

    /// The title line of a row inside a card.
    static func rowTitle() -> NSFont { .systemFont(ofSize: 13, weight: .semibold) }

    /// Ordinary body copy.
    static func body() -> NSFont { .systemFont(ofSize: 12) }

    /// Supporting / secondary copy - a card subtitle, a row's detail line.
    static func caption() -> NSFont { .systemFont(ofSize: 11.5) }

    /// The small uppercase label above a row's body text.
    ///
    /// Kerning is a string attribute, not a font property - pair this with
    /// `kickerKern` (see `kickerAttributes`). Adoption of a single kicker
    /// belongs with `HelmAccentRow` (audit §6.3 component 2, a later phase);
    /// the existing four copies still carry their own 0.6 / 0.7 / 0.9 kern.
    static func kicker() -> NSFont { .systemFont(ofSize: 10, weight: .bold) }

    /// The tracking a kicker is set with.
    static let kickerKern: CGFloat = 0.9

    /// Attributes for an uppercase kicker in `color`.
    static func kickerAttributes(color: NSColor) -> [NSAttributedString.Key: Any] {
        [.font: kicker(), .kern: kickerKern, .foregroundColor: color]
    }

    /// A number meant to be read as a measurement - a stat tile's value, a
    /// count badge. Monospaced digits so it does not reflow as it changes.
    static func metric(_ size: CGFloat, weight: NSFont.Weight = .semibold) -> NSFont {
        .monospacedDigitSystemFont(ofSize: size, weight: weight)
    }
}

// MARK: - HelmCard

/// The app's one card / panel container: an optional header, a hairline
/// divider, and a body.
///
/// This is `ShiftPanelView` (audit recipe C, the model the report chose)
/// renamed and widened. Two ways to build the header:
///
/// - `setHeader(symbol:tint:title:subtitle:actions:)` - the structured form,
///   `SettingsController.card`'s icon-tile + title + subtitle header. The
///   card owns the tile and both labels, so it re-themes them itself.
/// - `setHeader(_:insets:)` - an arbitrary header view, for the headers that
///   carry their own count badges / filter rows / buttons.
///
/// A body is either flush (`insets: .zero`, the default - for a scroll view
/// or a list stack whose rows carry their own inset) or padded with
/// `HelmCard.contentInsets`, the one card body padding.
///
/// **It themes itself.** Do not add it to a page-level `cardBackgrounds`
/// registry; call `applyTheme(_:)` from the page's `ThemeManager.shared.observe`
/// closure and nothing else.
final class HelmCard: NSView {
    /// The one card body padding, for a card whose body is real content
    /// rather than a full-bleed list.
    static let contentInsets = NSEdgeInsets(top: HelmMetrics.s4, left: HelmMetrics.s4,
                                           bottom: HelmMetrics.s4, right: HelmMetrics.s4)

    /// The one card header padding.
    static let headerInsets = NSEdgeInsets(top: 11, left: HelmMetrics.s4,
                                          bottom: 11, right: HelmMetrics.s3)

    let headerContainer = NSView()
    let bodyContainer = NSView()
    private let divider = NSView()

    /// Set only by the structured `setHeader(symbol:...)`, so `applyTheme`
    /// knows whether it owns a tile and a subtitle label to re-colour.
    private var headerTile: IconTileView?
    private var headerTitle: NSTextField?
    private var headerSubtitle: NSTextField?

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = HelmMetrics.rCard
        translatesAutoresizingMaskIntoConstraints = false

        divider.wantsLayer = true
        divider.translatesAutoresizingMaskIntoConstraints = false
        headerContainer.translatesAutoresizingMaskIntoConstraints = false
        bodyContainer.translatesAutoresizingMaskIntoConstraints = false

        addSubview(headerContainer)
        addSubview(divider)
        addSubview(bodyContainer)
        NSLayoutConstraint.activate([
            headerContainer.leadingAnchor.constraint(equalTo: leadingAnchor),
            headerContainer.trailingAnchor.constraint(equalTo: trailingAnchor),
            headerContainer.topAnchor.constraint(equalTo: topAnchor),

            divider.leadingAnchor.constraint(equalTo: leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: trailingAnchor),
            divider.topAnchor.constraint(equalTo: headerContainer.bottomAnchor),
            divider.heightAnchor.constraint(equalToConstant: 1),

            bodyContainer.leadingAnchor.constraint(equalTo: leadingAnchor),
            bodyContainer.trailingAnchor.constraint(equalTo: trailingAnchor),
            bodyContainer.topAnchor.constraint(equalTo: divider.bottomAnchor),
            bodyContainer.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    // MARK: Header

    /// The structured header: icon tile, title, optional subtitle, optional
    /// trailing action views pushed to the card's trailing edge.
    ///
    /// Returns the title label so a caller that needs to mutate the text
    /// later (a live count in the title, a status word) can keep a reference,
    /// rather than having to reach back through the view tree.
    @discardableResult
    func setHeader(symbol: String,
                   tint: HelmTint = .accent,
                   title: String,
                   subtitle: String? = nil,
                   actions: [NSView] = []) -> NSTextField {
        var subtitleLabel: NSTextField?
        if let subtitle { subtitleLabel = NSTextField(wrappingLabelWithString: subtitle) }
        return setHeader(symbol: symbol,
                         tint: tint,
                         titleLabel: NSTextField(labelWithString: title),
                         subtitleLabel: subtitleLabel,
                         actions: actions)
    }

    /// The same structured header, but reusing **caller-owned** labels.
    ///
    /// For text the page rewrites as data arrives ("GitHub (3)", a live
    /// progress subtitle). The card still owns each label's font and colour, so
    /// the page only ever sets `stringValue`.
    @discardableResult
    func setHeader(symbol: String,
                   tint: HelmTint = .accent,
                   titleLabel: NSTextField,
                   subtitleLabel: NSTextField? = nil,
                   actions: [NSView] = []) -> NSTextField {
        let tile = IconTileView(size: HelmMetrics.tileBase, cornerRadius: 9)
        tile.configure(symbol: symbol, tint: tint)
        headerTile = tile

        headerTitle = titleLabel
        titleLabel.font = HelmType.sectionTitle()
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.lineBreakMode = .byTruncatingTail

        headerSubtitle = subtitleLabel
        var textViews: [NSView] = [titleLabel]
        if let subtitleLabel {
            subtitleLabel.font = HelmType.caption()
            subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
            textViews.append(subtitleLabel)
        }

        let titleStack = NSStackView(views: textViews)
        titleStack.orientation = .vertical
        titleStack.alignment = .leading
        titleStack.spacing = 1
        titleStack.translatesAutoresizingMaskIntoConstraints = false
        // The text column is the one thing in the row allowed to flex, so a
        // long title truncates rather than squeezing the tile or the actions
        // (AGENTS.md's dense-row compression-resistance gotcha).
        titleStack.setContentHuggingPriority(.defaultLow, for: .horizontal)
        titleStack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        var rowViews: [NSView] = [tile, titleStack]
        if !actions.isEmpty {
            let spacer = NSView()
            spacer.translatesAutoresizingMaskIntoConstraints = false
            spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
            rowViews.append(spacer)
            for action in actions {
                action.setContentHuggingPriority(.required, for: .horizontal)
                action.setContentCompressionResistancePriority(.required, for: .horizontal)
                rowViews.append(action)
            }
        }

        let row = NSStackView(views: rowViews)
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = HelmMetrics.s3
        // AGENTS.md gotcha #10: a horizontal NSStackView left at the default
        // `.gravityAreas` distribution honours no hugging priority at all, so
        // the trailing actions drift with sibling content instead of sitting
        // at the card's trailing edge.
        row.distribution = .fill
        row.translatesAutoresizingMaskIntoConstraints = false

        setHeader(row)
        applyTheme(ThemeManager.shared.theme)
        return titleLabel
    }

    /// An arbitrary header view - for headers carrying their own badges,
    /// filter rows or buttons.
    func setHeader(_ view: NSView, insets: NSEdgeInsets = HelmCard.headerInsets) {
        headerContainer.subviews.forEach { $0.removeFromSuperview() }
        view.translatesAutoresizingMaskIntoConstraints = false
        headerContainer.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: headerContainer.leadingAnchor, constant: insets.left),
            view.trailingAnchor.constraint(equalTo: headerContainer.trailingAnchor, constant: -insets.right),
            view.topAnchor.constraint(equalTo: headerContainer.topAnchor, constant: insets.top),
            view.bottomAnchor.constraint(equalTo: headerContainer.bottomAnchor, constant: -insets.bottom),
        ])
    }

    // MARK: Body

    /// `insets` defaults to flush, which is what a scroll view or a list
    /// stack whose rows carry their own inset wants. A card whose body is
    /// real content passes `HelmCard.contentInsets`.
    func setBody(_ view: NSView, insets: NSEdgeInsets = NSEdgeInsets()) {
        bodyContainer.subviews.forEach { $0.removeFromSuperview() }
        view.translatesAutoresizingMaskIntoConstraints = false
        bodyContainer.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: bodyContainer.leadingAnchor, constant: insets.left),
            view.trailingAnchor.constraint(equalTo: bodyContainer.trailingAnchor, constant: -insets.right),
            view.topAnchor.constraint(equalTo: bodyContainer.topAnchor, constant: insets.top),
            view.bottomAnchor.constraint(equalTo: bodyContainer.bottomAnchor, constant: -insets.bottom),
        ])
    }

    // MARK: Theme

    func applyTheme(_ theme: HelmTheme) {
        Self.applyCardSurface(to: self, theme: theme)
        divider.layer?.backgroundColor = HelmTheme.nsColor(theme.chromeLineHex)
            .withAlphaComponent(Self.dividerAlpha).cgColor
        headerTile?.applyTheme(theme)
        // Theme-derived, never the system `labelColor` the four card copies
        // this replaced relied on - a forced `appearance` only picks the right
        // side of light/dark for a system grey, it cannot make it match the
        // palette (audit §5.3, Phase 0's rule).
        headerTitle?.textColor = HelmTheme.nsColor(theme.chromeInkHex)
        headerSubtitle?.textColor = HelmTheme.mutedInk(theme)
    }

    // MARK: The one card surface

    /// The app's card fill / border, in one place.
    ///
    /// Public and static because a handful of surfaces genuinely share this
    /// chrome without being cards yet - Updates' stat tiles, whose own
    /// consolidation is `HelmStatTile` in a later phase. They call this so
    /// there is still exactly one fill opacity and one border on any given
    /// page, and pass their own `cornerRadius` until that phase unifies it.
    ///
    /// An **opaque** surface, not `surface @ 0.6`: two of the five recipes
    /// this replaced were translucent, and translucency here buys nothing
    /// (there is only the flat page background behind a card) while making
    /// the card's effective colour depend on what it happens to sit on.
    static func applyCardSurface(to view: NSView, theme: HelmTheme, cornerRadius: CGFloat = HelmMetrics.rCard) {
        view.wantsLayer = true
        view.layer?.cornerRadius = cornerRadius
        view.layer?.backgroundColor = HelmTheme.nsColor(theme.chromeBackgroundHex).cgColor
        view.layer?.borderWidth = 1
        view.layer?.borderColor = HelmTheme.nsColor(theme.chromeLineHex)
            .withAlphaComponent(borderAlpha).cgColor
    }

    /// The card border opacity. `chromeBackgroundHex == backgroundHex` in
    /// three of the twelve themes (`gruvbox-light`, `tokyo-night-dark`,
    /// `tokyo-night-light`), so in those the border is the *only* thing
    /// separating a card from the page - it carries real load, and is not
    /// decoration to be faded away.
    static let borderAlpha: CGFloat = 0.6

    /// The header/body divider opacity - one step fainter than the card's own
    /// outline, so the card reads as one object rather than two stacked ones.
    static let dividerAlpha: CGFloat = 0.5
}

// MARK: - HelmButton

/// The app's one button.
///
/// **Why this exists.** The audit (§3.2 "Buttons - the biggest single driver
/// of the legacy feel") counted **124 stock `bezelStyle` buttons across 29
/// files** and **18 `keyEquivalent = "\r"` default buttons across 15**. A
/// stock `NSButton` paints macOS's own grey gradient bezel and a default
/// button paints literal system blue (`#0a84ff` measured; `controlAccentColor`
/// is `#007aff`, `selectedContentBackgroundColor` `#0059d1`) - none of which
/// has any relationship to the 12 Helm accents
/// (`#6cd7e3 #007194 #2aa198 #cba6f7 #8839ef #fe8019 #af3a03 #7aa2f7 #2959aa
/// #c4a7e7 #286983`, no overlap). So a fully themed app still read as generic
/// system chrome, and the report's own conclusion was that this one component
/// "would change the app's perceived age more than any other single change."
///
/// **Nothing here is a new visual invention.** The recipe is
/// `UpdatesController`'s Refresh pill - the single correctly-themed primary
/// action that already existed - promoted into a real control: an opaque
/// `accentHex` fill with a `selectionTextHex` label. That pairing is not a
/// guess either; `selectionTextHex` is SwiftTerm's own selected-text tone,
/// already contrast-verified against an opaque `accentHex` in every palette
/// (and re-asserted per theme by `HelmContrastSelfTest`).
///
/// **How it stops being a bezel.** `isBordered = false` makes AppKit draw no
/// bezel at all - verified by rendering a real default button both ways: the
/// stock one composites its bezel material, the unbordered one captures fully
/// transparent. So the Return-key shortcut (`keyEquivalent = "\r"`, which
/// every migrated site keeps) survives while the blue *look* has nothing left
/// to paint. Chrome then comes from the view's own layer, and the label from
/// `attributedTitle` - `contentTintColor` does not colour a string title,
/// only an image, which is why three pages had already hand-rolled exactly
/// this workaround before it was shared (`UpdatesController`'s "Install in
/// Bootstrap", `CommandLibraryViews`' Copy and Favorite).
///
/// **It themes itself**, like `HelmCard`: it registers its own
/// `ThemeManager.observe` and unregisters in `deinit`, so no page has to keep
/// a button registry. That is deliberate rather than convenient - a per-page
/// registry is exactly the shape of `ThemeManager.swift`'s checklist item 4
/// (a theme closure looping a collection that is still empty on its first,
/// synchronous firing), which is the single most repeated bug class in this
/// codebase.
///
/// **Migrating a site** is a type change, nothing more; `title`, `target`,
/// `action`, `keyEquivalent`, `isEnabled`, `isHidden`, `controlSize` and
/// `identifier` all keep working, because this is an `NSButton`:
///
/// ```swift
/// // before
/// let save = NSButton(title: "Save", target: self, action: #selector(save))
/// save.bezelStyle = .rounded
/// save.keyEquivalent = "\r"
/// // after
/// let save = HelmButton(title: "Save", variant: .primary, target: self, action: #selector(save))
/// save.keyEquivalent = "\r"
/// ```
final class HelmButton: NSButton {
    /// Which of the four roles a button plays. Picked per site from what the
    /// button already did, not assigned mechanically: `.primary` is the one
    /// action a sheet or card is *for*, `.secondary` is everything ordinary,
    /// `.quiet` is toolbar/inline weight, `.destructive` is delete/discard.
    enum Variant {
        /// Opaque accent fill, `selectionTextHex` label. At most one per
        /// sheet footer / card header.
        case primary
        /// Bordered, theme-derived - the default. Replaces the stock bezel.
        case secondary
        /// Borderless, muted label, hover-only background. Toolbar icons and
        /// link-weight actions.
        case quiet
        /// A contrast-corrected wash of the theme's own red. Delete, discard,
        /// "Keep deleted".
        case destructive
    }

    /// Two densities, matching `controlSize`'s `.regular` / `.small` so an
    /// existing `controlSize = .small` line at a migrated site keeps working
    /// unchanged (see the `controlSize` override).
    enum Size {
        case regular
        case small

        var font: NSFont {
            switch self {
            case .regular: return .systemFont(ofSize: 12, weight: .semibold)
            case .small: return .systemFont(ofSize: 11, weight: .semibold)
            }
        }

        var symbolPointSize: CGFloat {
            switch self {
            case .regular: return 12
            case .small: return 11
            }
        }

        /// Vertical padding above/below the label.
        var vInset: CGFloat {
            switch self {
            case .regular: return 6
            case .small: return 4
            }
        }

        /// The floor height, so a row of buttons stays on one baseline even
        /// when one of them is icon-only.
        var minHeight: CGFloat {
            switch self {
            case .regular: return 26
            case .small: return 21
            }
        }
    }

    // MARK: Configuration

    var variant: Variant {
        didSet { if variant != oldValue { invalidateIntrinsicContentSize(); restyle() } }
    }

    var size: Size {
        didSet { if size != oldValue { rebuildImage(); invalidateIntrinsicContentSize(); restyle() } }
    }

    /// An optional semantic hue for the *label* of a `.secondary` / `.quiet`
    /// button - the "this action is amber / accent-coloured" emphasis three
    /// pages had already hand-rolled with `attributedTitle`. Routed through
    /// `HelmContrast` rather than used raw, per Phase 0's rule: a `HelmTint`
    /// hue is safe as a fill or a bar and is **not** automatically safe as
    /// text. Ignored by `.primary` (its label is fixed to the on-accent tone)
    /// and by `.destructive` (its hue is already the point).
    var tint: HelmTint? {
        didSet { if tint != oldValue { restyle() } }
    }

    /// SF Symbol shown before the title, or alone when the title is empty.
    var symbolName: String? {
        didSet { if symbolName != oldValue { rebuildImage(); invalidateIntrinsicContentSize(); restyle() } }
    }

    private var plainTitle: String
    private var isHovering = false
    private var isPressed = false
    private var themeObservation: ThemeObservation?
    private var hoverTracking: NSTrackingArea?

    // MARK: Init

    init(title: String,
         variant: Variant = .secondary,
         size: Size = .regular,
         symbol: String? = nil,
         target: AnyObject? = nil,
         action: Selector? = nil) {
        self.plainTitle = title
        self.variant = variant
        self.size = size
        self.symbolName = symbol
        super.init(frame: .zero)

        // No bezel to paint grey (or system blue): all chrome is this view's
        // own layer from here on.
        isBordered = false
        // The stock default/focus rings are the other half of the system-blue
        // look the audit measured.
        focusRingType = .none
        wantsLayer = true
        layer?.masksToBounds = true
        alignment = .center
        lineBreakMode = .byTruncatingTail
        self.target = target
        self.action = action
        rebuildImage()

        // Registered last: `observe` fires synchronously, and `restyle` reads
        // every property above.
        themeObservation = ThemeManager.shared.observe { [weak self] _ in self?.restyle() }
        // Match `NSButton(title:target:action:)`, which hands back a
        // already-sized frame - a caller using frame layout (or relying on
        // `translatesAutoresizingMaskIntoConstraints`'s default `true`, which
        // this deliberately leaves alone) would otherwise get a zero rect.
        sizeToFit()
    }

    /// A title-less icon button - the toolbar shape. `.quiet` by default,
    /// since that is what a bare glyph in a toolbar reads as.
    convenience init(symbol: String,
                     variant: Variant = .quiet,
                     size: Size = .regular,
                     target: AnyObject? = nil,
                     action: Selector? = nil) {
        self.init(title: "", variant: variant, size: size, symbol: symbol, target: target, action: action)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    deinit {
        if let themeObservation { ThemeManager.shared.unobserve(themeObservation) }
    }

    // MARK: NSButton overrides

    /// Kept in sync with the plain string this button re-derives its
    /// `attributedTitle` from, so a site that rewrites `title` live (a
    /// Favorite / Favorited flip, a "Save"/"Create" swap) still repaints.
    override var title: String {
        get { plainTitle }
        set {
            plainTitle = newValue
            rebuildImage()
            invalidateIntrinsicContentSize()
            restyle()
        }
    }

    /// `.small` / `.mini` map to `Size.small`, so a migrated site's existing
    /// `controlSize = .small` line needs no edit.
    override var controlSize: NSControl.ControlSize {
        get { super.controlSize }
        set {
            super.controlSize = newValue
            size = (newValue == .small || newValue == .mini) ? .small : .regular
        }
    }

    /// A disabled button dims as a whole - fill, border, label and glyph
    /// together - rather than relying on the cell's own greying, which only
    /// applies to chrome this no longer draws.
    override var isEnabled: Bool {
        get { super.isEnabled }
        set { super.isEnabled = newValue; restyle() }
    }

    override var intrinsicContentSize: NSSize {
        var s = super.intrinsicContentSize
        s.width += 2 * hInset
        s.height = max(s.height + 2 * size.vInset, size.minHeight)
        // An icon-only button reads as a square tap target, not a sliver.
        if plainTitle.isEmpty { s.width = max(s.width, s.height) }
        return s
    }

    // MARK: Press / hover feedback

    override func mouseDown(with event: NSEvent) {
        isPressed = true
        restyle()
        // `super` runs AppKit's own tracking loop, so click-cancel-by-dragging
        // -out and the action dispatch itself stay exactly as they were.
        super.mouseDown(with: event)
        isPressed = false
        restyle()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTracking { removeTrackingArea(hoverTracking) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseEnteredAndExited, .activeInKeyWindow],
                                  owner: self,
                                  userInfo: nil)
        addTrackingArea(area)
        hoverTracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovering = true
        restyle()
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
        restyle()
    }

    // MARK: Chrome

    /// Horizontal padding. `.quiet` is tighter, so a bare toolbar glyph does
    /// not carry a pill's worth of dead space around it.
    private var hInset: CGFloat {
        switch (variant, size) {
        case (.quiet, .regular): return 8
        case (.quiet, .small): return 6
        case (_, .regular): return 13
        case (_, .small): return 10
        }
    }

    /// What this button is actually painted with, for `theme`.
    ///
    /// Exposed (rather than private) so `HelmButtonSelfTest` can assert the
    /// real resolved colours per variant per theme instead of re-deriving
    /// them, and so a probe can pixel-check a render against them.
    struct Palette {
        let fill: NSColor
        let hoverFill: NSColor
        let pressedFill: NSColor
        let border: NSColor
        let label: NSColor
    }

    static func palette(variant: Variant, tint: HelmTint?, theme: HelmTheme) -> Palette {
        let ink = HelmTheme.nsColor(theme.chromeInkHex)
        let line = HelmTheme.nsColor(theme.chromeLineHex)
        let hoverWash = line.withAlphaComponent(0.30)

        switch variant {
        case .primary:
            let accent = HelmTheme.nsColor(theme.accentHex)
            return Palette(fill: accent,
                           hoverFill: accent.hoverShifted(by: 0.12, forMode: theme.mode),
                           // Pressed goes the *other* way from hover, so the
                           // two states are never confusable.
                           pressedFill: accent.hoverShifted(by: 0.14, forMode: theme.mode == .dark ? .light : .dark),
                           border: .clear,
                           label: HelmTheme.nsColor(theme.selectionTextHex))

        case .secondary:
            // The one "sunken control fill" in this app: `chromeInkHex`
            // blended 8% into `chromeBackgroundHex`. Deliberately not
            // `backgroundHex`, which is numerically identical to
            // `chromeBackgroundHex` in gruvbox-light / tokyo-night-dark /
            // tokyo-night-light and would leave the control invisible there.
            let fill = Self.controlFill(theme)
            return Palette(fill: fill,
                           hoverFill: fill.hoverShifted(by: 0.07, forMode: theme.mode),
                           pressedFill: fill.hoverShifted(by: 0.12, forMode: theme.mode),
                           border: line.withAlphaComponent(0.70),
                           // `chromeInkHex` is guaranteed against the theme's
                           // *card* surface, and this fill sits 8% off it -
                           // enough to drop solarized-dark's ink to 4.20:1
                           // (measured). So the ink gets the same treatment
                           // every other tone in this file gets rather than
                           // being assumed safe.
                           label: Self.label(tint: tint, over: fill, theme: theme)
                               ?? Self.legible(ink, over: fill))

        case .quiet:
            let fill = NSColor.clear
            return Palette(fill: fill,
                           hoverFill: hoverWash,
                           pressedFill: line.withAlphaComponent(0.42),
                           border: .clear,
                           // A quiet button sits directly on a page or a card,
                           // so score its tinted label against the card
                           // surface it is most likely on.
                           label: Self.label(tint: tint,
                                             over: HelmTheme.nsColor(theme.chromeBackgroundHex),
                                             theme: theme) ?? HelmTheme.mutedInk(theme))

        case .destructive:
            // Phase 0's rule in one line: the red hue is fine as the fill,
            // and is *not* automatically legible as the label on top of it -
            // `tintedSurface` flattens the wash and nudges the label toward
            // the theme's own ink by the least amount that clears 4.5:1.
            let redHex = theme.ansiHex[1]
            let resolved = HelmContrast.tintedSurface(tintHex: redHex,
                                                      theme: theme,
                                                      target: HelmContrast.textTarget)
            return Palette(fill: resolved.fill,
                           hoverFill: resolved.fill.hoverShifted(by: 0.08, forMode: theme.mode),
                           pressedFill: resolved.fill.hoverShifted(by: 0.14, forMode: theme.mode),
                           border: HelmTheme.nsColor(redHex).withAlphaComponent(0.45),
                           label: resolved.foreground)
        }
    }

    /// The shared sunken-control fill, and the single definition of it.
    /// `ConsoleComposerPopover`, `ShiftController`'s project-detail form and
    /// `ShiftTaskEditorController` each carried a byte-identical private copy
    /// (audit §3.2, "Sunken form field - 3 byte-identical copies"); their
    /// consolidation into a real `HelmField` is Phase 6, but every button and
    /// popup this phase touches already reads it from here.
    static func controlFill(_ theme: HelmTheme) -> NSColor {
        let chromeBackground = HelmTheme.nsColor(theme.chromeBackgroundHex)
        let ink = HelmTheme.nsColor(theme.chromeInkHex)
        return chromeBackground.blended(withFraction: 0.08, of: ink) ?? chromeBackground
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
    static func legible(_ base: NSColor, over surface: NSColor) -> NSColor {
        if HelmContrast.ratio(base, surface) >= HelmContrast.textTarget { return base }
        let endpoint: NSColor = HelmContrast.relativeLuminance(HelmContrast.components(surface)) > 0.35
            ? .black : .white
        for step in stride(from: 0.05, through: 1.0, by: 0.05) {
            guard let blended = base.blended(withFraction: CGFloat(step), of: endpoint) else { break }
            if HelmContrast.ratio(blended, surface) >= HelmContrast.textTarget { return blended }
        }
        return endpoint
    }

    /// A tinted label, contrast-corrected against the surface it lands on -
    /// `nil` when no tint was asked for, so the caller falls back to ink.
    private static func label(tint: HelmTint?, over surface: NSColor, theme: HelmTheme) -> NSColor? {
        guard let tint else { return nil }
        let hue = HelmTheme.nsColor(tint.hex(in: theme))
        if HelmContrast.ratio(hue, surface) >= HelmContrast.textTarget { return hue }
        // Blend toward the theme's ink by the smallest step that clears the
        // floor - the same technique as `HelmContrast.tintedSurface`, applied
        // to a label over an already-known opaque fill.
        let ink = HelmTheme.nsColor(theme.chromeInkHex)
        for step in stride(from: 0.1, through: 1.0, by: 0.1) {
            guard let blended = hue.blended(withFraction: CGFloat(step), of: ink) else { break }
            if HelmContrast.ratio(blended, surface) >= HelmContrast.textTarget { return blended }
        }
        return legible(ink, over: surface)
    }

    private func restyle() {
        let theme = ThemeManager.shared.theme
        let p = Self.palette(variant: variant, tint: tint, theme: theme)

        let fill: NSColor
        if !isEnabled { fill = p.fill }
        else if isPressed { fill = p.pressedFill }
        else if isHovering { fill = p.hoverFill }
        else { fill = p.fill }

        layer?.cornerRadius = HelmMetrics.rControl
        layer?.backgroundColor = fill.cgColor
        layer?.borderColor = p.border.cgColor
        layer?.borderWidth = p.border.alphaComponent > 0 ? 1 : 0
        // Dim the whole control, not just chrome the cell no longer draws.
        alphaValue = isEnabled ? 1 : 0.42

        let labelColor = (variant == .quiet && isHovering && isEnabled)
            ? HelmTheme.nsColor(theme.chromeInkHex)
            : p.label
        let paragraph = NSMutableParagraphStyle()
        // `NSButton.attributedTitle` lays text out with the *string's* own
        // paragraph alignment, not the button's `alignment` - omitting this
        // left the rail's labels (and their icons) visibly off-centre once
        // before (`fm/grandline-sidebar-nav-polish`).
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byTruncatingTail
        super.attributedTitle = NSAttributedString(string: plainTitle, attributes: [
            .font: size.font,
            .foregroundColor: labelColor,
            .paragraphStyle: paragraph,
        ])
        // The glyph does follow `contentTintColor` (only a string title does not).
        contentTintColor = labelColor
    }

    private func rebuildImage() {
        guard let symbolName else {
            image = nil
            imagePosition = .noImage
            return
        }
        let configuration = NSImage.SymbolConfiguration(pointSize: size.symbolPointSize, weight: .semibold)
        image = NSImage(systemSymbolName: symbolName, accessibilityDescription: plainTitle.isEmpty ? symbolName : plainTitle)?
            .withSymbolConfiguration(configuration)
        imagePosition = plainTitle.isEmpty ? .imageOnly : .imageLeading
        // Without this the glyph is pinned to the cell's leading edge and the
        // title floats away from it, instead of the two reading as one label.
        imageHugsTitle = true
        imageScaling = .scaleNone
    }
}

// MARK: - HelmPopUpButton

/// `NSPopUpButton` with `HelmButton(.secondary)`'s chrome.
///
/// The audit counted 13 `NSPopUpButton`s rendering in system chrome (§3.2),
/// and §6.5 put *reimplementing* AppKit controls out of scope - "wrapping
/// their containers and re-tinting is buildable; reimplementing a date picker
/// is not worth it." A popup happens to need neither: `NSPopUpButton` is an
/// `NSButton` subclass, so `isBordered = false` drops its bezel exactly like
/// `HelmButton`'s while the menu, `selectItem…`, `titleOfSelectedItem`,
/// `indexOfSelectedItem` and every other API a caller uses keep working -
/// verified live before this was written (unbordered + layer fill + tint
/// renders themed, and `titleOfSelectedItem` / `numberOfItems` still report
/// correctly). Migrating a site is therefore also just a type change.
///
/// The one visible difference from `HelmButton`: the cell still draws the
/// disclosure chevron, which follows `contentTintColor`.
final class HelmPopUpButton: NSPopUpButton {
    private var themeObservation: ThemeObservation?

    init() {
        super.init(frame: .zero, pullsDown: false)
        commonSetup()
    }

    override init(frame: NSRect, pullsDown: Bool) {
        super.init(frame: frame, pullsDown: pullsDown)
        commonSetup()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    deinit {
        if let themeObservation { ThemeManager.shared.unobserve(themeObservation) }
    }

    private func commonSetup() {
        isBordered = false
        focusRingType = .none
        wantsLayer = true
        layer?.masksToBounds = true
        themeObservation = ThemeManager.shared.observe { [weak self] theme in self?.applyTheme(theme) }
    }

    /// A popup's own title is drawn from its selected menu item, not from
    /// `attributedTitle`, so its label follows `contentTintColor` here -
    /// unlike `HelmButton`, whose string title does not.
    private func applyTheme(_ theme: HelmTheme) {
        let p = HelmButton.palette(variant: .secondary, tint: nil, theme: theme)
        layer?.cornerRadius = HelmMetrics.rControl
        layer?.backgroundColor = p.fill.cgColor
        layer?.borderWidth = 1
        layer?.borderColor = p.border.cgColor
        contentTintColor = p.label
        // The menu itself is AppKit chrome drawn outside this view; matching
        // its light/dark side to the theme is all a view can do for it.
        appearance = NSAppearance(named: theme.mode == .dark ? .darkAqua : .aqua)
    }

    override var intrinsicContentSize: NSSize {
        var s = super.intrinsicContentSize
        // The stock bezel supplied this padding; an unbordered cell does not.
        s.width += 10
        s.height = max(s.height, 24)
        return s
    }
}
