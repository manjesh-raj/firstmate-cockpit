// Manjesh Grand Line - native macOS app.
//
// The "Vault" rail destination (fm/grandline-vault-tab): an in-app window
// onto Automic Vault (https://github.com/automic-vault/automic-vault), not a
// second secrets manager. Automic Vault stores secrets in the macOS Keychain
// and gates their release per tool/launcher; it has no embeddable framework
// or XPC interface, so - exactly like every other external system this app
// already embeds (firstmate's own state files, herdr, Homebrew) - this page
// only ever shells out to Automic Vault's real `av` CLI (`VaultData.swift`)
// and renders what it says. Grand Line never reads the Keychain directly and
// never stores, caches, or logs a secret value:
//
//   - Listing secrets/tools (`av list`, `av doctor --json`) only ever returns
//     names and metadata, so those run as an ordinary background `Process`
//     exactly like `UpdatesController`'s checks do.
//   - Saving a new secret (`av save NAME`) reads the value from the real
//     terminal's own `/dev/tty` - confirmed live that piping a value in via
//     stdin fails outright ("failed to open /dev/tty") - so it can only ever
//     run inside a real interactive terminal. This page never even
//     constructs the value; only the NAME crosses into a shell command
//     string, and that command runs in a real Console tab
//     (`AppShellController.runInConsole`, the exact mechanism every other
//     sudo/interactive action in this app already uses - see Bootstrap's
//     `onRunCommand`/Settings' Touch ID row).
//   - Triggering an injected run (`av inject +NAME -- cmd`) is confirmed
//     live to work fine as a background process with no controlling
//     terminal (Automic Vault's own approval prompt, when one fires, is
//     handled by its separate menu-bar app, not `/dev/tty`) - but this page
//     still routes it through the same Console tab mechanism rather than
//     capturing the command's output itself, since the command is
//     caller-authored free text and may print anything; Grand Line must
//     never be the thing that captures or logs a command's real output.
//
// Install/update reuses `UpdatesSource.check`/`.update` on the existing
// `DependencyCatalog` "automic-vault" entry (`VaultSource.checkInstall`/
// `.updateInstall`) - the same brew-cask mechanic the Updates and Bootstrap
// pages already run for this tool, never a second implementation, per the
// task's explicit instruction to reuse it.
//
// Per PRODUCT.md: quiet until it matters - no polling, no fake liveness.
// Refresh happens on `viewWillAppear` and the header's manual Refresh
// button only (mirrors `ReviewController`). The one thing this page draws
// attention to unprompted is a tool `av doctor --json` itself reports has
// real issues; with nothing outstanding, the page stays as quiet as any
// other destination. Every status is a text label, never color alone
// (PRODUCT.md's accessibility principle).

import AppKit

final class VaultController: NSViewController {

    /// Bootstrap/Settings' exact shape: a command that needs a real
    /// interactive terminal runs in the shared Console via
    /// `AppShellController.runInConsole`, never a background process this
    /// page captures output from itself.
    var onRunCommand: ((String, String) -> Void)?
    /// Same as above, but the caller learns when the command finished -
    /// used after "Save secret" so the secrets list can refresh once the
    /// captain's real `av save` in the Console tab actually completes.
    var onRunCommandTracked: ((String, String, @escaping (Bool) -> Void) -> Void)?

    private let scroll = NSScrollView()
    private let contentStack = NSStackView()

    private let subtitleLabel = NSTextField(labelWithString: "")
    private let refreshButton = NSButton()

    // Install status (always visible - reuses the same DependencyCatalog item
    // the Updates/Bootstrap pages already check/update).
    private let installViews = ToolRowLayout.Views(
        iconTile: IconTileView(), nameLabel: NSTextField(labelWithString: ""),
        detailLabel: NSTextField(labelWithString: ""), pill: NSView(),
        pillLabel: NSTextField(labelWithString: ""), trailingStack: NSStackView(),
        detailsButton: NSButton(), logField: NSTextField(wrappingLabelWithString: ""),
        logContainer: NSView(), rowContainer: HoverHighlightView()
    )
    private let installCheckButton = NSButton()
    private let installUpdateButton = NSButton()
    private let installSpinner = NSProgressIndicator()
    private var installStatus: DependencyStatus = .unknown
    private var installDetail = "Not checked yet."
    private var installLog = ""
    private var isInstallLogExpanded = false
    private var isInstallBusy = false

    // Quiet-until-it-matters attention banner - hidden unless a real tool has
    // real issues (`av doctor --json`), never a manufactured warning.
    private let attentionBanner = NSView()
    private let attentionLabel = NSTextField(wrappingLabelWithString: "")
    private let attentionIcon = NSImageView()

    private let secretsPanel = ShiftPanelView()
    private let secretsStack = NSStackView()
    private let secretsCountBadge = NSTextField(labelWithString: "0")
    private let addSecretButton = NSButton()

    private let toolsPanel = ShiftPanelView()
    private let toolsStack = NSStackView()
    private let toolsCountBadge = NSTextField(labelWithString: "0")

