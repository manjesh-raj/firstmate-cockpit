// Firstmate Cockpit - native macOS app.
//
// The Phase 2 console: one surface, two SwiftTerm terminals as tabs.
//
//   - Shell  (⌘1): the Phase 1 terminal, `$SHELL -l`, unchanged in behaviour.
//   - Mirror (⌘2): a live view of the first mate's tmux session, attached via a
//                  grouped session set up in Swift (see `TmuxMirror`).
//
// Both tabs are the paste-hardening `CockpitTerminalView`, so screenshot-paste
// into Claude works identically on either. The top bar carries the tab switch
// plus the section-6 terminal polish: Helm dark/light theming, font zoom, find,
// and copy. All of it is also on the main menu (see `App.swift`) with the usual
// keyboard shortcuts.

import AppKit
import SwiftTerm

final class ConsoleController: NSViewController, LocalProcessTerminalViewDelegate {

    // MARK: Tabs

    enum Tab { case shell, mirror }

    private var currentTab: Tab = .shell

    // MARK: Terminals

    private let shellTerm = CockpitTerminalView(frame: .zero)
    private let mirrorTerm = CockpitTerminalView(frame: .zero)

    /// The active grouped-session mirror, if connected. Torn down on reconnect
    /// and on app shutdown.
    private var mirror: TmuxMirror?
    private var startedProcesses = false

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
    private var shellTabButton = NSButton()
    private var mirrorTabButton = NSButton()
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

        for term in [shellTerm, mirrorTerm] {
            term.translatesAutoresizingMaskIntoConstraints = false
            term.processDelegate = self
            term.font = currentFont()
            content.addSubview(term)
            NSLayoutConstraint.activate([
                term.leadingAnchor.constraint(equalTo: content.leadingAnchor),
                term.trailingAnchor.constraint(equalTo: content.trailingAnchor),
                term.topAnchor.constraint(equalTo: content.topAnchor),
                term.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            ])
        }

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

        applyTheme()
        selectTab(.shell, focus: false)
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        startProcessesIfNeeded()
        view.window?.makeFirstResponder(activeTerminal())
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

