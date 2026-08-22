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

    // MARK: GL-03 - the `isChecking` latch must not be a one-way door
    //
    // Every check below is an unbounded subprocess spawn (Updates ~31,
    // GitHub Sync ~21 including `git fetch`/`git clone`, Vault's `av list`
    // which has a documented prior real hang, plus a dotfiles `git fetch`).
    // `isChecking` was set at the start of a pass and cleared only after all
    // four completed - so one hung child meant every future tick returned on
    // the `guard !isChecking` line and tool-update, fork-drift, vault and
    // setup-drift notifications went dark for the rest of the session, with
    // no UI or log signal at all.
    //
    // The real fix is per-check timeouts through the shared subprocess runner
    // (phase 2, GL-02/GL-15). Until that lands, this is the stopgap the review
    // asked for: a wall-clock watchdog that lets a *new* pass start once the
    // previous one has clearly wedged, plus a "last completed" timestamp so
    // the failure is at least observable instead of invisible.
    //
    // Note what this deliberately does NOT do: it does not kill the wedged
    // pass (there is no handle to its children yet - that is the phase-2
    // runner's job). A superseded pass may still be running and may still
    // publish its own results later; every one of those publishes is an
    // idempotent `NotificationSources.set*` call with a freshly-computed
    // count, so a late writer is stale-but-valid, never corrupting.

    /// How long a single pass may run before a new tick is allowed to start
    /// anyway. Generous on purpose: a genuinely slow (not hung) pass on a
    /// cold `brew`/`gh` cache can legitimately take minutes, and starting a
    /// second pass alongside it costs real process spawns.
    private let passWatchdog: TimeInterval = 5 * 60

    /// When the currently-running pass started, `nil` if none is running.
    private var passStartedAt: Date?

    /// Identifies the pass that currently "owns" the latch. A pass the
    /// watchdog superseded still finishes eventually and still reaches the
    /// completion block - without this it would clear the latch out from under
    /// the newer pass that replaced it, letting a third pass start alongside
    /// the second. Only the pass whose id still matches may clear it.
    private var currentPassID = 0

    /// When a pass last ran all four checks to completion. `nil` means no
    /// pass has ever finished - surfaced for diagnostics (F1/GL-11 will give
    /// this a real home; for now it is readable and logged).
    private(set) var lastCompletedPassAt: Date?

    /// How many passes were force-superseded by the watchdog. Non-zero means
    /// something in the check path is hanging and deserves attention.
    private(set) var supersededPassCount = 0

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
        if isChecking {
            guard let started = passStartedAt,
                  Date().timeIntervalSince(started) > passWatchdog else { return }
            supersededPassCount += 1
            NSLog("[cockpit] background signals: pass started \(Int(Date().timeIntervalSince(started)))s ago has not finished - "
                + "starting a new one anyway (GL-03 watchdog, \(supersededPassCount) so far this session).")
        }
        isChecking = true
        passStartedAt = Date()
        currentPassID += 1
        let passID = currentPassID
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
            DispatchQueue.main.async {
                // Every completed pass counts as a real completion for
                // diagnostics, even a superseded one - it did finish.
                self.lastCompletedPassAt = Date()
                // ...but only the pass that still owns the latch may release
                // it. See `currentPassID`.
                guard passID == self.currentPassID else { return }
                self.isChecking = false
                self.passStartedAt = nil
            }
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
