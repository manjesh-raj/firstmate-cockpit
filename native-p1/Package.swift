// swift-tools-version:5.9
import PackageDescription

// Firstmate Cockpit - native macOS P1 proof.
//
// A single-window AppKit app that embeds one SwiftTerm terminal running the
// operator's login shell. Its whole reason to exist is to let the captain judge
// two things that cannot be checked headlessly: native terminal *feel*, and the
// screenshot-paste-into-Claude round trip. See README.md for the run + validation
// steps.
//
// Built with `swift build` (Command Line Tools only - no Xcode / xcodebuild).
let package = Package(
    name: "FirstmateCockpitP1",
    platforms: [
        // SwiftTerm's AppKit views and the clipboard APIs used here need a recent macOS.
        .macOS(.v13)
    ],
    dependencies: [
        // The only production-grade native macOS terminal you can embed as a library.
        // Pinned to the 1.x line; Package.resolved records the exact commit.
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", .upToNextMajor(from: "1.2.0"))
    ],
    targets: [
        .executableTarget(
            name: "FirstmateCockpitP1",
            dependencies: [
                .product(name: "SwiftTerm", package: "SwiftTerm")
            ]
        )
    ]
)
