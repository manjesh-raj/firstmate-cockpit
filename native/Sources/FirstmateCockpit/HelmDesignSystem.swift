// Manjesh Grand Line - native macOS app.
//
// The app's design system: shared metric/type tokens, the one card container
// every page's sections are built out of, the one button, and the one
// accent-carrying row.
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
// and the page gutter at once for no reason. This file is §6.2 (tokens) plus
// §6.3 components 1 (`HelmCard`, phase 1), 3 (`HelmButton`, phase 2), 2
// (`HelmAccentRow`, phase 3) and 4/5/6 (`HelmStatTile`, `HelmEmptyState`,
// `HelmSegmentedTabs`, phase 4) of that report.
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
    /// A row card nested *inside* a card - one step tighter than `rCard`, so
    /// the two radii read as a hierarchy rather than competing. 10 is the
    /// value all four accent-row copies already shared before `HelmAccentRow`
    /// (audit §3.2); this is the token for it.
    static let rRow: CGFloat = 10

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
    /// The registered captain decision
    /// (`grandline-full-ui-audit-decision-page-title-voice`) is **settled**,
    /// and it went the way §6.2 recommended: **promote** `serif` (Georgia) to
    /// the app-wide page-title voice rather than retire it for all-sans. It is
    /// the app's only real typographic personality, the captain had already
    /// approved it for Shift, and it costs one line per hero title.
    ///
    /// So `.serif` is what a destination's **hero title** passes - Phase 7
    /// applied it at exactly one size (22, see `pageTitle`) in place of the
    /// four Shift-era sizes (15 / 19 / 22 / 23) the audit measured.
    ///
    /// `.sans` is not dead, and is deliberately still the default: it is the
    /// voice for display type that is *not* a page hero - a sheet's heading
    /// (`HelmFormSheet` sets its own at `sectionTitle()`), and the task
    /// editor's lead **input** field (`HelmTextField(.lead)`), which is text
    /// the captain types rather than a title the app displays.
    ///
    /// Do not add a third case or a second size. A page that wants a smaller
    /// title wants `sectionTitle()`.
    enum Voice {
        case sans
        case serif
    }

    /// A destination's own hero title. One size, 22pt, in both voices - the
    /// size Overview and Review already used, and the one Phase 7 collapsed
    /// Shift's four onto.
    ///
    /// A hero title is for a page whose title carries **information**: a
    /// greeting ("Good afternoon"), or the name of the record being viewed (a
    /// project, a command). It is *not* for restating the destination's own
    /// name - the top bar already shows that, which is why Phase 7 removed
    /// Review's literal "Review" label rather than restyling it.
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
    /// `kickerKern` (see `kickerAttributes`). This is now the app's only
    /// kicker: Phase 3 replaced the four hand-rolled copies that each carried
    /// their own 0.6 / 0.7 / 0.9 kern, and `HelmContrastSelfTest.
    /// checkNoHandRolledKickers` fails the build on a new one.
    static func kicker() -> NSFont { .systemFont(ofSize: 10, weight: .bold) }

    /// The tracking a kicker is set with.
    static let kickerKern: CGFloat = 0.9

    /// Attributes for an uppercase kicker in `color`.
    static func kickerAttributes(color: NSColor) -> [NSAttributedString.Key: Any] {
        [.font: kicker(), .kern: kickerKern, .foregroundColor: color]
    }

    /// Text that *is* code - a saved snippet's command preview, a key
    /// fingerprint. Monospaced at `caption()`'s size, so a code line and a
    /// prose caption sit on the same baseline rhythm.
    static func code() -> NSFont { .monospacedSystemFont(ofSize: 11.5, weight: .regular) }

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
            // The one sunken-control fill, defined once in `HelmField`
            // (Phase 6) - a `.secondary` button and a text field beside it are
            // the same surface, and were already meant to be before there was
            // a component to say so.
            let fill = HelmField.fill(theme)
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
                               ?? HelmContrast.legible(ink, over: fill))

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

    /// A tinted label, contrast-corrected against the surface it lands on -
    /// `nil` when no tint was asked for, so the caller falls back to ink.
    ///
    /// Thin wrapper over `HelmContrast.legibleTintedText`, which Phase 4
    /// promoted out of here so `HelmStatTile` could colour a tinted metric
    /// the same way rather than re-deriving it (two of the three stat-tile
    /// copies it replaced set a metric label to the raw hue - the §5.7
    /// mistake).
    private static func label(tint: HelmTint?, over surface: NSColor, theme: HelmTheme) -> NSColor? {
        guard let tint else { return nil }
        return HelmContrast.legibleTintedText(tintHex: tint.hex(in: theme), over: surface, theme: theme)
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

// MARK: - HelmAccentRow

/// The app's one "accent-carrying row": a coloured left accent bar, a tinted
/// round badge (or a caller-owned leading control), a kern'd uppercase kicker,
/// a body line, an optional meta line, and a tinted chip - on a card whose
/// border is a wash of the same hue.
///
/// **Why this exists.** The audit (§3.2, "Accent-bar card with an uppercase
/// kicker") found **four independent copies** of this one idea. All four
/// agreed on the 3pt bar at radius 1.5 and the radius-10 card, and disagreed
/// on everything else: three separate kicker constructions at three kern
/// values (0.9 / 0.7 / 0.6), two badge treatments, and one outlier
/// (`SRELeadChatView.accentCard`) with no border at all whose kicker was
/// coloured from the tint hue rather than `mutedInk`. A fifth surface,
/// Overview's "In flight" rows, had the badge and the chip but neither the
/// bar nor the kicker. The visible consequence: an SRE Lead "Finding" and a
/// Notification "PR Ready" - both meaning *here is a coloured, kickered
/// finding* - did not read as the same kind of object.
///
/// **Nothing here is a new design.** This is `NotificationRowView`
/// (`NotificationCenterPopover.swift`), which the audit called "the only
/// place in the app where the whole recipe is correct at once" and which the
/// captain singled out as the template, promoted and parameterised. Its
/// geometry, its `HoverHighlightView` card, its `tint @ 0.4` border, its
/// 26pt circular `IconTileView` badge and its `ToolRowLayout.pill` chip are
/// carried over unchanged; the row is now built once here instead of five
/// times across four files.
///
/// **The one rule that matters when extending this**: the kicker is
/// `HelmTheme.mutedInk`, never the tint hue. A `HelmTint` hue is safe as a
/// *fill* or a *bar* and is not automatically safe as *text* - see
/// `HelmContrast`'s doc comment and audit §5.7. That is why the tint reaches
/// the bar, the badge and the chip here and never the kicker, and it is
/// checked by `HelmContrastSelfTest.checkNoHandRolledKickers`.
///
/// **Not merged with `ToolRowLayout`**, deliberately: that is a dense
/// checklist row (fixed name/status columns, action buttons, a disclosure
/// chevron and an expandable log) and this is an alert/task card. They share
/// the primitives that carry the visual language - `ToolRowLayout.pill`,
/// `IconTileView`, `ToolRowLayout.attachAccentBar`'s idiom, `HelmType` - and
/// nothing else, because their layouts genuinely differ.
final class HelmAccentRow: NSView {

    /// Where the chip sits. `.trailing` is a wide list row (Shift's task and
    /// follow-up lists, Overview's "In flight"); `.belowBody` is the
    /// notification panel, which is 340pt wide and has no room for a chip
    /// beside wrapping body text. Bar weight and position, badge size, kicker
    /// typography and chip style are identical either way.
    enum ChipPlacement { case trailing, belowBody }

    /// Everything that varies per row. Structure - chip placement, whether
    /// there is a leading control, whether the body is text or a caller-owned
    /// view - is fixed at `init`, so a reused `NSTableView` cell can be
    /// re-pointed at a different record by calling `configure` alone.
    struct Content {
        /// Drives the accent bar, the badge and the card border: the row's
        /// single "what kind of thing is this" signal.
        var tint: HelmTint
        /// Rendered uppercase and kern'd in `mutedInk`. Never tinted.
        var kicker: String
        /// The row's headline. Ignored when the row was built with a
        /// caller-owned `contentView`.
        var title: String = ""
        /// A second, quieter line under the title. Hidden when nil/empty.
        var meta: String? = nil
        /// The badge glyph. Ignored when the row was built with a
        /// `leadingControl`; when both are absent, the row has no badge.
        var badgeSymbol: String? = nil
        /// A small glyph beside the title - Shift's "has an attachment"
        /// paperclip. Hidden when nil.
        var titleAccessorySymbol: String? = nil
        /// The chip's text. Hidden when nil.
        var chipText: String? = nil
        /// Defaults to `tint`. Set it only where the chip carries a
        /// *different* signal from the bar - a Shift follow-up's bar reads
        /// done/pending while its chip reads priority.
        var chipTint: HelmTint? = nil
        /// A wide row truncates its title to one line; a narrow one wraps.
        var titleWraps: Bool = false
        /// Render `meta` in `HelmType.code()` rather than `caption()` - for a
        /// meta line that is literally a command or a fingerprint, where
        /// proportional spacing costs real readability.
        var metaIsCode: Bool = false
        /// A literal hue for the bar / badge / border, overriding `tint`.
        ///
        /// Only for a record that genuinely carries a **user-chosen** colour
        /// rather than a semantic one: a saved `Host`'s own `accentHex`
        /// (picked per host in the host editor) and an `SSHKeyType`'s fixed
        /// per-algorithm accent. Everything else passes a `HelmTint`, which
        /// resolves against the active palette. The kicker is still
        /// `mutedInk` either way - a literal hue is no safer as text than a
        /// `HelmTint` one.
        var tintHex: String? = nil

        /// The hue actually painted: the literal override when set, else the
        /// semantic tint resolved against `theme`.
        func resolvedTintHex(in theme: HelmTheme) -> String { tintHex ?? tint.hex(in: theme) }
    }

    // MARK: Geometry - `NotificationRowView`'s, promoted

    private static let barWidth: CGFloat = 3
    private static let barRadius: CGFloat = 1.5
    /// The bar is inset from the card's top and bottom so it never clips past
    /// the card's own rounded corners at `HelmMetrics.rRow`.
    private static let barVerticalInset: CGFloat = 10
    private static let barLeadingInset: CGFloat = 2
    private static let contentLeading: CGFloat = 12
    private static let contentTrailing: CGFloat = 14
    private static let contentVertical: CGFloat = 12
    /// The vertical rhythm inside the body column - 4 in the notification
    /// panel and 3 in the two Shift lists as shipped, unified to 4.
    private static let bodySpacing: CGFloat = 4

    /// The card border is a wash of the row's own hue. It carries real load
    /// rather than decoration: it is the only thing separating a row from its
    /// container in the three themes where `chromeBackgroundHex ==
    /// backgroundHex`, exactly as for `HelmCard`.
    static let borderAlpha: CGFloat = 0.4

    /// How far a selected row's card fill is pulled toward the theme accent,
    /// and the alpha of its accent stroke. Both are `HelmTableRowView`'s own
    /// 0.24 / 0.65 recipe, softened a touch because a card already has a fill
    /// and a border of its own to sit under - see `isRowSelected`.
    static let selectionWash: CGFloat = 0.20
    static let selectionBorderAlpha: CGFloat = 0.85

    // MARK: Views

    private let card = HoverHighlightView()
    private let accentBar = NSView()
    private let badge: IconTileView?
    private let leadingControl: NSView?
    private let kickerLabel = NSTextField(labelWithString: "")
    private let titleLabel = NSTextField(labelWithString: "")
    private let titleAccessory = NSImageView()
    private let metaLabel = NSTextField(labelWithString: "")
    private let customContent: NSView?
    private let chip = NSView()
    private let chipLabel = NSTextField(labelWithString: "")

    private let trailingAccessory: NSView?

    private let chipPlacement: ChipPlacement
    private let hoverEnabled: Bool
    private var content: Content?
    /// The theme the row was last painted with, so `isRowSelected` can repaint
    /// without the caller having to hand the theme back in.
    private var lastTheme: HelmTheme = ThemeManager.shared.theme

    /// Whether this row is the selected one in its list.
    ///
    /// Selection lives on the card because the card is opaque: a wash painted
    /// *behind* it by an `NSTableRowView` (which is how the Hosts / Keys /
    /// Snippets lists rendered selection before Phase 5) is simply invisible
    /// once the row is a card. The recipe is the one that row view used -
    /// a wash of the theme's own accent plus a stronger accent stroke -
    /// relocated onto the thing that is actually on top. Never the *system*
    /// accent, which is the whole point of audit §5.2.
    var isRowSelected: Bool = false {
        didSet { if isRowSelected != oldValue { applyTheme(lastTheme) } }
    }

    /// Set to make the whole row clickable. Left nil for a row whose
    /// interaction lives elsewhere (a table's own double-click, a nested
    /// control) - which is also why `hover` is a separate argument: a hover
    /// highlight on a row that does nothing is a lie.
    var onClick: (() -> Void)?

    /// - Parameters:
    ///   - chipPlacement: see `ChipPlacement`.
    ///   - leadingControl: a caller-owned control in the badge's place -
    ///     Shift's task rows put their completion checkbox here. When set,
    ///     `Content.badgeSymbol` is ignored.
    ///   - contentView: a caller-owned body in place of the title/meta labels
    ///     - SRE Lead's rendered-markdown block stack. The kicker, bar, badge
    ///     and card still come from this row.
    ///   - hover: whether the card highlights under the cursor.
    ///   - trailingAccessory: a caller-owned view at the row's trailing edge,
    ///     after the chip - the Hosts / Keys / Snippets lists put each row's
    ///     own action buttons here, which is what let Phase 5 delete the
    ///     three-button `.fillEqually` footer strip those lists used to pin to
    ///     the bottom of the page. Mirrors `leadingControl`: the row owns the
    ///     slot, the caller owns the control and its behaviour.
    init(chipPlacement: ChipPlacement = .trailing,
         leadingControl: NSView? = nil,
         contentView: NSView? = nil,
         trailingAccessory: NSView? = nil,
         hover: Bool = true) {
        self.chipPlacement = chipPlacement
        self.leadingControl = leadingControl
        self.customContent = contentView
        self.trailingAccessory = trailingAccessory
        self.hoverEnabled = hover
        self.badge = leadingControl == nil
            ? IconTileView(size: HelmMetrics.tileSmall, cornerRadius: HelmMetrics.tileSmall / 2)
            : nil
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        buildLayout()
        let click = NSClickGestureRecognizer(target: self, action: #selector(rowClicked))
        // The row has to stay composable inside a *selectable* table: with the
        // AppKit default (`true`) this recognizer delays - and can swallow -
        // the primary mouse-down, so an `NSTableView` never sees the click
        // that should have selected the row. `rowClicked` no-ops when no
        // `onClick` is set, so letting the event through costs nothing for a
        // row that is not itself clickable.
        click.delaysPrimaryMouseButtonEvents = false
        addGestureRecognizer(click)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    private func buildLayout() {
        card.cornerRadius = HelmMetrics.rRow
        card.translatesAutoresizingMaskIntoConstraints = false
        addSubview(card)

        accentBar.wantsLayer = true
        accentBar.layer?.cornerRadius = Self.barRadius
        accentBar.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(accentBar)

        kickerLabel.translatesAutoresizingMaskIntoConstraints = false
        kickerLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        titleLabel.font = HelmType.rowTitle()
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        titleAccessory.symbolConfiguration = .init(pointSize: 10, weight: .regular)
        titleAccessory.setContentHuggingPriority(.required, for: .horizontal)
        titleAccessory.setContentCompressionResistancePriority(.required, for: .horizontal)
        titleAccessory.isHidden = true

        metaLabel.font = HelmType.caption()
        metaLabel.lineBreakMode = .byTruncatingTail
        metaLabel.maximumNumberOfLines = 1
        metaLabel.translatesAutoresizingMaskIntoConstraints = false

        chip.setContentHuggingPriority(.required, for: .horizontal)
        chip.setContentCompressionResistancePriority(.required, for: .horizontal)

        let titleRow = NSStackView(views: [titleLabel, titleAccessory])
        titleRow.orientation = .horizontal
        titleRow.alignment = .centerY
        titleRow.spacing = HelmMetrics.s1
        titleRow.distribution = .fill
        // `setContentHuggingPriority`/`setContentCompressionResistancePriority`
        // are **no-ops on an NSStackView** - they constrain a view against its
        // intrinsic content size, and a stack has none. The stack-level
        // equivalents are `setHuggingPriority`/`setClippingResistancePriority`,
        // and using the wrong pair here is what let a long title push the
        // whole row wider than its card instead of truncating (caught in a
        // real render, and the same root cause as audit §5.4 - see
        // `ToolRowLayout.columnHugging`).
        titleRow.setHuggingPriority(.defaultLow, for: .horizontal)
        titleRow.setClippingResistancePriority(.defaultLow, for: .horizontal)

        // The body column. `customContent` replaces the title/meta pair but
        // never the kicker - that is what makes an SRE Lead finding and a
        // notification read as the same kind of object.
        var bodyViews: [NSView] = [kickerLabel]
        let bodyContent: NSView
        if let customContent {
            customContent.translatesAutoresizingMaskIntoConstraints = false
            bodyContent = customContent
            bodyViews.append(customContent)
        } else {
            bodyContent = metaLabel
            bodyViews.append(titleRow)
            bodyViews.append(metaLabel)
        }
        if chipPlacement == .belowBody { bodyViews.append(chip) }

        let textStack = NSStackView(views: bodyViews)
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = Self.bodySpacing
        if chipPlacement == .belowBody { textStack.setCustomSpacing(6, after: bodyContent) }
        textStack.translatesAutoresizingMaskIntoConstraints = false
        // Stack-level priorities, not content-level - see `titleRow` above.
        textStack.setHuggingPriority(.defaultLow, for: .horizontal)
        textStack.setClippingResistancePriority(.defaultLow, for: .horizontal)

        var rowViews: [NSView] = []
        if let leading = leadingControl ?? badge {
            leading.setContentHuggingPriority(.required, for: .horizontal)
            leading.setContentCompressionResistancePriority(.required, for: .horizontal)
            rowViews.append(leading)
        }
        rowViews.append(textStack)
        if chipPlacement == .trailing { rowViews.append(chip) }
        if let trailingAccessory {
            trailingAccessory.translatesAutoresizingMaskIntoConstraints = false
            trailingAccessory.setContentHuggingPriority(.required, for: .horizontal)
            trailingAccessory.setContentCompressionResistancePriority(.required, for: .horizontal)
            // AGENTS.md gotcha (12): the two calls above are **no-ops** when
            // the accessory is itself an `NSStackView`, because both constrain
            // a view against its *intrinsic content size* and a stack has
            // none. Without the stack-level pair the accessory - not the text
            // column - is what `.fill` picks to absorb the row's slack, which
            // is how a 90pt "Connect" button rendered ~900pt wide in the first
            // Phase 5 render of this page.
            if let stack = trailingAccessory as? NSStackView {
                stack.setHuggingPriority(.required, for: .horizontal)
                stack.setClippingResistancePriority(.required, for: .horizontal)
            }
            rowViews.append(trailingAccessory)
        }

        let row = NSStackView(views: rowViews)
        row.orientation = .horizontal
        // A `.belowBody` row's badge sits beside the *first* line rather than
        // the middle of a wrapping paragraph.
        row.alignment = chipPlacement == .belowBody ? .top : .centerY
        row.spacing = 10
        // AGENTS.md gotcha #10: the default `.gravityAreas` distribution
        // honours no hugging priority, so the chip would drift with the
        // title's length instead of sitting at the row's trailing edge.
        row.distribution = .fill
        row.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(row)

        NSLayoutConstraint.activate([
            card.leadingAnchor.constraint(equalTo: leadingAnchor),
            card.trailingAnchor.constraint(equalTo: trailingAnchor),
            card.topAnchor.constraint(equalTo: topAnchor),
            card.bottomAnchor.constraint(equalTo: bottomAnchor),

            accentBar.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: Self.barLeadingInset),
            accentBar.widthAnchor.constraint(equalToConstant: Self.barWidth),
            accentBar.topAnchor.constraint(equalTo: card.topAnchor, constant: Self.barVerticalInset),
            accentBar.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -Self.barVerticalInset),

            row.leadingAnchor.constraint(equalTo: accentBar.trailingAnchor, constant: Self.contentLeading),
            row.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -Self.contentTrailing),
            row.topAnchor.constraint(equalTo: card.topAnchor, constant: Self.contentVertical),
            row.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -Self.contentVertical),
        ])

        if let customContent {
            // A caller-owned body has to be told it may use the whole column,
            // or a wrapping label inside it collapses to a few characters per
            // line - `ShiftEmptyStateView`'s documented trap.
            customContent.widthAnchor.constraint(equalTo: textStack.widthAnchor).isActive = true
        }
    }

    @objc private func rowClicked() { onClick?() }

    // MARK: Content

    func configure(_ content: Content, theme: HelmTheme) {
        self.content = content

        if let badge {
            badge.isHidden = content.badgeSymbol == nil
            if let symbol = content.badgeSymbol {
                badge.configure(symbol: symbol, tint: content.tint, pointSize: 11)
            }
        }

        titleLabel.stringValue = content.title
        titleLabel.maximumNumberOfLines = content.titleWraps ? 0 : 1
        titleLabel.lineBreakMode = content.titleWraps ? .byWordWrapping : .byTruncatingTail

        if let symbol = content.titleAccessorySymbol {
            titleAccessory.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            titleAccessory.isHidden = false
        } else {
            titleAccessory.isHidden = true
        }

        metaLabel.stringValue = content.meta ?? ""
        metaLabel.isHidden = (content.meta?.isEmpty ?? true)
        metaLabel.font = content.metaIsCode ? HelmType.code() : HelmType.caption()

        chip.isHidden = content.chipText == nil
        applyTheme(theme)
    }

    /// Re-resolves every colour against `theme`. Safe to call repeatedly: it
    /// re-reads the last `configure`d content rather than caching colours.
    func applyTheme(_ theme: HelmTheme) {
        lastTheme = theme
        guard let content else { return }
        let tintColor = HelmTheme.nsColor(content.resolvedTintHex(in: theme))

        badge?.applyTheme(theme)

        kickerLabel.attributedStringValue = NSAttributedString(
            string: content.kicker.uppercased(),
            // `mutedInk`, never the hue - see this class's doc comment.
            attributes: HelmType.kickerAttributes(color: HelmTheme.mutedInk(theme))
        )
        titleLabel.textColor = HelmTheme.nsColor(theme.chromeInkHex)
        metaLabel.textColor = HelmTheme.mutedInk(theme)
        titleAccessory.contentTintColor = HelmTheme.mutedInk(theme)

        if let chipText = content.chipText {
            let chipHex = content.chipTint.map { $0.hex(in: theme) } ?? content.resolvedTintHex(in: theme)
            ToolRowLayout.pill(text: chipText, colorHex: chipHex,
                               into: chip, label: chipLabel, theme: theme)
        }

        accentBar.layer?.backgroundColor = tintColor.cgColor

        let baseFill = HelmTheme.nsColor(theme.chromeBackgroundHex)
        if isRowSelected {
            // The pre-Phase-5 `HelmTableRowView` recipe, moved onto the card:
            // a wash of the theme's own accent under a stronger accent stroke.
            let accent = HelmTheme.nsColor(theme.accentHex)
            let fill = baseFill.blended(withFraction: Self.selectionWash, of: accent) ?? baseFill
            card.normalColor = fill
            card.hoverColor = fill
            card.layer?.borderWidth = 1
            card.layer?.borderColor = accent.withAlphaComponent(Self.selectionBorderAlpha).cgColor
        } else {
            card.normalColor = baseFill
            card.hoverColor = hoverEnabled
                ? (baseFill.blended(withFraction: 0.08, of: tintColor) ?? baseFill)
                : baseFill
            card.layer?.borderWidth = 1
            card.layer?.borderColor = tintColor.withAlphaComponent(Self.borderAlpha).cgColor
        }
    }

    // MARK: Probe / self-test surface

    /// Real, resolved geometry and colours for a live row, so a probe or a
    /// self-test can assert that every migrated call site renders the same
    /// recipe rather than eyeballing a screenshot.
    struct Geometry {
        let barFrame: NSRect
        let barColor: NSColor?
        let badgeFrame: NSRect?
        let kickerFont: NSFont?
        let kickerKern: CGFloat?
        let kickerColor: NSColor?
        let chipVisible: Bool
        let chipFrame: NSRect
        let cardRadius: CGFloat
        let cardBorderColor: NSColor?
        let cardFill: NSColor?
        let isRowSelected: Bool
        let trailingAccessoryFrame: NSRect?
    }

    func debugGeometry() -> Geometry {
        layoutSubtreeIfNeeded()
        let attrs = kickerLabel.attributedStringValue.length > 0
            ? kickerLabel.attributedStringValue.attributes(at: 0, effectiveRange: nil)
            : [:]
        return Geometry(
            barFrame: accentBar.convert(accentBar.bounds, to: self),
            barColor: accentBar.layer?.backgroundColor.map { NSColor(cgColor: $0) ?? .clear },
            badgeFrame: badge.map { $0.convert($0.bounds, to: self) },
            kickerFont: attrs[.font] as? NSFont,
            kickerKern: (attrs[.kern] as? NSNumber).map { CGFloat($0.doubleValue) },
            kickerColor: attrs[.foregroundColor] as? NSColor,
            chipVisible: !chip.isHidden,
            chipFrame: chip.convert(chip.bounds, to: self),
            cardRadius: card.layer?.cornerRadius ?? 0,
            cardBorderColor: card.layer?.borderColor.map { NSColor(cgColor: $0) ?? .clear },
            cardFill: card.normalColor,
            isRowSelected: isRowSelected,
            trailingAccessoryFrame: trailingAccessory.map { $0.convert($0.bounds, to: self) }
        )
    }
}