    // "Backup the recipe, not the values" (fm/grandline-vault-recipe-backup) -
    // see VaultRecipe.swift/VaultRecipeGit.swift for what's recorded and why.
    private let recipePanel = ShiftPanelView()
    private let recipeDetailLabel = NSTextField(wrappingLabelWithString: "")
    private let exportRecipeButton = NSButton()
    private let checkBackupButton = NSButton()
    private let recipeSpinner = NSProgressIndicator()
    private var isRecipeBusy = false

    private var secrets: [VaultSecret] = []
    private var tools: [VaultTool] = []
    private var isLoadingSnapshot = false
    private var hasLoadedOnce = false
    private var theme: HelmTheme = ThemeManager.shared.theme

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 940, height: 720))
        root.wantsLayer = true
        view = root

        // FlippedView - see ReviewController.loadView's identical comment for
        // why a plain NSView here would leave a blank gap above the header
        // until the first real render lands.
        let content = FlippedView()
        content.translatesAutoresizingMaskIntoConstraints = false

        let header = buildHeader()
        let installSection = buildInstallSection()
        _ = buildSecretsSection()
        _ = buildToolsSection()
        _ = buildRecipeSection()

        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = 20
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        contentStack.addArrangedSubview(header)
        contentStack.addArrangedSubview(installSection)
        contentStack.addArrangedSubview(attentionBanner)
        contentStack.addArrangedSubview(secretsPanel)
        contentStack.addArrangedSubview(toolsPanel)
        contentStack.addArrangedSubview(recipePanel)
        attentionBanner.isHidden = true

        content.addSubview(contentStack)
        NSLayoutConstraint.activate([
            contentStack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 28),
            contentStack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -28),
            contentStack.topAnchor.constraint(equalTo: content.topAnchor, constant: 24),
            contentStack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -28),
            installSection.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
            attentionBanner.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
            secretsPanel.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
            toolsPanel.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
            recipePanel.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
        ])

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
            content.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
        ])

        ThemeManager.shared.observe { [weak self, weak root] theme in
            self?.theme = theme
            root?.appearance = NSAppearance(named: theme.mode == .dark ? .darkAqua : .aqua)
            self?.applyTheme()
            if self?.hasLoadedOnce == true { self?.renderAll() }
        }
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        view.layoutSubtreeIfNeeded()
        scrollToTop()
        refresh()
    }

    private func scrollToTop() {
        scroll.contentView.scroll(to: .zero)
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    // MARK: Building the static chrome

    private func buildHeader() -> NSView {
        subtitleLabel.font = .systemFont(ofSize: 12)
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false

        refreshButton.title = ""
        refreshButton.isBordered = false
        refreshButton.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "Refresh")
        refreshButton.target = self
        refreshButton.action = #selector(refreshTapped)
        refreshButton.toolTip = "Refresh Vault status"
        refreshButton.translatesAutoresizingMaskIntoConstraints = false

        // No in-page "Vault" title - the top bar already shows the
        // destination name (see TopBarController), matching Tools/
        // Updates/Bootstrap/Settings/Overview, which likewise show only a
        // subtitle here rather than repeating the destination name.
        let row = NSStackView(views: [subtitleLabel, refreshButton])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 12
        row.translatesAutoresizingMaskIntoConstraints = false
        return row
    }

    private func buildInstallSection() -> NSView {
        installCheckButton.title = "Check"
        installCheckButton.bezelStyle = .rounded
        installCheckButton.controlSize = .small
        installCheckButton.target = self
        installCheckButton.action = #selector(checkInstallTapped)

        installUpdateButton.title = "Install / Update"
        installUpdateButton.bezelStyle = .rounded
        installUpdateButton.controlSize = .small
        installUpdateButton.target = self
        installUpdateButton.action = #selector(updateInstallTapped)
        installUpdateButton.isHidden = true

        installSpinner.style = .spinning
        installSpinner.controlSize = .small
        installSpinner.isIndeterminate = true
        installSpinner.translatesAutoresizingMaskIntoConstraints = false
        installSpinner.isHidden = true

        let row = ToolRowLayout.build(
            installViews,
            iconSymbol: "lock.shield",
            tint: .violet,
            name: VaultSource.dependencyItem.name,
            trailingViews: [installViews.pill, installCheckButton, installUpdateButton, installSpinner],
            detailsTarget: self,
            detailsAction: #selector(installDetailsTapped),
            identifier: "vault-install"
        )
        return row
    }

    private func attentionBannerView() -> NSView {
        attentionLabel.font = .systemFont(ofSize: 12, weight: .medium)
        attentionLabel.translatesAutoresizingMaskIntoConstraints = false

        attentionIcon.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold))
        attentionIcon.translatesAutoresizingMaskIntoConstraints = false
        attentionIcon.setContentHuggingPriority(.required, for: .horizontal)

        let row = NSStackView(views: [attentionIcon, attentionLabel])
        row.orientation = .horizontal
        row.alignment = .firstBaseline
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false

        attentionBanner.wantsLayer = true
        attentionBanner.layer?.cornerRadius = 9
        attentionBanner.translatesAutoresizingMaskIntoConstraints = false
        attentionBanner.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: attentionBanner.leadingAnchor, constant: 12),
            row.trailingAnchor.constraint(equalTo: attentionBanner.trailingAnchor, constant: -12),
            row.topAnchor.constraint(equalTo: attentionBanner.topAnchor, constant: 10),
            row.bottomAnchor.constraint(equalTo: attentionBanner.bottomAnchor, constant: -10),
        ])
        return attentionBanner
    }

    private func buildSecretsSection() -> NSView {
        _ = attentionBannerView() // configures attentionBanner's fixed chrome once.

        addSecretButton.title = "+ Add Secret"
        addSecretButton.bezelStyle = .rounded
        addSecretButton.controlSize = .small
        addSecretButton.target = self
        addSecretButton.action = #selector(addSecretTapped)

        secretsCountBadge.font = .monospacedSystemFont(ofSize: 11, weight: .medium)

        let header = sectionHeaderRow(title: "Secrets", badge: secretsCountBadge, trailing: addSecretButton)
        secretsStack.orientation = .vertical
        secretsStack.alignment = .leading
        secretsStack.spacing = 8
        secretsStack.translatesAutoresizingMaskIntoConstraints = false

        secretsPanel.setHeader(header)
        secretsPanel.setBody(secretsStack)
        return secretsPanel
    }

    private func buildToolsSection() -> NSView {
        toolsCountBadge.font = .monospacedSystemFont(ofSize: 11, weight: .medium)
        let header = sectionHeaderRow(title: "Verified Launchers", badge: toolsCountBadge, trailing: nil)
        toolsStack.orientation = .vertical
        toolsStack.alignment = .leading
        toolsStack.spacing = 8
        toolsStack.translatesAutoresizingMaskIntoConstraints = false

        toolsPanel.setHeader(header)
        toolsPanel.setBody(toolsStack)
        return toolsPanel
    }

    private func buildRecipeSection() -> NSView {
        exportRecipeButton.title = "Export Recipe"
        exportRecipeButton.bezelStyle = .rounded
        exportRecipeButton.controlSize = .small
        exportRecipeButton.target = self
        exportRecipeButton.action = #selector(exportRecipeTapped)

        checkBackupButton.title = "Check Against Backup"
        checkBackupButton.bezelStyle = .rounded
        checkBackupButton.controlSize = .small
        checkBackupButton.target = self
        checkBackupButton.action = #selector(checkBackupTapped)

        recipeSpinner.style = .spinning
        recipeSpinner.controlSize = .small
        recipeSpinner.isIndeterminate = true
        recipeSpinner.translatesAutoresizingMaskIntoConstraints = false
        recipeSpinner.isHidden = true

        let buttonsRow = NSStackView(views: [checkBackupButton, exportRecipeButton, recipeSpinner])
        buttonsRow.orientation = .horizontal
        buttonsRow.spacing = 8
        buttonsRow.alignment = .centerY

        let titleLabel = NSTextField(labelWithString: "Recipe Backup")
        titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let header = NSStackView(views: [titleLabel, spacer, buttonsRow])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 8
        header.translatesAutoresizingMaskIntoConstraints = false

        recipeDetailLabel.font = .systemFont(ofSize: 11.5)
        recipeDetailLabel.preferredMaxLayoutWidth = 700
        recipeDetailLabel.stringValue = "Records which secrets and tools are hardened right now - names and launcher metadata only, never a secret value - so the same setup can be replayed as a checklist after a fresh machine or wipe."
        recipeDetailLabel.textColor = HelmTheme.mutedInk(theme)
        recipeDetailLabel.translatesAutoresizingMaskIntoConstraints = false

        recipePanel.setHeader(header)
        recipePanel.setBody(recipeDetailLabel)
        return recipePanel
    }

    private func sectionHeaderRow(title: String, badge: NSTextField, trailing: NSView?) -> NSView {
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        badge.translatesAutoresizingMaskIntoConstraints = false

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        var views: [NSView] = [titleLabel, badge, spacer]
        if let trailing { views.append(trailing) }
        let row = NSStackView(views: views)
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false
        return row
    }

    // MARK: Refresh

    @objc private func refreshTapped() { refresh() }

    private func refresh() {
        checkInstall { [weak self] in
            guard let self else { return }
            if self.installStatus == .notInstalled {
                self.secrets = []
                self.tools = []
                self.renderAll()
            } else {
                self.loadSnapshot()
            }
        }
    }

    // MARK: Install check / update

    @objc private func checkInstallTapped() { checkInstall() }

    private func checkInstall(completion: (() -> Void)? = nil) {
        guard !isInstallBusy else { completion?(); return }
        isInstallBusy = true
        installStatus = .checking
        installDetail = "Checking\u{2026}"
        installCheckButton.isEnabled = false
        installUpdateButton.isEnabled = false
        installSpinner.isHidden = false
        installSpinner.startAnimation(nil)
        renderInstall()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let outcome = VaultSource.checkInstall()
            DispatchQueue.main.async {
                guard let self else { completion?(); return }
                self.isInstallBusy = false
                self.installStatus = outcome.status
                self.installDetail = outcome.detail
                self.installLog = outcome.log
                self.installCheckButton.isEnabled = true
                self.installUpdateButton.isEnabled = true
                self.installSpinner.stopAnimation(nil)
                self.installSpinner.isHidden = true
                self.renderInstall()
                completion?()
            }
        }
    }

    @objc private func updateInstallTapped() {
        guard !isInstallBusy else { return }
        isInstallBusy = true
        installDetail = "Installing / updating\u{2026}"
        installCheckButton.isEnabled = false
        installUpdateButton.isEnabled = false
        installSpinner.isHidden = false
        installSpinner.startAnimation(nil)
        renderInstall()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let outcome = VaultSource.updateInstall()
            DispatchQueue.main.async {
                guard let self else { return }
                self.isInstallBusy = false
                self.installLog = outcome.log
                self.installCheckButton.isEnabled = true
                self.installUpdateButton.isEnabled = true
                self.installSpinner.stopAnimation(nil)
                self.installSpinner.isHidden = true
                if outcome.ok {
                    self.checkInstall { [weak self] in
                        guard let self else { return }
                        if self.installStatus != .notInstalled { self.loadSnapshot() }
                    }
                } else {
                    self.installDetail = outcome.detail
                    self.installStatus = .updateFailed
                    self.renderInstall()
                }
            }
        }
    }

    @objc private func installDetailsTapped() {
        isInstallLogExpanded.toggle()
        ToolRowLayout.setLogExpanded(installViews, expanded: isInstallLogExpanded, log: installLog)
    }

    // MARK: Snapshot (secrets + tools)

    private func loadSnapshot() {
        guard !isLoadingSnapshot else { return }
        isLoadingSnapshot = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let snapshot = VaultSource.loadSnapshot()
            DispatchQueue.main.async {
                guard let self else { return }
                self.isLoadingSnapshot = false
                self.secrets = snapshot.secrets
                self.tools = snapshot.tools
                self.renderAll()
            }
        }
    }

    // MARK: Rendering

    private func renderInstall() {
        let (pillText, pillColor) = installPillVisuals(installStatus)
        ToolRowLayout.pill(text: pillText, colorHex: pillColor, into: installViews.pill, label: installViews.pillLabel)
        installViews.detailLabel.stringValue = installDetail
        installUpdateButton.isHidden = !installStatus.showsUpdateButton
        let failed = installStatus == .checkFailed || installStatus == .updateFailed
        ToolRowLayout.applyTheme(installViews, theme: theme, detailFailed: failed)
        ToolRowLayout.setLogExpanded(installViews, expanded: isInstallLogExpanded, log: installLog)
    }

    private func installPillVisuals(_ status: DependencyStatus) -> (String, String) {
        switch status {
        case .unknown: return ("Not Checked", theme.chromeInkHex)
        case .checking, .updating: return ("", theme.chromeInkHex)
        case .upToDate: return ("Installed", theme.ansiHex[2])
        case .updateAvailable: return ("Update Available", theme.ansiHex[3])
        case .notInstalled: return ("Not Installed", theme.ansiHex[3])
        case .checkFailed: return ("Check Failed", theme.ansiHex[1])
        case .updateFailed: return ("Update Failed", theme.ansiHex[1])
        }
    }

    private func renderAll() {
        hasLoadedOnce = true
        renderInstall()

        let notInstalled = installStatus == .notInstalled
        secretsPanel.isHidden = notInstalled
        toolsPanel.isHidden = notInstalled

        let needingAttention = tools.filter { if case .needsAttention = $0.status { return true } else { return false } }
        attentionBanner.isHidden = notInstalled || needingAttention.isEmpty
        if !needingAttention.isEmpty {
            let names = needingAttention.map(\.name).joined(separator: ", ")
            attentionLabel.stringValue = needingAttention.count == 1
                ? "\(names) needs attention - see Verified Launchers below."
                : "\(needingAttention.count) tools need attention: \(names)."
        }

        secretsCountBadge.stringValue = "\(secrets.count)"
        rebuildSecretsStack()

        toolsCountBadge.stringValue = "\(tools.count)"
        rebuildToolsStack()

        applyTheme()
        view.layoutSubtreeIfNeeded()
        scrollToTop()
    }

    private func rebuildSecretsStack() {
        for v in secretsStack.arrangedSubviews {
            secretsStack.removeArrangedSubview(v)
            v.removeFromSuperview()
        }
        if secrets.isEmpty {
            secretsStack.addArrangedSubview(emptyStateRow("No saved secrets yet. Use \u{201c}Add Secret\u{201d} above - the value is entered directly in a real terminal, never through this app."))
            return
        }
        for secret in secrets {
            let row = secretRowView(secret)
            secretsStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: secretsStack.widthAnchor).isActive = true
        }
    }

    private func rebuildToolsStack() {
        for v in toolsStack.arrangedSubviews {
            toolsStack.removeArrangedSubview(v)
            v.removeFromSuperview()
        }
        if tools.isEmpty {
            toolsStack.addArrangedSubview(emptyStateRow("No verified launchers registered with Automic Vault yet."))
            return
        }
        for tool in tools {
            let row = toolRowView(tool)
            toolsStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: toolsStack.widthAnchor).isActive = true
        }
    }

    private func emptyStateRow(_ text: String) -> NSView {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 11.5)
        label.textColor = HelmTheme.mutedInk(theme)
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }

    private func secretRowView(_ secret: VaultSecret) -> NSView {
        let views = ToolRowLayout.Views(
            iconTile: IconTileView(), nameLabel: NSTextField(labelWithString: ""),
            detailLabel: NSTextField(labelWithString: ""), pill: NSView(),
            pillLabel: NSTextField(labelWithString: ""), trailingStack: NSStackView(),
            detailsButton: NSButton(), logField: NSTextField(wrappingLabelWithString: ""),
            logContainer: NSView(), rowContainer: HoverHighlightView()
        )
        ToolRowLayout.pill(text: "Hardened", colorHex: theme.ansiHex[2], into: views.pill, label: views.pillLabel)

        let runButton = NSButton(title: "Run injected\u{2026}", target: self, action: #selector(runInjectedTapped(_:)))
        runButton.bezelStyle = .rounded
        runButton.controlSize = .small
        runButton.identifier = NSUserInterfaceItemIdentifier("secret-run:\(secret.name)")

        // A real labeled button, styled identically to "Run injected..." -
        // sits right next to it so the row's two actions read as one group,
        // rather than the icon-only button PR #116 pinned to the row's far
        // trailing edge. Still only ever copies the NAME already shown in
        // this row; the secret's value never touches this app (see this
        // file's header comment).
        let copyButton = NSButton(title: "Copy Name", target: self, action: #selector(copyNameTapped(_:)))
        copyButton.bezelStyle = .rounded
        copyButton.controlSize = .small
        copyButton.toolTip = "Copy secret name to clipboard"
        copyButton.identifier = NSUserInterfaceItemIdentifier("secret-copy:\(secret.name)")

        let row = ToolRowLayout.build(
            views,
            iconSymbol: "key.fill",
            tint: .good,
            name: secret.name,
            trailingViews: [views.pill, runButton, copyButton],
            identifier: "secret:\(secret.name)",
            showDetails: false
        )
        views.detailLabel.stringValue = "Stored in Automic Vault's Keychain"
        row.identifier = NSUserInterfaceItemIdentifier("secret:\(secret.name)")
        ToolRowLayout.applyTheme(views, theme: theme, detailFailed: false)
        return row
    }

    private func toolRowView(_ tool: VaultTool) -> NSView {
        let views = ToolRowLayout.Views(
            iconTile: IconTileView(), nameLabel: NSTextField(labelWithString: ""),
            detailLabel: NSTextField(labelWithString: ""), pill: NSView(),
            pillLabel: NSTextField(labelWithString: ""), trailingStack: NSStackView(),
            detailsButton: NSButton(), logField: NSTextField(wrappingLabelWithString: ""),
            logContainer: NSView(), rowContainer: HoverHighlightView()
        )
        let isHardened: Bool
        switch tool.status {
        case .hardened: isHardened = true
        case .needsAttention: isHardened = false
        }
        ToolRowLayout.pill(
            text: tool.status.label,
            colorHex: isHardened ? theme.ansiHex[2] : theme.ansiHex[1],
            into: views.pill, label: views.pillLabel
        )

        let row = ToolRowLayout.build(
            views,
            iconSymbol: "checkmark.shield",
            tint: isHardened ? .good : .critical,
            name: tool.name,
            trailingViews: [views.pill],
            identifier: "tool:\(tool.name)",
            showDetails: false
        )
        views.detailLabel.stringValue = tool.commands.isEmpty ? " " : tool.commands.joined(separator: ", ")
        ToolRowLayout.applyTheme(views, theme: theme, detailFailed: !isHardened)
        return row
    }

    // MARK: Actions

    @objc private func addSecretTapped() {
        let sheet = VaultSaveSecretSheetController()
        sheet.onSave = { [weak self] name in
            guard let self, let command = VaultSource.saveSecretCommand(name: name) else { return }
            if let tracked = self.onRunCommandTracked {
                tracked("Save secret: \(name)", command) { [weak self] _ in
                    DispatchQueue.main.async { self?.loadSnapshot() }
                }
            } else {
                self.onRunCommand?("Save secret: \(name)", command)
            }
        }
        presentAsSheet(sheet)
    }

    @objc private func runInjectedTapped(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue, raw.hasPrefix("secret-run:") else { return }
        let name = String(raw.dropFirst("secret-run:".count))
        presentInjectSheet(preselected: name)
    }

    @objc private func copyNameTapped(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue, raw.hasPrefix("secret-copy:") else { return }
        let name = String(raw.dropFirst("secret-copy:".count))
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(name, forType: .string)
        Toast.show(in: view, message: "Copied \u{201c}\(name)\u{201d} to clipboard")
    }

    // MARK: Recipe backup (fm/grandline-vault-recipe-backup)

    @objc private func exportRecipeTapped() {
        guard !isRecipeBusy else { return }
        guard let repoPath = VaultRecipeGit.resolveRepoPath() else {
            recipeDetailLabel.stringValue = "No local manjesh-config clone found yet - set it up from Bootstrap's \u{201c}Dotfiles & machine config\u{201d} card first."
            recipeDetailLabel.textColor = HelmTheme.nsColor(theme.ansiHex[3])
            return
        }
        setRecipeBusy(true, status: "Exporting recipe\u{2026}")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let snapshot = VaultSource.loadSnapshot()
            let recipe = VaultRecipe.build(from: snapshot, generatedAt: ISO8601DateFormatter().string(from: Date()))
            let result = VaultRecipeGit.export(recipe: recipe, repoPath: repoPath)
            DispatchQueue.main.async {
                guard let self else { return }
                self.setRecipeBusy(false, status: result.message)
                self.recipeDetailLabel.textColor = result.ok ? HelmTheme.mutedInk(self.theme) : HelmTheme.nsColor(self.theme.ansiHex[1])
                if result.ok {
                    Toast.show(in: self.view, message: "Vault recipe exported")
                }
            }
        }
    }

    @objc private func checkBackupTapped() {
        guard !isRecipeBusy else { return }
        guard let repoPath = VaultRecipeGit.resolveRepoPath() else {
            recipeDetailLabel.stringValue = "No local manjesh-config clone found yet - set it up from Bootstrap's \u{201c}Dotfiles & machine config\u{201d} card first."
            recipeDetailLabel.textColor = HelmTheme.nsColor(theme.ansiHex[3])
            return
        }
        setRecipeBusy(true, status: "Checking against backup\u{2026}")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let recipe = VaultRecipeGit.loadExistingRecipe(repoPath: repoPath) else {
                DispatchQueue.main.async {
                    self?.setRecipeBusy(false, status: "No recipe backup found yet - use \u{201c}Export Recipe\u{201d} first.")
                }
                return
            }
            let snapshot = VaultSource.loadSnapshot()
            let items = VaultRecipeChecklist.build(recipe: recipe, currentSnapshot: snapshot)
            DispatchQueue.main.async {
                guard let self else { return }
                self.setRecipeBusy(false, status: "Compared against the backup from \(recipe.generatedAt).")
                let sheet = VaultRecipeChecklistSheetController(items: items, generatedAt: recipe.generatedAt)
                self.presentAsSheet(sheet)
            }
        }
    }

    private func setRecipeBusy(_ busy: Bool, status: String) {
        isRecipeBusy = busy
        exportRecipeButton.isEnabled = !busy
        checkBackupButton.isEnabled = !busy
        recipeSpinner.isHidden = !busy
        if busy { recipeSpinner.startAnimation(nil) } else { recipeSpinner.stopAnimation(nil) }
        recipeDetailLabel.stringValue = status
        recipeDetailLabel.textColor = HelmTheme.mutedInk(theme)
    }

    private func presentInjectSheet(preselected: String?) {
        let sheet = VaultInjectSheetController(secretNames: secrets.map(\.name), preselected: preselected)
        sheet.onRun = { [weak self] secretName, command in
            guard let self, let full = VaultSource.injectCommand(secretName: secretName, command: command) else { return }
            self.onRunCommand?("Run: \(command)", full)
        }
        presentAsSheet(sheet)
    }

    // MARK: Theme

    private func applyTheme() {
        view.layer?.backgroundColor = HelmTheme.nsColor(theme.backgroundHex).cgColor
        let ink = HelmTheme.nsColor(theme.chromeInkHex)
        let muted = HelmTheme.mutedInk(theme)
        let warn = HelmTheme.nsColor(theme.ansiHex[3])

        subtitleLabel.textColor = muted
        subtitleLabel.stringValue = installStatus == .notInstalled
            ? "Automic Vault isn't installed on this machine yet."
            : "\(secrets.count) secret\(secrets.count == 1 ? "" : "s") \u{00B7} \(tools.count) verified launcher\(tools.count == 1 ? "" : "s")"
        refreshButton.contentTintColor = ink.withAlphaComponent(0.7)

        attentionBanner.layer?.backgroundColor = warn.withAlphaComponent(0.14).cgColor
        attentionLabel.textColor = ink
        attentionIcon.contentTintColor = warn

        secretsPanel.applyTheme(theme)
        toolsPanel.applyTheme(theme)
        recipePanel.applyTheme(theme)
    }
}

