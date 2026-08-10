// Manjesh Grand Line - native macOS app.
//
// The 8-theme picker menu (nav-redesign task, item 4): DARK/LIGHT group
// headers, a swatch + name + checkmark per theme, exactly mirroring the web
// app's theme dropdown (`backend/static/index.html`, `.theme-menu`/`THEMES`).
// Shared by the topbar's theme button and Settings' Appearance row so both
// pickers stay in lockstep with zero duplicated menu-building logic.

import AppKit

enum ThemeMenu {
    /// `target`/`action` are applied to every theme item (not the group
    /// headers, which are disabled separators-with-a-label); the chosen
    /// theme's id is read back via `NSMenuItem.representedObject`.
    static func build(target: AnyObject, action: Selector) -> NSMenu {
        let menu = NSMenu()
        appendGroup("DARK", HelmTheme.allThemes.filter { $0.mode == .dark }, to: menu, target: target, action: action)
        menu.addItem(.separator())
        appendGroup("LIGHT", HelmTheme.allThemes.filter { $0.mode == .light }, to: menu, target: target, action: action)
        return menu
    }

    private static func appendGroup(_ title: String, _ themes: [HelmTheme], to menu: NSMenu, target: AnyObject, action: Selector) {
        let header = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        let activeID = ThemeManager.shared.theme.id
        for theme in themes {
            let item = NSMenuItem(title: theme.name, action: action, keyEquivalent: "")
            item.target = target
            item.image = theme.swatchImage()
            item.state = theme.id == activeID ? .on : .off
            item.representedObject = theme.id
            menu.addItem(item)
        }
    }

    /// Read a theme item's id back and apply it - the shared action body for
    /// both the topbar button and Settings' Appearance popup.
    static func apply(from sender: NSMenuItem) {
        guard let id = sender.representedObject as? String, let theme = HelmTheme.theme(id: id) else { return }
        ThemeManager.shared.setTheme(theme)
    }
}
