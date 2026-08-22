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
        // Vendored whisper.cpp (ggml-org/whisper.cpp, MIT, pinned to upstream
        // tag v1.9.2 / commit 306c88f), not a remote SPM dependency or CMake
        // build - same zero-remote-dependencies, plain-`swift build`-only
        // convention SwiftTerm/YamlSwift's vendoring already established.
        // Backs Dictation's optional local Whisper engine
        // (fm/grandline-dictation-whisper-engine); see
        // Vendor/whisper.cpp/README.md for what was trimmed from upstream and
        // why (baseline ARM NEON CPU kernels, no CUDA/AMX/llamafile/dynamic-
        // backend-loading/etc). Metal acceleration (fm/grandline-dictation-
        // whisper-metal-accel) is enabled - GGML_USE_METAL plus the vendored
        // ggml-metal/*.{cpp,m} sources under ggml-src/ggml-metal/, auto-
        // discovered by SwiftPM's normal recursive source globbing (no
        // explicit `sources:` list needed). See that README section for how
        // the Metal shader source itself is made available at runtime with
        // no CMake/Xcode build step and no reliance on SwiftPM resource
        // bundles.
        .target(
            name: "CWhisper",
            path: "Vendor/whisper.cpp/Sources/CWhisper",
            publicHeadersPath: "include",
            cSettings: [
                .define("GGML_USE_CPU"),
                .define("GGML_USE_METAL"),
                .define("GGML_VERSION", to: "\"0.18.1-grandline\""),
                .define("GGML_COMMIT", to: "\"306c88f4d1286aec1bf96e544632897886af5501\""),
                .define("WHISPER_VERSION", to: "\"1.9.2\""),
                // ggml-metal-{device,context}.m are upstream Objective-C
                // sources written for manual reference counting (explicit
                // `release` calls, raw `void *` <-> `id<MTLDevice>` casts
                // with no __bridge) - SwiftPM's default clang invocation
                // enables ARC for Objective-C sources, which upstream's own
                // CMake build does not, so ARC has to be turned back off
                // here to match what these files actually expect. Harmless
                // no-op for every plain .c/.cpp file in this target.
                .unsafeFlags(["-fno-objc-arc"]),
                // SwiftPM defines SWIFT_PACKAGE for every target, which
                // steers ggml-metal-device.m into a branch expecting
                // SWIFTPM_MODULE_BUNDLE - a macro SwiftPM only generates for
                // targets that declare `resources:`, which this target
                // deliberately does not (see Vendor/whisper.cpp/README.md's
                // "Metal acceleration" section for why the shader source is
                // embedded in Swift instead of shipped as an SPM resource).
                // Defining it as the same class-based bundle lookup
                // upstream's own non-SWIFT_PACKAGE branch uses keeps that
                // code path compiling and behaving the same either way - it
                // is only ever a first, expected-to-miss probe before
                // WhisperMetalRuntime's GGML_METAL_PATH_RESOURCES env var is
                // checked.
                .define("SWIFTPM_MODULE_BUNDLE", to: "[NSBundle bundleForClass:[GGMLMetalClass class]]"),
                .headerSearchPath("ggml-src"),
                .headerSearchPath("ggml-src/ggml-cpu"),
                .headerSearchPath("ggml-src/ggml-metal"),
                .headerSearchPath("whisper-src"),
            ],
            cxxSettings: [
                .define("GGML_USE_CPU"),
                .define("GGML_USE_METAL"),
                .define("GGML_VERSION", to: "\"0.18.1-grandline\""),
                .define("GGML_COMMIT", to: "\"306c88f4d1286aec1bf96e544632897886af5501\""),
                .define("WHISPER_VERSION", to: "\"1.9.2\""),
                .headerSearchPath("ggml-src"),
                .headerSearchPath("ggml-src/ggml-cpu"),
                .headerSearchPath("ggml-src/ggml-metal"),
                .headerSearchPath("whisper-src"),
            ],
            linkerSettings: [
                .linkedFramework("Foundation"),
                .linkedFramework("Metal"),
                .linkedFramework("MetalKit"),
            ]
        ),
        .executableTarget(
            name: "FirstmateCockpit",
            dependencies: ["SwiftTerm", "Yaml", "CWhisper"],
            swiftSettings: [
                // GL-27: the 51 self-test suites (~10,500 lines, plus their
                // fault-injection seams and fixture data) are compiled into
                // debug builds only. `swift build` - the dev flow, CI, and
                // `Scripts/run-all-tests.sh` - is a debug build and has every
                // suite; `swift build -c release`, which
                // `native/build_native_app.sh` assembles the shipped `.app`
                // from, has none of them.
                //
                // A compilation condition rather than a second SPM target,
                // deliberately: the suites reach `internal` members of this
                // target throughout (that is what lets them drive the *real*
                // `ConsoleController`, `DictationEngine` and stores rather than
                // stand-ins), and a separate target would mean widening
                // hundreds of declarations to `public` - trading a real
                // encapsulation boundary for a build-layout one. `@testable
                // import` is not an option either: it needs a test target, and
                // this project builds with Command Line Tools only, with no
                // XCTest available (see any `SelfTests/*.swift` header).
                .define("FM_SELFTESTS", .when(configuration: .debug)),
            ]
        )
    ],
    cxxLanguageStandard: .cxx17
)