// MARK: - HelmStatTile

/// The app's one stat tile: a glyph, one big number, a caption underneath -
/// optionally tinted, optionally clickable.
///
/// **Why this exists.** The audit (§3.2 "Stat tile") measured three copies of
/// this shape, differing in every dimension that isn't the idea itself:
///
/// | Page | Value font | Padding | Fill | Height |
/// | --- | --- | --- | --- | --- |
/// | Overview | mono 15 semibold | 10 / 8 | `surface @ 1.00` | 50pt |
/// | Shift | `ShiftFont.mono(19, .semibold)` | 12 / 10 | `surface @ 1.00` | 56pt |
/// | Updates | mono 19 **bold** | 15 / 13 | `surface @ 0.60` | 67pt |
///
/// Shift turned out to have a **fourth** copy - `reviewStatTile`, byte-identical
/// to its own `statTile` and carrying a doc comment explaining that it existed
/// only because the two rows shared one theming array and "whichever rebuilds
/// last wins". A tile that themes itself removes the reason that copy existed.
///
/// **Nothing here is a new design.** The proportions are Shift's, which §6.3
/// named as the model (12/10 padding, 56pt, a 19pt metric); the click support
/// is Overview's (`FleetController`'s "ready to merge" tile jumps to `.review`);
/// the fill is `HelmCard.applyCardSurface`, which Phase 1 made public
/// specifically so tiles could stop being a fourth fill recipe.
///
/// **It themes itself** (like `HelmCard` and `HelmButton`): call `applyTheme`
/// from the page's `ThemeManager.shared.observe` closure. Do not add it to a
/// page-level `stashedTileParts`-style registry - those arrays are exactly
/// what forced Shift's duplicate.
final class HelmStatTile: NSView {
    /// Shift's proportions, which §6.3 picked as the model.
    static let height: CGFloat = 56
    private static let insetH: CGFloat = HelmMetrics.s3
    private static let insetV: CGFloat = 10
    /// The one metric size. Was 15 (Overview) / 19 (Shift) / 19 bold (Updates).
    private static let metricSize: CGFloat = 19
    /// The caption size. Was 9.5 (Overview, Shift) / 10.5 medium (Updates).
    private static let captionSize: CGFloat = 10.5

