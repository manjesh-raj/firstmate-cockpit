// Manjesh Grand Line - native macOS app.
//
// Settings > Terminal's "Bell & notifications" toggle (Fix 3): a real
// background poll of the same task state `FleetController` reads, so a
// crewmate parking on a decision surfaces a macOS notification even while
// the captain is looking at a different rail destination - mirroring the
// web app's "Surface a desktop notification the moment a crewmate needs
// your decision." `FleetController`'s own on-appear refresh is not enough
// for that promise, since it only runs while Overview is on screen.
//
// `fm/grandline-notification-center` extended this poll two ways:
//   1. It also detects a task finishing (done/failed) while the captain
//      wasn't looking - the design doc's signal #9, which had no other
//      computed home anywhere in the app. `reconcile(_:)` tracks this
//      separately from the pre-existing needs-decision/blocked tracking.
//   2. The poll itself now ALWAYS runs from app launch (`start()`, called
//      unconditionally in `main.swift`), decoupled from the "Bell &
//      notifications" Settings toggle - `setEnabled` now only gates whether
//      a macOS banner is actually posted (`osBannersEnabled`), not whether
//      detection happens at all. This is a deliberate architectural choice
//      for the in-app Notification Center: it must stay current whether or
//      not the captain has opted into OS banners, since the design doc
//      frames it as an always-on core feature, not something you turn on.
//      The OS banner and the in-app entry are two independent presentations
//      of the same detected event now, not one gating the other.
//
// A finished task is acknowledged (and stops resurfacing in the in-app
// center) the moment the captain opens the aggregated notification - see
// `acknowledgeFinishedTasks(ids:)`, called from the notification's own
// `navigate` closure (`NotificationSources.setFleetFinished`). This is
// separate from `seenFinishedForBanner`, which only dedups the one-shot OS
// banner and has no "did the captain actually see it" concept.

import Foundation
import UserNotifications

final class FleetNotifier {
    static let shared = FleetNotifier()

    private var timer: Timer?
    private var seenNeedsDecision: Set<String> = []
    private var seenFinishedForBanner: Set<String> = []
    private var acknowledgedFinishedIDs: Set<String> = []
    private var osBannersEnabled = false
    private let pollInterval: TimeInterval = 30

    /// Forwarded navigation for the in-app "N tasks finished" entry -
    /// mirrors `ConsoleComposerController.onRunInTerminal`'s own forward-
    /// don't-own convention. Set once at launch in `main.swift`.
    var onNavigateToOverview: (() -> Void)?

    private init() {}

    /// Always safe to call once at launch, regardless of the "Bell &
    /// notifications" setting - see the file header. Seeds both "already
    /// seen" sets with whatever is true right now, so turning this on for
    /// the first time (every launch) never treats pre-existing state as a
    /// fresh transition.
    func start() {
        guard timer == nil else { return }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let tasks = FleetDataSource.parseTasks()
            let decisionIDs = Set(tasks.filter { $0.status == "needs_decision" || $0.status == "blocked" }.map(\.id))
            let finishedIDs = Set(tasks.filter { $0.status == "done" || $0.status == "failed" }.map(\.id))
            DispatchQueue.main.async {
                guard let self else { return }
                self.seenNeedsDecision = decisionIDs
                self.seenFinishedForBanner = finishedIDs
                // A task already done/failed before this launch is not
                // "finished while you weren't looking" for the in-app
                // center either - primed as already-acknowledged.
                self.acknowledgedFinishedIDs = finishedIDs
            }
        }
        let t = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in self?.poll() }
        t.tolerance = 5
        timer = t
    }

    /// The "Bell & notifications" Settings toggle - gates whether a macOS
    /// banner is posted (and requests notification permission the first
    /// time it's turned on). Does NOT start/stop the poll itself; `start()`
    /// (always called once at launch) owns that, so the in-app Notification
    /// Center stays current either way.
    func setEnabled(_ enabled: Bool) {
        osBannersEnabled = enabled
        guard enabled, Bundle.main.bundleIdentifier != nil else { return }
        // UNUserNotificationCenter.current() throws an uncaught NSInternalInconsistencyException
        // ("bundleProxyForCurrentProcess is nil") on a process with no real bundle identifier -
        // true for the bare `.build/debug/FirstmateCockpit`/`swift run` dev binary. See
        // UpdatesController.notify/ShiftNotifications' identical guard for the same reason.
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func poll() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let tasks = FleetDataSource.parseTasks()
            DispatchQueue.main.async {
                self?.reconcile(tasks)
            }
        }
    }

    private func reconcile(_ tasks: [FleetTask]) {
        let decisionTasks = tasks.filter { $0.status == "needs_decision" || $0.status == "blocked" }
        let currentDecisionIDs = Set(decisionTasks.map(\.id))
        let freshDecisions = decisionTasks.filter { !seenNeedsDecision.contains($0.id) }
        seenNeedsDecision = currentDecisionIDs
        if osBannersEnabled {
            for task in freshDecisions { notify(task) }
        }

        let finishedTasks = tasks.filter { $0.status == "done" || $0.status == "failed" }
        let currentFinishedIDs = Set(finishedTasks.map(\.id))
        let freshFinished = finishedTasks.filter { !seenFinishedForBanner.contains($0.id) }
        seenFinishedForBanner = currentFinishedIDs
        if osBannersEnabled {
            for task in freshFinished { notifyFinished(task) }
        }

        // In-app Notification Center: signal #1 (needs-decision/blocked) is
        // fed from `FleetController.onNeedsDecisionCountChanged` instead
        // (already computed for the rail badge - see `AppShellController.
        // loadView()`) - not duplicated here. Signal #9 (finished tasks) has
        // no other computed home, so this poll is its one source.
        let unacknowledged = finishedTasks.filter { !acknowledgedFinishedIDs.contains($0.id) }
        NotificationSources.setFleetFinished(unacknowledged) { [weak self] in
            self?.acknowledgeFinishedTasks(ids: unacknowledged.map(\.id))
            self?.onNavigateToOverview?()
        }
    }

    /// Marks every task id in `ids` as already-seen by the in-app center, so
    /// it never resurfaces on a later poll purely because its `.meta` file
    /// is still sitting there marked done/failed (state files are not
    /// deleted by this poll). Not `private` so a debug probe / self-test can
    /// exercise this directly.
    func acknowledgeFinishedTasks(ids: [String]) {
        acknowledgedFinishedIDs.formUnion(ids)
    }

    private func notify(_ task: FleetTask) {
        let content = UNMutableNotificationContent()
        content.title = task.status == "blocked" ? "Task blocked" : "Task needs your decision"
        content.body = task.repo != nil ? "\(task.id) (\(task.repo!))" : task.id
        content.sound = .default
        let request = UNNotificationRequest(identifier: "fm.needs-decision.\(task.id)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    private func notifyFinished(_ task: FleetTask) {
        let content = UNMutableNotificationContent()
        content.title = task.status == "failed" ? "Task failed" : "Task finished"
        content.body = task.repo != nil ? "\(task.id) (\(task.repo!))" : task.id
        content.sound = .default
        let request = UNNotificationRequest(identifier: "fm.finished.\(task.id)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
