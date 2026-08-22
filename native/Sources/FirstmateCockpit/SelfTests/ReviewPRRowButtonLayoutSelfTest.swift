// Manjesh Grand Line - native macOS app.
//
// `fm/grandline-review-row-buttons-regression-fix`: a permanent regression
// guard for the row-width/button-visibility contract that has now broken
// twice on this exact row - first as the original `HelmAccentRow` redesign
// bug (#221, "a 90pt button rendered ~900pt wide"), fixed once by #226/the
// `HelmAccentRow` stack-level hugging trick, then AGAIN when
// `fm/grandline-review-page-stuck-loading-fix` (#227) ported the row into a
// reused `NSTableView` cell view (`ReviewPRRowCellView` in
// `ReviewPRListView.swift`) without carrying the "reused row, toggling
// button visibility" fix `HostsListRecordView` (`HostsListSection.swift`)
// already established for the identical shape: without an explicit
// `.fill` distribution plus `.required` content hugging on *both* buttons
// (not just the stack-level hugging `HelmAccentRow.buildLayout` already
// applies to the whole `trailingAccessory`), AGENTS.md gotcha (10) applies -
// "leftover width is resolved by Auto Layout's own tie-breaking, which can
// drift between runs/rows depending on transient sibling content... even
// with no code change" - here, whether the *previous* PR this reused cell
// displayed had Merge visible. That drift is exactly what a synthetic small
// PR set (like #221's own original verification) can miss, and exactly what
// this test forces by reusing the same table across multiple `setPRs` calls
// with different merge-visibility per row, mirroring how a captain's real
// scroll-and-reload session dequeues the same cell for different PRs.
//
// Run with:
//   swift build && FM_RUN_REVIEW_PR_ROW_BUTTON_LAYOUT_TESTS=1 .build/debug/FirstmateCockpit; echo $?

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

enum ReviewPRRowButtonLayoutSelfTest {

    /// A compact "Review"/"Merge" `HelmButton(size: .small)` never needs
    /// anywhere near this much width - the pre-fix bug stretched one to
    /// several hundred points. Comfortably below the list's own 900pt test
    /// window width, comfortably above either button's real natural width.
    private static let maxCompactButtonWidth: CGFloat = 140

    static func run() -> Bool {
        var failures = 0

        if let failure = checkMergeVisibleRowIsCompactAndBothButtonsShow() {
            print("FAIL mergeVisibleRowShowsBothButtonsCompact: \(failure)")
            failures += 1
        } else {
            print("PASS mergeVisibleRowShowsBothButtonsCompact")
        }

        if let failure = checkPendingChecksRowHidesMergeAndStaysCompact() {
            print("FAIL pendingChecksRowHidesMergeAndStaysCompact: \(failure)")
            failures += 1
        } else {
            print("PASS pendingChecksRowHidesMergeAndStaysCompact")
        }

        if let failure = checkGreenChecksWithNoTaskHidesMerge() {
            print("FAIL greenChecksWithNoTaskIDHidesMerge: \(failure)")
            failures += 1
        } else {
            print("PASS greenChecksWithNoTaskIDHidesMerge")
        }

        if let failure = checkReusedCellStaysCompactAfterMergeVisibilityDrops() {
            print("FAIL reusedCellStaysCompactAfterMergeVisibilityDrops: \(failure)")
            failures += 1
        } else {
            print("PASS reusedCellStaysCompactAfterMergeVisibilityDrops")
        }

        print(failures == 0
              ? "ReviewPRRowButtonLayoutSelfTest: all cases passed"
              : "ReviewPRRowButtonLayoutSelfTest: \(failures)/4 cases FAILED")
        return failures == 0
    }

    // MARK: Helpers

    private static func pr(index: Int, checks: String, taskID: String?) -> MergedPR {
        MergedPR(
            source: taskID != nil ? "work" : "forge",
            taskID: taskID,
            repo: "manjesh-raj/repo",
            url: "https://github.com/manjesh-raj/repo/pull/\(index)",
            number: index,
            title: "A real PR title",
            checks: checks,
            forge: "github"
        )
    }

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

