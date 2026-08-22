// Manjesh Grand Line - native macOS app.
//
// `fm/cockpit-block-view-stage0`: the real-view-hierarchy regression test
// for the crash that shipped in PR #79/#80 and took the whole app down on
// every launch - see `BlockView.swift`'s header for the full root-cause
// writeup. `TerminalBlockTrackerSelfTest.swift` only ever exercises
// `TerminalBlockTracker`'s OSC 133 parsing against a `HeadlessTerminal`; it
// never constructs an `NSView`, so it could not have caught (and did not
// catch) a bug in `BlockContainerView.render(_:)`'s Auto Layout constraint
// ordering. This file closes that gap: it builds a real `NSWindow`, adds a
// real `BlockContainerView` as a subview the same way
// `ConsoleController.addTab` does (four edge constraints, no shortcuts), and
// drives a full render -> re-render -> clear cycle through it, forcing a
// real `layoutSubtreeIfNeeded()` pass after each step.
//
// Why this is real evidence and not just a restatement of the fix: an
// `NSLayoutConstraint` activated between two views that don't yet share a
// common ancestor throws a genuine Objective-C exception synchronously,
// inside `NSLayoutConstraint._setActive:` - not a catchable Swift `Error`,
// and not something a parsing-only test can trigger since it never creates
// the views the constraint would reference. If `BlockContainerView.render(_:)`
// ever regresses back to activating a row's width constraint before calling
// `stack.addArrangedSubview(row)`, this file's process aborts with SIGABRT
// the moment that line runs - there is no way to catch it and print a `FAIL`
// line, so a non-zero exit code (from the signal, not from `run()` returning
// `false`) is itself the failure signal. Run with:
//
//   swift build && FM_RUN_BLOCK_VIEW_HIERARCHY_TESTS=1 .build/debug/FirstmateCockpit; echo $?

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

enum BlockViewHierarchySelfTest {

    static func run() -> Bool {
        let cases: [(String, () -> String?)] = [
            ("rendersARunningBlockWithoutCrashing", test_rendersRunningBlock),
            ("rendersRunningThenFinishedBlockWithoutCrashing", test_runningThenFinished),
            ("rendersMultipleBlocksThenClearsThemWithoutCrashing", test_multipleBlocksThenClear),
            ("survivesThemeReapplyAndVisibilityToggleAfterRender", test_themeReapplyAndVisibilityToggle),
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
        print(failures == 0 ? "BlockViewHierarchySelfTest: all \(cases.count) cases passed" : "BlockViewHierarchySelfTest: \(failures)/\(cases.count) cases FAILED")
        return failures == 0
    }

    // MARK: Helpers

    /// Mounts a `BlockContainerView` inside a real, real-backed `NSWindow` -
    /// the same four-edge-pin pattern `ConsoleController.addTab` uses to add
    /// it as a sibling of a tab's terminal inside `content`. A real
    /// `NSWindow` (not just a bare `NSView`) matters here: constraint
    /// activation's "do these views share a common ancestor" check walks the
    /// real view hierarchy, and a view with no window at all behaves
    /// differently in some Auto Layout edge cases than one that's fully
    /// mounted the way production code actually has it.
    private static func makeMountedContainer() -> (window: NSWindow, root: NSView, container: BlockContainerView) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 480))
        window.contentView = root

        let container = BlockContainerView(frame: .zero)
        root.addSubview(container)
        NSLayoutConstraint.activate([
            container.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            container.topAnchor.constraint(equalTo: root.topAnchor),
            container.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        root.layoutSubtreeIfNeeded()
        return (window, root, container)
    }

    // MARK: Cases

    private static func test_rendersRunningBlock() -> String? {
        let (window, root, container) = makeMountedContainer()
        let block = TerminalBlock(id: UUID(), commandText: "sleep 5 && echo done", outputText: "", status: .running)

        // This is the shape of the exact call that crashed on every launch
        // in the original PR #79/#80 build: a freshly-opened running block,
        // the very first row this container ever renders.
        container.render([block])
        root.layoutSubtreeIfNeeded()

        guard container.subviews.contains(where: { $0 is NSScrollView }) else {
            return "container lost its scroll view after render"
        }
        _ = window
        return nil
    }

    private static func test_runningThenFinished() -> String? {
        let (window, root, container) = makeMountedContainer()
        let id = UUID()

        var block = TerminalBlock(id: id, commandText: "sleep 5 && echo done", outputText: "", status: .running)
        container.render([block])
        root.layoutSubtreeIfNeeded()

        // A manual Refresh re-render (Stage 0's only trigger) after the
        // block closed - the real shape of what `TerminalBlockTracker`'s
        // OSC-133 close handler produces.
        block.commandText = "sleep 5 && echo done"
        block.outputText = "done\r\n"
        block.status = .finished(exitCode: 0)
        container.render([block])
        root.layoutSubtreeIfNeeded()

        _ = window
        return nil
    }

    private static func test_multipleBlocksThenClear() -> String? {
        let (window, root, container) = makeMountedContainer()

        // Several blocks in one render call - the original bug's loop body
        // activated a bad constraint on every single iteration, so multiple
        // blocks in one call is the most direct reproduction of "crashes on
        // every launch" (a real session accumulates more than one block
        // almost immediately).
        let blocks = (0..<5).map { i in
            TerminalBlock(
                id: UUID(),
                commandText: "echo block-\(i)",
                outputText: "output for block \(i)\r\nsecond line",
                status: i % 2 == 0 ? .finished(exitCode: 0) : .finished(exitCode: 1)
            )
        }
        container.render(blocks)
        root.layoutSubtreeIfNeeded()

        // Clearing back to empty exercises `render`'s
        // `removeArrangedSubview`/`removeFromSuperview` teardown path on a
        // non-empty stack, then leaves the empty-state label visible -
        // exactly what `BlockContainerView.clear()` (called alongside
        // `TerminalBlockTracker.reset()` on every restart) does.
        container.clear()
        root.layoutSubtreeIfNeeded()

        _ = window
        return nil
    }

    private static func test_themeReapplyAndVisibilityToggle() -> String? {
        let (window, root, container) = makeMountedContainer()
        let block = TerminalBlock(id: UUID(), commandText: "false", outputText: "", status: .finished(exitCode: 1))
        container.render([block])
        root.layoutSubtreeIfNeeded()

        // `applyTheme` re-renders internally (see `BlockContainerView.
        // applyTheme`) - drive it across every theme, mirroring
        // `ConsoleController.applyTheme` calling this on a theme-manager
        // notification while blocks already exist.
        for theme in HelmTheme.allThemes {
            container.applyTheme(theme)
            root.layoutSubtreeIfNeeded()
        }

        // Toggling visibility is exactly what `ConsoleController.
        // updateTabViewVisibility` does when block view is switched on/off
        // or the tab is deselected - never touches `render`, but exercises
        // the mounted hierarchy's layout under a hidden/visible flip.
        container.isHidden = true
        root.layoutSubtreeIfNeeded()
        container.isHidden = false
        root.layoutSubtreeIfNeeded()

        _ = window
        return nil
    }
}

#endif