    private let iconView = NSImageView()
    private let valueLabel = NSTextField(labelWithString: "")
    private let captionLabel = NSTextField(labelWithString: "")

    /// Drives the metric's colour only. Left `nil` for the ordinary case (the
    /// number reads in ink); set where the number itself carries a signal -
    /// Shift's "overdue", Updates' "up to date" / "updates available".
    ///
    /// Contrast-corrected via `HelmContrast.legibleTintedText`, never painted
    /// as the raw hue: two of the three copies this replaced set the value
    /// label straight to `tint.hex(in: theme)`, which is the §5.7 "a hue is
    /// safe as a fill, not automatically as text" mistake. In `solarized-dark`
    /// the raw green measures 2.71:1 against this tile's own fill.
    private(set) var tint: HelmTint?

    /// Set to make the whole tile clickable. Nil leaves it a plain readout -
    /// and, as with `HelmAccentRow.hover`, that is also why there is no hover
    /// highlight on a tile that does nothing.
    var onClick: (() -> Void)?

    init(symbol: String, value: String = "", caption: String, tint: HelmTint? = nil) {
        self.tint = tint
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        iconView.image = NSImage(systemSymbolName: symbol, accessibilityDescription: caption)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 12, weight: .medium))
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.setContentHuggingPriority(.required, for: .horizontal)
        iconView.setContentCompressionResistancePriority(.required, for: .horizontal)

        valueLabel.stringValue = value
        valueLabel.font = HelmType.metric(Self.metricSize)
        valueLabel.lineBreakMode = .byTruncatingTail
        valueLabel.maximumNumberOfLines = 1
        valueLabel.translatesAutoresizingMaskIntoConstraints = false

        captionLabel.stringValue = caption
        captionLabel.font = .systemFont(ofSize: Self.captionSize, weight: .medium)
        captionLabel.lineBreakMode = .byTruncatingTail
        captionLabel.maximumNumberOfLines = 1
        captionLabel.translatesAutoresizingMaskIntoConstraints = false

        let topRow = NSStackView(views: [iconView, valueLabel])
        topRow.orientation = .horizontal
        topRow.spacing = 6
        topRow.alignment = .firstBaseline
        topRow.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [topRow, captionLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 3
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.insetH),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -Self.insetH),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: Self.insetV),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -Self.insetV),
            heightAnchor.constraint(equalToConstant: Self.height),
        ])

        addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(tileClicked)))
        applyTheme(ThemeManager.shared.theme)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    @objc private func tileClicked() { onClick?() }

    /// The number. Set as often as the data changes - the tile keeps its own
    /// font and colour, so a page only ever writes the string.
    var value: String {
        get { valueLabel.stringValue }
        set { valueLabel.stringValue = newValue }
    }

    var caption: String {
        get { captionLabel.stringValue }
        set { captionLabel.stringValue = newValue }
    }

    /// Re-tints the metric. For a tile whose signal changes with the data
    /// rather than being fixed at construction.
    func setTint(_ tint: HelmTint?, theme: HelmTheme) {
        self.tint = tint
        applyTheme(theme)
    }

    func applyTheme(_ theme: HelmTheme) {
        HelmCard.applyCardSurface(to: self, theme: theme, cornerRadius: HelmMetrics.rRow)
        let ink = HelmTheme.nsColor(theme.chromeInkHex)
        let surface = HelmTheme.nsColor(theme.chromeBackgroundHex)
        let metricColor = tint.map {
            HelmContrast.legibleTintedText(tintHex: $0.hex(in: theme), over: surface, theme: theme)
        } ?? ink
        valueLabel.textColor = metricColor
        // The glyph tracks the metric, so a tinted tile reads as one signal
        // rather than a coloured number beside an ink icon. `nonTextTarget`
        // (3:1) is the right bar for a glyph, not the text one - the same
        // split `IconTileView` already makes.
        iconView.contentTintColor = metricColor.withAlphaComponent(0.85)
        captionLabel.textColor = HelmTheme.mutedInk(theme)
    }

    // MARK: Probe / self-test surface

    struct Geometry {
        let tileFrame: NSRect
        let cornerRadius: CGFloat
        let fill: NSColor?
        let borderWidth: CGFloat
        let metricFont: NSFont?
        let metricColor: NSColor?
        let captionFont: NSFont?
        let captionColor: NSColor?
        let clickable: Bool
    }

    func debugGeometry() -> Geometry {
        layoutSubtreeIfNeeded()
        return Geometry(tileFrame: frame,
                        cornerRadius: layer?.cornerRadius ?? 0,
                        fill: layer?.backgroundColor.map { NSColor(cgColor: $0) ?? .clear },
                        borderWidth: layer?.borderWidth ?? 0,
                        metricFont: valueLabel.font,
                        metricColor: valueLabel.textColor,
                        captionFont: captionLabel.font,
                        captionColor: captionLabel.textColor,
                        clickable: onClick != nil)
    }
}

