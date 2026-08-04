// Firstmate Cockpit - native macOS app.
//
// The console: one surface hosting a **flexible collection of tabs**, each a
// SwiftTerm terminal. This is Phase 0 of the connection-manager work (design
// report `data/cockpit-ssh-manager-research/report.md`, Section A4/A5 + Section D
// Phase 0): the old fixed `enum Tab { case shell, mirror }` is gone, replaced by
// `[TabModel]` rendered in a dynamic tab bar that grows and shrinks.
//
// What the tab model buys us:
//   - **New tab** (⌘T / the "+" button): a fresh login shell.
//   - **Duplicate** (⌘D): a new tab running the *same* argv as the current one -
//     the primitive that will later duplicate a host session.
//   - **Rename** (double-click a tab, ⌘⇧R, or right-click -> Rename): per-tab
//     name that never touches the process.
//   - **Close** (⌘W / the "×"): with the last-tab edge case handled - closing the
//     final tab opens a fresh shell so the window is never empty.
//
// The initial set is still Shell + Mirror, so nothing regresses. Every tab is a
// paste-hardening `CockpitTerminalView`, so screenshot-paste into Claude works on
// all of them, and every terminal gets Helm theming, font zoom, find, copy, a
// generous scrollback, and smooth native scrolling.

import AppKit
import SwiftTerm

final class ConsoleController: NSViewController, LocalProcessTerminalViewDelegate {

    /// The saved-keys Keychain (Phase 2) - consulted only to resolve a host's
    /// `.ssh` tab into a live `-i <path>` at start/reconnect time
    /// (`connectSSH`); everything secret stays inside `KeychainKeyStore` /
    /// `SSHKeyMaterializer`.
    private let keyStore: SSHKeyStore

