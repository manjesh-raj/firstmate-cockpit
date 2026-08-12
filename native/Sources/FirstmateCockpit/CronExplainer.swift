// Manjesh Grand Line - native macOS app.
//
// Tools page (cockpit-tools-page-specialist, phase 3 of 3), cron next-run
// explainer. Pure Foundation logic, no AppKit import, so it can be exercised
// by a permanent self-test the same way `DiffEngine.swift` is - see
// `CronExplainerSelfTest.swift`.
//
// Hand-rolled field parsing and next-run search, per the task brief: this is
// a small, well-understood problem (five integer-set fields plus the classic
// day-of-month/day-of-week OR rule) and doesn't need a dependency.

import Foundation

enum CronParseError: Error, Equatable {
    case wrongFieldCount(Int)
    case invalidField(String, String) // (field name, raw token)
    case outOfRange(String, String)   // (field name, raw token)
}

/// One comma-separated field's parsed items, kept structured (not just an
/// expanded `Set<Int>`) so the plain-English headline can describe *how* a
/// field was written ("every 15th minute") rather than just what it expands
/// to.
enum CronItem: Equatable {
    case star
    case value(Int)
    case range(Int, Int)
    case step(Int, Int, Int) // start, end, interval - covers */N, A-B/N, and N/S
}

struct CronField: Equatable {
    let items: [CronItem]
    let allowed: Set<Int>

    var isWildcard: Bool { items == [.star] }
}

struct ParsedCron: Equatable {
    let minute: CronField
    let hour: CronField
    let dayOfMonth: CronField
    let month: CronField
    let dayOfWeek: CronField
    let isReboot: Bool

    static let reboot = ParsedCron(
        minute: CronField(items: [], allowed: []), hour: CronField(items: [], allowed: []),
        dayOfMonth: CronField(items: [], allowed: []), month: CronField(items: [], allowed: []),
        dayOfWeek: CronField(items: [], allowed: []), isReboot: true
    )
}

enum CronExplainer {

    private static let shortcuts: [String: String] = [
        "@yearly": "0 0 1 1 *",
        "@annually": "0 0 1 1 *",
        "@monthly": "0 0 1 * *",
        "@weekly": "0 0 * * 0",
        "@daily": "0 0 * * *",
        "@midnight": "0 0 * * *",
        "@hourly": "0 * * * *",
    ]

