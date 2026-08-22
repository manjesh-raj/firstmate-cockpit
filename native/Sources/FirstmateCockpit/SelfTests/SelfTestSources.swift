// Manjesh Grand Line - native macOS app.
//
// GL-27: where the app's own source files are, for the handful of self-tests
// that assert something about the source rather than about behaviour (no
// `.tertiaryLabelColor` text sites, no stock bezels, no re-derived field
// chrome, no hand-rolled `Process`, every animated surface consulting Reduce
// Motion).
//
// Those guards used to compute their root as `#filePath`'s own directory,
// which was correct while every self-test sat in the same flat directory as the
// app. GL-27 moved the suites into this `SelfTests/` subdirectory (so they can
// be compiled out of the release binary and so 159 app files are no longer
// interleaved with 51 test files), which would have silently pointed every one
// of those guards at a directory containing no app code at all - and each of
// them *skips* when it cannot find its sentinel file, so they would all have
// gone on printing OK while checking nothing.
//
// This is the one place that resolves it, and it verifies the answer rather
// than assuming it: a sentinel app file has to actually be there. Returning
// `nil` is the honest "sources are not next to this binary" case (running the
// packaged `.app`), which callers are expected to report as a SKIP.

// GL-27: compiled into debug builds only.
//
// The 51 self-test suites are ~10,500 lines of test code, fault-injection
// seams and fixture data that used to be linked into the binary the captain
// actually runs. `FM_SELFTESTS` is defined by `Package.swift` for the debug
// configuration only, so `swift build` (and therefore CI and
// `Scripts/run-all-tests.sh`) still has every suite, while
// `swift build -c release` - what `native/build_native_app.sh` assembles the
// shipped `.app` from - has none of it.
//
// Do not remove this guard when editing a suite: `Phase3PolishSelfTest`
// asserts that every file in this directory carries it.
#if FM_SELFTESTS

import Foundation

enum SelfTestSources {

    /// A file that is unambiguously app code and has no plausible reason to be
    /// renamed or moved out of the target's root.
    private static let sentinel = "HelmDesignSystem.swift"

    /// `Sources/FirstmateCockpit/` - the *app's* sources, deliberately not
    /// including this directory. A source guard scanning its own suites would
    /// trip on the very tokens it exists to forbid, since a test names them in
    /// order to look for them.
    static func appSourceDirectory() -> URL? {
        let dir = URL(fileURLWithPath: #filePath)   // .../SelfTests/SelfTestSources.swift
            .deletingLastPathComponent()            // .../SelfTests
            .deletingLastPathComponent()            // .../FirstmateCockpit
        guard FileManager.default.fileExists(atPath: dir.appendingPathComponent(sentinel).path) else {
            return nil
        }
        return dir
    }

    /// Every `.swift` file directly in the app's source root, sorted. Not
    /// recursive: `SelfTests/` is a child of that root and must stay out of
    /// every source guard's view (see above), and nothing else nests today.
    static func appSourceFiles() -> [URL]? {
        guard let dir = appSourceDirectory(),
              let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        else { return nil }
        return files.filter { $0.pathExtension == "swift" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}

#endif
