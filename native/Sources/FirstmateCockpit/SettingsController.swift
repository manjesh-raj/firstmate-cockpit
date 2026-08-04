// Firstmate Cockpit - native macOS app.
//
// The native Settings panel (Fix 3) - parity with the old web cockpit's
// Connection/Appearance/Terminal screen (`backend/static/index.html`),
// adapted for a native app with no sign-in step. Three sections:
//
//   - Appearance: the same 8-theme picker (`ThemeMenu`) as the topbar, wired
//     straight to `ThemeManager` - every theme-aware window (console,
//     Hosts/Keys/Snippets) already observes it, so a change here repaints the
//     whole app immediately.
//   - Terminal: font-size +/- steppers. The live font change is routed
//     through `ConsoleController.stepFontSize` (wired by the app delegate,
//     `onFontSizeStep`) since this panel has no direct reference to the
//     console; the value itself lives in `AppSettings.fontSize`.
//   - General: the three ad-hoc environment-variable preferences that had no
//     UI home before this (`FM_SHELL_CWD`, `FM_MIRROR_TARGET`,
//     `FM_LOG_SESSIONS_DEFAULT` - see `TerminalEnvironment.swift` and
//     `ConsoleController.defaultLoggingEnabled`), now backed by
//     `AppSettings` and editable here. The env vars still win when set, so
//     existing scripted/dev workflows are unaffected.
//
// Like `HostEditorController`, fields persist immediately on change (this is
// a plain settings window, not a sheet with its own Save/Cancel) rather than
// batching into one Save button.

import AppKit

final class SettingsController: NSViewController {

    /// The Terminal section's +/- steppers. Wired by the app delegate to
    /// `ConsoleController.stepFontSize`, since this panel never holds a
    /// direct reference to the console.
    var onFontSizeStep: ((CGFloat) -> Void)?

