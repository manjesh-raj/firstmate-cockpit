// Manjesh Grand Line - native macOS app.
//
// `fm/grandline-review-page-stuck-loading-fix`: the loading -> loaded state
// transition regression test the acceptance bar for that fix asked for.
//
// The regression this guards against: `ReviewController.render(_:)` must
// flip `hasLoadedOnce` and unhide the loading skeleton's replacement (the
// stats row + GitHub/Bitbucket forge cards) on its very first call with real
// PR data - and must actually *return* (not hang the main thread inside
// `view.layoutSubtreeIfNeeded()`) within a bounded time. #221's redesign
// (`fm/grandline-review-page-redesign`) put every PR row into a plain
// `NSStackView` of `HelmAccentRow` cards - the same "an NSStackView with
// hundreds of arranged subviews blows up far faster than the row count"
// pathology this codebase has hit at least three times before
// (`DiffResultView.swift`, `BlockView.swift`'s headers) - at the captain's
// real open-PR count, a scale #221's own synthetic-data verification never
// exercised. Because the loading skeleton's `isHidden` flags are flipped
// *before* the catastrophic `layoutSubtreeIfNeeded()` call, the symptom
// wasn't a crash - it was the main thread never getting back around to
// repainting, so the screen visibly stayed on the last frame it drew (the
// loading spinner) for as long as that Auto Layout resolve took. See
// `ReviewPRListView.swift`'s header for the fix (a demand-driven
// `NSTableView`) and `ReviewPRListVolumeSelfTest.swift` for the volume
// measurement that proves the fix, not just the transition logic here.
//
// This file exercises `ReviewController.render(_:)` directly via
// `debugRender(_:)` (see that controller's own "Probe / self-test surface"
// section) - never `refresh()`, which would need a real `gh`/Bitbucket
// network fetch this test has no business making. Run with:
//
//   swift build && FM_RUN_REVIEW_LOADING_STATE_TESTS=1 .build/debug/FirstmateCockpit; echo $?

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

enum ReviewControllerLoadingStateSelfTest {

    /// A generous ceiling, not a tight one - this exists to catch a gross
    /// regression (the main thread never returning from `render(_:)`), not
    /// to enforce a specific number. See `ReviewPRListVolumeSelfTest.swift`
    /// for the tighter, row-count-scaled measurement.
    private static let renderBudgetSeconds: Double = 5.0

    static func run() -> Bool {
        let cases: [(String, () -> String?)] = [
            ("startsOnTheLoadingSkeletonBeforeAnyRender", test_initialStateIsLoading),
            ("firstRenderWithDataFlipsToLoadedAndShowsRows", test_firstRenderReachesLoadedState),
            ("firstRenderWithNoPRsStillFlipsToLoadedState", test_firstRenderWithEmptyDataStillLoads),
            ("aSecondRenderNeverRegressesBackToTheLoadingSkeleton", test_secondRenderStaysLoaded),
            ("realisticOpenPRCountRendersWithinBudget", test_realisticVolumeRendersQuickly),
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
              ? "ReviewControllerLoadingStateSelfTest: all \(cases.count) cases passed"
              : "ReviewControllerLoadingStateSelfTest: \(failures)/\(cases.count) cases FAILED")
        return failures == 0
    }

    // MARK: Helpers

