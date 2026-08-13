// Manjesh Grand Line - native macOS app.
//
// Hand-rolled natural-language date/time detection for the New/Edit Task
// sheet's Title field (cockpit-shift-create-edit, phase 2). Per the brief:
// this doesn't need full natural-language coverage, just the common cases
// the reviewed mockup demonstrated - today/tomorrow/next-week/next-<weekday>/
// a bare time-of-day, and simple combinations of a day phrase plus a time.
// No third-party dependency - the recognized vocabulary is small and fixed,
// so a small hand-rolled scanner is simpler and more predictable than parsing
// with `NSDataDetector` (which is tuned for prose, not short task titles) or
// a general NLP library.

import Foundation

struct ShiftParsedDate {
    /// The resolved date/time, if a match was found.
    let date: Date
    /// Whether a time-of-day was part of the match (false = date-only, the
    /// task's due time stays unset).
    let hasTime: Bool
    /// The substring that was recognized - shown in the inline confirmation
    /// label so the person typing can see what was detected.
    let matchedText: String
}

enum ShiftDateParser {

    private static let weekdayNames: [String: Int] = [
        // Calendar.current weekday: 1 = Sunday ... 7 = Saturday.
        "sunday": 1, "sun": 1,
        "monday": 2, "mon": 2,
        "tuesday": 3, "tue": 3, "tues": 3,
        "wednesday": 4, "wed": 4,
        "thursday": 5, "thu": 5, "thur": 5, "thurs": 5,
        "friday": 6, "fri": 6,
        "saturday": 7, "sat": 7,
    ]

