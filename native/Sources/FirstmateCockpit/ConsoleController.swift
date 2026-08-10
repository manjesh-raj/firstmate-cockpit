// Manjesh Grand Line - native macOS app.
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

    /// The snippet library (Phase 3, B2/B5) - consulted to resolve a host's
    /// startup-snippet id, and by `runSnippetInActiveTab` for the Snippets
    /// panel's "Run" action.
    private let snippetStore: SnippetStore

    /// Fix 1 (dedicated host pages): `false` for a per-host console
    /// (`AppShellController.connectHost`'s `makeHostConsole` factory), which
    /// governs two related behaviours instead of one - both express "this is
    /// the one shared, general-purpose console, not a page dedicated to a
    /// single host": (1) `loadView` only opens the Shell + Mirror pair on
    /// launch when this is `true`; (2) `closeTab`'s "never leave the window
    /// empty" fallback only applies when this is `true` - a dedicated host
    /// page is allowed to end up with zero tabs after its one ssh tab is
    /// closed, since `ConsoleController.connectSSHIfNeeded` re-opens it the
    /// next time the host is connected to. Getting (2) wrong was a real bug:
    /// falling back to a generic shell tab left `tabs` non-empty, which made
    /// `connectSSHIfNeeded`'s `tabs.isEmpty` guard permanently skip
    /// reconnecting that host.
    private let isFirstmateConsole: Bool

    init(keyStore: SSHKeyStore, snippetStore: SnippetStore, isFirstmateConsole: Bool = true) {
        self.keyStore = keyStore
        self.snippetStore = snippetStore
        self.isFirstmateConsole = isFirstmateConsole
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

    /// Mirrors `ThemeManager.shared.theme` - kept as a local var so the many
    /// call sites below don't all become `ThemeManager.shared.theme`, but the
    /// manager (not this property) is the source of truth: `toggleTheme`
    /// writes through it, and every window that needs to match (Hosts/Keys/
    /// Snippets) observes the same manager instead of tracking its own copy.
    private var theme: HelmTheme = ThemeManager.shared.theme
    private var fontSize: CGFloat = AppSettings.shared.fontSize
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
    private var logButton = NSButton()
    private let separator = NSView()

    // MARK: SRE Lead (dedicated host pages only - see `SRELead.swift`)

    /// Set by `connectSSHIfNeeded` for a dedicated host page - the same
    /// resolved `hostArgs`/`keyID` the interactive ssh tab already uses,
    /// kept around so a later SRE Lead toggle can open its own, independent
    /// second connection to the same bastion without this controller having
    /// to know anything else about the `Host` value itself.
    private var sreLeadHostContext: (hostArgs: [String], keyID: UUID?, becomeUser: String?)?

    private enum SRELeadPhase { case notStarted, starting, ready, failed }
    private var sreLeadPhase: SRELeadPhase = .notStarted
    private var sreLeadSession: SRELeadSession?
    private var sreLeadMirror: TmuxMirror?
    private var sreLeadTerminal: CockpitTerminalView?
    private var sreLeadButton: SRELeadStatusPill?

    private let sreLeadPane = NSView()
    private let sreLeadPaneSeparator = NSView()
    private let sreLeadHeader = NSView()
    private let sreLeadHeaderLabel = NSTextField(labelWithString: "SRE Lead")
    private var sreLeadPaneWidthConstraint: NSLayoutConstraint!
    private let sreLeadPaneWidth: CGFloat = 380

    /// `FM_LOG_SESSIONS_DEFAULT` (Phase 3, B5), then Settings > General's
    /// "Log sessions by default" toggle: when set, every newly started tab
    /// begins logging automatically. Re-read on every tab start (not cached)
    /// so a Settings change applies to the next tab without a restart.
    private var defaultLoggingEnabled: Bool {
        if let v = ProcessInfo.processInfo.environment["FM_LOG_SESSIONS_DEFAULT"]?.lowercased() {
            return v == "1" || v == "true" || v == "yes"
        }
        return AppSettings.shared.sessionLoggingDefault
    }

    // MARK: Lifecycle

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 980, height: 660))
        root.wantsLayer = true
        view = root

        buildTabBar()
        content.translatesAutoresizingMaskIntoConstraints = false
        content.wantsLayer = true
        root.addSubview(content)

        buildSRELeadPane()
        root.addSubview(sreLeadPane)

        sreLeadPaneWidthConstraint = sreLeadPane.widthAnchor.constraint(equalToConstant: 0)

        NSLayoutConstraint.activate([
            tabBar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            tabBar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            tabBar.topAnchor.constraint(equalTo: root.topAnchor),
            tabBar.heightAnchor.constraint(equalToConstant: 42),

            content.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: sreLeadPane.leadingAnchor),
            content.topAnchor.constraint(equalTo: tabBar.bottomAnchor),
            content.bottomAnchor.constraint(equalTo: root.bottomAnchor),

            sreLeadPane.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            sreLeadPane.topAnchor.constraint(equalTo: tabBar.bottomAnchor),
            sreLeadPane.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            sreLeadPaneWidthConstraint,
        ])

        // The starting set: the pinned "Firstmate" host's Shell + Mirror pair,
        // matching the previous fixed-tabs behaviour (Fix 4: this is now also
        // reachable from the Hosts sidebar's pinned entry, but the app still
        // lands here automatically on launch). Their processes start in
        // `viewDidAppear` (once the view is on screen). A per-host console
        // (Fix 1) opts out - its one tab is added on demand by
        // `connectSSHIfNeeded` instead.
        if isFirstmateConsole {
            openFirstmateHost(focus: false)
        }

        // Follow the shared Helm theme (Fix 2) rather than a private copy, so
        // toggling it from the toolbar, ⌘⌥T, or Settings all land here. The
        // token is kept (not discarded, unlike every other observer in this
        // app) because - since Fix 1 - a `ConsoleController` isn't
        // necessarily permanent: a per-host page is deallocated when its
        // host is deleted, and without unregistering here that would leak a
        // dead closure into `ThemeManager` forever (see `shutdown()`).
        themeObservation = ThemeManager.shared.observe { [weak self] theme in
            self?.theme = theme
            self?.applyTheme()
        }
    }

    private var themeObservation: ThemeObservation?

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
        logButton = makeIconButton(symbol: "record.circle", tooltip: "Log This Session (⌘⇧L)", action: #selector(toggleLoggingForActiveTab))

        // SRE Lead (design brief Part C) is a dedicated-host-page-only
        // affordance - the shared Firstmate console has no single host
        // cluster to investigate.
        var toolViews: [NSView] = []
        if !isFirstmateConsole {
            let pill = SRELeadStatusPill()
            pill.onClick = { [weak self] in self?.toggleSRELead() }
            sreLeadButton = pill
            toolViews.append(pill)
        }
        toolViews += [findButton, zoomOutButton, zoomInButton, themeButton, logButton]
        let tools = NSStackView(views: toolViews)
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
    private func addTab(launch: TabLaunch, name: String, select: Bool, accentHex: String? = nil, isOneShotCommand: Bool = false) -> TabModel {
        let term = makeTerminal()
        let tab = TabModel(name: name, launch: launch, terminal: term, accentHex: accentHex)
        tab.isOneShotCommand = isOneShotCommand

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
        case .ssh(_, let exe, let hostArgs, let keyID, let startupSnippetID):
            connectSSH(tab, executable: exe, hostArgs: hostArgs, keyID: keyID, startupSnippetID: startupSnippetID)
        }
        tab.started = true
        if defaultLoggingEnabled { startLogging(tab) }
    }

    // MARK: The pinned "Firstmate" host (Fix 4)

    /// Open the built-in tab pair - the connect action for the Hosts
    /// sidebar's pinned, non-deletable "Firstmate" entry
    /// (`HostsSidebarController`), and also what `loadView` calls to land the
    /// app on this pair at startup so the initial state is unchanged from
    /// before this pair lived in the Hosts list. Like every other host,
    /// connecting always opens a fresh tab pair rather than reusing an
    /// existing one - the same mental model as SSH hosts and ⌘T. Still
    /// exactly two tabs: on a tmux fleet, "Mirror" (read-only,
    /// `TmuxMirror`) + "Shell"; on a herdr fleet (fm/cockpit-mirror-herdr-
    /// real-attach), "herdr" (a real `herdr session attach` client,
    /// `HerdrMirror`) + "Shell", the latter completely unchanged either way.
    @discardableResult
    func openFirstmateHost(focus: Bool = true) -> TabModel {
        // The mirror/herdr tab first, Shell second (fixes3) - both the tab
        // bar order and the ⌘1…⌘9 shortcut numbering follow `tabs`' append
        // order, so this tab must be created before the shell tab.
        let mirror = TabLaunch.mirror(target: mirrorTarget())
        addTab(launch: mirror, name: mirror.defaultName, select: false)
        let s = shellArgv()
        let shell = TabLaunch.shell(executable: s.executable, args: s.args, cwd: shellCwd())
        let shellTab = addTab(launch: shell, name: shell.defaultName, select: false)
        select(tabID: shellTab.id, focus: focus)
        return shellTab
    }

    // MARK: Ad-hoc commands (Bootstrap page, cockpit-bootstrap-dotfiles)

    /// Open a new tab that runs `command` through a real login shell (`$SHELL
    /// -lc "<command>"`) - the Bootstrap page's "Clone & Bootstrap"/"Run
    /// rebuild.sh"/"Create link" actions all go through this rather than a
    /// silent background `Process`, since `darwin-rebuild switch` needs an
    /// interactive TTY for its `sudo` prompt (task brief requirement). This
    /// reuses the exact same `.shell` launch kind and `startProcess` path a
    /// plain new tab (⌘T) already uses, just with a one-shot `-lc` command
    /// instead of an interactive `-l` login shell. Marked `isOneShotCommand`
    /// so `processTerminated` never auto-reconnects it - unlike an
    /// interactive shell, this command is meant to run once and stop, and a
    /// successful exit must never be treated like a dropped connection.
    ///
    /// `completion`, when supplied (Bootstrap's "Run full setup" sequencer),
    /// fires exactly once with the child's real exit code once
    /// `processTerminated` sees this tab end - the sequencer waits on this
    /// rather than a fixed timer before starting its next step.
    @discardableResult
    func openCommandTab(label: String, command: String, cwd: String? = nil, completion: ((Int32?) -> Void)? = nil) -> TabModel {
        let launch = TabLaunch.shell(executable: shellArgv().executable, args: ["-lc", command], cwd: cwd ?? shellCwd())
        let tab = addTab(launch: launch, name: label, select: true, isOneShotCommand: true)
        tab.onOneShotCompletion = completion
        if let current = currentTab { view.window?.makeFirstResponder(current.terminal) }
        return tab
    }

    // MARK: SSH (Phase 1 hosts, Phase 2 keys, Phase 3 startup snippet)

    /// Open a new tab that runs `ssh` with the given argv - the connect action for
    /// a saved host or an ad-hoc quick-connect (design report C1). `args` already
    /// carries the host's agent-forwarding/jump-chain/port-forwarding flags
    /// (`Host.sshArguments(allHosts:)`, Phase 3 B1) - this method only adds the
    /// resolved key. The tab's name defaults to the host label (rename still
    /// works), and `accentHex` tints its chip with the host colour (A3).
    /// Duplicating this tab (Phase 0) re-runs the same connection, re-resolving
    /// `keyID` independently for the new tab. `startupSnippetID` (B2/B5), when
    /// set, is sent into the shell once the session looks ready.
    func openSSH(label: String, args: [String], accentHex: String?, keyID: UUID?, startupSnippetID: UUID? = nil) {
        let launch = TabLaunch.ssh(
            label: label, executable: HostCatalog.sshExecutable, hostArgs: args,
            keyID: keyID, startupSnippetID: startupSnippetID
        )
        addTab(launch: launch, name: label, select: true, accentHex: accentHex)
        // Bring the console forward if the user was in the sidebar.
        if let tab = currentTab { view.window?.makeFirstResponder(tab.terminal) }
    }

    /// Fix 1 (dedicated host pages): the connect action for a saved host's
    /// own page (`AppShellController.connectHost`). Opens the one ssh tab
    /// this console is dedicated to only the first time it's called - every
    /// later call (a re-click of the host's rail icon, or its Hosts sidebar
    /// Connect button) is a no-op, since `tabs` is no longer empty. That's
    /// what fixes the duplicate-tab bug: re-connecting to an already-open
    /// host just shows its existing page (`AppShellController` handles that
    /// part) instead of implicitly stacking a second tab. A deliberate
    /// second session to the same host still works via the tab chip's own
    /// Duplicate affordance (⌘D / `duplicateTab`).
    func connectSSHIfNeeded(label: String, args: [String], accentHex: String?, keyID: UUID?, startupSnippetID: UUID?, becomeUser: String? = nil) {
        sreLeadHostContext = (hostArgs: args, keyID: keyID, becomeUser: becomeUser)
        guard tabs.isEmpty else { return }
        openSSH(label: label, args: args, accentHex: accentHex, keyID: keyID, startupSnippetID: startupSnippetID)
    }

    /// Re-focus whichever tab is already current, without touching the tab
    /// set - used when a host's dedicated page is shown again after its one
    /// ssh tab was already opened by an earlier `connectSSHIfNeeded` call.
    func focusCurrentTab() {
        guard let tab = currentTab else { return }
        view.window?.makeFirstResponder(tab.terminal)
    }

    /// Start an ssh tab's process. If `keyID` names a saved key, it is resolved
    /// through the Keychain into a fresh temp `-i <path>` (`SSHKeyMaterializer`)
    /// - the Touch ID / passcode prompt happens inside that call. Any temp file
    /// from a previous start of this tab is cleaned up first, so reconnect never
    /// piles up scratch directories. A resolution failure (deleted key,
    /// cancelled prompt, Keychain error) does not block the connection - `ssh`
    /// still starts without `-i`, falling back to the system agent, with the
    /// error surfaced in the terminal so it is visible rather than silent.
    private func connectSSH(_ tab: TabModel, executable: String, hostArgs: [String], keyID: UUID?, startupSnippetID: UUID? = nil) {
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
        // No output filtering happens on this path: `startProcess` forks a
        // genuine PTY and every byte the host sends reaches the terminal
        // untouched (design report B1 "known hosts" - the interactive
        // "authenticity of host"/"REMOTE HOST IDENTIFICATION HAS CHANGED"
        // prompts render and are answerable here exactly as in Terminal.app,
        // since this is the same `startProcess` path the Shell tab already
        // uses, with no `-o StrictHostKeyChecking=...` override anywhere in
        // this app).
        tab.terminal.startProcess(
            executable: executable,
            args: args,
            environment: childEnvironment(),
            execName: nil,
            currentDirectory: shellCwd()
        )
        if let startupSnippetID {
            runStartupSnippet(startupSnippetID, in: tab)
        }
    }

    /// Best-effort startup snippet (B2/B5): "attach tmux, cd to the
    /// project" style commands a host wants run once its shell prompt is up.
    /// There is no reliable, protocol-level "the remote shell is now ready"
    /// signal to hook - the report is explicit that best-effort timing is
    /// fine for v1 - so this sends the snippet text after a fixed delay from
    /// process start, long enough for `ssh` to authenticate and the remote
    /// shell to print its prompt on a typical connection.
    private func runStartupSnippet(_ id: UUID, in tab: TabModel) {
        guard let snippet = snippetStore.snippet(id: id) else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak tab] in
            guard let tab, !tab.isClosing else { return }
            tab.terminal.send(txt: snippet.command + "\n")
        }
    }

    /// The Snippets panel's "Run" action (B2): send a snippet to whichever
    /// tab is currently in front. A no-op with no tabs, which cannot happen
    /// in practice (closing the last tab always opens a fresh one).
    func runSnippetInActiveTab(_ snippet: Snippet) {
        currentTab?.terminal.send(txt: snippet.command + "\n")
    }

    /// Delete a tab's materialized key scratch dir, if it has one. Called
    /// before every (re)start, on close, and on quit - never left for a crash
    /// to clean up.
    private func cleanupSSHKeyTempFile(_ tab: TabModel) {
        guard let path = tab.sshKeyTempPath else { return }
        SSHKeyMaterializer.cleanup(privateKeyPath: path)
        tab.sshKeyTempPath = nil
    }

    /// Set up a live session for `target` and attach `tab`'s terminal to it,
    /// on whichever backend firstmate itself resolves to right now
    /// (`FirstmateBackend.resolve()`, cockpit-mirror-herdr-aware) - tmux's
    /// read-only `TmuxMirror` (unchanged, tab named "Mirror") or herdr's
    /// real-attach `HerdrMirror` (fm/cockpit-mirror-herdr-real-attach, tab
    /// named "Herdr" - see `TabLaunch.defaultName`). On failure the error is
    /// written into the terminal so it is visible rather than silent.
    private func connectMirror(_ tab: TabModel, target: String) {
        switch FirstmateBackend.resolve() {
        case .tmux:
            switch TmuxMirror.setUp(target: target) {
            case .success(let m):
                tab.mirror = .tmux(m)
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
        case .herdr:
            switch HerdrMirror.setUp(target: target) {
            case .success(let m):
                tab.mirror = .herdr(m)
                // A real `herdr session attach` client is launched from the
                // firstmate home (not `shellCwd()`, which follows the
                // captain's own Settings/`FM_SHELL_CWD` preference for
                // *shell* tabs) - captain's explicit call, since this tab is
                // attaching to firstmate's own herdr session, not opening a
                // general-purpose shell.
                tab.terminal.startProcess(
                    executable: m.attachExecutable,
                    args: m.attachArgs,
                    environment: childEnvironment(),
                    execName: nil,
                    currentDirectory: FirstmateHome.root.path
                )
            case .failure(let err):
                tab.mirror = nil
                tab.terminal.feed(text: "\r\n  \u{1b}[2m[herdr]\u{1b}[0m \(err.message)\r\n")
                tab.terminal.feed(text: "  \u{1b}[2mSet FM_MIRROR_TARGET to a live herdr session, then press ⌘R to reconnect.\u{1b}[0m\r\n")
            }
        }
    }

    // MARK: SRE Lead (design brief: Part B session lifecycle + Part C pane)

    private func buildSRELeadPane() {
        sreLeadPane.translatesAutoresizingMaskIntoConstraints = false
        sreLeadPane.wantsLayer = true
        sreLeadPane.clipsToBounds = true

        sreLeadPaneSeparator.translatesAutoresizingMaskIntoConstraints = false
        sreLeadPaneSeparator.wantsLayer = true
        sreLeadPane.addSubview(sreLeadPaneSeparator)

        sreLeadHeader.translatesAutoresizingMaskIntoConstraints = false
        sreLeadHeader.wantsLayer = true
        sreLeadPane.addSubview(sreLeadHeader)

        sreLeadHeaderLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        sreLeadHeaderLabel.translatesAutoresizingMaskIntoConstraints = false
        sreLeadHeader.addSubview(sreLeadHeaderLabel)

        NSLayoutConstraint.activate([
            sreLeadPaneSeparator.leadingAnchor.constraint(equalTo: sreLeadPane.leadingAnchor),
            sreLeadPaneSeparator.topAnchor.constraint(equalTo: sreLeadPane.topAnchor),
            sreLeadPaneSeparator.bottomAnchor.constraint(equalTo: sreLeadPane.bottomAnchor),
            sreLeadPaneSeparator.widthAnchor.constraint(equalToConstant: 1),

            sreLeadHeader.leadingAnchor.constraint(equalTo: sreLeadPaneSeparator.trailingAnchor),
            sreLeadHeader.trailingAnchor.constraint(equalTo: sreLeadPane.trailingAnchor),
            sreLeadHeader.topAnchor.constraint(equalTo: sreLeadPane.topAnchor),
            sreLeadHeader.heightAnchor.constraint(equalToConstant: 32),

            sreLeadHeaderLabel.leadingAnchor.constraint(equalTo: sreLeadHeader.leadingAnchor, constant: 12),
            sreLeadHeaderLabel.centerYAnchor.constraint(equalTo: sreLeadHeader.centerYAnchor),
        ])
    }

    /// The toolbar pill's click action. Dedups exactly like
    /// `connectSSHIfNeeded`'s `tabs.isEmpty` guard dedups a host reconnect:
    /// a click while a spawn is already in flight (`.starting`) is ignored
    /// rather than racing a second `SRELead.setUp`.
    @objc private func toggleSRELead() {
        switch sreLeadPhase {
        case .starting:
            return
        case .ready:
            tearDownSRELead()
        case .notStarted, .failed:
            startSRELead()
        }
    }

    private func startSRELead() {
        guard let context = sreLeadHostContext else { return }
        sreLeadPhase = .starting
        sreLeadButton?.setState(.starting)
        sreLeadButton?.applyTheme(theme)
        setSRELeadPaneOpen(true)

        let hostArgs = context.hostArgs
        let keyID = context.keyID
        let becomeUser = context.becomeUser
        let keyStore = self.keyStore
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = SRELead.setUp(hostArgs: hostArgs, keyID: keyID, keyStore: keyStore, becomeUser: becomeUser)
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .success(let session):
                    self.sreLeadSession = session
                    self.attachSRELeadTerminal(to: session)
                case .failure(let error):
                    self.sreLeadPhase = .failed
                    self.sreLeadButton?.setState(.failed)
                    self.sreLeadButton?.applyTheme(self.theme)
                    self.showSRELeadError(error.message)
                }
            }
        }
    }

    private func attachSRELeadTerminal(to session: SRELeadSession) {
        let term = sreLeadTerminal ?? makeSRELeadTerminal()
        sreLeadTerminal = term
        switch TmuxMirror.setUp(target: session.tmuxSessionName) {
        case .success(let mirror):
            sreLeadMirror = mirror
            term.startProcess(
                executable: mirror.tmuxPath, args: mirror.attachArgs,
                environment: childEnvironment(), execName: nil, currentDirectory: shellCwd()
            )
            sreLeadPhase = .ready
            sreLeadButton?.setState(.ready)
            sreLeadButton?.applyTheme(theme)
        case .failure(let err):
            sreLeadPhase = .failed
            sreLeadButton?.setState(.failed)
            sreLeadButton?.applyTheme(theme)
            showSRELeadError(err.message)
        }
    }

    private func showSRELeadError(_ message: String) {
        let term = sreLeadTerminal ?? makeSRELeadTerminal()
        sreLeadTerminal = term
        term.feed(text: "\r\n  \u{1b}[2m[SRE Lead]\u{1b}[0m \(message)\r\n")
    }

    /// Toggle-close (design brief Part B): kill the tmux session + `claude`
    /// process and remove every scratch file `SRELead.setUp` wrote, exactly
    /// like `TmuxMirror.tearDown()`/`cleanupSSHKeyTempFile` do for a regular
    /// tab - nothing lingers. A later toggle-open starts a genuinely fresh
    /// session rather than reattaching to anything.
    private func tearDownSRELead() {
        sreLeadMirror?.tearDown()
        sreLeadMirror = nil
        sreLeadTerminal?.terminate()
        sreLeadTerminal?.removeFromSuperview()
        sreLeadTerminal = nil
        sreLeadSession?.tearDown()
        sreLeadSession = nil
        sreLeadPhase = .notStarted
        sreLeadButton?.setState(.notStarted)
        sreLeadButton?.applyTheme(theme)
        setSRELeadPaneOpen(false)
    }

    private func makeSRELeadTerminal() -> CockpitTerminalView {
        let term = CockpitTerminalView(frame: .zero)
        term.translatesAutoresizingMaskIntoConstraints = false
        term.processDelegate = self
        term.font = currentFont()
        term.terminal?.changeScrollback(scrollbackLines)
        sreLeadPane.addSubview(term)
        NSLayoutConstraint.activate([
            term.leadingAnchor.constraint(equalTo: sreLeadPane.leadingAnchor),
            term.trailingAnchor.constraint(equalTo: sreLeadPane.trailingAnchor),
            term.topAnchor.constraint(equalTo: sreLeadHeader.bottomAnchor),
            term.bottomAnchor.constraint(equalTo: sreLeadPane.bottomAnchor),
        ])
        theme.apply(to: term)
        return term
    }

    private func setSRELeadPaneOpen(_ open: Bool) {
        sreLeadPaneWidthConstraint.constant = open ? sreLeadPaneWidth : 0
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            ctx.allowsImplicitAnimation = true
            view.layoutSubtreeIfNeeded()
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
        tab.terminal.stopLogging()
        tab.terminal.terminate()
        tab.terminal.removeFromSuperview()
        tabs.remove(at: idx)

        // Last-tab edge case. The shared Firstmate console never leaves the
        // window empty - open a fresh shell. A dedicated host page (Fix 1)
        // is allowed to end up with zero tabs: falling back to a generic
        // shell tab here would leave `tabs` non-empty, which would make
        // `connectSSHIfNeeded`'s `tabs.isEmpty` guard think this host is
        // still connected and permanently skip reopening it.
        if tabs.isEmpty {
            if isFirstmateConsole {
                newShellTab()
            } else {
                currentTab = nil
                refreshTabBar()
            }
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
        updateLogButton()
        if focus { view.window?.makeFirstResponder(tab.terminal) }
    }

    // MARK: Theme

    @objc func toggleTheme() {
        ThemeManager.shared.toggle()
        // `applyTheme()` runs via the `observe` callback registered in
        // `loadView`, so nothing else is needed here.
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
        updateLogButton()

        sreLeadButton?.applyTheme(theme)
        sreLeadPane.layer?.backgroundColor = HelmTheme.nsColor(theme.backgroundHex).cgColor
        sreLeadPaneSeparator.layer?.backgroundColor = line.cgColor
        sreLeadHeader.layer?.backgroundColor = chromeBg.cgColor
        sreLeadHeaderLabel.textColor = ink
        if let term = sreLeadTerminal { theme.apply(to: term) }
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

    /// The Settings panel's font-size stepper (Fix 3) - same clamping and
    /// persistence as the toolbar/menu zoom actions above.
    func stepFontSize(by delta: CGFloat) { setFontSize(fontSize + delta) }
    var currentFontSize: CGFloat { fontSize }

    private func setFontSize(_ size: CGFloat) {
        fontSize = min(maxFont, max(minFont, size))
        AppSettings.shared.fontSize = fontSize
        let f = currentFont()
        for tab in tabs { tab.terminal.font = f }
    }

    // MARK: Session logging (B5)

    /// ⌘⇧L / the toolbar icon: toggle a plain-text transcript of the active
    /// tab's host output. Off -> on opens a fresh timestamped file; on -> off
    /// just closes it - a later toggle back on starts a new file rather than
    /// appending to the old one, so each "recording" is its own transcript.
    @objc func toggleLoggingForActiveTab() {
        guard let tab = currentTab else { return }
        if tab.terminal.isLogging {
            tab.terminal.stopLogging()
        } else {
            startLogging(tab)
        }
        updateLogButton()
    }

    /// `~/Library/Application Support/FirstmateCockpit/logs/<tab>-<timestamp>.log`.
    /// Best-effort: a failure (unwritable disk, sandboxing) is surfaced in the
    /// terminal rather than silently discarding the toggle.
    private func startLogging(_ tab: TabModel) {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("FirstmateCockpit", isDirectory: true)
            .appendingPathComponent("logs", isDirectory: true)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let slug = tab.name.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }
        let fileName = "\(String(slug))-\(formatter.string(from: Date())).log"
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try tab.terminal.startLogging(to: dir.appendingPathComponent(fileName))
        } catch {
            tab.terminal.feed(text: "\r\n  \u{1b}[2m[session log]\u{1b}[0m \(error.localizedDescription)\r\n")
        }
    }

    /// Restyle the toolbar icon for the active tab's current logging state -
    /// filled and red while recording, outline and theme-tinted otherwise.
    private func updateLogButton() {
        let isLogging = currentTab?.terminal.isLogging ?? false
        logButton.image = NSImage(
            systemSymbolName: isLogging ? "record.circle.fill" : "record.circle",
            accessibilityDescription: "Session Log"
        )
        logButton.contentTintColor = isLogging ? .systemRed : HelmTheme.nsColor(theme.chromeInkHex)
        logButton.toolTip = isLogging ? "Stop Session Log (⌘⇧L)" : "Log This Session (⌘⇧L)"
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
        case .ssh(_, let exe, let hostArgs, let keyID, let startupSnippetID):
            connectSSH(tab, executable: exe, hostArgs: hostArgs, keyID: keyID, startupSnippetID: startupSnippetID)
        }
        view.window?.makeFirstResponder(tab.terminal)
    }

    /// Tear down every mirror's grouped session, every materialized ssh key
    /// temp file, every open session log, and the theme observer registered
    /// in `loadView` - so nothing is left dangling. Called from the app
    /// delegate on quit for the shared Firstmate console, and (Fix 1) from
    /// `AppShellController.removeHostConsole` when a host's dedicated page
    /// is torn down mid-session, which is why unregistering the theme
    /// observer here (not just at quit) matters.
    func shutdown() {
        for tab in tabs {
            tab.mirror?.tearDown()
            tab.mirror = nil
            cleanupSSHKeyTempFile(tab)
            tab.terminal.stopLogging()
        }
        // Host-page disconnect (design brief Part B) - tear down the SRE
        // Lead session the same way `tearDownSRELead()` does, just without
        // the pane-close animation since this whole page may be on its way
        // out already (a deleted host's page via
        // `AppShellController.removeHostConsole`).
        sreLeadMirror?.tearDown()
        sreLeadMirror = nil
        sreLeadSession?.tearDown()
        sreLeadSession = nil
        if let themeObservation {
            ThemeManager.shared.unobserve(themeObservation)
            self.themeObservation = nil
        }
    }

    // MARK: Window title

    private func updateWindowTitle(from tab: TabModel) {
        view.window?.title = "Manjesh Grand Line - \(tab.name)"
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
    ///
    /// Settings > Terminal's "Reconnect automatically" (Fix 3): when on, this
    /// also schedules a real reconnect of the same tab after a short delay
    /// (mirroring `reconnectActive()`'s per-launch-kind restart), instead of
    /// only showing the hint and waiting for ⌘R.
    ///
    /// A one-shot command tab (`openCommandTab`, e.g. Bootstrap's
    /// `rebuild.sh`) is never auto-reconnected here, regardless of the
    /// setting above or the exit code - it ran a provisioning command to
    /// completion, not a shell that dropped, and re-running it would repeat
    /// side effects (and re-prompt for `sudo`) forever. Captain-reproduced:
    /// a successful `rebuild.sh` exit used to be treated like a dropped
    /// shell, restarting the whole `darwin-rebuild switch` every 2 seconds.
    func processTerminated(source: TerminalView, exitCode: Int32?) {
        if source === sreLeadTerminal {
            // The SRE Lead mirror (or the `claude` process behind it) ended
            // unexpectedly - reset to a torn-down state so the pill reflects
            // reality and a re-click starts a genuinely fresh session
            // rather than reattaching to a dead one.
            tearDownSRELead()
            return
        }
        guard let tab = tabs.first(where: { $0.terminal === source }) else { return }
        if tab.isClosing { return }
        tab.mirror?.tearDown()
        tab.mirror = nil
        cleanupSSHKeyTempFile(tab)
        let code = exitCode.map { " (exit \($0))" } ?? ""

        if tab.isOneShotCommand {
            let outcome = (exitCode == 0) ? "finished\(code)" : "failed\(code)"
            source.feed(text: "\r\n  \u{1b}[2m[\(outcome)]\u{1b}[0m\r\n")
            tab.onOneShotCompletion?(exitCode)
            return
        }

        let hint = AppSettings.shared.autoReconnect ? "reconnecting…" : "press ⌘R to reconnect"
        source.feed(text: "\r\n  \u{1b}[2m[process ended\(code) - \(hint)]\u{1b}[0m\r\n")

        if AppSettings.shared.autoReconnect {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self, weak tab] in
                guard let self, let tab, !tab.isClosing, self.tabs.contains(where: { $0 === tab }) else { return }
                self.startTab(tab)
            }
        }
    }
}
