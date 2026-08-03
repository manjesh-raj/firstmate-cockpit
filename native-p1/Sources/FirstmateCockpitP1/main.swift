// Firstmate Cockpit - native macOS P1 proof.
//
// One AppKit window holding one SwiftTerm terminal that forks the operator's
// login shell in-process. This is deliberately tiny: it exists only to let the
// captain judge, on their own machine, the two things a headless build cannot
// prove -
//
//   1. Native terminal *feel* (scroll momentum, selection, rendering) vs the
//      web (xterm.js-in-WKWebView) terminal it is meant to replace.
//   2. The screenshot-paste-into-Claude round trip: copy an image to the macOS
//      clipboard, press Cmd-V in the terminal, and have Claude Code (running in
//      this same shell) read the image off the system clipboard.
//
// The API shapes here are the ones verified by the native design scout
// (report.md sections 4.3 and 5). The `CockpitTerminalView` paste override is
// section 5.3 verbatim. See README.md for run + validation instructions.

import AppKit
import SwiftTerm

// MARK: - Paste-hardening terminal (design report section 5.3)

/// A `LocalProcessTerminalView` that guarantees the bracketed-paste signal for
/// an image-only clipboard.
///
/// SwiftTerm's default `paste(_:)` already emits an empty bracketed paste
/// (`ESC[200~` `ESC[201~`) when the clipboard holds no text, which is the exact
/// signal Claude Code needs to notice a paste and go read the image off the
/// system clipboard. This subclass makes that contract explicit and independent
/// of any future upstream change: if there is an image and no text, and the
/// terminal has bracketed paste mode on, it sends the empty bracketed paste
/// directly. Otherwise it defers to SwiftTerm's normal paste (real text still
/// pastes as text).
final class CockpitTerminalView: LocalProcessTerminalView {
    override func paste(_ sender: Any) {
        let pb = NSPasteboard.general
        let hasText = (pb.string(forType: .string)?.isEmpty == false)
        let hasImage = pb.canReadObject(forClasses: [NSImage.self], options: nil)
        if !hasText, hasImage, terminal.bracketedPasteMode {
            send(data: EscapeSequences.bracketedPasteStart[0...])
            send(data: EscapeSequences.bracketedPasteEnd[0...])
            return
        }
        super.paste(sender)
    }
}

// MARK: - Shell launch (mirrors backend/shell.py)

/// The operator's login shell (`$SHELL -l`), falling back to `bash -i`, exactly
/// like `_shell_argv()` in `backend/shell.py`.
func shellArgv() -> (executable: String, args: [String]) {
    if let shell = ProcessInfo.processInfo.environment["SHELL"],
       FileManager.default.fileExists(atPath: shell) {
        return (shell, ["-l"])
    }
    return ("/bin/bash", ["-i"])
}

/// Where the shell opens: `FM_SHELL_CWD` if it is a directory, else `$HOME`.
/// (The Python app also considers the firstmate home; P1 has no backend, so we
/// keep just the honoured override plus home.)
func shellCwd() -> String {
    let env = ProcessInfo.processInfo.environment
    if let override = env["FM_SHELL_CWD"] {
        let expanded = (override as NSString).expandingTildeInPath
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: expanded, isDirectory: &isDir), isDir.boolValue {
            return expanded
        }
    }
    return FileManager.default.homeDirectoryForCurrentUser.path
}

/// Environment for the terminal child, mirroring `terminal.py`/`shell.py`:
/// force `TERM=xterm-256color` and a UTF-8 locale (a Finder-launched GUI app
/// inherits no LANG/LC_ALL), and drop `TMUX` so this is a fresh, un-nested
/// shell. Returned as SwiftTerm's `KEY=VALUE` array form.
func childEnvironment() -> [String] {
    var env = ProcessInfo.processInfo.environment
    env["TERM"] = "xterm-256color"
    env["LANG"] = "en_US.UTF-8"
    env["LC_ALL"] = "en_US.UTF-8"
    env.removeValue(forKey: "TMUX")
    return env.map { "\($0.key)=\($0.value)" }
}

// MARK: - Application

final class AppDelegate: NSObject, NSApplicationDelegate, LocalProcessTerminalViewDelegate {
    var window: NSWindow!
    var terminalView: CockpitTerminalView!

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()

        let frame = NSRect(x: 0, y: 0, width: 960, height: 640)
        window = NSWindow(
            contentRect: frame,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Firstmate Cockpit - Native P1"
        window.center()

        terminalView = CockpitTerminalView(frame: frame)
        terminalView.autoresizingMask = [.width, .height]
        terminalView.processDelegate = self
        window.contentView = terminalView

        let shell = shellArgv()
        terminalView.startProcess(
            executable: shell.executable,
            args: shell.args,
            environment: childEnvironment(),
            execName: nil,
            currentDirectory: shellCwd()
        )

        window.makeKeyAndOrderFront(nil)
        // Route the first-responder chain to the terminal so Cmd-V lands there.
        window.makeFirstResponder(terminalView)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    // MARK: Menu

    /// A minimal main menu. The one load-bearing item is Edit > Paste (Cmd-V):
    /// it targets the first responder via `NSText.paste(_:)`, which resolves to
    /// the terminal's `paste(_:)` and drives the screenshot-paste flow. Without
    /// this menu a plain `swift run` executable gets no Paste action at all (the
    /// WKWebView used to hand it over for free).
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

        // Edit menu - carries Paste.
        let editMenuItem = NSMenuItem()
        mainMenu.addItem(editMenuItem)
        let editMenu = NSMenu(title: "Edit")
        editMenuItem.submenu = editMenu
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        NSApp.mainMenu = mainMenu
    }

    // MARK: LocalProcessTerminalViewDelegate

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        window.title = title.isEmpty ? "Firstmate Cockpit - Native P1" : title
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    /// The login shell exited. In P1 there is nothing to reconnect to, so just
    /// close the window (which quits the app via the terminate-on-last-window
    /// rule above). Later phases add a restart affordance.
    func processTerminated(source: TerminalView, exitCode: Int32?) {
        window.performClose(nil)
    }
}

let app = NSApplication.shared
// Regular activation policy so a `swift run`-launched executable gets a real
// Dock icon, menu bar, and key window instead of a background agent.
app.setActivationPolicy(.regular)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
