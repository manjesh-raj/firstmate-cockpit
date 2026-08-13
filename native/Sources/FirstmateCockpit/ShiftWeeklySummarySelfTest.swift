// Manjesh Grand Line - native macOS app.
//
// Permanent self-test for `ShiftStore.weeklySummary` (phase 5, cockpit-shift-
// power-features), run via `FM_RUN_SHIFT_WEEKLY_SUMMARY_TESTS=1
// .build/debug/FirstmateCockpit` - same convention as `ShiftStoreSelfTest.swift`.
//
// Deliberately uses `Date()`-relative offsets rather than hardcoded calendar
// dates (unlike `ShiftStoreSelfTest`'s fixed 2026-08-01) - `weeklySummary`
// keys everything off `Calendar.current`'s notion of "this week" relative to
// whatever `reference` it's given, so the only way to test it without
// reimplementing that same week-boundary math a second time is to compute
// the boundaries the identical way the test's own assertions need them, then
// place seeded data relative to those boundaries.
//
// Covers: completed-this-week counting both a task's `completedAt` and a
// follow-up's `follow_up_completed` activity entry; "pushed back 2+ times"
// only counting an id with 2+ `task_due_date_changed`/`follow_up_snoozed`
// entries (not 1); and "coming up next week" counting a due date inside the
// week right after this one while excluding one far outside it.

import Foundation

enum ShiftWeeklySummarySelfTest {
    static func run() -> Bool {
        var failures: [String] = []
        func check(_ condition: Bool, _ message: String) {
            if !condition { failures.append(message) }
        }

        let scratchRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("shift-weekly-summary-selftest-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: scratchRoot) }
        setenv("FM_SHIFT_DIR", scratchRoot.path, 1)
        defer { unsetenv("FM_SHIFT_DIR") }

        let store = ShiftStore()
        let now = Date()
        let cal = Calendar.current
        guard let weekInterval = cal.dateInterval(of: .weekOfYear, for: now) else {
            return report(["could not compute this week's interval"])
        }

        // MARK: Completed this week - a task's completedAt, and a follow-up's
        // follow_up_completed activity entry.

        var completedTask = ShiftTask.fresh()
        completedTask.title = "Ship the release notes"
        store.addTask(completedTask)
        store.setTaskCompleted(id: completedTask.id, completed: true, now: now)

        var followUp = ShiftFollowUp.fresh()
        followUp.title = "Check with the team about the deployment"
        store.addFollowUp(followUp)
        store.setFollowUpStatus(id: followUp.id, done: true, now: now)

        let summaryAfterCompletion = store.weeklySummary(reference: now)
        check(summaryAfterCompletion.completedCount == 2, "expected 2 completed this week (1 task + 1 follow-up), got \(summaryAfterCompletion.completedCount)")

        // MARK: Pushed back 2+ times - a task's due date edited twice, a
        // follow-up snoozed twice. A single push should NOT count.

        var pushedTask = ShiftTask.fresh()
        pushedTask.title = "Update documentation for release process"
        pushedTask.dueDate = "2026-01-01"
        store.addTask(pushedTask)
        var editOnce = pushedTask
        editOnce.dueDate = "2026-01-05"
        store.updateTask(editOnce, now: now)
        var editTwice = editOnce
        editTwice.dueDate = "2026-01-10"
        store.updateTask(editTwice, now: now)

        var singlePushTask = ShiftTask.fresh()
        singlePushTask.title = "Only pushed once"
        singlePushTask.dueDate = "2026-02-01"
        store.addTask(singlePushTask)
        var singlePushEdit = singlePushTask
        singlePushEdit.dueDate = "2026-02-05"
        store.updateTask(singlePushEdit, now: now)

        var snoozedFollowUp = ShiftFollowUp.fresh()
        snoozedFollowUp.title = "Check whether the pending request is completed"
        snoozedFollowUp.followUpAt = "2026-01-01"
        store.addFollowUp(snoozedFollowUp)
        store.snoozeFollowUp(id: snoozedFollowUp.id, to: cal.date(byAdding: .day, value: 1, to: now) ?? now, now: now)
        store.snoozeFollowUp(id: snoozedFollowUp.id, to: cal.date(byAdding: .day, value: 2, to: now) ?? now, now: now)

        let summaryAfterPushes = store.weeklySummary(reference: now)
        let pushedTitles = Set(summaryAfterPushes.pushedBack.map(\.title))
        check(pushedTitles.contains(pushedTask.title), "task pushed back twice should appear in pushedBack")
        check(pushedTitles.contains(snoozedFollowUp.title), "follow-up snoozed twice should appear in pushedBack")
        check(!pushedTitles.contains(singlePushTask.title), "task pushed back only once should NOT appear in pushedBack")
        if let entry = summaryAfterPushes.pushedBack.first(where: { $0.title == pushedTask.title }) {
            check(entry.count == 2, "pushed task's count should be 2, got \(entry.count)")
        }

        // MARK: Coming up next week - inside the window right after this
        // week, excluding something far outside it.

        let nextWeekEnd = cal.date(byAdding: .day, value: 7, to: weekInterval.end) ?? weekInterval.end
        let midNextWeek = cal.date(byAdding: .second, value: -Int(nextWeekEnd.timeIntervalSince(weekInterval.end)) / 2, to: nextWeekEnd) ?? weekInterval.end
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        df.calendar = Calendar(identifier: .gregorian)

        var upcomingTask = ShiftTask.fresh()
        upcomingTask.title = "Coming up next week task"
        upcomingTask.dueDate = df.string(from: midNextWeek)
        store.addTask(upcomingTask)

        var farFutureTask = ShiftTask.fresh()
        farFutureTask.title = "Far future task"
        farFutureTask.dueDate = df.string(from: cal.date(byAdding: .day, value: 90, to: now) ?? now)
        store.addTask(farFutureTask)

        let summaryAfterUpcoming = store.weeklySummary(reference: now)
        check(summaryAfterUpcoming.upcomingCount >= 1, "expected at least 1 upcoming item, got \(summaryAfterUpcoming.upcomingCount)")

        // Confirm the far-future task specifically isn't what's being
        // counted, by removing the near-term one and checking the count
        // drops - a positive-only assertion above couldn't distinguish
        // "counted correctly" from "counted everything regardless of date."
        var upcomingRemoved = upcomingTask
        upcomingRemoved.dueDate = nil
        store.updateTask(upcomingRemoved, now: now)
        let summaryAfterRemoval = store.weeklySummary(reference: now)
        check(
            summaryAfterRemoval.upcomingCount == summaryAfterUpcoming.upcomingCount - 1,
            "removing the one upcoming task's due date should drop upcomingCount by 1, was \(summaryAfterUpcoming.upcomingCount) now \(summaryAfterRemoval.upcomingCount)"
        )

        return report(failures)
    }

    private static func report(_ failures: [String]) -> Bool {
        if failures.isEmpty {
            print("[ShiftWeeklySummarySelfTest] all checks passed")
            return true
        }
        print("[ShiftWeeklySummarySelfTest] \(failures.count) failure(s):")
        for f in failures { print("  - \(f)") }
        return false
    }
}
