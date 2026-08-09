// Firstmate Cockpit - native macOS app.
//
// The `.bootstrap` rail destination (cockpit-bootstrap-scaffold, phase 1 of
// a larger, captain-reviewed plan). This PR is scaffold-only: the page holds
// a single "Firstmate home" card, laid out with the same card chrome
// `SettingsController` already established (icon + title header, rounded
// bordered background, `FlippedView` + scrollToTop for the same
// empty-gap-above-header fix that page and `FleetController`/
// `ReviewController` carry). Later phases (not this PR) add the
// dotfiles bootstrap/rebuild terminal wiring, the AGENTS.md/CLAUDE.md
// symlink checklist, the software-install checklist, and the Updates page
// behaviour split.
//
// The Firstmate-home card lets the captain see and override
// `FirstmateHome.root` - which is a `static let`, resolved once at process
// launch (see that file) - so a change here can only take effect after a
// restart. Save & Verify never live-repoints already-resolved paths; it
// persists the candidate to `AppSettings.fmHome` and asks for a restart.

import AppKit

final class BootstrapController: NSViewController {

    private var theme: HelmTheme = ThemeManager.shared.theme

    private let subtitleLabel = NSTextField(labelWithString: "Machine setup and environment bootstrap - stored locally on this machine.")

    private let currentPathLabel = NSTextField(labelWithString: "")
    private let pathField = NSTextField()
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let saveButton = NSButton()
    private let restartButton = NSButton()