    private static let monthNames = ["", "January", "February", "March", "April", "May", "June",
                                      "July", "August", "September", "October", "November", "December"]
    private static let dayNames = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]

    // MARK: Parse

    static func parse(_ expression: String) throws -> ParsedCron {
        let trimmed = expression.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == "@reboot" { return .reboot }
        let expanded = shortcuts[trimmed] ?? trimmed
        let fields = expanded.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard fields.count == 5 else { throw CronParseError.wrongFieldCount(fields.count) }

        let minute = try parseField(fields[0], name: "minute", min: 0, max: 59)
        let hour = try parseField(fields[1], name: "hour", min: 0, max: 23)
        let dayOfMonth = try parseField(fields[2], name: "day-of-month", min: 1, max: 31)
        let month = try parseField(fields[3], name: "month", min: 1, max: 12)
        let dayOfWeek = try parseDayOfWeekField(fields[4])

        return ParsedCron(minute: minute, hour: hour, dayOfMonth: dayOfMonth, month: month, dayOfWeek: dayOfWeek, isReboot: false)
    }

    private static func parseField(_ raw: String, name: String, min: Int, max: Int) throws -> CronField {
        var items: [CronItem] = []
        var allowed: Set<Int> = []
        for token in raw.split(separator: ",", omittingEmptySubsequences: true) {
            let (item, values) = try parseToken(String(token), name: name, min: min, max: max)
            items.append(item)
            allowed.formUnion(values)
        }
        guard !items.isEmpty else { throw CronParseError.invalidField(name, raw) }
        return CronField(items: items, allowed: allowed)
    }

    /// Day-of-week gets its own pass so `7` (a common alias for Sunday, alongside
    /// `0`) is normalized into the field's `allowed` set without also polluting
    /// `month`/`dayOfMonth` parsing with a special case they don't need.
    private static func parseDayOfWeekField(_ raw: String) throws -> CronField {
        let field = try parseField(raw, name: "day-of-week", min: 0, max: 7)
        let allowed = Set(field.allowed.map { $0 == 7 ? 0 : $0 })
        return CronField(items: field.items, allowed: allowed)
    }

    private static func parseToken(_ token: String, name: String, min: Int, max: Int) throws -> (CronItem, Set<Int>) {
        guard !token.isEmpty else { throw CronParseError.invalidField(name, token) }

        func checkRange(_ v: Int) throws -> Int {
            guard v >= min, v <= max else { throw CronParseError.outOfRange(name, token) }
            return v
        }
        func expand(_ start: Int, _ end: Int, _ interval: Int = 1) throws -> Set<Int> {
            guard start <= end, interval > 0 else { throw CronParseError.invalidField(name, token) }
            return Set(stride(from: start, through: end, by: interval))
        }

        if token == "*" {
            return (.star, try expand(min, max))
        }

        if let slashIndex = token.firstIndex(of: "/") {
            let base = String(token[token.startIndex..<slashIndex])
            let stepRaw = String(token[token.index(after: slashIndex)...])
            guard let interval = Int(stepRaw), interval > 0 else { throw CronParseError.invalidField(name, token) }
            if base == "*" {
                return (.step(min, max, interval), try expand(min, max, interval))
            }
            if base.contains("-") {
                let parts = base.split(separator: "-")
                guard parts.count == 2, let a = Int(parts[0]), let b = Int(parts[1]) else {
                    throw CronParseError.invalidField(name, token)
                }
                let start = try checkRange(a), end = try checkRange(b)
                return (.step(start, end, interval), try expand(start, end, interval))
            }
            guard let start = Int(base) else { throw CronParseError.invalidField(name, token) }
            let checkedStart = try checkRange(start)
            return (.step(checkedStart, max, interval), try expand(checkedStart, max, interval))
        }

        if token.contains("-") {
            let parts = token.split(separator: "-")
            guard parts.count == 2, let a = Int(parts[0]), let b = Int(parts[1]) else {
                throw CronParseError.invalidField(name, token)
            }
            let start = try checkRange(a), end = try checkRange(b)
            return (.range(start, end), try expand(start, end))
        }

        guard let v = Int(token) else { throw CronParseError.invalidField(name, token) }
        let checked = try checkRange(v)
        return (.value(checked), [checked])
    }

    // MARK: Next-run search

    /// The standard cron day-of-month/day-of-week rule: if *both* fields are
    /// restricted (not `*`), a day matches when EITHER matches (an OR, not an
    /// AND) - if only one is restricted, only that one has to match.
    private static func domDowMatches(_ cron: ParsedCron, day: Int, dow: Int) -> Bool {
        let domWild = cron.dayOfMonth.isWildcard
        let dowWild = cron.dayOfWeek.isWildcard
        if domWild && dowWild { return true }
        if domWild { return cron.dayOfWeek.allowed.contains(dow) }
        if dowWild { return cron.dayOfMonth.allowed.contains(day) }
        return cron.dayOfMonth.allowed.contains(day) || cron.dayOfWeek.allowed.contains(dow)
    }

    /// Brute-forces forward day by day (cheap - a few thousand iterations even
    /// for an 8-year cap), only descending into the (small, bounded) hour/minute
    /// sets on a day that already matches month + day-of-month/day-of-week.
    static func nextRuns(_ cron: ParsedCron, after: Date, count: Int, calendar: Calendar = .current) -> [Date] {
        guard !cron.isReboot, count > 0 else { return [] }
        let sortedMinutes = cron.minute.allowed.sorted()
        let sortedHours = cron.hour.allowed.sorted()
        guard !sortedMinutes.isEmpty, !sortedHours.isEmpty else { return [] }

        var cal = calendar
        cal.timeZone = calendar.timeZone

        guard let floor = cal.date(from: cal.dateComponents([.year, .month, .day, .hour, .minute], from: after)) else { return [] }
        let searchStart = cal.date(byAdding: .minute, value: 1, to: floor) ?? floor
        let searchStartComponents = cal.dateComponents([.year, .month, .day, .hour, .minute], from: searchStart)
        let startHour = searchStartComponents.hour ?? 0
        let startMinute = searchStartComponents.minute ?? 0

        guard var dayCursor = cal.date(from: cal.dateComponents([.year, .month, .day], from: searchStart)) else { return [] }
        let maxDays = 366 * 8
        var daysChecked = 0
        var results: [Date] = []

        while results.count < count && daysChecked < maxDays {
            let comps = cal.dateComponents([.year, .month, .day, .weekday], from: dayCursor)
            if let month = comps.month, let day = comps.day, let weekday = comps.weekday {
                let dow = weekday - 1 // Calendar's 1=Sunday...7=Saturday -> cron's 0=Sunday...6=Saturday
                let isStartDay = daysChecked == 0
                if cron.month.allowed.contains(month), domDowMatches(cron, day: day, dow: dow) {
                    for hour in sortedHours {
                        if isStartDay, hour < startHour { continue }
                        for minute in sortedMinutes {
                            if isStartDay, hour == startHour, minute < startMinute { continue }
                            var c = cal.dateComponents([.year, .month, .day], from: dayCursor)
                            c.hour = hour
                            c.minute = minute
                            c.second = 0
                            guard let candidate = cal.date(from: c), candidate >= searchStart else { continue }
                            results.append(candidate)
                            if results.count == count { break }
                        }
                        if results.count == count { break }
                    }
                }
            }
            guard let next = cal.date(byAdding: .day, value: 1, to: dayCursor) else { break }
            dayCursor = next
            daysChecked += 1
        }
        return results
    }

    // MARK: Plain-English headline

    static func headline(_ cron: ParsedCron) -> String {
        if cron.isReboot { return "Runs at startup, not on a schedule." }

        if case .value(let minute) = cron.minute.items.first, cron.minute.items.count == 1,
           case .value(let hour) = cron.hour.items.first, cron.hour.items.count == 1,
           cron.dayOfMonth.isWildcard, cron.month.isWildcard, cron.dayOfWeek.isWildcard {
            return String(format: "At %02d:%02d.", hour, minute)
        }

        var sentence = "At " + minuteClause(cron.minute)
        if !cron.hour.isWildcard { sentence += " " + hourClause(cron.hour) }
        if !cron.dayOfMonth.isWildcard { sentence += " " + dayOfMonthClause(cron.dayOfMonth) }
        if !cron.month.isWildcard { sentence += " " + monthClause(cron.month) }
        if !cron.dayOfWeek.isWildcard { sentence += " " + dayOfWeekClause(cron.dayOfWeek) }
        return sentence + "."
    }

    private static func ordinal(_ n: Int) -> String {
        let suffix: String
        switch (n % 100, n % 10) {
        case (11, _), (12, _), (13, _): suffix = "th"
        case (_, 1): suffix = "st"
        case (_, 2): suffix = "nd"
        case (_, 3): suffix = "rd"
        default: suffix = "th"
        }
        return "\(n)\(suffix)"
    }

    private static func joinList(_ values: [Int]) -> String {
        values.sorted().map(String.init).joined(separator: ", ")
    }

    private static func minuteClause(_ field: CronField) -> String {
        switch field.items.count == 1 ? field.items[0] : nil {
        case .star: return "every minute"
        case .value(let v): return "minute \(v)"
        case .range(let a, let b): return "every minute from \(a) through \(b)"
        case .step(let start, let end, let interval):
            if start == 0 && end == 59 { return "every \(ordinal(interval)) minute" }
            return "every \(ordinal(interval)) minute from \(start) through \(end)"
        case .none: return "minutes \(joinList(Array(field.allowed)))"
        }
    }

    private static func hourClause(_ field: CronField) -> String {
        switch field.items.count == 1 ? field.items[0] : nil {
        case .value(let v): return "past hour \(v)"
        case .range(let a, let b): return "past every hour from \(a) through \(b)"
        case .step(let start, let end, let interval):
            if start == 0 && end == 23 { return "past every \(ordinal(interval)) hour" }
            return "past every \(ordinal(interval)) hour from \(start) through \(end)"
        case .star, .none: return "past hours \(joinList(Array(field.allowed)))"
        }
    }

    private static func dayOfMonthClause(_ field: CronField) -> String {
        switch field.items.count == 1 ? field.items[0] : nil {
        case .value(let v): return "on day-of-month \(v)"
        case .range(let a, let b): return "on every day-of-month from \(a) through \(b)"
        case .step(let start, let end, let interval): return "on every \(ordinal(interval)) day-of-month from \(start) through \(end)"
        case .star, .none: return "on days-of-month \(joinList(Array(field.allowed)))"
        }
    }

    private static func monthClause(_ field: CronField) -> String {
        func name(_ v: Int) -> String { monthNames[v] }
        switch field.items.count == 1 ? field.items[0] : nil {
        case .value(let v): return "in \(name(v))"
        case .range(let a, let b): return "in every month from \(name(a)) through \(name(b))"
        case .step(let start, let end, let interval): return "in every \(ordinal(interval)) month from \(name(start)) through \(name(end))"
        case .star, .none: return "in \(field.allowed.sorted().map(name).joined(separator: ", "))"
        }
    }

    private static func dayOfWeekClause(_ field: CronField) -> String {
        func name(_ v: Int) -> String { dayNames[v] }
        switch field.items.count == 1 ? field.items[0] : nil {
        case .value(let v): return "on \(name(v))"
        case .range(let a, let b): return "on every day-of-week from \(name(a)) through \(name(b))"
        case .step(let start, let end, let interval): return "on every \(ordinal(interval)) day-of-week from \(name(start)) through \(name(end))"
        case .star, .none: return "on \(field.allowed.sorted().map(name).joined(separator: ", "))"
        }
    }

    // MARK: Random

    /// Generates a random, always-valid 5-field expression from a handful of
    /// realistic shapes - not exhaustive, just varied enough that clicking
    /// Random repeatedly explores different clause combinations.
    static func randomExpression() -> String {
        let generators: [() -> String] = [
            { "\(Int.random(in: 0...59)) \(Int.random(in: 0...23)) * * *" },
            { "*/\([5, 10, 15, 20, 30].randomElement()!) * * * *" },
            { "0 */\([2, 3, 4, 6, 12].randomElement()!) * * *" },
            { "\(Int.random(in: 0...59)) \(Int.random(in: 0...23)) * * \(Int.random(in: 0...6))" },
            { "0 \(Int.random(in: 0...23)) \(Int.random(in: 1...28)) * *" },
            { "\(Int.random(in: 0...59)) \(Int.random(in: 0...23)) * * 1-5" },
            { "@daily" },
            { "@hourly" },
        ]
        return generators.randomElement()!()
    }
}
