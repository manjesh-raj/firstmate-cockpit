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
        checkFieldRecipe(&ok)
        checkNoReDerivedFieldChrome(&ok)
        checkPageToolbarRecipe(&ok)
        checkResponsiveGrid(&ok)
        checkPageTitleVoice(&ok)
        checkRowDoesNotResizeWindow(&ok)
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

    // MARK: 8b. A row must never resize the window (fm/grandline-design-fidelity-fixes)

    /// **No constraint inside a `ToolRowLayout` row may outrank
    /// `NSLayoutPriorityWindowSizeStayPut` (500).**
    ///
    /// A window only holds its own size at priority 500, so *any* content
    /// constraint above that can reach out and resize the whole window. The
    /// fixed-name-column constraint (§5.4's fix) shipped at `.defaultHigh + 1`
    /// (751) paired with a required `<= nameColumnMaxWidth`, and between them
    /// they capped the entire app window at `nameColumnMaxWidth /
    /// nameColumnFraction` plus the row, card and page insets - **1410pt** -
    /// on every page carrying these rows. On a 1512pt-wide screen the window
    /// refused to grow past that, reported `isZoomed == true` at it, and even
    /// genuine macOS full screen rendered 1410pt wide, centred, with a black
    /// bar down each side.
    ///
    /// Two checks, because either alone would miss it: the priority itself,
    /// and a real window that is asked to be wider than the cap and must
    /// actually stay there.
    private static func checkRowDoesNotResizeWindow(_ ok: inout Bool) {
        print("\n-- rows must not drive window size (priority < 500) --")
        let theme = ThemeManager.shared.theme

        let host = NSView(frame: NSRect(x: 0, y: 0, width: 1600, height: 300))
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            stack.topAnchor.constraint(equalTo: host.topAnchor),
        ])
        let v = ToolRowLayout.Views(
            iconTile: IconTileView(), nameLabel: NSTextField(labelWithString: ""),
            detailLabel: NSTextField(labelWithString: ""), pill: NSView(),
            pillLabel: NSTextField(labelWithString: ""), trailingStack: NSStackView(),
            detailsButton: NSButton(), logField: NSTextField(wrappingLabelWithString: ""),
            logContainer: NSView(), rowContainer: HoverHighlightView())
        ToolRowLayout.pill(text: "Up to Date", colorHex: theme.accentHex,
                           into: v.pill, label: v.pillLabel, theme: theme)
        let row = ToolRowLayout.build(v, iconSymbol: "shippingbox", tint: .info, name: "chrome-devtools-axi",
                                      trailingViews: [HelmButton(title: "Check", variant: .secondary, size: .small)],
                                      identifier: "probe")
        stack.addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        host.layoutSubtreeIfNeeded()

        let stayPut = NSLayoutConstraint.Priority(rawValue: 500)
        var offenders: [NSLayoutConstraint] = []
        func scan(_ view: NSView) {
            for c in view.constraints where c.isActive && c.priority > stayPut && c.priority < .required {
                switch c.firstAttribute {
                case .width, .leading, .trailing, .left, .right, .centerX: offenders.append(c)
                default: break
                }
            }
            view.subviews.forEach(scan)
        }
        scan(host)
        if offenders.isEmpty {
            print("  OK no horizontal row constraint sits above NSLayoutPriorityWindowSizeStayPut")
        } else {
            for c in offenders { print("  FAIL priority \(c.priority.rawValue) > 500: \(c)") }
            ok = false
        }

        // The real thing: a window whose content is one of these rows must be
        // able to hold a width well past `nameColumnMaxWidth / fraction`.
        let target: CGFloat = 1600
        let vc = NSViewController()
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let inner = NSStackView()
        inner.orientation = .vertical
        inner.alignment = .leading
        inner.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(inner)
        NSLayoutConstraint.activate([
            inner.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            inner.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            inner.topAnchor.constraint(equalTo: content.topAnchor),
            inner.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor),
        ])
        let v2 = ToolRowLayout.Views(
            iconTile: IconTileView(), nameLabel: NSTextField(labelWithString: ""),
            detailLabel: NSTextField(labelWithString: ""), pill: NSView(),
            pillLabel: NSTextField(labelWithString: ""), trailingStack: NSStackView(),
            detailsButton: NSButton(), logField: NSTextField(wrappingLabelWithString: ""),
            logContainer: NSView(), rowContainer: HoverHighlightView())
        ToolRowLayout.pill(text: "Up to Date", colorHex: theme.accentHex,
                           into: v2.pill, label: v2.pillLabel, theme: theme)
        let row2 = ToolRowLayout.build(v2, iconSymbol: "shippingbox", tint: .info, name: "chrome-devtools-axi",
                                       trailingViews: [HelmButton(title: "Check", variant: .secondary, size: .small)],
                                       identifier: "probe2")
        inner.addArrangedSubview(row2)
        row2.widthAnchor.constraint(equalTo: inner.widthAnchor).isActive = true
        vc.view = content
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                           styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        win.contentViewController = vc
        win.setFrame(NSRect(x: -30000, y: -30000, width: target, height: 300), display: false)
        win.layoutIfNeeded()
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        let held = win.frame.width
        if held >= target - 1 {
            print("  OK a window carrying one of these rows holds \(Int(held))pt")
        } else {
            print("  FAIL window shrank to \(Int(held))pt when asked for \(Int(target)) - a row constraint is resizing it")
            ok = false
        }
        win.orderOut(nil)
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

    // MARK: 12. One sunken-field recipe (audit §3.2 "Sunken form field", §6.3's
    //            `HelmField` extraction, Phase 6)

    /// Every field shape - single-line, secure, multi-line, date picker, field
    /// card, toggle row - resolves to one radius, one border width and one
    /// fill, in every theme; and that fill is visibly distinct from *both*
    /// page surfaces.
    ///
    /// The distinctness assertion is the load-bearing one, and it is why the
    /// fill blends toward ink rather than using a token straight:
    /// `chromeBackgroundHex == backgroundHex` in three of the twelve palettes
    /// (`gruvbox-light`, `tokyo-night-dark`, `tokyo-night-light`), so a field
    /// painted with either token bare would have no visible boundary at all in
    /// exactly those three - which is a real bug this app has already shipped
    /// once, in the Compose popover.
    private static func checkFieldRecipe(_ ok: inout Bool) {
        print("\n-- form fields (one recipe + a visible boundary, all themes) --")
        var worstInk = (ratio: Double.greatestFiniteMagnitude, label: "")
        var worstMuted = (ratio: Double.greatestFiniteMagnitude, label: "")
        var worstEdge = (ratio: Double.greatestFiniteMagnitude, label: "")
        for theme in HelmTheme.allThemes {
            let text = HelmTextField(placeholder: "Placeholder")
            let secure = HelmSecureTextField(placeholder: "Placeholder")
            let multi = HelmTextView(height: 80)
            let picker = HelmDatePicker()
            let card = HelmFieldCard(label: "Priority", accessory: HelmDotAccessory())
            let toggle = HelmToggleRow(title: "Something", subtitle: "Explains itself")
            text.applyTheme(theme)
            secure.applyTheme(theme)
            multi.applyTheme(theme)
            picker.applyTheme(theme)
            card.applyTheme(theme)
            toggle.applyTheme(theme)

            let shapes: [(String, NSView)] = [
                ("text", text.chromeView), ("secure", secure.chromeView), ("textview", multi.chromeView),
                ("datepicker", picker.chromeView), ("card", card.chromeView), ("toggle", toggle.chromeView),
            ]
            var problems: [String] = []
            let expected = HelmField.fill(theme)
            for (name, view) in shapes {
                let g = HelmField.geometry(of: view)
                // The field card and the toggle row are row-shaped surfaces, so
                // they carry `rRow`; everything else is a control at `rControl`.
                let wantRadius = (name == "card" || name == "toggle") ? HelmMetrics.rRow : HelmField.cornerRadius
                if abs(g.radius - wantRadius) > 0.01 { problems.append("\(name) radius \(g.radius)") }
                if abs(g.borderWidth - 1) > 0.01 { problems.append("\(name) border width \(g.borderWidth)") }
                guard let fill = g.fill else { problems.append("\(name) no fill"); continue }
                if HelmContrast.ratio(fill, expected) > 1.01 { problems.append("\(name) fill is not HelmField.fill") }
            }

            // The fill has to be visibly separate from whichever surface the
            // field lands on. 1.05:1 is a deliberately low bar - a field's
            // boundary is also carried by its border - but it catches "the fill
            // is literally the background", which is the real failure mode.
            for (surfaceName, hex) in [("chrome", theme.chromeBackgroundHex), ("page", theme.backgroundHex)] {
                let r = HelmContrast.ratio(expected, HelmTheme.nsColor(hex))
                if r < worstEdge.ratio { worstEdge = (r, "\(theme.id) vs \(surfaceName)") }
                if r < 1.02 { problems.append("fill indistinguishable from \(surfaceName) (\(fmt(r)))") }
            }

            let inkRatio = HelmContrast.ratio(HelmField.ink(theme), expected)
            if inkRatio < worstInk.ratio { worstInk = (inkRatio, theme.id) }
            if inkRatio < HelmContrast.textTarget - 0.01 {
                problems.append("field text contrast \(fmt(inkRatio))")
            }
            let mutedRatio = HelmContrast.ratio(HelmField.mutedInk(theme), expected)
            if mutedRatio < worstMuted.ratio { worstMuted = (mutedRatio, theme.id) }
            if mutedRatio < HelmContrast.textTarget - 0.01 {
                problems.append("field muted text contrast \(fmt(mutedRatio))")
            }

            if !problems.isEmpty {
                print("  FAIL \(theme.id): \(problems.joined(separator: ", "))")
                ok = false
            }
        }
        print("  OK - one fill / one border / radius \(HelmField.cornerRadius) control + \(HelmMetrics.rRow) row, worst field text \(fmt(worstInk.ratio)) (\(worstInk.label)), worst field muted \(fmt(worstMuted.ratio)) (\(worstMuted.label)), worst fill-vs-surface \(fmt(worstEdge.ratio)) (\(worstEdge.label))")
    }

    // MARK: 13. The sunken fill must stay defined once (audit §3.2, Phase 6)

    /// The audit found this recipe hand-rolled three times, each copy carrying
    /// a doc comment pointing at the others. A fourth is invisible in review
    /// and only shows up as one field that drifts on some themes - so it fails
    /// here instead. Also catches an `NSScrollView` reaching back for AppKit's
    /// own `.bezelBorder` frame, which is the same system chrome `HelmButton`
    /// removed from every push button.
    private static func checkNoReDerivedFieldChrome(_ ok: inout Bool) {
        print("\n-- re-derived field chrome (must not appear in Sources/) --")
        let sourcesDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        guard let files = try? FileManager.default.contentsOfDirectory(at: sourcesDir, includingPropertiesForKeys: nil),
              files.contains(where: { $0.lastPathComponent == "HelmTheme.swift" }) else {
            print("  SKIP - sources not present next to this binary (\(sourcesDir.path))")
            return
        }
        let banned = [
            "blended(withFraction: 0.08, of: ink)",
            "fieldFillColor",
            "styleSunkenField",
            "styleDetailFormField",
            "borderType = .bezelBorder",
        ]
        var offenders: [String] = []
        for file in files where file.pathExtension == "swift" {
            // `HelmForm.swift` is where the one definition lives; this file
            // names the banned strings in prose above.
            if ["HelmForm.swift", "HelmContrastSelfTest.swift"].contains(file.lastPathComponent) { continue }
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            for (n, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("//") { continue }
                for token in banned where line.contains(token) {
                    offenders.append("\(file.lastPathComponent):\(n + 1) \(token)")
                }
            }
        }
        if offenders.isEmpty {
            print("  OK - one HelmField.fill, no re-derived sunken chrome, no scroll-view bezels")
        } else {
            for o in offenders { print("  FAIL \(o)") }
            print("  \(offenders.count) re-derived field-chrome site(s) - use HelmField instead")
            ok = false
        }
    }

    // MARK: 14. The one page toolbar (audit §3.2 "Page toolbars", Phase 7)

    /// Console, Docs and Tools each built their own bar (42 / 44 / 42pt, plus
    /// a second 40pt one inside Docs' Playbook tab) and Console's glyphs were
    /// bare borderless images while the top bar 40pt above rendered bordered
    /// squares. This asserts the shared component resolves to one height, one
    /// fill, one hairline per theme, and that its glyph really is the
    /// bordered `.secondary` square rather than a borderless one - the exact
    /// thing the audit measured as "two icon-button languages".
    private static func checkPageToolbarRecipe(_ ok: inout Bool) {
        print("\n-- page toolbar (one height / fill / hairline / bordered square) --")

        // Shape first, and it is theme-independent: a square at the shared
        // side length, `HelmButton`'s own control radius, and - the part that
        // matters - a variant that paints a border.
        let glyph = HelmPageToolbar.iconButton(symbol: "magnifyingglass", tooltip: "t", target: nil, action: nil)
        // In a real superview, laid out for real - a bare view with no
        // ancestor resolves only some of its own constraints.
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 60))
        host.addSubview(glyph)
        NSLayoutConstraint.activate([
            glyph.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            glyph.centerYAnchor.constraint(equalTo: host.centerYAnchor),
        ])
        host.layoutSubtreeIfNeeded()
        if glyph.variant != .secondary {
            print("  FAIL toolbar glyph variant is \(glyph.variant), not .secondary (a borderless glyph is the audit's finding)")
            ok = false
        }
        // A 1pt tolerance, and the reason is measured rather than slack: the
        // frame lands on exactly 28.0 x 28.0 when the button is inside a real
        // `NSWindow` (verified with a render probe) and 28.0 x 27.5 in this
        // windowless host, because `NSButton.alignmentRectInsets` resolves
        // slightly differently without one. What this check is actually
        // guarding is the 5.5pt error the naive version had - a plain
        // `heightAnchor == 28` renders a **33.5pt** tall box, since Auto Layout
        // sizes the alignment rect while the layer paints the frame (see
        // `HelmPageToolbar.iconButton`).
        let side = HelmPageToolbar.iconButtonSide
        if abs(glyph.frame.width - side) > 1 || abs(glyph.frame.height - side) > 1 {
            print("  FAIL toolbar glyph is \(glyph.frame.size), not a \(side)pt square")
            ok = false
        }
        if abs((glyph.layer?.cornerRadius ?? -1) - HelmMetrics.rControl) > 0.01 {
            print("  FAIL toolbar glyph radius \(glyph.layer?.cornerRadius ?? -1), want \(HelmMetrics.rControl)")
            ok = false
        }

        let bar = HelmPageToolbar()
        bar.setLeading(NSView())
        bar.setTrailing(HelmPageToolbar.group([
            HelmPageToolbar.iconButton(symbol: "plus", tooltip: "t", target: nil, action: nil),
        ]))
        // A real width, so the two slots resolve to real frames.
        bar.frame = NSRect(x: 0, y: 0, width: 900, height: HelmPageToolbar.height)

        for theme in HelmTheme.allThemes {
            bar.applyTheme(theme)
            let g = bar.debugGeometry()
            var problems: [String] = []
            if abs(g.height - HelmPageToolbar.height) > 0.01 { problems.append("height \(g.height)") }
            if let fill = g.fill {
                if HelmContrast.ratio(fill, HelmTheme.nsColor(theme.chromeBackgroundHex)) > 1.01 {
                    problems.append("fill is not chromeBackgroundHex")
                }
            } else {
                problems.append("no fill (a bar with no explicit background paints nothing - gotcha #8)")
            }
            if let sep = g.separatorFill {
                if HelmContrast.ratio(sep, HelmTheme.nsColor(theme.chromeLineHex)) > 1.01 {
                    problems.append("hairline is not chromeLineHex")
                }
            } else {
                problems.append("no hairline")
            }
            if abs(g.leadingMinX - HelmPageToolbar.leadingInset) > 0.51 {
                problems.append("leading inset \(g.leadingMinX)")
            }
            if abs((bar.frame.width - g.trailingMaxX) - HelmPageToolbar.trailingInset) > 0.51 {
                problems.append("trailing inset \(bar.frame.width - g.trailingMaxX)")
            }
            if !problems.isEmpty {
                print("  FAIL \(theme.id): \(problems.joined(separator: ", "))")
                ok = false
            }
        }
        print("  OK - \(HelmPageToolbar.height)pt, chromeBackground fill + chromeLine hairline in all \(HelmTheme.allThemes.count) themes, \(HelmPageToolbar.iconButtonSide)pt bordered .secondary squares")
    }

    // MARK: 15. The one responsive grid (audit §4.8, Phase 7)

    /// Settings' theme grid used a fixed 4-column chunk, which is what left
    /// the audit's ragged 4/2/4/2 last row; Tools and Docs each had their own
    /// copy of the real math. This asserts the shared helper's two guarantees
    /// - column count tracks real width, and a partial last row is padded to a
    /// full column count so `.fillEqually` divides by the same number - hold
    /// for a spread of widths and item counts, including the awkward ones.
    private static func checkResponsiveGrid(_ ok: inout Bool) {
        print("\n-- responsive grid (columns from real width, partial row padded) --")
        let minWidth: CGFloat = 300
        let spacing = HelmResponsiveGrid.spacing

        // Column count must be monotonic in width and never below 1, including
        // for a zero width (the pre-first-layout case, which would otherwise
        // collapse a whole grid to one column permanently).
        var previous = 0
        for width in [CGFloat(0), 200, 320, 600, 900, 1120, 1500, 2400] {
            let columns = HelmResponsiveGrid.columns(containerWidth: width, minItemWidth: minWidth)
            if columns < 1 {
                print("  FAIL width \(width) -> \(columns) columns")
                ok = false
            }
            // Width 0 falls back to a nominal container, so it is exempt from
            // the monotonic check.
            if width > 0 {
                if columns < previous {
                    print("  FAIL width \(width) gave fewer columns (\(columns)) than a narrower one (\(previous))")
                    ok = false
                }
                previous = columns
            }
            let itemWidth = HelmResponsiveGrid.itemWidth(containerWidth: width, columns: columns)
            // Cards plus gaps must fill the container exactly - the "cards
            // hug the leading edge and waste the rest" bug in reverse.
            let container = width > 0 ? width : HelmResponsiveGrid.fallbackContainerWidth
            let total = itemWidth * CGFloat(columns) + spacing * CGFloat(columns - 1)
            if abs(total - container) > 0.01 {
                print("  FAIL width \(width): \(columns) x \(itemWidth) + gaps = \(total), want \(container)")
                ok = false
            }
            if columns > 1 && itemWidth < minWidth - 0.01 {
                print("  FAIL width \(width): \(columns) columns forces \(itemWidth) < minimum \(minWidth)")
                ok = false
            }
        }

        // Every row - full or partial - must end up with the same number of
        // arranged subviews, so a lone leftover card is never stretched.
        for count in 1...13 {
            let rows = HelmResponsiveGrid.rows(Array(0..<count),
                                              containerWidth: 1120,
                                              minItemWidth: minWidth) { _, _ in NSView() }
            let expectedColumns = HelmResponsiveGrid.columns(containerWidth: 1120, minItemWidth: minWidth)
            let slotCounts = Set(rows.map { $0.arrangedSubviews.count })
            if rows.isEmpty || slotCounts != [expectedColumns] {
                print("  FAIL \(count) items -> row slot counts \(slotCounts.sorted()), want every row at \(expectedColumns)")
                ok = false
            }
            if let first = rows.first, first.distribution != .fillEqually {
                print("  FAIL \(count) items -> row distribution \(first.distribution)")
                ok = false
            }
        }
        print("  OK - columns track width, rows fill the container, every row padded to a full column count")
    }

    // MARK: 16. One page-title voice, at one size (audit §6.2, Phase 7)

    /// The captain's registered decision is "promote the serif to the app-wide
    /// page-title voice, at a single size (22)". The audit's finding was that
    /// the serif existed at **four** sizes (15 / 17 / 19 / 22 / 23 across
    /// Shift and the Command Library) with no rule, so the guarantee worth
    /// enforcing is not "serif is used" but "`ShiftFont.serif` is reachable
    /// only through `HelmType.pageTitle`" - which is what keeps a fifth size
    /// from appearing.
    private static func checkPageTitleVoice(_ ok: inout Bool) {
        print("\n-- page-title voice (serif only via HelmType.pageTitle, one size) --")

        for voice in [HelmType.Voice.sans, .serif] {
            let font = HelmType.pageTitle(voice)
            if abs(font.pointSize - 22) > 0.01 {
                print("  FAIL pageTitle(\(voice)) is \(font.pointSize)pt, want 22")
                ok = false
            }
        }
        if HelmType.pageTitle(.serif).fontName == HelmType.pageTitle(.sans).fontName {
            print("  FAIL the serif and sans voices resolve to the same face (\(HelmType.pageTitle(.serif).fontName))")
            ok = false
        }

        let sourcesDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        guard let files = try? FileManager.default.contentsOfDirectory(at: sourcesDir, includingPropertiesForKeys: nil),
              files.contains(where: { $0.lastPathComponent == "HelmTheme.swift" }) else {
            print("  SKIP source guard - sources not present next to this binary")
            return
        }
        var offenders: [String] = []
        for file in files where file.pathExtension == "swift" {
            // `HelmDesignSystem.swift` holds the one call (inside
            // `HelmType.pageTitle`); `ShiftTypography.swift` declares
            // `ShiftFont.serif` itself; this file names it in prose.
            if ["HelmDesignSystem.swift", "ShiftTypography.swift", "HelmContrastSelfTest.swift"]
                .contains(file.lastPathComponent) { continue }
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            for (n, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                if line.trimmingCharacters(in: .whitespaces).hasPrefix("//") { continue }
                if line.contains("ShiftFont.serif(") {
                    offenders.append("\(file.lastPathComponent):\(n + 1)")
                }
            }
        }
        if offenders.isEmpty {
            print("  OK - serif reachable only via HelmType.pageTitle(.serif), at 22pt")
        } else {
            for o in offenders { print("  FAIL \(o) calls ShiftFont.serif directly - use HelmType.pageTitle(.serif) or HelmType.sectionTitle()") }
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
