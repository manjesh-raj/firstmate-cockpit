// Manjesh Grand Line - native macOS app.
//
// Permanent, dependency-free self-test for this app's colour-contrast floors,
// added by `fm/grandline-design-audit-phase0` so the three contrast defects
// that phase fixed (the full-app UI audit's §5.7 shared pill, §5.3 system
// text colours, and §7 item 7's `HelmTheme.mutedInk` constant) cannot
// silently regress the next time a theme or a `HelmTint` is added.
// `fm/grandline-design-system-phase2` added `HelmButton`'s two checks (every
// variant's label against its own fill, and a source guard against the stock
// bezel coming back) for the same reason.
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

/// `HelmButton.Variant`'s cases with the one fact the contrast sweep needs
/// that the enum itself does not carry: whether the variant paints a fill of
/// its own (so its label is scored against that) or is transparent (so its
/// label is scored against the surfaces it can sit on).
private enum HelmButtonVariantsUnderTest {
    static let all: [(variant: HelmButton.Variant, name: String, paintsFill: Bool)] = [
        (.primary, "primary", true),
        (.secondary, "secondary", true),
        (.quiet, "quiet", false),
        (.destructive, "destructive", true),
    ]
}

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
        checkButtonVariants(&ok)
        checkNoStockBezels(&ok)
        checkAccentRowRecipe(&ok)
        checkNoHandRolledKickers(&ok)
        checkStatusColumnAligned(&ok)
        checkStatTileRecipe(&ok)
        checkEmptyStateRecipe(&ok)
        checkSegmentedTabsRecipe(&ok)
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

    // MARK: 5. `HelmButton`'s four variants (audit §3.2 "Buttons", §6.3 #3)

    /// Every variant's label has to clear the text floor against the fill that
    /// variant actually paints, in every palette - including the two the audit
    /// singled out as the risky ones:
    ///
    /// - `.primary` is an opaque `accentHex` fill with a `selectionTextHex`
    ///   label. That pairing is borrowed from SwiftTerm's own selected-text
    ///   tone, so it *should* be safe by construction - this asserts it rather
    ///   than assuming it, which is the whole point of Phase 0's rule.
    /// - `.destructive` puts a tint hue's own label on a wash of itself, which
    ///   is exactly the shape §5.7 measured failing in 44 of 72 pairs. It goes
    ///   through `HelmContrast.tintedSurface`; this proves that holds.
    private static func checkButtonVariants(_ ok: inout Bool) {
        print("\n-- HelmButton variants (target \(HelmContrast.textTarget):1, label vs its own fill) --")
        // The system colours the audit measured stock buttons painting. A
        // variant fill must never resolve to one of these in any theme.
        let systemChrome = [NSColor.controlAccentColor,
                            NSColor.selectedContentBackgroundColor].map(HelmContrast.components)
        for theme in HelmTheme.allThemes {
            var cells: [String] = []
            for variant in HelmButtonVariantsUnderTest.all {
                let p = HelmButton.palette(variant: variant.variant, tint: nil, theme: theme)
                // `.quiet` paints no fill of its own, so score its label
                // against both surfaces it can sit on, like a pill.
                let backdrops: [(String, NSColor)] = variant.paintsFill
                    ? [("fill", p.fill)]
                    : [("card", HelmTheme.nsColor(theme.chromeBackgroundHex)),
                       ("page", HelmTheme.nsColor(theme.backgroundHex))]
                var worst = Double.greatestFiniteMagnitude
                for (name, backdrop) in backdrops {
                    let r = HelmContrast.ratio(p.label, backdrop)
                    worst = min(worst, r)
                    if r < HelmContrast.textTarget - 0.01 {
                        print("  FAIL \(theme.id) .\(variant.name) label on \(name): \(fmt(r)):1")
                        ok = false
                    }
                }
                if variant.paintsFill {
                    let fill = HelmContrast.components(p.fill)
                    for system in systemChrome where abs(fill.0 - system.0) < 0.02
                        && abs(fill.1 - system.1) < 0.02 && abs(fill.2 - system.2) < 0.02 {
                        print("  FAIL \(theme.id) .\(variant.name): fill is macOS system chrome, not the palette")
                        ok = false
                    }
                }
                cells.append("\(variant.name) \(fmt(worst))")
            }
            // The one hard identity: a primary action is the theme's accent.
            let primaryFill = HelmButton.palette(variant: .primary, tint: nil, theme: theme).fill
            if HelmContrast.ratio(primaryFill, HelmTheme.nsColor(theme.accentHex)) > 1.01 {
                print("  FAIL \(theme.id): .primary fill is not accentHex")
                ok = false
            }
            print("  \(pad(theme.id, 20)) \(cells.joined(separator: "  "))")
        }
        // A tinted label (the "\u{2606} Favorite" / "Install in Bootstrap"
        // emphasis three pages used to hand-roll) has to clear the floor too.
        print("  -- tinted labels on .secondary / .quiet --")
        for theme in HelmTheme.allThemes {
            for (name, hue) in hues {
                for variant in [HelmButton.Variant.secondary, .quiet] {
                    let p = HelmButton.palette(variant: variant, tint: tint(named: name), theme: theme)
                    let backdrop = variant == .secondary
                        ? p.fill : HelmTheme.nsColor(theme.chromeBackgroundHex)
                    let r = HelmContrast.ratio(p.label, backdrop)
                    if r < HelmContrast.textTarget - 0.01 {
                        print("  FAIL \(theme.id) .\(variant) tint \(name): \(fmt(r)):1")
                        ok = false
                    }
                    _ = hue
                }
            }
        }
        print("  OK - all \(HelmTheme.allThemes.count) themes x 4 variants, plus every tint on .secondary/.quiet")
    }

    /// `HelmTint` by the name `hues` uses, so the tinted-label sweep above can
    /// ask for the real enum case rather than a hex.
    private static func tint(named name: String) -> HelmTint {
        switch name {
        case "red": return .critical
        case "green": return .good
        case "amber": return .warn
        case "blue": return .info
        case "violet": return .violet
        case "accent": return .accent
        default: return .neutral
        }
    }

    // MARK: 6. The stock bezel must not come back (audit §3.2, §7 Phase 2)

    /// The audit counted 124 `bezelStyle` sites across 29 files; Phase 2 left
    /// exactly one, and it is not a button. A new one is almost always someone
    /// reaching for `NSButton` instead of `HelmButton`, which is invisible in
    /// review and only shows up as one grey control on an otherwise themed
    /// page - so it fails here instead.
    private static func checkNoStockBezels(_ ok: inout Bool) {
        print("\n-- stock bezels (must not appear in Sources/) --")
        let sourcesDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        guard let files = try? FileManager.default.contentsOfDirectory(at: sourcesDir, includingPropertiesForKeys: nil),
              files.contains(where: { $0.lastPathComponent == "HelmTheme.swift" }) else {
            print("  SKIP - sources not present next to this binary (\(sourcesDir.path))")
            return
        }
        // The one allowed site, with the reason it is allowed: this is
        // `NSTextField.bezelStyle` on `TabChipView`'s inline-rename field - a
        // different property on a different class, not a button at all.
        let allowed: Set<String> = ["TabChipView.swift:label.bezelStyle = .roundedBezel"]
        var offenders: [String] = []
        for file in files where file.pathExtension == "swift" {
            if file.lastPathComponent == "HelmContrastSelfTest.swift" { continue }
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            for (n, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("//") || trimmed.hasPrefix("///") { continue }
                guard trimmed.contains("bezelStyle") else { continue }
                if allowed.contains("\(file.lastPathComponent):\(trimmed)") { continue }
                offenders.append("\(file.lastPathComponent):\(n + 1) \(trimmed)")
            }
        }
        if offenders.isEmpty {
            print("  OK - no stock bezels (1 documented NSTextField exception allowed)")
        } else {
            for o in offenders { print("  FAIL \(o)") }
            print("  \(offenders.count) stock-bezel site(s) - use HelmButton instead")
            ok = false
        }
    }

    // MARK: 7. One accent-row recipe (audit §3.2, §6.3 component 2, Phase 3)

    /// Every `HelmAccentRow` renders the same recipe in every theme: the bar
    /// at one weight and position, the badge at one size, the kicker at one
    /// font/kern **in `mutedInk`, never the hue**, and the card at one radius
    /// with a `tint @ 0.4` border. This is the invariant the four
    /// pre-Phase-3 copies each broke differently - `SRELeadChatView`'s worst,
    /// with no border and a hue-coloured kicker.
    private static func checkAccentRowRecipe(_ ok: inout Bool) {
        print("\n-- accent rows (one recipe, all themes) --")
        for theme in HelmTheme.allThemes {
            for (name, _) in hues.prefix(3) {
                let tint: HelmTint = name == "red" ? .critical : (name == "green" ? .good : .warn)
                // The two structural variants both callers use.
                for placement in [HelmAccentRow.ChipPlacement.trailing, .belowBody] {
                    let row = HelmAccentRow(chipPlacement: placement)
                    row.configure(HelmAccentRow.Content(tint: tint,
                                                        kicker: "Kicker",
                                                        title: "A representative row title",
                                                        meta: "a meta line",
                                                        badgeSymbol: "bell.fill",
                                                        chipText: "Chip"),
                                  theme: theme)
                    // Give it a realistic width so the geometry resolves.
                    row.widthAnchor.constraint(equalToConstant: 420).isActive = true
                    let g = row.debugGeometry()
                    let muted = HelmTheme.mutedInk(theme)
                    var problems: [String] = []
                    if abs(g.barFrame.width - 3) > 0.01 { problems.append("bar width \(g.barFrame.width)") }
                    if g.badgeFrame.map({ abs($0.width - HelmMetrics.tileSmall) > 0.01 }) ?? true {
                        problems.append("badge size \(String(describing: g.badgeFrame?.width))")
                    }
                    if abs(g.cardRadius - HelmMetrics.rRow) > 0.01 { problems.append("radius \(g.cardRadius)") }
                    if g.kickerFont?.pointSize != HelmType.kicker().pointSize { problems.append("kicker font") }
                    if (g.kickerKern ?? 0) != HelmType.kickerKern { problems.append("kicker kern \(String(describing: g.kickerKern))") }
                    // The rule: a tint hue is safe as a fill or a bar, never
                    // automatically as text. The kicker is `mutedInk`.
                    if let kc = g.kickerColor, HelmContrast.ratio(kc, muted) > 1.01 {
                        problems.append("kicker not mutedInk")
                    }
                    if !g.chipVisible { problems.append("chip missing") }
                    if g.cardBorderColor == nil { problems.append("no card border") }
                    if !problems.isEmpty {
                        print("  FAIL \(theme.id) \(name) \(placement): \(problems.joined(separator: ", "))")
                        ok = false
                    }
                }
            }
        }
        print("  OK - bar 3pt, badge \(Int(HelmMetrics.tileSmall))pt, radius \(Int(HelmMetrics.rRow)), kicker in mutedInk, tinted border, in all \(HelmTheme.allThemes.count) themes")
    }

    /// A kicker built by hand is how the app ended up with three kern values
    /// for one label, and with `SRELeadChatView` colouring its kicker from
    /// the raw tint hue - the exact "hue as text" mistake §5.7 is about. Every
    /// kicker goes through `HelmType.kicker()`/`kickerKern`, so a stray
    /// `.kern:` outside the design system fails here.
    private static func checkNoHandRolledKickers(_ ok: inout Bool) {
        print("\n-- kickers (must come from HelmType) --")
        let sourcesDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        guard let files = try? FileManager.default.contentsOfDirectory(at: sourcesDir, includingPropertiesForKeys: nil),
              files.contains(where: { $0.lastPathComponent == "HelmTheme.swift" }) else {
            print("  SKIP - sources not present next to this binary (\(sourcesDir.path))")
            return
        }
        var offenders: [String] = []
        for file in files where file.pathExtension == "swift" {
            if ["HelmContrastSelfTest.swift", "HelmDesignSystem.swift"].contains(file.lastPathComponent) { continue }
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            for (n, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("//") { continue }
                guard trimmed.contains(".kern:") else { continue }
                // The token itself is fine wherever it appears.
                if trimmed.contains("HelmType.kickerKern") { continue }
                offenders.append("\(file.lastPathComponent):\(n + 1) \(trimmed)")
            }
        }
        if offenders.isEmpty {
            print("  OK - no hand-rolled kern outside HelmType")
        } else {
            for o in offenders { print("  FAIL \(o)") }
            print("  \(offenders.count) hand-rolled kicker(s) - use HelmType.kickerAttributes")
            ok = false
        }
    }

    // MARK: 8. The status column stays a column (audit §5.4)

    /// The shared checklist row's status pill used to sit immediately after
    /// the name label, so it tracked the name's length: measured at a 64pt
    /// spread over five real Updates rows, forming a ragged diagonal instead
    /// of a column. `ToolRowLayout`'s fixed name column fixed it; this keeps
    /// it fixed, at three widths so the proportional column is exercised
    /// rather than one lucky size.
    private static func checkStatusColumnAligned(_ ok: inout Bool) {
        print("\n-- status column (audit §5.4) --")
        let theme = ThemeManager.shared.theme
        // Deliberately mismatched name lengths *and* action sets - both are
        // what used to move the pill.
        let fixtures: [(String, [String])] = [
            ("gh-axi", ["Check"]),
            ("chrome-devtools-axi", ["Check", "Update"]),
            ("gh (GitHub CLI)", ["Check"]),
            ("DevOps Playbook", ["Check", "Install in Bootstrap \u{2192}"]),
        ]
        for width in [760.0, 1064.0, 1400.0] as [CGFloat] {
            let host = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 400))
            host.translatesAutoresizingMaskIntoConstraints = false
            let stack = NSStackView()
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.translatesAutoresizingMaskIntoConstraints = false
            host.addSubview(stack)
            NSLayoutConstraint.activate([
                host.widthAnchor.constraint(equalToConstant: width),
                stack.leadingAnchor.constraint(equalTo: host.leadingAnchor),
                stack.trailingAnchor.constraint(equalTo: host.trailingAnchor),
                stack.topAnchor.constraint(equalTo: host.topAnchor),
            ])
            var pills: [(NSView, NSView)] = []
            for (name, buttons) in fixtures {
                let v = ToolRowLayout.Views(
                    iconTile: IconTileView(), nameLabel: NSTextField(labelWithString: ""),
                    detailLabel: NSTextField(labelWithString: ""), pill: NSView(),
                    pillLabel: NSTextField(labelWithString: ""), trailingStack: NSStackView(),
                    detailsButton: NSButton(), logField: NSTextField(wrappingLabelWithString: ""),
                    logContainer: NSView(), rowContainer: HoverHighlightView())
                ToolRowLayout.pill(text: "Up to Date", colorHex: theme.accentHex,
                                   into: v.pill, label: v.pillLabel, theme: theme)
                let row = ToolRowLayout.build(
                    v, iconSymbol: "shippingbox", tint: .info, name: name,
                    trailingViews: buttons.map { HelmButton(title: $0, variant: .secondary, size: .small) },
                    identifier: name)
                stack.addArrangedSubview(row)
                row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
                pills.append((v.pill, v.rowContainer))
            }
            host.layoutSubtreeIfNeeded()
            let xs = pills.map { $0.0.convert($0.0.bounds, to: $0.1).minX }
            let spread = (xs.max() ?? 0) - (xs.min() ?? 0)
            if spread > 0.5 {
                print("  FAIL width \(Int(width)): pill x spread \(fmt(Double(spread)))pt - status column is not a column")
                ok = false
            } else {
                print("  OK width \(Int(width)): pill x constant at \(fmt(Double(xs.first ?? 0)))")
            }
        }
    }

    // MARK: 9. One stat-tile recipe (audit §3.2 "Stat tile", §6.3 #4, Phase 4)

    /// Every `HelmStatTile` renders one recipe in every theme - one height, one
    /// radius, one metric size, one caption size, `HelmCard`'s own fill and
    /// border - and, the part that is a real defect rather than inconsistency,
    /// **a tinted metric clears the text floor against the tile's own fill**.
    /// Two of the three copies this replaced set the value label straight to
    /// `HelmTheme.nsColor(tint.hex(in: theme))`, which is §5.7's "a hue is safe
    /// as a fill, not automatically as text" mistake: Solarized Dark's green
    /// measures 2.71:1 that way.
    private static func checkStatTileRecipe(_ ok: inout Bool) {
        print("\n-- stat tiles (one recipe + legible tinted metric, all themes) --")
        var worst = (ratio: Double.greatestFiniteMagnitude, label: "")
        for theme in HelmTheme.allThemes {
            for tint in [nil, HelmTint.good, .warn, .critical, .accent, .info, .violet] as [HelmTint?] {
                let tile = HelmStatTile(symbol: "checkmark.circle", value: "12", caption: "a caption", tint: tint)
                tile.applyTheme(theme)
                tile.widthAnchor.constraint(equalToConstant: 180).isActive = true
                let g = tile.debugGeometry()
                var problems: [String] = []
                if abs(g.tileFrame.height - HelmStatTile.height) > 0.01 {
                    problems.append("height \(g.tileFrame.height)")
                }
                if abs(g.cornerRadius - HelmMetrics.rRow) > 0.01 { problems.append("radius \(g.cornerRadius)") }
                if abs(g.borderWidth - 1) > 0.01 { problems.append("border width \(g.borderWidth)") }
                if g.metricFont?.pointSize != 19 { problems.append("metric size \(String(describing: g.metricFont?.pointSize))") }
                if g.captionFont?.pointSize != 10.5 { problems.append("caption size \(String(describing: g.captionFont?.pointSize))") }
                // The fill is `HelmCard`'s, so a tile and a card on one page can
                // never drift into two surfaces again. The alpha check matters
                // as much as the hue: Updates' copy was the same colour at
                // `@ 0.60`, which is a different *rendered* surface.
                if let fill = g.fill {
                    if HelmContrast.ratio(fill, HelmTheme.nsColor(theme.chromeBackgroundHex)) > 1.01 {
                        problems.append("fill is not the card surface")
                    }
                    if abs(fill.alphaComponent - 1) > 0.01 {
                        problems.append("fill alpha \(fmt(Double(fill.alphaComponent)))")
                    }
                }
                if let metric = g.metricColor, let fill = g.fill {
                    let r = HelmContrast.ratio(metric, fill)
                    if r < worst.ratio { worst = (r, "\(theme.id) \(String(describing: tint))") }
                    if r < HelmContrast.textTarget - 0.01 { problems.append("metric contrast \(fmt(r))") }
                }
                if let caption = g.captionColor,
                   HelmContrast.ratio(caption, HelmTheme.mutedInk(theme)) > 1.01 {
                    problems.append("caption not mutedInk")
                }
                if !problems.isEmpty {
                    print("  FAIL \(theme.id) \(String(describing: tint)): \(problems.joined(separator: ", "))")
                    ok = false
                }
            }
        }
        print("  OK - \(Int(HelmStatTile.height))pt / radius \(Int(HelmMetrics.rRow)) / metric 19 / caption 10.5, card surface, worst metric contrast \(fmt(worst.ratio)) (\(worst.label))")
    }

    // MARK: 10. One empty-state recipe (audit §3.2 "Empty state", §6.3 #5, Phase 4)

    /// Both `HelmEmptyState` sizes render one recipe: a real glyph (four of the
    /// six treatments this replaced had none, and one of those made Vault's
    /// panels collapse to `bodyH=0` - §5.5), body copy in `mutedInk` with a real
    /// non-zero width (the `preferredMaxLayoutWidth` trap this class inherited a
    /// fix for), and a title only where one was asked for.
    private static func checkEmptyStateRecipe(_ ok: inout Bool) {
        print("\n-- empty states (one recipe, both sizes, all themes) --")
        for theme in HelmTheme.allThemes {
            for size in [HelmEmptyState.Size.compact, .standard] {
                for boxed in [false, true] {
                    let empty = HelmEmptyState(symbol: "tray",
                                               title: size == .standard ? "Nothing here" : nil,
                                               body: "A single-line explanation long enough to need a real width to lay out in.",
                                               size: size,
                                               boxed: boxed)
                    empty.applyTheme(theme)
                    // A realistic container, so `layout()` has a width to hand
                    // the wrapping label.
                    let host = NSView(frame: NSRect(x: 0, y: 0, width: 340, height: 160))
                    host.addSubview(empty)
                    NSLayoutConstraint.activate([
                        empty.leadingAnchor.constraint(equalTo: host.leadingAnchor),
                        empty.trailingAnchor.constraint(equalTo: host.trailingAnchor),
                        empty.topAnchor.constraint(equalTo: host.topAnchor),
                        empty.bottomAnchor.constraint(equalTo: host.bottomAnchor),
                    ])
                    host.layoutSubtreeIfNeeded()
                    let g = empty.debugGeometry()
                    var problems: [String] = []
                    if g.glyphFrame.width < 1 { problems.append("no glyph") }
                    if g.titleVisible != (size == .standard) { problems.append("title visible \(g.titleVisible)") }
                    if g.bodyFont?.pointSize != HelmType.caption().pointSize {
                        problems.append("body size \(String(describing: g.bodyFont?.pointSize))")
                    }
                    if let bodyColor = g.bodyColor,
                       HelmContrast.ratio(bodyColor, HelmTheme.mutedInk(theme)) > 1.01 {
                        problems.append("body not mutedInk")
                    }
                    // The trap: a wrapping label in a centre-aligned stack with
                    // inequality side constraints collapses to a few characters
                    // per line unless handed a real width.
                    if g.bodyFrame.width < 100 { problems.append("body width \(fmt(Double(g.bodyFrame.width)))") }
                    if boxed && abs(g.cornerRadius - HelmMetrics.rRow) > 0.01 {
                        problems.append("boxed radius \(g.cornerRadius)")
                    }
                    if !problems.isEmpty {
                        print("  FAIL \(theme.id) \(size) boxed=\(boxed): \(problems.joined(separator: ", "))")
                        ok = false
                    }
                }
            }
        }
        print("  OK - glyph + body in mutedInk at a real width, title only when asked, boxed radius \(Int(HelmMetrics.rRow))")
    }

    // MARK: 11. One sub-navigation recipe (audit §3.2, §6.3 #6, Phase 4)

    /// Every `HelmSegmentedTabs` is pills in a bordered capsule, and the active
    /// pill's label clears the text floor **against the wash it actually sits
    /// on**. Both copies this replaced painted `label.textColor = accent`
    /// directly over an accent wash - the same §5.7 mistake as the stat tiles.
    private static func checkSegmentedTabsRecipe(_ ok: inout Bool) {
        print("\n-- segmented tabs (one recipe + legible active label, all themes) --")
        var worst = (ratio: Double.greatestFiniteMagnitude, label: "")
        for theme in HelmTheme.allThemes {
            for size in [HelmSegmentedTabs.Size.standard, .compact] {
                let tabs = HelmSegmentedTabs(items: [.init(id: "a", title: "First"),
                                                     .init(id: "b", title: "Second"),
                                                     .init(id: "c", title: "Third")],
                                             selected: "b", size: size)
                tabs.applyTheme(theme)
                let g = tabs.debugGeometry()
                var problems: [String] = []
                if g.pillCount != 3 { problems.append("pill count \(g.pillCount)") }
                if g.activeID != "b" { problems.append("active \(g.activeID)") }
                if abs(g.capsuleBorderWidth - 1) > 0.01 { problems.append("no capsule border") }
                if abs(g.capsuleRadius - size.capsuleRadius) > 0.01 { problems.append("capsule radius \(g.capsuleRadius)") }
                if g.pillRadii.contains(where: { abs($0 - size.pillRadius) > 0.01 }) {
                    problems.append("pill radii \(g.pillRadii)")
                }
                if Set(g.labelPointSizes).count != 1 { problems.append("label sizes \(g.labelPointSizes)") }
                // The active label lands on the accent wash composited over the
                // capsule's own fill, which itself sits over one of the two page
                // surfaces - score the worse.
                if let activeInk = g.activeInk, let wash = g.activeFill {
                    for behindHex in [theme.chromeBackgroundHex, theme.backgroundHex] {
                        let capsule = HelmContrast.mix(
                            HelmContrast.components(HelmTheme.nsColor(theme.chromeBackgroundHex)),
                            HelmContrast.components(HelmTheme.nsColor(behindHex)),
                            Double(HelmSegmentedTabs.capsuleAlpha))
                        let fill = HelmContrast.mix(HelmContrast.components(wash), capsule,
                                                    Double(wash.alphaComponent))
                        let r = HelmContrast.ratio(HelmContrast.components(activeInk), fill)
                        if r < worst.ratio { worst = (r, "\(theme.id) \(size)") }
                        if r < HelmContrast.textTarget - 0.01 { problems.append("active label contrast \(fmt(r))") }
                    }
                }
                if let inactiveInk = g.inactiveInk,
                   HelmContrast.ratio(inactiveInk, HelmTheme.mutedInk(theme)) > 1.01 {
                    problems.append("inactive label not mutedInk")
                }
                if !problems.isEmpty {
                    print("  FAIL \(theme.id) \(size): \(problems.joined(separator: ", "))")
                    ok = false
                }
            }
        }
        print("  OK - bordered capsule, one pill radius / label size per size, inactive in mutedInk, worst active label contrast \(fmt(worst.ratio)) (\(worst.label))")
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
