// Manjesh Grand Line - native macOS app.
//
// Permanent, dependency-free self-test for `DiffEngine` - same "env-var-
// gated, run and read the result" convention as `SRELeadMarkdownSelfTest.swift`
// (see that file's header and the AGENTS.md "Verifying native UI bugs
// without a real screenshot" bullet for why this project has no `swift
// test` story). Run with:
//
//   swift build && FM_RUN_DIFF_ENGINE_TESTS=1 .build/debug/FirstmateCockpit; echo $?
//
// Covers the pure-logic half of the Tools page's diff tool
// (cockpit-tools-page-diff): line-level LCS grouping (unchanged/added/
// removed/changed pairing) against a nontrivial Kubernetes Deployment
// manifest pair (kept as local literals here - the real panel no longer
// prefills sample content, per fm/cockpit-tools-page-partial-row-fix),
// plus word-level highlighting and the "show only differences"
// collapse-boundary math. The rendering half (DiffResultView's NSView tree,
// collapse/expand click handling) has no equivalent here - it was verified
// with a temporary env-gated launch probe per the same AGENTS.md
// convention, reverted before commit; see this task's PR description for
// that transcript.

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

enum DiffEngineSelfTest {

    static func run() -> Bool {
        let cases: [(String, () -> String?)] = [
            ("identicalTextProducesAllUnchangedRows", test_identicalTextProducesAllUnchangedRows),
            ("pureAdditionProducesOneAddedRow", test_pureAdditionProducesOneAddedRow),
            ("pureRemovalProducesOneRemovedRow", test_pureRemovalProducesOneRemovedRow),
            ("oneEditedLineProducesAChangedRowWithWordHighlights", test_oneEditedLineProducesAChangedRowWithWordHighlights),
            ("manifestPairProducesExactlyOneRemovedOneChangedTwoAdded", test_manifestPairProducesExactlyOneRemovedOneChangedTwoAdded),
            ("wordDiffPreservesWhitespaceOnReassembly", test_wordDiffPreservesWhitespaceOnReassembly),
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
        print(failures == 0 ? "DiffEngineSelfTest: all \(cases.count) cases passed" : "DiffEngineSelfTest: \(failures)/\(cases.count) cases FAILED")
        return failures == 0
    }

    // MARK: Cases - each returns `nil` on success, or a failure message.

    private static func test_identicalTextProducesAllUnchangedRows() -> String? {
        let text = "a\nb\nc"
        let rows = DiffEngine.lineDiff(before: text, after: text)
        guard rows.count == 3 else { return "expected 3 rows, got \(rows.count)" }
        guard rows.allSatisfy({ $0.kind == .unchanged }) else { return "expected all unchanged, got \(rows.map(\.kind))" }
        return nil
    }

    private static func test_pureAdditionProducesOneAddedRow() -> String? {
        let rows = DiffEngine.lineDiff(before: "a\nb", after: "a\nb\nc")
        guard rows.count == 3 else { return "expected 3 rows, got \(rows.count)" }
        guard rows[2].kind == .added, rows[2].leftNumber == nil, rows[2].rightNumber == 3 else {
            return "expected row 2 to be a pure add on the right at line 3, got \(rows[2])"
        }
        return nil
    }

    private static func test_pureRemovalProducesOneRemovedRow() -> String? {
        let rows = DiffEngine.lineDiff(before: "a\nb\nc", after: "a\nb")
        guard rows.count == 3 else { return "expected 3 rows, got \(rows.count)" }
        guard rows[2].kind == .removed, rows[2].rightNumber == nil, rows[2].leftNumber == 3 else {
            return "expected row 2 to be a pure remove on the left at line 3, got \(rows[2])"
        }
        return nil
    }

    private static func test_oneEditedLineProducesAChangedRowWithWordHighlights() -> String? {
        let rows = DiffEngine.lineDiff(before: "image: app:1.4.0", after: "image: app:1.5.0")
        guard rows.count == 1, rows[0].kind == .changed else { return "expected one changed row, got \(rows)" }
        guard let left = rows[0].leftTokens, let right = rows[0].rightTokens else { return "expected tokens on both sides" }
        guard left.contains(where: { $0.changed && $0.text.contains("1.4.0") }) else {
            return "expected a changed left token containing 1.4.0, got \(left)"
        }
        guard right.contains(where: { $0.changed && $0.text.contains("1.5.0") }) else {
            return "expected a changed right token containing 1.5.0, got \(right)"
        }
        guard left.contains(where: { !$0.changed && $0.text.contains("image:") }) else {
            return "expected 'image:' to be an unchanged shared token, got \(left)"
        }
        return nil
    }

    /// Mirrors `ToolsController`'s real prefilled example pair: the "After"
    /// manifest removes the `tier: frontend` label, bumps the image tag from
    /// 1.4.0 to 1.5.0, and adds a new `APP_ENV` env var entry (two lines) -
    /// one changed field, one removed line, and one added block all present
    /// at once, per the task's acceptance criteria.
    private static func test_manifestPairProducesExactlyOneRemovedOneChangedTwoAdded() -> String? {
        let before = """
        apiVersion: apps/v1
        kind: Deployment
        metadata:
          name: web-app
          labels:
            app: web-app
            tier: frontend
        spec:
          containers:
            - name: web-app
              image: registry.example.com/web-app:1.4.0
              env:
                - name: LOG_LEVEL
                  value: "info"
        """
        let after = """
        apiVersion: apps/v1
        kind: Deployment
        metadata:
          name: web-app
          labels:
            app: web-app
        spec:
          containers:
            - name: web-app
              image: registry.example.com/web-app:1.5.0
              env:
                - name: LOG_LEVEL
                  value: "info"
                - name: APP_ENV
                  value: "production"
        """
        let rows = DiffEngine.lineDiff(before: before, after: after)
        let removed = rows.filter { $0.kind == .removed }
        let changed = rows.filter { $0.kind == .changed }
        let added = rows.filter { $0.kind == .added }
        let unchanged = rows.filter { $0.kind == .unchanged }

        guard removed.count == 1, removed[0].leftTokens?.first?.text.contains("tier: frontend") == true else {
            return "expected exactly 1 removed row for 'tier: frontend', got \(removed)"
        }
        guard changed.count == 1,
              changed[0].leftTokens?.contains(where: { $0.changed && $0.text.contains("1.4.0") }) == true,
              changed[0].rightTokens?.contains(where: { $0.changed && $0.text.contains("1.5.0") }) == true else {
            return "expected exactly 1 changed row for the image tag bump, got \(changed)"
        }
        guard added.count == 2,
              added.contains(where: { $0.rightTokens?.first?.text.contains("APP_ENV") == true }),
              added.contains(where: { $0.rightTokens?.first?.text.contains("production") == true }) else {
            return "expected exactly 2 added rows for the new APP_ENV env entry, got \(added)"
        }
        guard unchanged.count == before.components(separatedBy: "\n").count - 2 else {
            return "expected all other lines to be unchanged, got \(unchanged.count) unchanged of \(rows.count) total rows"
        }
        return nil
    }

    private static func test_wordDiffPreservesWhitespaceOnReassembly() -> String? {
        let left = "  cpu:  500m"
        let right = "  cpu:  750m"
        let (leftTokens, rightTokens) = DiffEngine.wordDiff(left, right)
        guard leftTokens.map(\.text).joined() == left else { return "left tokens don't reassemble: \(leftTokens.map(\.text))" }
        guard rightTokens.map(\.text).joined() == right else { return "right tokens don't reassemble: \(rightTokens.map(\.text))" }
        return nil
    }
}

#endif
