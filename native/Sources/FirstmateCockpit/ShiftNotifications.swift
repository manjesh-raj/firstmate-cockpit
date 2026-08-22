// Manjesh Grand Line - native macOS app.
//
// Local notifications for due tasks and follow-ups (phase 5, cockpit-shift-
// power-features). Follows `FleetNotifier.swift`'s established shape
// (background poll + "already notified" set + an immediate, trigger-less
// `UNNotificationRequest`) rather than `UNCalendarNotificationTrigger`
// scheduling - simpler to reason about and verify, and consistent with the
// one other place this app already does due-item alerting.
//
// Authorization is requested once at `start()` (safe to call every launch -
// a no-op once already determined, same as `FleetNotifier.start()`) and
// every call site here tolerates a denial gracefully: `requestAuthorization`'s
// `granted` flag is only logged, never asserted on, and `poll()` still runs
// on schedule regardless - `UNUserNotificationCenter.add` simply drops a
// request silently if the user never granted permission, so there is
// nothing to special-case in the scheduling logic itself.

import Foundation
import UserNotifications

final class ShiftNotificationScheduler {
    private let store: ShiftStore
    private var timer: Timer?

    /// `fm/grandline-notification-center`: fired on every poll with the
    /// current due-or-overdue counts (signal #8) - feeds the in-app
    /// Notification Center the same due-detection this scheduler already
    /// runs for the OS banner below, rather than a second implementation of
    /// "is this due." Unlike the banner's own once-per-distinct-due-Date
    /// dedup, this reflects the live count every poll (`nil`/0 clears it),
    /// since the in-app entry's own clear rule is "clears when completed,"
    /// not "clears once you've been told."
    var onDueCountsChanged: ((Int, Int) -> Void)?

    /// Each due item is notified once per distinct due `Date` - if a task's
    /// due date/time changes (edited, or pushed back), the new value is a
    /// fresh key and can notify again; snoozing/editing to the *same* value
    /// twice does not double-notify.
    private var notifiedTaskDueAt: [String: Date] = [:]
    private var notifiedFollowUpDueAt: [String: Date] = [:]

    private let pollInterval: TimeInterval = 60
    /// How far ahead of a due date/time to fire the reminder - matches the
    /// brief's "due tasks and follow-ups coming up" (not just exactly-on-time
    /// alerts, which a 60s poll could easily miss by a few seconds).
    private let lookahead: TimeInterval = 30 * 60

    init(store: ShiftStore) {
        self.store = store
    }

    /// Safe to call every launch. Requests notification permission
    /// (gracefully - see this file's header) and starts the poll if it
    /// isn't already running.
    ///
    /// `UNUserNotificationCenter.current()` throws an uncaught
    /// `NSInternalInconsistencyException` ("bundleProxyForCurrentProcess is
    /// nil") when the running process has no real Info.plist/bundle
    /// identifier - true for the bare `swift run`/`.build/debug/
    /// FirstmateCockpit` dev workflow this project's own README documents as
    /// normal (confirmed live: this crashed on every launch under that
    /// workflow until this guard was added, exactly the same class of crash
    /// `UpdatesController.notify`'s own header already documents and guards
    /// against). The packaged app (`build_native_app.sh`'s output, a real
    /// bundle) is unaffected either way - the poll timer still runs
    /// regardless, it just can't touch `UNUserNotificationCenter` from a
    /// bare binary.
    func start() {
        guard timer == nil else { return }
        ServiceHealthRegistry.shared.register(.shiftDueItems)
        if Bundle.main.bundleIdentifier != nil {
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
                if !granted {
                    let reason = error?.localizedDescription ?? "denied"
                    AppLog.poller.error("""
                        Tasks: notification permission not granted (\(reason, privacy: .public)) - \
                        due-item reminders will not appear until it is.
                        """)
                    // A permission the captain declined is a real, permanent
                    // reason this service cannot do its job, and it is
                    // invisible everywhere else.
                    ServiceHealthRegistry.shared.recordFailure(
                        .shiftDueItems,
                        "Notification permission not granted (\(reason)). Enable it in System Settings > Notifications.")
                }
            }
        }
        poll()
        let t = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in self?.poll() }
        t.tolerance = 10
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Exposed (not `private`) so a self-test / debug probe can force one
    /// check without waiting for the timer - mirrors how `FleetNotifier`'s
    /// own poll cycle is exercised in this codebase (a temporary env-gated
    /// probe, per AGENTS.md's "Verifying native UI bugs" convention).
    func poll() {
        ServiceHealthRegistry.shared.recordSuccess(.shiftDueItems)
        let now = Date()
        let horizon = now.addingTimeInterval(lookahead)

        var dueTaskCount = 0
        for task in store.activeTasks {
            guard let due = ShiftDateFormatting.dateTime(from: task.dueDate, time: task.dueTime) else { continue }
            guard due <= horizon else { continue }
            dueTaskCount += 1
            guard notifiedTaskDueAt[task.id] != due else { continue }
            notifiedTaskDueAt[task.id] = due
            notify(
                title: due <= now ? "Task due now" : "Task due soon",
                body: task.title,
                identifier: "shift.task.\(task.id)"
            )
        }

        var dueFollowUpCount = 0
        for followUp in store.followUps where followUp.status == .pending {
            guard let due = ShiftDateFormatting.dateTime(from: followUp.followUpAt, time: followUp.followUpTime) else { continue }
            guard due <= horizon else { continue }
            dueFollowUpCount += 1
            guard notifiedFollowUpDueAt[followUp.id] != due else { continue }
            notifiedFollowUpDueAt[followUp.id] = due
            notify(
                title: due <= now ? "Follow-up due now" : "Follow-up coming up",
                body: followUp.title,
                identifier: "shift.followup.\(followUp.id)"
            )
        }

        onDueCountsChanged?(dueTaskCount, dueFollowUpCount)
    }

    private func notify(title: String, body: String, identifier: String) {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
    }
}
