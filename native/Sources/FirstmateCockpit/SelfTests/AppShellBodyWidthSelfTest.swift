// Manjesh Grand Line - native macOS app.
//
// `fm/grandline-live-gap-rootcause-scout`: regression coverage for the
// captain-reported "black/blank gap on the right side of the window" bug.
// The scout report (`data/grandline-live-gap-rootcause-scout/report.md`)
// captured, live, on the captain's own running instance:
//
//   window.frame                = {{0, 0}, {1033, 949}}
//   contentView.frame           = {{0, 0}, {1032.5, 949}}   (tracks window)
//   bodyContainer.frame         = {{84, 0}, {1428, 949}}    (does NOT)
//
// `bodyContainer`'s width (1428) matched the *screen's* width minus the
// rail (1512 - 84), not the window's real, current width minus the rail
// (1033 - 84 = 949) - a 479pt discrepancy repeated identically across
// `bodyContainer` and all twelve destination views mounted inside it. This
// file builds a real `AppShellController` inside a real `NSWindow` (the
// same shape `BlockViewHierarchySelfTest.swift`/`SRELeadPerTabSelfTest.swift`
// already use for this kind of real-view-hierarchy regression test) and
// drives real window resizes through it, asserting `bodyContainer`'s width
// tracks the window's actual current content width at every step - the
// property this task's report found to be violated.
//
// The first two cases are ordinary sanity coverage; they can pass even on
// a build that never hits the specific staleness this task fixed, since a
// freshly-built, freshly-resized hierarchy has no reason to already be
// stale. The third case, `widthSelfHealsAfterATieIsSilentlyBroken`, is what
// actually proves the fix: it deliberately reproduces the exact starting
// condition the live bug exhibited (the width tie inactive, the frame
// stuck at a stale, screen-sized value) via
// `AppShellController.debugBreakBodyWidthTieForTests()`, then fires a real
// resize and asserts `reassertBodyContainerWidthTie()` (wired to
// `NSWindow.didResizeNotification`) repairs it. Confirmed live, per this
// project's own convention, to actually catch a regression rather than
// just pass: temporarily reverting `AppShellController.swift`'s fix (no
// resize observer, no reactivation) makes this exact case fail - the frame
// stays at its stale, pre-break value after the resize, since nothing
// notices the tie is inactive - and reapplying the fix makes it pass again.
//
// `fm/grandline-log-analyzer-body-width-regression` found and fixed a SECOND,
// unrelated way to reach this same symptom (identical geometry, but nothing
// to do with the width-tie staleness above): `LogAnalyzerController`'s
// Compare tab ties `comparePopupBefore`/`comparePopupAfter` to their own
// column at `.required`. That tie is a real, externally-added constraint -
// not one a stack's own `.gravityAreas`/arrangement math would skip for a
// hidden arranged subview - so it stayed fully binding straight through the
// Compare tab (hidden until chosen), `tabContainer` (hidden until an
// analysis exists) and this destination's own root, all the way up to
// `bodyContainer`. A popup's intrinsic width comes from its populated menu
// items (`renderComparePickers()` always adds at least one, and one per
// captured evidence label - free-form text a captain can make arbitrarily
// long), so it could cap the *whole window* at whatever width those items
// needed - on every destination, not just Log Analyzer, since bodyContainer
// is shared. `test_bodyContainerTracksWindowAcrossRealisticWidths` below is
// the regression coverage for that fix - confirmed live, per this project's
// convention, to actually catch it: reverting the `LogAnalyzerController`
// fix (dropping that tie back to `.required`) fails this case at every one
// of its swept widths, not just one, and reapplying the fix passes it again.
//
// Run with:
//   swift build && FM_RUN_APP_SHELL_BODY_WIDTH_TESTS=1 .build/debug/FirstmateCockpit; echo $?

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

import AppKit

enum AppShellBodyWidthSelfTest {

