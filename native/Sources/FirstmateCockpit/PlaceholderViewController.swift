// Firstmate Cockpit - native macOS app.
//
// A "coming soon" destination for rail entries with no native content yet
// (Overview, Review - nav-redesign task, item 1). The confirmed design
// explicitly allows the Review/git-branch icon to be a placeholder "if
// there's nothing to show yet natively"; Overview gets the same treatment
// since there is no fleet/PR data source in the native app either. Both are
// real, clickable rail destinations - only their content is a stub.

import AppKit

final class PlaceholderViewController: NSViewController {

    private let symbol: String
    private let title_: String
    private let subtitle: String

    private let icon = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(wrappingLabelWithString: "")

    init(symbol: String, title: String, subtitle: String) {
        self.symbol = symbol
        self.title_ = title
        self.subtitle = subtitle
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        root.wantsLayer = true
        view = root

        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title_)
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 34, weight: .light)
        icon.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.stringValue = title_
        titleLabel.font = .systemFont(ofSize: 17, weight: .semibold)
        titleLabel.alignment = .center
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        subtitleLabel.stringValue = subtitle
        subtitleLabel.font = .systemFont(ofSize: 12)
        subtitleLabel.alignment = .center
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [icon, titleLabel, subtitleLabel])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: root.centerYAnchor),
            subtitleLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 340),
        ])

        ThemeManager.shared.observe { [weak self] theme in self?.applyTheme(theme) }
    }

    private func applyTheme(_ theme: HelmTheme) {
        view.layer?.backgroundColor = HelmTheme.nsColor(theme.backgroundHex).cgColor
        icon.contentTintColor = HelmTheme.nsColor(theme.chromeInkHex).withAlphaComponent(0.55)
        titleLabel.textColor = HelmTheme.nsColor(theme.chromeInkHex)
        subtitleLabel.textColor = HelmTheme.nsColor(theme.chromeInkHex).withAlphaComponent(0.6)
    }
}
