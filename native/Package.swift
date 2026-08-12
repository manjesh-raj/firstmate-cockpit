// swift-tools-version:5.9
import PackageDescription

// Manjesh Grand Line - native macOS app.
//
// Phase 2: a tabbed console surface hosting two SwiftTerm terminals - a real
// login shell and a live mirror of the first mate's tmux session - with Helm
// dark/light terminal theming and in-terminal search, font zoom, and copy.
//
// Built ON the Phase 1 proof (a single SwiftTerm terminal + screenshot paste),
// which is preserved verbatim as the Shell tab. Phase 2 is deliberately
// backend-free: the tmux grouped-session lifecycle is ported to Swift `Process`
// so the console does not need the Python backend running yet (that is Phase 3).
//
// Built with `swift build` (Command Line Tools only - no Xcode / xcodebuild).
let package = Package(
    name: "FirstmateCockpit",
    platforms: [
        // SwiftTerm's AppKit views and the clipboard APIs used here need a recent macOS.
        .macOS(.v13)
    ],
    targets: [
        // Vendored SwiftTerm 1.15.0 (Vendor/SwiftTerm), not a remote SPM dependency.
        // The upstream `dimmedColor(towards:)` (SGR-2 dim/faint text) blends a flat
        // 50% toward the background regardless of whether that background is dark
        // or light, which reads fine on dark themes but leaves dim text nearly
        // invisible on light ones - and there is no public/open hook to override it
        // from outside the module. See Vendor/SwiftTerm/README.md for the patch and
        // why it has to live here instead of a remote fork.
        .target(
            name: "SwiftTerm",
            path: "Vendor/SwiftTerm/Sources/SwiftTerm",
            exclude: ["Mac/README.md"],
            resources: [
                .process("Apple/Metal/Shaders.metal")
            ]
        ),
        // Vendored YamlSwift (behrang/YamlSwift, MIT, pinned to upstream
        // `master` commit 063286d), not a remote SPM dependency - same
        // zero-remote-dependencies rule SwiftTerm's vendoring already
        // follows. Backs the Tools page's YAML validate/beautify tool
        // (cockpit-tools-page-core); see Vendor/YamlSwift/README.md.
        .target(
            name: "Yaml",
            path: "Vendor/YamlSwift/Sources/Yaml"
        ),
        .executableTarget(
            name: "FirstmateCockpit",
            dependencies: ["SwiftTerm", "Yaml"]
        )
    ]
)