// MARK: - Add Secret sheet

/// Only the secret NAME is ever entered here - the value is never touched by
/// this app; `av save` prompts for it in the real Console terminal this
/// sheet's Save action opens.
final class VaultSaveSecretSheetController: NSViewController {
    var onSave: ((String) -> Void)?

    private let nameField = NSTextField()
    private let errorLabel = NSTextField(labelWithString: "")

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 170))
        view = root
        ThemeManager.shared.observe { [weak root] theme in
            root?.appearance = NSAppearance(named: theme.mode == .dark ? .darkAqua : .aqua)
        }

        let title = NSTextField(labelWithString: "Save a new secret")
        title.font = .systemFont(ofSize: 14, weight: .semibold)

        let help = NSTextField(wrappingLabelWithString: "Only the name is sent here. Automic Vault will prompt for the value directly in a real terminal - Grand Line never sees it.")
        help.font = .systemFont(ofSize: 11)
        help.textColor = .secondaryLabelColor
        help.preferredMaxLayoutWidth = 320

        nameField.placeholderString = "SECRET_NAME"
        nameField.translatesAutoresizingMaskIntoConstraints = false

        errorLabel.font = .systemFont(ofSize: 10.5)
        errorLabel.textColor = .systemRed
        errorLabel.isHidden = true

        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancel.bezelStyle = .rounded
        cancel.keyEquivalent = "\u{1b}"
        let save = NSButton(title: "Save\u{2026}", target: self, action: #selector(confirm))
        save.bezelStyle = .rounded
        save.keyEquivalent = "\r"
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let bottom = NSStackView(views: [spacer, cancel, save])
        bottom.orientation = .horizontal
        bottom.spacing = 10

        let stack = NSStackView(views: [title, help, nameField, errorLabel, bottom])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 18),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -18),
            nameField.widthAnchor.constraint(equalTo: stack.widthAnchor),
            bottom.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
    }

    @objc private func confirm() {
        let name = nameField.stringValue.trimmingCharacters(in: .whitespaces)
        guard VaultSource.isSafeToken(name) else {
            errorLabel.stringValue = "Use only letters, numbers, underscore, and dash."
            errorLabel.isHidden = false
            return
        }
        onSave?(name)
        dismiss(self)
    }

    @objc private func cancel() {
        dismiss(self)
    }
}

