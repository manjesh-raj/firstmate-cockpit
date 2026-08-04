# Vendored SwiftTerm (patched)

This is a vendored, patched copy of [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm)
`Sources/SwiftTerm`, pinned to upstream commit `dd2fb8ac5b861e7bf617c872895e338f38165648`
(tag `1.15.0`). It replaces the plain SPM remote dependency that `native/Package.swift`
used to declare.

## Why vendored instead of a remote SPM dependency

SGR-2 (dim/faint) terminal text was nearly invisible in light Helm themes: light gray
on near-white. The root cause is `NSColor.dimmedColor(towards:)` in
`Sources/SwiftTerm/Mac/MacExtensions.swift` (and the iOS twin in
`Sources/SwiftTerm/iOS/iOSExtensions.swift`), which blends the foreground 50% toward
the background in flat sRGB regardless of which side is dark. That fixed 50% blend
lands on a good contrast ratio when the background is dark (blending a light ink
toward near-black still leaves it far from the background) but collapses to well
under 2:1 when the background is light (blending a dark ink toward near-white pulls
it most of the way to invisible).

There is no public hook to override this: `dimmedColor`, `getAttributes`,
`buildAttributedString`, and `mapColor` are all `internal` methods inside
`extension TerminalView` (not `open`, not part of the module's public API), and
`TerminalView.draw(_:)` itself is `public` but not `open`, so it can't be overridden
from a subclass in another module either. Fixing this required patching the function
itself, so the dependency is vendored here rather than fetched from GitHub - this
keeps the patch entirely inside this repo (reviewable in a normal diff, no external
fork to maintain) instead of depending on a personal SwiftTerm fork.

## The patch

`dimmedColor(towards:)` (both the AppKit and UIKit variants) now targets a fixed
WCAG contrast ratio (4.5:1, matching this project's own `verify-contrast.mjs` bar)
against the background, found by bisecting the blend fraction along the straight
sRGB line from the foreground to the background, capped at the original 50% so dim
text never becomes *less* dimmed than before. On dark backgrounds the cap wins (the
old 50% blend already clears 4.5:1 by a wide margin, so behavior is unchanged). On
light backgrounds the bisection finds a smaller blend fraction that stays legible
instead of collapsing toward the background. See the doc comment on
`dimmedColor(towards:)` for the exact algorithm.

## Second patch: truecolor de-emphasised text (cockpit-native-fixes5)

The `dimmedColor` patch above only fires for the SGR-2 "faint" attribute. Some tools
render de-emphasised text a different way entirely: a literal 24-bit truecolor
foreground (`ESC[38;2;r;g;bm`) chosen with no idea what background it will ever
render against. Verified live against this exact codebase's own firstmate session
(`tmux capture-pane -e` on a running `claude` pane): Claude Code renders its own
de-emphasised status lines ("Searched for N files...", token/cost footers) as
`ESC[38;2;153;153;153m`, not SGR-2 dim. That gray measures ~6.7:1 against a
near-black dark-theme background (legible, the look the source app intended) but
only ~2.55:1 against a light theme's near-white background - `getAttributes`'s
`flags.contains(.dim)` branch never sees it, so the first patch has no effect on it.

`getAttributes` in `Apple/AppleTerminalView.swift` now also checks whether the raw
foreground (`attribute.fg`) is a `.trueColor` case; if so it calls
`NSColor.legibleColor(against:)` / `UIColor.legibleColor(against:)` (new methods,
`Mac/MacExtensions.swift` / `iOS/iOSExtensions.swift`), which remap the color only if
it doesn't already meet the background contrast floor. This intentionally applies to
*every* truecolor foreground, not just gray/muted-looking ones - there is no reliable
way to distinguish "this is ghost/status text" from "this is a genuine but
unfortunately-low-contrast color choice" from RGB bytes alone, and the remap is
self-gating (a no-op whenever contrast is already sufficient) and hue-preserving
(blends toward black or white, whichever the color is already closer to, so a
saturated color darkens/lightens rather than desaturating to gray). See
`Dimming.contrastFixBlendFraction`'s doc comment for the full algorithm, including
why the blend direction can't simply be inferred from which side of the background
the foreground currently sits on.

## Updating this vendored copy

If SwiftTerm's own `dimmedColor` is ever fixed upstream (or a future version adds a
public/open hook for it), prefer reverting to a plain remote SPM dependency in
`native/Package.swift` and deleting this directory over carrying the patch forward.
Otherwise, to pick up a newer upstream release: replace `Sources/SwiftTerm` with the
new version's tree, then re-apply both patches - `dimmedColor` and `legibleColor` -
to `Mac/MacExtensions.swift`, `iOS/iOSExtensions.swift`, `Dimming.swift`, and the
`getAttributes` call site in `Apple/AppleTerminalView.swift`.
