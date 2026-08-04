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

## Updating this vendored copy

If SwiftTerm's own `dimmedColor` is ever fixed upstream (or a future version adds a
public/open hook for it), prefer reverting to a plain remote SPM dependency in
`native/Package.swift` and deleting this directory over carrying the patch forward.
Otherwise, to pick up a newer upstream release: replace `Sources/SwiftTerm` with the
new version's tree, then re-apply the `dimmedColor` patch to both
`Mac/MacExtensions.swift` and `iOS/iOSExtensions.swift`.
