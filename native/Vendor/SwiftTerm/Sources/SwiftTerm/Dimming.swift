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
}
