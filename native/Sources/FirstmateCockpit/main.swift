// Firstmate Cockpit - native macOS app (Phase 2 entry point).
//
// One AppKit window whose content is the tabbed `ConsoleController` (Shell +
// live tmux Mirror). This file owns only the window, the main menu, and app
// lifecycle - all terminal behaviour lives in `ConsoleController` and its
// helpers. It builds ON Phase 1: the Shell tab is the P1 terminal unchanged, and
// the load-bearing Edit > Paste wiring (which drives screenshot-paste into
// Claude) is preserved here for both tabs.

import AppKit
import SwiftTerm

final class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    let console = ConsoleController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()

        let frame = NSRect(x: 0, y: 0, width: 980, height: 660)
        window = NSWindow(
            contentRect: frame,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Firstmate Cockpit"
        window.center()
        window.contentViewController = console

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    /// Tear down the mirror's grouped tmux session so a `cockpit_*` session is
    /// not left behind after the app quits.
    func applicationWillTerminate(_ notification: Notification) {
        console.shutdown()
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

        NSApp.mainMenu = mainMenu
    }
}

let app = NSApplication.shared
// Regular activation policy so a `swift run`-launched executable gets a real
// Dock icon, menu bar, and key window instead of a background agent.
app.setActivationPolicy(.regular)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
