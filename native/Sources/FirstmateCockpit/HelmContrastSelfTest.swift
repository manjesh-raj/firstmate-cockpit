// Manjesh Grand Line - native macOS app.
//
// Permanent, dependency-free self-test for this app's colour-contrast floors,
// added by `fm/grandline-design-audit-phase0` so the three contrast defects
// that phase fixed (the full-app UI audit's §5.7 shared pill, §5.3 system
// text colours, and §7 item 7's `HelmTheme.mutedInk` constant) cannot
// silently regress the next time a theme or a `HelmTint` is added.
// `FM_RUN_CONTRAST_TESTS=1 .build/debug/FirstmateCockpit`.
//
// It is the audit's own probe made permanent: the same WCAG maths
// (`HelmContrast`, itself the same sRGB -> linear -> 0.2126R + 0.7152G +
// 0.0722B formula `HelmTheme.swift`'s header and the vendored
// `Dimming.swift` document) run over every real `HelmTheme.allThemes`
// palette rather than the handful the original report sampled.
//
// Pure logic - no window, no view tree, no timing. The rendering half (that
// a real pill/tile on a real page actually paints these colours) is verified
// with a temporary off-screen-render probe per this repo's "Verifying native
// UI bugs without a real screenshot" convention, not here.

import AppKit
import Foundation

enum HelmContrastSelfTest {
    /// Every hue a tinted component can be given, by the name it reads as in
    /// the audit's own tables.
    private static let hues: [(String, (HelmTheme) -> String)] = [
        ("red", { $0.ansiHex[1] }),
        ("green", { $0.ansiHex[2] }),
        ("amber", { $0.ansiHex[3] }),
        ("blue", { $0.ansiHex[4] }),
        ("violet", { $0.ansiHex[5] }),
        ("accent", { $0.accentHex }),
        ("neutral", { $0.chromeInkHex }),
    ]

    static func run() -> Bool {
        var ok = true
        print("== Helm contrast self-test: \(HelmTheme.allThemes.count) themes x \(hues.count) hues ==")
        checkPills(&ok)
        checkIconTiles(&ok)
        checkMutedInk(&ok)
        checkNoSystemTextColors(&ok)
        print(ok ? "== contrast: PASS ==" : "== contrast: FAIL ==")
        return ok
    }

    // MARK: 1. The shared status pill (audit §5.7)

    /// `ToolRowLayout.pill` used to paint the label and the wash in the same
    /// hue, which fell below 4.5:1 in 44 of 72 theme/hue pairs. It now routes
    /// through `HelmContrast.tintedSurface`; this asserts the result clears
    /// the floor for every pair, against **both** surfaces a pill can land on.
    private static func checkPills(_ ok: inout Bool) {
        print("\n-- pills (target \(HelmContrast.textTarget):1, label vs its own fill) --")
        var unchanged = 0, adjusted = 0
        for theme in HelmTheme.allThemes {
            var cells: [String] = []
            for (name, hue) in hues {
                let hex = hue(theme)
                let resolved = HelmContrast.tintedSurface(tintHex: hex, theme: theme, target: HelmContrast.textTarget)
                let worst = worstRatio(foreground: resolved.foreground, tintHex: hex, theme: theme, wash: resolved.washAlpha)
                if worst < HelmContrast.textTarget - 0.01 {
                    print("  FAIL \(theme.id) \(name): \(fmt(worst)):1 at wash \(resolved.washAlpha)")
                    ok = false
                }
                // The raw hue as its own label is what the old code did -
                // count how often the fix actually had to change anything, so
                // a future reader can see it is not repainting the whole app.
                if HelmContrast.ratio(HelmTheme.nsColor(hex), resolved.fill) >= HelmContrast.textTarget {
                    unchanged += 1
                } else {
                    adjusted += 1
                }
                cells.append("\(name) \(fmt(worst))")
            }
            print("  \(pad(theme.id, 20)) \(cells.joined(separator: "  "))")
        }
        print("  hue/theme pairs whose raw hue already cleared the floor: \(unchanged); nudged toward ink: \(adjusted)")
    }

    // MARK: 2. Icon tiles (audit §5.7, "related, lower severity")

    /// A glyph is a non-text UI component, so the applicable floor is 3:1.
    /// `IconTileView.applyTheme` routes through the same helper.
    private static func checkIconTiles(_ ok: inout Bool) {
        print("\n-- icon tiles (target \(HelmContrast.nonTextTarget):1, glyph vs its own tile fill) --")
        for theme in HelmTheme.allThemes {
            var cells: [String] = []
            for (name, hue) in hues {
                let hex = hue(theme)
                let resolved = HelmContrast.tintedSurface(tintHex: hex, theme: theme,
                                                          target: HelmContrast.nonTextTarget,
                                                          washSteps: HelmContrast.tileWashSteps)
                let worst = worstRatio(foreground: resolved.foreground, tintHex: hex, theme: theme, wash: resolved.washAlpha)
                if worst < HelmContrast.nonTextTarget - 0.01 {
                    print("  FAIL \(theme.id) \(name): \(fmt(worst)):1 at wash \(resolved.washAlpha)")
                    ok = false
                }
                cells.append("\(name) \(fmt(worst))")
            }
            print("  \(pad(theme.id, 20)) \(cells.joined(separator: "  "))")
        }
    }

    // MARK: 3. The one muted-text token (audit §7 item 7)

