// Manjesh Grand Line - native macOS app.
//
// Permanent, dependency-free self-test for `TerminalView.invalidationRegion`
// (`fm/grandline-terminal-wrap-duplicate-char` - see
// `native/Vendor/SwiftTerm/README.md`'s "wrap redraw boundary" local-patch
// entry for the full writeup). Same convention as `CronExplainerSelfTest.swift`
// et al: this project has no `swift test` story on a Command Line Tools-only
// toolchain, so a pure-logic function gets a permanent, env-var-gated
// self-test instead. Run with:
//
//   swift build && FM_RUN_TERMINAL_WRAP_REDRAW_TESTS=1 .build/debug/FirstmateCockpit; echo $?
//
// This covers only the pure geometry math extracted out of
// `TerminalView.updateDisplay`'s invalidation-rect computation - it cannot,
// by itself, prove that this geometry is what actually eliminates the
// captain-reported duplicated leading character at a wrap boundary (that
// would need a real on-screen window driving real incremental AppKit
// dirty-rect redraws, which this environment cannot fully exercise - see the
// PR description for the full investigation and its limits). What this test
// does guarantee, permanently, is that the fix is genuinely symmetric and
// that the two pre-existing behaviors (extend down below a region that
// doesn't reach the last row; extend fully to the bottom when it does) are
// unchanged.

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

import CoreGraphics
import Foundation
import SwiftTerm

enum TerminalWrapRedrawSelfTest {

    static func run() -> Bool {
        let cases: [(String, () -> String?)] = [
            ("regionStartingAtRowZeroIsNotExtendedUpward", test_regionStartingAtRowZeroIsNotExtendedUpward),
            ("regionNotStartingAtRowZeroIsExtendedUpwardByOneCell", test_regionNotStartingAtRowZeroIsExtendedUpwardByOneCell),
            ("regionNotReachingLastRowIsStillExtendedDownwardByOneCell", test_regionNotReachingLastRowIsStillExtendedDownwardByOneCell),
            ("regionReachingLastRowExtendsFullyToTheBottomUnchanged", test_regionReachingLastRowExtendsFullyToTheBottomUnchanged),
            ("midScreenWrapRegionIsExtendedOnBothEdges", test_midScreenWrapRegionIsExtendedOnBothEdges),
            ("upwardExtensionNeverPushesBelowZero", test_upwardExtensionNeverPushesBelowZero),
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
        print(failures == 0 ? "TerminalWrapRedrawSelfTest: all \(cases.count) cases passed" : "TerminalWrapRedrawSelfTest: \(failures)/\(cases.count) cases FAILED")
        return failures == 0
    }

    // A 24-row, 480pt-tall viewport (20pt cells), 300pt wide - arbitrary but
    // fixed numbers used across every case below.
    private static let cellHeight: CGFloat = 20
    private static let frameWidth: CGFloat = 300
    private static let terminalRows = 24
    private static let frameHeight: CGFloat = CGFloat(terminalRows) * cellHeight // 480

    private static func region(rowStart: Int, rowEnd: Int) -> CGRect {
        TerminalView.invalidationRegion(
            rowStart: rowStart, rowEnd: rowEnd, terminalRows: terminalRows,
            frameWidth: frameWidth, frameHeight: frameHeight, cellHeight: cellHeight)
    }

    // Row N (0 = topmost) occupies y in [frameHeight - (N+1)*cellHeight, frameHeight - N*cellHeight].
    private static func rowRect(_ row: Int) -> (minY: CGFloat, maxY: CGFloat) {
        let maxY = frameHeight - CGFloat(row) * cellHeight
        let minY = maxY - cellHeight
        return (minY, maxY)
    }

    private static func test_regionStartingAtRowZeroIsNotExtendedUpward() -> String? {
        // rowStart = 0, rowEnd = 5 (mid-screen end) - top edge must land exactly
        // at the top of the frame, never beyond it (there is no row -1 to bleed
        // in from).
        let r = region(rowStart: 0, rowEnd: 5)
        if r.maxY != frameHeight {
            return "expected region.maxY == frameHeight (\(frameHeight)) for a row-0-starting region, got \(r.maxY)"
        }
        return nil
    }

    private static func test_regionNotStartingAtRowZeroIsExtendedUpwardByOneCell() -> String? {
        // rowStart = 5, rowEnd = 10 (mid-screen both ends) - the region's top
        // edge should reach one full cell above row 5's own top edge, i.e. up
        // to row 4's own top edge, so row 4's overhang/leftover pixels are
        // included in what gets cleared and redrawn.
        let r = region(rowStart: 5, rowEnd: 10)
        let row4 = rowRect(4)
        if r.maxY != row4.maxY {
            return "expected region.maxY to reach row 4's top edge (\(row4.maxY)) for a rowStart=5 region, got \(r.maxY)"
        }
        return nil
    }

    private static func test_regionNotReachingLastRowIsStillExtendedDownwardByOneCell() -> String? {
        // Pre-existing behavior, unchanged by this fix: rowEnd=10 (not the last
        // row, terminalRows=24) should still extend one cell below row 10, down
        // to row 11's bottom edge.
        let r = region(rowStart: 5, rowEnd: 10)
        let row11 = rowRect(11)
        if r.minY != row11.minY {
            return "expected region.minY to reach row 11's bottom edge (\(row11.minY)), got \(r.minY)"
        }
        return nil
    }

    private static func test_regionReachingLastRowExtendsFullyToTheBottomUnchanged() -> String? {
        // Pre-existing behavior, unchanged by this fix: rowEnd == terminalRows-1
        // extends the region all the way down to y=0, not just one extra cell.
        let r = region(rowStart: 20, rowEnd: terminalRows - 1)
        if r.minY != 0 {
            return "expected region.minY == 0 when rowEnd is the last row, got \(r.minY)"
        }
        // And the new upward extension still applies since rowStart (20) > 0.
        let row19 = rowRect(19)
        if r.maxY != row19.maxY {
            return "expected the last-row case to still extend upward to row 19's top edge (\(row19.maxY)), got \(r.maxY)"
        }
        return nil
    }

    private static func test_midScreenWrapRegionIsExtendedOnBothEdges() -> String? {
        // The exact shape of the captain-reported bug: a single long line wraps
        // from row 7 to row 8, both strictly mid-screen (terminalRows=24, so
        // neither row is the first or last visible row). The invalidation
        // region must cover row 6 (above) through row 9 (below), not just rows
        // 7-8 themselves.
        let r = region(rowStart: 7, rowEnd: 8)
        let row6 = rowRect(6)
        let row9 = rowRect(9)
        if r.maxY != row6.maxY {
            return "expected the wrap region to extend up to row 6's top edge (\(row6.maxY)), got \(r.maxY)"
        }
        if r.minY != row9.minY {
            return "expected the wrap region to extend down to row 9's bottom edge (\(row9.minY)), got \(r.minY)"
        }
        return nil
    }

    private static func test_upwardExtensionNeverPushesBelowZero() -> String? {
        // rowStart=1 (barely not at the top): the downward-extension code
        // already clamps at 0 via max(0, ...) - confirm the upward extension
        // (which only ever grows region.height, never subtracts from
        // region.origin.y) can't push the *bottom* edge negative either, for a
        // region that also reaches the very last row.
        let r = region(rowStart: 1, rowEnd: terminalRows - 1)
        if r.minY < 0 {
            return "region.minY went negative (\(r.minY))"
        }
        return nil
    }
}

#endif