// MARK: - HelmEmptyState

/// The app's one "nothing here yet" placeholder: a glyph, an optional title,
/// body copy, and an optional action.
///
/// **Why this exists.** The audit (§3.2 "Empty state") found **six**
/// treatments for one job, including one that was left-aligned with no icon at
/// all (`ReviewController`) and four that were a bare `NSTextField` with no
/// container, no icon and no padding - which is what made Vault's empty panels
/// collapse to 0pt-tall header-only slabs (§5.5).
///
/// **Nothing here is a new design.** This is `ShiftEmptyStateView` - the one
/// §3.2 called "the good one", and the API every table-backed list in the app
/// already calls - widened with `DocsController`'s Playbook empty state
/// (§3.2's "most complete one": a 40pt glyph, a real title, and an action
/// button). `ShiftEmptyStateView` is **gone**: this is that class, renamed and
/// generalised, exactly as `ShiftPanelView` became `HelmCard` in Phase 1, so
/// there is one empty state rather than two under different names.
///
/// Two sizes, no other knobs:
/// - `.compact` - a 22pt glyph and body copy, for an empty list *inside* an
///   already-titled card. `ShiftEmptyStateView`'s exact proportions; a title
///   here would just restate the card header immediately above it.
/// - `.standard` - a 40pt glyph, a title, body copy, and room for an action.
///   `DocsController`'s proportions, for an empty state that is the whole page.
///
/// The `boxed` flag adds `HelmCard`'s own fill and border, for the two callers
/// (Overview, Review) whose empty state sits directly on the page background
/// with no card around it and needs a container of its own to read as an
/// object.
final class HelmEmptyState: NSView {
    enum Size {
        case compact
        case standard

