// swift-tools-version:5.9
import PackageDescription

// Firstmate Cockpit - native macOS app.
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
    dependencies: [
        // The only production-grade native macOS terminal you can embed as a library.
        // Pinned to the 1.x line; Package.resolved records the exact commit (1.15.0).
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", .upToNextMajor(from: "1.2.0"))
    ],
    targets: [
        .executableTarget(
            name: "FirstmateCockpit",
            dependencies: [
                .product(name: "SwiftTerm", package: "SwiftTerm")
            ]
        )
    ]
)
