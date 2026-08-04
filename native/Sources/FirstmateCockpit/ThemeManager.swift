// Firstmate Cockpit - native macOS app.
//
// A single source of truth for the app's Helm theme, persisted across
// launches. Before this existed, `ConsoleController` kept its own private
// `theme` var and every other window (Hosts sidebar, Keys, Snippets)
// followed the *system* light/dark appearance instead - the captain-reported
// bug where toggling the in-app theme left the Hosts sidebar stuck in the
// system's appearance while the terminal switched to Helm dark. Anything that
// needs to render in the current Helm theme should read `ThemeManager.shared`
// and register via `observe` rather than tracking its own copy.
//
// Nav-redesign task: grew from 2 palettes (dark/light) to all 8
// (`HelmTheme.allThemes`), so persistence keyed on a theme `id` rather than a
// bare "light"/"dark" string; a pre-existing "fm.themeMode" value is migrated
// once so an upgrade doesn't silently reset anyone's dark/light preference.

import Foundation

final class ThemeManager {
    static let shared = ThemeManager()

    private(set) var theme: HelmTheme
    private var observers: [(HelmTheme) -> Void] = []

    private static let defaultsKey = "fm.themeID"
    private static let legacyModeKey = "fm.themeMode"

    private init() {
        if let id = UserDefaults.standard.string(forKey: Self.defaultsKey), let match = HelmTheme.theme(id: id) {
            theme = match
        } else if let legacyMode = UserDefaults.standard.string(forKey: Self.legacyModeKey) {
            theme = legacyMode == "light" ? .light : .dark
        } else {
            theme = .dark
        }
    }

    /// Change the active theme and notify every observer (including the one
    /// just registering, via `observe`, so callers don't need a separate
    /// "apply once" step).
    func setTheme(_ theme: HelmTheme) {
        self.theme = theme
        UserDefaults.standard.set(theme.id, forKey: Self.defaultsKey)
        observers.forEach { $0(theme) }
    }

    /// The quick dark/light flip (View menu, ⌘⌥T, the console's own theme
    /// button) - always lands on the two original Helm palettes regardless of
    /// which of the 8 is active; the full picker (topbar, Settings) is what
    /// reaches the other 6.
    func toggle() {
        setTheme(theme.mode == .dark ? .light : .dark)
    }

    /// Register for theme changes; `fn` is called immediately with the
    /// current theme, then again on every subsequent change.
    func observe(_ fn: @escaping (HelmTheme) -> Void) {
        observers.append(fn)
        fn(theme)
    }
}
