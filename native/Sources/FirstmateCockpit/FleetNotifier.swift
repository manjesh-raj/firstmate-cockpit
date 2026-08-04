// Firstmate Cockpit - native macOS app.
//
// Settings > Terminal's "Bell & notifications" toggle (Fix 3): a real
// background poll of the same task state `FleetController` reads, so a
// crewmate parking on a decision surfaces a macOS notification even while
// the captain is looking at a different rail destination - mirroring the
// web app's "Surface a desktop notification the moment a crewmate needs
// your decision." `FleetController`'s own on-appear refresh is not enough
// for that promise, since it only runs while Overview is on screen.

import Foundation
import UserNotifications

final class FleetNotifier {
    static let shared = FleetNotifier()

    private var timer: Timer?
    private var seenNeedsDecision: Set<String> = []
    private let pollInterval: TimeInterval = 30

    private init() {}

    /// Called once at launch (if the setting is already on) and again every
    /// time the Settings toggle flips - safe to call repeatedly.
    func setEnabled(_ enabled: Bool) {
        if enabled {
            start()
        } else {
            stop()
        }
    }

    private func start() {
        guard timer == nil else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        // Prime the "already seen" set with whatever is parked right now, so
        // enabling the toggle doesn't immediately fire a notification for
        // every task that has been waiting since before this was turned on.
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let ids = Set(FleetDataSource.parseTasks().filter { $0.status == "needs_decision" || $0.status == "blocked" }.map(\.id))
            DispatchQueue.main.async { self?.seenNeedsDecision = ids }
        }
        let t = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in self?.poll() }
        t.tolerance = 5
        timer = t
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func poll() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let tasks = FleetDataSource.parseTasks().filter { $0.status == "needs_decision" || $0.status == "blocked" }
            DispatchQueue.main.async {
                self?.reconcile(tasks)
            }
        }
    }

    private func reconcile(_ tasks: [FleetTask]) {
        let currentIDs = Set(tasks.map(\.id))
        let fresh = tasks.filter { !seenNeedsDecision.contains($0.id) }
        seenNeedsDecision = currentIDs
        for task in fresh {
            notify(task)
        }
    }

    private func notify(_ task: FleetTask) {
        let content = UNMutableNotificationContent()
        content.title = task.status == "blocked" ? "Task blocked" : "Task needs your decision"
        content.body = task.repo != nil ? "\(task.id) (\(task.repo!))" : task.id
        content.sound = .default
        let request = UNNotificationRequest(identifier: "fm.needs-decision.\(task.id)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
