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

    /// Stable identifier, matching the web app's `data-theme` ids
    /// (`backend/static/index.html`'s `THEMES` array) - used for persistence
    /// (`ThemeManager`) and for the topbar/Settings theme pickers to look a
    /// theme back up by id.
    let id: String
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
    /// Text colour for a selected run, paired with `selectionHex` so selected
    /// text always clears WCAG AA against the (now opaque) selection fill -
    /// the same role as the web app's `--accent-ink` token against `--accent`.
    /// Without this SwiftTerm defaults `selectedTextForegroundColor` to a
    /// hardcoded black, which is unreadable once `selectionHex` is a
    /// mid-luminance accent (every light theme) rather than a pale tint.
    let selectionTextHex: String
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
        // Opaque, not alpha-blended: an alpha-blended fill's effective colour
        // (and thus its contrast against selectionTextHex) depends on
        // whatever background happened to be underneath a given cell -
        // including arbitrary ANSI colours from the remote program's own
        // output. A solid fill keeps the contrast guarantee exact.
        view.selectedTextBackgroundColor = Self.nsColor(selectionHex)
        view.selectedTextForegroundColor = Self.nsColor(selectionTextHex)
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

    /// The one "muted/secondary text" tone every destination should use
    /// instead of picking its own opacity ad hoc (Fix 8, fixes4). Alpha-
    /// blending `chromeInkHex` looks fine in the dark palettes at much lower
    /// opacity, but the same opacity can silently drop below WCAG AA (4.5:1)
    /// in the light ones - that's exactly how the Overview dashboard's PR
    /// text and timestamps went near-invisible. 0.7 is the measured floor:
    /// checked against every theme's `backgroundHex` and `chromeBackgroundHex`
    /// (the two surfaces text actually sits on), the worst case across all 8
    /// palettes is ~5.06:1 (Paper), comfortably clear of 4.5:1.
    static func mutedInk(_ theme: HelmTheme) -> NSColor {
        nsColor(theme.chromeInkHex).withAlphaComponent(0.7)
    }

    // MARK: The two original, hand-pinned Helm palettes

    static let dark = HelmTheme(
        id: "helm-dark",
        mode: .dark,
        name: "Helm Dark",
        chromeBackgroundHex: "111820", // --surface
        chromeInkHex: "f0f4f7",        // --ink
        chromeLineHex: "323a43",       // --line
        accentHex: "6cd7e3",           // --accent
        foregroundHex: "f0f4f7",       // --ink
        backgroundHex: "05090e",       // --term-bg
        cursorHex: "6cd7e3",           // --accent
        selectionHex: "6cd7e3",        // --accent, opaque fill
        selectionTextHex: "001a22",    // --accent-ink (10.6:1 on the accent fill)
        ansiHex: [
            // index 8 (bright black / "dim") brightened from 585e65 (3.05:1 on
            // term-bg, below the 4.5:1 floor) to 747c86 (4.68:1) - it is used
            // for genuinely-dim-but-still-legible text (comments, timestamps).
            "292e34", "ef6661", "67d283", "f2bf4e", "5eade2", "d285cb", "71cfd9", "ced1d4",
            "747c86", "ff8179", "7fe998", "ffd972", "7dc7f7", "e9a1e3", "96e8ef", "f9fcfe",
        ]
    )

    static let light = HelmTheme(
        id: "helm-light",
        mode: .light,
        name: "Helm Light",
        chromeBackgroundHex: "fcfeff", // --surface
        chromeInkHex: "212c3a",        // --ink
        chromeLineHex: "cdd5dd",       // --line
        accentHex: "007194",           // --accent
        foregroundHex: "212c3a",       // --ink
        backgroundHex: "f5f7f9",       // --term-bg
        cursorHex: "007194",           // --accent
        selectionHex: "007194",        // --accent, opaque fill
        selectionTextHex: "f9fcff",    // --accent-ink (5.4:1 on the accent fill)
        ansiHex: [
            // index 3 (yellow) darkened from ad6800 (4.11:1) to 995c00
            // (4.91:1) - just under the floor on a light background.
            // index 7 ("white", i.e. SGR 37/1m bold-white without an
            // explicit bright flag) was 9ca5b1, a pale grey at only 2.32:1
            // on term-bg - effectively invisible, and the actual bug the
            // captain hit: SwiftTerm only promotes indices 0-6 to their
            // bright siblings on bold text, so bold "white" stays on this
            // slot rather than jumping to index 15. Darkened to 4c5866
            // (6.75:1), the same muted-ink hue the web app uses for
            // secondary text on this theme.
            "272e38", "c22826", "007a43", "995c00", "0069a1", "93398e", "007984", "4c5866",
            "4e5661", "b3000d", "006c32", "9d5400", "005893", "852381", "006875", "212c3a",
        ]
    )
}

