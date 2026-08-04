//
//  Dimming.swift
//  SwiftTerm
//
//  Added locally (Firstmate Cockpit vendor patch) to fix SGR-2 (dim/faint)
//  text contrast on light backgrounds. See MacExtensions.swift's
//  `dimmedColor(towards:)` doc comment and Vendor/SwiftTerm/README.md for the
//  full writeup. Shared by both the AppKit (MacExtensions.swift) and UIKit
//  (iOSExtensions.swift) `dimmedColor` implementations so the two platforms
//  can't drift. Uses only `Double` (no CoreGraphics) since this file, like
//  Colors.swift, is also compiled on Linux/Windows.
//

import Foundation

enum Dimming {
    /// WCAG contrast ratio dim text should target against its background -
    /// the same 4.5:1 bar this project's own `scripts/verify-contrast.mjs`
    /// uses for UI text, chosen so dim text stays legible without becoming
    /// as prominent as normal-intensity text.
    static let targetContrastRatio = 4.5

    /// The original, pre-fix behavior blended 50% of the way from the
    /// foreground to the background. That is kept as an upper bound so dim
    /// text on backgrounds that already have plenty of contrast headroom
    /// (e.g. dark themes) renders identically to before.
    static let maxBlendFraction = 0.5

    private static func srgbToLinear (_ c: Double) -> Double {
        c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    }

    /// WCAG relative luminance of an sRGB color.
    private static func relativeLuminance (_ r: Double, _ g: Double, _ b: Double) -> Double {
        0.2126 * srgbToLinear(r) + 0.7152 * srgbToLinear(g) + 0.0722 * srgbToLinear(b)
    }

    /// WCAG contrast ratio between two relative luminances.
    private static func contrastRatio (_ l1: Double, _ l2: Double) -> Double {
        let hi = max(l1, l2), lo = min(l1, l2)
        return (hi + 0.05) / (lo + 0.05)
    }

    /// Finds how far to blend from `(fgRed, fgGreen, fgBlue)` toward
    /// `(bgRed, bgGreen, bgBlue)` (both straight, un-premultiplied sRGB) so the
    /// blended color's contrast against the background is as close as
    /// possible to `targetContrastRatio`, without exceeding `maxBlendFraction`.
    ///
    /// Contrast against the background falls monotonically as the blend
    /// fraction rises (the color moves closer to the background), so a plain
    /// bisection over `[0, maxBlendFraction]` finds the fraction directly:
    /// - If even a full `maxBlendFraction` blend still clears the target
    ///   (typical on dark backgrounds, where the old 50% blend already scores
    ///   ~7:1+), the bisection converges on `maxBlendFraction` itself - dim
    ///   text renders exactly as it did before the fix.
    /// - If the *undimmed* foreground is already below the target (an
    ///   already low-contrast theme), the bisection converges on 0 - the
    ///   least-bad option, rather than dimming an already-marginal color
    ///   further.
    /// - Otherwise (typical on light backgrounds) it converges on whatever
    ///   smaller fraction keeps the ratio at the target.
    static func blendFraction (fgRed: Double, fgGreen: Double, fgBlue: Double,
                                bgRed: Double, bgGreen: Double, bgBlue: Double) -> Double {
        let bgLuminance = relativeLuminance(bgRed, bgGreen, bgBlue)

        func ratio (at t: Double) -> Double {
            let r = fgRed + (bgRed - fgRed) * t
            let g = fgGreen + (bgGreen - fgGreen) * t
            let b = fgBlue + (bgBlue - fgBlue) * t
            return contrastRatio(relativeLuminance(r, g, b), bgLuminance)
        }

        var lo = 0.0
        var hi = maxBlendFraction
        var mid = hi
        for _ in 0..<24 {
            mid = (lo + hi) / 2
            if ratio(at: mid) > targetContrastRatio {
                lo = mid
            } else {
                hi = mid
            }
        }
        return mid
    }