    private static func checkMergeVisibleRowIsCompactAndBothButtonsShow() -> String? {
        let (window, list, target) = makeMountedList()
        list.setPRs([pr(index: 1, checks: "green", taskID: "task-1")], theme: ThemeManager.shared.theme)
        list.window?.contentView?.layoutSubtreeIfNeeded()

        guard let state = list.debugRowButtonState(at: 0) else { return "no cell view at row 0" }
        if state.mergeHidden { return "Merge button was hidden for a checks==green, taskID!=nil PR" }
        if state.reviewFrame.width <= 0 { return "Review button rendered with zero/negative width" }
        if state.mergeFrame.width <= 0 { return "Merge button rendered with zero/negative width" }
        if state.reviewFrame.width > maxCompactButtonWidth {
            return "Review button rendered \(state.reviewFrame.width)pt wide - stretched full-width regression"
        }
        if state.mergeFrame.width > maxCompactButtonWidth {
            return "Merge button rendered \(state.mergeFrame.width)pt wide - stretched full-width regression"
        }
        if state.reviewFrame.intersects(state.mergeFrame) {
            return "Review and Merge button frames overlap: \(state.reviewFrame) vs \(state.mergeFrame)"
        }
        _ = (window, target)
        return nil
    }

    private static func checkPendingChecksRowHidesMergeAndStaysCompact() -> String? {
        let (window, list, target) = makeMountedList()
        list.setPRs([pr(index: 2, checks: "pending", taskID: "task-2")], theme: ThemeManager.shared.theme)
        list.window?.contentView?.layoutSubtreeIfNeeded()

        guard let state = list.debugRowButtonState(at: 0) else { return "no cell view at row 0" }
        if !state.mergeHidden { return "Merge button showed while checks were still pending - regresses #226" }
        if state.reviewFrame.width <= 0 { return "Review button rendered with zero/negative width" }
        if state.reviewFrame.width > maxCompactButtonWidth {
            return "Review button rendered \(state.reviewFrame.width)pt wide with Merge hidden - " +
                   "stretched full-width regression (the exact bug this test guards)"
        }
        _ = (window, target)
        return nil
    }

    private static func checkGreenChecksWithNoTaskHidesMerge() -> String? {
        let (window, list, target) = makeMountedList()
        list.setPRs([pr(index: 3, checks: "green", taskID: nil)], theme: ThemeManager.shared.theme)
        list.window?.contentView?.layoutSubtreeIfNeeded()

        guard let state = list.debugRowButtonState(at: 0) else { return "no cell view at row 0" }
        if !state.mergeHidden {
            return "Merge button showed for a PR with no tracked task - regresses the pr.source==\"work\" gate"
        }
        if state.reviewFrame.width > maxCompactButtonWidth {
            return "Review button rendered \(state.reviewFrame.width)pt wide with Merge hidden"
        }
        _ = (window, target)
        return nil
    }

    /// The actual regression this task fixes: a reused table cell whose
    /// Merge button was visible for one PR, then hidden for the next PR
    /// dequeued into the same cell instance - the exact "transient sibling
    /// content" drift AGENTS.md gotcha (10) describes.
    private static func checkReusedCellStaysCompactAfterMergeVisibilityDrops() -> String? {
        let (window, list, target) = makeMountedList()

        list.setPRs([pr(index: 4, checks: "green", taskID: "task-4")], theme: ThemeManager.shared.theme)
        list.window?.contentView?.layoutSubtreeIfNeeded()
        guard let firstState = list.debugRowButtonState(at: 0) else { return "no cell view at row 0 (first pass)" }
        if firstState.mergeHidden { return "Merge button was hidden on the first pass" }

        // Same table, same dequeued cell, a different PR - Merge now hidden.
        list.setPRs([pr(index: 5, checks: "red", taskID: "task-5")], theme: ThemeManager.shared.theme)
        list.window?.contentView?.layoutSubtreeIfNeeded()
        guard let secondState = list.debugRowButtonState(at: 0) else { return "no cell view at row 0 (second pass)" }
        if !secondState.mergeHidden { return "Merge button stayed visible for checks==red on reuse" }
        if secondState.reviewFrame.width > maxCompactButtonWidth {
            return "Review button rendered \(secondState.reviewFrame.width)pt wide after reuse dropped Merge's " +
                   "visibility - this is the exact #227 regression (stale wider content leaking into the " +
                   "reused actionsRow's tie-break under .gravityAreas)"
        }
        _ = (window, target)
        return nil
    }
}

#endif
