// Manjesh Grand Line - native macOS app.
//
// SRE Lead's four-state phase, and how the toolbar control that shows it
// looks in each state.
//
// **This file used to be `SRELeadStatusPill.swift`, and the control it
// described no longer exists.** That was a bespoke `NSView` drawing its own
// rounded border, a 6pt `CALayer` dot and a label - written before this app
// had a design system, and never migrated by the phase that unified the very
// toolbar it sits in. Phase 7 (`fm/grandline-design-system-phase7`) gave
// Find, Compose, Blocks and Claude usage the shared
// `HelmPageToolbar.labeledButton` recipe (a bordered `.secondary` glyph plus
// label), and `labeledButton`'s own doc comment names "SRE Lead" as one of
// the four controls the audit prototype shows that way - but this control was
// not one of the sites it changed. So the toolbar shipped three labelled icon
// buttons and, first in the same row, a grey dot: the captain's
// `03-sre-lead-icon-live.png` against the proposed
// `02-sre-lead-icon-proposed.png`.
//
// `ConsoleController` now builds it with `makeLabeledButton` like every
// sibling, so there is no second toolbar-control implementation to keep in
// step. What the dot's colour used to carry, `HelmButton.tint` carries -
// a `HelmTint` case, resolved per theme and contrast-corrected by
// `HelmButton` itself, never a raw hue used as a label colour (Phase 0's
// rule). Click behaviour, the label text per state, the tooltip and the
// 5-tab concurrent-cap messaging are all unchanged.

import AppKit

/// Where one tab's SRE Lead currently is.
///
/// `Equatable` (`fm/grandline-sre-lead-per-tab`): this is `SRELeadTabState.
/// phase`'s type as well as what the toolbar control renders, so per-tab
/// cap/gating checks can compare phases with `==` instead of a manual switch.
enum SRELeadPhase: Equatable {
    case notStarted, starting, ready, failed

    /// The glyph for this state.
    ///
    /// The shield family, matching the proposed screenshot, with the outline
    /// as the resting shape. Every member used here was confirmed to resolve
    /// on this OS before being used, because `NSImage(systemSymbolName:)`
    /// returns nil silently and this app has shipped an invisible icon that
    /// way before ("anchor" is not an SF Symbol - see AGENTS.md).
    ///
    /// **`.ready` gets a filled shield, and that is not decoration.** The
    /// other three states are already distinguishable by their label text
    /// ("- starting...", "- failed") or by being the resting state, but
    /// `.notStarted` and `.ready` both read exactly "SRE Lead" - so the only
    /// thing separating "nothing running here" from "running, ask away" would
    /// be `tint`, and a tint is not reliable for that. `HelmButton` routes a
    /// tint through `HelmContrast.legibleTintedText`, which blends the hue
    /// toward the theme's own ink until it clears 4.5:1 - so in a light
    /// palette whose green is already dark, the corrected `.good` label sits
    /// close to plain ink. Seen in a real render: gruvbox-light's `.ready`
    /// was hard to tell from `.notStarted` at a glance. The fill carries the
    /// distinction in every theme, and the tint reinforces it where the
    /// palette allows.
    var symbol: String {
        switch self {
        case .notStarted: return "shield"
        case .starting: return "shield"
        case .ready: return "shield.fill"
        case .failed: return "shield.slash"
        }
    }

    var text: String {
        switch self {
        case .notStarted: return "SRE Lead"
        case .starting: return "SRE Lead \u{2014} starting\u{2026}"
        case .ready: return "SRE Lead"
        case .failed: return "SRE Lead \u{2014} failed"
        }
    }

    /// The state signal the dot used to carry, as a `HelmTint` rather than a
    /// literal hue so it resolves against whichever of the 12 palettes is
    /// active. `HelmButton` runs it through `HelmContrast.legibleTintedText`
    /// before using it on a label, which is the only way a tint hue is
    /// allowed to become text in this app (Phase 0's rule).
    ///
    /// **`nil` for `.notStarted`, deliberately.** That is the default state,
    /// and it is the state the captain's proposed screenshot shows: a plain
    /// bordered control with a white label, reading at exactly the same
    /// weight as the Find and Compose buttons beside it. Tinting it (even
    /// `.neutral`, which resolves to muted ink) would make the control's own
    /// name quieter than its siblings' just for sitting idle. The tint
    /// appears only once there is something to report - which is also what
    /// keeps all four states distinguishable, since `.ready` is then the one
    /// that goes green the way the old dot did.
    var tint: HelmTint? {
        switch self {
        case .notStarted: return nil
        case .starting: return .warn
        case .ready: return .good
        case .failed: return .critical
        }
    }
}
