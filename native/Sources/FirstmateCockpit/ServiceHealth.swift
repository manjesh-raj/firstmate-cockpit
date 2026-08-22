// Manjesh Grand Line - native macOS app.
//
// GL-11 / F1 (production-readiness review sections 20 and 25): the registry
// behind the Health card. The review's framing is the point worth keeping -
// "a cockpit whose own gauges can silently die is not glanceable." Before
// this, `BackgroundSignalsPoller`, `FleetNotifier` and `ShiftGitSync` had zero
// log statements between them and no user-visible liveness signal at all, so a
// wedged poller (GL-03) meant notifications went stale forever with nothing
// anywhere saying so.
//
// This is deliberately a *registry*, not a monitor: it never polls anything and
// never decides that a service is unhealthy on its own. Each service reports
// its own outcomes (`recordSuccess`/`recordFailure`), and the registry only
// remembers the last of each plus a consecutive-failure count. That keeps the
// health of a service defined by the service, which is the only place that can
// know what "healthy" means for it.
//
// Two consumers:
//  - `HealthCardView` (Settings) renders one row per service.
//  - After `failureThreshold` consecutive failures, `NotificationSources`
//    raises a `.actionNeeded` entry (GL-30). One failure is noise - a laptop
//    on a train fails a `gh` call constantly; repeated failure is a real
//    signal, and it is the one the review asks to surface.
//
// Everything here stays local: timestamps and error strings in memory, nothing
// persisted, nothing sent anywhere. Error strings come from the same sources
// the logs use, so the "don't log a secret value" rule covers this too - a
// failure detail is a tool's own message, never a credential.

import Foundation

/// The background services the Health card knows about. A case is added when a
/// service starts reporting, not speculatively - an always-"never run" row is
/// worse than no row.
enum HealthService: String, CaseIterable {

    case backgroundSignals
    case fleetTasks
    case shiftGitSync
    case docsSync
    case shiftDueItems
    case persistence

    /// Row title on the Health card.
    var title: String {
        switch self {
        case .backgroundSignals: return "Tool & drift signals"
        case .fleetTasks: return "Fleet task watcher"
        case .shiftGitSync: return "Tasks git sync"
        case .docsSync: return "Docs & runbooks sync"
        case .shiftDueItems: return "Due-item reminders"
        case .persistence: return "Saving to disk"
        }
    }

    /// One line saying what this service actually does, so a failure row is
    /// actionable rather than a bare name.
    var detail: String {
        switch self {
        case .backgroundSignals:
            return "Checks tool updates, fork drift, Vault and setup drift every 15 minutes."
        case .fleetTasks:
            return "Watches the fleet's task state for decisions and finished work."
        case .shiftGitSync:
            return "Commits and pushes Tasks, runbooks and command library changes."
        case .docsSync:
            return "Pulls the DevOps Playbook and runbook content."
        case .shiftDueItems:
            return "Notifies when a task or follow-up comes due."
        case .persistence:
            return "Writes hosts, keys, snippets, tasks and commands to disk."
        }
    }

    var symbol: String {
        switch self {
        case .backgroundSignals: return "antenna.radiowaves.left.and.right"
        case .fleetTasks: return "sailboat"
        case .shiftGitSync: return "arrow.triangle.2.circlepath"
        case .docsSync: return "book.closed"
        case .shiftDueItems: return "bell"
        case .persistence: return "internaldrive"
        }
    }
}

struct ServiceHealthState {
    var lastSuccess: Date?
    var lastFailure: Date?
    var lastFailureDetail: String?
    /// Reset to zero by any success. This is what makes the notification
    /// threshold mean "still broken" rather than "was broken once".
    var consecutiveFailures: Int = 0
    /// Set while a pass is in flight, so the card can say "checking…" rather
    /// than showing a stale timestamp as if it were current.
    var isRunning: Bool = false

    /// Never reported anything yet - rendered as "not run yet", which is a
    /// true and useful statement at launch.
    var hasReported: Bool { lastSuccess != nil || lastFailure != nil }

