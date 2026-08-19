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