    /// Mounts a real, fully-loaded `ReviewController` inside a real
    /// `NSWindow` - `.view` triggers `loadView()`, and a real window matters
    /// for the same reason `BlockViewHierarchySelfTest.makeMountedContainer`
    /// documents: constraint activation's "do these share a common ancestor"
    /// check behaves differently for a view with no window at all.
    private static func makeMountedController() -> (window: NSWindow, controller: ReviewController) {
        let controller = ReviewController()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 800),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = controller.view
        controller.view.frame = NSRect(x: 0, y: 0, width: 1100, height: 800)
        controller.view.layoutSubtreeIfNeeded()
        return (window, controller)
    }

    private static func syntheticPR(index: Int, forge: String, checks: String, taskID: String?) -> MergedPR {
        MergedPR(
            source: taskID != nil ? "work" : "forge",
            taskID: taskID,
            repo: "manjesh-raj/repo-\(index % 7)",
            url: "https://\(forge == "github" ? "github.com" : "bitbucket.org")/manjesh-raj/repo-\(index % 7)/pull/\(index)",
            number: index,
            title: "Fix issue #\(index) in the pipeline",
            checks: checks,
            forge: forge
        )
    }

    // MARK: Cases

    private static func test_initialStateIsLoading() -> String? {
        let (window, controller) = makeMountedController()
        defer { _ = window }

        guard controller.debugIsLoadingSkeletonVisible else {
            return "loading skeleton should be visible before the first render"
        }
        guard !controller.debugHasLoadedOnce else {
            return "hasLoadedOnce should be false before the first render"
        }
        guard !controller.debugAreForgeSectionsVisible else {
            return "forge sections should stay hidden before the first render"
        }
        return nil
    }

    private static func test_firstRenderReachesLoadedState() -> String? {
        let (window, controller) = makeMountedController()
        defer { _ = window }

        let prs = [
            syntheticPR(index: 1, forge: "github", checks: "green", taskID: "task-1"),
            syntheticPR(index: 2, forge: "github", checks: "pending", taskID: nil),
            syntheticPR(index: 3, forge: "bitbucket", checks: "red", taskID: nil),
        ]

        let start = DispatchTime.now()
        controller.debugRender(prs)
        controller.view.layoutSubtreeIfNeeded()
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000_000

        guard elapsed <= renderBudgetSeconds else {
            return "render(_:) took \(elapsed)s for \(prs.count) PRs, over the \(renderBudgetSeconds)s budget - " +
                   "the exact main-thread-never-returns symptom this fix targets"
        }
        guard controller.debugHasLoadedOnce else {
            return "hasLoadedOnce should flip to true on the first render"
        }
        guard !controller.debugIsLoadingSkeletonVisible else {
            return "the loading skeleton should be hidden after the first render - this is the reported bug"
        }
        guard controller.debugAreForgeSectionsVisible else {
            return "the GitHub/Bitbucket forge cards should be visible after the first render"
        }
        guard controller.debugGithubRowCount == 2 else {
            return "expected 2 GitHub rows, got \(controller.debugGithubRowCount)"
        }
        guard controller.debugBitbucketRowCount == 1 else {
            return "expected 1 Bitbucket row, got \(controller.debugBitbucketRowCount)"
        }
        return nil
    }

    private static func test_firstRenderWithEmptyDataStillLoads() -> String? {
        let (window, controller) = makeMountedController()
        defer { _ = window }

        controller.debugRender([])
        controller.view.layoutSubtreeIfNeeded()

        guard controller.debugHasLoadedOnce else {
            return "hasLoadedOnce should flip to true even with zero open PRs - a genuinely empty page is not a stuck page"
        }
        guard !controller.debugIsLoadingSkeletonVisible else {
            return "the loading skeleton should be hidden even when there are no open PRs"
        }
        guard controller.debugAreForgeSectionsVisible else {
            return "the (empty-state) forge cards should still be visible with zero open PRs"
        }
        return nil
    }

    private static func test_secondRenderStaysLoaded() -> String? {
        let (window, controller) = makeMountedController()
        defer { _ = window }

        controller.debugRender([syntheticPR(index: 1, forge: "github", checks: "green", taskID: "task-1")])
        controller.view.layoutSubtreeIfNeeded()
        guard !controller.debugIsLoadingSkeletonVisible else {
            return "loading skeleton should already be hidden after the first render"
        }

        // A later refresh (e.g. the manual Refresh button, or `viewWillAppear`
        // on a repeat visit) re-renders with new data - it must never flip
        // the page back to the loading skeleton.
        controller.debugRender([])
        controller.view.layoutSubtreeIfNeeded()
        guard !controller.debugIsLoadingSkeletonVisible else {
            return "a second render() regressed the page back to the loading skeleton"
        }
        guard controller.debugHasLoadedOnce else {
            return "hasLoadedOnce should stay true across a second render()"
        }
        return nil
    }

    private static func test_realisticVolumeRendersQuickly() -> String? {
        let (window, controller) = makeMountedController()
        defer { _ = window }

        // Comfortably above a realistic real-world open-PR count across a
        // captain's whole fleet of project clones, but nowhere near the
        // volume `ReviewPRListVolumeSelfTest` measures - this case is about
        // the loading-state transition staying correct at a size larger
        // than #221's own small synthetic verification set, not about
        // finding the exact ceiling.
        let prs = (0..<80).map { i in
            syntheticPR(index: i, forge: i % 2 == 0 ? "github" : "bitbucket",
                        checks: ["green", "pending", "red", "none"][i % 4],
                        taskID: i % 3 == 0 ? "task-\(i)" : nil)
        }

        let start = DispatchTime.now()
        controller.debugRender(prs)
        controller.view.layoutSubtreeIfNeeded()
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000_000

        guard elapsed <= renderBudgetSeconds else {
            return "render(_:) took \(elapsed)s for \(prs.count) PRs, over the \(renderBudgetSeconds)s budget"
        }
        guard controller.debugHasLoadedOnce, !controller.debugIsLoadingSkeletonVisible else {
            return "did not reach the loaded state for \(prs.count) PRs"
        }
        return nil
    }
}

#endif
