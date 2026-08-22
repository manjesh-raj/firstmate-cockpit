// Manjesh Grand Line - native macOS app.
//
// GL-29: permanent coverage for `FleetDataSource` and `OpenPRsSource` - the
// pair that drives Overview and Review, and therefore the app's answer to
// "should I act right now."
//
// What is covered here is deliberately the *decision* logic, not the network:
//
//   - `mergedPRs`: how a forge-discovered PR and a task-tracked PR for the
//     same URL become one row, and which fields survive that merge. This is
//     where `taskID` comes from, and `taskID` is what makes the Merge action
//     possible at all (GL-38, fixed in Phase 2) - so a regression here breaks
//     merging without breaking anything visible.
//   - `canMerge`/`mergeArguments`: the Merge button's gate and the exact argv
//     `bin/fm-pr-merge.sh` is invoked with. GL-38 shipped for its whole life
//     with the task id missing from that argv and nothing noticed, because
//     nothing asserted the shape.
//   - `parseRemote`: every PR the app shows depends on turning the captain's
//     real `origin` URLs into `(forge, owner, repo)`.
//   - `classify`: which crew states read as "needs your call".
//   - `FetchResult.isDegraded`: GL-14's rule that a failed scan must never
//     render as an all-clear.
//
// Run: `FM_RUN_FLEET_DATA_TESTS=1 .build/debug/FirstmateCockpit`
//
// No `gh`, no `git`, no network, and no read of the captain's real `$FM_HOME`.

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

enum FleetDataSelfTest {

    static func run() -> Bool {
        var ok = true
        checkMergedPRs(&ok)
        checkMergeGate(&ok)
        checkParseRemote(&ok)
        checkClassify(&ok)
        checkDegradedFetch(&ok)
        print(ok ? "FleetDataSelfTest: all checks passed" : "FleetDataSelfTest: FAILED")
        return ok
    }

    private static func fail(_ message: String, _ ok: inout Bool) {
        print("  FAIL \(message)")
        ok = false
    }

    // MARK: mergedPRs

    private static func checkMergedPRs(_ ok: inout Bool) {
        print("\n-- mergedPRs (forge + task rows collapse to one row per PR) --")

        let forgePR = OpenPRInfo(repo: "manjesh-grand-line", number: 12, title: "Phase 3",
                                 url: "https://github.com/o/r/pull/12", forge: "github", checks: "green")
        func makeTask(pr: String?) -> FleetTask {
            var t = FleetTask(id: "grandline-review-phase3-polish", repo: "manjesh-grand-line",
                              kind: "ship", pr: pr)
            t.status = "working"
            return t
        }
        let task = makeTask(pr: "https://github.com/o/r/pull/12")

        // 1. The same PR seen from both sides is one row, tagged "work",
        //    keeping the forge's title/number/checks.
        let merged = FleetDataSource.mergedPRs(openPRs: [forgePR], tasks: [task])
        guard merged.count == 1 else {
            fail("expected one merged row, got \(merged.count)", &ok)
            return
        }
        let row = merged[0]
        if row.source != "work" { fail("source should be work, got \(row.source)", &ok) }
        if row.taskID != task.id { fail("taskID lost in the merge: \(String(describing: row.taskID))", &ok) }
        if row.title != "Phase 3" { fail("forge title lost: \(row.title)", &ok) }
        if row.checks != "green" { fail("forge checks lost: \(row.checks)", &ok) }
        if row.number != 12 { fail("forge number lost: \(String(describing: row.number))", &ok) }

        // 2. A URL that differs only by scheme/trailing slash/case is the same
        //    PR - otherwise a captain sees the same PR twice, once mergeable
        //    and once not.
        let messyTask = makeTask(pr: "HTTP://GitHub.com/o/r/pull/12/")
        let deduped = FleetDataSource.mergedPRs(openPRs: [forgePR], tasks: [messyTask])
        if deduped.count != 1 {
            fail("a scheme/slash/case variant produced \(deduped.count) rows instead of 1", &ok)
        }

        // 3. A forge PR with no task stays a plain forge row - and therefore
        //    stays unmergeable, which is a real constraint, not an oversight.
        let forgeOnly = FleetDataSource.mergedPRs(openPRs: [forgePR], tasks: [])
        if forgeOnly.first?.source != "forge" || forgeOnly.first?.taskID != nil {
            fail("a forge-only PR should have source=forge and no taskID", &ok)
        }

        // 4. A task whose PR the forge scan never returned still shows up -
        //    that is the offline/degraded case, and losing the row would hide
        //    real work.
        let taskOnly = FleetDataSource.mergedPRs(openPRs: [], tasks: [task])
        guard taskOnly.count == 1, let only = taskOnly.first else {
            fail("a task-tracked PR vanished when the forge scan returned nothing", &ok)
            return
        }
        if only.number != 12 { fail("PR number should be derivable from the URL, got \(String(describing: only.number))", &ok) }
        if only.checks != "none" { fail("unknown checks should read \"none\", got \(only.checks)", &ok) }

        // 5. A task with no PR at all contributes no row.
        if !FleetDataSource.mergedPRs(openPRs: [], tasks: [makeTask(pr: nil)]).isEmpty {
            fail("a task with no PR produced a row", &ok)
        }
        print("  OK - merge/dedup/fallback shape holds")
    }

