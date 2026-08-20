// Manjesh Grand Line - native macOS app.
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
// Nav-redesign task: grew from 2 palettes (dark/light) to 8
// (`HelmTheme.allThemes`), so persistence keyed on a theme `id` rather than a
// bare "light"/"dark" string; a pre-existing "fm.themeMode" value is migrated
// once so an upgrade doesn't silently reset anyone's dark/light preference.
// cockpit-theme-overhaul: grew again to 12 (the 2 original Helm palettes
// plus 5 real named families, each contributing a light+dark pair) and gave
// `toggle()` family-aware pairing - see that method's own comment.

import AppKit

// Theme-audit task: every top-level window/view controller in this app must
// do all three of the following, or a view silently stops following the
// active Helm theme (the recurring bug class this task exists to close out -
// Hosts panel in PR #18, FleetController/PlaceholderViewController in PR
// #18's Fix 8, the icon rail here). When adding a new destination, sidebar,
// or sheet, check it against this list before shipping:
//   1. Register via `ThemeManager.shared.observe { ... }` in `loadView()` (or
//      `NSWindow.followHelmTheme()` for a bare window with no view-level
//      hook) - discard the returned token unless this view's lifetime is
//      shorter than the app's (see `ThemeObservation` below), in which case
//      keep it and call `ThemeManager.shared.unobserve` on teardown.
//   2. Force `root.appearance = NSAppearance(named: theme.mode == .dark ?
//      .darkAqua : .aqua)` inside that closure - otherwise any system-
//      semantic color used anywhere in the view's subtree (`.labelColor`,
//      `.secondaryLabelColor`, `.windowBackgroundColor`, etc.) resolves
//      against the OS's actual light/dark setting instead of the in-app
//      theme. Do NOT use `NSVisualEffectView` + `.behindWindow` blending for
//      a full-size destination or window's root: that material blends
//      against whatever is behind the *window* (desktop/other apps), not
//      other content inside it, and has been the direct cause of every
//      "renders in the wrong color" report so far (Hosts' Fix 6, this task's
//      icon-rail fix) - use a plain `NSView` with a `HelmTheme`-derived
//      `layer.backgroundColor` fill instead.
//   3. Actually repaint in that closure (re-set colors/backgrounds), not
//      just once in `loadView` - `observe` calls the closure immediately on
//      registration *and* on every later change, so as long as the same
//      code path handles both there is nothing else to do for live updates.
//   4. **Populate anything that closure iterates BEFORE registering it, or
//      end `loadView` with an explicit `applyTheme(ThemeManager.shared.
//      theme)`.** `observe` firing synchronously at registration is the
//      point of rule 3, but it is also a trap: a closure that loops over a
//      collection (`sectionLabels`, `railDividers`, a `cardBackgrounds`
//      registry) sees that collection EMPTY on the first firing whenever the
//      views are built further down the same `loadView`. The loop is a
//      silent no-op, those views keep whatever color they were constructed
//      with (usually a system semantic color, which is both off-palette and
//      often the wrong side of light/dark), and then the whole thing
//      self-heals on the next unrelated theme switch - so a theme-sweep
//      verification pass cannot catch it, only a first-load measurement can.
//      This has now been confirmed FOUR times in this codebase and is the
//      single most repeated bug class here:
//        - `IconRailController.restyleMark` (needed a second `restyle` call
//          at the end of `loadView`, since `mark`'s layer did not exist yet);
//        - `IconRailController.restyleDividers` (`railDividers` held exactly
//          one of its twelve dividers on the first synchronous run);
//        - `ShiftTaskEditorController` (`sectionLabels` empty, so the four
//          DETAILS/TAGS/DESCRIPTION/ATTACHMENT kickers rendered in
//          `.labelColor` - *brighter* than the body text they label - until
//          any theme switch fixed them; audit §5.1,
//          `fm/grandline-design-audit-phase0`);
//        - `HelmFormSheet` (Phase 6). Structurally guaranteed for a shared
//          scaffold rather than merely likely: the sheet registers its
//          observation in `init`, and every row - and therefore every entry
//          in the registries that closure iterates - is added by the caller
//          afterwards, so the first firing ALWAYS finds them empty. Hence
//          `refreshTheme()`, which every editor's `loadView` ends with.
//      The re-apply is one line and costs nothing, so prefer it by default
//      in any `loadView` whose theme closure touches a collection or a view
//      built after the `observe` call.

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
    /// button) - flips to the *active theme's own* light/dark counterpart
    /// (`pairId`), e.g. Catppuccin Mocha <-> Latte, Solarized Dark <-> Light.
    /// `helm-dark`/`helm-light` pair with each other, matching the original
    /// behavior for those two. Falls back to the plain Helm dark/light swap
    /// only for a theme with no defined pair (shouldn't happen today - every
    /// theme in `HelmTheme.allThemes` has one - but kept as a safety net
    /// rather than force-unwrapping the lookup).
    func toggle() {
        if let pair = HelmTheme.theme(id: theme.pairId) {
            setTheme(pair)
        } else {
            setTheme(theme.mode == .dark ? .light : .dark)
        }
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

extension NSWindow {
    /// Keep this window's own `appearance` - not just its content view's - in
    /// sync with the active Helm theme's mode. A view can force its own
    /// `.appearance` for everything drawn inside it, but the window's title
    /// bar chrome (traffic lights, title text) has no view to hook and
    /// otherwise always follows the OS's actual light/dark setting,
    /// regardless of which Helm theme is active - the same "fixed color
    /// regardless of theme" bug class this task audits for, just at the
    /// window level instead of the view level. Every caller here is an
    /// app-lifetime window, so the returned token is discardable.
    @discardableResult
    func followHelmTheme() -> ThemeObservation {
        ThemeManager.shared.observe { [weak self] theme in
            self?.appearance = NSAppearance(named: theme.mode == .dark ? .darkAqua : .aqua)
        }
    }
}