        var glyphPointSize: CGFloat { self == .compact ? 22 : 40 }
        var glyphWeight: NSFont.Weight { self == .compact ? .regular : .light }
        var spacing: CGFloat { self == .compact ? HelmMetrics.s2 : 10 }
        /// A `.compact` state fills whatever cell it is handed and centres in
        /// it; a `.standard` one owns real vertical rhythm of its own.
        var verticalPadding: CGFloat { self == .compact ? HelmMetrics.s2 : 22 }
    }

    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let bodyLabel = NSTextField(labelWithString: "")
    private let stack: NSStackView
    private let size: Size
    private let boxed: Bool
    private let accessory: NSView?
    /// The glyph is fixed at `init` (only `setText` rewrites the words), so a
    /// reusing `NSTableView` cell needs this to know whether the instance it
    /// got back is showing the symbol it wants.
    let symbolName: String

    /// - Parameters:
    ///   - symbol: the SF Symbol. Confirm a symbol actually resolves before
    ///     shipping it - `NSImage(systemSymbolName:)` returns nil silently
    ///     (the "anchor" isn't-a-symbol bug Phase 0 fixed).
    ///   - title: `.standard`'s headline. Ignored (and hidden) when nil.
    ///   - body: the explanation. Always present - it is the one thing every
    ///     one of the six treatments this replaced actually had.
    ///   - boxed: wrap in `HelmCard`'s fill/border, for a state sitting
    ///     straight on the page background.
    ///   - accessory: a caller-owned action view under the body - Docs' "Sync
    ///     Now" `HelmButton` beside its progress spinner. Deliberately a view
    ///     slot rather than a `(title, closure)` pair: the app's one empty
    ///     state with an action already owns a button *and* a spinner it
    ///     enables/disables around its own async work, so a component-owned
    ///     button would have taken behaviour away rather than sharing it.
    init(symbol: String,
         title: String? = nil,
         body: String,
         size: Size = .compact,
         boxed: Bool = false,
         accessory: NSView? = nil) {
        self.size = size
        self.boxed = boxed
        self.accessory = accessory
        self.symbolName = symbol

        iconView.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title ?? body)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: size.glyphPointSize,
                                                                 weight: size.glyphWeight))
        iconView.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.font = size == .compact ? HelmType.rowTitle() : HelmType.sectionTitle()
        titleLabel.alignment = .center
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.stringValue = title ?? ""
        titleLabel.isHidden = (title?.isEmpty ?? true)

        bodyLabel.font = HelmType.caption()
        bodyLabel.alignment = .center
        bodyLabel.lineBreakMode = .byWordWrapping
        bodyLabel.maximumNumberOfLines = 0
        bodyLabel.stringValue = body
        bodyLabel.translatesAutoresizingMaskIntoConstraints = false

        var views: [NSView] = [iconView, titleLabel, bodyLabel]
        if let accessory {
            accessory.translatesAutoresizingMaskIntoConstraints = false
            views.append(accessory)
        }

        stack = NSStackView(views: views)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = size.spacing
        stack.translatesAutoresizingMaskIntoConstraints = false
        if accessory != nil { stack.setCustomSpacing(HelmMetrics.s4, after: bodyLabel) }
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            // Inequalities, not a width tie: this view is used both as a
            // reused `NSTableView` cell (whose height the table decides) and
            // as a page-filling container.
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: HelmMetrics.s3),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -HelmMetrics.s3),
            stack.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: size.verticalPadding),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -size.verticalPadding),
        ])
        applyTheme(ThemeManager.shared.theme)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    /// Rewrites the copy on an already-built instance - for a reused table
    /// cell, or a state whose text depends on live data.
    func setText(title: String? = nil, body: String) {
        titleLabel.stringValue = title ?? ""
        titleLabel.isHidden = (title?.isEmpty ?? true)
        bodyLabel.stringValue = body
        needsLayout = true
    }

    /// A wrapping `NSTextField` inside a centre-aligned stack whose own
    /// leading/trailing constraints are *inequalities* has no width Auto
    /// Layout is obliged to give it, so a long single-line string collapses to
    /// a few characters per line - "No saved secrets yet. Use ..." rendering
    /// as "No / sa". Inherited verbatim from `ShiftEmptyStateView`, where this
    /// was a real, fixed bug: every pre-existing caller happened to pass short
    /// or explicitly `\n`-broken copy, which hid it. Handing the label the real
    /// available width each pass is a no-op for text that already fits.
    override func layout() {
        super.layout()
        let cap: CGFloat = size == .compact ? .greatestFiniteMagnitude : 360
        let available = min(bounds.width - 2 * HelmMetrics.s3, cap)
        if available > 0, bodyLabel.preferredMaxLayoutWidth != available {
            bodyLabel.preferredMaxLayoutWidth = available
            bodyLabel.invalidateIntrinsicContentSize()
        }
    }

    func applyTheme(_ theme: HelmTheme) {
        let muted = HelmTheme.mutedInk(theme)
        iconView.contentTintColor = muted
        // A `.compact` state is one muted line under a card header, so its
        // title (when it has one) stays muted too; a `.standard` state is the
        // whole page, and its headline carries the weight.
        titleLabel.textColor = size == .compact ? muted : HelmTheme.nsColor(theme.chromeInkHex)
        bodyLabel.textColor = muted
        // A caller-owned accessory is a `HelmButton`/spinner the caller
        // already themes (a `HelmButton` themes itself), so nothing here
        // reaches into it.
        if boxed {
            HelmCard.applyCardSurface(to: self, theme: theme, cornerRadius: HelmMetrics.rRow)
        }
    }

    // MARK: Probe / self-test surface

    struct Geometry {
        let frame: NSRect
        let glyphFrame: NSRect
        let titleVisible: Bool
        let titleFont: NSFont?
        let bodyFont: NSFont?
        let bodyColor: NSColor?
        let bodyFrame: NSRect
        let hasAccessory: Bool
        let boxed: Bool
        let cornerRadius: CGFloat
    }

    func debugGeometry() -> Geometry {
        layoutSubtreeIfNeeded()
        return Geometry(frame: frame,
                        glyphFrame: iconView.convert(iconView.bounds, to: self),
                        titleVisible: !titleLabel.isHidden,
                        titleFont: titleLabel.font,
                        bodyFont: bodyLabel.font,
                        bodyColor: bodyLabel.textColor,
                        bodyFrame: bodyLabel.convert(bodyLabel.bounds, to: self),
                        hasAccessory: accessory != nil,
                        boxed: boxed,
                        cornerRadius: layer?.cornerRadius ?? 0)
    }
}

// MARK: - HelmSegmentedTabs