    static func run() -> Bool {
        let cases: [(String, () -> String?)] = [
            ("bodyContainerWidthTracksWindowAtLaunch", test_widthTracksWindowAtLaunch),
            ("bodyContainerWidthTracksASeriesOfResizes", test_widthTracksResizeSeries),
            ("widthSelfHealsAfterATieIsSilentlyBroken", test_widthSelfHealsAfterTieBroken),
            ("bodyContainerTracksWindowAcrossRealisticWidths", test_widthTracksAcrossRealisticWidths),
        ]
        var failures = 0
        for (name, testCase) in cases {
            if let failure = testCase() {
                print("FAIL \(name): \(failure)")
                failures += 1
            } else {
                print("PASS \(name)")
            }
        }
        print(failures == 0
            ? "AppShellBodyWidthSelfTest: all \(cases.count) cases passed"
            : "AppShellBodyWidthSelfTest: \(failures)/\(cases.count) cases FAILED")
        return failures == 0
    }

    // MARK: Helpers

    /// A fresh scratch directory per call, so every store this test touches
    /// (`HostStore`/`SSHKeyStore`/`SnippetStore`/`ShiftStore`/`DictationStore`)
    /// reads/writes disposable files under it - never the captain's real
    /// saved hosts/keys/snippets/tasks/dictation data - matching this app's
    /// established `FM_*_FILE`/`FM_*_DIR` scratch-override convention (see
    /// AGENTS.md).
    private static func withScratchEnv<T>(_ body: () -> T) -> T {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("grandline-appshell-body-width-test-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let overrides: [String: String] = [
            "FM_HOSTS_FILE": dir.appendingPathComponent("hosts.json").path,
            "FM_KEYS_FILE": dir.appendingPathComponent("keys.json").path,
            "FM_SNIPPETS_FILE": dir.appendingPathComponent("snippets.json").path,
            "FM_SHIFT_DIR": dir.appendingPathComponent("shift").path,
            "FM_DICTATION_DIR": dir.appendingPathComponent("dictation").path,
        ]
        var previous: [String: String?] = [:]
        for (key, value) in overrides {
            previous[key] = ProcessInfo.processInfo.environment[key]
            setenv(key, value, 1)
        }
        defer {
            for (key, value) in previous {
                if let value { setenv(key, value, 1) } else { unsetenv(key) }
            }
        }
        return body()
    }