    init(keyStore: SSHKeyStore) {
        self.keyStore = keyStore
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: Tabs

    private var tabs: [TabModel] = []
    private var currentTab: TabModel?
    private var hasAppeared = false

    /// Scrollback retained per normal-screen terminal. SwiftTerm defaults to 500
    /// lines; a shell session wants much more so history that scrolls off the top
    /// stays reachable.
    private let scrollbackLines = 10_000

    // MARK: Theme + font

    private var theme: HelmTheme = .dark
    private var fontSize: CGFloat = 13
    private let minFont: CGFloat = 8
    private let maxFont: CGFloat = 28

    private func currentFont() -> NSFont {
        NSFont(name: "Menlo", size: fontSize)
            ?? .monospacedSystemFont(ofSize: fontSize, weight: .regular)
    }

    // MARK: Chrome views

    private let tabBar = NSView()
    private let content = NSView()
    private let tabsStack = NSStackView()
    private var plusButton = NSButton()
    private var themeButton = NSButton()
    private var findButton = NSButton()
    private var zoomInButton = NSButton()
    private var zoomOutButton = NSButton()
    private let separator = NSView()

    // MARK: Lifecycle

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 980, height: 660))
        root.wantsLayer = true
        view = root

        buildTabBar()
        content.translatesAutoresizingMaskIntoConstraints = false
        content.wantsLayer = true
        root.addSubview(content)

        NSLayoutConstraint.activate([
            tabBar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            tabBar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            tabBar.topAnchor.constraint(equalTo: root.topAnchor),
            tabBar.heightAnchor.constraint(equalToConstant: 42),

            content.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            content.topAnchor.constraint(equalTo: tabBar.bottomAnchor),
            content.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])

        // The starting set: Shell + Mirror, matching the previous behaviour. Their
        // processes start in `viewDidAppear` (once the view is on screen).
        let s = shellArgv()
        let shell = TabLaunch.shell(executable: s.executable, args: s.args, cwd: shellCwd())
        addTab(launch: shell, name: shell.defaultName, select: false)
        let mirror = TabLaunch.mirror(target: mirrorTarget())
        addTab(launch: mirror, name: mirror.defaultName, select: false)

        applyTheme()
        if let first = tabs.first { select(tabID: first.id, focus: false) }
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        hasAppeared = true
        for tab in tabs where !tab.started { startTab(tab) }
        if let tab = currentTab { view.window?.makeFirstResponder(tab.terminal) }
    }

    // MARK: Building the top bar

    private func buildTabBar() {
        tabBar.translatesAutoresizingMaskIntoConstraints = false
        tabBar.wantsLayer = true
        view.addSubview(tabBar)

        separator.translatesAutoresizingMaskIntoConstraints = false
        separator.wantsLayer = true
        tabBar.addSubview(separator)
        NSLayoutConstraint.activate([
            separator.leadingAnchor.constraint(equalTo: tabBar.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: tabBar.trailingAnchor),
            separator.bottomAnchor.constraint(equalTo: tabBar.bottomAnchor),
            separator.heightAnchor.constraint(equalToConstant: 1),
        ])

        tabsStack.orientation = .horizontal
        tabsStack.spacing = 4
        tabsStack.alignment = .centerY
        tabsStack.translatesAutoresizingMaskIntoConstraints = false
        tabBar.addSubview(tabsStack)

        plusButton = makeIconButton(symbol: "plus", tooltip: "New Shell Tab (⌘T)", action: #selector(newShellTab))

        findButton = makeIconButton(symbol: "magnifyingglass", tooltip: "Find (⌘F)", action: #selector(showFind))
        zoomOutButton = makeIconButton(symbol: "minus.magnifyingglass", tooltip: "Zoom Out (⌘−)", action: #selector(zoomOut))
        zoomInButton = makeIconButton(symbol: "plus.magnifyingglass", tooltip: "Zoom In (⌘+)", action: #selector(zoomIn))
        themeButton = makeIconButton(symbol: "circle.lefthalf.filled", tooltip: "Toggle Light/Dark (⌘⌥T)", action: #selector(toggleTheme))
        let tools = NSStackView(views: [findButton, zoomOutButton, zoomInButton, themeButton])
        tools.orientation = .horizontal
        tools.spacing = 2
        tools.translatesAutoresizingMaskIntoConstraints = false
        tabBar.addSubview(tools)

        NSLayoutConstraint.activate([
            tabsStack.leadingAnchor.constraint(equalTo: tabBar.leadingAnchor, constant: 12),
            tabsStack.centerYAnchor.constraint(equalTo: tabBar.centerYAnchor),
            tabsStack.trailingAnchor.constraint(lessThanOrEqualTo: tools.leadingAnchor, constant: -8),
            tools.trailingAnchor.constraint(equalTo: tabBar.trailingAnchor, constant: -10),
            tools.centerYAnchor.constraint(equalTo: tabBar.centerYAnchor),
        ])
    }

    private func makeIconButton(symbol: String, tooltip: String, action: Selector) -> NSButton {
        let b = NSButton(title: "", target: self, action: action)
        b.isBordered = false
        b.wantsLayer = true
        b.layer?.cornerRadius = 6
        b.toolTip = tooltip
        b.imageScaling = .scaleProportionallyDown
        if let img = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip) {
            b.image = img
        } else {
            b.title = symbol
        }
        NSLayoutConstraint.activate([
            b.widthAnchor.constraint(equalToConstant: 30),
            b.heightAnchor.constraint(equalToConstant: 26),
        ])
        return b
    }

    /// Re-lay the tab bar: one chip per tab, then the "+" button.
    private func refreshTabBar() {
        for v in tabsStack.arrangedSubviews {
            tabsStack.removeArrangedSubview(v)
            v.removeFromSuperview()
        }
        for tab in tabs {
            tabsStack.addArrangedSubview(tab.chip)
        }
        tabsStack.addArrangedSubview(plusButton)
        styleChips()
    }

    // MARK: Tab lifecycle

    /// Create a terminal view wired for this console: the paste-hardening
    /// subclass, this delegate, the current font + theme, and a generous
    /// scrollback so history is retained (SwiftTerm's default is only 500 lines).
    private func makeTerminal() -> CockpitTerminalView {
        let term = CockpitTerminalView(frame: .zero)
        term.translatesAutoresizingMaskIntoConstraints = false
        term.processDelegate = self
        term.font = currentFont()
        // Retain a real scrollback so shells keep their history reachable.
        // SwiftTerm 1.15's `scrollWheel` already scrolls a normal-screen buffer
        // smoothly and content-wise: it accumulates precise trackpad deltas and
        // converts them to whole lines 1:1 (no page-jumps), and its
        // `scrollSensitivity` defaults to a native 1.0. So the WezTerm feel the
        // captain wants is the shell tab's default here; we just give it history.
        // (The Mirror tab runs tmux on the alternate screen and pages inherently.)
        term.terminal?.changeScrollback(scrollbackLines)
        content.addSubview(term)
        NSLayoutConstraint.activate([
            term.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            term.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            term.topAnchor.constraint(equalTo: content.topAnchor),
            term.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        theme.apply(to: term)
        return term
    }

    /// Add a tab for `launch`, build its chip, and (if the view is already on
    /// screen) start its process. Returns the new tab.
    @discardableResult
    private func addTab(launch: TabLaunch, name: String, select: Bool, accentHex: String? = nil) -> TabModel {
        let term = makeTerminal()
        let tab = TabModel(name: name, launch: launch, terminal: term, accentHex: accentHex)

        let chip = TabChipView(tabID: tab.id, name: name)
        let id = tab.id
        chip.onSelect = { [weak self] in self?.select(tabID: id) }
        chip.onClose = { [weak self] in self?.closeTab(id: id) }
        chip.onDuplicate = { [weak self] in self?.duplicateTab(id: id) }
        chip.onRename = { [weak self] newName in self?.renameTab(id: id, to: newName) }
        tab.chip = chip

        tabs.append(tab)
        refreshTabBar()

        if hasAppeared { startTab(tab) }
        if select { self.select(tabID: tab.id) }
        return tab
    }

    /// Start (or restart) a tab's child process from its launch spec.
    private func startTab(_ tab: TabModel) {
        switch tab.launch {
        case .shell(let exe, let args, let cwd):
            tab.terminal.startProcess(
                executable: exe,
                args: args,
                environment: childEnvironment(),
                execName: nil,
                currentDirectory: cwd
            )
        case .mirror(let target):
            connectMirror(tab, target: target)
        case .ssh(_, let exe, let hostArgs, let keyID):
            connectSSH(tab, executable: exe, hostArgs: hostArgs, keyID: keyID)
        }
        tab.started = true
    }

    // MARK: SSH (Phase 1 hosts, Phase 2 keys)

    /// Open a new tab that runs `ssh` with the given argv - the connect action for
    /// a saved host or an ad-hoc quick-connect (design report C1). The tab's name
    /// defaults to the host label (rename still works), and `accentHex` tints its
    /// chip with the host colour (A3). Duplicating this tab (Phase 0) re-runs the
    /// same connection, re-resolving `keyID` independently for the new tab.
    func openSSH(label: String, args: [String], accentHex: String?, keyID: UUID?) {
        let launch = TabLaunch.ssh(label: label, executable: HostCatalog.sshExecutable, hostArgs: args, keyID: keyID)
        addTab(launch: launch, name: label, select: true, accentHex: accentHex)
        // Bring the console forward if the user was in the sidebar.
        if let tab = currentTab { view.window?.makeFirstResponder(tab.terminal) }
    }

    /// Start an ssh tab's process. If `keyID` names a saved key, it is resolved
    /// through the Keychain into a fresh temp `-i <path>` (`SSHKeyMaterializer`)
    /// - the Touch ID / passcode prompt happens inside that call. Any temp file
    /// from a previous start of this tab is cleaned up first, so reconnect never
    /// piles up scratch directories. A resolution failure (deleted key,
    /// cancelled prompt, Keychain error) does not block the connection - `ssh`
    /// still starts without `-i`, falling back to the system agent, with the
    /// error surfaced in the terminal so it is visible rather than silent.
    private func connectSSH(_ tab: TabModel, executable: String, hostArgs: [String], keyID: UUID?) {
        cleanupSSHKeyTempFile(tab)
        var args = hostArgs
        if let keyID, let key = keyStore.key(id: keyID) {
            do {
                let materialized = try SSHKeyMaterializer.materialize(key: key)
                tab.sshKeyTempPath = materialized.privateKeyPath
                args = ["-i", materialized.privateKeyPath] + args
            } catch {
                tab.terminal.feed(text: "\r\n  \u{1b}[2m[ssh key]\u{1b}[0m \(error.localizedDescription)\r\n")
                tab.terminal.feed(text: "  \u{1b}[2mConnecting without the saved key. Press ⌘R to retry.\u{1b}[0m\r\n")
            }
        }
        tab.terminal.startProcess(
            executable: executable,
            args: args,
            environment: childEnvironment(),
            execName: nil,
            currentDirectory: shellCwd()
        )
    }

    /// Delete a tab's materialized key scratch dir, if it has one. Called
    /// before every (re)start, on close, and on quit - never left for a crash
    /// to clean up.
    private func cleanupSSHKeyTempFile(_ tab: TabModel) {
        guard let path = tab.sshKeyTempPath else { return }
        SSHKeyMaterializer.cleanup(privateKeyPath: path)
        tab.sshKeyTempPath = nil
    }

    /// Set up a grouped session and attach `tab`'s terminal to it. On failure the
    /// error is written into the terminal so it is visible rather than silent.
    private func connectMirror(_ tab: TabModel, target: String) {
        switch TmuxMirror.setUp(target: target) {
        case .success(let m):
            tab.mirror = m
            tab.terminal.startProcess(
                executable: m.tmuxPath,
                args: m.attachArgs,
                environment: childEnvironment(),
                execName: nil,
                currentDirectory: shellCwd()
            )
        case .failure(let err):
            tab.mirror = nil
            tab.terminal.feed(text: "\r\n  \u{1b}[2m[mirror]\u{1b}[0m \(err.message)\r\n")
            tab.terminal.feed(text: "  \u{1b}[2mSet FM_MIRROR_TARGET to a live tmux target, then press ⌘R to reconnect.\u{1b}[0m\r\n")
        }
    }

    // MARK: Tab commands (menu + chip)

    /// ⌘T / the "+" button: a fresh login shell tab.
    @objc func newShellTab() {
        let s = shellArgv()
        let launch = TabLaunch.shell(executable: s.executable, args: s.args, cwd: shellCwd())
        addTab(launch: launch, name: launch.defaultName, select: true)
    }

    /// ⌘D: a new tab running the same argv as the current one.
    @objc func duplicateCurrentTab() {
        if let tab = currentTab { duplicateTab(id: tab.id) }
    }

    private func duplicateTab(id: UUID) {
        guard let src = tabs.first(where: { $0.id == id }) else { return }
        addTab(launch: src.launch, name: src.name, select: true, accentHex: src.accentHex)
    }

    /// ⌘W: close the current tab.
    @objc func closeCurrentTab() {
        if let tab = currentTab { closeTab(id: tab.id) }
    }

    private func closeTab(id: UUID) {
        guard let idx = tabs.firstIndex(where: { $0.id == id }) else { return }
        let tab = tabs[idx]

        tab.isClosing = true
        tab.mirror?.tearDown()
        tab.mirror = nil
        cleanupSSHKeyTempFile(tab)
        tab.terminal.terminate()
        tab.terminal.removeFromSuperview()
        tabs.remove(at: idx)

        // Last-tab edge case: never leave an empty window - open a fresh shell.
        if tabs.isEmpty {
            newShellTab()
            return
        }

        refreshTabBar()
        if currentTab === tab || currentTab == nil {
            let neighbor = tabs[min(idx, tabs.count - 1)]
            select(tabID: neighbor.id)
        } else {
            styleChips()
        }
    }

    /// ⌘⇧R / double-click / right-click -> Rename: start editing the current tab's name.
    @objc func renameCurrentTab() {
        currentTab?.chip.beginRename()
    }

    private func renameTab(id: UUID, to newName: String) {
        guard let tab = tabs.first(where: { $0.id == id }) else { return }
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        tab.name = trimmed.isEmpty ? tab.launch.defaultName : trimmed
        tab.chip.setName(tab.name)
        styleChips()
        view.window?.makeFirstResponder(tab.terminal)
    }

    /// ⌘1…⌘9: select the Nth tab (menu items carry a 1-based tag).
    @objc func selectTabByShortcut(_ sender: NSMenuItem) {
        let idx = sender.tag - 1
        guard idx >= 0, idx < tabs.count else { return }
        select(tabID: tabs[idx].id)
    }

    // MARK: Selection

    private func activeTerminal() -> CockpitTerminalView? { currentTab?.terminal }

    private func select(tabID: UUID, focus: Bool = true) {
        guard let tab = tabs.first(where: { $0.id == tabID }) else { return }
        currentTab = tab
        for t in tabs { t.terminal.isHidden = (t !== tab) }
        styleChips()
        updateWindowTitle(from: tab)
        if focus { view.window?.makeFirstResponder(tab.terminal) }
    }

    // MARK: Theme

    @objc func toggleTheme() {
        theme = (theme.mode == .dark) ? .light : .dark
        applyTheme()
    }

    private func applyTheme() {
        for tab in tabs { theme.apply(to: tab.terminal) }

        let chromeBg = HelmTheme.nsColor(theme.chromeBackgroundHex)
        let line = HelmTheme.nsColor(theme.chromeLineHex)
        view.layer?.backgroundColor = HelmTheme.nsColor(theme.backgroundHex).cgColor
        tabBar.layer?.backgroundColor = chromeBg.cgColor
        separator.layer?.backgroundColor = line.cgColor
        content.layer?.backgroundColor = HelmTheme.nsColor(theme.backgroundHex).cgColor

        let ink = HelmTheme.nsColor(theme.chromeInkHex)
        for b in [plusButton, findButton, zoomInButton, zoomOutButton, themeButton] {
            b.contentTintColor = ink
        }
        styleChips()
    }

    private func styleChips() {
        let accent = HelmTheme.nsColor(theme.accentHex)
        let ink = HelmTheme.nsColor(theme.chromeInkHex)
        let muted = ink.withAlphaComponent(0.55)
        for tab in tabs {
            // Host tabs carry their own accent (A3); other tabs use the theme accent.
            let chipAccent = tab.accentHex.map(HelmTheme.nsColor) ?? accent
            let chipTint = chipAccent.withAlphaComponent(theme.mode == .dark ? 0.20 : 0.14)
            tab.chip.applyStyle(selected: tab === currentTab, accent: chipAccent, muted: muted, tint: chipTint)
        }
        plusButton.contentTintColor = ink
    }

    // MARK: Font zoom

    @objc func zoomIn() { setFontSize(fontSize + 1) }
    @objc func zoomOut() { setFontSize(fontSize - 1) }
    @objc func zoomReset() { setFontSize(13) }

    private func setFontSize(_ size: CGFloat) {
        fontSize = min(maxFont, max(minFont, size))
        let f = currentFont()
        for tab in tabs { tab.terminal.font = f }
    }

    // MARK: Find + copy (routed to the active terminal)

    @objc func showFind() {
        // Route to the active terminal's native find bar. SwiftTerm's
        // `performFindPanelAction` expects a menu item whose tag is the
        // NSFindPanelAction; showFindPanel == 1.
        guard let term = activeTerminal() else { return }
        let item = NSMenuItem()
        item.tag = Int(NSFindPanelAction.showFindPanel.rawValue)
        view.window?.makeFirstResponder(term)
        term.performFindPanelAction(item)
    }

    @objc func copySelection() {
        activeTerminal()?.copy(self)
    }

    // MARK: Reconnect / restart

    /// ⌘R: restart whichever tab is in front from its launch spec. For a mirror
    /// this re-runs the grouped-session setup (a fresh attach); for a shell it
    /// forks a new login shell.
    @objc func reconnectActive() {
        guard let tab = currentTab else { return }
        switch tab.launch {
        case .mirror(let target):
            tab.mirror?.tearDown()
            tab.mirror = nil
            connectMirror(tab, target: target)
        case .shell(let exe, let args, let cwd):
            tab.terminal.startProcess(
                executable: exe,
                args: args,
                environment: childEnvironment(),
                execName: nil,
                currentDirectory: cwd
            )
        case .ssh(_, let exe, let hostArgs, let keyID):
            connectSSH(tab, executable: exe, hostArgs: hostArgs, keyID: keyID)
        }
        view.window?.makeFirstResponder(tab.terminal)
    }

    /// Tear down every mirror's grouped session and every materialized ssh key
    /// temp file so nothing is left dangling. Called from the app delegate on quit.
    func shutdown() {
        for tab in tabs {
            tab.mirror?.tearDown()
            tab.mirror = nil
            cleanupSSHKeyTempFile(tab)
        }
    }

    // MARK: Window title

    private func updateWindowTitle(from tab: TabModel) {
        view.window?.title = "Firstmate Cockpit - \(tab.name)"
    }

    // MARK: LocalProcessTerminalViewDelegate

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        // Only the active terminal drives the window title; keep the tab name too.
        guard source === currentTab?.terminal, let tab = currentTab else { return }
        if title.isEmpty {
            updateWindowTitle(from: tab)
        } else {
            view.window?.title = "\(tab.name) - \(title)"
        }
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    /// A tab's process ended. The console keeps running (other tabs may be live)
    /// and shows a dim "reconnect" hint in the tab that exited. A mirror tears
    /// down its grouped session here so nothing is left dangling. A tab that is
    /// being closed is skipped - its view is on its way out.
    func processTerminated(source: TerminalView, exitCode: Int32?) {
        guard let tab = tabs.first(where: { $0.terminal === source }) else { return }
        if tab.isClosing { return }
        tab.mirror?.tearDown()
        tab.mirror = nil
        cleanupSSHKeyTempFile(tab)
        let code = exitCode.map { " (exit \($0))" } ?? ""
        source.feed(text: "\r\n  \u{1b}[2m[process ended\(code) - press ⌘R to reconnect]\u{1b}[0m\r\n")
    }
}