    enum Verdict { case unknown, running, healthy, degraded, failing }

    var verdict: Verdict {
        if isRunning { return .running }
        if !hasReported { return .unknown }
        if consecutiveFailures >= ServiceHealthRegistry.failureThreshold { return .failing }
        if consecutiveFailures > 0 { return .degraded }
        return .healthy
    }
}

/// App-lifetime singleton, `ThemeManager`-shaped: an `observe` list of
/// closures plus a synchronous notify, since every consumer is a view.
///
/// Thread-safety matters here in a way it does not for `ThemeManager`: the
/// reporters are background queues (pollers, the git-sync serial queue) while
/// every observer is a view on the main thread. State is guarded by a lock and
/// observers are always notified on the main queue.
final class ServiceHealthRegistry {

    static let shared = ServiceHealthRegistry()

    /// Consecutive failures before this is worth interrupting the captain over.
    /// Two 15-minute poller passes is half an hour of a signal being wrong,
    /// which is the point at which "the gauge is broken" beats "the network
    /// blipped".
    static let failureThreshold = 3

    private let lock = NSLock()
    private var states: [HealthService: ServiceHealthState] = [:]
    private var observers: [(HealthService) -> Void] = []

    private init() {}

    // MARK: Reporting (any thread)

    func markRunning(_ service: HealthService) {
        mutate(service) { $0.isRunning = true }
    }

    func recordSuccess(_ service: HealthService, at date: Date = Date()) {
        AppLog.poller.debug("\(service.rawValue, privacy: .public) ok")
        mutate(service) {
            $0.isRunning = false
            $0.lastSuccess = date
            $0.consecutiveFailures = 0
            $0.lastFailureDetail = nil
        }
    }

    func recordFailure(_ service: HealthService, _ detail: String, at date: Date = Date()) {
        AppLog.poller.error("\(service.rawValue, privacy: .public) failed: \(detail, privacy: .public)")
        var crossedThreshold = false
        var count = 0
        mutate(service) {
            $0.isRunning = false
            $0.lastFailure = date
            $0.lastFailureDetail = detail
            $0.consecutiveFailures += 1
            count = $0.consecutiveFailures
            crossedThreshold = $0.consecutiveFailures >= Self.failureThreshold
        }
        if crossedThreshold {
            // The Notification Center store is main-thread-only, like every
            // other UI-facing singleton here.
            DispatchQueue.main.async {
                NotificationSources.setServiceFailing(service, failures: count, detail: detail)
            }
        }
    }

    // MARK: Reading

    func state(_ service: HealthService) -> ServiceHealthState {
        lock.lock(); defer { lock.unlock() }
        return states[service] ?? ServiceHealthState()
    }

    /// Only services that have something to say, in `HealthService`'s own
    /// declaration order. A service that has never reported is included once
    /// the app knows it exists - see `register(_:)`.
    func knownServices() -> [HealthService] {
        lock.lock(); defer { lock.unlock() }
        return HealthService.allCases.filter { states[$0] != nil }
    }

    /// Declare a service so its row appears (as "not run yet") before its
    /// first pass finishes. Called from the service's own `start()`.
    func register(_ service: HealthService) {
        mutate(service) { _ in }
    }

    // MARK: Observation

    /// Fires on the main queue whenever any service's state changes. No
    /// removal token: every observer here is an app-lifetime view, the same
    /// tradeoff `ThemeManager` documents.
    func observe(_ handler: @escaping (HealthService) -> Void) {
        lock.lock()
        observers.append(handler)
        lock.unlock()
    }

    private func mutate(_ service: HealthService, _ body: (inout ServiceHealthState) -> Void) {
        lock.lock()
        var state = states[service] ?? ServiceHealthState()
        body(&state)
        states[service] = state
        let handlers = observers
        lock.unlock()
        guard !handlers.isEmpty else { return }
        DispatchQueue.main.async {
            for handler in handlers { handler(service) }
        }
    }
}
