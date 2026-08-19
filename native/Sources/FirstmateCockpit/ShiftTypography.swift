// Manjesh Grand Line - native macOS app.
//
// Shift's own presentation layer (fm/cockpit-shift-ui-polish), matching the
// captain-approved mockup at
// data/cockpit-shift-ui-polish/reviewed-mockup-reference.html. This is
// deliberately the *only* new file this pass adds: everything else - dark
// palette, priority/status/sync tint colors, hover highlighting - already
// existed and was already wired into `ThemeManager`/`HelmTint`/
// `HoverHighlightView` before this pass (see ShiftController.swift's header
// for what the root-cause check actually found). The one thing genuinely
// missing was the mockup's three-typeface system - every Shift label used
// the app's default `.systemFont` sans face, with no serif/mono distinction
// anywhere - plus a shared bordered-panel container matching the mockup's
// `.panel`/`.panel-head`. Both are Shift-specific per the task brief ("extend
// the tokens where Shift needs something the rest of the app doesn't have
// yet"), not a second app-wide font/color system: every color here still
// flows through `HelmTheme`/`HelmTint` exactly like the rest of the app.

import AppKit

/// The mockup's three type roles: `--serif` for the greeting and panel
/// headings, `--mono` for kicker labels/counts/stat numbers/pill text,
/// `--sans` (the app's existing default, untouched) for everything else.
enum ShiftFont {
    static func serif(_ size: CGFloat) -> NSFont {
        NSFont(name: "Georgia", size: size) ?? .systemFont(ofSize: size)
    }

    static func mono(_ size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        .monospacedSystemFont(ofSize: size, weight: weight)
    }
}

/// `ShiftPanelView` used to live here - the bordered/rounded header + divider
/// + body panel Shift, Vault and Dictation all shared. It is now `HelmCard`
/// in `HelmDesignSystem.swift`, where it is the app's single card container
/// rather than one of five (full-app UI audit §6.3 component 1). Nothing
/// about the look changed in that move.

/// `ShiftEmptyStateView` used to live here - the centered icon-over-copy
/// "nothing here yet" placeholder every table-backed list in the app used. It
/// is now `HelmEmptyState` in `HelmDesignSystem.swift`, where it is the app's
/// single empty state rather than one of six (full-app UI audit §6.3
/// component 5), widened with `DocsController`'s Playbook empty state's title
/// and action button. Its `.compact` size renders exactly as this class did.
