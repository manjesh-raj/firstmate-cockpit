// Firstmate Cockpit - native macOS app.
//
// A single source of truth for the app's Helm theme (dark/light), persisted
// across launches. Before this existed, `ConsoleController` kept its own
// private `theme` var and every other window (Hosts sidebar, Keys, Snippets)
// followed the *system* light/dark appearance instead - the captain-reported
// bug where toggling the in-app theme left the Hosts sidebar stuck in the
// system's appearance while the terminal switched to Helm dark. Anything that
// needs to render in the current Helm theme should read `ThemeManager.shared`
// and register via `observe` rather than tracking its own copy.

import Foundation

final class ThemeManager {
    static let shared = ThemeManager()

    private(set) var theme: HelmTheme
    private var observers: [(HelmTheme) -> Void] = []

    private static let defaultsKey = "fm.themeMode"

    private init() {
        let saved = UserDefaults.standard.string(forKey: Self.defaultsKey)
        theme = (saved == "light") ? .light : .dark
    }

    /// Change the active theme and notify every observer (including the one
    /// just registering, via `observe`, so callers don't need a separate
    /// "apply once" step).
    func setTheme(_ theme: HelmTheme) {
        self.theme = theme
        UserDefaults.standard.set(theme.mode == .light ? "light" : "dark", forKey: Self.defaultsKey)
        observers.forEach { $0(theme) }
    }

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
