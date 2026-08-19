// Manjesh Grand Line - native macOS app.
//
// Thin adapters (`fm/grandline-notification-center`) that turn each already-
// computed signal listed in the captain-approved design doc's inventory
// table into an `AppNotification` and hand it to
// `GrandLineNotificationCenter.shared.set(_:id:)`. No detection logic lives
// here - every function takes a count (or list) a page/poller already
// computed and only owns the id/title/subtext/tint/kind formatting, so
// there is exactly one place to read "what does each signal's notification
// actually say."
//
// Call sites (not owned by this file):
//   - Fleet decisions (#1) / PR ready (#2): `AppShellController.loadView()`,
//     piggybacking on the existing `onNeedsDecisionCountChanged`/
//     `onOpenPRCountChanged` callbacks that already drive the rail badges -
//     no new poll, updates exactly when those pages' own counts do.
//   - Tool updates (#3) / GitHub Sync (#4) / Vault (#5) / setup drift (#6):
//     `BackgroundSignalsPoller.swift`, a dedicated slow poll (see that
//     file's header for the cadence tradeoff) plus a feed from each page's
//     own on-visit check where wired.
//   - SRE Lead reply (#7): `ConsoleController`/`AppShellController.connectHost`.
//   - Shift due (#8): `ShiftNotificationScheduler.poll()`.
//   - Fleet finished (#9): `FleetNotifier.reconcile(_:)`.

import Foundation

enum NotificationSources {

    // MARK: #1 - Fleet task needs a decision / is blocked

    static let fleetDecisionsID = "fleet-decisions"

    static func setFleetDecisions(count: Int, navigate: @escaping () -> Void) {
        guard count > 0 else {
            GrandLineNotificationCenter.shared.set(nil, id: fleetDecisionsID)
            return
        }
        let title = count == 1 ? "1 task needs your decision" : "\(count) tasks need your decision"
        GrandLineNotificationCenter.shared.set(
            AppNotification(
                id: fleetDecisionsID, title: title,
                subtext: "Overview \u{00B7} clears when answered",
                kind: .actionNeeded, tint: .warn, navigate: navigate
            ),
            id: fleetDecisionsID
        )
    }

    // MARK: #2 - PR ready to merge

    static let prReadyID = "pr-ready"

    static func setPRReady(count: Int, navigate: @escaping () -> Void) {
        guard count > 0 else {
            GrandLineNotificationCenter.shared.set(nil, id: prReadyID)
            return
        }
        let title = count == 1 ? "1 PR ready to merge" : "\(count) PRs ready to merge"
        GrandLineNotificationCenter.shared.set(
            AppNotification(
                id: prReadyID, title: title,
                subtext: "Review \u{00B7} clears when merged",
                kind: .actionNeeded, tint: .good, navigate: navigate
            ),
            id: prReadyID
        )
    }

    // MARK: #3 - A tool has an update available

    static let toolUpdatesID = "tool-updates"

    static func setToolUpdates(count: Int, navigate: @escaping () -> Void) {
        guard count > 0 else {
            GrandLineNotificationCenter.shared.set(nil, id: toolUpdatesID)
            return
        }
        let title = count == 1 ? "1 tool has an update available" : "\(count) tools have updates available"
        GrandLineNotificationCenter.shared.set(
            AppNotification(
                id: toolUpdatesID, title: title,
                subtext: "Updates \u{00B7} clears when installed",
                kind: .informational, tint: .info, navigate: navigate
            ),
            id: toolUpdatesID
        )
    }

    // MARK: #4 - A personal fork is behind/diverged from upstream

    static let githubSyncID = "github-sync"

    static func setGitHubSync(count: Int, navigate: @escaping () -> Void) {
        guard count > 0 else {
            GrandLineNotificationCenter.shared.set(nil, id: githubSyncID)
            return
        }
        let title = count == 1 ? "1 fork is behind upstream" : "\(count) forks are behind upstream"
        GrandLineNotificationCenter.shared.set(
            AppNotification(
                id: githubSyncID, title: title,
                subtext: "GitHub Sync \u{00B7} clears when synced",
                kind: .informational, tint: .info, navigate: navigate
            ),
            id: githubSyncID
        )
    }