    private let themeButton = NSButton()
    private let fontSizeLabel = NSTextField(labelWithString: "")
    private let shellCwdField = NSTextField()
    private let mirrorTargetField = NSTextField()
    private let sessionLoggingCheckbox = NSButton(checkboxWithTitle: "Log sessions by default", target: nil, action: nil)

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 460, height: 420))
        root.wantsLayer = true
        view = root
        // Nav-redesign task: Settings now sits embedded in the same window as
        // the themed rail/console/placeholders (previously its own floating
        // window, where the system's own light/dark mode covered for this) -
        // so it needs the same theme-follows-`ThemeManager` treatment as the
        // Hosts/Keys/Snippets panels (PR #14 Fix 2), or it would show as a
        // glaring system-background rectangle whenever the in-app theme and
        // the OS appearance disagree.
        ThemeManager.shared.observe { [weak root] theme in
            root?.appearance = NSAppearance(named: theme.mode == .dark ? .darkAqua : .aqua)
            root?.layer?.backgroundColor = HelmTheme.nsColor(theme.backgroundHex).cgColor
        }

        let appearance = section("Appearance", buildAppearanceRow())
        let terminal = section("Terminal", buildTerminalRow())
        let general = section("General", buildGeneralGrid())

        let stack = NSStackView(views: [appearance, terminal, general])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 22
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 22),
            appearance.widthAnchor.constraint(equalTo: stack.widthAnchor),
            terminal.widthAnchor.constraint(equalTo: stack.widthAnchor),
            general.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])

        refreshFromSettings()
    }

    // MARK: Sections

    private func section(_ title: String, _ content: NSView) -> NSView {
        let header = NSTextField(labelWithString: title)
        header.font = .systemFont(ofSize: 13, weight: .semibold)
        let stack = NSStackView(views: [header, content])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        return stack
    }

    // MARK: Appearance

    private func buildAppearanceRow() -> NSView {
        themeButton.bezelStyle = .rounded
        themeButton.imagePosition = .imageLeading
        themeButton.target = self
        themeButton.action = #selector(themeButtonClicked)
        themeButton.translatesAutoresizingMaskIntoConstraints = false
        return themeButton
    }

    @objc private func themeButtonClicked() {
        let menu = ThemeMenu.build(target: self, action: #selector(themeItemSelected(_:)))
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: themeButton.bounds.height + 4), in: themeButton)
    }

    @objc private func themeItemSelected(_ sender: NSMenuItem) {
        ThemeMenu.apply(from: sender)
        refreshFromSettings()
    }

    // MARK: Terminal

    private func buildTerminalRow() -> NSView {
        let minus = smallButton(symbol: "minus.magnifyingglass", action: #selector(fontStepDown))
        let plus = smallButton(symbol: "plus.magnifyingglass", action: #selector(fontStepUp))
        fontSizeLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        fontSizeLabel.translatesAutoresizingMaskIntoConstraints = false
        fontSizeLabel.setContentHuggingPriority(.defaultHigh, for: .horizontal)

        let row = NSStackView(views: [NSTextField(labelWithString: "Font size"), minus, fontSizeLabel, plus])
        row.orientation = .horizontal
        row.spacing = 10
        row.translatesAutoresizingMaskIntoConstraints = false
        return row
    }

    private func smallButton(symbol: String, action: Selector) -> NSButton {
        let b = NSButton(title: "", target: self, action: action)
        b.bezelStyle = .rounded
        b.image = NSImage(systemSymbolName: symbol, accessibilityDescription: symbol)
        b.translatesAutoresizingMaskIntoConstraints = false
        return b
    }

    @objc private func fontStepDown() {
        onFontSizeStep?(-1)
        refreshFromSettings()
    }

    @objc private func fontStepUp() {
        onFontSizeStep?(1)
        refreshFromSettings()
    }

    // MARK: General

    private func buildGeneralGrid() -> NSView {
        let chooseCwd = NSButton(title: "Choose…", target: self, action: #selector(chooseShellCwd))
        chooseCwd.bezelStyle = .rounded

        configure(shellCwdField, placeholder: "~ (Home)")
        let cwdRow = NSStackView(views: [shellCwdField, chooseCwd])
        cwdRow.orientation = .horizontal
        cwdRow.spacing = 8
        cwdRow.translatesAutoresizingMaskIntoConstraints = false
        shellCwdField.setContentHuggingPriority(.defaultLow, for: .horizontal)

        configure(mirrorTargetField, placeholder: "firstmate")

        sessionLoggingCheckbox.target = self
        sessionLoggingCheckbox.action = #selector(sessionLoggingToggled)
        sessionLoggingCheckbox.translatesAutoresizingMaskIntoConstraints = false

        let grid = NSGridView(views: [
            [rowLabel("Working directory"), cwdRow],
            [rowLabel("Mirror target"), mirrorTargetField],
            [rowLabel(""), sessionLoggingCheckbox],
        ])
        grid.rowSpacing = 10
        grid.columnSpacing = 12
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).xPlacement = .fill
        grid.translatesAutoresizingMaskIntoConstraints = false
        return grid
    }

    private func rowLabel(_ text: String) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.font = .systemFont(ofSize: 12)
        l.textColor = .secondaryLabelColor
        return l
    }

    private func configure(_ field: NSTextField, placeholder: String) {
        field.placeholderString = placeholder
        field.translatesAutoresizingMaskIntoConstraints = false
        field.target = self
        field.action = #selector(textFieldChanged(_:))
        field.delegate = self
    }

    @objc private func chooseShellCwd() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose the default working directory for new Shell/Firstmate tabs."
        if let current = AppSettings.shared.defaultShellCwd {
            panel.directoryURL = URL(fileURLWithPath: (current as NSString).expandingTildeInPath)
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        shellCwdField.stringValue = url.path
        AppSettings.shared.defaultShellCwd = url.path
    }

    @objc private func textFieldChanged(_ sender: NSTextField) {
        let value = sender.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        switch sender {
        case shellCwdField:
            AppSettings.shared.defaultShellCwd = value.isEmpty ? nil : value
        case mirrorTargetField:
            AppSettings.shared.mirrorTarget = value.isEmpty ? nil : value
        default:
            break
        }
    }

    @objc private func sessionLoggingToggled() {
        AppSettings.shared.sessionLoggingDefault = sessionLoggingCheckbox.state == .on
    }

    // MARK: Sync

    override func viewWillAppear() {
        super.viewWillAppear()
        refreshFromSettings()
    }

    private func refreshFromSettings() {
        let theme = ThemeManager.shared.theme
        themeButton.title = " " + theme.name
        themeButton.image = theme.swatchImage()
        fontSizeLabel.stringValue = "\(Int(AppSettings.shared.fontSize)) pt"
        shellCwdField.stringValue = AppSettings.shared.defaultShellCwd ?? ""
        mirrorTargetField.stringValue = AppSettings.shared.mirrorTarget ?? ""
        sessionLoggingCheckbox.state = AppSettings.shared.sessionLoggingDefault ? .on : .off
    }
}

extension SettingsController: NSTextFieldDelegate {
    func controlTextDidEndEditing(_ obj: Notification) {
        guard let field = obj.object as? NSTextField else { return }
        textFieldChanged(field)
    }
}
