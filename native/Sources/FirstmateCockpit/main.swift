// Manjesh Grand Line - native macOS app (Phase 2 entry point).
//
// One AppKit window whose content is `AppShellController` - the nav-redesign
// task's icon rail + topbar + swappable body (Console/Home, Overview,
// Review, Settings). This file owns only the window, the main menu, and app
// lifecycle - all terminal behaviour lives in `ConsoleController` and its
// helpers. It builds ON Phase 1: the Shell tab is the P1 terminal unchanged, and
// the load-bearing Edit > Paste wiring (which drives screenshot-paste into
// Claude) is preserved here for both tabs.

import AppKit
import SwiftTerm

final class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    // Phase 1: saved SSH hosts + the panel that lists and connects them. The
    // panel hands a `ssh` argv to the console, which opens it as a new tab.
    let hostStore = HostStore()
    // Phase 2: the saved-keys Keychain. The console resolves a host's chosen
    // key through it at connect time; the Keys window (below) is where the
    // captain generates/imports/browses them.
    let keyStore = SSHKeyStore()
    // Phase 3: the saved-command library (B2/B5). The console resolves a
    // host's startup snippet through it at connect time, and the Snippets
    // window's "Run" sends a snippet straight to the active tab.
    let snippetStore = SnippetStore()
    lazy var console = ConsoleController(keyStore: keyStore, snippetStore: snippetStore)
    lazy var hostsPanel = HostsSidebarController(store: hostStore)
    lazy var keysController = KeysSidebarController(store: keyStore)
    lazy var snippetsController = SnippetsController(store: snippetStore)
    lazy var settingsController = SettingsController()
    // Fix 1: `makeHostConsole` builds a fresh, host-scoped console (no
    // Mirror/Shell tabs) for `AppShellController.connectHost` - captured as
    // local constants (not `self`) so this closure, which `appShell` holds
    // onto for its whole lifetime, can't form a retain cycle with `self`.
    lazy var appShell: AppShellController = {
        let keyStore = self.keyStore
        let snippetStore = self.snippetStore
        return AppShellController(
            hostsPanel: hostsPanel, console: console, settings: settingsController,
            makeHostConsole: { ConsoleController(keyStore: keyStore, snippetStore: snippetStore, isFirstmateConsole: false) }
        )
    }()
    var keysWindow: NSWindow?
    var snippetsWindow: NSWindow?
    var hostEditorWindow: NSWindow?
    /// Fix 1: last-seen saved-host ids, so `hostStore.observe` below can
    /// detect a delete (a host id present last time but missing now) and
    /// tear down that host's dedicated page rather than leaving it stranded.
    private var knownHostIDs: Set<UUID> = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Connect action from the panel: a saved host (has an id) reaches its
        // own dedicated page (Fix 1) - the same one its rail icon opens, via
        // `connectToHost` below; an ad-hoc quick-connect (no saved identity to
        // pin a page to) still opens as a plain tab in the shared Firstmate
        // console, same as before Fix 1.
        hostsPanel.onConnect = { [weak self] hostID, label, args, accentHex, keyID, startupSnippetID in
            guard let self else { return }
            if let hostID, let host = self.hostStore.host(id: hostID) {
                self.connectToHost(host)
            } else {
                self.console.openSSH(label: label, args: args, accentHex: accentHex, keyID: keyID, startupSnippetID: startupSnippetID)
                self.appShell.show(.console)
            }
        }
        // The pinned "Firstmate" entry (Fix 4) - the same Shell + Mirror pair
        // the console has always opened at startup, now also reachable from
        // the Hosts list. Unaffected by Fix 1: it's the one destination that
        // deliberately stays on the shared `console`, never a dedicated page.
        hostsPanel.onConnectPinned = { [weak self] in
            guard let self else { return }
            self.console.openFirstmateHost()
            self.appShell.show(.console)
        }
        // Nav-redesign task, item 3: Add/Edit Host is a dedicated full-page
        // window, not a sheet on this ~240pt-wide panel.
        appShell.onPresentHostEditor = { [weak self] host in
            self?.presentHostEditor(for: host)
        }
        // Fix 3 (fixes4): a pinned rail icon per saved host, kept live via
        // `HostStore.observe` - the same add/rename/delete signal the Hosts
        // list itself reloads from. Clicking one connects exactly like the
        // Hosts list's own Connect action (Fix 1: both now reach the same
        // dedicated per-host page via `connectToHost`).
        appShell.rail.setHosts(hostStore.hosts)
        knownHostIDs = Set(hostStore.hosts.map { $0.id })
        hostStore.observe { [weak self] in
            guard let self else { return }
            let currentIDs = Set(self.hostStore.hosts.map { $0.id })
            // Fix 1: a host id that was known last time but isn't anymore was
            // deleted - tear down its dedicated page so the rail (which just
            // lost that host's icon) can't leave it stranded.
            for removedID in self.knownHostIDs.subtracting(currentIDs) {
                self.appShell.removeHostConsole(id: removedID)
            }
            self.knownHostIDs = currentIDs
            self.appShell.rail.setHosts(self.hostStore.hosts)
        }
        appShell.rail.onConnectHost = { [weak self] host in
            self?.connectToHost(host)
        }
        // The Snippets panel's "Run" (Phase 3, B2) sends straight to the
        // console's active tab.
        snippetsController.onRun = { [weak self] snippet in
            self?.console.runSnippetInActiveTab(snippet)
        }
        // Settings > Terminal's font-size stepper (Fix 3) talks straight to
        // the live console; Appearance goes through `ThemeManager` directly
        // since every theme-aware view already observes it.
        settingsController.onFontSizeStep = { [weak self] delta in
            self?.console.stepFontSize(by: delta)
        }

        // Settings > Terminal's "Bell & notifications" toggle (Fix 3): start
        // the background poll now if it was already on from a previous
        // launch, and again whenever the toggle flips.
        FleetNotifier.shared.setEnabled(AppSettings.shared.notifyOnNeedsDecision)

        buildMenu()

        let frame = NSRect(x: 0, y: 0, width: 1220, height: 720)
        window = NSWindow(
            contentRect: frame,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Manjesh Grand Line"
        window.center()
        window.contentViewController = appShell
        // Theme-audit task: the window's own chrome (title bar) has no view
        // to force `.appearance` on, so without this it always follows the
        // OS's actual light/dark setting rather than the active Helm theme.
        window.followHelmTheme()

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    /// Tear down the mirror's grouped tmux session so a `cockpit_*` session is
    /// not left behind after the app quits - the shared Firstmate console and
    /// (Fix 1) every host's own dedicated console.
    func applicationWillTerminate(_ notification: Notification) {
        console.shutdown()
        appShell.shutdownAllHostConsoles()
    }

    // MARK: Host connect (Fix 1: dedicated per-host pages)

    /// The one place a saved host is actually connected to - reached from
    /// both the Hosts sidebar's own "Connect" and a pinned rail icon click,
    /// so there's exactly one behavior for "connect to this saved host"
    /// regardless of entry point. `AppShellController.connectHost` owns the
    /// "open the first time, just focus after that" logic
    /// (`ConsoleController.connectSSHIfNeeded`); this method's only job is
    /// resolving the host's full `ssh` argv, which needs `hostStore.hosts`
    /// for jump-chain resolution (`Host.sshArguments(allHosts:)`).
    private func connectToHost(_ host: Host) {
        appShell.connectHost(host, args: host.sshArguments(allHosts: hostStore.hosts))
    }

    // MARK: Host editor window (nav-redesign task, item 3)

    /// Open (or bring forward) the Add/Edit Host form as its own window -
    /// the same visual weight as Settings, not a sheet cramped into the
    /// narrow Hosts panel. `HostEditorController`'s fields and its inline
    /// "+ New Key…" flow (which still opens as a sheet on top of *this*
    /// window) are unchanged from PR #14.
    func presentHostEditor(for host: Host?) {
        let editor = HostEditorController(host: host, keyStore: keyStore, snippets: snippetStore.snippets)
        editor.onSave = { [weak self] saved in
            guard let self else { return }
            if self.hostStore.host(id: saved.id) != nil {
                self.hostStore.update(saved)
            } else {
                self.hostStore.add(saved)
            }
            self.appShell.showToast("\u{201C}\(saved.label)\u{201D} saved")
        }
        editor.onDelete = { [weak self] id in
            self?.hostStore.delete(id: id)
        }

        // Reuse one window across repeated Add/Edit calls (matching the Keys/
        // Snippets windows below) rather than piling up a new one on every
        // "+" click - only `contentViewController` needs to change since a
        // fresh `HostEditorController` is built above for whichever host is
        // being edited this time.
        let win: NSWindow
        if let existing = hostEditorWindow {
            win = existing
        } else {
            win = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 640, height: 780),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            win.isReleasedWhenClosed = false
            // cockpit-native-host-form-fixes, Fix 1: without this, opening
            // Add/Edit Host while the main `AppShellController` window is
            // full screen makes macOS treat this second regular window as a
            // tile to dock into that same full-screen Space (its default
            // behavior for a second standard window), stretching the
            // centered form back out to full width - the exact regression
            // the centered-form fix (PR #20) was meant to close, just gated
            // behind full-screen mode. `.fullScreenAuxiliary` tells AppKit
            // this window is allowed to float over a full-screen Space
            // instead of tiling into it; `.moveToActiveSpace` matters
            // because this window is cached and reused (`hostEditorWindow`)
            // for the app's whole lifetime, so a later reopen always
            // surfaces on whichever Space (full-screen or not) is active at
            // that moment, not the Space it happened to be in last time.
            // `.floating` keeps it visually above the full-screen window's
            // own content - Space membership alone doesn't guarantee that.
            win.collectionBehavior = [.fullScreenAuxiliary, .moveToActiveSpace]
            win.level = .floating
            win.followHelmTheme()
            hostEditorWindow = win
        }
        win.title = host == nil ? "New Host" : "Edit Host"
        win.contentViewController = editor
        // Fix 2 (third round): the form's content column caps at 520pt and
        // centers (`HostEditorController.maxContentWidth`), so 568pt
        // (520 + 24pt margin each side) is the narrowest width that shows the
        // whole column without horizontal clipping - AppKit enforces that as
        // a live floor via the content view controller's fitting size (verified
        // with a live probe: dragging the window narrower than 568 settles
        // back to 568 on the next layout pass, same as any AppKit dialog
        // window whose content can't shrink further). 580 leaves a hair of
        // margin above that floor; 640 is the default so the centering is
        // visibly obvious - not flush with the window edges - without the
        // captain having to widen it by hand. Height has no such floor (the
        // form scrolls vertically), so 620 stays the height floor unchanged.
        win.contentMinSize = NSSize(width: 580, height: 620)
        win.setContentSize(NSSize(width: 640, height: 780))
        win.center()
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: Keys window (Phase 2)

    /// Open (or bring forward) the "SSH Keys" screen. A separate window rather
    /// than a third split-view pane, since keys are managed far less often
    /// than hosts are connected to (design report Section A1: "a keychain
    /// screen the captain can browse").
    @objc func showKeysWindow() {
        if keysWindow == nil {
            let win = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 380, height: 520),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            win.title = "SSH Keys"
            win.contentViewController = keysController
            win.isReleasedWhenClosed = false
            win.followHelmTheme()
            win.center()
            keysWindow = win
        }
        keysWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func newKeyFromMenu() {
        showKeysWindow()
        keysController.newKey()
    }

    // MARK: Snippets window (Phase 3, B2/B5)

    /// Open (or bring forward) the "Snippets" screen - a separate window,
    /// matching how the Keys screen (above) is kept out of the main
    /// split-view rather than added as a third pane.
    @objc func showSnippetsWindow() {
        if snippetsWindow == nil {
            let win = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 360, height: 480),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            win.title = "Snippets"
            win.contentViewController = snippetsController
            win.isReleasedWhenClosed = false
            win.followHelmTheme()
            win.center()
            snippetsWindow = win
        }
        snippetsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func newSnippetFromMenu() {
        showSnippetsWindow()
        snippetsController.newSnippet()
    }

    // MARK: Menu

    /// The main menu. Three load-bearing groups:
    ///  - Edit > Paste (⌘V) targets the first responder via `NSText.paste(_:)`,
    ///    which resolves to the focused terminal's `paste(_:)` - the screenshot-
    ///    paste-into-Claude flow. A plain `swift run` executable has no Paste
    ///    action otherwise (the old WKWebView got one for free from the browser).
    ///  - Edit > Find, the Tab items, and the View items target the responder
    ///    chain, resolving to `ConsoleController` (the window's content view
    ///    controller), so ⌘F / ⌘T / ⌘D / ⌘W / ⌘R / ⌘1…⌘9 / zoom / theme all work
    ///    from the keyboard.
    func buildMenu() {
        let mainMenu = NSMenu()

        // App menu
        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu()
        appMenuItem.submenu = appMenu
        let appName = ProcessInfo.processInfo.processName
        appMenu.addItem(withTitle: "About \(appName)", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(NSMenuItem.separator())
        // Nav-redesign task, item 5: Settings is a rail destination in the
        // main window now, not a separate window.
        appMenu.addItem(withTitle: "Settings…", action: #selector(AppShellController.selectSettings), keyEquivalent: ",")
            .target = appShell
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "Hide \(appName)", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit \(appName)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        // Edit menu - Cut/Copy/Paste/Select All + Find.
        let editMenuItem = NSMenuItem()
        mainMenu.addItem(editMenuItem)
        let editMenu = NSMenu(title: "Edit")
        editMenuItem.submenu = editMenu
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenu.addItem(NSMenuItem.separator())
        editMenu.addItem(withTitle: "Find…", action: #selector(ConsoleController.showFind), keyEquivalent: "f")
        // Fix 4: ⌘K is the topbar Search control's shortcut too - both invoke
        // the exact same in-terminal find action, targeted explicitly at the
        // app shell (not the responder chain) so it works regardless of
        // which destination or view currently has focus.
        let findInTerminalItem = NSMenuItem(title: "Find in Terminal", action: #selector(AppShellController.activateConsoleFind), keyEquivalent: "k")
        findInTerminalItem.target = appShell
        editMenu.addItem(findInTerminalItem)

        // Hosts menu - the Phase 1 connection manager. New Host targets the
        // panel directly (so it works regardless of focus - the editor now
        // opens as its own window, so this doesn't need the Hosts
        // destination on screen); Show Hosts and Quick Connect route through
        // the shell so the Hosts destination is showing first. The panel's
        // own Connect opens an ssh tab in the console and switches to it
        // (Fix 2: Hosts and Console are decoupled destinations now).
        let hostsMenuItem = NSMenuItem()
        mainMenu.addItem(hostsMenuItem)
        let hostsMenu = NSMenu(title: "Hosts")
        hostsMenuItem.submenu = hostsMenu
        let newHostItem = NSMenuItem(title: "New Host…", action: #selector(HostsSidebarController.newHost), keyEquivalent: "n")
        newHostItem.target = hostsPanel
        hostsMenu.addItem(newHostItem)
        // No keyboard shortcut (⌘K now belongs to Find in Terminal above) -
        // reachable via this menu item or by clicking the Hosts rail icon.
        let quickConnectItem = NSMenuItem(title: "Quick Connect", action: #selector(AppShellController.revealHostsQuickConnect), keyEquivalent: "")
        quickConnectItem.target = appShell
        hostsMenu.addItem(quickConnectItem)
        hostsMenu.addItem(NSMenuItem.separator())
        let showHostsItem = NSMenuItem(title: "Show Hosts", action: #selector(AppShellController.selectHosts), keyEquivalent: "s")
        showHostsItem.keyEquivalentModifierMask = [.command, .control]
        showHostsItem.target = appShell
        hostsMenu.addItem(showHostsItem)

        // Keys menu - the Phase 2 Keychain screen. Both items target the app
        // delegate directly (so they work regardless of focus, like the Hosts
        // menu's New Host / Quick Connect above).
        let keysMenuItem = NSMenuItem()
        mainMenu.addItem(keysMenuItem)
        let keysMenu = NSMenu(title: "Keys")
        keysMenuItem.submenu = keysMenu
        keysMenu.addItem(withTitle: "New Key…", action: #selector(AppDelegate.newKeyFromMenu), keyEquivalent: "n")
            .keyEquivalentModifierMask = [.command, .shift]
        keysMenu.addItem(withTitle: "Manage Keys…", action: #selector(AppDelegate.showKeysWindow), keyEquivalent: "k")
            .keyEquivalentModifierMask = [.command, .shift]
        for item in keysMenu.items { item.target = self }

        // Snippets menu - the Phase 3 saved-command library (B2/B5). Same
        // shape as the Keys menu above.
        let snippetsMenuItem = NSMenuItem()
        mainMenu.addItem(snippetsMenuItem)
        let snippetsMenu = NSMenu(title: "Snippets")
        snippetsMenuItem.submenu = snippetsMenu
        snippetsMenu.addItem(withTitle: "New Snippet…", action: #selector(AppDelegate.newSnippetFromMenu), keyEquivalent: "n")
            .keyEquivalentModifierMask = [.command, .option]
        snippetsMenu.addItem(withTitle: "Manage Snippets…", action: #selector(AppDelegate.showSnippetsWindow), keyEquivalent: "p")
            .keyEquivalentModifierMask = [.command, .option]
        for item in snippetsMenu.items { item.target = self }

        // Tab menu - the dynamic tab collection: new / duplicate / rename / close,
        // reconnect, and ⌘1…⌘9 to jump to a tab. All resolve to ConsoleController.
        let tabMenuItem = NSMenuItem()
        mainMenu.addItem(tabMenuItem)
        let tabMenu = NSMenu(title: "Tab")
        tabMenuItem.submenu = tabMenu
        tabMenu.addItem(withTitle: "New Tab", action: #selector(ConsoleController.newShellTab), keyEquivalent: "t")
        tabMenu.addItem(withTitle: "Duplicate Tab", action: #selector(ConsoleController.duplicateCurrentTab), keyEquivalent: "d")
        let renameItem = NSMenuItem(title: "Rename Tab…", action: #selector(ConsoleController.renameCurrentTab), keyEquivalent: "r")
        renameItem.keyEquivalentModifierMask = [.command, .shift]
        tabMenu.addItem(renameItem)
        tabMenu.addItem(withTitle: "Close Tab", action: #selector(ConsoleController.closeCurrentTab), keyEquivalent: "w")
        tabMenu.addItem(NSMenuItem.separator())
        tabMenu.addItem(withTitle: "Reconnect Tab", action: #selector(ConsoleController.reconnectActive), keyEquivalent: "r")
        let loggingItem = NSMenuItem(title: "Toggle Session Logging", action: #selector(ConsoleController.toggleLoggingForActiveTab), keyEquivalent: "l")
        loggingItem.keyEquivalentModifierMask = [.command, .shift]
        tabMenu.addItem(loggingItem)
        tabMenu.addItem(NSMenuItem.separator())
        // ⌘1…⌘9 select the Nth tab; the tag carries the 1-based index.
        for n in 1...9 {
            let item = NSMenuItem(title: "Select Tab \(n)", action: #selector(ConsoleController.selectTabByShortcut(_:)), keyEquivalent: "\(n)")
            item.tag = n
            tabMenu.addItem(item)
        }

        // View menu - zoom + theme (all resolve to ConsoleController).
        let viewMenuItem = NSMenuItem()
        mainMenu.addItem(viewMenuItem)
        let viewMenu = NSMenu(title: "View")
        viewMenuItem.submenu = viewMenu
        viewMenu.addItem(withTitle: "Zoom In", action: #selector(ConsoleController.zoomIn), keyEquivalent: "+")
        viewMenu.addItem(withTitle: "Zoom Out", action: #selector(ConsoleController.zoomOut), keyEquivalent: "-")
        viewMenu.addItem(withTitle: "Actual Size", action: #selector(ConsoleController.zoomReset), keyEquivalent: "0")
        viewMenu.addItem(NSMenuItem.separator())
        let themeItem = NSMenuItem(title: "Toggle Light/Dark", action: #selector(ConsoleController.toggleTheme), keyEquivalent: "t")
        themeItem.keyEquivalentModifierMask = [.command, .option]
        viewMenu.addItem(themeItem)
        // `fm/cockpit-block-view-terminal`: same shape as the theme toggle above.
        let blockViewItem = NSMenuItem(title: "Toggle Block View", action: #selector(ConsoleController.toggleBlockView), keyEquivalent: "b")
        blockViewItem.keyEquivalentModifierMask = [.command, .option]
        viewMenu.addItem(blockViewItem)

        NSApp.mainMenu = mainMenu
    }
}

// `fm/cockpit-sre-lead-shared-terminal`: `swift build && FM_RUN_SRE_LEAD_BRIDGE_TESTS=1
// .build/debug/FirstmateCockpit` runs `SRELeadBridge`'s self-tests and exits,
// never opening a window - this project builds with Command Line Tools only
// (no Xcode), which has no `XCTest.framework` and, in practice, no working
// `swift test` story for a `swift-testing`-based test target either (see
// `SRELeadBridgeSelfTest.swift`'s header for what was actually tried and why
// it didn't work), so this is the plain, dependency-free stand-in - the same
// "env-var-gated verification, run and read the result" convention this
// codebase already uses for AppKit UI probes (see AGENTS.md's "Verifying
// native UI bugs without a real screenshot"), just kept permanently instead
// of reverted after one use.
if ProcessInfo.processInfo.environment["FM_RUN_SRE_LEAD_BRIDGE_TESTS"] == "1" {
    exit(SRELeadBridgeSelfTest.run() ? 0 : 1)
}

// `fm/cockpit-sre-lead-reply-formatting`: same convention, for
// `SRELeadMarkdown.parse`'s block/callout parsing - see
// `SRELeadMarkdownSelfTest.swift`'s header.
if ProcessInfo.processInfo.environment["FM_RUN_SRE_LEAD_MARKDOWN_TESTS"] == "1" {
    exit(SRELeadMarkdownSelfTest.run() ? 0 : 1)
}

// `fm/cockpit-block-view-terminal`: same convention, for
// `TerminalBlockTracker`'s OSC 133 parsing and its coexistence with
// `SRELeadBridge` - see `TerminalBlockTrackerSelfTest.swift`'s header.
if ProcessInfo.processInfo.environment["FM_RUN_BLOCK_VIEW_TESTS"] == "1" {
    exit(TerminalBlockTrackerSelfTest.run() ? 0 : 1)
}

// `fm/cockpit-block-view-error-explain`: same convention, for the "Explain
// this" action's eligibility rule and its reuse of `SRELeadMarkdown`'s
// renderer - see `BlockExplainSelfTest.swift`.
if ProcessInfo.processInfo.environment["FM_RUN_BLOCK_EXPLAIN_TESTS"] == "1" {
    exit(BlockExplainSelfTest.run() ? 0 : 1)
}


let app = NSApplication.shared
// Regular activation policy so a `swift run`-launched executable gets a real
// Dock icon, menu bar, and key window instead of a background agent.
app.setActivationPolicy(.regular)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
