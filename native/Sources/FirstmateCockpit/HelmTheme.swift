// Manjesh Grand Line - native macOS app.
//
// The "Helm" terminal palette (design report section 9), plus 10 real named
// theme families (cockpit-theme-overhaul). `helm-dark`/`helm-light` are the
// original, hand-pinned Helm tokens; the other 10 are sourced verbatim from
// each family's own canonical repo (see `data/cockpit-theme-research/report.md`
// for exact sources, per-family tables, and the reasoning behind every
// deviation from canonical values below).
//
// `foreground`/`background` come straight from Helm `--ink` / `--term-bg`, the
// cursor from `--accent`, and the ANSI reds/greens/yellows/blues are tuned off
// Helm `--bad` / `--ok` / `--need` / `--accent` so the terminal reads as the same
// instrument panel as the rest of the cockpit.
//
// Contrast is verified with a hand-written WCAG relative-luminance check
// (sRGB -> linear -> 0.2126R + 0.7152G + 0.0722B -> (L1+0.05)/(L2+0.05)) held
// to a 4.5:1 floor for text-bearing fields. There used to be a
// `scripts/verify-contrast.mjs` for the old web app that did the equivalent
// check against OKLCH input; it was removed along with that app
// (`83cd4b3`) and never carried forward - this file's comments no longer
// point at it.

import AppKit
import SwiftTerm

/// A complete terminal colour scheme: the 16 ANSI colours plus foreground,
/// background, cursor, and selection.
struct HelmTheme {
    enum Mode { case dark, light }

    /// Stable identifier - used for persistence (`ThemeManager`) and for the
    /// topbar/Settings theme pickers to look a theme back up by id.
    let id: String
    let mode: Mode
    let name: String
    /// The id of this theme's light/dark counterpart within the same family
    /// (e.g. `catppuccin-mocha` <-> `catppuccin-latte`), used by
    /// `ThemeManager.toggle()` to flip within a family instead of always
    /// landing on `helm-dark`/`helm-light`.
    let pairId: String
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
    /// text and timestamps went near-invisible.
    ///
    /// 0.7 was the measured floor **for the original 8 palettes only**, and
    /// the doc comment here used to say so and leave it. The full-app UI
    /// audit re-measured it against all 12 (`fm/grandline-design-audit-phase0`,
    /// audit §7 item 7) and found a flat 0.7 genuinely fails five of the ten
    /// sourced-family themes - solarized-dark 3.14, catppuccin-latte 3.47,
    /// tokyo-night-light 3.75, rose-pine-dawn 4.04, gruvbox-light 4.37 -
    /// because those palettes' own `chromeInkHex`/background pairs are
    /// naturally lower-contrast than Helm's hand-picked tones.
    ///
    /// So this is no longer one flat constant. `baseMutedAlpha` (0.7) is the
    /// starting point and the **look** every theme that can afford it keeps
    /// byte for byte; a theme that cannot is raised - by the smallest amount
    /// that clears 4.5:1 against the *worse* of the two surfaces real text
    /// sits on (`chromeBackgroundHex` and `backgroundHex`), never further.
    /// Raising the constant globally instead would have washed out the seven
    /// themes that already clear it comfortably (helm-dark measures 8.36) for
    /// no reason. Contrast rises monotonically with alpha here - more alpha
    /// means less of the background showing through - so a plain bisection
    /// finds the minimum directly. Covered by `HelmContrastSelfTest`
    /// (`FM_RUN_CONTRAST_TESTS=1`), which fails if any theme drops below the
    /// floor the next time a palette is added or a token retuned.
    static let baseMutedAlpha: CGFloat = 0.7

    private static let mutedAlphaCache = MutedAlphaCache()

    static func mutedInk(_ theme: HelmTheme) -> NSColor {
        nsColor(theme.chromeInkHex).withAlphaComponent(mutedAlpha(for: theme))
    }

    /// The alpha `mutedInk` actually uses for `theme` - exposed so the
    /// contrast self-test can report it, and so a probe can confirm a given
    /// theme was or was not raised.
    static func mutedAlpha(for theme: HelmTheme) -> CGFloat {
        if let cached = mutedAlphaCache.value(for: theme.id) { return cached }
        let resolved = computeMutedAlpha(for: theme)
        mutedAlphaCache.store(resolved, for: theme.id)
        return resolved
    }

