// Manjesh Grand Line - native macOS app.
//
// The `.docs` rail destination: an in-app, view-only panel for the captain's
// DevOps Playbook. The site (`https://manjesh-raj.github.io/devops-playbook/`)
// draws canvas diagrams, runs tab switchers/accordions, and tracks reading
// progress in local storage - faithfully showing that needs a real
// `WKWebView`, no way around it for this specific site. The captain does not
// want a live network dependency for it though, so this loads a bundled,
// synced-on-demand local copy (`DocsStore.folderURL`, kept fresh from the
// Updates page - see `DocsData.swift`) via a `file://` URL, never the network,
// and never lets in-page navigation leave that local folder.
//
// Root view follows this app's own documented gotcha #8 (`AGENTS.md`): a
// plain `NSView` with `wantsLayer`/`HelmTheme` background, not
// `NSVisualEffectView` vibrancy - reserved for a real split-view sidebar, not
// a full-size destination. Theme-awareness here is for this page's own
// chrome only (toolbar, empty state); the embedded site renders in its own
// light-only styling, which is expected.

import AppKit
import WebKit

final class DocsController: NSViewController {

    static let liveSiteURL = URL(string: "https://manjesh-raj.github.io/devops-playbook/")!

    private var webView: WKWebView!
    private let toolbar = NSView()
    private var backButton: NSButton!
    private var forwardButton: NSButton!
    private var reloadButton: NSButton!
    private let openLiveButton = NSButton()

    private let toolbarDivider = NSView()
    private let emptyStateContainer = NSView()
    private let emptyIcon = NSImageView()
    private let emptyTitleLabel = NSTextField(labelWithString: "Docs not synced yet")
    private let emptyBodyLabel = NSTextField(wrappingLabelWithString: "The DevOps Playbook hasn't been synced to this Mac yet. Sync it once to browse it here, fully offline afterward.")
    private let syncButton = NSButton()
    private let syncSpinner = NSProgressIndicator()
    private var isSyncing = false