        shellTabButton = makeTabButton(title: "Shell", action: #selector(selectShellTab))
        mirrorTabButton = makeTabButton(title: "Mirror", action: #selector(selectMirrorTab))
        let tabs = NSStackView(views: [shellTabButton, mirrorTabButton])
        tabs.orientation = .horizontal
        tabs.spacing = 4
        tabs.translatesAutoresizingMaskIntoConstraints = false
        tabBar.addSubview(tabs)

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
            tabs.leadingAnchor.constraint(equalTo: tabBar.leadingAnchor, constant: 12),
            tabs.centerYAnchor.constraint(equalTo: tabBar.centerYAnchor),
            tools.trailingAnchor.constraint(equalTo: tabBar.trailingAnchor, constant: -10),
            tools.centerYAnchor.constraint(equalTo: tabBar.centerYAnchor),
        ])
    }

    private func makeTabButton(title: String, action: Selector) -> NSButton {
        let b = NSButton(title: title, target: self, action: action)
        b.isBordered = false
        b.wantsLayer = true
        b.layer?.cornerRadius = 7
        b.setButtonType(.momentaryChange)
        b.contentTintColor = nil
        (b.cell as? NSButtonCell)?.imagePosition = .noImage
        return b
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

    // MARK: Starting the terminals

    private func startProcessesIfNeeded() {
        guard !startedProcesses else { return }
        startedProcesses = true

        let shell = shellArgv()
        shellTerm.startProcess(
            executable: shell.executable,
            args: shell.args,
            environment: childEnvironment(),
            execName: nil,
            currentDirectory: shellCwd()
        )

        connectMirror()
    }

    /// Set up the grouped session and attach the Mirror terminal to it. On
    /// failure (no tmux, no such session) the error is written into the terminal
    /// so it is visible rather than silent.
    private func connectMirror() {
        let target = mirrorTarget()
        switch TmuxMirror.setUp(target: target) {
        case .success(let m):
            mirror = m
            mirrorTerm.startProcess(
                executable: m.tmuxPath,
                args: m.attachArgs,
                environment: childEnvironment(),
                execName: nil,
                currentDirectory: shellCwd()
            )
        case .failure(let err):
            mirror = nil
            mirrorTerm.feed(text: "\r\n  \u{1b}[2m[mirror]\u{1b}[0m \(err.message)\r\n")
            mirrorTerm.feed(text: "  \u{1b}[2mSet FM_MIRROR_TARGET to a live tmux target, then press ⌘R to reconnect.\u{1b}[0m\r\n")
        }
    }

    private func disconnectMirror() {
        mirror?.tearDown()
        mirror = nil
    }

    // MARK: Tab switching

    private func activeTerminal() -> CockpitTerminalView {
        currentTab == .shell ? shellTerm : mirrorTerm
    }

    @objc func selectShellTab() { selectTab(.shell) }
    @objc func selectMirrorTab() { selectTab(.mirror) }

    private func selectTab(_ tab: Tab, focus: Bool = true) {
        currentTab = tab
        shellTerm.isHidden = tab != .shell
        mirrorTerm.isHidden = tab != .mirror
        styleTabButtons()
        if focus { view.window?.makeFirstResponder(activeTerminal()) }
    }

    // MARK: Theme

    @objc func toggleTheme() {
        theme = (theme.mode == .dark) ? .light : .dark
        applyTheme()
    }

    private func applyTheme() {
        theme.apply(to: shellTerm)
        theme.apply(to: mirrorTerm)

        let chromeBg = HelmTheme.nsColor(theme.chromeBackgroundHex)
        let line = HelmTheme.nsColor(theme.chromeLineHex)
        view.layer?.backgroundColor = HelmTheme.nsColor(theme.backgroundHex).cgColor
        tabBar.layer?.backgroundColor = chromeBg.cgColor
        separator.layer?.backgroundColor = line.cgColor
        content.layer?.backgroundColor = HelmTheme.nsColor(theme.backgroundHex).cgColor

        let ink = HelmTheme.nsColor(theme.chromeInkHex)
        for b in [findButton, zoomInButton, zoomOutButton, themeButton] {
            b.contentTintColor = ink
        }
        styleTabButtons()
    }

    private func styleTabButtons() {
        let accent = HelmTheme.nsColor(theme.accentHex)
        let ink = HelmTheme.nsColor(theme.chromeInkHex)
        let muted = ink.withAlphaComponent(0.55)
        let tint = accent.withAlphaComponent(theme.mode == .dark ? 0.20 : 0.14)

        style(tab: shellTabButton, title: "Shell", selected: currentTab == .shell,
              accent: accent, ink: ink, muted: muted, tint: tint)
        style(tab: mirrorTabButton, title: "Mirror", selected: currentTab == .mirror,
              accent: accent, ink: ink, muted: muted, tint: tint)
    }

    private func style(tab button: NSButton, title: String, selected: Bool,
                       accent: NSColor, ink: NSColor, muted: NSColor, tint: NSColor) {
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        let attrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: selected ? accent : muted,
            .font: NSFont.systemFont(ofSize: 13, weight: selected ? .semibold : .regular),
            .paragraphStyle: para,
        ]
        button.attributedTitle = NSAttributedString(string: "  \(title)  ", attributes: attrs)
        button.layer?.backgroundColor = selected ? tint.cgColor : NSColor.clear.cgColor
    }

    // MARK: Font zoom

    @objc func zoomIn() { setFontSize(fontSize + 1) }
    @objc func zoomOut() { setFontSize(fontSize - 1) }
    @objc func zoomReset() { setFontSize(13) }

    private func setFontSize(_ size: CGFloat) {
        fontSize = min(maxFont, max(minFont, size))
        let f = currentFont()
        shellTerm.font = f
        mirrorTerm.font = f
    }

    // MARK: Find + copy (routed to the active terminal)

    @objc func showFind() {
        // Route to the active terminal's native find bar. SwiftTerm's
        // `performFindPanelAction` expects a menu item whose tag is the
        // NSFindPanelAction; showFindPanel == 1.
        let item = NSMenuItem()
        item.tag = Int(NSFindPanelAction.showFindPanel.rawValue)
        view.window?.makeFirstResponder(activeTerminal())
        activeTerminal().performFindPanelAction(item)
    }

    @objc func copySelection() {
        activeTerminal().copy(self)
    }

    // MARK: Reconnect / restart

    /// ⌘R: restart whichever terminal is in front. For the mirror this re-runs
    /// the full grouped-session setup (a fresh attach); for the shell it forks a
    /// new login shell.
    @objc func reconnectActive() {
        switch currentTab {
        case .mirror:
            disconnectMirror()
            connectMirror()
        case .shell:
            let shell = shellArgv()
            shellTerm.startProcess(
                executable: shell.executable,
                args: shell.args,
                environment: childEnvironment(),
                execName: nil,
                currentDirectory: shellCwd()
            )
        }
        view.window?.makeFirstResponder(activeTerminal())
    }

    /// Tear down the grouped session so we don't leave a stale `cockpit_*`
    /// session behind. Called from the app delegate on quit.
    func shutdown() {
        disconnectMirror()
    }

    // MARK: LocalProcessTerminalViewDelegate

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        // Only the active terminal drives the window title.
        guard source === activeTerminal() else { return }
        view.window?.title = title.isEmpty ? "Firstmate Cockpit" : title
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    /// A tab's process ended. Unlike P1 (which closed the window), the console
    /// keeps running - the other tab may still be live - and shows a dim
    /// "reconnect" hint in the tab that exited. The mirror also tears down its
    /// grouped session here so nothing is left dangling.
    func processTerminated(source: TerminalView, exitCode: Int32?) {
        if source === mirrorTerm {
            disconnectMirror()
        }
        let code = exitCode.map { " (exit \($0))" } ?? ""
        source.feed(text: "\r\n  \u{1b}[2m[process ended\(code) - press ⌘R to reconnect]\u{1b}[0m\r\n")
    }
}
