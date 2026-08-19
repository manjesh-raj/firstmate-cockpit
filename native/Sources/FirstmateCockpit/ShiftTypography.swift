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

/// `ShiftPanelView` used to live here - the bordered/rounded header + divider
/// + body panel Shift, Vault and Dictation all shared. It is now `HelmCard`
/// in `HelmDesignSystem.swift`, where it is the app's single card container
/// rather than one of five (full-app UI audit §6.3 component 1). Nothing
/// about the look changed in that move.

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

    /// A wrapping `NSTextField` inside a centre-aligned stack whose own
    /// leading/trailing constraints are *inequalities* has no width Auto
    /// Layout is obliged to give it, so a long single-line string collapses
    /// to a few characters per line and then truncates at
    /// `maximumNumberOfLines` - "No saved secrets yet. Use ..." rendered as
    /// "No / sa". Every pre-existing caller happened to pass short or
    /// explicitly `\n`-broken copy, which hid it. Handing the label the real
    /// available width each layout pass is the standard fix, and is a no-op
    /// for text that already fits on one line.
    override func layout() {
        super.layout()
        let available = bounds.width - 24
        if available > 0, label.preferredMaxLayoutWidth != available {
            label.preferredMaxLayoutWidth = available
            label.invalidateIntrinsicContentSize()
        }
    }

    func applyTheme(_ theme: HelmTheme) {
        let muted = HelmTheme.mutedInk(theme)
        iconView.contentTintColor = muted
        label.textColor = muted
    }
}