    private static func computeMutedAlpha(for theme: HelmTheme) -> CGFloat {
        let ink = HelmContrast.components(nsColor(theme.chromeInkHex))
        let surfaces = [theme.chromeBackgroundHex, theme.backgroundHex].map {
            HelmContrast.components(nsColor($0))
        }
        func clears(_ alpha: CGFloat) -> Bool {
            surfaces.allSatisfy { surface in
                HelmContrast.ratio(HelmContrast.mix(ink, surface, Double(alpha)), surface) >= HelmContrast.textTarget
            }
        }
        if clears(baseMutedAlpha) { return baseMutedAlpha }
        // Even fully opaque ink cannot separate from this palette's own
        // surface (no palette shipped today is in this state) - use the most
        // legible value available rather than staying at the failing default.
        if !clears(1) { return 1 }
        var lo = Double(baseMutedAlpha), hi = 1.0
        for _ in 0..<24 {
            let mid = (lo + hi) / 2
            if clears(CGFloat(mid)) { hi = mid } else { lo = mid }
        }
        return CGFloat(hi)
    }

    /// Tiny thread-safe memo - `mutedInk` is called for effectively every
    /// muted label on every re-theme, and the bisection above, while cheap,
    /// has no reason to run more than once per palette.
    private final class MutedAlphaCache {
        private var storage: [String: CGFloat] = [:]
        private let lock = NSLock()
        func value(for id: String) -> CGFloat? {
            lock.lock(); defer { lock.unlock() }
            return storage[id]
        }
        func store(_ value: CGFloat, for id: String) {
            lock.lock(); defer { lock.unlock() }
            storage[id] = value
        }
    }

    // MARK: The two original, hand-pinned Helm palettes