/// The app's one sub-navigation control: labelled pills inside a bordered
/// capsule, for switching between a fixed few views inside one destination.
///
/// **Why this exists.** The audit (§3.2 "Sub-navigation") found four
/// treatments, and the interesting part of the finding was that two of them -
/// Shift's segmented capsule and Docs' bare pills - were **already identical
/// code** for the pill itself (label 12pt medium, radius 7, insets 10/6,
/// `HoverHighlightView`, accent wash when active). Only the wrapper differed,
/// so one recipe rendered as two different-looking controls a rail click
/// apart. Updates' filter segments were a third near-copy at radius 6 in a
/// radius-8 container.
///
/// **Nothing here is a new design.** This is `ShiftController.buildTabRow`
/// (§6.3's named model) promoted: its pill, its capsule, its 3pt inset, its
/// accent-wash active state.
///
/// **`TabChipView` is deliberately not folded in.** Console's and Tools' tab
/// strips are closable, user-created, dynamic chips - "manage a set of tabs",
/// not "switch between a fixed few views". Per the audit's own framing those
/// are different concepts, and they stay separate.
///
/// **It themes itself**: call `applyTheme` from the page's
/// `ThemeManager.shared.observe` closure, and `select(_:)` when the active
/// view changes.
final class HelmSegmentedTabs: NSView {
    /// `.standard` is Shift's own geometry - a 12pt label at 10/6 insets.
    /// `.compact` is Updates' denser filter row, which sits in a toolbar
    /// beside a search field rather than under a page title.
    enum Size {
        case compact
        case standard

        var labelSize: CGFloat { self == .compact ? 11.5 : 12 }
        var pillInsetH: CGFloat { self == .compact ? HelmMetrics.s3 : 10 }
        var pillInsetV: CGFloat { self == .compact ? 5 : 6 }
        var capsuleInset: CGFloat { self == .compact ? 2 : 3 }
        var pillRadius: CGFloat { self == .compact ? HelmMetrics.rChip : 7 }
        var capsuleRadius: CGFloat { self == .compact ? HelmMetrics.rControl : 9 }
        var spacing: CGFloat { self == .compact ? 2 : 3 }
    }

    /// The capsule's own translucency - the value both implementations this
    /// replaced already used. Named because the active pill's label contrast has
    /// to be measured through it (see `applyTheme`).
    static let capsuleAlpha: CGFloat = 0.6

    /// One tab. `id` is the caller's own identifier for the view it switches
    /// to - a `DocsTab`, a filter mode, a top-level Shift view - so a page
    /// keeps its existing enum rather than being handed indices back.
    struct Item {
        let id: String
        let title: String
        init(id: String, title: String) {
            self.id = id
            self.title = title
        }
    }

    private struct Pill {
        let id: String
        let container: HoverHighlightView
        let label: NSTextField
    }

    private let capsule = NSView()
    private var pills: [Pill] = []
    private let size: Size
    private var selectedID: String

    /// Fires with the selected item's `id`. The component does **not** switch
    /// anything itself - the page's own existing switch logic stays where it
    /// is, exactly as before the migration.
    var onSelect: ((String) -> Void)?

    init(items: [Item], selected: String? = nil, size: Size = .standard) {
        self.size = size
        self.selectedID = selected ?? items.first?.id ?? ""
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        var pillViews: [NSView] = []
        for item in items {
            let container = HoverHighlightView()
            container.cornerRadius = size.pillRadius
            container.translatesAutoresizingMaskIntoConstraints = false
            container.identifier = NSUserInterfaceItemIdentifier(item.id)

            let label = NSTextField(labelWithString: item.title)
            label.font = .systemFont(ofSize: size.labelSize, weight: .medium)
            label.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(label)
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: size.pillInsetH),
                label.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -size.pillInsetH),
                label.topAnchor.constraint(equalTo: container.topAnchor, constant: size.pillInsetV),
                label.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -size.pillInsetV),
            ])
            container.addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(pillClicked(_:))))
            pills.append(Pill(id: item.id, container: container, label: label))
            pillViews.append(container)
        }

        let row = NSStackView(views: pillViews)
        row.orientation = .horizontal
        row.spacing = size.spacing
        row.translatesAutoresizingMaskIntoConstraints = false

        capsule.wantsLayer = true
        capsule.layer?.cornerRadius = size.capsuleRadius
        capsule.translatesAutoresizingMaskIntoConstraints = false
        capsule.addSubview(row)
        addSubview(capsule)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: capsule.leadingAnchor, constant: size.capsuleInset),
            row.trailingAnchor.constraint(equalTo: capsule.trailingAnchor, constant: -size.capsuleInset),
            row.topAnchor.constraint(equalTo: capsule.topAnchor, constant: size.capsuleInset),
            row.bottomAnchor.constraint(equalTo: capsule.bottomAnchor, constant: -size.capsuleInset),

            capsule.leadingAnchor.constraint(equalTo: leadingAnchor),
            capsule.trailingAnchor.constraint(equalTo: trailingAnchor),
            capsule.topAnchor.constraint(equalTo: topAnchor),
            capsule.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        // Nothing sets a hugging priority here on purpose: this view has no
        // intrinsic content size, so `setContentHuggingPriority` would be a
        // no-op (AGENTS.md gotcha (12)). The capsule stays at its pills' width
        // because the chain above - label insets -> pill -> row -> capsule ->
        // self - is all required equalities, so its width is already fully
        // determined. A caller that wants it to stretch has to say so with its
        // own constraint.
        applyTheme(ThemeManager.shared.theme)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    @objc private func pillClicked(_ sender: NSClickGestureRecognizer) {
        guard let id = sender.view?.identifier?.rawValue else { return }
        // Repaint immediately, then hand the id up: a page that re-themes on
        // switch would repaint anyway, but one that doesn't still gets the
        // right active pill.
        select(id)
        onSelect?(id)
    }

    /// Moves the active pill without firing `onSelect` - for a page whose
    /// view changed from somewhere else (a menu item, the search palette).
    func select(_ id: String) {
        selectedID = id
        applyTheme(ThemeManager.shared.theme)
    }

    var selected: String { selectedID }

    /// Rewrites one pill's label - for a tab carrying a live count.
    func setTitle(_ title: String, forID id: String) {
        pills.first { $0.id == id }?.label.stringValue = title
    }

    func applyTheme(_ theme: HelmTheme) {
        let line = HelmTheme.nsColor(theme.chromeLineHex)
        let surface = HelmTheme.nsColor(theme.chromeBackgroundHex)
        let accent = HelmTheme.nsColor(theme.accentHex)
        let muted = HelmTheme.mutedInk(theme)
        // The capsule is the *container*, one step back from a card: a
        // translucent surface with the same border alpha the two capsule
        // implementations this replaced already used.
        capsule.layer?.backgroundColor = surface.withAlphaComponent(Self.capsuleAlpha).cgColor
        capsule.layer?.borderWidth = 1
        capsule.layer?.borderColor = line.withAlphaComponent(0.5).cgColor

        let activeWash = accent.withAlphaComponent(theme.mode == .dark ? 0.20 : 0.14)
        // What the active pill's label *actually* lands on: the accent wash
        // composited over the capsule, which is itself translucent over
        // whichever surface the capsule was placed on. Both candidates are
        // scored, exactly as `HelmContrast.tintedSurface` does for a chip - a
        // capsule under a page title sits on `backgroundHex`, one in a toolbar
        // card on `chromeBackgroundHex`, and this control cannot know which.
        //
        // Composited with `HelmContrast.mix`, deliberately not
        // `NSColor.blended(withFraction:of:)`: `blended` converts both operands
        // into a common *calibrated* RGB space before mixing, so its result
        // drifts from the straight-sRGB composite that alpha blending actually
        // performs (and that `HelmContrast.ratio` then measures). The gap is
        // small but real - it left the active label reading 4.39 in
        // `gruvbox-light` while the correction believed it had cleared 4.5.
        let washAlpha = Double(activeWash.alphaComponent)
        let accentRGB = HelmContrast.components(accent)
        let surfaceRGB = HelmContrast.components(surface)
        let activeFills = [theme.chromeBackgroundHex, theme.backgroundHex].map { behindHex -> NSColor in
            let behind = HelmContrast.components(HelmTheme.nsColor(behindHex))
            let capsuleFill = HelmContrast.mix(surfaceRGB, behind, Double(Self.capsuleAlpha))
            return HelmContrast.color(HelmContrast.mix(accentRGB, capsuleFill, washAlpha))
        }
        // The accent as *text*: corrected, never the raw hue. Both copies this
        // replaced painted `label.textColor = accent` directly - the §5.7
        // mistake, and it measures below the floor in several palettes.
        let activeInk = HelmContrast.legibleTintedText(tintHex: theme.accentHex,
                                                      overAnyOf: activeFills, theme: theme)
        for pill in pills {
            let isActive = pill.id == selectedID
            pill.container.normalColor = isActive ? activeWash : .clear
            pill.container.hoverColor = isActive ? activeWash : line.withAlphaComponent(0.25)
            pill.label.textColor = isActive ? activeInk : muted
            pill.label.font = .systemFont(ofSize: size.labelSize, weight: isActive ? .semibold : .medium)
        }
    }

    // MARK: Probe / self-test surface

    struct Geometry {
        let capsuleRadius: CGFloat
        let capsuleBorderWidth: CGFloat
        let capsuleFill: NSColor?
        let pillCount: Int
        let pillRadii: [CGFloat]
        let activeID: String
        let activeFill: NSColor?
        let activeInk: NSColor?
        let inactiveInk: NSColor?
        let labelPointSizes: [CGFloat]
    }

    func debugGeometry() -> Geometry {
        layoutSubtreeIfNeeded()
        let active = pills.first { $0.id == selectedID }
        let inactive = pills.first { $0.id != selectedID }
        return Geometry(capsuleRadius: capsule.layer?.cornerRadius ?? 0,
                        capsuleBorderWidth: capsule.layer?.borderWidth ?? 0,
                        capsuleFill: capsule.layer?.backgroundColor.map { NSColor(cgColor: $0) ?? .clear },
                        pillCount: pills.count,
                        pillRadii: pills.map { $0.container.cornerRadius },
                        activeID: selectedID,
                        activeFill: active?.container.normalColor,
                        activeInk: active?.label.textColor,
                        inactiveInk: inactive?.label.textColor,
                        labelPointSizes: pills.compactMap { $0.label.font?.pointSize })
    }
}

