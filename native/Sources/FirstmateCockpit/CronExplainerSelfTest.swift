// Manjesh Grand Line - native macOS app.
//
// Permanent, dependency-free self-test for `CronExplainer` - same convention
// as `DiffEngineSelfTest.swift`. Run with:
//
//   swift build && FM_RUN_CRON_EXPLAINER_TESTS=1 .build/debug/FirstmateCockpit; echo $?
import Foundation

enum CronExplainerSelfTest {

    static func run() -> Bool {
        let cases: [(String, () -> String?)] = [
            ("fixedTimeHeadline", test_fixedTimeHeadline),
            ("rangeAndStepHeadline", test_rangeAndStepHeadline),
            ("rebootIsNotAnError", test_rebootIsNotAnError),
            ("shortcutsExpandCorrectly", test_shortcutsExpandCorrectly),
            ("wrongFieldCountErrors", test_wrongFieldCountErrors),
            ("outOfRangeValueErrors", test_outOfRangeValueErrors),
            ("fixedTimeNextRunsAreOncePerDay", test_fixedTimeNextRunsAreOncePerDay),
            ("rangeAndStepNextRunsMatchExpectedFirstTwo", test_rangeAndStepNextRunsMatchExpectedFirstTwo),
            ("domDowOrRule", test_domDowOrRule),
            ("randomExpressionAlwaysParses", test_randomExpressionAlwaysParses),
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
        print(failures == 0 ? "CronExplainerSelfTest: all \(cases.count) cases passed" : "CronExplainerSelfTest: \(failures)/\(cases.count) cases FAILED")
        return failures == 0
    }

    private static func utcCalendar() -> Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal
    }

    /// "5 4 * * *" - a simple fixed daily time. Verified by hand: minute=5,
    /// hour=4, everything else wildcard, so the headline should collapse to
    /// "At 04:05." and the next 5 runs should be 04:05 UTC on 5 consecutive
    /// days starting the day after `after`.
    private static func test_fixedTimeHeadline() -> String? {
        guard let cron = try? CronExplainer.parse("5 4 * * *") else { return "failed to parse" }
        let headline = CronExplainer.headline(cron)
        guard headline == "At 04:05." else { return "expected 'At 04:05.', got '\(headline)'" }
        return nil
    }

    /// "*/15 2 * * 1-5" - every 15th minute past hour 2, weekdays only.
    /// Verified by hand against the parsed structure, not just eyeballing
    /// the sentence: minute is a */15 step over the full 0-59 range, hour is
    /// a fixed 2, day-of-week is a Monday-Friday range, day-of-month/month
    /// are wildcard.
    private static func test_rangeAndStepHeadline() -> String? {
        guard let cron = try? CronExplainer.parse("*/15 2 * * 1-5") else { return "failed to parse" }
        let headline = CronExplainer.headline(cron)
        let expected = "At every 15th minute past hour 2 on every day-of-week from Monday through Friday."
        guard headline == expected else { return "expected '\(expected)', got '\(headline)'" }
        return nil
    }

    private static func test_rebootIsNotAnError() -> String? {
        guard let cron = try? CronExplainer.parse("@reboot") else { return "failed to parse @reboot" }
        guard cron.isReboot else { return "expected isReboot true" }
        let headline = CronExplainer.headline(cron)
        guard headline == "Runs at startup, not on a schedule." else { return "unexpected headline: \(headline)" }
        let runs = CronExplainer.nextRuns(cron, after: Date(), count: 5)
        guard runs.isEmpty else { return "expected no next runs for @reboot, got \(runs)" }
        return nil
    }

    private static func test_shortcutsExpandCorrectly() -> String? {
        guard let daily = try? CronExplainer.parse("@daily") else { return "failed to parse @daily" }
        guard daily.minute.allowed == [0], daily.hour.allowed == [0] else { return "expected @daily to be 0 0 * * *" }
        guard let hourly = try? CronExplainer.parse("@hourly") else { return "failed to parse @hourly" }
        guard hourly.minute.allowed == [0], hourly.hour.isWildcard else { return "expected @hourly to be 0 * * * *" }
        return nil
    }

    private static func test_wrongFieldCountErrors() -> String? {
        do {
            _ = try CronExplainer.parse("1 2 3")
            return "expected an error for a 3-field expression"
        } catch CronParseError.wrongFieldCount(3) {
            return nil
        } catch {
            return "expected wrongFieldCount(3), got \(error)"
        }
    }

