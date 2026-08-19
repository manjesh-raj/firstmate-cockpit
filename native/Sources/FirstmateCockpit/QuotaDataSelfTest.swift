// Manjesh Grand Line - native macOS app.
//
// Permanent, env-gated self-test for `QuotaSource.parse` - run via
// `FM_RUN_QUOTA_DATA_TESTS=1 .build/debug/FirstmateCockpit`, same convention
// as `VaultDataSelfTest.swift`/`HostStoreSelfTest.swift`.
//
// `fm/grandline-quota-percent-fix` fixed a real captain-reported bug: the
// popover always showed "Couldn't parse quota-axi's output." because `parse`
// read a `percentUsed` key that doesn't exist in the real `quota-axi`
// output - the real key is `percentRemaining` (confirmed live on this
// machine, see `QuotaData.swift`'s header). This file's payloads are copied
// from that real, live `quota-axi --json --provider claude
// --allow-keychain-prompt` output (with only the numbers/timestamps
// trimmed), not invented, so a future change to the real shape has a real
// baseline to diff against.
import Foundation

enum QuotaDataSelfTest {
    @discardableResult
    static func run() -> Bool {
        var failures: [String] = []
        func check(_ name: String, _ condition: Bool) {
            if !condition { failures.append(name) }
        }

        // MARK: real-shaped payload (both windows this popover cares about,
        // plus the two other window kinds `quota-axi` also returns -
        // `model:fable` (kind `model`) and `extra_usage` (kind `credits`) -
        // which must NOT be mistaken for session/weekly.

        let realShaped = """
        {
          "generatedAt": "2026-08-19T04:46:09.481Z",
          "schemaVersion": 5,
          "providers": [
            {
              "provider": "claude",
              "plan": "team",
              "windows": [
                {
                  "id": "five_hour",
                  "label": "session",
                  "kind": "session",
                  "resetsAt": "2026-08-19T08:20:00.299282+00:00",
                  "percentRemaining": 91,
                  "pace": { "status": "behind" }
                },
                {
                  "id": "seven_day",
                  "label": "week",
                  "kind": "weekly",
                  "resetsAt": "2026-08-23T16:00:00.299301+00:00",
                  "percentRemaining": 79,
                  "pace": { "status": "behind" }
                },
                {
                  "id": "model:fable",
                  "label": "Fable week",
                  "kind": "model",
                  "percentRemaining": 100,
                  "pace": { "status": "unknown", "reason": "missing_cycle" }
                },
                {
                  "id": "extra_usage",
                  "label": "extra usage",
                  "kind": "credits",
                  "spentUsd": 260.28,
                  "pace": { "status": "unknown", "reason": "missing_usage" }
                }
              ]
            }
          ]
        }
        """

        if let snapshot = QuotaSource.parse(realShaped, latency: 1.2, log: "") {
            check("real payload: plan parsed", snapshot.plan == "team")
            check("real payload: session present", snapshot.session != nil)
            check("real payload: weekly present", snapshot.weekly != nil)
            // percentRemaining: 91 -> percentUsed: 9
            check("real payload: session percentUsed converted from percentRemaining", snapshot.session?.percentUsed == 9)
            check("real payload: session pace parsed", snapshot.session?.pace == .behind)
            check("real payload: session resetsAt parsed (fractional seconds)", snapshot.session?.resetsAt != nil)
            // percentRemaining: 79 -> percentUsed: 21
            check("real payload: weekly percentUsed converted from percentRemaining", snapshot.weekly?.percentUsed == 21)
            check("real payload: weekly kind is .weekly", snapshot.weekly?.kind == .weekly)
            check("real payload: session kind is .session", snapshot.session?.kind == .session)
        } else {
            failures.append("real payload failed to parse at all")
        }

        // MARK: one window missing - should still parse using whichever is present

        let sessionOnly = """
        {"providers":[{"provider":"claude","plan":"pro","windows":[
          {"id":"five_hour","resetsAt":"2026-08-19T08:20:00.299282+00:00","percentRemaining":40,"pace":{"status":"ahead"}}
        ]}]}
        """
        if let snapshot = QuotaSource.parse(sessionOnly, latency: 0.5, log: "") {
            check("session-only: session present", snapshot.session != nil)
            check("session-only: weekly absent", snapshot.weekly == nil)
            check("session-only: percentUsed converted", snapshot.session?.percentUsed == 60)
            check("session-only: pace ahead", snapshot.session?.pace == .ahead)
        } else {
            failures.append("session-only payload failed to parse")
        }

        let weeklyOnly = """
        {"providers":[{"provider":"claude","plan":"pro","windows":[
          {"id":"seven_day","resetsAt":"2026-08-23T16:00:00.299301+00:00","percentRemaining":5,"pace":{"status":"behind"}}
        ]}]}
        """
        if let snapshot = QuotaSource.parse(weeklyOnly, latency: 0.5, log: "") {
            check("weekly-only: weekly present", snapshot.weekly != nil)
            check("weekly-only: session absent", snapshot.session == nil)
            check("weekly-only: percentUsed converted (high usage)", snapshot.weekly?.percentUsed == 95)
        } else {
            failures.append("weekly-only payload failed to parse")
        }

        // MARK: genuinely unparseable payloads must return nil, not crash

        check("empty string returns nil", QuotaSource.parse("", latency: 0, log: "") == nil)
        check("non-JSON returns nil", QuotaSource.parse("not json at all", latency: 0, log: "") == nil)
        check("valid JSON with no claude provider returns nil", QuotaSource.parse(#"{"providers":[{"provider":"other"}]}"#, latency: 0, log: "") == nil)
        check(
            "claude provider with no usable windows returns nil",
            QuotaSource.parse(#"{"providers":[{"provider":"claude","windows":[{"id":"model:fable","percentRemaining":100}]}]}"#, latency: 0, log: "") == nil
        )
        check(
            "windows entries missing percentRemaining are skipped, not crashed on",
            QuotaSource.parse(#"{"providers":[{"provider":"claude","windows":[{"id":"five_hour"}]}]}"#, latency: 0, log: "") == nil
        )

        // MARK: threshold semantics unchanged in meaning - a nearly-exhausted
        // window (low percentRemaining) must land as HIGH percentUsed, so
        // the popover's existing `.critical`/`.warn` thresholds (computed as
        // `percentUsed > 90` / `>= 80`) still flag it as urgent, not calm.

        let nearlyExhausted = """
        {"providers":[{"provider":"claude","windows":[
          {"id":"five_hour","percentRemaining":3,"pace":{"status":"behind"}}
        ]}]}
        """
        if let snapshot = QuotaSource.parse(nearlyExhausted, latency: 0, log: "") {
            let percentUsed = snapshot.session?.percentUsed ?? -1
            check("nearly-exhausted window reads as high percentUsed", percentUsed == 97)
            check("nearly-exhausted window crosses the critical threshold (>90)", percentUsed > 90)
        } else {
            failures.append("nearly-exhausted payload failed to parse")
        }

        if failures.isEmpty {
            print("QuotaDataSelfTest: all checks passed")
            return true
        } else {
            print("QuotaDataSelfTest: FAILED - \(failures.joined(separator: "; "))")
            return false
        }
    }
}