    // MARK: The merge action (GL-38)

    private static func checkMergeGate(_ ok: inout Bool) {
        print("\n-- merge gate + argv (GL-38) --")

        func pr(checks: String, taskID: String?) -> MergedPR {
            MergedPR(source: taskID == nil ? "forge" : "work", taskID: taskID, repo: "r",
                     url: "https://github.com/o/r/pull/1", number: 1, title: "t",
                     checks: checks, forge: "github")
        }

        if !FleetDataSource.canMerge(pr(checks: "green", taskID: "t-1")) {
            fail("a green, task-tracked PR must be mergeable", &ok)
        }
        for checks in ["pending", "red", "none"] {
            if FleetDataSource.canMerge(pr(checks: checks, taskID: "t-1")) {
                fail("checks=\(checks) must not be mergeable", &ok)
            }
        }
        if FleetDataSource.canMerge(pr(checks: "green", taskID: nil)) {
            fail("a PR with no task id has no working merge path and must not offer one", &ok)
        }

        // The argv `bin/fm-pr-merge.sh` validates: `<task-id> <pr-url>`, in
        // that order. This is the assertion whose absence let GL-38 ship.
        let args = FleetDataSource.mergeArguments(taskID: "t-1", url: "https://github.com/o/r/pull/1")
        if args != ["t-1", "https://github.com/o/r/pull/1"] {
            fail("merge argv is \(args) - the script takes <task-id> <pr-url>", &ok)
        }
        print("  OK - green + task id only, argv carries the task id first")
    }

    // MARK: parseRemote

    private static func checkParseRemote(_ ok: inout Bool) {
        print("\n-- parseRemote (both real remote forms) --")
        let cases: [(String, (String, String, String)?)] = [
            ("git@github.com:manjesh-raj/manjesh-grand-line.git", ("github", "manjesh-raj", "manjesh-grand-line")),
            ("https://github.com/manjesh-raj/manjesh-grand-line.git", ("github", "manjesh-raj", "manjesh-grand-line")),
            ("https://github.com/manjesh-raj/manjesh-grand-line", ("github", "manjesh-raj", "manjesh-grand-line")),
            ("git@bitbucket.org:team/repo.git", ("bitbucket", "team", "repo")),
            ("https://user@bitbucket.org/team/repo.git", ("bitbucket", "team", "repo")),
            // Not a forge this app knows: skipped rather than guessed at.
            ("git@gitlab.com:team/repo.git", nil),
            ("", nil),
        ]
        for (raw, expected) in cases {
            let got = OpenPRsSource.parseRemote(raw)
            switch (got, expected) {
            case (nil, nil):
                continue
            case let (g?, e?) where g.forge == e.0 && g.owner == e.1 && g.repo == e.2:
                continue
            default:
                fail("parseRemote(\"\(raw)\") = \(String(describing: got)), want \(String(describing: expected))", &ok)
            }
        }
        print("  OK - ssh + https forms, unknown forges skipped")
    }

    // MARK: classify

    private static func checkClassify(_ ok: inout Bool) {
        print("\n-- classify (which states need the captain) --")
        let expected = [
            "working": "working",
            "parked": "needs_decision",
            "done": "done",
            "blocked": "blocked",
            "failed": "failed",
            "something-new": "unknown",
        ]
        for (state, want) in expected {
            let got = FleetDataSource.classify(state)
            if got != want { fail("classify(\"\(state)\") = \(got), want \(want)", &ok) }
        }
        print("  OK - unknown states stay \"unknown\" rather than defaulting to done")
    }

    // MARK: GL-14

    private static func checkDegradedFetch(_ ok: inout Bool) {
        print("\n-- FetchResult: empty is not the same as failed (GL-14) --")
        let clean = OpenPRsSource.FetchResult()
        if clean.isDegraded { fail("a clean, genuinely empty scan reported degraded", &ok) }
        if clean.failureSummary != nil { fail("a clean scan produced a failure summary", &ok) }

        let partial = OpenPRsSource.FetchResult(prs: [], failedRepos: ["treehouse"])
        if !partial.isDegraded { fail("a failed repo did not mark the scan degraded", &ok) }
        if partial.failureSummary == nil { fail("a failed repo produced no summary to show", &ok) }

        let total = OpenPRsSource.FetchResult(projectsUnreadable: true)
        if !total.isDegraded { fail("an unreadable projects directory did not mark the scan degraded", &ok) }
        if total.failureSummary == nil { fail("an unreadable projects directory produced no summary", &ok) }

        let many = OpenPRsSource.FetchResult(prs: [], failedRepos: ["a", "b", "c"])
        if many.failureSummary?.contains("3") != true {
            fail("a multi-repo failure should say how many: \(String(describing: many.failureSummary))", &ok)
        }
        print("  OK - clean / partial / total failure are three distinct states")
    }
}

#endif