    /// cockpit-native-fixes5: a literal 24-bit truecolor foreground (`ESC[38;2;r;g;bm`)
    /// carries no theme awareness at all - unlike the SGR-2 "faint" attribute above,
    /// which SwiftTerm itself blends toward the background, a truecolor value is
    /// concrete RGB bytes chosen by the child process with no idea what background
    /// they will ever land on. Verified live against this exact codebase's own
    /// firstmate session (`tmux capture-pane -e`): Claude Code renders its own
    /// de-emphasised status lines ("Searched for N files...", token/cost footers)
    /// as `ESC[38;2;153;153;153m`, not SGR-2 dim - so the `dimmedColor` path above
    /// never sees it. That gray measures ~7.4:1 against a near-black dark-theme
    /// background (legible, the look the source app intended) but only ~2.85:1
    /// against a light theme's near-white background - below the 4.5:1 WCAG floor.
    ///
    /// Reusing `blendFraction` above isn't right here: that bisection blends
    /// *toward* the background (intentionally reducing contrast for a stylistic
    /// dim look, capped so it never drops below `targetContrastRatio`). Here the
    /// color already has *insufficient* contrast, so the fix must blend *away*
    /// from the background instead - toward black if the foreground is the darker
    /// of the two, toward white if it's the lighter - raising contrast only as
    /// far as `targetContrastRatio` requires. Contrast rises monotonically as
    /// `t` increases in this direction, the mirror image of the dim case, so the
    /// bisection searches for the *smallest* `t` that clears the bar rather than
    /// the largest one that still clears it.
    ///
    /// This intentionally has no separate "is this dim/ghost text vs. a genuine
    /// color choice" gate: `NSColor.legibleColor(against:)`/`UIColor.legibleColor
    /// (against:)` call this for every truecolor foreground unconditionally, and
    /// it is self-gating - a foreground that already meets the target returns a
    /// blend fraction of 0 (no visible change), which is what keeps normal bright
    /// truecolor text, and any color already legible on the active theme,
    /// untouched. Blending toward black/white also preserves hue (all channels
    /// scale together), so a genuinely-chosen but low-contrast color (e.g. a
    /// dusty diff-removal red, measured live at `38;2;220;90;90`) darkens or
    /// lightens rather than desaturating into gray.
    /// Returns the blend fraction (see doc comment above) plus which endpoint
    /// it blends toward, so callers don't have to re-derive the direction
    /// themselves with a second, potentially-inconsistent luminance formula.
    ///
    /// The direction is NOT simply "whichever side of the background the
    /// foreground currently sits on" - that heuristic breaks when foreground
    /// and background are both clustered near the same extreme (e.g. an
    /// off-white foreground on a light-but-not-identical background): pushing
    /// further toward white barely moves the contrast ratio, because there is
    /// almost no headroom left between the foreground and pure white. Instead
    /// this evaluates the contrast achievable at each endpoint (pure black and
    /// pure white) and picks whichever one can actually reach further, then
    /// bisects the minimal blend toward *that* endpoint to hit the target.
    static func contrastFixBlendFraction(fgRed: Double, fgGreen: Double, fgBlue: Double,
                                          bgRed: Double, bgGreen: Double, bgBlue: Double) -> (fraction: Double, towardWhite: Bool) {
        let bgLuminance = relativeLuminance(bgRed, bgGreen, bgBlue)

        func ratio (toward: Double, t: Double) -> Double {
            let r = fgRed + (toward - fgRed) * t
            let g = fgGreen + (toward - fgGreen) * t
            let b = fgBlue + (toward - fgBlue) * t
            return contrastRatio(relativeLuminance(r, g, b), bgLuminance)
        }

        let currentRatio = ratio(toward: 0, t: 0)
        if currentRatio >= targetContrastRatio { return (0, false) }

        let blackAchievable = ratio(toward: 0, t: 1)
        let whiteAchievable = ratio(toward: 1, t: 1)
        let towardWhite = whiteAchievable > blackAchievable
        let toward: Double = towardWhite ? 1 : 0
        let achievable = towardWhite ? whiteAchievable : blackAchievable

        if achievable < targetContrastRatio {
            // Foreground and background are too close together in luminance
            // for any same-hue blend to separate them enough - use the full
            // blend anyway, the most legible this exact hue can get here.
            return (1, towardWhite)
        }

        var lo = 0.0
        var hi = 1.0
        var mid = hi
        for _ in 0..<24 {
            mid = (lo + hi) / 2
            if ratio(toward: toward, t: mid) < targetContrastRatio {
                lo = mid
            } else {
                hi = mid
            }
        }
        return (hi, towardWhite)
    }
}
