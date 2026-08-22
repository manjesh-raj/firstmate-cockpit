// Manjesh Grand Line - native macOS app.
//
// Data side of the "Claude usage" toolbar popover for Herdr-backed console
// tabs (`fm/grandline-herdr-utilization-panel`, following the captain-
// approved design plan built from `data/grandline-herdr-utilization-panel-
// research/report.md`). Follows this app's established "thin native window
// onto another CLI tool" pattern (see `VaultData.swift`'s own header): every
// read goes through the real `quota-axi` CLI via `Process`, never a
// reimplementation of its quota math, and every field is parsed tolerantly
// (skip, don't crash, on anything missing/malformed) exactly like
// `VaultSource.parseDoctorTools` already does.
//
// Scope, per the captain's explicit review: Claude only. No multi-provider
// picker - `quota-axi --json --provider claude` already narrows the
// `providers` array to the one entry this feature cares about.
//
// This file writes its own small `run`/`resolveExecutable`/`RunResult` trio
// rather than reusing `VaultData.swift`'s (private) copies or refactoring the
// five existing near-duplicates in this codebase - consolidating them was
// explicitly out of scope for this task, and every other integration in this
// app (Vault, Updates, Dotfiles, NotSynced, Fleet) already writes its own.

import Foundation

/// One usage window from `quota-axi`'s `windows[]` array - only the fields
/// this popover shows (the real JSON key is `percentRemaining`; `percentUsed`
/// here is `100 - percentRemaining`, converted once at the parse boundary -
/// see `QuotaSource.parse`'s comment - since the popover's own UI is written
/// in terms of "used", plus `resetsAt`, `pace.status`). Anything else in the
/// raw JSON (per-model windows like `"id": "model:fable"`, credits like
/// `"id": "extra_usage"`) is ignored by `parse`'s `switch id` falling
/// through its `default: continue`.
struct QuotaWindow: Equatable {
    enum Kind: Equatable {
        case session
        case weekly
    }

    enum PaceStatus: Equatable {
        case onPace
        case behind
        case ahead
        case unknown

        init(rawValue: String?) {
            switch rawValue {
            case "on_pace": self = .onPace
            case "behind": self = .behind
            case "ahead": self = .ahead
            default: self = .unknown
            }
        }

        var label: String {
            switch self {
            case .onPace: return "On pace"
            case .behind: return "Behind"
            case .ahead: return "Ahead"
            case .unknown: return "Unknown"
            }
        }
    }

    let kind: Kind
    let percentUsed: Double
    let resetsAt: Date?
    let pace: PaceStatus
}

struct QuotaSnapshot {
    let plan: String?
    let session: QuotaWindow?
    let weekly: QuotaWindow?
    /// Wall-clock time the underlying `quota-axi` call took - shown in the
    /// popover's footer ("quota-axi · 1.4s"), matching this app's convention
    /// of surfacing the real data source/latency rather than hiding it.
    let latency: TimeInterval
    /// Raw command output for whatever failed, if anything - mirrors
    /// `VaultSnapshot.log`'s "show the real command output" principle.
    let log: String
}

enum QuotaFetchResult {
    case success(QuotaSnapshot)
    case failure(String)
}

enum QuotaSource {

    /// Bounds how long a fetch waits for `quota-axi` before giving up -
    /// confirmed live to normally return in ~1-2s; this is generous
    /// headroom for a real keychain prompt or a slow network hop, mirroring
    /// `VaultSource.appPasswordCheckTimeout`'s "never risk an indefinite
    /// hang" reasoning.
    private static let timeout: TimeInterval = 15

    /// Full fetch: resolves `quota-axi`, runs it with the Claude-only flag,
    /// and parses the confirmed-live JSON shape (report section 5) into a
    /// typed snapshot. Safe to call from a background queue; never touches
    /// the main thread.
    static func fetch() -> QuotaFetchResult {
        guard let exe = resolveExecutable("quota-axi") else {
            return .failure("quota-axi isn't on PATH.")
        }
        let start = Date()
        guard let result = runWithTimeout(exe, ["--json", "--provider", "claude", "--allow-keychain-prompt"], timeout: timeout) else {
            return .failure("quota-axi timed out.")
        }
        let latency = Date().timeIntervalSince(start)
        guard result.status == 0, !result.stdout.isEmpty else {
            // GL-14: this used to surface `quota-axi`'s raw stderr, which for
            // the most common failure by far - no network - is a stack of
            // transport detail that reads like a bug in the tool. Name the
            // recognisable cases; anything else still shows the real output,
            // because inventing a friendly message for an unknown failure would
            // hide the one thing worth reading.
            return .failure(friendlyFailure(result))
        }
        guard let snapshot = parse(result.stdout, latency: latency, log: result.combinedLog) else {
            return .failure("Couldn't parse quota-axi's output.")
        }
        return .success(snapshot)
    }