    /// Builds a real `AppShellController` (the exact production dependency
    /// shape `main.swift` uses) mounted as a real `NSWindow`'s
    /// `contentViewController` - matching `main.swift`'s own
    /// `window.contentViewController = appShell` ordering, since that
    /// ordering is itself part of what this file's bug lives near (see
    /// AGENTS.md's `fm/grandline-design-fidelity-fixes` history). The window
    /// is deliberately never made key/ordered front - a real resize still
    /// fires `NSWindow.didResizeNotification` for a window that exists but
    /// isn't on screen, and keeping it off screen means this test can never
    /// visibly disturb anything on a shared machine.
    private static func makeMountedShell() -> (window: NSWindow, shell: AppShellController) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1220, height: 720),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        let hostStore = HostStore()
        let keyStore = SSHKeyStore()
        let snippetStore = SnippetStore()
        let shiftStore = ShiftStore()
        let dictationStore = DictationStore()
        let shell = AppShellController(
            hostsPanel: HostsController(hostStore: hostStore, keyStore: keyStore, snippetStore: snippetStore),
            console: ConsoleController(keyStore: keyStore, snippetStore: snippetStore, isFirstmateConsole: false),
            settings: SettingsController(hostStore: hostStore, keyStore: keyStore, snippetStore: snippetStore, dictationStore: dictationStore),
            hostStore: hostStore, keyStore: keyStore, snippetStore: snippetStore, shiftStore: shiftStore,
            dictationStore: dictationStore, commandLibraryStore: CommandLibraryStore(),
            makeHostConsole: { ConsoleController(keyStore: keyStore, snippetStore: snippetStore, isFirstmateConsole: false) }
        )
        window.contentViewController = shell
        return (window, shell)
    }

    /// The width `bodyContainer` should have for a given window: the
    /// window's own current content width minus the fixed 84pt rail - the
    /// exact relationship the scout report found violated live.
    private static func expectedBodyWidth(for window: NSWindow) -> CGFloat {
        (window.contentView?.bounds.width ?? 0) - IconRailController.width
    }

    // MARK: Cases

    private static func test_widthTracksWindowAtLaunch() -> String? {
        withScratchEnv {
            let (window, shell) = makeMountedShell()
            let expected = expectedBodyWidth(for: window)
            let actual = shell.bodyContainerFrameForTests.width
            guard abs(actual - expected) < 0.5 else {
                return "expected bodyContainer width \(expected) at launch (window content width \(window.contentView?.bounds.width ?? -1)), got \(actual)"
            }
            return nil
        }
    }

    private static func test_widthTracksResizeSeries() -> String? {
        withScratchEnv {
            let (window, shell) = makeMountedShell()
            // A wide, screen-like size (matching the scout report's real
            // 1512-wide screen) followed by a narrower one (matching the
            // real 1033-wide window the report captured) - the exact
            // direction of resize the live bug involved.
            for width in [CGFloat(1512), CGFloat(1033), CGFloat(1220), CGFloat(900)] {
                window.setFrame(NSRect(x: 0, y: 0, width: width, height: 900), display: true)
                let expected = expectedBodyWidth(for: window)
                let actual = shell.bodyContainerFrameForTests.width
                guard abs(actual - expected) < 0.5 else {
                    return "after resizing to \(width) wide: expected bodyContainer width \(expected), got \(actual)"
                }
            }
            return nil
        }
    }

    private static func test_widthSelfHealsAfterTieBroken() -> String? {
        withScratchEnv {
            let (window, shell) = makeMountedShell()
            // Start wide (matching the report's real screen width) so the
            // "stale, screen-sized" value this bug produced is concrete and
            // matches the report's own numbers exactly, not just any old
            // value.
            window.setFrame(NSRect(x: 0, y: 0, width: 1512, height: 900), display: true)
            let staleWidth = shell.bodyContainerFrameForTests.width
            guard abs(staleWidth - (1512 - IconRailController.width)) < 0.5 else {
                return "setup failed: expected bodyContainer to be \(1512 - IconRailController.width) wide before breaking the tie, got \(staleWidth)"
            }

            // Reproduce the exact live failure: the width tie goes inactive
            // (whatever the real underlying AppKit cause was - see this
            // file's header) while the window itself later shrinks, exactly
            // as the scout report captured (window real/current, body
            // frozen at the old, wider value).
            shell.debugBreakBodyWidthTieForTests()
            window.setFrame(NSRect(x: 0, y: 0, width: 1033, height: 900), display: true)

            let afterResizeWidth = shell.bodyContainerFrameForTests.width
            let expected = expectedBodyWidth(for: window)
            guard abs(afterResizeWidth - expected) < 0.5 else {
                return "bodyContainer did not self-heal after its width tie was broken and the window resized: "
                    + "expected \(expected) (window content width \(window.contentView?.bounds.width ?? -1)), "
                    + "got \(afterResizeWidth) (still matching the stale \(staleWidth) it had before the break)"
            }
            return nil
        }
    }

    /// `fm/grandline-log-analyzer-body-width-regression`: proves
    /// `bodyContainer` fills the window's real width across a *range* of
    /// realistic widths - not just the one specific dimension a test
    /// happens to check, since a fix tuned to one width could pass this
    /// suite while still being broken generally. Every width below is well
    /// above this page's own legitimate minimum content width (confirmed
    /// separately: `LogAnalyzerController`'s Analysis tab, which is visible
    /// by default, needs roughly 980pt of real content width on its own to
    /// render its raw/structured split without being squished - a genuine
    /// floor unrelated to this bug, not something this test should fight).
    /// This is deliberately a *different* case from
    /// `widthSelfHealsAfterATieIsSilentlyBroken` above: that one reproduces
    /// a specific historical staleness in the width-*tie* mechanism itself;
    /// this one proves no destination's own content can cap the window
    /// below its requested size in the first place, which is a property of
    /// the destinations mounted inside `bodyContainer`, not of the tie.
    private static func test_widthTracksAcrossRealisticWidths() -> String? {
        withScratchEnv {
            let (window, shell) = makeMountedShell()
            for width in [CGFloat(1100), 1220, 1350, 1420, 1512, 1600, 1800, 2000] {
                window.setFrame(NSRect(x: 0, y: 0, width: width, height: 900), display: true)
                let actual = shell.bodyContainerFrameForTests.width
                let expected = width - IconRailController.width
                guard abs(actual - expected) < 0.5 else {
                    return "at window width \(width): expected bodyContainer \(expected), got \(actual) "
                        + "(window's own frame stayed at \(window.frame.width) - a destination's content is "
                        + "capping bodyContainer below what the window actually offers)"
                }
            }
            return nil
        }
    }
}

#endif