    /// `HelmTheme.mutedInk` is the app's single muted/secondary text tone.
    /// Its alpha constant is only correct if it clears 4.5:1 on **both**
    /// surfaces real text sits on, in **every** palette - the original 0.7
    /// was measured against the first 8 palettes only, and the audit found
    /// gruvbox-light at 4.37 and tokyo-night-dark at 4.79 once the 10
    /// sourced-family themes landed.
    private static func checkMutedInk(_ ok: inout Bool) {
        print("\n-- HelmTheme.mutedInk (target \(HelmContrast.textTarget):1, on chrome + page background) --")
        for theme in HelmTheme.allThemes {
            let muted = HelmTheme.mutedInk(theme)
            let onChrome = flattenedRatio(muted, over: theme.chromeBackgroundHex)
            let onPage = flattenedRatio(muted, over: theme.backgroundHex)
            let worst = min(onChrome, onPage)
            let alpha = HelmTheme.mutedAlpha(for: theme)
            let raised = alpha > HelmTheme.baseMutedAlpha ? "  (raised from \(fmt(Double(HelmTheme.baseMutedAlpha))))" : ""
            if worst < HelmContrast.textTarget - 0.01 {
                print("  FAIL \(theme.id): chrome \(fmt(onChrome)) page \(fmt(onPage)) at alpha \(fmt(Double(alpha)))")
                ok = false
            }
            print("  \(pad(theme.id, 20)) chrome \(fmt(onChrome))  page \(fmt(onPage))  alpha \(fmt(Double(alpha)))\(raised)")
        }
    }

    // MARK: 4. No system text colours (audit §5.3)

    /// `.tertiaryLabelColor` fails 4.5:1 in every one of the 12 themes
    /// (measured as low as 1.86:1) and `.secondaryLabelColor` fails in the
    /// light ones, because both are fixed system greys that know nothing
    /// about the active `HelmTheme`. Phase 0 replaced all 36 sites with
    /// `HelmTheme.mutedInk` / `chromeInkHex`; this keeps them gone.
    ///
    /// A source scan rather than a colour measurement, because the defect is
    /// "this token is used at all", not "this token measures badly" - the
    /// measurement is printed alongside so the reason stays visible. Uses
    /// `#filePath` to find the sources, and *skips* (rather than fails) when
    /// they are not present, so a relocated/packaged binary running the other
    /// checks does not report a false failure.
    private static func checkNoSystemTextColors(_ ok: inout Bool) {
        print("\n-- system text colours (must not appear in Sources/) --")
        // Measured under the appearance each theme forces on its own views
        // (`ThemeManager.swift`'s checklist), which is the fairest reading of
        // these tokens - they still fail, because they are fixed system greys
        // that know nothing about which Helm palette is active.
        for theme in HelmTheme.allThemes {
            let appearance = NSAppearance(named: theme.mode == .dark ? .darkAqua : .aqua)
            var t = 0.0, s = 0.0
            let measure = {
                t = flattenedRatio(.tertiaryLabelColor, over: theme.chromeBackgroundHex)
                s = flattenedRatio(.secondaryLabelColor, over: theme.chromeBackgroundHex)
            }
            if let appearance { appearance.performAsCurrentDrawingAppearance(measure) } else { measure() }
            print("  (why) \(pad(theme.id, 18)) .tertiaryLabelColor \(fmt(t))  .secondaryLabelColor \(fmt(s))")
        }
        let sourcesDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        guard let files = try? FileManager.default.contentsOfDirectory(at: sourcesDir, includingPropertiesForKeys: nil),
              files.contains(where: { $0.lastPathComponent == "HelmTheme.swift" }) else {
            print("  SKIP - sources not present next to this binary (\(sourcesDir.path))")
            return
        }
        var offenders: [String] = []
        for file in files where file.pathExtension == "swift" {
            // This file names both tokens in prose above; exclude itself.
            if file.lastPathComponent == "HelmContrastSelfTest.swift" { continue }
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            for (n, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("//") { continue }
                for token in [".tertiaryLabelColor", ".secondaryLabelColor"] where line.contains(token) {
                    offenders.append("\(file.lastPathComponent):\(n + 1) \(token)")
                }
            }
        }
        if offenders.isEmpty {
            print("  OK - no .tertiaryLabelColor / .secondaryLabelColor text sites")
        } else {
            for o in offenders { print("  FAIL \(o)") }
            print("  \(offenders.count) system-colour text site(s) - use HelmTheme.mutedInk / chromeInkHex instead")
            ok = false
        }
    }

    // MARK: Helpers

    /// The chip's own fill is the hue washed over a surface; the label has to
    /// clear the floor on whichever surface the chip actually landed on, so
    /// score the worst of the two.
    private static func worstRatio(foreground: NSColor, tintHex: String, theme: HelmTheme, wash: CGFloat) -> Double {
        let tint = HelmContrast.components(HelmTheme.nsColor(tintHex))
        let fg = HelmContrast.components(foreground)
        return [theme.chromeBackgroundHex, theme.backgroundHex].map { surfaceHex -> Double in
            let surface = HelmContrast.components(HelmTheme.nsColor(surfaceHex))
            return HelmContrast.ratio(fg, HelmContrast.mix(tint, surface, Double(wash)))
        }.min() ?? 0
    }

    /// Contrast of a possibly-translucent colour once composited over an
    /// opaque surface - what the eye actually sees.
    private static func flattenedRatio(_ color: NSColor, over surfaceHex: String) -> Double {
        guard let c = color.usingColorSpace(.sRGB) else { return 0 }
        let surface = HelmContrast.components(HelmTheme.nsColor(surfaceHex))
        let straight = (Double(c.redComponent), Double(c.greenComponent), Double(c.blueComponent))
        let flattened = HelmContrast.mix(straight, surface, Double(c.alphaComponent))
        return HelmContrast.ratio(flattened, surface)
    }

    private static func fmt(_ v: Double) -> String { String(format: "%.2f", v) }
    private static func pad(_ s: String, _ n: Int) -> String {
        s.count >= n ? s : s + String(repeating: " ", count: n - s.count)
    }
}
