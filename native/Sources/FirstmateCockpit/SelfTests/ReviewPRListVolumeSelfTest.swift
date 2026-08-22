// Manjesh Grand Line - native macOS app.
//
// `fm/grandline-review-page-stuck-loading-fix`: the volume test that proves
// `ReviewPRListView`'s fix, mirroring `BlockViewVolumeSelfTest.swift`'s
// shape (measure real wall-clock cost at a row count comfortably past the
// point this codebase's Diff-tool history measured a plain `NSStackView`
// blowing up - ~300-340 rows taking ~13.6 seconds, see
// `DiffResultView.swift`'s header) rather than just asserting "no crash".
//
// A regression back to a plain `NSStackView` of permanent `HelmAccentRow`s
// (what `fm/grandline-review-page-redesign`, #221, actually shipped) would
// fail this test by taking far longer than the budget below, not by
// crashing - see `ReviewPRListView.swift`'s header for the full root-cause
// writeup. Run with:
//
//   swift build && FM_RUN_REVIEW_PR_LIST_VOLUME_TESTS=1 .build/debug/FirstmateCockpit; echo $?

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

enum ReviewPRListVolumeSelfTest {

    /// Comfortably past the ~300-340 rows that made the Diff tool's old
    /// `NSStackView` approach take ~13.6 seconds.
    private static let prCount = 400

    /// A generous ceiling, not a tight one - this test exists to catch a
    /// gross regression back to the `NSStackView` pathology, not to enforce
    /// a specific number.
    private static let renderBudgetSeconds: Double = 5.0

    static func run() -> Bool {
        var failures = 0

        let (setSeconds, setFailure) = measureSetPRs()
        if let setFailure {
            print("FAIL setsRealisticVolumeOfPRsWithinBudget: \(setFailure)")
            failures += 1
        } else {
            print("PASS setsRealisticVolumeOfPRsWithinBudget (\(prCount) PRs in \(String(format: "%.3f", setSeconds))s)")
        }

        let clearFailure = measureClearAfterVolume()
        if let clearFailure {
            print("FAIL clearingBackToEmptyAfterVolumeStaysCheap: \(clearFailure)")
            failures += 1
        } else {
            print("PASS clearingBackToEmptyAfterVolumeStaysCheap")
        }

        print("ReviewPRListVolumeSelfTest: setPRs=\(String(format: "%.3f", setSeconds))s for \(prCount) synthetic PRs")
        print(failures == 0 ? "ReviewPRListVolumeSelfTest: all cases passed" : "ReviewPRListVolumeSelfTest: \(failures)/2 cases FAILED")
        return failures == 0
    }

    // MARK: Helpers

    private static func syntheticPR(index: Int) -> MergedPR {
        MergedPR(
            source: index % 3 == 0 ? "work" : "forge",
            taskID: index % 3 == 0 ? "task-\(index)" : nil,
            repo: "manjesh-raj/repo-\(index % 11)",
            url: "https://github.com/manjesh-raj/repo-\(index % 11)/pull/\(index)",
            number: index,
            title: "A realistic PR title for issue #\(index) touching the pipeline",
            checks: ["green", "pending", "red", "none"][index % 4],
            forge: "github"
        )
    }

    /// A plain, no-op action target - this test never clicks a row's
    /// Review/Merge button, it only needs `ReviewPRListView`'s init to have
    /// something valid to wire cells to.
    private final class DummyTarget: NSObject {
        @objc func noop(_ sender: Any?) {}
    }

    private static func makeMountedList() -> (window: NSWindow, list: ReviewPRListView, target: NSObject) {
        let target = DummyTarget()

        let list = ReviewPRListView(
            emptyTitle: "No open PRs here",
            emptyBody: "This forge has nothing waiting on you right now.",
            actionTarget: target,
            reviewAction: #selector(DummyTarget.noop(_:)),
            mergeAction: #selector(DummyTarget.noop(_:)),
            checksVisuals: { checks in
                switch checks {
                case "green": return (.good, "Ready to merge")
                case "red": return (.critical, "Checks failing")
                case "pending": return (.warn, "Checks running")
                default: return (.neutral, "No checks")
                }
            }
        )

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 700),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 700))
        window.contentView = root
        root.addSubview(list)
        NSLayoutConstraint.activate([
            list.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            list.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            list.topAnchor.constraint(equalTo: root.topAnchor),
        ])
        root.layoutSubtreeIfNeeded()
        return (window, list, target)
    }

    private static func measureSetPRs() -> (seconds: Double, failure: String?) {
        let (window, list, target) = makeMountedList()
        let prs = (0..<prCount).map(syntheticPR)

        // This is the exact call `ReviewController.render(_:)` makes per
        // forge, at real volume rather than #221's own small synthetic set.
        let start = DispatchTime.now()
        list.setPRs(prs, theme: ThemeManager.shared.theme)
        list.window?.contentView?.layoutSubtreeIfNeeded()
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000_000

        guard list.debugRowCount == prCount else {
            return (elapsed, "expected \(prCount) rows, got \(list.debugRowCount)")
        }
        guard elapsed <= renderBudgetSeconds else {
            return (elapsed, "setPRs(_:) took \(elapsed)s for \(prCount) PRs, over the \(renderBudgetSeconds)s budget - " +
                    "see AGENTS.md's Diff-tool history for this exact NSStackView pathology")
        }
        _ = window
        _ = target
        return (elapsed, nil)
    }

    private static func measureClearAfterVolume() -> String? {
        let (window, list, target) = makeMountedList()
        let prs = (0..<prCount).map(syntheticPR)
        list.setPRs(prs, theme: ThemeManager.shared.theme)
        list.window?.contentView?.layoutSubtreeIfNeeded()

        list.setPRs([], theme: ThemeManager.shared.theme)
        list.window?.contentView?.layoutSubtreeIfNeeded()

        guard list.debugRowCount == 0 else {
            return "expected 0 rows after clearing, got \(list.debugRowCount)"
        }
        guard list.debugTableHeight == ReviewPRListView.emptyRowHeight else {
            return "expected the empty-state height after clearing, got \(list.debugTableHeight)"
        }
        _ = window
        _ = target
        return nil
    }
}

#endif
