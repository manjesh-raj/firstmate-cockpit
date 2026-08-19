// Manjesh Grand Line - native macOS app.
//
// The top bar (nav-redesign task, item 4): always visible above the body
// content regardless of which rail destination is active, carrying the
// destination title plus - reproduced faithfully, not redesigned - the
// web app's Search pill (`#palette-open`, `.kbtn`) with its inline ⌘K badge,
// and its theme-picker button (`#theme-btn`/`.theme-menu`).
//
// Fix 4 originally mapped this pill onto an in-terminal find (there was no
// real global search yet); phase 4 ("Knowledge and speed") superseded that -
// it now opens the real unified search palette (Runbooks + Postmortems, see
// `UnifiedSearch.swift`) via `AppShellController.onSearchTapped`. Plain
// find-in-terminal is unaffected - still reachable via the console toolbar's
// own magnifying-glass icon and the Edit menu's `⌘F`.
//
// `fm/grandline-notification-center` adds the bell between `searchPill` and
// `themeButton` - the captain-approved design doc's own annotated
// screenshot places it exactly there. `notificationCenter` (`Notification
// CenterPopover.swift`) owns the badge count and the dropdown panel; this
// controller only positions the bell button itself and re-themes it.
//
// `fm/grandline-notification-bell-badge-fix-2` widened the bell's own width
// constraint from a fixed 34pt to `NotificationBellButton.controlWidth` -
// see that type's own doc comment for why the badge needs real, non-
// overlapping room to the icon's right rather than another overlap-amount
// tweak. The bell's leading/trailing anchor formulas below are otherwise
// untouched: `searchPill` still sits 10pt from the bell's leading edge
// (which is still the visible icon square's own leading edge, unchanged),
// and the bell's wider trailing edge still sits 10pt from `themeButton` -
// so `themeButton` never gets crowded, it's simply the reserved badge zone
// that now occupies what used to be dead space in that same gap.

import AppKit

final class TopBarController: NSViewController {

    static let height: CGFloat = 52

    var onSearchTapped: (() -> Void)?

    let notificationCenter = NotificationCenterController()

    private let titleLabel = NSTextField(labelWithString: "")
    private let searchPill = PillButton(icon: "magnifyingglass", text: "Search", badgeText: "⌘K")
    private let themeButton = NSButton()
    private let separator = NSView()

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: Self.height))
        root.wantsLayer = true
        view = root

        titleLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        searchPill.translatesAutoresizingMaskIntoConstraints = false
        searchPill.onClick = { [weak self] in self?.onSearchTapped?() }

        themeButton.title = ""
        themeButton.isBordered = false
        themeButton.wantsLayer = true
        themeButton.layer?.cornerRadius = 9
        themeButton.image = NSImage(systemSymbolName: "paintpalette", accessibilityDescription: "Theme")?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 14, weight: .regular))
        themeButton.target = self
        themeButton.action = #selector(themeClicked)
        themeButton.toolTip = "Theme"
        themeButton.translatesAutoresizingMaskIntoConstraints = false

        separator.wantsLayer = true
        separator.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(titleLabel)
        root.addSubview(searchPill)
        root.addSubview(notificationCenter.bell)
        root.addSubview(themeButton)
        root.addSubview(separator)

        NSLayoutConstraint.activate([
            separator.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            separator.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            separator.heightAnchor.constraint(equalToConstant: 1),

            titleLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 18),
            titleLabel.centerYAnchor.constraint(equalTo: root.centerYAnchor),

            themeButton.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14),
            themeButton.centerYAnchor.constraint(equalTo: root.centerYAnchor),
            themeButton.widthAnchor.constraint(equalToConstant: 34),
            themeButton.heightAnchor.constraint(equalToConstant: 34),

            notificationCenter.bell.trailingAnchor.constraint(equalTo: themeButton.leadingAnchor, constant: -10),
            notificationCenter.bell.centerYAnchor.constraint(equalTo: root.centerYAnchor),
            notificationCenter.bell.widthAnchor.constraint(equalToConstant: NotificationBellButton.controlWidth),
            notificationCenter.bell.heightAnchor.constraint(equalToConstant: 34),

            searchPill.trailingAnchor.constraint(equalTo: notificationCenter.bell.leadingAnchor, constant: -10),
            searchPill.centerYAnchor.constraint(equalTo: root.centerYAnchor),
        ])

        ThemeManager.shared.observe { [weak self] theme in self?.applyTheme(theme) }
    }

    func setTitle(_ text: String) {
        titleLabel.stringValue = text
    }

    @objc private func themeClicked() {
        let menu = ThemeMenu.build(target: self, action: #selector(themeItemSelected(_:)))
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: themeButton.bounds.height + 4), in: themeButton)
    }

    @objc private func themeItemSelected(_ sender: NSMenuItem) {
        ThemeMenu.apply(from: sender)
    }

    private func applyTheme(_ theme: HelmTheme) {
        let ink = HelmTheme.nsColor(theme.chromeInkHex)
        let line = HelmTheme.nsColor(theme.chromeLineHex)
        let surface = HelmTheme.nsColor(theme.chromeBackgroundHex)

        view.layer?.backgroundColor = HelmTheme.nsColor(theme.backgroundHex).cgColor
        separator.layer?.backgroundColor = line.cgColor
        titleLabel.textColor = ink

        themeButton.contentTintColor = ink.withAlphaComponent(0.75)
        themeButton.layer?.backgroundColor = surface.cgColor
        themeButton.layer?.borderWidth = 1
        themeButton.layer?.borderColor = line.withAlphaComponent(0.5).cgColor

        notificationCenter.bell.applyTheme(ink: ink, line: line, surface: surface)

        searchPill.applyTheme(faint: ink.withAlphaComponent(0.55), line: line, surface: surface)
    }
}

/// A small rounded pill button - icon, label, and an optional trailing
/// keyboard-shortcut badge - matching the web app's `.kbtn`/`.kbd` styling.
/// `NSButton` can't mix an image, a title, and a separately-styled badge in
/// one control, so this composes them from plain subviews with a click
/// gesture recognizer standing in for the button action.
final class PillButton: NSView {
    var onClick: (() -> Void)?

    private let iconView = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let badge = NSTextField(labelWithString: "")

    init(icon: String, text: String, badgeText: String?) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 9
        layer?.borderWidth = 1

        iconView.image = NSImage(systemSymbolName: icon, accessibilityDescription: text)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 13, weight: .regular))
        iconView.translatesAutoresizingMaskIntoConstraints = false

        label.stringValue = text
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.translatesAutoresizingMaskIntoConstraints = false

        var arranged: [NSView] = [iconView, label]
        if let badgeText {
            badge.stringValue = badgeText
            badge.font = .monospacedSystemFont(ofSize: 10, weight: .medium)
            badge.wantsLayer = true
            badge.layer?.cornerRadius = 4
            badge.layer?.borderWidth = 1
            badge.translatesAutoresizingMaskIntoConstraints = false
            arranged.append(badge)
        }

        let stack = NSStackView(views: arranged)
        stack.orientation = .horizontal
        stack.spacing = 7
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 11, bottom: 0, right: 11)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightAnchor.constraint(equalToConstant: 34),
        ])

        addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(clicked)))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func clicked() { onClick?() }

    func applyTheme(faint: NSColor, line: NSColor, surface: NSColor) {
        layer?.backgroundColor = surface.cgColor
        layer?.borderColor = line.cgColor
        iconView.contentTintColor = faint
        label.textColor = faint
        badge.textColor = faint
        badge.layer?.backgroundColor = surface.cgColor
        badge.layer?.borderColor = line.cgColor
    }
}