// MARK: - HelmPageToolbar

/// The app's one **page toolbar**: the horizontal chrome strip a destination
/// puts directly under the app top bar, carrying that page's tab strip (or
/// sub-navigation) on the leading side and its actions on the trailing side.
///
/// Phase 7, audit §3.2's "Page toolbars" and §6.4's Console row. What was
/// wrong is worth stating precisely, because it is not "these bars looked
/// slightly different":
///
/// - **Two icon-button languages, 40pt apart.** The app top bar renders its
///   icons as bordered 34x34 squares (`TopBarController`: `isBordered = false`
///   + a `chromeBackgroundHex` layer fill + a 1pt `chromeLineHex` border).
///   Console's toolbar, one bar below it, rendered *six to eleven* bare
///   borderless glyphs at identical visual weight with no chrome at all - so
///   the same "icon button" idea read two completely different ways within
///   40 vertical points.
/// - **No shared slot, so three heights.** Console built its own 42pt bar,
///   Tools its own 42pt bar (copied from Console by hand - its own comment
///   said "mirrors ConsoleController.buildTabBar"), Docs its own 44pt bar,
///   and Docs then stacked a *second* 40pt bar inside its Playbook tab.
///   Nothing enforced any of those numbers matching.
///
/// This type is that missing slot. It owns the height, the fill, the bottom
/// hairline, the two content insets, and - via `iconButton(...)` - the one
/// toolbar-glyph recipe, so a page supplies only *what* goes in it.
///
/// **It themes itself**, like `HelmCard` and `HelmButton`: a page calls
/// `applyTheme(_:)` from its own `ThemeManager.observe` closure and nothing
/// else. `iconButton`'s buttons are `HelmButton`s, which already observe the
/// theme individually, so a page never re-tints a toolbar glyph either.
final class HelmPageToolbar: NSView {

    /// The one page-toolbar height. 44pt - Docs' own value, and the roomiest
    /// of the three, so nothing that fitted before stops fitting: it clears a
    /// 28pt `TabChipView` / `iconButton` with 8pt of breathing room above and
    /// below.
    static let height: CGFloat = 44

    /// The leading inset. `HelmMetrics.s3`, which is what all three bars
    /// already used for their tab strip.
    static let leadingInset: CGFloat = HelmMetrics.s3
    /// The trailing inset, slightly tighter than the leading one so a bordered
    /// icon square's own chrome doesn't read as floating away from the edge.
    static let trailingInset: CGFloat = 10

    /// The bordered icon square's side. Matches `TabChipView`'s own 28pt
    /// height so a toolbar reads as one row of controls on one baseline,
    /// rather than the top bar's 34pt (which would leave only 5pt of air in a
    /// 44pt bar, and would tower over the tab chips beside it). Same visual
    /// *language* as the top bar - bordered, filled, rounded square - at the
    /// density a page toolbar needs.
    static let iconButtonSide: CGFloat = 28

    /// The one toolbar-glyph recipe: a bordered icon square, in the app's own
    /// button component rather than a second hand-rolled chrome.
    ///
    /// `.secondary` is deliberate. It is `HelmButton`'s "bordered,
    /// theme-derived" variant - the one that replaced the stock bezel in Phase
    /// 2 - so a toolbar glyph is now painted by exactly the same code as every
    /// other bordered control in the app, and picks up its hover/press states
    /// for free. `.quiet` (borderless) is what the audit was complaining
    /// about, so it is specifically *not* the default here.
    ///
    /// A caller that needs a state colour (Console's record-red while logging,
    /// its accent while Block View is showing) sets `HelmButton.tint`, never
    /// `contentTintColor` - `HelmButton.restyle()` owns that property and will
    /// overwrite it on the next theme change.
    static func iconButton(symbol: String,
                           tooltip: String,
                           target: AnyObject?,
                           action: Selector?) -> HelmButton {
        let b = HelmButton(symbol: symbol, variant: .secondary, target: target, action: action)
        b.toolTip = tooltip
        b.translatesAutoresizingMaskIntoConstraints = false

        // **Auto Layout constrains an `NSButton`'s *alignment rect*, not its
        // frame** - and `NSButton.alignmentRectInsets` is not zero: measured
        // live, `(top: 3, left: 0, bottom: 2.5, right: 0)` at `.regular`
        // (2.5/2.5 at `.small`). AppKit reserves that vertical slack for the
        // focus ring a stock bezel would draw.
        //
        // A `HelmButton` draws its chrome in its own **layer**, which fills
        // the *frame* - so a plain `heightAnchor == 28` produces a 28pt
        // alignment rect and a visibly **33.5pt** bordered box: not a square,
        // and 5.5pt taller than the 28pt `TabChipView` beside it. Confirmed by
        // measuring the real button in a real window (28 -> 33.5, 34 -> 39.5,
        // i.e. a fixed +5.5 offset), which is also the mechanism behind
        // AGENTS.md's rail note that "every row resolves several points taller
        // than its explicit heightAnchor constant".
        //
        // So subtract the button's own insets - read from the button, never
        // hardcoded - and the frame lands on exactly `iconButtonSide` square.
        let insets = b.alignmentRectInsets
        NSLayoutConstraint.activate([
            b.widthAnchor.constraint(equalToConstant: iconButtonSide - insets.left - insets.right),
            b.heightAnchor.constraint(equalToConstant: iconButtonSide - insets.top - insets.bottom),
        ])
        return b
    }

    /// A toolbar control that names itself: the same bordered `.secondary`
    /// chrome as `iconButton`, with its glyph *and* a label.
    ///
    /// The audit prototype's Console toolbar reads "Find / Compose / Claude
    /// usage / SRE Lead" (`15-proposed-console-sre-lead.png`); as shipped
    /// those were four bare glyphs, indistinguishable from each other and from
    /// the zoom controls beside them unless the captain hovered for a tooltip.
    /// Phase 7 unified the toolbar's *chrome* and left every control an icon
    /// square, which is right for a pure utility (zoom in / zoom out) and
    /// wrong for a named feature.
    ///
    /// Height is compensated for the button's own `alignmentRectInsets`
    /// exactly as in `iconButton` - see that method for the measured reason -
    /// so a labelled control and an icon square sit on one baseline at the
    /// same visible height.
    static func labeledButton(symbol: String,
                              title: String,
                              tooltip: String,
                              target: AnyObject?,
                              action: Selector?) -> HelmButton {
        let b = HelmButton(title: title, variant: .secondary, size: .small,
                           symbol: symbol, target: target, action: action)
        b.toolTip = tooltip
        b.translatesAutoresizingMaskIntoConstraints = false
        b.setContentHuggingPriority(.required, for: .horizontal)
        b.setContentCompressionResistancePriority(.required, for: .horizontal)
        let insets = b.alignmentRectInsets
        b.heightAnchor.constraint(equalToConstant: iconButtonSide - insets.top - insets.bottom).isActive = true
        return b
    }

