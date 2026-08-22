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
    // Phase 5 (cockpit-shift-power-features): one `ShiftStore` shared by the
    // main window's Shift page, the menu bar item, the search palette, and
    // quick capture - all read/write the same tasks/follow-ups, never
    // separate store instances that could drift out of sync with each other.
    let shiftStore = ShiftStore()
    lazy var console = ConsoleController(keyStore: keyStore, snippetStore: snippetStore)
    // Phase 5 of the full-app UI audit merged the Hosts destination and the
    // two floating SSH Keys / Snippets windows into one destination with
    // three segmented tabs, so this is now the only controller for all three
    // stores' browsing/editing surfaces.
    lazy var hostsPanel = HostsController(hostStore: hostStore, keyStore: keyStore, snippetStore: snippetStore)
    lazy var settingsController = SettingsController(hostStore: hostStore, keyStore: keyStore, snippetStore: snippetStore, dictationStore: dictationStore)
    lazy var shiftMenuBar = ShiftMenuBarController(store: shiftStore)
    lazy var shiftSearch = ShiftSearchController(store: shiftStore)
    // Phase 4 ("Knowledge and speed"): the unified `⌘K` search palette. Its
    // own `DocsRunbookStore` instance (not `appShell`'s private one inside
    // `DocsController`) - both read the same git-synced folder fresh on every
    // call, so a second instance costs nothing and needs no plumbing through
    // `AppShellController`'s constructor, mirroring how `UpdatesController`/
    // `BootstrapController` already keep independent copies of the same
    // underlying checks (see AGENTS.md).
    lazy var unifiedSearch = UnifiedSearchController(store: DocsRunbookStore())
    lazy var shiftQuickCapture = ShiftQuickCaptureController(store: shiftStore)
    lazy var shiftNotifications = ShiftNotificationScheduler(store: shiftStore)
    lazy var shiftHotkey = ShiftGlobalHotkey { [weak self] in self?.shiftQuickCapture.present() }
    // fm/grandline-dictation-mvp (phase 1): one `DictationEngine` for the
    // app's whole lifetime, driven by `DictationHotkey`'s hold/release
    // callbacks - mirrors `shiftHotkey`/`shiftQuickCapture`'s own shape.
    let dictationEngine = DictationEngine()
    // Phase 2 (fm/grandline-dictation-phase2): transcription history +
    // personal vocabulary, shared by the Dictation page and the engine
    // (vocabulary bias, history recording) - same "one store, every reader/
    // writer shares it" convention as `shiftStore`.
    let dictationStore = DictationStore()
    // GL-23: one command library for the whole app. The Tasks page's DevOps
    // Commands tab and the Log Analyzer's "from your library" matching both
    // read and write it; two caching instances diverged in-session and
    // last-writer-wins on `recent.yaml`. Same one-store convention as
    // `shiftStore` and `dictationStore` above.
    let commandLibraryStore = CommandLibraryStore()
    // fm/grandline-dictation-visual-feedback-hud: the floating on-screen HUD
    // - see DictationHUD.swift's header. Owned here (not by `AppShellController`)
    // since it must appear regardless of whether Grand Line's own window is
    // visible/frontmost.
    let dictationHUD = DictationHUDController()
    // GL-09: dictation is gated on the lock here rather than inside
    // `DictationEngine`, because the gate belongs where the *trigger* is - a
    // hotkey that fires while locked should do nothing at all, not start an
    // engine that then declines. `onUp` is deliberately NOT gated: a recording
    // that was legitimately started before the lock engaged still has to be
    // stopped, or the microphone stays open.
    lazy var dictationHotkey = DictationHotkey(
        shortcut: AppSettings.shared.dictationShortcut,
        onDown: { [weak self] in
            guard AppLockGate.shared.allows(.dictation) else {
                AppLog.lifecycle.info("dictation hotkey refused - app is locked (GL-09)")
                return
            }
            self?.dictationEngine.startRecording()
        },
        onUp: { [weak self] in self?.dictationEngine.stopRecording() }
    )
    // fm/grandline-app-lock: the app-level password lock's timing state
    // machine - see AppLock.swift's header for the idle/hard-logout math.
    let appLock = AppLockController()
    // Fix 1: `makeHostConsole` builds a fresh, host-scoped console (no
    // Mirror/Shell tabs) for `AppShellController.connectHost` - captured as
    // local constants (not `self`) so this closure, which `appShell` holds
    // onto for its whole lifetime, can't form a retain cycle with `self`.
    lazy var appShell: AppShellController = {
        let keyStore = self.keyStore
        let snippetStore = self.snippetStore
        return AppShellController(
            hostsPanel: hostsPanel, console: console, settings: settingsController,
            hostStore: hostStore, keyStore: keyStore, snippetStore: snippetStore, shiftStore: shiftStore,
            dictationStore: dictationStore, commandLibraryStore: commandLibraryStore,
            makeHostConsole: { ConsoleController(keyStore: keyStore, snippetStore: snippetStore, isFirstmateConsole: false) }
        )
    }()
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
        // Finding 4 (cockpit-audit-core): a corrupted hosts.json comes up as
        // an empty list with no other signal - surface that once here rather
        // than letting the captain mistake it for "nothing saved yet".
        if let backupPath = hostStore.loadFailureBackupPath {
            appShell.showToast("Couldn't read saved hosts - backed up the old file to \((backupPath as NSString).lastPathComponent)")
        }
        // GL-01: the same treatment for the three stores that used to fail
        // *silently*. Backing the file up is the durability half; saying so is
        // what makes it recoverable - a captain who is never told will not go
        // looking for a `.corrupt-` file. Staged over a second apart so two
        // simultaneous failures do not overwrite each other's toast.
        //
        // Keys first and most emphatically: losing key metadata orphans the
        // Keychain blobs those entries pointed at, and nothing else can clean
        // them up afterwards.
        var storeFailureNotices: [String] = []
        if let backupPath = keyStore.loadFailureBackupPath {
            storeFailureNotices.append("Couldn't read saved SSH keys - backed up to \((backupPath as NSString).lastPathComponent). "
                + "Keychain entries for those keys are still there.")
        }
        if let backupPath = snippetStore.loadFailureBackupPath {
            storeFailureNotices.append("Couldn't read saved snippets - backed up to \((backupPath as NSString).lastPathComponent)")
        }
        for backupPath in dictationStore.loadFailureBackupPaths {
            storeFailureNotices.append("Couldn't read a dictation file - backed up to \((backupPath as NSString).lastPathComponent)")
        }
        for (index, notice) in storeFailureNotices.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5 + Double(index) * 4) { [weak self] in
                self?.appShell.showToast(notice)
            }
        }
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
        // The Snippets tab's "Run" (Phase 3, B2) sends straight to the
        // console's active tab.
        appShell.onRunSnippet = { [weak self] snippet in
            self?.console.runSnippetInActiveTab(snippet)
        }
        // Settings > Terminal's font-size stepper (Fix 3) talks straight to
        // the live console; Appearance goes through `ThemeManager` directly
        // since every theme-aware view already observes it.
        settingsController.onFontSizeStep = { [weak self] delta in
            self?.console.stepFontSize(by: delta)
        }

        // Settings > Terminal's "Bell & notifications" toggle (Fix 3): this
        // only ever gates whether a macOS banner is ALSO posted for a
        // needs-decision/blocked task - see `FleetNotifier.setEnabled`'s own
        // comment. `FleetNotifier.shared.start()` below always runs
        // regardless, since the in-app Notification Center
        // (`fm/grandline-notification-center`) must stay current whether or
        // not the captain wants OS banners too.
        FleetNotifier.shared.setEnabled(AppSettings.shared.notifyOnNeedsDecision)
        FleetNotifier.shared.onNavigateToOverview = { [weak self] in self?.appShell.show(.overview) }
        FleetNotifier.shared.start()

        // fm/grandline-notification-center: the slow background poll for the
        // four signals that otherwise only ever recompute on a page visit
        // (tool updates, GitHub Sync drift, Vault attention, Bootstrap
        // setup drift) - see `BackgroundSignalsPoller.swift`'s header for
        // the cadence tradeoff.
        BackgroundSignalsPoller.shared.onNavigateToUpdates = { [weak self] in self?.appShell.show(.updates) }
        BackgroundSignalsPoller.shared.onNavigateToGitHubSync = { [weak self] in self?.appShell.show(.githubSync) }
        BackgroundSignalsPoller.shared.onNavigateToVault = { [weak self] in self?.appShell.show(.vault) }
        BackgroundSignalsPoller.shared.onNavigateToBootstrap = { [weak self] in self?.appShell.show(.bootstrap) }
        BackgroundSignalsPoller.shared.start()

        // Phase 5 (cockpit-shift-power-features): search palette + menu bar
        // popover + global quick capture + due-item notifications. All four
        // read/write the one shared `shiftStore` above - never a second
        // instance.
        shiftSearch.onSelectTask = { [weak self] id in self?.appShell.openShiftTask(id: id) }
        shiftSearch.onSelectFollowUp = { [weak self] id in self?.appShell.openShiftFollowUp(id: id) }
        shiftSearch.onSelectProject = { [weak self] id in self?.appShell.openShiftProject(id: id) }
        // Phase 4 ("Knowledge and speed"): `⌘K` now opens this unified
        // palette app-wide - both its own click (the topbar Search pill,
        // wired below) and the main menu's `⌘K` item resolve here.
        unifiedSearch.onSelectRunbook = { [weak self] id in self?.appShell.openDocsRunbook(id: id) }
        unifiedSearch.onSelectPostmortem = { [weak self] id in self?.appShell.openDocsPostmortem(id: id) }
        // The topbar Search pill's click, forwarded through `AppShellController.
        // onSearchTapped` (see that property's own doc comment) - not
        // `appShell.topBar.onSearchTapped` directly, since `loadView()` (run
        // later, once `window.contentViewController = appShell` is assigned
        // below) wires that control to call back through this property, and
        // would silently clobber a direct assignment made before that point.
        appShell.onSearchTapped = { [weak self] in self?.unifiedSearch.present() }
        shiftQuickCapture.onCaptured = { [weak self] in
            self?.appShell.showToast("Task captured")
        }
        // The global hotkey's system-wide (other-app-frontmost) case needs
        // Accessibility permission - see `ShiftGlobalHotkey`'s header for
        // exactly why. Requesting it here (once, at launch) surfaces the
        // real macOS prompt the first time this app ever runs rather than
        // silently failing later.
        shiftHotkey.requestPermissionIfNeeded()
        shiftHotkey.start()
        // fm/grandline-notification-center: feeds the same due-detection
        // `poll()` already computes for the OS banner into the in-app
        // Notification Center too, rather than only firing a one-shot
        // banner with no record afterward.
        shiftNotifications.onDueCountsChanged = { [weak self] taskCount, followUpCount in
            NotificationSources.setShiftDue(taskCount: taskCount, followUpCount: followUpCount) {
                self?.appShell.showShiftDestination()
            }
        }
        shiftNotifications.start()

        // fm/grandline-dictation-mvp: unlike `shiftHotkey` above, Dictation
        // deliberately does NOT request Accessibility trust eagerly at
        // launch - the task brief asks each Dictation permission to be
        // requested "the first time it's genuinely needed," which for
        // Accessibility is the Dictation page's own status action (or, if
        // Shift's own eager request above already granted it, this monitor
        // just starts working with no further prompt needed - it's the same
        // one process-wide Accessibility trust grant). The hotkey's
        // local+global monitors are still registered now regardless -
        // registering them is free and has nothing to do with whether the
        // grant exists yet.
        dictationEngine.onStatusChanged = { [weak self] status, isCeilingTimeout in
            self?.appShell.setDictationEngineStatus(status)
            self?.dictationHUD.handle(status, isCeilingTimeout: isCeilingTimeout)
        }
        // Phase 2: bias recognition toward the captain's personal vocabulary,
        // and record every successful (real, pasted) transcript into
        // history - both read/write the one shared `dictationStore` above.
        dictationEngine.vocabularyProvider = { [weak self] in self?.dictationStore.vocabulary ?? [] }
        // Phase 3: read the "Clean up my sentences" toggle fresh at the
        // moment each dictation finishes - see `AppSettings.dictationCleanupEnabled`'s
        // own doc comment for why this defaults to off.
        dictationEngine.cleanupEnabledProvider = { AppSettings.shared.dictationCleanupEnabled }
        // fm/grandline-dictation-whisper-engine: read the "Use local Whisper
        // engine" toggle fresh at the start of every recording - see
        // `AppSettings.dictationLocalWhisperEnabled`'s own doc comment for
        // why this defaults to off.
        dictationEngine.localWhisperEnabledProvider = { AppSettings.shared.dictationLocalWhisperEnabled }
        dictationEngine.onTranscript = { [weak self] text, duration in
            self?.dictationStore.recordHistory(text: text, durationSeconds: duration, date: Date())
        }
        // Phase 2: the Dictation page's shortcut recorder edits
        // `AppSettings.dictationShortcut` itself and reports the change here
        // so the *live* hotkey instance actually picks it up - a plain
        // settings write with no restart would leave the old monitor
        // installed (see `DictationHotkey.updateShortcut`'s own header).
        appShell.onDictationShortcutChanged = { [weak self] shortcut in
            self?.dictationHotkey.updateShortcut(shortcut)
        }
        dictationHotkey.start()

        // `shiftMenuBar` is `lazy` - force it into existence now so its
        // `NSStatusItem` actually appears at launch rather than only the
        // first time something else happens to reference the property.
        _ = shiftMenuBar

        buildMenu()

        // fm/grandline-app-lock: wire the lock state machine to the shell's
        // overlay and to the menu-disable safety net below. The actual
        // `.launch` lock happens further down, *after* `window.contentViewController
        // = appShell` below has forced `AppShellController.loadView()` to run
        // at least once - `showLock` sets `lockScreen.view.isHidden = false`,
        // but `loadView()` itself unconditionally sets that same property to
        // `true` right after embedding the view (its default hidden state);
        // locking before `loadView()` has ever run meant that default-hidden
        // assignment executed *after* `showLock`'s and silently re-hid the
        // overlay - confirmed live (a real launch dump showed
        // `overlayHidden=true` immediately after `showLock` had already run
        // and correctly disabled the menu). Locking after the window/
        // contentViewController assignment below closes that race.
        appLock.onLock = { [weak self] reason in self?.appShell.showLock(reason: reason) }
        appShell.onUnlocked = { [weak self] in self?.appLock.recordUnlock() }
        appShell.onLogoutRequested = { [weak self] in self?.appLock.lock(reason: .manualLogout) }
        appShell.onLockStateChanged = { [weak self] locked in self?.setContentMenusEnabled(!locked) }
        appLock.start()

        // The window opens filling the screen's usable area, not a hardcoded
        // 1220x720 box.
        //
        // This is **half** of the captain's "the window doesn't cover the
        // laptop screen" report (`01-live-window-not-fullscreen.png`): a fixed
        // content rect plus `center()` meant the window simply never asked for
        // more than 1220x720. The other half was a real Auto Layout constraint
        // that capped the window at 1410pt wide no matter what was asked for,
        // including in genuine full screen - see the priority note on
        // `ToolRowLayout.build`'s name-column constraint
        // (`HelmUIComponents.swift`). Both had to go; either one alone still
        // left black bars.
        //
        // `visibleFrame` (not `frame`) so the menu bar and the Dock are
        // excluded, and it is applied as the *window* frame (title bar
        // included) so nothing is pushed off the top of the screen.
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1220, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Manjesh Grand Line"
        // **`contentViewController` first, then the frame.** Assigning a
        // content view controller makes AppKit re-derive the window's frame
        // from that content's Auto Layout fitting size (AGENTS.md's
        // host-editor gotcha (3), in its milder form) - so setting the frame
        // *before* this line is silently undone. Measured with a real window:
        // set to 1512x950 and then given a content view controller, it came
        // back 960x652, i.e. exactly `contentMinSize` plus the title bar.
        window.contentViewController = appShell
        window.contentMinSize = Self.minContentSize
        window.setFrame(Self.defaultWindowFrame(), display: false)
        // `setFrameAutosaveName` after the frame is set: with no saved frame
        // yet (first launch on this machine) AppKit keeps what we just asked
        // for, and from then on the captain's own resize/zoom is what is
        // restored - so this sets a sane default without overriding a
        // deliberate later choice.
        window.setFrameAutosaveName(Self.windowAutosaveName)
        // Theme-audit task: the window's own chrome (title bar) has no view
        // to force `.appearance` on, so without this it always follows the
        // OS's actual light/dark setting rather than the active Helm theme.
        window.followHelmTheme()

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        // `loadView()` has now run at least once (triggered by the
        // `contentViewController` assignment above) - lock now so the very
        // first frame the captain sees is the lock screen, not the console.
        appLock.lock(reason: .launch)

    }

    /// The main window's saved-frame key. Once the captain resizes or zooms
    /// the window, AppKit restores that instead of the default below.
    static let windowAutosaveName = "GrandLineMainWindow"

    /// Never smaller than this. Deliberately below any real Mac's usable
    /// height so it can never fight `defaultWindowFrame` - it only stops the
    /// captain dragging the window down to a size where the destinations
    /// stop being readable.
    static let minContentSize = NSSize(width: 960, height: 620)

    /// The screen's usable area - menu bar and Dock excluded. This is the
    /// *window* frame (title bar included), so the title bar stays on screen.
    /// Falls back to the old fixed size only when there is no screen at all
    /// to measure (a headless / self-test launch).
    static func defaultWindowFrame() -> NSRect {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else {
            return NSRect(x: 0, y: 0, width: 1220, height: 720)
        }
        return screen.visibleFrame
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
        shiftHotkey.stop()
        shiftNotifications.stop()
        BackgroundSignalsPoller.shared.stop()
        dictationHotkey.stop()
        appLock.stop()
    }

    // MARK: App-level password lock (fm/grandline-app-lock)

    /// The lock overlay is opaque and topmost, so mouse clicks on rail/body
    /// content underneath it are already blocked by ordinary AppKit hit-
    /// testing - but most of this app's menu items have a concrete `target`
    /// (not `nil`, routed through the first-responder chain), so a keyboard
    /// shortcut like ⌘N or ⌘T would otherwise still reach its destination's
    /// action even while that destination is hidden behind the overlay. This
    /// is the one choke point that closes that gap: every submenu except
    /// Edit (Cut/Copy/Paste/Select All/Find are all `nil`-target, responder-
    /// chain-routed items - while locked, the only thing that can ever be
    /// first responder is the lock screen's own password field, so leaving
    /// these enabled is what lets a captain paste a password from a manager
    /// via ⌘V rather than breaking that) gets disabled while locked, minus
    /// the App menu's Hide/Quit (still allowed, same as any other macOS app).
    private func setContentMenusEnabled(_ enabled: Bool) {
        guard let mainMenu = NSApp.mainMenu else { return }
        let appName = ProcessInfo.processInfo.processName
        for topLevelItem in mainMenu.items {
            guard let submenu = topLevelItem.submenu, submenu.title != "Edit" else { continue }
            for item in submenu.items {
                // GL-17 added Hide Others/Show All next to Hide; they are the
                // same class of item (system-level app visibility, disclosing
                // and writing nothing of this app's data), so they stay enabled
                // while locked for the same reason Hide and Quit do.
                if item.title == "Hide \(appName)" || item.title == "Quit \(appName)"
                    || item.title == "Hide Others" || item.title == "Show All" { continue }
                item.isEnabled = enabled
            }
        }
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
        let existingLabels = Set(hostStore.hosts.filter { $0.id != host?.id }.map { $0.label } + ["Firstmate"])
        let editor = HostEditorController(host: host, keyStore: keyStore, snippets: snippetStore.snippets, existingLabels: existingLabels)
        editor.onSave = { [weak self] saved in
            guard let self else { return }
            if self.hostStore.host(id: saved.id) != nil {
                self.hostStore.update(saved)
            } else {
                self.hostStore.add(saved)
            }
            self.appShell.showToast("\u{201C}\(saved.label)\u{201D} saved")
        }
        // GL-06: the host editor window's Delete button was unconfirmed too,
        // and deleting a host also tears down that host's live console page
        // (see `HostStore.observe` in `applicationDidFinishLaunching`). Same
        // copy as the Hosts list's own row-level confirmation, via the one
        // shared prompt. Deferred a runloop turn because `deleteHost()` closes
        // the editor window right after this returns.
        editor.onDelete = { [weak self] id in
            DispatchQueue.main.async {
                guard let self, let host = self.hostStore.host(id: id) else { return }
                guard DestructiveConfirm.confirm(
                    message: "Delete \u{201C}\(host.label)\u{201D}?",
                    detail: "This removes the saved host and closes its console page. "
                          + "It does not affect any running session."
                ) else { return }
                self.hostStore.delete(id: id)
            }
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
            // GL-09: a `.floating` window stays above the lock overlay - which
            // is a subview of the *main* window, not a screen-level shield - so
            // a Host Editor open at lock time remained fully usable, editing and
            // saving real host records. Registered once, when the window is
            // created; the gate orders it out on every lock.
            AppLockGate.shared.registerSecondaryWindow { [weak self] in self?.hostEditorWindow }
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

    // MARK: Shift power features (phase 5)

    @objc func showShiftSearch() {
        shiftSearch.present()
    }

    @objc func showShiftQuickCapture() {
        shiftQuickCapture.present()
    }

    // MARK: Unified search (phase 4, "Knowledge and speed")

    @objc func showUnifiedSearch() {
        unifiedSearch.present()
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
        // GL-17: Services, plus the standard Hide Others / Show All trio a Mac
        // user expects to find here. `NSApp.servicesMenu` is what makes the
        // system populate the submenu; without the assignment it stays empty.
        let servicesItem = appMenu.addItem(withTitle: "Services", action: nil, keyEquivalent: "")
        let servicesMenu = NSMenu(title: "Services")
        servicesItem.submenu = servicesMenu
        NSApp.servicesMenu = servicesMenu
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "Hide \(appName)", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = appMenu.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(NSMenuItem.separator())
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
        // Phase 4 ("Knowledge and speed") reassigned ⌘K from "Find in
        // Terminal" (Fix 4's original mapping) to the real unified search
        // palette below - plain find-in-terminal stays reachable with no
        // shortcut here (same "menu item only, no keyEquivalent" convention
        // as "Quick Connect" below) since the console toolbar's own
        // magnifying-glass icon already triggers the identical action
        // independently of any menu shortcut, and ⌘F ("Find…" above) covers
        // the common case too.
        let findInTerminalItem = NSMenuItem(title: "Find in Terminal", action: #selector(AppShellController.activateConsoleFind), keyEquivalent: "")
        findInTerminalItem.target = appShell
        editMenu.addItem(findInTerminalItem)
        // Phase 4: ⌘K now opens the unified search palette (Runbooks +
        // Postmortems - see `UnifiedSearch.swift`'s header for why terminal
        // history isn't included yet), matching the topbar Search pill's own
        // ⌘K badge.
        let unifiedSearchItem = NSMenuItem(title: "Search…", action: #selector(AppDelegate.showUnifiedSearch), keyEquivalent: "k")
        unifiedSearchItem.target = self
        editMenu.addItem(unifiedSearchItem)

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
        let newHostItem = NSMenuItem(title: "New Host…", action: #selector(HostsController.newHost), keyEquivalent: "n")
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

        // Shift menu (cockpit-shift-create-edit, phase 2) - task/follow-up
        // creation. Both items target the app shell directly (like the Hosts
        // menu's "New Host…" above), so they work regardless of which
        // destination is currently showing - the shell switches to `.shift`
        // itself before presenting the sheet.
        let shiftMenuItem = NSMenuItem()
        mainMenu.addItem(shiftMenuItem)
        let shiftMenu = NSMenu(title: "Tasks")
        shiftMenuItem.submenu = shiftMenu
        let newTaskItem = NSMenuItem(title: "New Task…", action: #selector(AppShellController.newShiftTaskFromMenu), keyEquivalent: "n")
        newTaskItem.target = appShell
        shiftMenu.addItem(newTaskItem)
        let newFollowUpItem = NSMenuItem(title: "New Follow-up…", action: #selector(AppShellController.newShiftFollowUpFromMenu), keyEquivalent: "f")
        newFollowUpItem.keyEquivalentModifierMask = [.command, .shift]
        newFollowUpItem.target = appShell
        shiftMenu.addItem(newFollowUpItem)
        // cockpit-fix-shift-new-project: no keyEquivalent - ⌘⇧P is already
        // "Search Shift…" below, and this menu follows that item's own
        // no-shortcut precedent ("Weekly Review") rather than force a
        // collision.
        let newProjectItem = NSMenuItem(title: "New Project…", action: #selector(AppShellController.newShiftProjectFromMenu), keyEquivalent: "")
        newProjectItem.target = appShell
        shiftMenu.addItem(newProjectItem)
        shiftMenu.addItem(NSMenuItem.separator())
        // Phase 5 (cockpit-shift-power-features): ⌘⇧P rather than the
        // reviewed mockup's own ⌘K, which this app already bound to "Find in
        // Terminal" above, well before this phase existed.
        let searchShiftItem = NSMenuItem(title: "Search Tasks…", action: #selector(AppDelegate.showShiftSearch), keyEquivalent: "p")
        searchShiftItem.keyEquivalentModifierMask = [.command, .shift]
        searchShiftItem.target = self
        shiftMenu.addItem(searchShiftItem)
        let weeklyReviewItem = NSMenuItem(title: "Weekly Review", action: #selector(AppShellController.showShiftWeeklyReview), keyEquivalent: "")
        weeklyReviewItem.target = appShell
        shiftMenu.addItem(weeklyReviewItem)
        // In-app fallback for quick capture's global ⌥Space hotkey (see
        // `ShiftGlobalHotkey`'s header) - works with no Accessibility
        // permission at all as long as this app is frontmost, so it's a
        // meaningful discoverability aid even before that permission is
        // granted.
        let quickCaptureItem = NSMenuItem(title: "Quick Capture", action: #selector(AppDelegate.showShiftQuickCapture), keyEquivalent: " ")
        quickCaptureItem.keyEquivalentModifierMask = [.option]
        quickCaptureItem.target = self
        shiftMenu.addItem(quickCaptureItem)

        // Log Analyzer menu (`fm/grandline-log-analyzer-build`, spec §24).
        //
        // **Shortcut collisions were checked against this file, not assumed.**
        // ⌘⇧L / ⌘⇧C / ⌘⇧T / ⌘⇧I were all genuinely free. ⌘⇧R was NOT - the
        // Tab menu's "Rename Tab…" below already owns it - so spec §24's
        // "⌘⇧R Create RCA" is bound to **⌘⇧A** instead (A for "after-action
        // review"), which is free; taking ⌘⇧R would have silently broken an
        // already-shipped shortcut. ⌘↵ (Analyze) is not a menu item at all:
        // it is `analyzeButton`'s own `keyEquivalent`, so it only fires while
        // the page is on screen rather than analyzing from any destination.
        // Esc is handled by `LogAnalyzerController.cancelOperation`, the
        // responder-chain path, for the same reason.
        let logAnalyzerMenuItem = NSMenuItem()
        mainMenu.addItem(logAnalyzerMenuItem)
        let logAnalyzerMenu = NSMenu(title: "Log Analyzer")
        logAnalyzerMenuItem.submenu = logAnalyzerMenu

        let openAnalyzerItem = NSMenuItem(title: "Open Log Analyzer",
                                          action: #selector(AppShellController.showLogAnalyzer), keyEquivalent: "l")
        openAnalyzerItem.keyEquivalentModifierMask = [.command, .shift]
        logAnalyzerMenu.addItem(openAnalyzerItem)

        let analyzeClipboardItem = NSMenuItem(title: "Analyze Clipboard",
                                              action: #selector(AppShellController.analyzeClipboardInLogAnalyzer),
                                              keyEquivalent: "")
        logAnalyzerMenu.addItem(analyzeClipboardItem)
        logAnalyzerMenu.addItem(NSMenuItem.separator())

        let copyAnalysisItem = NSMenuItem(title: "Copy Analysis",
                                          action: #selector(AppShellController.logAnalyzerCopyAnalysis), keyEquivalent: "c")
        copyAnalysisItem.keyEquivalentModifierMask = [.command, .shift]
        logAnalyzerMenu.addItem(copyAnalysisItem)

        let sendToTerminalItem = NSMenuItem(title: "Send Top Command to Terminal",
                                            action: #selector(AppShellController.logAnalyzerSendToTerminal), keyEquivalent: "t")
        sendToTerminalItem.keyEquivalentModifierMask = [.command, .shift]
        logAnalyzerMenu.addItem(sendToTerminalItem)

        let investigateItem = NSMenuItem(title: "Investigate Further",
                                         action: #selector(AppShellController.logAnalyzerInvestigateFurther), keyEquivalent: "i")
        investigateItem.keyEquivalentModifierMask = [.command, .shift]
        logAnalyzerMenu.addItem(investigateItem)

        let createRCAItem = NSMenuItem(title: "Create RCA",
                                       action: #selector(AppShellController.logAnalyzerCreateRCA), keyEquivalent: "a")
        createRCAItem.keyEquivalentModifierMask = [.command, .shift]
        logAnalyzerMenu.addItem(createRCAItem)

        for item in logAnalyzerMenu.items { item.target = appShell }

        // Keys menu - the Phase 2 Keychain screen. Both items target the app
        // shell (so they work regardless of focus, like the Hosts menu's New
        // Host / Quick Connect above). Phase 5 of the full-app UI audit folded
        // this screen into the Hosts destination as a segmented tab, so
        // "Manage Keys…" now selects that tab instead of opening a window -
        // the shortcuts and titles are unchanged.
        let keysMenuItem = NSMenuItem()
        mainMenu.addItem(keysMenuItem)
        let keysMenu = NSMenu(title: "Keys")
        keysMenuItem.submenu = keysMenu
        keysMenu.addItem(withTitle: "New Key…", action: #selector(AppShellController.newKeyFromMenu), keyEquivalent: "n")
            .keyEquivalentModifierMask = [.command, .shift]
        keysMenu.addItem(withTitle: "Manage Keys…", action: #selector(AppShellController.selectKeys), keyEquivalent: "k")
            .keyEquivalentModifierMask = [.command, .shift]
        for item in keysMenu.items { item.target = appShell }

        // Snippets menu - the Phase 3 saved-command library (B2/B5). Same
        // shape as the Keys menu above, and folded into the same destination
        // by the same phase.
        let snippetsMenuItem = NSMenuItem()
        mainMenu.addItem(snippetsMenuItem)
        let snippetsMenu = NSMenu(title: "Snippets")
        snippetsMenuItem.submenu = snippetsMenu
        snippetsMenu.addItem(withTitle: "New Snippet…", action: #selector(AppShellController.newSnippetFromMenu), keyEquivalent: "n")
            .keyEquivalentModifierMask = [.command, .option]
        snippetsMenu.addItem(withTitle: "Manage Snippets…", action: #selector(AppShellController.selectSnippets), keyEquivalent: "p")
            .keyEquivalentModifierMask = [.command, .option]
        for item in snippetsMenu.items { item.target = appShell }

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

        // GL-17: Window and Help. Before this, ⌘M did nothing at all, there
        // was no Zoom or Bring All to Front, and there was no Help menu despite
        // `setup-guide.md` living in the repo - the first three things a
        // discerning Mac user checks.
        //
        // `NSApp.windowsMenu` is the load-bearing line: assigning it is what
        // makes AppKit itself maintain the list of open windows underneath the
        // separator, so a floating Host Editor or a secondary panel shows up
        // without this file tracking windows by hand.
        let windowMenuItem = NSMenuItem()
        mainMenu.addItem(windowMenuItem)
        let windowMenu = NSMenu(title: "Window")
        windowMenuItem.submenu = windowMenu
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenu.addItem(NSMenuItem.separator())
        windowMenu.addItem(withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        NSApp.windowsMenu = windowMenu

        let helpMenuItem = NSMenuItem()
        mainMenu.addItem(helpMenuItem)
        let helpMenu = NSMenu(title: "Help")
        helpMenuItem.submenu = helpMenu
        // Both open a real file that ships in this repo, resolved at click
        // time (see `openRepoDoc`) rather than assumed to exist - the app can
        // be running from a bundle whose source tree has moved.
        helpMenu.addItem(withTitle: "Grand Line Setup Guide", action: #selector(openSetupGuide), keyEquivalent: "?")
            .target = self
        helpMenu.addItem(withTitle: "Read Me", action: #selector(openReadme), keyEquivalent: "")
            .target = self
        NSApp.helpMenu = helpMenu

        NSApp.mainMenu = mainMenu
    }

    // MARK: Help menu (GL-17)

    /// Opens a doc that lives at the repo root, next to `native/`. Resolved
    /// from `FirstmateHome`'s own resolution first (the captain's real
    /// checkout), then relative to this executable for a `swift run` build.
    /// Shows a plain alert rather than failing silently if neither exists -
    /// a Help item that does nothing is worse than no Help item.
    private func openRepoDoc(named name: String) {
        var candidates: [URL] = []
        // A bundled app sits at <repo>/dist/<App>.app/Contents/MacOS/<exe>;
        // a `swift build` binary at <repo>/native/.build/<config>/<exe>.
        let exe = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        var dir = exe.deletingLastPathComponent()
        for _ in 0..<6 {
            candidates.append(dir.appendingPathComponent(name))
            dir = dir.deletingLastPathComponent()
        }
        guard let found = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) else {
            let alert = NSAlert()
            alert.messageText = "Couldn't find \(name)"
            alert.informativeText = "It ships at the root of the Manjesh Grand Line repository, "
                + "next to the `native/` directory. This build couldn't locate that checkout."
            alert.alertStyle = .informational
            alert.runModal()
            return
        }
        NSWorkspace.shared.open(found)
    }

    @objc private func openSetupGuide() { openRepoDoc(named: "setup-guide.md") }
    @objc private func openReadme() { openRepoDoc(named: "README.md") }
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

// `fm/grandline-sre-lead-per-tab`: same convention, for the real
// `ConsoleController` per-tab SRE Lead integration (independent phases, no
// chat cross-talk, tab-switch rebinding, the 5-tab cap, per-tab teardown on
// close) - see `SRELeadPerTabSelfTest.swift`'s header.
if ProcessInfo.processInfo.environment["FM_RUN_SRE_LEAD_PER_TAB_TESTS"] == "1" {
    exit(SRELeadPerTabSelfTest.run() ? 0 : 1)
}

// `fm/cockpit-sre-lead-reply-formatting`: same convention, for
// `SRELeadMarkdown.parse`'s block/callout parsing - see
// `SRELeadMarkdownSelfTest.swift`'s header.
if ProcessInfo.processInfo.environment["FM_RUN_SRE_LEAD_MARKDOWN_TESTS"] == "1" {
    exit(SRELeadMarkdownSelfTest.run() ? 0 : 1)
}

// fm/cockpit-local-state-portable: same convention, for the export/import/
// diff/apply path - see `BackupSelfTest.swift`'s header.
if ProcessInfo.processInfo.environment["FM_RUN_BACKUP_TESTS"] == "1" {
    exit(BackupSelfTest.run() ? 0 : 1)
}

// fm/cockpit-tools-page-diff: same convention, for `DiffEngine`'s line/word
// LCS diffing - see `DiffEngineSelfTest.swift`'s header.
if ProcessInfo.processInfo.environment["FM_RUN_DIFF_ENGINE_TESTS"] == "1" {
    exit(DiffEngineSelfTest.run() ? 0 : 1)
}

// cockpit-tools-page-specialist: same convention, for the cron next-run
// explainer, the resource-unit converter, and the certificate inspector -
// see each self-test file's own header.
if ProcessInfo.processInfo.environment["FM_RUN_CRON_EXPLAINER_TESTS"] == "1" {
    exit(CronExplainerSelfTest.run() ? 0 : 1)
}
if ProcessInfo.processInfo.environment["FM_RUN_RESOURCE_UNITS_TESTS"] == "1" {
    exit(ResourceUnitsSelfTest.run() ? 0 : 1)
}
if ProcessInfo.processInfo.environment["FM_RUN_TERMINAL_WRAP_REDRAW_TESTS"] == "1" {
    exit(TerminalWrapRedrawSelfTest.run() ? 0 : 1)
}
if ProcessInfo.processInfo.environment["FM_RUN_CERT_INSPECTOR_TESTS"] == "1" {
    exit(CertInspectorSelfTest.run() ? 0 : 1)
}

// fm/cockpit-tools-yaml-order-perf-fix: same convention, for YamlBeautify's
// key-order fidelity - see YamlBeautifySelfTest.swift's header.
if ProcessInfo.processInfo.environment["FM_RUN_YAML_BEAUTIFY_TESTS"] == "1" {
    exit(YamlBeautifySelfTest.run() ? 0 : 1)
}

// cockpit-shift-foundation: same convention, for ShiftStore's completion/
// reopen file-move logic and YAML scalar fidelity - see
// ShiftStoreSelfTest.swift's header.
if ProcessInfo.processInfo.environment["FM_RUN_SHIFT_STORE_TESTS"] == "1" {
    exit(ShiftStoreSelfTest.run() ? 0 : 1)
}

// fm/grandline-devops-command-library: same convention, for the DevOps
// Command Library's parameter detection/substitution/search/favorites - see
// CommandLibraryStoreSelfTest.swift's header.
if ProcessInfo.processInfo.environment["FM_RUN_COMMAND_LIBRARY_TESTS"] == "1" {
    exit(CommandLibraryStoreSelfTest.run() ? 0 : 1)
}

// cockpit-shift-create-edit: same convention, for `ShiftDateParser`'s
// natural-language date/time detection - see `ShiftDateParserSelfTest.swift`'s
// header.
if ProcessInfo.processInfo.environment["FM_RUN_SHIFT_DATE_PARSER_TESTS"] == "1" {
    exit(ShiftDateParserSelfTest.run() ? 0 : 1)
}

// cockpit-shift-git-sync: same convention, for `ShiftGitSync`'s clone/commit/
// push/pull/debounce/status logic against a real disposable local bare repo -
// see ShiftGitSyncSelfTest.swift's header.
if ProcessInfo.processInfo.environment["FM_RUN_SHIFT_GIT_SYNC_TESTS"] == "1" {
    exit(ShiftGitSyncSelfTest.run() ? 0 : 1)
}

// cockpit-shift-power-features: same convention, for `ShiftStore.weeklySummary`'s
// completed/pushed-back/upcoming counting - see
// ShiftWeeklySummarySelfTest.swift's header.
if ProcessInfo.processInfo.environment["FM_RUN_SHIFT_WEEKLY_SUMMARY_TESTS"] == "1" {
    exit(ShiftWeeklySummarySelfTest.run() ? 0 : 1)
}

// cockpit-shift-conflict-handling: same convention, for the record-level
// 3-way merge and conflict-resolution flow layered on top of
// `ShiftGitSync.pullNow`'s `.diverged` case - see
// ShiftConflictSelfTest.swift's header.
if ProcessInfo.processInfo.environment["FM_RUN_SHIFT_CONFLICT_TESTS"] == "1" {
    exit(ShiftConflictSelfTest.run() ? 0 : 1)
}

// grandline-shift-task-image-attachments: same convention, for the image
// downscale/PNG-encode logic every attach path (file picker, drag-drop,
// clipboard paste) funnels through - see
// ShiftImageAttachmentWellSelfTest.swift's header. The store-level round
// trip (hasAttachment persistence, file write/read/remove) is covered by
// ShiftStoreSelfTest.swift; the real-remote push is covered by
// ShiftGitSyncSelfTest.swift - both extended in place rather than
// duplicated here.
if ProcessInfo.processInfo.environment["FM_RUN_SHIFT_ATTACHMENT_WELL_TESTS"] == "1" {
    exit(ShiftImageAttachmentWellSelfTest.run() ? 0 : 1)
}

// `fm/cockpit-block-view-stage0`: same convention, for the OSC 133 parser,
// the real-view-hierarchy render path, the reconnect-bookkeeping
// unification, and volume - see each file's own header for what class of
// prior production break it targets and why the other three couldn't have
// caught it.
if ProcessInfo.processInfo.environment["FM_RUN_BLOCK_VIEW_TESTS"] == "1" {
    exit(TerminalBlockTrackerSelfTest.run() ? 0 : 1)
}
if ProcessInfo.processInfo.environment["FM_RUN_BLOCK_VIEW_HIERARCHY_TESTS"] == "1" {
    exit(BlockViewHierarchySelfTest.run() ? 0 : 1)
}
if ProcessInfo.processInfo.environment["FM_RUN_BLOCK_VIEW_RESTART_TESTS"] == "1" {
    exit(BlockViewRestartIntegrationSelfTest.run() ? 0 : 1)
}
if ProcessInfo.processInfo.environment["FM_RUN_BLOCK_VIEW_VOLUME_TESTS"] == "1" {
    exit(BlockViewVolumeSelfTest.run() ? 0 : 1)
}

// `fm/cockpit-fix-host-decode-regression`: same convention, for `Host`'s
// custom decode fallback (a new `CodingKeys` entry with a Swift-side default,
// like `blockViewOptIn`, must not break decoding of pre-existing `hosts.json`
// files) - see HostStoreSelfTest.swift's header.
// `fm/grandline-review-phase1-stabilize` (GL-01/GL-21): store durability -
// a decode failure must preserve the file, and a failed directory read must
// not look like an empty library. Runs entirely against scratch paths via the
// stores' own `FM_*` overrides.
if ProcessInfo.processInfo.environment["FM_RUN_STORE_DURABILITY_TESTS"] == "1" {
    exit(StoreDurabilitySelfTest.run() ? 0 : 1)
}

// `fm/grandline-review-phase2-harden` (GL-02/GL-15): the shared subprocess
// runner, including the stderr-flood child the review asked for by name plus
// an in-process reproduction of the pre-fix drain order still deadlocking on
// that same child - see SubprocessSelfTest.swift's header.
if ProcessInfo.processInfo.environment["FM_RUN_SUBPROCESS_TESTS"] == "1" {
    exit(SubprocessSelfTest.run() ? 0 : 1)
}

// `fm/grandline-review-phase2-harden` (GL-26): the one `claude -p` runner the
// five drifted copies collapsed into - see ClaudeOneShotSelfTest.swift.
if ProcessInfo.processInfo.environment["FM_RUN_CLAUDE_ONE_SHOT_TESTS"] == "1" {
    exit(ClaudeOneShotSelfTest.run() ? 0 : 1)
}

// `fm/grandline-review-phase2-harden` (GL-10/GL-11/GL-30): throwing
// persistence writes funnelled through PersistenceFailureReporter, and the
// ServiceHealth registry behind the Health card - see Phase2HardeningSelfTest.swift.
if ProcessInfo.processInfo.environment["FM_RUN_PHASE2_HARDENING_TESTS"] == "1" {
    exit(Phase2HardeningSelfTest.run() ? 0 : 1)
}

// `fm/grandline-review-phase1-stabilize` (GL-05/GL-08): the single-instance
// lock and the `ssh` argv option-terminator contract.
if ProcessInfo.processInfo.environment["FM_RUN_PHASE1_HARDENING_TESTS"] == "1" {
    exit(Phase1HardeningSelfTest.run() ? 0 : 1)
}

if ProcessInfo.processInfo.environment["FM_RUN_HOST_STORE_TESTS"] == "1" {
    exit(HostStoreSelfTest.run() ? 0 : 1)
}

// `fm/grandline-vault-tab`: same convention, for `VaultSource`'s pure logic
// (shell-token safety, the two command-string builders, `av doctor --json`
// parsing) - see VaultDataSelfTest.swift's header.
if ProcessInfo.processInfo.environment["FM_RUN_VAULT_DATA_TESTS"] == "1" {
    exit(VaultDataSelfTest.run() ? 0 : 1)
}

// `fm/grandline-live-gap-rootcause-scout`: real-view-hierarchy regression
// coverage for the captain-reported black/blank right-side window gap -
// asserts `AppShellController.bodyContainer`'s width tracks the window's
// real, current content width across a series of resizes, and self-heals
// if that tie is ever silently broken - see AppShellBodyWidthSelfTest.swift's
// header.
if ProcessInfo.processInfo.environment["FM_RUN_APP_SHELL_BODY_WIDTH_TESTS"] == "1" {
    exit(AppShellBodyWidthSelfTest.run() ? 0 : 1)
}

// fm/grandline-app-lock: same convention, for `AppLockController`'s idle/
// hard-logout timing math against a fake clock/idle-time provider - see
// AppLockSelfTest.swift's header.
if ProcessInfo.processInfo.environment["FM_RUN_APP_LOCK_TESTS"] == "1" {
    exit(AppLockControllerSelfTest.run() ? 0 : 1)
}

// `fm/grandline-log-analyzer-build`: same convention, for the Log Analyzer's
// whole pure-logic layer - redaction (including byte-level greps of a built
// AI prompt and a saved investigation for planted secrets), source detection,
// severity/grouping, timeline, correlation, AI reply parsing, Command Library
// matching, artifact rendering, comparison, storage, and the terminal-capture
// scope rule - see LogAnalyzerSelfTest.swift's header.
if ProcessInfo.processInfo.environment["FM_RUN_LOG_ANALYZER_TESTS"] == "1" {
    exit(LogAnalyzerSelfTest.run() ? 0 : 1)
}

// `fm/grandline-mirror-resolve-race-fix`: same convention, for the Mirror
// tab's backend-kind/target atomicity - see MirrorResolveRaceSelfTest.swift's
// header.
if ProcessInfo.processInfo.environment["FM_RUN_MIRROR_RESOLVE_RACE_TESTS"] == "1" {
    exit(MirrorResolveRaceSelfTest.run() ? 0 : 1)
}

// `fm/grandline-dictation-mvp`: same convention, for `DictationHotkey`'s
// hold/release detection over synthetic `.flagsChanged` events - see
// DictationHotkeySelfTest.swift's header.
if ProcessInfo.processInfo.environment["FM_RUN_DICTATION_HOTKEY_TESTS"] == "1" {
    exit(DictationHotkeySelfTest.run() ? 0 : 1)
}

// `fm/grandline-dictation-phase2`: same convention, for `DictationStore`'s
// history/vocabulary persistence and `DictationShortcut`'s encode/decode +
// display-string logic - see DictationDataSelfTest.swift's header.
if ProcessInfo.processInfo.environment["FM_RUN_DICTATION_DATA_TESTS"] == "1" {
    exit(DictationDataSelfTest.run() ? 0 : 1)
}

// `fm/grandline-dictation-phase3`: same convention, for `DictationCleanup`'s
// `claude -p` invocation/parsing/fallback logic - see
// DictationCleanupSelfTest.swift's header.
if ProcessInfo.processInfo.environment["FM_RUN_DICTATION_CLEANUP_TESTS"] == "1" {
    exit(DictationCleanupSelfTest.run() ? 0 : 1)
}

// `fm/grandline-dictation-whisper-engine`: same convention, for the vendored
// whisper.cpp wrapper's model validation, audio resampling, and (when a real
// model path is provided) real load/transcribe - see
// WhisperEngineSelfTest.swift's header.
if ProcessInfo.processInfo.environment["FM_RUN_WHISPER_ENGINE_TESTS"] == "1" {
    exit(WhisperEngineSelfTest.run() ? 0 : 1)
}

// Child-process-only entry point `testMetalFallbackDoesNotCrash()` spawns
// with `FM_WHISPER_METAL_RESOURCES_OVERRIDE` pointed at an empty directory -
// see that test's own doc comment for why this needs a genuinely separate
// process rather than an in-process assertion.
if ProcessInfo.processInfo.environment["FM_RUN_WHISPER_METAL_FALLBACK_ONLY_TEST"] == "1" {
    exit(WhisperEngineSelfTest.runRealModelOnly() ? 0 : 1)
}

// `fm/grandline-docs-knowledge-foundation`: same convention, for
// `DocsRunbookStore`'s CRUD/title-slug logic and `DocsKnowledgeSearch`'s
// scoped search, plus (against a real disposable local bare repo, never
// `manjesh-config`) `ShiftGitSync`'s repo-layout migration - see
// DocsRunbookDataSelfTest.swift's header.
if ProcessInfo.processInfo.environment["FM_RUN_DOCS_RUNBOOK_TESTS"] == "1" {
    exit(DocsRunbookDataSelfTest.run() ? 0 : 1)
}

// `fm/grandline-sre-lead-postmortem`: same convention, for
// `SRELeadPostmortem.generate`'s `claude -p` invocation/parsing/fallback
// logic - see SRELeadPostmortemSelfTest.swift's header.
if ProcessInfo.processInfo.environment["FM_RUN_SRE_LEAD_POSTMORTEM_TESTS"] == "1" {
    exit(SRELeadPostmortemSelfTest.run() ? 0 : 1)
}

// `fm/grandline-console-command-composer`: same convention, for
// `ConsoleCommandComposer.generate`'s `claude -p` invocation/parsing/fallback
// logic - see ConsoleCommandComposerSelfTest.swift's header.
if ProcessInfo.processInfo.environment["FM_RUN_CONSOLE_COMMAND_COMPOSER_TESTS"] == "1" {
    exit(ConsoleCommandComposerSelfTest.run() ? 0 : 1)
}

// `fm/grandline-quota-percent-fix`: same convention, for `QuotaSource.parse`
// against `quota-axi`'s real `percentRemaining`-keyed output - see
// QuotaDataSelfTest.swift's header.
if ProcessInfo.processInfo.environment["FM_RUN_QUOTA_DATA_TESTS"] == "1" {
    exit(QuotaDataSelfTest.run() ? 0 : 1)
}

// `fm/grandline-notification-center`: pure store logic (add/clear/dismiss/
// dedup/badge count) - see GrandLineNotificationCenterSelfTest.swift's header.
if ProcessInfo.processInfo.environment["FM_RUN_NOTIFICATION_CENTER_TESTS"] == "1" {
    exit(GrandLineNotificationCenterSelfTest.run() ? 0 : 1)
}

// The trickiest of the nine signals - SRE Lead replying on a tab you're not
// looking at - driven against a real `ConsoleController`, same convention as
// `SRELeadPerTabSelfTest.swift`. See NotificationCenterSRELeadSelfTest.swift's
// header.
if ProcessInfo.processInfo.environment["FM_RUN_NOTIFICATION_CENTER_SRE_LEAD_TESTS"] == "1" {
    exit(NotificationCenterSRELeadSelfTest.run() ? 0 : 1)
}

// `fm/grandline-design-audit-phase0`: WCAG contrast floors for the shared
// pill, icon tiles and `HelmTheme.mutedInk`, across every real palette - see
// HelmContrastSelfTest.swift's header.
if ProcessInfo.processInfo.environment["FM_RUN_CONTRAST_TESTS"] == "1" {
    exit(HelmContrastSelfTest.run() ? 0 : 1)
}

// `fm/grandline-review-page-stuck-loading-fix`: the Review page's loading ->
// loaded state transition (drives `render(_:)` directly via
// `ReviewController`'s own "Probe / self-test surface", no real network
// fetch) - see ReviewControllerLoadingStateSelfTest.swift's header.
if ProcessInfo.processInfo.environment["FM_RUN_REVIEW_LOADING_STATE_TESTS"] == "1" {
    exit(ReviewControllerLoadingStateSelfTest.run() ? 0 : 1)
}

// The volume measurement that proves the fix above - a demand-driven
// `NSTableView` renders hundreds of PR rows without the plain-`NSStackView`
// blowup #221 shipped. See ReviewPRListVolumeSelfTest.swift's header.
if ProcessInfo.processInfo.environment["FM_RUN_REVIEW_PR_LIST_VOLUME_TESTS"] == "1" {
    exit(ReviewPRListVolumeSelfTest.run() ? 0 : 1)
}

// The row-width/button-visibility contract that regressed a second time when
// #227 ported this row into a reused NSTableView cell view without carrying
// forward the "reused row, toggling button visibility" fix
// `HostsListRecordView` already established. See
// ReviewPRRowButtonLayoutSelfTest.swift's header.
if ProcessInfo.processInfo.environment["FM_RUN_REVIEW_PR_ROW_BUTTON_LAYOUT_TESTS"] == "1" {
    exit(ReviewPRRowButtonLayoutSelfTest.run() ? 0 : 1)
}

// GL-05: refuse to be a second instance. This sits *after* every
// `FM_RUN_*_TESTS` block above (each of which `exit()`s, so a headless
// self-test never contends for the lock and never blocks a real running
// instance) and *before* `AppDelegate()` is constructed - which is the line
// that builds `HostStore`/`SSHKeyStore`/`SnippetStore`/`DictationStore`/
// `ShiftStore` and therefore the first thing that touches the shared files
// two instances corrupt. See `SingleInstanceGuard`'s header for what each of
// the three layers (Info.plist, NSRunningApplication, flock) actually covers.
switch SingleInstanceGuard.acquire() {
case .acquired:
    break
case .alreadyRunning(let pid):
    let who = pid.map { " (pid \($0))" } ?? ""
    AppLog.lifecycle.error("""
        Manjesh Grand Line is already running\(who, privacy: .public) - activating it and exiting. \
        Two instances share one set of JSON stores and one Shift git working tree; the second one \
        silently overwrites the first's saves. See GL-05.
        """)
    exit(0)
}

let app = NSApplication.shared
// Regular activation policy so a `swift run`-launched executable gets a real
// Dock icon, menu bar, and key window instead of a background agent.
app.setActivationPolicy(.regular)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