// MARK: - Recipe replay checklist sheet

/// Shows how a previously-exported recipe compares to live `av` state right
/// now - the "replay as a checklist" half of fm/grandline-vault-recipe-
/// backup. Never re-saves or re-hardens anything itself: the captain
/// re-enters each real value from its real source, matching the task
/// brief's explicit "this app never invents or stores a value it doesn't
/// get from `av` itself."
final class VaultRecipeChecklistSheetController: NSViewController {

    private let items: [VaultRecipeChecklistItem]
    private let generatedAt: String
    private var theme: HelmTheme = ThemeManager.shared.theme

    init(items: [VaultRecipeChecklistItem], generatedAt: String) {
        self.items = items
        self.generatedAt = generatedAt
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 480, height: 540))
        view = root
        ThemeManager.shared.observe { [weak self, weak root] theme in
            self?.theme = theme
            root?.appearance = NSAppearance(named: theme.mode == .dark ? .darkAqua : .aqua)
        }

        let title = NSTextField(labelWithString: "Replay Checklist")
        title.font = .systemFont(ofSize: 15, weight: .semibold)

        let help = NSTextField(wrappingLabelWithString: "Compared against the recipe backup from \(generatedAt). \u{201c}Missing\u{201d} items were recorded before but aren\u{2019}t true right now - re-save the secret or re-harden the tool from its real source; this app never invents a value.")
        help.font = .systemFont(ofSize: 11)
        help.textColor = .secondaryLabelColor
        help.preferredMaxLayoutWidth = 440

        let listStack = NSStackView()
        listStack.orientation = .vertical
        listStack.alignment = .leading
        listStack.spacing = 6
        listStack.translatesAutoresizingMaskIntoConstraints = false

        if items.isEmpty {
            let empty = NSTextField(labelWithString: "No secrets or hardened tools recorded in the backup or right now.")
            empty.font = .systemFont(ofSize: 11.5)
            empty.textColor = .secondaryLabelColor
            listStack.addArrangedSubview(empty)
        } else {
            for item in items {
                listStack.addArrangedSubview(checklistRow(item))
            }
        }

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.documentView = listStack
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let close = NSButton(title: "Close", target: self, action: #selector(closeTapped))
        close.bezelStyle = .rounded
        close.keyEquivalent = "\r"
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let bottom = NSStackView(views: [spacer, close])
        bottom.orientation = .horizontal
        bottom.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [title, help, scroll, bottom])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 18),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -18),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 300),
            bottom.widthAnchor.constraint(equalTo: stack.widthAnchor),
            listStack.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
        ])
    }

    private func checklistRow(_ item: VaultRecipeChecklistItem) -> NSView {
        let kindLabel = NSTextField(labelWithString: item.kind == .secret ? "Secret" : "Tool")
        kindLabel.font = .systemFont(ofSize: 9.5, weight: .medium)
        kindLabel.textColor = HelmTheme.mutedInk(theme)

        let nameLabel = NSTextField(labelWithString: item.name)
        nameLabel.font = .systemFont(ofSize: 12, weight: .medium)

        let (statusText, statusColorHex) = statusVisuals(item.status)
        let statusLabel = NSTextField(labelWithString: statusText)
        statusLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        statusLabel.textColor = HelmTheme.nsColor(statusColorHex)

        let topRow = NSStackView(views: [kindLabel, nameLabel])
        topRow.orientation = .horizontal
        topRow.spacing = 6
        topRow.alignment = .firstBaseline

        var rowViews: [NSView] = [topRow]
        if let detail = item.detail {
            let detailLabel = NSTextField(labelWithString: "Launchers: \(detail)")
            detailLabel.font = .systemFont(ofSize: 10.5)
            detailLabel.textColor = HelmTheme.mutedInk(theme)
            rowViews.append(detailLabel)
        }

        let textStack = NSStackView(views: rowViews)
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 2

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let row = NSStackView(views: [textStack, spacer, statusLabel])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        row.distribution = .fill
        row.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.setContentHuggingPriority(.required, for: .horizontal)
        return row
    }

    private func statusVisuals(_ status: VaultRecipeItemStatus) -> (String, String) {
        switch status {
        case .matches: return ("Matches backup", theme.ansiHex[2])
        case .missingLocally: return ("Missing - needs redo", theme.ansiHex[1])
        case .newSinceBackup: return ("New since backup", theme.ansiHex[3])
        }
    }

    @objc private func closeTapped() { dismiss(self) }
}