    // MARK: #5 - A security/hardener tool needs attention

    static let vaultAttentionID = "vault-attention"

    static func setVaultAttention(count: Int, navigate: @escaping () -> Void) {
        guard count > 0 else {
            GrandLineNotificationCenter.shared.set(nil, id: vaultAttentionID)
            return
        }
        let title = count == 1 ? "1 security tool needs attention" : "\(count) security tools need attention"
        GrandLineNotificationCenter.shared.set(
            AppNotification(
                id: vaultAttentionID, title: title,
                subtext: "Vault \u{00B7} clears when hardened",
                kind: .informational, tint: .violet, navigate: navigate
            ),
            id: vaultAttentionID
        )
    }

    // MARK: #6 - Machine setup has drifted

    static let setupDriftID = "setup-drift"

    static func setSetupDrift(count: Int, navigate: @escaping () -> Void) {
        guard count > 0 else {
            GrandLineNotificationCenter.shared.set(nil, id: setupDriftID)
            return
        }
        let title = count == 1 ? "1 setup item has drifted" : "\(count) setup items have drifted"
        GrandLineNotificationCenter.shared.set(
            AppNotification(
                id: setupDriftID, title: title,
                subtext: "Bootstrap \u{00B7} clears when re-satisfied",
                kind: .informational, tint: .warn, navigate: navigate
            ),
            id: setupDriftID
        )
    }

    // MARK: #7 - SRE Lead answered a question on a tab you're not looking at (per tab)

    static func sreLeadReplyID(tabID: UUID) -> String { "sre-lead.\(tabID.uuidString)" }

    static func setSRELeadReply(tabID: UUID, tabName: String, hostLabel: String, navigate: @escaping () -> Void) {
        let id = sreLeadReplyID(tabID: tabID)
        GrandLineNotificationCenter.shared.set(
            AppNotification(
                id: id, title: "SRE Lead replied on \u{201c}\(tabName)\u{201d}",
                subtext: "\(hostLabel) \u{00B7} clears when opened",
                kind: .actionNeeded, tint: .good, navigate: navigate
            ),
            id: id
        )
    }

    static func clearSRELeadReply(tabID: UUID) {
        GrandLineNotificationCenter.shared.remove(id: sreLeadReplyID(tabID: tabID))
    }

    // MARK: #8 - A Shift task/follow-up is due or overdue

    static let shiftDueID = "shift-due"

    static func setShiftDue(taskCount: Int, followUpCount: Int, navigate: @escaping () -> Void) {
        let total = taskCount + followUpCount
        guard total > 0 else {
            GrandLineNotificationCenter.shared.set(nil, id: shiftDueID)
            return
        }
        let title: String
        if taskCount > 0 && followUpCount > 0 {
            title = "\(total) tasks/follow-ups due or overdue"
        } else if taskCount > 0 {
            title = taskCount == 1 ? "1 task due or overdue" : "\(taskCount) tasks due or overdue"
        } else {
            title = followUpCount == 1 ? "1 follow-up due or overdue" : "\(followUpCount) follow-ups due or overdue"
        }
        GrandLineNotificationCenter.shared.set(
            AppNotification(
                id: shiftDueID, title: title,
                subtext: "Tasks \u{00B7} clears when completed",
                kind: .informational, tint: .warn, navigate: navigate
            ),
            id: shiftDueID
        )
    }

    // MARK: #9 - A fleet task finished (done/failed) while you weren't looking

    static let fleetFinishedID = "fleet-finished"

    static func setFleetFinished(_ tasks: [FleetTask], navigate: @escaping () -> Void) {
        guard !tasks.isEmpty else {
            GrandLineNotificationCenter.shared.set(nil, id: fleetFinishedID)
            return
        }
        let anyFailed = tasks.contains { $0.status == "failed" }
        let title = tasks.count == 1 ? "1 task finished" : "\(tasks.count) tasks finished"
        GrandLineNotificationCenter.shared.set(
            AppNotification(
                id: fleetFinishedID, title: title,
                subtext: "Overview \u{00B7} clears when read",
                kind: .actionNeeded, tint: anyFailed ? .critical : .good, navigate: navigate
            ),
            id: fleetFinishedID
        )
    }
}
