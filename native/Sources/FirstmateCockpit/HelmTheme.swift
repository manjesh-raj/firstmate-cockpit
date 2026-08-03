// Firstmate Cockpit - native macOS app.
//
// The "Helm" terminal palette (design report section 9). The web cockpit's Helm
// tokens are OKLCH, which SwiftTerm cannot consume, so these are the same tokens
// pre-converted to sRGB hex (via the OKLCH -> sRGB math in
// `scripts/verify-contrast.mjs`) and hand-extended into a full 16-colour ANSI set
// that harmonises with each mode. Changing a Helm token in the web app means
// re-deriving the matching hex here; the source-of-truth conversion is that
// script.
//
// `foreground`/`background` come straight from Helm `--ink` / `--term-bg`, the
// cursor from `--accent`, and the ANSI reds/greens/yellows/blues are tuned off
// Helm `--bad` / `--ok` / `--need` / `--accent` so the terminal reads as the same
// instrument panel as the rest of the cockpit.

import AppKit
import SwiftTerm

/// A complete terminal colour scheme: the 16 ANSI colours plus foreground,
/// background, cursor, and selection.
struct HelmTheme {
    enum Mode { case dark, light }

    let mode: Mode
    let name: String
    /// Window / chrome colours so the AppKit shell around the terminal matches.
    let chromeBackgroundHex: String
    let chromeInkHex: String
    let chromeLineHex: String
    let accentHex: String

    let foregroundHex: String
    let backgroundHex: String
    let cursorHex: String
    let selectionHex: String
    /// 16 ANSI colours, in SwiftTerm/xterm order:
    /// black, red, green, yellow, blue, magenta, cyan, white, then the 8 bright.
    let ansiHex: [String]

    // MARK: Apply

    /// Install this theme onto a SwiftTerm terminal view: the 16 ANSI colours,
    /// then foreground / background / cursor / selection.
    func apply(to view: TerminalView) {
        view.installColors(ansiHex.map(Self.termColor))
        view.nativeForegroundColor = Self.nsColor(foregroundHex)
        view.nativeBackgroundColor = Self.nsColor(backgroundHex)
        view.caretColor = Self.nsColor(cursorHex)
        view.selectedTextBackgroundColor = Self.nsColor(selectionHex).withAlphaComponent(0.35)
        view.needsDisplay = true
    }

    // MARK: Colour parsing

    /// `"rrggbb"` (or `"#rrggbb"`) -> the three 8-bit channels.
    private static func channels(_ hex: String) -> (UInt8, UInt8, UInt8) {
        var s = hex
        if s.hasPrefix("#") { s.removeFirst() }
        let v = UInt32(s, radix: 16) ?? 0
        return (UInt8((v >> 16) & 0xff), UInt8((v >> 8) & 0xff), UInt8(v & 0xff))
    }

    static func termColor(_ hex: String) -> SwiftTerm.Color {
        let (r, g, b) = channels(hex)
        // SwiftTerm.Color channels are 16-bit; scale 8-bit 0-255 to 0-65535 (× 257).
        return SwiftTerm.Color(red: UInt16(r) * 257, green: UInt16(g) * 257, blue: UInt16(b) * 257)
    }

    static func nsColor(_ hex: String) -> NSColor {
        let (r, g, b) = channels(hex)
        return NSColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1)
    }

    // MARK: The two shipped Helm palettes

    static let dark = HelmTheme(
        mode: .dark,
        name: "Helm Dark",
        chromeBackgroundHex: "111820", // --surface
        chromeInkHex: "f0f4f7",        // --ink
        chromeLineHex: "323a43",       // --line
        accentHex: "6cd7e3",           // --accent
        foregroundHex: "f0f4f7",       // --ink
        backgroundHex: "05090e",       // --term-bg
        cursorHex: "6cd7e3",           // --accent
        selectionHex: "6cd7e3",        // --accent (drawn at 35% alpha)
        ansiHex: [
            "292e34", "ef6661", "67d283", "f2bf4e", "5eade2", "d285cb", "71cfd9", "ced1d4",
            "585e65", "ff8179", "7fe998", "ffd972", "7dc7f7", "e9a1e3", "96e8ef", "f9fcfe",
        ]
    )

    static let light = HelmTheme(
        mode: .light,
        name: "Helm Light",
        chromeBackgroundHex: "fcfeff", // --surface
        chromeInkHex: "212c3a",        // --ink
        chromeLineHex: "cdd5dd",       // --line
        accentHex: "007194",           // --accent
        foregroundHex: "212c3a",       // --ink
        backgroundHex: "f5f7f9",       // --term-bg
        cursorHex: "007194",           // --accent
        selectionHex: "007194",        // --accent (drawn at 35% alpha)
        ansiHex: [
            "272e38", "c22826", "007a43", "ad6800", "0069a1", "93398e", "007984", "9ca5b1",
            "4e5661", "b3000d", "006c32", "9d5400", "005893", "852381", "006875", "212c3a",
        ]
    )
}
