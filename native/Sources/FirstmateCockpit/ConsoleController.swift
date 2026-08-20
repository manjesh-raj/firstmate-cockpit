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

    /// `fm/grandline-notification-center`: fired when an SRE Lead reply
    /// lands on a tab that isn't the one currently visible to the captain
    /// (a different tab selected, or this whole host page not the currently
    /// shown destination). `AppShellController.connectHost` wires this to
    /// build the in-app notification and its own navigate-back-to-this-tab
    /// closure - this controller only reports the event, it doesn't know
    /// about rail destinations or other host pages.
    var onSRELeadReplyWhileBackground: ((TabModel) -> Void)?

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
    /// Mirrors `FontSizeManager.shared.size` (`fm/cockpit-tools-page-ui-polish`) -
    /// same "local var kept live via `observe`" convention as `theme` above,
    /// so every open tab's font stays in sync with Settings' presets and the
    /// Tools page's own monospace text, regardless of which one changed it.
    private var fontSize: CGFloat = FontSizeManager.shared.size

    private func currentFont() -> NSFont {
        NSFont(name: "Menlo", size: fontSize)
            ?? .monospacedSystemFont(ofSize: fontSize, weight: .regular)
    }

    // MARK: Chrome views

    /// The shared page toolbar (Phase 7, audit §3.2's "Page toolbars"). This
    /// bar used to be a hand-rolled 42pt `NSView` with its own separator, and
    /// Tools' own comment said it was a copy of this one - `HelmPageToolbar`
    /// is now the single definition of the height, fill, hairline and insets
    /// for all three pages that have such a bar.
    private let tabBar = HelmPageToolbar()
    private let content = NSView()
    private let tabsStack = NSStackView()
    /// Every toolbar glyph is a bordered icon square now
    /// (`HelmPageToolbar.iconButton`, i.e. `HelmButton(.secondary)`), not a
    /// bare borderless image button. That was the audit's "two icon-button
    /// languages, 40pt apart" finding: the app top bar renders its icons as
    /// bordered squares, and this bar - one bar below it - rendered up to
    /// eleven chrome-less glyphs at identical weight.
    ///
    /// Typed `HelmButton` rather than `NSButton` specifically so the two
    /// state-coloured glyphs below can set `tint` (see `updateLogButton` /
    /// `updateBlockViewControls`). `HelmButton.restyle()` owns
    /// `contentTintColor`, so assigning that directly would be silently
    /// overwritten on the next theme change - `tint` is the seam.
    private var plusButton: HelmButton!
    private var themeButton: HelmButton!
    private var findButton: HelmButton!
    private var zoomInButton: HelmButton!
    private var zoomOutButton: HelmButton!
    private var logButton: HelmButton!
    /// `fm/cockpit-block-view-stage0` - only ever shown for the one opted-in
    /// host's tab, see `updateBlockViewControls`.
    private var blockViewToggleButton: HelmButton!
    private var blockViewRefreshButton: HelmButton!
    /// Phase 3 of "Knowledge and speed" (`fm/grandline-console-command-
    /// composer`) - only ever shown for a plain `.shell` tab that isn't a
    /// one-shot command, see `updateComposeControls`.
    private var composeButton: HelmButton!
    private let composer = ConsoleComposerController()
    /// `fm/grandline-herdr-utilization-panel` - only ever shown for a
    /// Herdr-backed `.mirror` tab, the opposite gating of `composeButton`
    /// above (see `updateUtilizationControls`), so the two never fight for
    /// the same toolbar slot on the same tab.
    private var utilizationButton: HelmButton!
    private let quotaUsage = QuotaUsageController()

    // MARK: SRE Lead (dedicated host pages only - see `SRELead.swift`)

    /// `fm/grandline-sre-lead-per-tab`: SRE Lead's own state (session,
    /// bridge, runner, chat, phase) lives on each `TabModel.sreLead`, not
    /// here - see `SRELeadTabState.swift`'s header. `ConsoleController` only
    /// owns the shared chrome: the pill, the pane, and the header - every
    /// started tab's chat is added as a hidden sibling inside `sreLeadPane`
    /// and shown/hidden to match whichever tab is currently selected
    /// (`updateSRELeadPaneContent`).
    private var sreLeadButton: SRELeadStatusPill?

    private let sreLeadPane = NSView()
    private let sreLeadPaneSeparator = NSView()
    private let sreLeadHeader = NSView()
    /// Separates the header bar from the body below it - needed once the
    /// pane's body switched from `backgroundHex` to `chromeBackgroundHex`
    /// (matching the header's own long-standing fill) so the two don't read
    /// as one indistinguishable block (`fm/grandline-sre-lead-polish`).
    private let sreLeadHeaderDivider = NSView()
    private let sreLeadHeaderLabel = NSTextField(labelWithString: "SRE Lead")
    /// "Generate Postmortem" (`fm/grandline-sre-lead-postmortem`) - hidden
    /// until `updateGeneratePostmortemButton()` sees a real assistant reply
    /// in the current tab's chat (see `SRELeadChatView.hasRealExchange`), so
    /// it never appears over an empty/just-opened session.
    private let sreLeadGeneratePostmortemButton = NSButton()
    /// Shown inside `sreLeadPane` whenever the currently selected tab has no
    /// `sreLead` state yet - "started, running, or not-yet-started, never
    /// another tab's" (design doc). Lets a captain start SRE Lead for
    /// whichever tab is on screen without reaching for the toolbar pill.
    private let sreLeadEmptyStateView = NSView()
    private let sreLeadEmptyStateLabel = NSTextField(wrappingLabelWithString: "SRE Lead hasn't been started for this tab yet.")
    private let sreLeadEmptyStateButton = HelmButton(title: "", variant: .primary)
    /// Only ever created on demand (`generatePostmortemClicked`) - a fresh
    /// `DocsRunbookStore()` shares `DocsRunbookGitSync.shared`'s singleton
    /// clone/queue exactly like `DocsController`'s own instance does (see
    /// that type's header), so this never opens a second clone of the repo.
    private lazy var docsRunbookStore = DocsRunbookStore()
    private var sreLeadPaneWidthConstraint: NSLayoutConstraint!
    private let sreLeadPaneWidth: CGFloat = 380

    /// Captain-specified cap (task brief): at most this many tabs on one
    /// host page may have SRE Lead running (`.starting`/`.ready`)
    /// simultaneously. Attempting to start a 6th shows a clear alert instead
    /// of silently queuing or silently refusing.
    private let sreLeadMaxConcurrent = 5

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

        // The one path that ever sends a composed command anywhere - see
        // `ConsoleComposerPopover.swift`'s header for why this is never
        // triggered automatically.
        composer.onRunInTerminal = { [weak self] command in
            self?.currentTab?.terminal.send(txt: command + "\n")
        }

        sreLeadPaneWidthConstraint = sreLeadPane.widthAnchor.constraint(equalToConstant: 0)

        NSLayoutConstraint.activate([
            tabBar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            tabBar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            tabBar.topAnchor.constraint(equalTo: root.topAnchor),

            // `content` (and therefore every tab's terminal inside it,
            // including the primary interactive tab SRE Lead's bridge
            // injects into) is pinned to the root's full width, never to
            // `sreLeadPane`'s leading edge. Opening/closing the SRE Lead
            // pane only changes `sreLeadPaneWidthConstraint` below - it used
            // to also resize `content` (trailing was pinned to
            // `sreLeadPane.leadingAnchor`), and any frame change on a
            // SwiftTerm view triggers `resize(cols:rows:)`, which reflows
            // the buffer at the new column count and can truncate/garble
            // scrollback the captain had already built up logging into a
            // bastion. The pane now overlays the right edge of `content`
            // (it's added after `content`, so it already renders on top)
            // instead of pushing it - a real width change on `content` only
            // ever happens from an actual window resize now, not from
            // toggling this pane.
            content.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: root.trailingAnchor),
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

        // Follow the shared font size (`fm/cockpit-tools-page-ui-polish`) the
        // same way - a per-host page can be torn down mid-session, so the
        // token is kept and unregistered in `shutdown()`, not discarded.
        fontSizeObservation = FontSizeManager.shared.observe { [weak self] size in
            guard let self else { return }
            self.fontSize = size
            let f = self.currentFont()
            for tab in self.tabs { tab.terminal.font = f }
        }
    }

    private var themeObservation: ThemeObservation?
    private var fontSizeObservation: FontSizeObservation?

    override func viewDidAppear() {
        super.viewDidAppear()
        hasAppeared = true
        for tab in tabs where !tab.started { startTab(tab) }
        if let tab = currentTab { view.window?.makeFirstResponder(tab.terminal) }
    }

    // MARK: Building the top bar

    private func buildTabBar() {
        view.addSubview(tabBar)

        tabsStack.orientation = .horizontal
        tabsStack.spacing = 4
        tabsStack.alignment = .centerY
        tabsStack.translatesAutoresizingMaskIntoConstraints = false
        tabBar.setLeading(tabsStack)

        plusButton = makeIconButton(symbol: "plus", tooltip: "New Shell Tab (⌘T)", action: #selector(newShellTab))

        findButton = makeIconButton(symbol: "magnifyingglass", tooltip: "Find (⌘F)", action: #selector(showFind))
        zoomOutButton = makeIconButton(symbol: "minus.magnifyingglass", tooltip: "Zoom Out (⌘−)", action: #selector(zoomOut))
        zoomInButton = makeIconButton(symbol: "plus.magnifyingglass", tooltip: "Zoom In (⌘+)", action: #selector(zoomIn))
        themeButton = makeIconButton(symbol: "circle.lefthalf.filled", tooltip: "Toggle Light/Dark (⌘⌥T)", action: #selector(toggleTheme))
        logButton = makeIconButton(symbol: "record.circle", tooltip: "Log This Session (⌘⇧L)", action: #selector(toggleLoggingForActiveTab))
        blockViewToggleButton = makeIconButton(symbol: "rectangle.grid.1x2", tooltip: "Show Parsed Blocks (Stage 0)", action: #selector(toggleBlockView))
        blockViewRefreshButton = makeIconButton(symbol: "arrow.clockwise", tooltip: "Refresh Blocks", action: #selector(refreshBlockView))
        composeButton = makeIconButton(symbol: "sparkles", tooltip: "Compose a command…", action: #selector(toggleComposer))
        utilizationButton = makeIconButton(symbol: quotaUsageGaugeSymbol, tooltip: "Claude usage", action: #selector(toggleUtilization))

        // SRE Lead (design brief Part C) and block view (`fm/cockpit-block-
        // view-stage0`) are both dedicated-host-page-only affordances - the
        // shared Firstmate console has no single host cluster to
        // investigate, and its Shell/Mirror tabs never get a block tracker
        // at all (see `TabModel.blockViewOptIn`) - a bug there took down the
        // whole app on every launch in the original PR #79/#80 attempt.
        var toolViews: [NSView] = []
        if !isFirstmateConsole {
            let pill = SRELeadStatusPill()
            pill.onClick = { [weak self] in self?.toggleSRELead() }
            sreLeadButton = pill
            toolViews.append(pill)
        }
        toolViews += [findButton, zoomOutButton, zoomInButton, themeButton]
        if !isFirstmateConsole {
            toolViews += [blockViewToggleButton, blockViewRefreshButton]
        }
        // Compose (phase 3, `fm/grandline-console-command-composer`) is
        // available on both the shared Firstmate console (its Shell tab is a
        // plain `.shell` launch too) and every dedicated host page - visibility
        // is per-tab (`updateComposeControls`), not per-console like SRE
        // Lead/block view above. `utilizationButton` (`fm/grandline-herdr-
        // utilization-panel`) sits in the same slot, gated the opposite way
        // (`updateUtilizationControls`) - the two are never both visible on
        // the same tab.
        toolViews.append(composeButton)
        toolViews.append(utilizationButton)
        toolViews.append(logButton)
        // `setTrailing` also installs the clearance inequality that keeps a
        // long tab strip truncating rather than running under the actions -
        // the constraint this method used to activate by hand.
        tabBar.setTrailing(HelmPageToolbar.group(toolViews))
    }

    private func makeIconButton(symbol: String, tooltip: String, action: Selector) -> HelmButton {
        HelmPageToolbar.iconButton(symbol: symbol, tooltip: tooltip, target: self, action: action)
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

    /// Finding 6 (cockpit-audit-core, captain decision): port the Tools
    /// page's numbered-disambiguation convention into Console - bare kind
    /// name for the first currently-open tab of a kind, "N" appended for
    /// each subsequent concurrent one (e.g. "Shell 2", "myhost 3"), counting
    /// only tabs currently open (never a running total), so closing "Shell 2"
    /// and opening a new shell reuses that name rather than climbing to
    /// "Shell 3".
    private func numberedName(for launch: TabLaunch) -> String {
        let bare = launch.defaultName
        let kind = launch.kindIdentity
        let existing = tabs.filter { $0.launch.kindIdentity == kind }.count
        return existing == 0 ? bare : "\(bare) \(existing + 1)"
    }

    /// Add a tab for `launch`, build its chip, and (if the view is already on
    /// screen) start its process. Returns the new tab. `blockViewOptIn` is
    /// `fm/cockpit-block-view-stage0`'s single-host gate - `true` only for
    /// the one saved host whose `Host.blockViewOptIn` is set, threaded down
    /// from `AppShellController.connectHost` through `connectSSHIfNeeded`/
    /// `openSSH`; every other caller (⌘T, ⌘D, the Firstmate console's
    /// Shell/Mirror pair, an ad-hoc quick-connect with no saved `Host`)
    /// leaves it at the default `false`.
    @discardableResult
    private func addTab(launch: TabLaunch, name: String, select: Bool, accentHex: String? = nil, isOneShotCommand: Bool = false, blockViewOptIn: Bool = false) -> TabModel {
        let term = makeTerminal()
        let tab = TabModel(name: name, launch: launch, terminal: term, accentHex: accentHex)
        tab.isOneShotCommand = isOneShotCommand

        // `fm/cockpit-block-view-stage0`: only ever true for an `.ssh` tab on
        // the one opted-in host, and only when the whole feature is enabled
        // (`BlockViewFeature.isEnabled`) - see `TabModel.blockViewOptIn`'s
        // doc comment for why this is narrower than both prior attempts.
        // Created up front (not lazily on first display) so the tracker is
        // already accumulating blocks the instant the captain looks at the
        // block-view panel, and torn down explicitly in `closeTab`.
        if case .ssh = launch, blockViewOptIn, BlockViewFeature.isEnabled, let terminal = term.terminal {
            tab.blockViewOptIn = true
            let tracker = TerminalBlockTracker()
            tracker.attach(to: terminal)
            tab.blockTracker = tracker

            let container = BlockContainerView(frame: .zero)
            container.applyTheme(theme)
            container.isHidden = true
            content.addSubview(container)
            NSLayoutConstraint.activate([
                container.leadingAnchor.constraint(equalTo: content.leadingAnchor),
                container.trailingAnchor.constraint(equalTo: content.trailingAnchor),
                container.topAnchor.constraint(equalTo: content.topAnchor),
                container.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            ])
            tab.blockContainer = container
        }

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

    /// Start (or restart) a tab's child process from its launch spec. This
    /// is the path both a first-ever start (`addTab`) AND an automatic
    /// reconnect (`processTerminated`'s `AppSettings.shared.autoReconnect`
    /// timer) go through - `restartTabBookkeeping` below is called from
    /// exactly here and from `reconnectActive` (the manual ⌘R path), so both
    /// "a process just (re)started" cases share one bookkeeping step. See
    /// `restartTabBookkeeping`'s own doc comment for why this unification
    /// exists.
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
        case .mirror(let kind, let target):
            connectMirror(tab, kind: kind, target: target)
        case .ssh(_, let exe, let hostArgs, let keyID, let startupSnippetID):
            connectSSH(tab, executable: exe, hostArgs: hostArgs, keyID: keyID, startupSnippetID: startupSnippetID)
        }
        tab.started = true
        if defaultLoggingEnabled { startLogging(tab) }
        restartTabBookkeeping(tab)
    }

    /// `fm/cockpit-block-view-stage0`: the one entry point for "a tab's
    /// process just (re)started" bookkeeping, called from both `startTab`
    /// (covering the very first start AND `processTerminated`'s automatic-
    /// reconnect timer, since that timer calls `startTab` directly) and
    /// `reconnectActive` (the manual ⌘R path, which restarts a process
    /// through a different switch over `tab.launch` and never calls
    /// `startTab` itself).
    ///
    /// This exists because of a structural gap the scout report
    /// (`data/cockpit-block-view-scout/report.md`, "Mechanism A") found in
    /// the previous attempt: `reconnectActive` explicitly reset the block
    /// tracker after restarting, but `processTerminated`'s auto-reconnect
    /// timer called `startTab` directly and `startTab` never reset anything -
    /// so a real network drop with a command mid-flight left a permanently
    /// "running" block from the dead session, and the *next* session's
    /// output could bleed into that stale block's text once the tracker's
    /// stale buffer snapshot diverged from the new session's buffer. Stage 0
    /// avoids that class of bug by construction rather than by remembering
    /// to call `reset()` in two places that have to stay in sync: there is
    /// exactly one place a restart's bookkeeping is defined, and every
    /// restart path is required to call it - a future addition to this
    /// bookkeeping can't be added to only one of the two paths again, since
    /// there is only one path to add it to.
    private func restartTabBookkeeping(_ tab: TabModel) {
        tab.blockTracker?.reset()
        tab.blockContainer?.clear()
        installShellIntegrationIfSupported(tab)
    }

    /// `fm/cockpit-block-view-stage0`: best-effort, same timing convention as
    /// `runStartupSnippet` - there is no protocol-level "the shell is ready"
    /// signal, so this sends the hook after a fixed delay long enough for
    /// the remote SSH session (authentication + remote prompt) to be sitting
    /// at a real prompt. A no-op unless this tab has a block tracker at all
    /// (i.e. `blockViewOptIn && BlockViewFeature.isEnabled` at tab-creation
    /// time - see `addTab`) and for a one-shot provisioning command
    /// (`isOneShotCommand`), neither of which is an interactive prompt cycle
    /// this hook has anything to attach to.
    private func installShellIntegrationIfSupported(_ tab: TabModel) {
        guard tab.blockTracker != nil, !tab.isOneShotCommand else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self, weak tab] in
            guard let self, let tab else { return }
            self.sendShellIntegrationLines(ShellIntegration.installSequence, to: tab)
        }
    }

    /// Sends `ShellIntegration.installSequence` one line at a time, each
    /// after the previous, rather than as one concatenated blob.
    ///
    /// `fm/cockpit-fix-block-view-stage0-bugs`: verified live (pty-based
    /// repro, see this task's PR description) that this genuinely needs to
    /// be paced, not just ordered - with zsh's line editor (ZLE) disabled
    /// (part of this sequence's own echo-suppression trick, see
    /// `ShellIntegration.swift`'s header), sending every line back-to-back
    /// with no gap at all made zsh's parser lose track of line boundaries
    /// entirely (it read the whole blob as one unterminated multi-line
    /// double-quoted string, dropping into a `dquote>` continuation prompt
    /// and never running anything) - reproduced consistently at a 0ms gap,
    /// gone at every gap tested down to 20ms. 120ms per line (a handful of
    /// lines, so under half a second in total - negligible next to the
    /// existing 1.5s post-connect delay above) is a comfortable margin
    /// above that, not a tuned-to-the-edge minimum.
    private func sendShellIntegrationLines(_ lines: [String], to tab: TabModel) {
        guard !lines.isEmpty else { return }
        guard !tab.isClosing else { return }
        tab.terminal.send(txt: lines[0])
        let remaining = Array(lines.dropFirst())
        guard !remaining.isEmpty else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self, weak tab] in
            guard let self, let tab else { return }
            self.sendShellIntegrationLines(remaining, to: tab)
        }
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
        //
        // `fm/grandline-mirror-resolve-race-fix`: kind and target come from
        // one atomic call, never a separate `mirrorTarget()`/`resolve()`
        // pair - see `FirstmateBackend.resolveMirrorTarget()`'s doc comment.
        let resolution = FirstmateBackend.resolveMirrorTarget()
        let mirror = TabLaunch.mirror(kind: resolution.kind, target: resolution.target)
        addTab(launch: mirror, name: numberedName(for: mirror), select: false)
        let s = shellArgv()
        let shell = TabLaunch.shell(executable: s.executable, args: s.args, cwd: shellCwd())
        let shellTab = addTab(launch: shell, name: numberedName(for: shell), select: false)
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
    /// set, is sent into the shell once the session looks ready. `blockViewOptIn`
    /// (`fm/cockpit-block-view-stage0`) defaults `false` - only
    /// `connectSSHIfNeeded` (a saved host's dedicated page) ever passes
    /// `true`, and only for the one host whose `Host.blockViewOptIn` is set;
    /// an ad-hoc quick-connect has no `Host` to read that flag from at all.
    func openSSH(label: String, args: [String], accentHex: String?, keyID: UUID?, startupSnippetID: UUID? = nil, blockViewOptIn: Bool = false) {
        let launch = TabLaunch.ssh(
            label: label, executable: HostCatalog.sshExecutable, hostArgs: args,
            keyID: keyID, startupSnippetID: startupSnippetID
        )
        addTab(launch: launch, name: numberedName(for: launch), select: true, accentHex: accentHex, blockViewOptIn: blockViewOptIn)
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
    func connectSSHIfNeeded(label: String, args: [String], accentHex: String?, keyID: UUID?, startupSnippetID: UUID?, blockViewOptIn: Bool = false) {
        guard tabs.isEmpty else { return }
        openSSH(label: label, args: args, accentHex: accentHex, keyID: keyID, startupSnippetID: startupSnippetID, blockViewOptIn: blockViewOptIn)
        // `fm/grandline-sre-lead-per-tab`: no `primarySSHTab` to set anymore -
        // SRE Lead is per-tab now (`TabModel.sreLead`), started explicitly by
        // the captain for whichever tab they're looking at, never pinned to
        // "the first ssh tab this page ever opened".
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

    /// The DevOps Command Library's "Send to Terminal" action (fm/grandline-
    /// devops-command-library-phase2) - same shape as `runSnippetInActiveTab`
    /// above, since it's the identical "type this into whichever tab is
    /// currently in front" behavior, just for an already-substituted command
    /// string instead of a saved `Snippet`.
    func sendCommandLibraryTextToActiveTab(_ text: String) {
        currentTab?.terminal.send(txt: text + "\n")
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
    /// on `kind` - tmux's read-only `TmuxMirror` (unchanged, tab named
    /// "Mirror") or herdr's real-attach `HerdrMirror`
    /// (fm/cockpit-mirror-herdr-real-attach, tab named "Herdr" - see
    /// `TabLaunch.defaultName`). On failure the error is written into the
    /// terminal so it is visible rather than silent.
    ///
    /// `kind` and `target` are always the pair frozen into `tab.launch` by
    /// `FirstmateBackend.resolveMirrorTarget()` at tab-creation time - this
    /// method deliberately does NOT call `FirstmateBackend.resolve()` again
    /// itself (`fm/grandline-mirror-resolve-race-fix`; see that function's
    /// doc comment for the two-independent-calls race this replaces).
    private func connectMirror(_ tab: TabModel, kind: FirstmateBackendKind, target: String) {
        switch kind {
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

    // MARK: SRE Lead (`fm/grandline-sre-lead-per-tab`: per-tab state on
    // `TabModel.sreLead` - see `SRELeadTabState.swift`'s header. This
    // section owns only the shared chrome: the pill, the pane, the header,
    // and the empty state - every method below operates on a specific
    // `TabModel`, never a page-level phase.

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

        sreLeadHeaderDivider.translatesAutoresizingMaskIntoConstraints = false
        sreLeadHeaderDivider.wantsLayer = true
        sreLeadPane.addSubview(sreLeadHeaderDivider)

        sreLeadHeaderLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        sreLeadHeaderLabel.translatesAutoresizingMaskIntoConstraints = false
        sreLeadHeader.addSubview(sreLeadHeaderLabel)

        sreLeadGeneratePostmortemButton.translatesAutoresizingMaskIntoConstraints = false
        sreLeadGeneratePostmortemButton.title = ""
        sreLeadGeneratePostmortemButton.isBordered = false
        sreLeadGeneratePostmortemButton.wantsLayer = true
        sreLeadGeneratePostmortemButton.toolTip = "Generate Postmortem"
        sreLeadGeneratePostmortemButton.image = NSImage(systemSymbolName: "doc.badge.plus", accessibilityDescription: "Generate Postmortem")
        sreLeadGeneratePostmortemButton.imageScaling = .scaleProportionallyDown
        sreLeadGeneratePostmortemButton.target = self
        sreLeadGeneratePostmortemButton.action = #selector(generatePostmortemClicked)
        sreLeadGeneratePostmortemButton.isHidden = true
        sreLeadHeader.addSubview(sreLeadGeneratePostmortemButton)

        NSLayoutConstraint.activate([
            sreLeadPaneSeparator.leadingAnchor.constraint(equalTo: sreLeadPane.leadingAnchor),
            sreLeadPaneSeparator.topAnchor.constraint(equalTo: sreLeadPane.topAnchor),
            sreLeadPaneSeparator.bottomAnchor.constraint(equalTo: sreLeadPane.bottomAnchor),
            // Widened from the original 1pt and re-tinted with the theme's
            // accent color (was `chromeLineHex`) so the terminal/pane
            // boundary reads as a deliberate, unmissable seam in every Helm
            // theme, not a hairline easy to miss (`fm/grandline-sre-lead-polish`).
            sreLeadPaneSeparator.widthAnchor.constraint(equalToConstant: 3),

            sreLeadHeader.leadingAnchor.constraint(equalTo: sreLeadPaneSeparator.trailingAnchor),
            sreLeadHeader.trailingAnchor.constraint(equalTo: sreLeadPane.trailingAnchor),
            sreLeadHeader.topAnchor.constraint(equalTo: sreLeadPane.topAnchor),
            sreLeadHeader.heightAnchor.constraint(equalToConstant: 32),

            sreLeadHeaderDivider.leadingAnchor.constraint(equalTo: sreLeadPaneSeparator.trailingAnchor),
            sreLeadHeaderDivider.trailingAnchor.constraint(equalTo: sreLeadPane.trailingAnchor),
            sreLeadHeaderDivider.topAnchor.constraint(equalTo: sreLeadHeader.bottomAnchor),
            sreLeadHeaderDivider.heightAnchor.constraint(equalToConstant: 1),

            sreLeadHeaderLabel.leadingAnchor.constraint(equalTo: sreLeadHeader.leadingAnchor, constant: 12),
            sreLeadHeaderLabel.centerYAnchor.constraint(equalTo: sreLeadHeader.centerYAnchor),

            sreLeadGeneratePostmortemButton.trailingAnchor.constraint(equalTo: sreLeadHeader.trailingAnchor, constant: -10),
            sreLeadGeneratePostmortemButton.centerYAnchor.constraint(equalTo: sreLeadHeader.centerYAnchor),
            sreLeadGeneratePostmortemButton.widthAnchor.constraint(equalToConstant: 22),
            sreLeadGeneratePostmortemButton.heightAnchor.constraint(equalToConstant: 22),
        ])

        buildSRELeadEmptyState()
    }

    private func buildSRELeadEmptyState() {
        sreLeadEmptyStateView.translatesAutoresizingMaskIntoConstraints = false
        sreLeadEmptyStateView.wantsLayer = true
        sreLeadEmptyStateView.isHidden = true
        sreLeadPane.addSubview(sreLeadEmptyStateView)

        sreLeadEmptyStateLabel.font = .systemFont(ofSize: 12)
        sreLeadEmptyStateLabel.alignment = .center
        sreLeadEmptyStateLabel.lineBreakMode = .byWordWrapping
        sreLeadEmptyStateLabel.maximumNumberOfLines = 0
        sreLeadEmptyStateLabel.translatesAutoresizingMaskIntoConstraints = false
        sreLeadEmptyStateView.addSubview(sreLeadEmptyStateLabel)

        sreLeadEmptyStateButton.title = "Start SRE Lead for This Tab"
        sreLeadEmptyStateButton.controlSize = .small
        sreLeadEmptyStateButton.target = self
        sreLeadEmptyStateButton.action = #selector(startSRELeadForCurrentTabClicked)
        sreLeadEmptyStateButton.translatesAutoresizingMaskIntoConstraints = false
        sreLeadEmptyStateView.addSubview(sreLeadEmptyStateButton)

        NSLayoutConstraint.activate([
            sreLeadEmptyStateView.leadingAnchor.constraint(equalTo: sreLeadPaneSeparator.trailingAnchor),
            sreLeadEmptyStateView.trailingAnchor.constraint(equalTo: sreLeadPane.trailingAnchor),
            sreLeadEmptyStateView.topAnchor.constraint(equalTo: sreLeadHeaderDivider.bottomAnchor),
            sreLeadEmptyStateView.bottomAnchor.constraint(equalTo: sreLeadPane.bottomAnchor),

            sreLeadEmptyStateLabel.leadingAnchor.constraint(equalTo: sreLeadEmptyStateView.leadingAnchor, constant: 20),
            sreLeadEmptyStateLabel.trailingAnchor.constraint(equalTo: sreLeadEmptyStateView.trailingAnchor, constant: -20),
            sreLeadEmptyStateLabel.centerYAnchor.constraint(equalTo: sreLeadEmptyStateView.centerYAnchor, constant: -16),

            sreLeadEmptyStateButton.centerXAnchor.constraint(equalTo: sreLeadEmptyStateView.centerXAnchor),
            sreLeadEmptyStateButton.topAnchor.constraint(equalTo: sreLeadEmptyStateLabel.bottomAnchor, constant: 12),
        ])
    }

    /// How many tabs on this page currently have SRE Lead actively running
    /// (`.starting` or `.ready` - not `.notStarted`/`.failed`, neither of
    /// which holds a live bridge/process). Backs the 5-tab cap.
    private func activeSRELeadTabCount() -> Int {
        tabs.reduce(into: 0) { count, tab in
            switch tab.sreLead?.phase {
            case .some(.starting), .some(.ready): count += 1
            default: break
            }
        }
    }

    /// The toolbar pill's click action - operates on `currentTab`, never a
    /// page-level phase (`fm/grandline-sre-lead-per-tab`). Dedups exactly
    /// like `connectSSHIfNeeded`'s `tabs.isEmpty` guard dedups a host
    /// reconnect: a click while a spawn is already in flight (`.starting`)
    /// is ignored rather than racing a second `SRELead.setUp` for this tab.
    @objc private func toggleSRELead() {
        guard let tab = currentTab else { return }
        switch tab.sreLead?.phase ?? .notStarted {
        case .starting:
            return
        case .ready:
            tearDownSRELead(for: tab)
        case .notStarted, .failed:
            startSRELead(for: tab)
        }
    }

    /// The pane's own empty-state "Start SRE Lead for This Tab" button -
    /// the second entry point into `startSRELead(for:)` alongside the
    /// toolbar pill, so a captain who switches to a not-yet-started tab
    /// while the pane is already open (showing another tab's transcript)
    /// doesn't have to reach for the toolbar.
    @objc private func startSRELeadForCurrentTabClicked() {
        guard let tab = currentTab, (tab.sreLead?.phase ?? .notStarted) != .starting else { return }
        startSRELead(for: tab)
    }

    /// Starts a brand-new, fully independent SRE Lead investigation for
    /// `tab` - its own `SRELeadSession`/`SRELeadBridge` (bridge target is
    /// `tab` itself, never any other tab's terminal) /`SRELeadRunner`, and
    /// its own chat view. Refuses to start a 6th concurrent session on this
    /// page (`sreLeadMaxConcurrent`) with a clear alert rather than silently
    /// queuing or silently refusing.
    private func startSRELead(for tab: TabModel) {
        if activeSRELeadTabCount() >= sreLeadMaxConcurrent {
            showSRELeadCapReachedAlert()
            return
        }

        let state = tab.sreLead ?? SRELeadTabState()
        tab.sreLead = state

        guard let claude = SRELead.resolveClaude() else {
            state.phase = .failed
            updateSRELeadControls()
            showSRELeadError("claude CLI not found on PATH.", in: tab)
            return
        }

        state.phase = .starting
        updateSRELeadControls()

        DispatchQueue.global(qos: .userInitiated).async { [weak self, weak tab] in
            let result = SRELead.setUp()
            DispatchQueue.main.async {
                guard let self, let tab, let state = tab.sreLead else { return }
                switch result {
                case .success(let session):
                    state.session = session
                    state.bridge = SRELeadBridge(bridgeDir: session.bridgeDir, target: tab)
                    state.bridge?.start()
                    state.runner = SRELeadRunner(session: session, claude: claude)
                    let chat = state.chatView ?? self.makeSRELeadChat(for: tab)
                    state.chatView = chat
                    chat.clearMessages()
                    chat.append(SRELeadMessage(role: .status, text: "SRE Lead is ready. Ask a question about this cluster below."))
                    chat.setInputEnabled(true)
                    state.phase = .ready
                    self.updateSRELeadControls()
                case .failure(let error):
                    state.phase = .failed
                    self.updateSRELeadControls()
                    self.showSRELeadError(error.message, in: tab)
                }
            }
        }
    }

    /// The chat view's input submits here - the native equivalent of the
    /// old tmux pane's "just type into the terminal" entry point, now with a
    /// real input field instead of the captain having to click into a raw
    /// `claude` TUI first. Scoped to `tab`'s own runner/chat, so two tabs'
    /// turns can never cross-talk.
    private func handleSRELeadSubmit(_ text: String, in tab: TabModel) {
        guard let state = tab.sreLead, let runner = state.runner, let chat = state.chatView else { return }
        chat.append(SRELeadMessage(role: .user, text: text))
        chat.setInputEnabled(false)
        runner.ask(text) { [weak self, weak chat, weak tab] result in
            guard let chat else { return }
            switch result {
            case .success(let reply):
                chat.append(SRELeadMessage(role: .assistant, text: reply))
                // fm/grandline-notification-center (#7): a reply that lands
                // while this tab isn't the one on screen (a different tab
                // selected, or this whole host page hidden) is exactly the
                // "SRE Lead answered on a tab you're not looking at" signal
                // - a reply landing on the tab the captain is already
                // watching needs no notification at all.
                if let self, let tab, tab !== self.currentTab || self.view.isHidden {
                    self.onSRELeadReplyWhileBackground?(tab)
                }
            case .failure(let error):
                chat.append(SRELeadMessage(role: .error, text: error.message))
            }
            chat.setInputEnabled(true)
            // Only steal first responder back if the captain is still
            // looking at this same tab - a reply landing for a background
            // tab must never yank focus away from whatever is on screen.
            guard let self, let tab, tab === self.currentTab,
                  let window = self.view.window, window.firstResponder !== chat else { return }
            window.makeFirstResponder(chat)
        }
    }

    private func showSRELeadError(_ message: String, in tab: TabModel) {
        let state = tab.sreLead ?? SRELeadTabState()
        tab.sreLead = state
        let chat = state.chatView ?? makeSRELeadChat(for: tab)
        state.chatView = chat
        chat.append(SRELeadMessage(role: .error, text: message))
        if tab === currentTab { updateSRELeadPaneContent() }
    }

    /// One alert for the 5-tab cap (task brief: "a clear, non-crashing
    /// message telling the captain to stop one of the other 5 first, rather
    /// than silently queuing or silently refusing").
    private func showSRELeadCapReachedAlert() {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "SRE Lead limit reached"
        alert.informativeText = "Up to \(sreLeadMaxConcurrent) tabs on this host page can run SRE Lead at the same time. Stop SRE Lead on another tab before starting a new one."
        alert.addButton(withTitle: "OK")
        if let window = view.window {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }

    /// Refreshes the pill, the pane's visible content, the Generate
    /// Postmortem button, and the pill's tooltip - all four always derived
    /// from `currentTab`, called from every place that changes which tab is
    /// selected or changes that tab's own SRE Lead phase.
    private func updateSRELeadControls() {
        guard let tab = currentTab else { return }
        let phase = tab.sreLead?.phase ?? .notStarted
        sreLeadButton?.setState(phase)
        sreLeadButton?.applyTheme(theme)
        updateSRELeadPaneContent()
        updateGeneratePostmortemButton()
        updateSRELeadButtonTooltip(for: tab)
    }

    /// Explains the pill's disabled-in-spirit cap state up front, rather
    /// than only after an attempt bounces off the alert above.
    private func updateSRELeadButtonTooltip(for tab: TabModel) {
        let phase = tab.sreLead?.phase ?? .notStarted
        if (phase == .notStarted || phase == .failed), activeSRELeadTabCount() >= sreLeadMaxConcurrent {
            sreLeadButton?.toolTip = "SRE Lead limit reached (\(sreLeadMaxConcurrent) tabs) - stop SRE Lead on another tab first."
        } else {
            sreLeadButton?.toolTip = "Toggle the SRE Lead investigation pane"
        }
    }

    /// Shows whichever tab is currently selected inside `sreLeadPane`: its
    /// own chat (started/starting/failed-with-error) if it has one, or the
    /// shared empty state otherwise - never another tab's chat. Every other
    /// tab's chat is hidden, the same "hide, don't rebuild" convention this
    /// app uses everywhere else.
    ///
    /// This is also the single place that decides whether the pane is open
    /// at all: it tracks the *currently selected* tab's own `sreLead` state,
    /// not "does any tab on this page have SRE Lead state" - a fresh or
    /// duplicated tab with no `sreLead` state must show a fully closed pane
    /// (no pane, not even the empty state), regardless of what a sibling tab
    /// is doing. Called from every place that changes which tab is selected
    /// or changes that tab's own SRE Lead phase (`updateSRELeadControls`),
    /// plus directly wherever a tab's own state changes without also
    /// touching the currently-selected tab's controls.
    private func updateSRELeadPaneContent() {
        guard let current = currentTab else {
            sreLeadEmptyStateView.isHidden = true
            setSRELeadPaneOpen(false)
            return
        }
        for tab in tabs {
            tab.sreLead?.chatView?.isHidden = (tab !== current)
        }
        sreLeadEmptyStateView.isHidden = (current.sreLead?.chatView != nil)
        setSRELeadPaneOpen(current.sreLead != nil)
    }

    /// The pane header's "Generate Postmortem" button is only ever shown
    /// once the *current* tab's chat has a real assistant reply to
    /// summarize (`SRELeadChatView.hasRealExchange`) - wired to fire on
    /// every `append`/`clearMessages` via `chat.onMessagesChanged` (see
    /// `makeSRELeadChat`), and called directly after `startSRELead`'s own
    /// session-open/session-fail transitions since those don't append
    /// through the normal submit path.
    private func updateGeneratePostmortemButton() {
        sreLeadGeneratePostmortemButton.isHidden = !(currentTab?.sreLead?.chatView?.hasRealExchange ?? false)
    }

    /// "Generate Postmortem": summarizes the *current* tab's own
    /// investigation transcript into a structured markdown document via one
    /// non-interactive `claude -p` call (`SRELeadPostmortem.generate`), then
    /// saves it into the same Docs → Postmortems store phase 1 built
    /// (`DocsRunbookStore.createPostmortem`). A failure here only ever
    /// appends an error message to that tab's own chat feed - the
    /// investigation transcript itself is never touched, so the captain can
    /// retry with nothing lost.
    @objc private func generatePostmortemClicked() {
        guard let tab = currentTab, let chat = tab.sreLead?.chatView, chat.hasRealExchange,
              sreLeadGeneratePostmortemButton.isEnabled else { return }
        let transcript = chat.transcriptForPostmortem
        let hostLabel = tab.name

        sreLeadGeneratePostmortemButton.isEnabled = false
        chat.append(SRELeadMessage(role: .status, text: "Generating postmortem\u{2026}"))

        SRELeadPostmortem.generate(hostLabel: hostLabel, transcript: transcript) { [weak self, weak chat] result in
            guard let self, let chat else { return }
            self.sreLeadGeneratePostmortemButton.isEnabled = true
            switch result {
            case .success(let markdown):
                let title = DocsRunbookStore.titleFromContent(markdown, fallback: "Postmortem - \(hostLabel)")
                let saved = self.docsRunbookStore.createPostmortem(title: title, content: markdown)
                chat.append(SRELeadMessage(role: .status, text: "Postmortem saved: \u{201C}\(saved.title)\u{201D} - see Docs \u{2192} Postmortems."))
            case .failure(let error):
                chat.append(SRELeadMessage(role: .error, text: "Couldn't generate the postmortem: \(error.message). You can try again."))
            }
        }
    }

    /// Tears down `tab`'s own SRE Lead session (bridge, in-flight `claude`
    /// process, scratch dir) and removes its chat - never another tab's.
    /// Called from the pill's toggle-off click and, unconditionally, from
    /// `closeTab` for whichever tab is being closed. Whether the shared pane
    /// ends up open or closed is decided entirely by `updateSRELeadControls`/
    /// `updateSRELeadPaneContent` off the *currently selected* tab's own
    /// state (see that method's doc comment) - tearing down a background
    /// tab's session never touches the pane a captain is actually looking
    /// at, and tearing down the current tab's own session closes the pane
    /// immediately since its `sreLead` is now `nil`.
    private func tearDownSRELead(for tab: TabModel) {
        guard let state = tab.sreLead else { return }
        state.tearDownSession()
        state.chatView?.removeFromSuperview()
        tab.sreLead = nil

        if tab === currentTab {
            sreLeadGeneratePostmortemButton.isEnabled = true
            updateSRELeadControls()
        }
    }

    private func makeSRELeadChat(for tab: TabModel) -> SRELeadChatView {
        let chat = SRELeadChatView(frame: .zero)
        chat.isHidden = true
        chat.onSubmit = { [weak self, weak tab] text in
            guard let self, let tab else { return }
            self.handleSRELeadSubmit(text, in: tab)
        }
        chat.onMessagesChanged = { [weak self, weak tab] in
            guard let self, let tab, tab === self.currentTab else { return }
            self.updateGeneratePostmortemButton()
        }
        chat.setInputEnabled(false)
        sreLeadPane.addSubview(chat)
        NSLayoutConstraint.activate([
            chat.leadingAnchor.constraint(equalTo: sreLeadPaneSeparator.trailingAnchor),
            chat.trailingAnchor.constraint(equalTo: sreLeadPane.trailingAnchor),
            chat.topAnchor.constraint(equalTo: sreLeadHeaderDivider.bottomAnchor),
            chat.bottomAnchor.constraint(equalTo: sreLeadPane.bottomAnchor),
        ])
        chat.applyTheme(theme)
        return chat
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
        addTab(launch: launch, name: numberedName(for: launch), select: true)
    }

    /// ⌘D: a new tab running the same argv as the current one.
    @objc func duplicateCurrentTab() {
        if let tab = currentTab { duplicateTab(id: tab.id) }
    }

    private func duplicateTab(id: UUID) {
        guard let src = tabs.first(where: { $0.id == id }) else { return }
        addTab(launch: src.launch, name: numberedName(for: src.launch), select: true, accentHex: src.accentHex, blockViewOptIn: src.blockViewOptIn)
    }

    /// ⌘W: close the current tab.
    @objc func closeCurrentTab() {
        if let tab = currentTab { closeTab(id: tab.id) }
    }

    private func closeTab(id: UUID) {
        guard let idx = tabs.firstIndex(where: { $0.id == id }) else { return }
        let tab = tabs[idx]

        // Finding 11 (cockpit-audit-core), generalized by `fm/grandline-sre-
        // lead-per-tab`: `shutdown()` already tears every tab's SRE Lead
        // down when the whole page goes away, but closing just one tab used
        // to only special-case the page's single `primarySSHTab` - now that
        // SRE Lead is per-tab, *any* closed tab with its own SRE Lead state
        // tears down unconditionally, never a sibling tab's.
        if tab.sreLead != nil {
            tearDownSRELead(for: tab)
        }
        // fm/grandline-notification-center: a closed tab can never be
        // navigated to again - drop its own unread entry, if any, rather
        // than leaving a dead notification whose click would do nothing.
        NotificationSources.clearSRELeadReply(tabID: tab.id)

        tab.isClosing = true
        tab.mirror?.tearDown()
        tab.mirror = nil
        cleanupSSHKeyTempFile(tab)
        tab.terminal.stopLogging()
        tab.terminal.terminate()
        tab.terminal.removeFromSuperview()
        tab.blockContainer?.removeFromSuperview()
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
                updateSRELeadPaneContent()
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

    /// Finding 7 (cockpit-audit-core): right-click "Rename" on a *background*
    /// tab's chip doesn't select it first (`TabChipView.rightMouseDown`), so
    /// `tab` here can be a hidden tab, not `currentTab`. Restoring focus to
    /// `tab.terminal` unconditionally silently stole keyboard focus away from
    /// whichever tab was actually on screen. Restore focus to `currentTab`
    /// instead - renaming the active tab (the double-click / ⌘⇧R path) is
    /// unaffected, since `tab === currentTab` there anyway.
    private func renameTab(id: UUID, to newName: String) {
        guard let tab = tabs.first(where: { $0.id == id }) else { return }
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        tab.name = trimmed.isEmpty ? tab.launch.defaultName : trimmed
        tab.chip.setName(tab.name)
        styleChips()
        if let current = currentTab { view.window?.makeFirstResponder(current.terminal) }
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
        for t in tabs { updateTabViewVisibility(t) }
        styleChips()
        updateWindowTitle(from: tab)
        updateLogButton()
        updateBlockViewControls()
        updateComposeControls()
        updateUtilizationControls()
        updateSRELeadControls()
        // fm/grandline-notification-center (#7): selecting a tab is exactly
        // "the captain is now looking at this tab" - clears its own SRE
        // Lead unread entry, if any, regardless of how selection happened
        // (a chip click, ⌘1-9, or a notification's own navigate closure).
        NotificationSources.clearSRELeadReply(tabID: tab.id)
        if focus { view.window?.makeFirstResponder(tab.terminal) }
    }

    /// `fm/grandline-notification-center`: the one external entry point for
    /// jumping straight to a specific tab (the SRE Lead reply notification's
    /// own navigate closure) - mirrors `focusCurrentTab()`'s existing public
    /// surface for "the currently selected tab," just parameterized by id.
    func selectAndFocusTab(id: UUID) {
        select(tabID: id, focus: true)
    }

    /// `fm/grandline-notification-center`: called whenever this whole host
    /// page comes back on screen without a tab-selection change happening
    /// (e.g. re-opening it from the rail icon or the Hosts list) - `select`
    /// above already clears the currently-selected tab's own SRE Lead
    /// unread entry on every selection change, but that doesn't fire just
    /// from `isHidden` flipping back to `false` with no selection change.
    func markCurrentTabAsRead() {
        guard let tab = currentTab else { return }
        NotificationSources.clearSRELeadReply(tabID: tab.id)
    }

    // MARK: Compose (`fm/grandline-console-command-composer`)

    /// Only ever shown for a plain `.shell` tab that isn't a one-shot
    /// provisioning command (`isOneShotCommand`) - never an SSH tab (a
    /// different remote shell's own command syntax), a Mirror/Herdr tab (not
    /// a captain-typed shell at all), or a one-shot command tab (already has
    /// a fixed, tracked purpose). Closes the popover outright when the
    /// current tab stops qualifying (e.g. switching away mid-review), so it
    /// never sits open pointed at a tab it no longer applies to.
    private func updateComposeControls() {
        let available: Bool
        if let tab = currentTab, case .shell = tab.launch, !tab.isOneShotCommand {
            available = true
        } else {
            available = false
        }
        composeButton.isHidden = !available
        if !available { composer.close() }
        composeButton.contentTintColor = HelmTheme.nsColor(theme.chromeInkHex)
    }

    @objc private func toggleComposer() {
        guard !composeButton.isHidden else { return }
        composer.toggle(relativeTo: composeButton)
    }

    // MARK: Claude usage (`fm/grandline-herdr-utilization-panel`)

    /// Only ever shown for a Herdr-backed `.mirror` tab - the opposite gating
    /// of `updateComposeControls` above, mirrored from the same two call
    /// sites (`select(tabID:)`, `applyTheme()`). Hidden, not merely disabled,
    /// on every other tab kind (`.shell`, `.ssh`, a tmux `.mirror`), and
    /// closes the popover outright when the current tab stops qualifying -
    /// same reasoning as Compose's own doc comment.
    private func updateUtilizationControls() {
        let available: Bool
        if let tab = currentTab, case .mirror(let kind, _) = tab.launch, kind == .herdr {
            available = true
        } else {
            available = false
        }
        utilizationButton.isHidden = !available
        if !available { quotaUsage.close() }
        utilizationButton.contentTintColor = HelmTheme.nsColor(theme.chromeInkHex)
    }

    @objc private func toggleUtilization() {
        guard !utilizationButton.isHidden else { return }
        quotaUsage.toggle(relativeTo: utilizationButton)
    }

    // MARK: Block view (`fm/cockpit-block-view-stage0`)

    /// Whether the current tab is showing parsed blocks instead of raw
    /// scrollback right now - a per-console, session-only toggle (not
    /// persisted, not a process-wide flag like the original PR #79/#83
    /// attempts' `BlockViewManager`) since Stage 0 only ever has at most one
    /// opted-in tab per console to toggle at all. Only ever visibly matters
    /// for a tab with a `blockContainer` - see `updateTabViewVisibility`.
    private var blockViewShowing = false

    /// Decides which of a tab's two views (raw `terminal` or parsed
    /// `blockContainer`) is visible right now - never both, and never for a
    /// tab that isn't the current one. Toggling never touches `terminal`'s
    /// process or `startProcess` state either way. A tab with no
    /// `blockContainer` (every tab except the one opted-in host's, when the
    /// feature is enabled - see `TabModel.blockViewOptIn`) always shows raw
    /// `terminal` regardless of `blockViewShowing`.
    private func updateTabViewVisibility(_ tab: TabModel) {
        let isCurrent = (tab === currentTab)
        guard isCurrent else {
            tab.terminal.isHidden = true
            tab.blockContainer?.isHidden = true
            return
        }
        if blockViewShowing, let container = tab.blockContainer {
            tab.terminal.isHidden = true
            container.isHidden = false
        } else {
            tab.terminal.isHidden = false
            tab.blockContainer?.isHidden = true
        }
    }

    /// Toolbar toggle - only meaningful (and only shown at all, see
    /// `updateBlockViewControls`) for the one opted-in host's tab.
    @objc private func toggleBlockView() {
        guard currentTab?.blockContainer != nil else { return }
        blockViewShowing.toggle()
        if let tab = currentTab { updateTabViewVisibility(tab) }
        updateBlockViewControls()
    }

    /// Stage 0's one interactive action on the block view: re-parse
    /// `blockTracker.blocks` (already kept current by the OSC 133 handler -
    /// see `TerminalBlockTracker`'s header for why that's not the same as
    /// live-streaming) into the visible list. Nothing calls `render`
    /// automatically - this manual click is the only way the panel updates,
    /// by design (see `BlockView.swift`'s header).
    @objc private func refreshBlockView() {
        guard let tab = currentTab, let tracker = tab.blockTracker, let container = tab.blockContainer else { return }
        container.render(tracker.blocks)
    }

    /// Shows/hides and restyles the two block-view toolbar buttons - only
    /// present at all when the current tab has a tracker (i.e. is the one
    /// opted-in host's tab with the feature enabled); every other tab hides
    /// both, matching `sreLeadButton`'s existing per-tab-relevance pattern.
    private func updateBlockViewControls() {
        let available = currentTab?.blockContainer != nil
        blockViewToggleButton.isHidden = !available
        blockViewRefreshButton.isHidden = !available || !blockViewShowing
        guard available else { return }
        // `symbolName`, not `image`: `HelmButton` builds its glyph from that
        // property (at the variant's own point size / weight), so a directly
        // assigned `image` would be replaced the next time anything triggers
        // `rebuildImage()`.
        blockViewToggleButton.symbolName = blockViewShowing ? "rectangle.grid.1x2.fill" : "rectangle.grid.1x2"
        // `tint`, not `contentTintColor`: `HelmButton` owns the latter and
        // re-derives it on every theme change, so a direct assignment here
        // would survive exactly until the next theme switch. `nil` means "no
        // emphasis", i.e. the variant's own label colour.
        blockViewToggleButton.tint = blockViewShowing ? .accent : nil
        blockViewToggleButton.toolTip = blockViewShowing ? "Show Raw Scrollback" : "Show Parsed Blocks (Stage 0)"
        blockViewRefreshButton.toolTip = "Refresh Blocks"
    }

    // MARK: Theme

    @objc func toggleTheme() {
        ThemeManager.shared.toggle()
        // `applyTheme()` runs via the `observe` callback registered in
        // `loadView`, so nothing else is needed here.
    }

    private func applyTheme() {
        for tab in tabs {
            theme.apply(to: tab.terminal)
            tab.blockContainer?.applyTheme(theme)
        }

        let chromeBg = HelmTheme.nsColor(theme.chromeBackgroundHex)
        let line = HelmTheme.nsColor(theme.chromeLineHex)
        let ink = HelmTheme.nsColor(theme.chromeInkHex)
        view.layer?.backgroundColor = HelmTheme.nsColor(theme.backgroundHex).cgColor
        // The bar's fill and hairline, and every glyph in it, are the
        // component's / `HelmButton`'s own business now - this page no longer
        // keeps a toolbar-button registry to re-tint (`ThemeManager.swift`'s
        // checklist item 4).
        tabBar.applyTheme(theme)
        content.layer?.backgroundColor = HelmTheme.nsColor(theme.backgroundHex).cgColor

        styleChips()
        updateLogButton()
        updateBlockViewControls()
        updateComposeControls()
        updateUtilizationControls()

        // The pane is a distinct surface/card, not a continuation of the
        // terminal - filled with `chromeBackgroundHex` (this app's "surface"
        // token) instead of `backgroundHex` (the terminal's own token),
        // fixing a captain-reported "melds into the terminal" report
        // (`fm/grandline-sre-lead-polish`). Checked live across all 12
        // `HelmTheme.allThemes`: `chromeBackgroundHex` differs from
        // `backgroundHex` in 9 of them, but is numerically IDENTICAL in
        // `gruvbox-light`/`tokyo-night-dark`/`tokyo-night-light` - so the
        // fill alone can't be the only thing carrying this distinction. The
        // widened, `accentHex`-tinted `sreLeadPaneSeparator` below is what
        // makes the boundary unmistakable in every theme regardless of
        // whether the two fills happen to match, since every theme's accent
        // is a deliberately bold, saturated color far from either
        // background/chrome-background shade - never rely on the fill pair
        // alone to prove this distinction in a future change here.
        let paneBg = HelmTheme.nsColor(theme.chromeBackgroundHex)
        let accent = HelmTheme.nsColor(theme.accentHex)
        sreLeadPane.layer?.backgroundColor = paneBg.cgColor
        sreLeadPaneSeparator.layer?.backgroundColor = accent.cgColor
        sreLeadHeader.layer?.backgroundColor = chromeBg.cgColor
        sreLeadHeaderDivider.layer?.backgroundColor = line.cgColor
        sreLeadHeaderLabel.textColor = ink
        sreLeadGeneratePostmortemButton.contentTintColor = ink
        sreLeadEmptyStateView.layer?.backgroundColor = paneBg.cgColor
        sreLeadEmptyStateLabel.textColor = HelmTheme.mutedInk(theme)
        // Every started tab's own chat, not just the current one - each is a
        // real, independent view that needs to stay in sync with the active
        // theme whether or not it happens to be the one currently visible.
        for tab in tabs { tab.sreLead?.chatView?.applyTheme(theme) }
        // Re-applies `sreLeadButton`'s theme + refreshes the pane/postmortem
        // button/tooltip for whichever tab is current.
        updateSRELeadControls()
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

    @objc func zoomIn() { FontSizeManager.shared.step(by: 1) }
    @objc func zoomOut() { FontSizeManager.shared.step(by: -1) }
    @objc func zoomReset() { FontSizeManager.shared.setSize(13) }

    /// The Settings panel's font-size stepper (Fix 3) - now a thin forward
    /// to `FontSizeManager`, which is the source of truth (`fm/cockpit-
    /// tools-page-ui-polish`); kept as a method on this class since
    /// `main.swift`'s existing `onFontSizeStep` wiring still calls it.
    func stepFontSize(by delta: CGFloat) { FontSizeManager.shared.step(by: delta) }
    var currentFontSize: CGFloat { fontSize }

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
        // Finding 8 (cockpit-audit-core): the timestamp alone is only
        // second-resolution, so two tabs created (e.g. via rapid ⌘D) within
        // the same wall-clock second used to compute the identical log path -
        // the second `startLogging` truncated the file the first tab's still-
        // open `FileHandle` was writing to, interleaving/corrupting both
        // transcripts. Including the tab's own UUID makes every tab's log
        // path unique regardless of name or timing.
        let shortID = tab.id.uuidString.split(separator: "-").first.map(String.init) ?? tab.id.uuidString
        let fileName = "\(String(slug))-\(formatter.string(from: Date()))-\(shortID).log"
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
        logButton.symbolName = isLogging ? "record.circle.fill" : "record.circle"
        // `.critical` rather than a literal `.systemRed`: same "this is
        // recording" signal, now the active theme's own red, routed through
        // `HelmContrast` by `HelmButton` so it stays legible on the toolbar
        // fill in all 12 palettes. (A rail *badge* deliberately keeps a fixed
        // system red - see `IconRailController.attachBadge` - but that is an
        // OS-convention alert pill, not a themed control's label.)
        logButton.tint = isLogging ? .critical : nil
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
        case .mirror(let kind, let target):
            tab.mirror?.tearDown()
            tab.mirror = nil
            // Finding 9 (cockpit-audit-core): `tearDown()` kills the tmux/
            // herdr session synchronously, but the still-attached client
            // notices and exits on its own, asynchronous timing - if
            // SwiftTerm's `LocalProcess` hasn't yet reaped that exit,
            // `startProcess`'s own `if running { return }` guard silently
            // drops this reconnect attempt with no error shown. Wait for the
            // old process to actually finish (bounded, so a truly stuck
            // process still surfaces a message instead of hanging forever)
            // before starting the new one.
            //
            // `kind`/`target` are the pair already frozen into `tab.launch`
            // at tab-creation time - reused verbatim, not re-resolved, so a
            // manual reconnect can never introduce a fresh kind/target
            // disagreement either (`fm/grandline-mirror-resolve-race-fix`).
            waitForProcessExit(tab, thenRun: { [weak self] in
                self?.connectMirror(tab, kind: kind, target: target)
            })
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
        // The manual-reconnect path's own restart bookkeeping - see
        // `restartTabBookkeeping`'s doc comment for why `startTab` and this
        // method are the only two callers, and why that matters.
        restartTabBookkeeping(tab)
        view.window?.makeFirstResponder(tab.terminal)
    }

    /// Polls `tab.terminal.process.running` (bridged from SwiftTerm's
    /// `LocalProcess`) every 50ms, up to `maxAttempts` times, then runs
    /// `thenRun` - immediately if the process has already exited, otherwise
    /// once it does. If it's still running after the bound, `thenRun` still
    /// runs (matching this app's other "degrade gracefully, don't hang
    /// forever" races) but a visible message explains why the reconnect may
    /// not have taken effect, rather than silently doing nothing.
    private func waitForProcessExit(_ tab: TabModel, maxAttempts: Int = 40, thenRun: @escaping () -> Void) {
        guard tab.terminal.process.running else {
            thenRun()
            return
        }
        guard maxAttempts > 0 else {
            tab.terminal.feed(text: "\r\n  \u{1b}[2m[reconnect]\u{1b}[0m previous session hadn't exited yet - retrying anyway\u{1b}[0m\r\n")
            thenRun()
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self, weak tab] in
            guard let self, let tab else { return }
            self.waitForProcessExit(tab, maxAttempts: maxAttempts - 1, thenRun: thenRun)
        }
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
        // Host-page disconnect (design brief Part B) - tear down every
        // tab's own SRE Lead session (`fm/grandline-sre-lead-per-tab`: each
        // tab has its own now, not one page-level session) the same way
        // `tearDownSRELead(for:)` does, just without the pane-close
        // animation/UI refresh since this whole page may be on its way out
        // already (a deleted host's page via
        // `AppShellController.removeHostConsole`).
        for tab in tabs {
            tab.sreLead?.tearDownSession()
            tab.sreLead = nil
            // fm/grandline-notification-center: this whole page is going
            // away (a deleted host) - no dead notification should be left
            // pointing at a tab that no longer exists.
            NotificationSources.clearSRELeadReply(tabID: tab.id)
        }
        if let themeObservation {
            ThemeManager.shared.unobserve(themeObservation)
            self.themeObservation = nil
        }
        if let fontSizeObservation {
            FontSizeManager.shared.unobserve(fontSizeObservation)
            self.fontSizeObservation = nil
        }
        composer.shutdown()
        quotaUsage.shutdown()
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
        // The SRE Lead pane is a native `SRELeadChatView`, not a
        // `TerminalView` - it never appears as `source` here. Each
        // `claude -p` turn is a one-shot `Process` `SRELeadRunner` owns and
        // waits on directly (`ask`'s completion), not something this
        // delegate callback observes.
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

    // MARK: Test support (`fm/cockpit-block-view-stage0`)
    //
    // `BlockViewRestartIntegrationSelfTest` needs to drive this controller's
    // *real* restart machinery - `startTab`/`reconnectActive` themselves,
    // not a reimplementation of them in the test - to prove both restart
    // paths leave the block tracker in the same clean state (the scout
    // report's Mechanism A: the original attempt only reset it correctly
    // from `reconnectActive`, not from the auto-reconnect timer that calls
    // `startTab` directly). These five methods exist for exactly that; no
    // production code calls them.

    /// Opens a real `.ssh` tab on this (non-Firstmate) console, exactly the
    /// way `AppShellController.connectHost` does for an opted-in host, minus
    /// needing a real `Host`/`AppShellController`. `127.0.0.1` with a 1s
    /// connect timeout fails fast (nothing real listens on the ssh port
    /// there in this environment) - the test only needs a real `Terminal`
    /// and a real `TerminalBlockTracker` attached to it, not a working
    /// connection.
    func debugOpenTestSSHTab(label: String) {
        openSSH(
            label: label,
            args: ["-o", "ConnectTimeout=1", "-o", "BatchMode=yes", "127.0.0.1"],
            accentHex: nil, keyID: nil, startupSnippetID: nil, blockViewOptIn: true
        )
    }

    /// The real `Terminal` behind the current tab, so a test can feed
    /// synthetic OSC 133 bytes into it directly - mirroring
    /// `TerminalBlockTrackerSelfTest`'s `HeadlessTerminal` technique - without
    /// a live shell actually emitting them.
    func debugCurrentTerminal() -> Terminal? { currentTab?.terminal.terminal }

    /// The two facts Mechanism A's bug corrupts: how many blocks the tracker
    /// holds, and whether any of them is still `.running` (the permanently-
    /// stuck-spinner symptom).
    func debugBlockState() -> (count: Int, hasRunning: Bool)? {
        guard let tracker = currentTab?.blockTracker else { return nil }
        let hasRunning = tracker.blocks.contains {
            if case .running = $0.status { return true }
            return false
        }
        return (tracker.blocks.count, hasRunning)
    }

    /// Drives the exact "initial start / automatic reconnect" path -
    /// `processTerminated`'s auto-reconnect timer calls `startTab` directly,
    /// so this does too, rather than reimplementing what it does.
    func debugSimulateAutoReconnectRestart() {
        guard let tab = currentTab else { return }
        startTab(tab)
    }

    /// Drives the exact manual ⌘R path.
    func debugSimulateManualReconnectRestart() {
        reconnectActive()
    }

    // MARK: Test support (`fm/grandline-mirror-resolve-race-fix`)

    /// Every open tab's id, in tab-bar order - so a test can find and select
    /// a specific tab (e.g. `openFirstmateHost`'s Mirror/Herdr tab, created
    /// first but not selected) without `tabs` itself needing to be internal.
    func debugAllTabIDs() -> [UUID] { tabs.map { $0.id } }

    /// Selects a tab by id, exactly like clicking its chip.
    func debugSelectTab(_ id: UUID) { select(tabID: id, focus: false) }

    /// The kind+target frozen into the current tab's `TabLaunch.mirror` (if
    /// it is one) - lets a test confirm they were resolved atomically and
    /// never re-derived independently, without duplicating `ConsoleController`'s
    /// own switch-over-`tab.launch` logic.
    func debugMirrorLaunch() -> (kind: FirstmateBackendKind, target: String)? {
        guard case .mirror(let kind, let target) = currentTab?.launch else { return nil }
        return (kind, target)
    }

    /// The current tab's raw terminal output so far, so a test can check for
    /// (or the absence of) the `[mirror]`/`[herdr]` failure text
    /// `connectMirror` feeds in on a setup error.
    func debugCurrentTerminalOutput() -> String? {
        guard let terminal = currentTab?.terminal.terminal else { return nil }
        return String(data: terminal.getBufferAsData(), encoding: .utf8)
    }

    // MARK: Test support (`fm/grandline-sre-lead-per-tab`)
    //
    // `SRELeadPerTabSelfTest` needs to drive this controller's *real*
    // per-tab SRE Lead machinery - `startSRELead(for:)`/`handleSRELeadSubmit`/
    // `tearDownSRELead(for:)`/`closeTab` themselves, not reimplementations of
    // them - to prove the state genuinely lives per-tab (independent phases,
    // no cross-talk between two tabs' chats, per-tab teardown on close, the
    // 5-tab cap). No production code calls any of these.

    /// Starts SRE Lead for the tab at `id`, exactly like clicking the
    /// toolbar pill while that tab is current - but without needing to
    /// actually select it first, so a test can start it on several tabs in
    /// any order.
    func debugStartSRELead(forTabID id: UUID) {
        guard let tab = tabs.first(where: { $0.id == id }) else { return }
        startSRELead(for: tab)
    }

    /// Tears SRE Lead down for the tab at `id`, exactly like clicking the
    /// pill while that tab is current and ready.
    func debugTearDownSRELead(forTabID id: UUID) {
        guard let tab = tabs.first(where: { $0.id == id }) else { return }
        tearDownSRELead(for: tab)
    }

    /// Closes a tab by id - the same `closeTab(id:)` a chip's "×"/⌘W drives.
    func debugCloseTab(id: UUID) { closeTab(id: id) }

    func debugSRELeadPhase(forTabID id: UUID) -> SRELeadStatusPill.State? {
        tabs.first(where: { $0.id == id })?.sreLead?.phase
    }

    /// Submits `question` into the tab at `id`'s own SRE Lead chat, exactly
    /// like the captain typing into that tab's input field and pressing
    /// Return - drives the real `handleSRELeadSubmit(_:in:)`, so a fake
    /// `claude` script (`SRELead.claudePathOverrideForTests`) is what
    /// actually answers it.
    func debugAskSRELead(forTabID id: UUID, question: String) {
        guard let tab = tabs.first(where: { $0.id == id }) else { return }
        handleSRELeadSubmit(question, in: tab)
    }

    /// The exact text of every message currently in the tab at `id`'s own
    /// SRE Lead chat - `nil` if that tab has no chat yet.
    func debugSRELeadChatTexts(forTabID id: UUID) -> [String]? {
        tabs.first(where: { $0.id == id })?.sreLead?.chatView?.debugMessageTexts()
    }

    /// How many tabs on this page currently have SRE Lead actively running -
    /// the same count `startSRELead(for:)` checks against `sreLeadMaxConcurrent`.
    func debugActiveSRELeadCount() -> Int { activeSRELeadTabCount() }

    /// Whether the shared pane is currently visible (non-zero width) - never
    /// which tab's content it shows, since `updateSRELeadPaneContent()`
    /// already has its own dedicated debug surface below.
    func debugSRELeadPaneOpen() -> Bool { sreLeadPaneWidthConstraint.constant > 0 }

    /// Whether the pane is currently showing the shared "not started yet"
    /// empty state (as opposed to some tab's real chat) - `nil` if there is
    /// no current tab at all.
    func debugSRELeadShowingEmptyState() -> Bool? {
        guard currentTab != nil else { return nil }
        return !sreLeadEmptyStateView.isHidden
    }
}