    /// Scans `text` for a recognized date/time phrase. Returns `nil` if
    /// nothing in the small vocabulary above matched.
    static func parse(_ text: String, now: Date = Date()) -> ShiftParsedDate? {
        let lower = text.lowercased()
        let cal = Calendar.current

        var baseDate: Date?
        var dayMatch: String?

        // Longest/most-specific phrases first so "next week" isn't shadowed
        // by a bare "next" and "next monday" isn't shadowed by a bare
        // "monday" match later in the same string.
        if let range = lower.range(of: "next week") {
            baseDate = cal.date(byAdding: .day, value: 7, to: cal.startOfDay(for: now))
            dayMatch = String(lower[range])
        } else if let (weekday, range) = firstMatch(of: weekdayNames, prefixedBy: "next ", in: lower) {
            baseDate = nextOccurrence(of: weekday, from: now, cal: cal, allowToday: false, skipCurrentWeek: true)
            dayMatch = String(lower[range])
        } else if let range = lower.range(of: "tomorrow") {
            baseDate = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: now))
            dayMatch = String(lower[range])
        } else if let range = lower.range(of: "today") {
            baseDate = cal.startOfDay(for: now)
            dayMatch = String(lower[range])
        } else if let (weekday, range) = firstMatch(of: weekdayNames, prefixedBy: nil, in: lower) {
            baseDate = nextOccurrence(of: weekday, from: now, cal: cal, allowToday: false, skipCurrentWeek: false)
            dayMatch = String(lower[range])
        }

        let (time, timeMatch) = parseTimeOfDay(lower)

        switch (baseDate, time) {
        case (.some(let day), .some((let hour, let minute))):
            var comps = cal.dateComponents([.year, .month, .day], from: day)
            comps.hour = hour
            comps.minute = minute
            guard let combined = cal.date(from: comps) else { return nil }
            let matched = [dayMatch, timeMatch].compactMap { $0 }.joined(separator: " ")
            return ShiftParsedDate(date: combined, hasTime: true, matchedText: matched)
        case (.some(let day), .none):
            return ShiftParsedDate(date: day, hasTime: false, matchedText: dayMatch ?? "")
        case (.none, .some((let hour, let minute))):
            // A bare time with no day phrase: today if that time hasn't
            // passed yet, otherwise tomorrow - matches how a person would
            // read "3pm" typed at 10am vs at 5pm.
            var comps = cal.dateComponents([.year, .month, .day], from: now)
            comps.hour = hour
            comps.minute = minute
            guard var combined = cal.date(from: comps) else { return nil }
            if combined < now {
                combined = cal.date(byAdding: .day, value: 1, to: combined) ?? combined
            }
            return ShiftParsedDate(date: combined, hasTime: true, matchedText: timeMatch ?? "")
        case (.none, .none):
            return nil
        }
    }

    /// Finds the first weekday-name keyword in `text`, optionally requiring
    /// it be immediately preceded by `prefix` (used to implement "next
    /// <weekday>" without also matching a bare "<weekday>" via the same
    /// table). Returns the weekday number and the full matched range
    /// (including the prefix, if any).
    private static func firstMatch(
        of table: [String: Int], prefixedBy prefix: String?, in text: String
    ) -> (Int, Range<String.Index>)? {
        var best: (Int, Range<String.Index>)?
        for (name, weekday) in table {
            let needle = (prefix ?? "") + name
            guard let range = text.range(of: needle) else { continue }
            // Require a word boundary after the match so "friday" doesn't
            // match inside "fridayish" (unlikely in practice, but cheap to
            // guard). No boundary check before `prefix` itself since callers
            // pass a literal like "next " that already ends in a space.
            let afterOK = range.upperBound == text.endIndex || !text[range.upperBound].isLetter
            guard afterOK else { continue }
            if best == nil || range.lowerBound < best!.1.lowerBound {
                best = (weekday, range)
            }
        }
        return best
    }

    /// The next date matching `weekday` (1=Sunday...7=Saturday) strictly
    /// after `from`'s calendar day. `skipCurrentWeek` is unused in practice
    /// today (both "next <weekday>" and a bare "<weekday>" resolve to the
    /// nearest future occurrence) but is threaded through in case a future
    /// refinement wants "next Monday" to mean "the Monday after this
    /// upcoming one" - kept as a documented, named no-op rather than a
    /// silent behavior difference between the two call sites.
    private static func nextOccurrence(
        of weekday: Int, from now: Date, cal: Calendar, allowToday: Bool, skipCurrentWeek: Bool
    ) -> Date {
        let today = cal.startOfDay(for: now)
        let todayWeekday = cal.component(.weekday, from: today)
        var offset = (weekday - todayWeekday + 7) % 7
        if offset == 0 && !allowToday { offset = 7 }
        return cal.date(byAdding: .day, value: offset, to: today) ?? today
    }

    /// Recognizes "3pm", "3:30pm", "9am", "15:00", "noon", "midnight" -
    /// returns (hour, minute) in 24-hour form plus the matched substring.
    /// Deliberately requires an am/pm suffix or a colon (never a bare
    /// integer) so an ordinary number in a title ("Version 2 release") is
    /// never mistaken for a time.
    private static func parseTimeOfDay(_ text: String) -> ((hour: Int, minute: Int)?, String?) {
        if let range = text.range(of: "\\bnoon\\b", options: .regularExpression) {
            return ((12, 0), String(text[range]))
        }
        if let range = text.range(of: "\\bmidnight\\b", options: .regularExpression) {
            return ((0, 0), String(text[range]))
        }
        // e.g. "3pm", "3:30 pm", "11:45am"
        if let range = text.range(
            of: "\\b([0-1]?[0-9])(?::([0-5][0-9]))?\\s*(am|pm)\\b", options: .regularExpression
        ) {
            let match = String(text[range])
            if let parsed = parseAmPm(match) { return (parsed, match) }
        }
        // e.g. "15:00", "9:05" - 24-hour, colon required (bare "9" is
        // ambiguous and intentionally not matched).
        if let range = text.range(of: "\\b([0-1]?[0-9]|2[0-3]):([0-5][0-9])\\b", options: .regularExpression) {
            let match = String(text[range])
            let parts = match.split(separator: ":")
            if parts.count == 2, let h = Int(parts[0]), let m = Int(parts[1]), h < 24 {
                return ((h, m), match)
            }
        }
        return (nil, nil)
    }

    private static func parseAmPm(_ match: String) -> (Int, Int)? {
        let lower = match.lowercased()
        let isPM = lower.hasSuffix("pm")
        let digits = lower.dropLast(2).trimmingCharacters(in: .whitespaces)
        let parts = digits.split(separator: ":")
        guard let hourRaw = parts.first, var hour = Int(hourRaw), hour >= 1, hour <= 12 else { return nil }
        let minute = parts.count > 1 ? (Int(parts[1]) ?? 0) : 0
        if isPM && hour != 12 { hour += 12 }
        if !isPM && hour == 12 { hour = 0 }
        return (hour, minute)
    }
}