    private var cardBackgroundViews: [NSView] = []
    private var scrollView: NSScrollView!

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 620, height: 720))
        root.wantsLayer = true
        view = root
        ThemeManager.shared.observe { [weak root, weak self] theme in
            root?.appearance = NSAppearance(named: theme.mode == .dark ? .darkAqua : .aqua)
            root?.layer?.backgroundColor = HelmTheme.nsColor(theme.backgroundHex).cgColor
            self?.theme = theme
            self?.applyTheme()
        }

        let header = buildHeader()
        let homeCard = card(icon: "folder", title: "Firstmate home", content: buildHomeSection())

        let stack = NSStackView(views: [header, homeCard])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.setCustomSpacing(16, after: header)

        let content = FlippedView()
        content.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 18),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
            header.widthAnchor.constraint(equalTo: stack.widthAnchor),
            homeCard.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])

        let scroll = NSScrollView()
        scroll.documentView = content
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: root.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            content.widthAnchor.constraint(equalTo: scroll.widthAnchor),
        ])
        scrollView = scroll

        refreshFromSettings()
        applyTheme()
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        refreshFromSettings()
        scrollToTop()
    }

    private func scrollToTop() {
        guard let scroll = scrollView else { return }
        scroll.contentView.scroll(to: .zero)
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    // MARK: Header

    private func buildHeader() -> NSView {
        subtitleLabel.font = .systemFont(ofSize: 12)
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        return subtitleLabel
    }

    // MARK: Card chrome (mirrors SettingsController.card)

    private func card(icon: String, title: String, content: NSView) -> NSView {
        let iconView = NSImageView()
        iconView.image = NSImage(systemSymbolName: icon, accessibilityDescription: title)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 14, weight: .semibold))
        iconView.translatesAutoresizingMaskIntoConstraints = false

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 14.5, weight: .semibold)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        let header = NSStackView(views: [iconView, titleLabel])
        header.orientation = .horizontal
        header.spacing = 8
        header.alignment = .firstBaseline
        header.translatesAutoresizingMaskIntoConstraints = false

        content.translatesAutoresizingMaskIntoConstraints = false

        let inner = NSStackView(views: [header, content])
        inner.orientation = .vertical
        inner.alignment = .leading
        inner.spacing = 12
        inner.translatesAutoresizingMaskIntoConstraints = false
        content.widthAnchor.constraint(equalTo: inner.widthAnchor).isActive = true

        let background = NSView()
        background.wantsLayer = true
        background.layer?.cornerRadius = 13
        background.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(inner)
        NSLayoutConstraint.activate([
            inner.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 16),
            inner.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -16),
            inner.topAnchor.constraint(equalTo: background.topAnchor, constant: 14),
            inner.bottomAnchor.constraint(equalTo: background.bottomAnchor, constant: -14),
        ])
        cardBackgroundViews.append(background)
        return background
    }

    // MARK: Firstmate home

    private func buildHomeSection() -> NSView {
        let currentLabel = NSTextField(labelWithString: "Currently active")
        currentLabel.font = .systemFont(ofSize: 12.5, weight: .medium)

        currentPathLabel.font = .monospacedSystemFont(ofSize: 11.5, weight: .regular)
        currentPathLabel.lineBreakMode = .byTruncatingMiddle

        let desc = NSTextField(wrappingLabelWithString: "The directory firstmate reads projects, backlog, and crew state from. Checked after the FM_HOME / FIRSTMATE_HOME environment variables. Changing it here requires a restart to take effect.")
        desc.font = .systemFont(ofSize: 11)
        desc.textColor = .secondaryLabelColor
        desc.preferredMaxLayoutWidth = 520

        pathField.placeholderString = "~/manjesh/firstmate"
        pathField.translatesAutoresizingMaskIntoConstraints = false

        let browseButton = NSButton(title: "Browse\u{2026}", target: self, action: #selector(browseClicked))
        browseButton.bezelStyle = .rounded

        let fieldRow = NSStackView(views: [pathField, browseButton])
        fieldRow.orientation = .horizontal
        fieldRow.spacing = 8
        pathField.setContentHuggingPriority(.defaultLow, for: .horizontal)

        saveButton.title = "Save & Verify"
        saveButton.bezelStyle = .rounded
        saveButton.target = self
        saveButton.action = #selector(saveClicked)

        restartButton.title = "Restart Firstmate Cockpit"
        restartButton.bezelStyle = .rounded
        restartButton.target = self
        restartButton.action = #selector(restartClicked)
        restartButton.isHidden = true

        let actionRow = NSStackView(views: [saveButton, restartButton])
        actionRow.orientation = .horizontal
        actionRow.spacing = 8

        statusLabel.font = .systemFont(ofSize: 11.5)
        statusLabel.preferredMaxLayoutWidth = 520
        statusLabel.isHidden = true

        let section = NSStackView(views: [currentLabel, currentPathLabel, desc, fieldRow, actionRow, statusLabel])
        section.orientation = .vertical
        section.alignment = .leading
        section.spacing = 8
        section.setCustomSpacing(2, after: currentLabel)
        section.setCustomSpacing(12, after: desc)
        fieldRow.widthAnchor.constraint(equalTo: section.widthAnchor).isActive = true
        return section
    }

    @objc private func browseClicked() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose the Firstmate home directory."
        let existing = pathField.stringValue.isEmpty ? FirstmateHome.root.path : pathField.stringValue
        panel.directoryURL = URL(fileURLWithPath: (existing as NSString).expandingTildeInPath)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        pathField.stringValue = url.path
    }

    @objc private func saveClicked() {
        let raw = pathField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else {
            showStatus("Enter a path before saving.", isError: true)
            return
        }
        let expanded = (raw as NSString).expandingTildeInPath
        let candidate = URL(fileURLWithPath: expanded).standardizedFileURL
        guard FirstmateHome.homeOk(at: candidate) else {
            showStatus("No bin/fm-crew-state.sh found under \(candidate.path) - not saved.", isError: true)
            restartButton.isHidden = true
            return
        }
        AppSettings.shared.fmHome = candidate.path
        pathField.stringValue = candidate.path
        showStatus("Saved. Restart Firstmate Cockpit for the new home to take effect.", isError: false)
        restartButton.isHidden = false
        Toast.show(in: view, message: "Firstmate home saved")
    }

    @objc private func restartClicked() {
        let url = Bundle.main.bundleURL
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: url, configuration: config, completionHandler: nil)
        NSApp.terminate(nil)
    }

    private func showStatus(_ message: String, isError: Bool) {
        statusLabel.stringValue = message
        statusLabel.textColor = isError ? HelmTheme.nsColor(theme.ansiHex[1]) : HelmTheme.nsColor(theme.ansiHex[2])
        statusLabel.isHidden = false
    }

    // MARK: Sync

    private func refreshFromSettings() {
        guard isViewLoaded else { return }
        currentPathLabel.stringValue = FirstmateHome.root.path
        if pathField.stringValue.isEmpty {
            pathField.stringValue = AppSettings.shared.fmHome ?? FirstmateHome.root.path
        }
    }

    private func applyTheme() {
        guard isViewLoaded else { return }
        let surface = HelmTheme.nsColor(theme.chromeBackgroundHex)
        let line = HelmTheme.nsColor(theme.chromeLineHex)
        subtitleLabel.textColor = HelmTheme.mutedInk(theme)
        currentPathLabel.textColor = HelmTheme.mutedInk(theme)
        for v in cardBackgroundViews {
            v.layer?.backgroundColor = surface.withAlphaComponent(0.6).cgColor
            v.layer?.borderWidth = 1
            v.layer?.borderColor = line.withAlphaComponent(0.5).cgColor
        }
    }
}
