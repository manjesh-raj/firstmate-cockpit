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