// MARK: - The 6 additional named palettes (nav-redesign task)

extension HelmTheme {
    /// `[L, C, hue]` in OKLCH, matching one CSS custom property.
    private typealias Tok = (Double, Double, Double)

    /// OKLCH -> sRGB hex, byte-for-byte the same math as
    /// `scripts/verify-contrast.mjs`'s `hex()` (verified against every
    /// hand-pinned value in `dark`/`light` above before use here) - the
    /// single source of truth for this app's OKLCH token values. Only used
    /// to derive the 6 palettes below from the same tokens as the web app's
    /// CSS (`backend/static/index.html`); `dark`/`light` stay hand-pinned hex
    /// so nothing already shipped shifts by a rounding hair.
    private static func oklchHex(_ L: Double, _ C: Double, _ hDeg: Double) -> String {
        let h = hDeg * .pi / 180
        let a = C * cos(h), b = C * sin(h)
        let l_ = L + 0.3963377774 * a + 0.2158037573 * b
        let m_ = L - 0.1055613458 * a - 0.0638541728 * b
        let s_ = L - 0.0894841775 * a - 1.2914855480 * b
        let l = l_ * l_ * l_, m = m_ * m_ * m_, s = s_ * s_ * s_
        var r = 4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s
        var g = -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s
        var bl = -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s
        func toSrgb(_ c: Double) -> Double {
            let cc = min(1, max(0, c))
            return cc <= 0.0031308 ? 12.92 * cc : 1.055 * pow(cc, 1 / 2.4) - 0.055
        }
        r = toSrgb(r); g = toSrgb(g); bl = toSrgb(bl)
        func to255(_ c: Double) -> Int { Int((min(1, max(0, c)) * 255).rounded()) }
        return String(format: "%02x%02x%02x", to255(r), to255(g), to255(bl))
    }

    /// Build a full theme from the same OKLCH tokens the web CSS defines.
    /// Red/green/yellow ANSI slots (and black/white) are lifted straight
    /// from `dark`/`light`'s own hand-tuned arrays - the underlying
    /// `--bad`/`--ok`/`--need`/`--ink` tokens are identical or a hair apart
    /// across every theme in a mode, per the CSS - so only the accent-linked
    /// slots (blue/magenta/cyan, base + bright) are re-derived per theme,
    /// alongside the chrome/cursor/selection colours.
    private static func derived(
        id: String, name: String, mode: Mode,
        surface: Tok, line: Tok, ink: Tok,
        accent: Tok, info: Tok, termBg: Tok,
        accentInk: Tok, muted: Tok? = nil
    ) -> HelmTheme {
        let base = mode == .dark ? HelmTheme.dark : HelmTheme.light
        let accentHex = oklchHex(accent.0, accent.1, accent.2)
        let blueHex = oklchHex(info.0, info.1, info.2)
        let magentaHue = accent.2 + 100
        let magentaHex = oklchHex(accent.0, accent.1, magentaHue)
        // Dark brights lighten (+L); light "brights" deepen instead (-L, +C) -
        // matching how the hand-tuned light ANSI set actually reads (its
        // bright reds/greens are more saturated and slightly darker, not
        // paler, so they still land against a light terminal background).
        let dl: Double = mode == .dark ? 0.08 : -0.06
        let dc: Double = mode == .dark ? 0 : 0.03
        let brightCyanHex = oklchHex(min(0.97, accent.0 + dl), accent.1 + dc, accent.2)
        let brightBlueHex = oklchHex(min(0.97, info.0 + dl), info.1 + dc, info.2)
        let brightMagentaHex = oklchHex(min(0.97, accent.0 + dl), accent.1 + dc, magentaHue)

        var ansi = base.ansiHex
        ansi[4] = blueHex; ansi[12] = brightBlueHex
        ansi[5] = magentaHex; ansi[13] = brightMagentaHex
        ansi[6] = accentHex; ansi[14] = brightCyanHex
        // Index 7 ("white") needs its own per-theme fix on light themes, same
        // root cause as `light.ansiHex[7]` above: `base.ansiHex[7]` for light
        // mode is already the corrected muted-grey, but each light theme has
        // its own hue, so re-derive it from that theme's own muted token
        // rather than reusing helm-light's.
        if let muted, mode == .light {
            ansi[7] = oklchHex(muted.0, muted.1, muted.2)
        }

        return HelmTheme(
            id: id, mode: mode, name: name,
            chromeBackgroundHex: oklchHex(surface.0, surface.1, surface.2),
            chromeInkHex: oklchHex(ink.0, ink.1, ink.2),
            chromeLineHex: oklchHex(line.0, line.1, line.2),
            accentHex: accentHex,
            foregroundHex: oklchHex(ink.0, ink.1, ink.2),
            backgroundHex: oklchHex(termBg.0, termBg.1, termBg.2),
            cursorHex: accentHex,
            selectionHex: accentHex,
            selectionTextHex: oklchHex(accentInk.0, accentInk.1, accentInk.2),
            ansiHex: ansi
        )
    }

