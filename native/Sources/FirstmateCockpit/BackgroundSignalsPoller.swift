// Manjesh Grand Line - native macOS app.
//
// Background poll (`fm/grandline-notification-center`) for the four
// Notification Center signals that, before this task, only ever recomputed
// on an explicit page visit: tool updates (Updates page), fork drift
// (GitHub Sync page), Vault attention, and Bootstrap's own setup-drift
// check. Every one of these already has a real, non-duplicated check
// function (`UpdatesSource.check`, `GitHubSyncSource.check`,
// `VaultSource.loadSnapshot`, `SetupStepChecks.*`) - this file only owns
// *when* to call them for the purpose of keeping the in-app Notification
// Center current, never a second implementation of what "needs attention"
// means for any of them.
//
// Cadence tradeoff (the design doc flagged exactly this as worth a
// deliberate decision, not a default): these checks shell out to `brew`/
// `npm`/`gh api`/`av` once per catalog item/repo/tool - `FleetNotifier`'s
// 30s cadence would mean dozens of process spawns every half-minute even
// while the captain is looking at something else entirely, which is a real
// background cost for signals that change on the order of hours, not
// seconds (a tool doesn't get a new release, a fork doesn't fall behind,
// every 30 seconds). This poller runs every 15 minutes instead - "no dead/
// excessive polling" per this app's own standing bar, while still staying
// materially fresher than "only when you happen to open that page." Each
// of the four pages' own on-visit checks are unaffected and still run
// independently at their existing cadence (page visit / manual refresh) -
// this poller exists purely so the notification center doesn't go stale
// between visits, not to replace those pages' own logic.
//
// All four checks run sequentially on one background queue, not
// concurrently - mirrors `BootstrapController.installAllMissing`'s own
// "never race two package-manager invocations against each other" caution,
// generalized here since `brew`/`npm`/`av` can all be invoked across the
// four checks.

import Foundation

final class BackgroundSignalsPoller {
    static let shared = BackgroundSignalsPoller()

    /// 15 minutes - see the file header for the reasoning.
    private let pollInterval: TimeInterval = 15 * 60

    private var timer: Timer?
    private var isChecking = false

    /// Forwarded navigation - set once at launch by whoever owns
    /// `AppShellController` (mirrors `ConsoleComposerController.
    /// onRunInTerminal`'s own forward-don't-own convention). `show(_:)` is
    /// already internal (not private) on `AppShellController`, so these are
    /// plain pass-throughs, not new navigation behavior.
    var onNavigateToUpdates: (() -> Void)?
    var onNavigateToGitHubSync: (() -> Void)?
    var onNavigateToVault: (() -> Void)?
    var onNavigateToBootstrap: (() -> Void)?

    private init() {}

    /// Safe to call every launch. Runs one check shortly after starting (so
    /// the center has real data soon after launch, not just after the first
    /// 15-minute interval elapses) and then on the fixed cadence.
    func start() {
        guard timer == nil else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in self?.checkNow() }
        let t = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in self?.checkNow() }
        t.tolerance = 30
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Exposed (not `private`) so a debug probe / self-test can force one
    /// pass without waiting on the timer, matching
    /// `ShiftNotificationScheduler.poll()`'s own convention.
    func checkNow() {
        guard !isChecking else { return }
        isChecking = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            // Computed once and shared with `checkSetupDrift` below (the
            // Software checklist step reads the exact same per-item
            // outcomes) rather than shelling out to `brew`/`npm` twice for
            // the same catalog in one poll pass.
            let softwareStatuses = DependencyCatalog.items.map { UpdatesSource.check($0).status }
            self.checkToolUpdates(statuses: softwareStatuses)
            self.checkGitHubSync()
            self.checkVault()
            self.checkSetupDrift(softwareStatuses: softwareStatuses)
            DispatchQueue.main.async { self.isChecking = false }
        }
    }

    // MARK: #3 - tool updates

    private func checkToolUpdates(statuses: [DependencyStatus]) {
        let count = statuses.filter { $0.showsUpdateButton }.count
        DispatchQueue.main.async { [weak self] in
            NotificationSources.setToolUpdates(count: count) { self?.onNavigateToUpdates?() }
        }
    }

    // MARK: #4 - GitHub Sync

    private func checkGitHubSync() {
        let count = GitHubSyncCatalog.repos.filter { GitHubSyncSource.check($0).status.showsSyncButton }.count
        DispatchQueue.main.async { [weak self] in
            NotificationSources.setGitHubSync(count: count) { self?.onNavigateToGitHubSync?() }
        }
    }

    // MARK: #5 - Vault attention

    private func checkVault() {
        let snapshot = VaultSource.loadSnapshot()
        let count = snapshot.tools.filter {
            if case .needsAttention = $0.status { return true }
            return false
        }.count
        DispatchQueue.main.async { [weak self] in
            NotificationSources.setVaultAttention(count: count) { self?.onNavigateToVault?() }
        }
    }

    // MARK: #6 - Bootstrap setup drift

    /// Mirrors `BootstrapController`/`AutomationController`'s own
    /// independently-fetched-state pattern (see `SetupStepChecks.swift`'s
    /// header) rather than reaching into either controller's private
    /// fields - this poller keeps its own throwaway copy of the same inputs
    /// those pages already gather, purely to call the identical
    /// `SetupStepChecks` predicates.
    private func checkSetupDrift(softwareStatuses: [DependencyStatus]) {
        let firstmateHome = SetupStepChecks.firstmateHomeDone()

        var dotfilesState: DotfilesRepoState?
        var agentItems: [AgentInstructionsItem] = []
        let repoPath = DotfilesSource.resolvedDotfilesPath()
        if let repoPath {
            dotfilesState = DotfilesSource.repoState(at: repoPath)
            agentItems = DotfilesSource.agentInstructionItems(repoPath: repoPath)
        } else {
            agentItems = DotfilesSource.agentInstructionPaths.map {
                AgentInstructionsItem(label: $0.label, path: $0.path, status: .notLinked)
            }
        }
        let dotfilesDone = SetupStepChecks.dotfilesDone(isLoading: false, repoPath: repoPath, state: dotfilesState)
        let agentDone = SetupStepChecks.agentInstructionsDone(isLoading: false, items: agentItems)
        let softwareDone = SetupStepChecks.softwareDone(isLoading: false, statuses: softwareStatuses)

        let hostCount = HostStore().hosts.count
        let snippetCount = SnippetStore().snippets.count
        let restoreConfigDone = SetupStepChecks.restoreConfigDone(hostCount: hostCount, snippetCount: snippetCount)

        // `restoreConfigDone` has no "not yet checked" state (it's a pure
        // synchronous read), and `firstmateHomeDone` is likewise always a
        // definite bool - only dotfiles/agent/software can be `nil`
        // ("still checking" in a live controller's async flow), which
        // can't happen here since every call above is already synchronous.
        // `?? true` is unreachable in practice but keeps this a total
        // function rather than force-unwrapping.
        let results: [Bool] = [
            firstmateHome,
            dotfilesDone ?? true,
            agentDone ?? true,
            softwareDone ?? true,
            restoreConfigDone,
        ]
        let driftedCount = results.filter { !$0 }.count

        DispatchQueue.main.async { [weak self] in
            NotificationSources.setSetupDrift(count: driftedCount) { self?.onNavigateToBootstrap?() }
        }
    }
}
