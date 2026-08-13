// Manjesh Grand Line - native macOS app.
//
// Shift's own presentation layer (fm/cockpit-shift-ui-polish), matching the
// captain-approved mockup at
// data/cockpit-shift-ui-polish/reviewed-mockup-reference.html. This is
// deliberately the *only* new file this pass adds: everything else - dark
// palette, priority/status/sync tint colors, hover highlighting - already
// existed and was already wired into `ThemeManager`/`HelmTint`/
// `HoverHighlightView` before this pass (see ShiftController.swift's header
// for what the root-cause check actually found). The one thing genuinely
// missing was the mockup's three-typeface system - every Shift label used
// the app's default `.systemFont` sans face, with no serif/mono distinction
// anywhere - plus a shared bordered-panel container matching the mockup's
// `.panel`/`.panel-head`. Both are Shift-specific per the task brief ("extend
// the tokens where Shift needs something the rest of the app doesn't have
// yet"), not a second app-wide font/color system: every color here still
// flows through `HelmTheme`/`HelmTint` exactly like the rest of the app.

import AppKit

/// The mockup's three type roles: `--serif` for the greeting and panel
/// headings, `--mono` for kicker labels/counts/stat numbers/pill text,
/// `--sans` (the app's existing default, untouched) for everything else.
enum ShiftFont {
    static func serif(_ size: CGFloat) -> NSFont {
        NSFont(name: "Georgia", size: size) ?? .systemFont(ofSize: size)
    }

    static func mono(_ size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        .monospacedSystemFont(ofSize: size, weight: weight)
    }
}

/// A bordered, rounded panel wrapping a header row and body content with a
/// divider between them - the mockup's `.panel`/`.panel-head`. Reused by
/// every Shift section (Tasks, Follow-ups) instead of each hand-rolling its
/// own background/border, the same "one shared piece, every caller reuses
/// it" convention `ToolRowLayout`/`IconTileView` already established
/// elsewhere in this app.
final class ShiftPanelView: NSView {
    let headerContainer = NSView()
    private let divider = NSView()
    let bodyContainer = NSView()

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 12
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

    func setHeader(_ view: NSView, insets: NSEdgeInsets = NSEdgeInsets(top: 11, left: 14, bottom: 11, right: 12)) {
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

    func setBody(_ view: NSView) {
        bodyContainer.subviews.forEach { $0.removeFromSuperview() }
        view.translatesAutoresizingMaskIntoConstraints = false
        bodyContainer.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: bodyContainer.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: bodyContainer.trailingAnchor),
            view.topAnchor.constraint(equalTo: bodyContainer.topAnchor),
            view.bottomAnchor.constraint(equalTo: bodyContainer.bottomAnchor),
        ])
    }

    func applyTheme(_ theme: HelmTheme) {
        layer?.backgroundColor = HelmTheme.nsColor(theme.chromeBackgroundHex).cgColor
        layer?.borderWidth = 1
        layer?.borderColor = HelmTheme.nsColor(theme.chromeLineHex).withAlphaComponent(0.6).cgColor
        divider.layer?.backgroundColor = HelmTheme.nsColor(theme.chromeLineHex).withAlphaComponent(0.5).cgColor
    }
}

/// A centered "nothing here yet" placeholder - an icon over proportionate
/// copy, matching the rest of the mockup's considered-empty-state look
/// rather than a bare one-line sentence. Used by both table-based lists
/// (task/follow-up) and the projects grid.
final class ShiftEmptyStateView: NSView {
    private let iconView = NSImageView()
    private let label = NSTextField(labelWithString: "")

    init(symbol: String, text: String) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        iconView.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 22, weight: .regular))
        iconView.translatesAutoresizingMaskIntoConstraints = false

        label.stringValue = text
        label.font = .systemFont(ofSize: 11.5)
        label.alignment = .center
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 2

        let stack = NSStackView(views: [iconView, label])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    func applyTheme(_ theme: HelmTheme) {
        let muted = HelmTheme.mutedInk(theme)
        iconView.contentTintColor = muted
        label.textColor = muted
    }
}