    static let dark = HelmTheme(
        id: "helm-dark",
        mode: .dark,
        name: "Helm Dark",
        pairId: "helm-light",
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
        pairId: "helm-dark",
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

// MARK: - The 10 named-family palettes (cockpit-theme-overhaul)
//
// Sourced from each family's own canonical repo - see
// `data/cockpit-theme-research/report.md` Part 2 for exact source URLs, the
// full per-family contrast tables, and the reasoning behind every deviation
// called out below. Unlike the old `derived(...)` palettes these are not
// computed from OKLCH tokens - every hex value here is either lifted
// verbatim from the family's own source, or a deliberate, documented
// deviation from it.

extension HelmTheme {
    // --- Solarized (github.com/altercation/solarized) ---
    //
    // Solarized's own README.md defines a single set of 8 accent hues + an
    // 8-step monotone ramp (base03...base3) reused unchanged across both
    // modes - only which end of the ramp is "background" flips.
    static let solarizedDarkAnsi = [
        "073642", "dc322f", "859900", "b58900", "268bd2", "d33682", "2aa198", "eee8d5",
        // index 8 ("bright black") is base03 - the same hex as this theme's
        // own backgroundHex, an exact 1.00:1 self-match. This is a known,
        // accepted Solarized limitation (confirmed in the family's own
        // ANSI-16 table): no other ramp step is a clean substitute without
        // stopping to look like Solarized's own "bright black".
        "002b36", "dc322f", "859900", "b58900", "268bd2", "d33682", "2aa198", "fdf6e3",
    ]

    static let solarizedDark = HelmTheme(
        id: "solarized-dark", mode: .dark, name: "Solarized Dark", pairId: "solarized-light",
        chromeBackgroundHex: "073642", chromeInkHex: "93a1a1", chromeLineHex: "586e75",
        accentHex: "2aa198",
        foregroundHex: "839496", backgroundHex: "002b36",
        cursorHex: "2aa198", selectionHex: "2aa198", selectionTextHex: "002b36",
        ansiHex: solarizedDarkAnsi
    )

    static let solarizedLight = HelmTheme(
        id: "solarized-light", mode: .light, name: "Solarized Light", pairId: "solarized-dark",
        chromeBackgroundHex: "eee8d5", chromeInkHex: "002b36", chromeLineHex: "93a1a1",
        accentHex: "2aa198",
        // `base00`/`base3` - Solarized's own README-recommended default
        // body-text pairing. Measures 4.13:1, a hair under the 4.5:1 floor
        // (not flagged as a deviation in the sourcing report, which focused
        // its contrast pass on the ANSI/accent/chrome slots) - consistent
        // with this family's whole design philosophy of deliberately
        // desaturated, lower-contrast tones (see the accent caveat below).
        foregroundHex: "657b83", backgroundHex: "fdf6e3",
        cursorHex: "2aa198", selectionHex: "2aa198", selectionTextHex: "002b36",
        ansiHex: [
            "073642", "dc322f", "859900",
            // index 3 (yellow) ships as canonical b58900 despite measuring
            // only 2.98:1 against this light background - darkening it away
            // from Solarized's actual yellow isn't worth the hue drift for a
            // slot most themes here only use sparingly. Accepted limitation.
            "b58900",
            "268bd2", "d33682", "2aa198",
            // index 7/15 ("white"/"bright white") deviate from canonical
            // base2/base3 (`eee8d5`/`fdf6e3`) - both measure 1.14:1/1.00:1
            // against this light background, nearly invisible. base01
            // (`586e75`) is the only ramp step that clears 4.5:1 (4.99:1)
            // without abandoning Solarized's own ramp for a non-canonical hue.
            "586e75",
            "002b36", "dc322f", "859900", "b58900", "268bd2", "d33682", "2aa198", "586e75",
        ]
    )

    // --- Catppuccin (github.com/catppuccin/palette, github.com/catppuccin/alacritty) ---
    //
    // Every value below is sourced verbatim - the report found zero contrast
    // failures for this family, so no deviations were needed anywhere.
    static let catppuccinMocha = HelmTheme(
        id: "catppuccin-mocha", mode: .dark, name: "Catppuccin Mocha", pairId: "catppuccin-latte",
        chromeBackgroundHex: "1e1e2e", chromeInkHex: "cdd6f4", chromeLineHex: "6c7086",
        accentHex: "cba6f7",
        foregroundHex: "cdd6f4", backgroundHex: "181825",
        cursorHex: "cba6f7", selectionHex: "cba6f7", selectionTextHex: "1e1e2e",
        ansiHex: [
            "45475a", "f38ba8", "a6e3a1", "f9e2af", "89b4fa", "f5c2e7", "94e2d5", "bac2de",
            "585b70", "f38ba8", "a6e3a1", "f9e2af", "89b4fa", "f5c2e7", "94e2d5", "a6adc8",
        ]
    )

    static let catppuccinLatte = HelmTheme(
        id: "catppuccin-latte", mode: .light, name: "Catppuccin Latte", pairId: "catppuccin-mocha",
        chromeBackgroundHex: "eff1f5", chromeInkHex: "4c4f69", chromeLineHex: "9ca0b0",
        accentHex: "8839ef",
        foregroundHex: "4c4f69", backgroundHex: "e6e9ef",
        cursorHex: "8839ef", selectionHex: "8839ef", selectionTextHex: "eff1f5",
        ansiHex: [
            "bcc0cc", "d20f39", "40a02b", "df8e1d", "1e66f5", "ea76cb", "179299", "5c5f77",
            "acb0be", "d20f39", "40a02b", "df8e1d", "1e66f5", "ea76cb", "179299", "6c6f85",
        ]
    )

    // --- Gruvbox (github.com/morhetz/gruvbox, colors/gruvbox.vim) ---
    static let gruvboxDark = HelmTheme(
        id: "gruvbox-dark", mode: .dark, name: "Gruvbox Dark", pairId: "gruvbox-light",
        chromeBackgroundHex: "3c3836", chromeInkHex: "ebdbb2", chromeLineHex: "665c54",
        accentHex: "fe8019",
        foregroundHex: "ebdbb2", backgroundHex: "282828",
        cursorHex: "fe8019", selectionHex: "fe8019", selectionTextHex: "282828",
        ansiHex: [
            "282828", "cc241d", "98971a", "d79921", "458588", "b16286", "689d6a", "a89984",
            // index 8 ("bright black" / dim-but-legible text, per this
            // project's own precedent for this slot) brightened from
            // Gruvbox's canonical `gray` (928374, 4.02:1 on this background -
            // below the 4.5:1 floor this slot is held to) to 9e8c7a
            // (4.55:1), staying the same grey-brown hue.
            "9e8c7a", "fb4934", "b8bb26", "fabd2f", "83a598", "d3869b", "8ec07c", "ebdbb2",
        ]
    )

    static let gruvboxLight = HelmTheme(
        id: "gruvbox-light", mode: .light, name: "Gruvbox Light", pairId: "gruvbox-dark",
        chromeBackgroundHex: "fbf1c7", chromeInkHex: "3c3836", chromeLineHex: "bdae93",
        accentHex: "af3a03",
        foregroundHex: "3c3836", backgroundHex: "fbf1c7",
        cursorHex: "af3a03", selectionHex: "af3a03", selectionTextHex: "fbf1c7",
        ansiHex: [
            "fbf1c7", "cc241d", "98971a",
            // index 3 (yellow) darkened from canonical `neutral_yellow`
            // (d79921, 2.19:1 on this light background) to 876700 (4.66:1) -
            // Gruvbox publishes no third yellow to fall back to.
            "876700",
            "458588", "b16286", "689d6a", "7c6f64",
            // index 8 ("bright black"), same fix as gruvbox-dark's ansi[8]
            // but darkened instead: canonical `gray` (928374) measures only
            // 3.24:1 here; 726557 clears at 4.98:1, same grey-brown hue.
            "726557",
            "9d0006", "79740e",
            // index 11 ("bright yellow" / faded_yellow) darkened from
            // canonical b57614 (3.33:1) to 8f5f0a (4.86:1), same reasoning
            // as index 3 above.
            "8f5f0a",
            "076678", "8f3f71", "427b58", "3c3836",
        ]
    )

    // --- Tokyo Night (github.com/enkia/tokyo-night-vscode-theme) ---
    static let tokyoNightDark = HelmTheme(
        id: "tokyo-night-dark", mode: .dark, name: "Tokyo Night", pairId: "tokyo-night-light",
        chromeBackgroundHex: "16161e", chromeInkHex: "a9b1d6",
        // No dedicated divider token is published for this family; derived
        // as a ~12% blend of chromeInkHex into chromeBackgroundHex, the same
        // ratio helm-dark/helm-light's own hand-picked chromeLineHex sits at
        // relative to their chrome background (~1.5:1, decorative only).
        chromeLineHex: "282934",
        accentHex: "7aa2f7",
        // `editor.foreground`, not the literal `terminal.foreground`
        // (787c99) - that value measures only 4.40:1 on this background,
        // just under the floor. `editor.foreground` is an equally authentic
        // published Tokyo Night token and clears at 8.10:1.
        foregroundHex: "a9b1d6", backgroundHex: "16161e",
        cursorHex: "7aa2f7", selectionHex: "7aa2f7", selectionTextHex: "16161e",
        ansiHex: [
            "363b54", "f7768e", "73daca", "e0af68", "7aa2f7", "bb9af7", "7dcfff",
            // index 7 ("white") - same `editor.foreground` swap as
            // `foregroundHex` above, replacing canonical `terminal.foreground`.
            "a9b1d6",
            "363b54", "f7768e", "73daca", "e0af68", "7aa2f7", "bb9af7", "7dcfff",
            // index 15 ("bright white") keeps the canonical, unreplaced
            // `terminal.foreground`-derived value - enkia's port doesn't
            // distinguish it from index 7 the way it does on light mode below.
            "acb0d0",
        ]
    )

    static let tokyoNightLight = HelmTheme(
        id: "tokyo-night-light", mode: .light, name: "Tokyo Night Light", pairId: "tokyo-night-dark",
        chromeBackgroundHex: "d6d8df", chromeInkHex: "343b59",
        chromeLineHex: "c3c5cf",
        accentHex: "2959aa",
        foregroundHex: "343b59", backgroundHex: "d6d8df",
        cursorHex: "2959aa", selectionHex: "2959aa", selectionTextHex: "d6d8df",
        ansiHex: [
            "343B58", "8c4351", "33635c",
            // index 3 (yellow) ships as canonical 8f5e15 despite measuring
            // only 3.90:1 - no alternate yellow is published for this port.
            // Accepted limitation, same reasoning as Solarized's yellow.
            "8f5e15",
            "2959aa", "7b43ba", "006c86",
            // index 7 ("white") - `editor.foreground` swap, same as dark
            // mode above, replacing canonical `terminal.foreground` (707280).
            "343b59",
            "343B58", "8c4351", "33635c", "8f5e15", "2959aa", "7b43ba", "006c86",
            // index 15 ("bright white") keeps the canonical value (707280,
            // 3.35:1) - enkia's port makes this the one slot that's
            // byte-identical to its normal counterpart, so it wasn't swapped
            // to `editor.foreground` like index 7 was. Accepted limitation,
            // no alternate published to substitute.
            "707280",
        ]
    )

    // --- Rosé Pine (github.com/rose-pine/palette, /alacritty, /vscode) ---
    static let rosePineMain = HelmTheme(
        id: "rose-pine-main", mode: .dark, name: "Rosé Pine", pairId: "rose-pine-dawn",
        chromeBackgroundHex: "1f1d2e", chromeInkHex: "e0def4", chromeLineHex: "26233a",
        // `iris` - clears both the UI-accent job (7.88:1 on chromeBackground)
        // and the selection-fill job (8.43:1) on this mode; `pine` (used for
        // Dawn instead) fails the UI-accent job here at 2.70:1. An
        // intentionally asymmetric accent choice across the family's two
        // modes, mirroring how helm-dark/helm-light already use two
        // different accent hexes rather than a lightness twist of one hue.
        accentHex: "c4a7e7",
        foregroundHex: "e0def4", backgroundHex: "191724",
        cursorHex: "c4a7e7", selectionHex: "c4a7e7", selectionTextHex: "191724",
        ansiHex: [
            "26233a", "eb6f92", "31748f", "f6c177", "9ccfd8", "c4a7e7", "ebbcba", "e0def4",
            "6e6a86", "eb6f92", "31748f", "f6c177", "9ccfd8", "c4a7e7", "ebbcba", "e0def4",
        ]
    )

    static let rosePineDawn = HelmTheme(
        id: "rose-pine-dawn", mode: .light, name: "Rosé Pine Dawn", pairId: "rose-pine-main",
        chromeBackgroundHex: "fffaf3",
        // Current `rose-pine/palette` repo's `dawn.text` (`464261`), not the
        // older `575279` still shipped by some of the family's other ports
        // (`alacritty`/`vscode`) for the same role - both clear contrast,
        // `464261` is simply the more current source of record.
        chromeInkHex: "464261", chromeLineHex: "f2e9e1",
        // `pine` - clears both jobs on this mode (5.88:1 UI accent, 5.59:1
        // selection fill); `iris` (used for Main instead) fails both here.
        accentHex: "286983",
        foregroundHex: "464261", backgroundHex: "faf4ed",
        cursorHex: "286983", selectionHex: "286983", selectionTextHex: "faf4ed",
        ansiHex: [
            "f2e9e1", "b4637a", "286983", "ea9d34", "56949f", "907aa9", "d7827e", "464261",
            "9893a5", "b4637a", "286983", "ea9d34", "56949f", "907aa9", "d7827e", "464261",
        ]
    )

    /// All 12 palettes: the two hand-pinned Helm originals, then the 10
    /// sourced-family themes grouped by family (dark variant then its
    /// light pair).
    static let allThemes: [HelmTheme] = [
        dark, light,
        solarizedDark, solarizedLight,
        catppuccinMocha, catppuccinLatte,
        gruvboxDark, gruvboxLight,
        tokyoNightDark, tokyoNightLight,
        rosePineMain, rosePineDawn,
    ]

    static func theme(id: String) -> HelmTheme? {
        allThemes.first { $0.id == id }
    }

    /// A small rounded two-tone swatch (chrome background + accent) for the
    /// theme-picker menu.
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