    // Tokens copied verbatim from `backend/static/index.html`'s `:root[data-theme=...]`
    // blocks - keep these in sync if a web theme's tokens change.
    static let midnight = derived(
        id: "midnight", name: "Midnight", mode: .dark,
        surface: (0.20, 0.03, 262), line: (0.35, 0.032, 262), ink: (0.96, 0.01, 255),
        accent: (0.78, 0.12, 242), info: (0.80, 0.10, 250), termBg: (0.13, 0.026, 262),
        accentInk: (0.17, 0.05, 255)
    )
    static let graphite = derived(
        id: "graphite", name: "Graphite", mode: .dark,
        surface: (0.215, 0.006, 285), line: (0.355, 0.009, 285), ink: (0.965, 0.003, 285),
        accent: (0.80, 0.12, 300), info: (0.77, 0.10, 250), termBg: (0.145, 0.005, 285),
        accentInk: (0.18, 0.05, 300)
    )
    static let nocturne = derived(
        id: "nocturne", name: "Nocturne", mode: .dark,
        surface: (0.205, 0.02, 300), line: (0.345, 0.022, 300), ink: (0.965, 0.006, 320),
        accent: (0.78, 0.13, 345), info: (0.77, 0.10, 255), termBg: (0.138, 0.016, 300),
        accentInk: (0.20, 0.06, 345)
    )
    static let paper = derived(
        id: "paper", name: "Paper", mode: .light,
        surface: (0.995, 0.004, 80), line: (0.87, 0.02, 80), ink: (0.30, 0.03, 70),
        accent: (0.49, 0.15, 305), info: (0.51, 0.12, 290), termBg: (0.975, 0.008, 80),
        accentInk: (0.99, 0.004, 80), muted: (0.46, 0.03, 70)
    )
    static let frost = derived(
        id: "frost", name: "Frost", mode: .light,
        surface: (0.995, 0.003, 240), line: (0.87, 0.016, 240), ink: (0.29, 0.035, 250),
        accent: (0.51, 0.14, 248), info: (0.51, 0.13, 248), termBg: (0.975, 0.005, 240),
        accentInk: (0.99, 0.004, 240), muted: (0.45, 0.03, 250)
    )
    static let linen = derived(
        id: "linen", name: "Linen", mode: .light,
        surface: (0.99, 0.006, 60), line: (0.865, 0.02, 60), ink: (0.29, 0.028, 55),
        accent: (0.48, 0.11, 200), info: (0.51, 0.12, 250), termBg: (0.968, 0.008, 60),
        accentInk: (0.99, 0.004, 200), muted: (0.455, 0.026, 58)
    )

    /// All 8 palettes, in the same DARK-then-LIGHT, web-matching order as
    /// `backend/static/index.html`'s `THEMES` array.
    static let allThemes: [HelmTheme] = [dark, midnight, graphite, nocturne, light, paper, frost, linen]

    static func theme(id: String) -> HelmTheme? {
        allThemes.first { $0.id == id }
    }

    /// A small rounded two-tone swatch (chrome background + accent) for the
    /// theme-picker menu, mirroring the web app's `.theme-item .sw` chip.
    func swatchImage(size: NSSize = NSSize(width: 24, height: 14)) -> NSImage {
        let image = NSImage(size: size)
        image.lockFocus()
        let rect = NSRect(origin: .zero, size: size)
        NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4).addClip()
        let left = NSRect(x: 0, y: 0, width: size.width / 2, height: size.height)
        let right = NSRect(x: size.width / 2, y: 0, width: size.width / 2, height: size.height)
        Self.nsColor(chromeBackgroundHex).setFill()
        left.fill()
        Self.nsColor(accentHex).setFill()
        right.fill()
        image.unlockFocus()
        image.isTemplate = false
        return image
    }
}
