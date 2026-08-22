// Manjesh Grand Line - native macOS app.
//
// A single source of truth for the app's monospace font size, persisted via
// `AppSettings.fontSize` and mirroring `ThemeManager`'s observe/notify shape
// (`fm/cockpit-tools-page-ui-polish`). Before this existed, only
// `ConsoleController` tracked font size (a private `fontSize` var, pushed to
// from Settings via a one-off `onFontSizeStep` closure wired in `main.swift`)
// - correct for terminal tabs, but any other view that wants to render
// monospace text at the same size (the Tools page's YAML/JSON/diff/JWT/cron
// output, added across three earlier phases) had no way to read or observe
// it. Route font-size reads/writes through `FontSizeManager.shared` and
// register via `observe` instead of tracking a private copy - the same rule
// `ThemeManager.swift`'s header lays out for theme.
//
// `ConsoleController` and `ToolsController`/`ToolInstance` both observe this
// now, so a change from Settings' font-size presets updates every open
// terminal tab AND every open Tools tab's monospace text live, in one place,
// rather than needing a second bespoke wiring path per consumer.

import Foundation

/// An opaque handle to a live `FontSizeManager.observe` registration -
/// mirrors `ThemeObservation`. Every current observer (`ConsoleController`,
/// `ToolsController`) is an app-lifetime singleton and can discard it.
final class FontSizeObservation {}

final class FontSizeManager {
    static let shared = FontSizeManager()

    static let minSize: CGFloat = 8
    static let maxSize: CGFloat = 28

    private(set) var size: CGFloat
    private var observers: [(token: FontSizeObservation, fn: (CGFloat) -> Void)] = []

    private init() {
        size = AppSettings.shared.fontSize
    }

    /// Set an absolute size (clamped to `minSize...maxSize`), persist it, and
    /// notify every observer - the Settings panel's font presets call this
    /// directly.
    func setSize(_ newSize: CGFloat) {
        size = min(Self.maxSize, max(Self.minSize, newSize))
        AppSettings.shared.fontSize = size
        observers.forEach { $0.fn(size) }
    }

    /// The toolbar/menu zoom actions' relative step (⌘+/⌘-/`ConsoleController.
    /// stepFontSize`).
    func step(by delta: CGFloat) { setSize(size + delta) }

    /// Register for font-size changes; `fn` is called immediately with the
    /// current size, then again on every subsequent change.
    @discardableResult
    func observe(_ fn: @escaping (CGFloat) -> Void) -> FontSizeObservation {
        let token = FontSizeObservation()
        observers.append((token, fn))
        fn(size)
        return token
    }

    func unobserve(_ token: FontSizeObservation) {
        observers.removeAll { $0.token === token }
    }
}

// MARK: - ChromeTextScale

/// An opaque handle to a live `ChromeTextScale.observe` registration - mirrors
/// `FontSizeObservation`.
final class ChromeTextScaleObservation {}

/// The app's UI-chrome text scale (GL-32), the sibling of `FontSizeManager`.
///
/// `FontSizeManager` is the *monospace* size: terminals and the Tools page's
/// code output. It deliberately does not touch UI chrome, which is why the
/// accessibility review found `HelmType`'s sizes fixed at 10-22pt with no way
/// for a captain who wants larger interface text to get it - macOS has no
/// system-wide UI text size preference for an app to follow, so an app that
/// wants to offer one has to own it.
///
/// This is GL-32's *floor plus hook* half, not a full text-scaling system:
///
///   - Every `HelmType` accessor multiplies by `scale` and is floored at
///     `HelmType.minimumUIPointSize`, so the smallest captions and kickers
///     can never render below a readable size at any scale.
///   - A change notifies observers, and `AppShellController` turns that into
///     an app-wide theme re-fire, which is what makes every page that derives
///     its fonts inside `applyTheme` (the four shared components, and any page
///     that follows them) pick the new scale up live.
///
/// What is deliberately *not* covered: text whose font is set once in a page's
/// own `loadView` and never re-derived. That keeps its size until the view is
/// rebuilt or the app relaunches. Closing that gap means routing every
/// remaining hand-set font through a re-derivable path, which is the "High"
/// half of GL-32 and its own scheduled work - not something to half-do here.
final class ChromeTextScale {
    static let shared = ChromeTextScale()

    static let minScale: CGFloat = 1.0
    static let maxScale: CGFloat = 1.3

    /// The three steps Settings offers. Values, not an enum, because
    /// `AppSettings.uiTextScale` persists the multiplier itself - a stored
    /// enum case would need a migration the first time the steps change.
    static let steps: [(title: String, scale: CGFloat)] = [
        ("Default", 1.0),
        ("Large", 1.15),
        ("Larger", 1.3),
    ]

    private(set) var scale: CGFloat
    private var observers: [(token: ChromeTextScaleObservation, fn: (CGFloat) -> Void)] = []

    private init() {
        scale = AppSettings.shared.uiTextScale
    }

    func setScale(_ newScale: CGFloat) {
        let clamped = min(Self.maxScale, max(Self.minScale, newScale))
        guard clamped != scale else { return }
        scale = clamped
        AppSettings.shared.uiTextScale = clamped
        observers.forEach { $0.fn(clamped) }
    }

    @discardableResult
    func observe(_ fn: @escaping (CGFloat) -> Void) -> ChromeTextScaleObservation {
        let token = ChromeTextScaleObservation()
        observers.append((token, fn))
        fn(scale)
        return token
    }

    func unobserve(_ token: ChromeTextScaleObservation) {
        observers.removeAll { $0.token === token }
    }
}
