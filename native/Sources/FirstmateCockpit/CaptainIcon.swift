// Firstmate Cockpit - native macOS app.
//
// The captain's own hand-drawn sea-captain artwork for the "Firstmate Latest
// Updates" rail icon (cockpit-native-updates-polish), replacing the generic
// person.fill SF Symbol placeholder. Source: ~/Downloads/captain-logo.png -
// a soft radial-glow gray background with lighter gray line-art on top, not
// usable as an icon as-is.
//
// Extraction (native/scripts/extract-captain-icon.py): a flat luminance
// threshold would have picked up the glow's own brighter center as "icon",
// since the glow itself gets lighter than the far background. Instead the
// script subtracts a heavily blurred copy of the image from itself (a large-
// radius Gaussian, so the glow washes out into its own blur) and thresholds
// that residual - the line art stays because it is consistently brighter
// than its *immediate* surroundings, glow or no glow. A median filter drops
// isolated speckle without eroding the (thin) linework, then a light blur
// anti-aliases the stencil edges before it's cropped to a square bounding
// box and downsampled to 256x256. Verified programmatically: the 256x256
// output has 4171/65536 pixels with alpha > 10 (a real, non-empty
// silhouette, not a blank or fully-opaque square) and visually by rendering
// it over solid magenta and dark backgrounds (see the PR description).
//
// No Assets.xcassets: this project builds with `swift build` only (Swift
// Package Manager, Command Line Tools, no Xcode project) - `xcrun --find
// actool` (the tool that compiles asset catalogs) is absent from a CLT-only
// toolchain, confirmed on this machine. An SPM `resources:` bundle was also
// considered, but `MetalTerminalRenderer.swift`'s own `candidateBundles()`
// comment documents that this *executable* target's generated `Bundle.module`
// accessor `fatalError`s (aborts the process, not throws) if it can't
// resolve the resource-bundle path, and this app's manual bundle assembly
// (`build_native_app.sh`, no py2app/Xcode step) isn't guaranteed to lay
// resources out where that accessor looks - a fragility no SF Symbol carries.
// A base64-embedded PNG literal has no bundle path to resolve at all: it
// works identically under `swift run`, `.build/debug/FirstmateCockpit`, and
// any assembled .app, and stays exactly as self-contained as the rest of
// this app's vendored/inlined assets (no CDN, no remote dependency).
import AppKit

enum CaptainIcon {
    /// A template image (see `IconRailController.railButton`), so it tints
    /// via `contentTintColor` exactly like every other rail icon, in every
    /// Helm theme - never a fixed-color blob.
    static let templateImage: NSImage? = {
        guard let data = Data(base64Encoded: base64PNG) else { return nil }
        let image = NSImage(data: data)
        image?.isTemplate = true
        return image
    }()

    // 256x256 PNG, RGBA, black fill / alpha-carries-the-shape - see the file
    // header above for how this was produced from captain-logo.png.
    private static let base64PNG =
        "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" +
        "shCLWYSBnDsJPycK6W8MahzjfCr3/JNo0VZZIPR14c8+hBJgn9biAQOfZ4lRiM/bZxbl9JWVld9mBSTUlY7BBUAQHCzM/Vz952VGBiHm0aT9or9cAPcArgDM" +
        "WFAsFzQ3PEvIQRSieSV8fyWgwSi99ClVAA7uwzNZXAOTHk/kSd1u95f6/f7rKDxSpl3psz8Wkwq3RcS+C3cAE4VQalLbA6Hv+xeA3IIJBdJeE6Qllxq+719B" +
        "HcvK/4cbAHeW9/gLwq21sJhq0vbpGlzKYJ43ztrDoIYKMzXqq2PSzVApRSAQXXgGzFS4GQwgnseGFytzuLAsApz9voB5gTPix2IYesrugrW1tT9FkwpGnTF4" +
        "O6y5uEKw0ZQLcJJgA2Ll/xbDhBAheo8BXp3UcdaRbkTjFnbOlQKj9vsaRN3z7M6L6Om+S4IJFCN+LIYxUNaLKjSQpSCrhskAASeU+LLF+uU63ZZpKI/NLUGx" +
        "XhftuLcPXBQpxFja7fYPQZad1ZvoAPzgfr//ZuS7RWWgpPlabKPueVbEKHuvLHYFDqnF5zCSXzfRN7KyYOZDvWaangIWFhZ7B2cP999389XCwmJ0bGBWg9T6" +
        "9hYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhat" +
        "neD/A+0ztqhKpSqYAAAAAElFTkSuQmCC"
}