    /// A horizontal group of toolbar controls, spaced the one way.
    static func group(_ views: [NSView]) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = HelmMetrics.s1
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }

    private let separator = NSView()
    private var heightConstraint: NSLayoutConstraint!
    private var leadingContent: NSView?
    private var trailingContent: NSView?
    /// Activated once both slots are filled, so the leading content truncates
    /// rather than overrunning the actions (Console's tab strip does exactly
    /// this once enough tabs are open).
    private var clearanceConstraint: NSLayoutConstraint?

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true

        separator.wantsLayer = true
        separator.translatesAutoresizingMaskIntoConstraints = false
        addSubview(separator)

        heightConstraint = heightAnchor.constraint(equalToConstant: Self.height)
        NSLayoutConstraint.activate([
            heightConstraint,
            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            separator.bottomAnchor.constraint(equalTo: bottomAnchor),
            separator.heightAnchor.constraint(equalToConstant: 1),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    /// The leading slot - a page's tab strip or sub-navigation.
    func setLeading(_ content: NSView) {
        leadingContent?.removeFromSuperview()
        leadingContent = content
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.leadingInset),
            content.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        updateClearance()
    }

    /// The trailing slot - this page's actions.
    func setTrailing(_ content: NSView) {
        trailingContent?.removeFromSuperview()
        trailingContent = content
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.trailingInset),
            content.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        updateClearance()
    }

    private func updateClearance() {
        clearanceConstraint?.isActive = false
        guard let leadingContent, let trailingContent else { return }
        let c = leadingContent.trailingAnchor.constraint(lessThanOrEqualTo: trailingContent.leadingAnchor,
                                                         constant: -HelmMetrics.s2)
        c.isActive = true
        clearanceConstraint = c
    }

    /// Collapses the bar to nothing, for a page whose toolbar is meaningless
    /// in some state - Tools with no tool tab open, where the strip's only
    /// content was a "+" that opens the picker already filling the page
    /// (audit §4.8).
    ///
    /// Both halves are needed: `isHidden` alone leaves the 44pt reserved,
    /// because an ordinary hidden `NSView`'s constraints still participate
    /// fully in layout (AGENTS.md gotcha (11) - true for a plain view, false
    /// for a hidden *arranged subview* of an `NSStackView`). Owning the height
    /// constraint here rather than letting the page add its own also avoids
    /// two required height constraints fighting.
    func setCollapsed(_ collapsed: Bool) {
        isHidden = collapsed
        heightConstraint.constant = collapsed ? 0 : Self.height
    }

    func applyTheme(_ theme: HelmTheme) {
        layer?.backgroundColor = HelmTheme.nsColor(theme.chromeBackgroundHex).cgColor
        separator.layer?.backgroundColor = HelmTheme.nsColor(theme.chromeLineHex).cgColor
    }

    // MARK: Verification hooks

    /// The resolved chrome, for `HelmContrastSelfTest` and a render probe -
    /// asserted rather than re-derived, the same way `HelmButton.palette` and
    /// `HelmSegmentedTabs.debugGeometry` are.
    struct Geometry {
        let height: CGFloat
        let fill: NSColor?
        let separatorFill: NSColor?
        let leadingMinX: CGFloat
        let trailingMaxX: CGFloat
    }

    func debugGeometry() -> Geometry {
        layoutSubtreeIfNeeded()
        return Geometry(height: bounds.height,
                        fill: layer?.backgroundColor.map { NSColor(cgColor: $0) ?? .clear },
                        separatorFill: separator.layer?.backgroundColor.map { NSColor(cgColor: $0) ?? .clear },
                        leadingMinX: leadingContent?.frame.minX ?? -1,
                        trailingMaxX: trailingContent?.frame.maxX ?? -1)
    }
}

// MARK: - HelmResponsiveGrid

/// The app's one wrapping card-grid layout: column count derived from the
/// container's **real** width, and a partial last row padded with invisible
/// spacers so its cards stay the same width as every other row's.
///
/// Phase 7, audit §4.8 and §6.4's Settings row. This is not new code - it is
/// `ToolsController.rebuildGrid`'s math, which the audit called "the best card
/// grid in the app", lifted out of it so the two pages that had already
/// hand-copied it (`DocsController.layoutDocGrid`, whose own comment says it
/// is a port) and the one that had *not* (`SettingsController.
/// rebuildAppearanceGrid`, a fixed `columnsPerRow = 4` that left the audit's
/// ragged 4/2/4/2 last row and never responded to window width) all share one
/// definition.
///
/// Both halves matter, and both were bug fixes when they landed in Tools:
///
/// - **Columns from real width.** A fixed column count plus a fixed card width
///   hugs the leading edge on a wide window (measured live in
///   `fm/cockpit-tools-page-ui-polish`: ~700pt of a 1500pt container wasted).
/// - **Spacer padding.** `.fillEqually` divides a row's width by however many
///   arranged subviews it has, so a partial last row would stretch its lone
///   card across the whole row (`fm/cockpit-tools-page-partial-row-fix`).
///
/// A caller still owns its own card view; this only decides how many go in a
/// row and how wide each one is.
enum HelmResponsiveGrid {

    /// The one inter-card gap.
    static let spacing: CGFloat = 14

    /// The width to lay out against before the container has a real one -
    /// a first `rebuild` runs before the first layout pass, and a zero width
    /// would resolve to a single column.
    static let fallbackContainerWidth: CGFloat = 860

    /// How many `minItemWidth`-or-wider columns fit in `containerWidth`.
    /// Never fewer than one, however narrow the container gets.
    static func columns(containerWidth: CGFloat,
                        minItemWidth: CGFloat,
                        spacing: CGFloat = spacing) -> Int {
        let width = containerWidth > 0 ? containerWidth : fallbackContainerWidth
        return max(1, Int((width + spacing) / (minItemWidth + spacing)))
    }

    /// The width one card gets, once `columns` of them plus their gaps have to
    /// fill `containerWidth` exactly.
    static func itemWidth(containerWidth: CGFloat,
                          columns: Int,
                          spacing: CGFloat = spacing) -> CGFloat {
        let width = containerWidth > 0 ? containerWidth : fallbackContainerWidth
        return (width - spacing * CGFloat(max(0, columns - 1))) / CGFloat(max(1, columns))
    }

    /// Lays `items` out into `.fillEqually` rows: the whole grid in one call.
    ///
    /// `makeItem` is handed each item and the width its card should be built
    /// for (some cards need it up front - a wrapping label's
    /// `preferredMaxLayoutWidth`, for instance).
    static func rows<Item>(_ items: [Item],
                           containerWidth: CGFloat,
                           minItemWidth: CGFloat,
                           spacing: CGFloat = spacing,
                           makeItem: (Item, CGFloat) -> NSView) -> [NSStackView] {
        let columnsPerRow = columns(containerWidth: containerWidth,
                                    minItemWidth: minItemWidth,
                                    spacing: spacing)
        let width = itemWidth(containerWidth: containerWidth,
                              columns: columnsPerRow,
                              spacing: spacing)
        return items.chunked(into: columnsPerRow).map { chunk in
            var views: [NSView] = chunk.map { makeItem($0, width) }
            // The partial-last-row fix: pad to a fixed column count so
            // `.fillEqually` always divides by the same number.
            while views.count < columnsPerRow {
                let spacer = NSView()
                spacer.translatesAutoresizingMaskIntoConstraints = false
                views.append(spacer)
            }
            let row = NSStackView(views: views)
            row.orientation = .horizontal
            row.spacing = spacing
            row.distribution = .fillEqually
            row.translatesAutoresizingMaskIntoConstraints = false
            return row
        }
    }
}
