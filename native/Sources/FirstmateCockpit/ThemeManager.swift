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

/// An opaque handle to a live `ThemeManager.observe` registration, returned
/// so a caller whose lifetime is shorter than the app's (cockpit-native-
/// host-pages: a per-host `ConsoleController`, torn down when its host is
/// deleted) can unregister via `ThemeManager.unobserve` instead of leaking a
/// dead closure into `observers` forever. Every other observer in this app
/// (Hosts/Keys/Snippets/Settings/the shared Firstmate console, etc.) is a
/// permanent, app-lifetime singleton that never needs to call `unobserve` -
/// discarding the returned token there is fine, which is why `observe` is
/// `@discardableResult`.
final class ThemeObservation {}

final class ThemeManager {
    static let shared = ThemeManager()

    private(set) var theme: HelmTheme
    private var observers: [(token: ThemeObservation, fn: (HelmTheme) -> Void)] = []

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
        observers.forEach { $0.fn(theme) }
    }

    /// The quick dark/light flip (View menu, ⌘⌥T, the console's own theme
    /// button) - always lands on the two original Helm palettes regardless of
    /// which of the 8 is active; the full picker (topbar, Settings) is what
    /// reaches the other 6.
    func toggle() {
        setTheme(theme.mode == .dark ? .light : .dark)
    }

    /// Register for theme changes; `fn` is called immediately with the
    /// current theme, then again on every subsequent change. Returns a
    /// token for `unobserve` - discard it for anything that lives as long
    /// as the app; keep it for anything that can be torn down sooner.
    @discardableResult
    func observe(_ fn: @escaping (HelmTheme) -> Void) -> ThemeObservation {
        let token = ThemeObservation()
        observers.append((token, fn))
        fn(theme)
        return token
    }

    /// Unregister a registration made through `observe`, e.g. when its
    /// owner is deallocated before the app quits (cockpit-native-host-pages:
    /// `ConsoleController.shutdown()` for a deleted host's dedicated page).
    func unobserve(_ token: ThemeObservation) {
        observers.removeAll { $0.token === token }
    }
}