// MARK: - Run injected sheet

final class VaultInjectSheetController: NSViewController {
    var onRun: ((String, String) -> Void)?

    private let secretNames: [String]
    private let preselected: String?
    private let secretPopup = NSPopUpButton()
    private let commandField = NSTextField()
    private let errorLabel = NSTextField(labelWithString: "")

    init(secretNames: [String], preselected: String?) {
        self.secretNames = secretNames
        self.preselected = preselected
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 380, height: 190))
        view = root
        ThemeManager.shared.observe { [weak root] theme in
            root?.appearance = NSAppearance(named: theme.mode == .dark ? .darkAqua : .aqua)
        }

        let title = NSTextField(labelWithString: "Run with a secret injected")
        title.font = .systemFont(ofSize: 14, weight: .semibold)

        let help = NSTextField(wrappingLabelWithString: "Runs \u{201c}av inject +SECRET -- command\u{201d} in a Console tab, so any output or approval prompt is visible directly - never captured by this app.")
        help.font = .systemFont(ofSize: 11)
        help.textColor = .secondaryLabelColor
        help.preferredMaxLayoutWidth = 340

        secretPopup.removeAllItems()
        secretPopup.addItems(withTitles: secretNames)
        if let preselected, secretNames.contains(preselected) {
            secretPopup.selectItem(withTitle: preselected)
        }
        secretPopup.isEnabled = !secretNames.isEmpty
        secretPopup.translatesAutoresizingMaskIntoConstraints = false

        commandField.placeholderString = "e.g. gh auth status"
        commandField.translatesAutoresizingMaskIntoConstraints = false

        errorLabel.font = .systemFont(ofSize: 10.5)
        errorLabel.textColor = .systemRed
        errorLabel.isHidden = true
        if secretNames.isEmpty {
            errorLabel.stringValue = "Save a secret first."
            errorLabel.isHidden = false
        }

        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancel.bezelStyle = .rounded
        cancel.keyEquivalent = "\u{1b}"
        let run = NSButton(title: "Run", target: self, action: #selector(confirm))
        run.bezelStyle = .rounded
        run.keyEquivalent = "\r"
        run.isEnabled = !secretNames.isEmpty
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let bottom = NSStackView(views: [spacer, cancel, run])
        bottom.orientation = .horizontal
        bottom.spacing = 10

        let stack = NSStackView(views: [title, help, secretPopup, commandField, errorLabel, bottom])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 18),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -18),
            secretPopup.widthAnchor.constraint(equalTo: stack.widthAnchor),
            commandField.widthAnchor.constraint(equalTo: stack.widthAnchor),
            bottom.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
    }

    @objc private func confirm() {
        guard let secret = secretPopup.titleOfSelectedItem, !secret.isEmpty else { return }
        let command = commandField.stringValue.trimmingCharacters(in: .whitespaces)
        guard !command.isEmpty else {
            errorLabel.stringValue = "Enter a command to run."
            errorLabel.isHidden = false
            return
        }
        onRun?(secret, command)
        dismiss(self)
    }

    @objc private func cancel() {
        dismiss(self)
    }
}