    /// Recognises the offline/auth shapes in `quota-axi`'s own output. Kept
    /// `internal` so `QuotaDataSelfTest` can pin the mapping.
    static func friendlyFailure(_ result: SubprocessResult) -> String {
        let log = result.combinedLog
        let lower = log.lowercased()
        let offlineMarkers = ["could not resolve host", "network is unreachable", "connection refused",
                              "temporary failure in name resolution", "offline", "no route to host",
                              "nodename nor servname", "operation timed out", "timed out"]
        if offlineMarkers.contains(where: { lower.contains($0) }) {
            return "Couldn't reach Anthropic - check your connection, then try again."
        }
        if lower.contains("unauthorized") || lower.contains("401") || lower.contains("not authenticated")
            || lower.contains("no credentials") {
            return "quota-axi isn't authenticated. Run it once in a terminal to sign in."
        }
        if log.isEmpty {
            return "quota-axi failed (exit \(result.status))."
        }
        return log
    }

    /// `resetsAt` comes back from `quota-axi` as e.g.
    /// `"2026-08-17T18:50:00.081363+00:00"` - fractional seconds plus a
    /// `+00:00` offset (not `Z`). A plain `ISO8601DateFormatter()` (default
    /// format options) fails to parse this and returns `nil` for every
    /// window, unconditionally - confirmed live before landing this fix:
    /// `ISO8601DateFormatter().date(from:)` on that exact string is `nil`,
    /// while adding `.withFractionalSeconds` to `formatOptions` parses it
    /// correctly. Tried with fractional seconds first, then without (in case
    /// a future `quota-axi` response omits them), rather than a single fixed
    /// formatter.
    private static func parseResetsAt(_ s: String) -> Date? {
        let withFractional = ISO8601DateFormatter()
        withFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFractional.date(from: s) { return date }
        return ISO8601DateFormatter().date(from: s)
    }

    /// Not `private` - exercisable directly for future tests, mirroring
    /// `VaultSource.parseDoctorTools`'s own visibility.
    static func parse(_ json: String, latency: TimeInterval, log: String) -> QuotaSnapshot? {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let providers = obj["providers"] as? [[String: Any]],
              let claude = providers.first(where: { ($0["provider"] as? String) == "claude" })
        else { return nil }

        let plan = claude["plan"] as? String
        let windows = (claude["windows"] as? [[String: Any]]) ?? []

        var session: QuotaWindow?
        var weekly: QuotaWindow?
        for entry in windows {
            // The real `quota-axi` output carries `percentRemaining`, not
            // `percentUsed` - confirmed live: a `windows[]` entry looks like
            // `{"id": "five_hour", "percentRemaining": 93, ...}`. There is
            // no `percentUsed` key at all in the real output; the popover's
            // own UI (bar fill width, the 80%/90% warning thresholds) is
            // written in terms of "used," so the conversion happens once,
            // right here at the parse boundary, rather than threading a
            // "remaining" semantic through code that assumes "used"
            // everywhere else.
            guard let id = entry["id"] as? String,
                  let percentRemaining = entry["percentRemaining"] as? Double
            else { continue }
            let percentUsed = 100 - percentRemaining
            let resetsAt = (entry["resetsAt"] as? String).flatMap { parseResetsAt($0) }
            let paceStatus = QuotaWindow.PaceStatus(rawValue: (entry["pace"] as? [String: Any])?["status"] as? String)
            switch id {
            case "five_hour":
                session = QuotaWindow(kind: .session, percentUsed: percentUsed, resetsAt: resetsAt, pace: paceStatus)
            case "seven_day":
                weekly = QuotaWindow(kind: .weekly, percentUsed: percentUsed, resetsAt: resetsAt, pace: paceStatus)
            default:
                continue
            }
        }

        // At least one of the two windows this popover cares about must be
        // present, or there's nothing worth showing.
        guard session != nil || weekly != nil else { return nil }
        return QuotaSnapshot(plan: plan, session: session, weekly: weekly, latency: latency, log: log)
    }

    // MARK: Process plumbing

    // GL-15: this file's own header used to explain why it carried a fresh copy
    // of `resolveExecutable`/`RunResult`/`runWithTimeout`; `Subprocess` is that
    // consolidation, and its bounded-wait behaviour *is* the shape this file
    // established.

    private static func resolveExecutable(_ name: String) -> String? {
        Subprocess.resolveExecutable(name)
    }

    private typealias RunResult = SubprocessResult

    /// `nil` on timeout, matching what the local copy returned so the caller's
    /// "couldn't read quota" branch is unchanged.
    private static func runWithTimeout(_ executable: String, _ args: [String], timeout: TimeInterval) -> RunResult? {
        let result = Subprocess.run(executable: executable, arguments: args,
                                    timeout: timeout, log: AppLog.network)
        return result.timedOut ? nil : result
    }
}