    private var theme: HelmTheme = ThemeManager.shared.theme

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 720))
        root.wantsLayer = true
        view = root

        let config = WKWebViewConfiguration()
        webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = self
        webView.translatesAutoresizingMaskIntoConstraints = false

        buildToolbar()
        buildEmptyState()

        root.addSubview(toolbar)
        root.addSubview(webView)
        root.addSubview(emptyStateContainer)
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        emptyStateContainer.translatesAutoresizingMaskIntoConstraints = false

        toolbarDivider.wantsLayer = true
        toolbarDivider.translatesAutoresizingMaskIntoConstraints = false
        toolbar.addSubview(toolbarDivider)
        NSLayoutConstraint.activate([
            toolbarDivider.leadingAnchor.constraint(equalTo: toolbar.leadingAnchor),
            toolbarDivider.trailingAnchor.constraint(equalTo: toolbar.trailingAnchor),
            toolbarDivider.bottomAnchor.constraint(equalTo: toolbar.bottomAnchor),
            toolbarDivider.heightAnchor.constraint(equalToConstant: 1),
        ])

        NSLayoutConstraint.activate([
            toolbar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            toolbar.topAnchor.constraint(equalTo: root.topAnchor),
            toolbar.heightAnchor.constraint(equalToConstant: 40),

            webView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            webView.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            webView.bottomAnchor.constraint(equalTo: root.bottomAnchor),

            emptyStateContainer.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            emptyStateContainer.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            emptyStateContainer.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            emptyStateContainer.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])

        ThemeManager.shared.observe { [weak self, weak root] theme in
            root?.appearance = NSAppearance(named: theme.mode == .dark ? .darkAqua : .aqua)
            root?.layer?.backgroundColor = HelmTheme.nsColor(theme.backgroundHex).cgColor
            self?.theme = theme
            self?.applyTheme()
        }

        DocsSyncCenter.observe { [weak self] in
            guard let self, self.isViewLoaded else { return }
            self.loadDocsIfAvailable()
        }

        applyTheme()
        loadDocsIfAvailable()
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        updateNavButtons()
    }

    // MARK: Toolbar

    private func buildToolbar() {
        backButton = makeIconButton(symbol: "chevron.left", tooltip: "Back", action: #selector(backTapped))
        forwardButton = makeIconButton(symbol: "chevron.right", tooltip: "Forward", action: #selector(forwardTapped))
        reloadButton = makeIconButton(symbol: "arrow.clockwise", tooltip: "Reload (local copy only)", action: #selector(reloadTapped))
        let navTools = NSStackView(views: [backButton, forwardButton, reloadButton])
        navTools.orientation = .horizontal
        navTools.spacing = 2
        navTools.translatesAutoresizingMaskIntoConstraints = false

        let titleLabel = NSTextField(labelWithString: "DevOps Playbook")
        titleLabel.font = .systemFont(ofSize: 12.5, weight: .semibold)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        self.docsTitleLabel = titleLabel

        openLiveButton.title = "Open Live Site"
        openLiveButton.image = NSImage(systemSymbolName: "arrow.up.forward.square", accessibilityDescription: nil)
        openLiveButton.imagePosition = .imageLeading
        openLiveButton.bezelStyle = .rounded
        openLiveButton.controlSize = .small
        openLiveButton.target = self
        openLiveButton.action = #selector(openLiveTapped)
        openLiveButton.translatesAutoresizingMaskIntoConstraints = false

        toolbar.addSubview(navTools)
        toolbar.addSubview(titleLabel)
        toolbar.addSubview(openLiveButton)
        NSLayoutConstraint.activate([
            navTools.leadingAnchor.constraint(equalTo: toolbar.leadingAnchor, constant: 10),
            navTools.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),

            titleLabel.leadingAnchor.constraint(equalTo: navTools.trailingAnchor, constant: 12),
            titleLabel.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),

            openLiveButton.trailingAnchor.constraint(equalTo: toolbar.trailingAnchor, constant: -10),
            openLiveButton.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),
        ])
    }

    private var docsTitleLabel: NSTextField?

    private func makeIconButton(symbol: String, tooltip: String, action: Selector) -> NSButton {
        let b = NSButton(title: "", target: self, action: action)
        b.isBordered = false
        b.wantsLayer = true
        b.layer?.cornerRadius = 6
        b.toolTip = tooltip
        b.imageScaling = .scaleProportionallyDown
        b.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)
        NSLayoutConstraint.activate([
            b.widthAnchor.constraint(equalToConstant: 28),
            b.heightAnchor.constraint(equalToConstant: 26),
        ])
        return b
    }

    @objc private func backTapped() { webView.goBack() }
    @objc private func forwardTapped() { webView.goForward() }

    /// Reloads the *local* bundle only - never re-syncs from the network.
    /// Syncing is a distinct, explicit action (Updates page row, or the
    /// empty state's Sync button below).
    @objc private func reloadTapped() { loadDocsIfAvailable() }

    @objc private func openLiveTapped() {
        NSWorkspace.shared.open(Self.liveSiteURL)
    }

    private func updateNavButtons() {
        backButton.isEnabled = webView.canGoBack
        forwardButton.isEnabled = webView.canGoForward
    }

    // MARK: Empty state

    private func buildEmptyState() {
        emptyIcon.image = NSImage(systemSymbolName: "book.closed", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 34, weight: .light))
        emptyIcon.translatesAutoresizingMaskIntoConstraints = false

        emptyTitleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        emptyTitleLabel.alignment = .center
        emptyTitleLabel.translatesAutoresizingMaskIntoConstraints = false

        emptyBodyLabel.font = .systemFont(ofSize: 12)
        emptyBodyLabel.alignment = .center
        emptyBodyLabel.preferredMaxLayoutWidth = 360
        emptyBodyLabel.translatesAutoresizingMaskIntoConstraints = false

        syncButton.title = "Sync Now"
        syncButton.bezelStyle = .rounded
        syncButton.controlSize = .regular
        syncButton.target = self
        syncButton.action = #selector(syncNowTapped)
        syncButton.translatesAutoresizingMaskIntoConstraints = false

        syncSpinner.style = .spinning
        syncSpinner.controlSize = .small
        syncSpinner.isIndeterminate = true
        syncSpinner.isHidden = true
        syncSpinner.translatesAutoresizingMaskIntoConstraints = false

        let actionRow = NSStackView(views: [syncButton, syncSpinner])
        actionRow.orientation = .horizontal
        actionRow.spacing = 10
        actionRow.alignment = .centerY
        actionRow.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [emptyIcon, emptyTitleLabel, emptyBodyLabel, actionRow])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.setCustomSpacing(16, after: emptyBodyLabel)

        emptyStateContainer.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: emptyStateContainer.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: emptyStateContainer.centerYAnchor),
            stack.widthAnchor.constraint(lessThanOrEqualTo: emptyStateContainer.widthAnchor, constant: -80),
        ])
    }

    @objc private func syncNowTapped() {
        guard !isSyncing else { return }
        isSyncing = true
        syncButton.isEnabled = false
        syncSpinner.isHidden = false
        syncSpinner.startAnimation(nil)
        DispatchQueue.global(qos: .userInitiated).async {
            let outcome = DocsSyncSource.update()
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.isSyncing = false
                self.syncButton.isEnabled = true
                self.syncSpinner.isHidden = true
                self.syncSpinner.stopAnimation(nil)
                if outcome.ok {
                    self.loadDocsIfAvailable()
                } else if let container = self.view.window?.contentView {
                    Toast.show(in: container, message: "Docs sync failed: \(outcome.detail)")
                }
            }
        }
    }

    // MARK: Loading

    /// Shows the local copy if one exists, or the empty state if not - called
    /// on first load, on an explicit Reload, and whenever `DocsSyncCenter`
    /// reports a sync completed (from this page or the Updates page).
    private func loadDocsIfAvailable() {
        guard DocsStore.isSynced else {
            webView.isHidden = true
            emptyStateContainer.isHidden = false
            return
        }
        emptyStateContainer.isHidden = true
        webView.isHidden = false
        webView.loadFileURL(DocsStore.indexURL, allowingReadAccessTo: DocsStore.folderURL)
    }

    // MARK: Theme (chrome only - the embedded site keeps its own light-only styling)

    private func applyTheme() {
        let ink = HelmTheme.nsColor(theme.chromeInkHex)
        let muted = HelmTheme.mutedInk(theme)
        let surface = HelmTheme.nsColor(theme.chromeBackgroundHex)
        let line = HelmTheme.nsColor(theme.chromeLineHex)

        toolbar.wantsLayer = true
        toolbar.layer?.backgroundColor = surface.cgColor
        docsTitleLabel?.textColor = ink
        for b in [backButton, forwardButton, reloadButton] {
            b?.contentTintColor = ink.withAlphaComponent(0.75)
        }
        emptyIcon.contentTintColor = muted
        emptyTitleLabel.textColor = ink
        emptyBodyLabel.textColor = muted
        emptyStateContainer.wantsLayer = true
        emptyStateContainer.layer?.backgroundColor = HelmTheme.nsColor(theme.backgroundHex).cgColor
        toolbarDivider.layer?.backgroundColor = line.withAlphaComponent(0.5).cgColor
    }
}

extension DocsController: WKNavigationDelegate {
    /// Anything that stays inside the local synced-docs folder proceeds
    /// in-page; everything else (including the live site's own domain, if a
    /// link ever pointed there) is cancelled and opened in the system browser
    /// instead - this panel can never turn into a general browser.
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.allow)
            return
        }
        if url.isFileURL {
            let docsPath = DocsStore.folderURL.standardizedFileURL.path
            if url.standardizedFileURL.path.hasPrefix(docsPath) {
                decisionHandler(.allow)
                return
            }
        }
        decisionHandler(.cancel)
        NSWorkspace.shared.open(url)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        updateNavButtons()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        updateNavButtons()
    }
}