    private static func test_outOfRangeValueErrors() -> String? {
        do {
            _ = try CronExplainer.parse("99 4 * * *")
            return "expected an error for minute 99"
        } catch CronParseError.outOfRange("minute", "99") {
            return nil
        } catch {
            return "expected outOfRange(minute, 99), got \(error)"
        }
    }

    /// Fixed input: "5 4 * * *" with `after` = 2026-01-01 00:00:00 UTC.
    /// Expected: 2026-01-01 04:05, 2026-01-02 04:05, ... 5 consecutive days,
    /// each exactly 24h apart - checked by hand against the calendar.
    private static func test_fixedTimeNextRunsAreOncePerDay() -> String? {
        guard let cron = try? CronExplainer.parse("5 4 * * *") else { return "failed to parse" }
        let cal = utcCalendar()
        guard let after = cal.date(from: DateComponents(year: 2026, month: 1, day: 1, hour: 0, minute: 0)) else { return "bad fixture date" }
        let runs = CronExplainer.nextRuns(cron, after: after, count: 5, calendar: cal)
        guard runs.count == 5 else { return "expected 5 runs, got \(runs.count)" }
        for (i, run) in runs.enumerated() {
            let c = cal.dateComponents([.year, .month, .day, .hour, .minute], from: run)
            guard c.hour == 4, c.minute == 5, c.day == 1 + i, c.month == 1, c.year == 2026 else {
                return "run \(i) was \(run), expected 2026-01-\(String(format: "%02d", 1 + i)) 04:05 UTC"
            }
        }
        return nil
    }

    /// Fixed input: "*/15 2 * * 1-5" with `after` = 2026-01-01 00:00:00 UTC
    /// (2026-01-01 is a Thursday). Expected first two runs: 2026-01-01 02:00
    /// (Thursday, within range) and 2026-01-01 02:15 - checked by hand.
    private static func test_rangeAndStepNextRunsMatchExpectedFirstTwo() -> String? {
        guard let cron = try? CronExplainer.parse("*/15 2 * * 1-5") else { return "failed to parse" }
        let cal = utcCalendar()
        guard let after = cal.date(from: DateComponents(year: 2026, month: 1, day: 1, hour: 0, minute: 0)) else { return "bad fixture date" }
        let runs = CronExplainer.nextRuns(cron, after: after, count: 2, calendar: cal)
        guard runs.count == 2 else { return "expected 2 runs, got \(runs.count)" }
        let first = cal.dateComponents([.year, .month, .day, .hour, .minute, .weekday], from: runs[0])
        guard first.year == 2026, first.month == 1, first.day == 1, first.hour == 2, first.minute == 0, first.weekday == 5 /* Thursday */ else {
            return "expected first run 2026-01-01 02:00 (Thursday), got \(runs[0]) (\(first))"
        }
        let second = cal.dateComponents([.year, .month, .day, .hour, .minute], from: runs[1])
        guard second.day == 1, second.hour == 2, second.minute == 15 else {
            return "expected second run 2026-01-01 02:15, got \(runs[1])"
        }
        return nil
    }

    /// "0 0 1,15 * 1" - runs at midnight on the 1st/15th of the month OR any
    /// Monday, since both day-of-month and day-of-week are restricted.
    /// Verified by hand: 2026-01-01 is a Thursday (not the 1st/15th match via
    /// dow), so the first three matches should be Jan 1 (dom), Jan 5 (Monday,
    /// dow), Jan 12 (Monday, dow) - Jan 15 also matches but comes after.
    private static func test_domDowOrRule() -> String? {
        guard let cron = try? CronExplainer.parse("0 0 1,15 * 1") else { return "failed to parse" }
        let cal = utcCalendar()
        guard let after = cal.date(from: DateComponents(year: 2025, month: 12, day: 31, hour: 0, minute: 0)) else { return "bad fixture date" }
        let runs = CronExplainer.nextRuns(cron, after: after, count: 3, calendar: cal)
        guard runs.count == 3 else { return "expected 3 runs, got \(runs.count)" }
        let days = runs.map { cal.component(.day, from: $0) }
        guard days == [1, 5, 12] else { return "expected days [1, 5, 12], got \(days)" }
        return nil
    }

    private static func test_randomExpressionAlwaysParses() -> String? {
        for _ in 0..<50 {
            let expr = CronExplainer.randomExpression()
            guard (try? CronExplainer.parse(expr)) != nil else { return "randomExpression produced unparseable '\(expr)'" }
        }
        return nil
    }
}
