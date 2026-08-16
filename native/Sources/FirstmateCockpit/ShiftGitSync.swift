// Manjesh Grand Line - native macOS app.
//
// Git-backed sync for Shift's data (cockpit-shift-git-sync, phase 4 of the
// Shift build - see AGENTS.md's "Shift" section for phases 1-3). The
// captain's decision, already made and not relitigated here: Shift's YAML
// files live in a `personal-tasks/` folder inside the existing
// `manjesh-config` GitHub repo, not a separate dedicated repo.
//
// `fm/grandline-docs-knowledge-foundation` moved that folder under a new
// shared `GrandLineDocs/` parent (alongside `GrandLineDocs/runbooks/`, see
// `DocsRunbookSync.swift`) so every piece of data this app syncs to
// `manjesh-config` lives in one place - `Self.shiftSubpath` is the one
// constant that changed, plus a one-time, self-healing repo-layout migration
// (`migrateRepoLayoutIfNeeded()`) that `git mv`s an old top-level
// `personal-tasks/` into `GrandLineDocs/personal-tasks/` the first time any
// client with this code clones/pulls a repo still in the old layout - it
// never re-fires once any client has pushed the move, since the new location
// then already exists in every later clone.
//
// This reuses the exact shape `DotfilesData.swift` already established for a
// local-clone-plus-shell-`git` workflow (clone / `pull --ff-only` / plain
// `Process`-based shelling out, never a git library), and
// `DocsSyncSource.ghAuthToken()` (`DocsData.swift`) for auth - no second git-
// sync mechanism, no second credential path.
//
// The speed contract: every UI-triggered write already happens synchronously
// to the local YAML file via `ShiftYaml`/`ShiftStore`, with zero git/network
// involvement in that call - see `ShiftStore.persist*` methods. This class
// only owns what happens *after* that local write: a debounced background
// commit+push, and a periodic/launch-time pull. The UI never waits on
// anything in this file.
import Foundation
import Yaml

final class ShiftGitSync {

    enum Status: Equatable {
        case synced
        case localChanges
        case syncing
        case failed(String)
        /// A non-fast-forward pull that genuinely can't be auto-merged - see
        /// `detectAndResolveConflicts()`. `fileCount` is how many of Shift's
        /// three list files have at least one record needing a captain
        /// decision; the actual `ShiftConflictSet` lives in
        /// `pendingConflictSet`, not in this case's payload, so `Status`
        /// itself stays trivially `Equatable`.
        case conflict(fileCount: Int)
    }

    /// `GrandLineDocs/personal-tasks/` inside the local working tree - what
    /// `ShiftStore` actually reads/writes. See `Self.shiftSubpath`.
    let dataRoot: URL
    let workingTree: URL

    /// The one place the repo-relative path to Shift's data lives - every
    /// `git add`/`git status`/`git show <ref>:<path>` call below is scoped to
    /// this, never a second hardcoded literal.
    static let shiftSubpath = "GrandLineDocs/personal-tasks"
    private let remoteURL: String
    private let branch: String
    private let debounceInterval: TimeInterval
    private let periodicPullInterval: TimeInterval

    /// One serial queue owns every git invocation and every status mutation -
    /// the simplest way to make "cancel the pending debounced commit, then
    /// schedule a new one" race-free without a separate lock.
    private let queue: DispatchQueue

    /// Lets `DocsRunbookGitSync` (`DocsRunbookData.swift`) serialize its own
    /// git invocations through this SAME queue against this SAME
    /// `workingTree` - both Shift's `personal-tasks/` and the Runbooks
    /// store's `runbooks/` live in one shared clone of `manjesh-config`
    /// (see this file's own header), and two independent serial queues
    /// issuing `git` subprocesses against the same working tree at once could
    /// race on `.git/index.lock`. Only `.shared`'s queue is meant to be reused
    /// this way - a disposable test instance still gets its own isolated
    /// queue/working tree.
    var sharedQueue: DispatchQueue { queue }

    private(set) var status: Status = .synced
    private var statusHandlers: [(Status) -> Void] = []
    private var pendingCommit: DispatchWorkItem?
    private var pullTimer: Timer?

    /// Set by `detectAndResolveConflicts()` whenever it finds real per-record
    /// conflicts (status flips to `.conflict`) - cleared once
    /// `resolveConflicts(choices:)` successfully applies a resolution. The UI
    /// reads this to build the resolution screen; it is never used to decide
    /// anything on its own (that's always driven by an explicit captain
    /// choice or an already-proven-unambiguous auto-merge).
    private(set) var pendingConflictSet: ShiftConflictSet?

    /// Only ever `true` for `.shared` (the one production instance) - see
    /// `migrateLegacyDataIfNeeded()`. A disposable test instance (this
    /// phase's own `ShiftGitSyncSelfTest`, or any future one) must never touch
    /// the captain's real `~/Library/Application Support/FirstmateCockpit/
    /// shift/` folder just because it happens to still exist on the machine
    /// running the test - that folder isn't scoped to any one instance's
    /// `workingTree`, so without this guard a throwaway test instance would
    /// migrate (and rename away) real local data on its very first run.
    private let migratesLegacyData: Bool

    init(
        workingTree: URL,
        remoteURL: String,
        branch: String = "main",
        debounceInterval: TimeInterval = 3.0,
        periodicPullInterval: TimeInterval = 300,
        queueLabel: String = "com.firstmate.cockpit.shift-git-sync",
        migratesLegacyData: Bool = false
    ) {
        self.workingTree = workingTree
        self.dataRoot = workingTree.appendingPathComponent(Self.shiftSubpath, isDirectory: true)
        self.remoteURL = remoteURL
        self.branch = branch
        self.debounceInterval = debounceInterval
        self.periodicPullInterval = periodicPullInterval
        self.queue = DispatchQueue(label: queueLabel)
        self.migratesLegacyData = migratesLegacyData
    }

    // MARK: Default (production) instance

    /// `~/Library/Application Support/FirstmateCockpit/shift-repo/`,
    /// overridable via `FM_SHIFT_GIT_CLONE_PATH` - same env-var convention as
    /// every other `FM_*` local-state override in this app. Deliberately its
    /// own clone, separate from `DotfilesSource`'s own `~/manjesh/dotfiles`
    /// checkout of the same repo, so editing Shift data can never race or
    /// conflict with whatever branch/state the dotfiles checkout happens to
    /// be in.
    static func resolveDefaultWorkingTree() -> URL {
        if let override = ProcessInfo.processInfo.environment["FM_SHIFT_GIT_CLONE_PATH"], !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath, isDirectory: true)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("FirstmateCockpit", isDirectory: true).appendingPathComponent("shift-repo", isDirectory: true)
    }

    /// `DotfilesSource.cloneURL` (the real `manjesh-config` repo) by default,
    /// overridable via `FM_SHIFT_REMOTE_URL` - what makes it possible to
    /// point a whole test instance of the app at a disposable local bare repo
    /// instead, without touching this file's production default.
    static func resolveDefaultRemoteURL() -> String {
        ProcessInfo.processInfo.environment["FM_SHIFT_REMOTE_URL"] ?? DotfilesSource.cloneURL
    }

    /// Migration only ever runs when the resolved remote is genuinely the
    /// real `manjesh-config` repo - never merely because this is the `.shared`
    /// singleton. That distinction matters because `FM_SHIFT_REMOTE_URL` lets
    /// a real, launched instance of this app run against a disposable test
    /// remote (exactly what this phase's own verification does, and what any
    /// future manual testing should keep doing) while still going through
    /// `.shared` - gating on "is this `.shared`" would have migrated the
    /// captain's real local phase 1-3 Shift data into that test clone the
    /// first time a test run's clone happened to succeed. Confirmed live
    /// this was a real bug, not a hypothetical one, during this phase's own
    /// verification - see the PR description.
    static let shared = ShiftGitSync(
        workingTree: resolveDefaultWorkingTree(), remoteURL: resolveDefaultRemoteURL(),
        migratesLegacyData: resolveDefaultRemoteURL() == DotfilesSource.cloneURL
    )

    // MARK: Status observation

    /// Fires immediately with the current status, then on every change - same
    /// shape as `ThemeManager.observe`/`HostStore.observe`. Callbacks are
    /// always delivered on the main thread.
    func observeStatus(_ handler: @escaping (Status) -> Void) {
        statusHandlers.append(handler)
        let current = status
        DispatchQueue.main.async { handler(current) }
    }

    private func setStatus(_ newStatus: Status) {
        status = newStatus
        let handlers = statusHandlers
        DispatchQueue.main.async { handlers.forEach { $0(newStatus) } }
    }

    // MARK: Startup (production entry point)

    /// Ensures the local clone exists (cloning if needed, migrating any
    /// pre-git-sync local Shift data in on first run), then starts the
    /// periodic pull timer. Entirely asynchronous - safe to call from
    /// `ShiftStore.init()` on the main thread at app launch.
    func start() {
        queue.async { [weak self] in
            guard let self else { return }
            let existedAlready = FileManager.default.fileExists(atPath: self.workingTree.appendingPathComponent(".git").path)
            let ok = self.ensureWorkingTreeNow()
            // A fresh clone already has the latest commit; only a
            // pre-existing checkout (every launch after the first) needs its
            // own explicit launch-time pull.
            if ok, existedAlready, self.pullNow() == .diverged {
                _ = self.detectAndResolveConflicts()
            }
        }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.pullTimer == nil else { return }
            self.pullTimer = Timer.scheduledTimer(withTimeInterval: self.periodicPullInterval, repeats: true) { [weak self] _ in
                self?.queue.async {
                    guard let self else { return }
                    if self.pullNow() == .diverged { _ = self.detectAndResolveConflicts() }
                }
            }
        }
    }

    // MARK: Local-write -> debounced commit+push

    /// Called by `ShiftStore` right after a local YAML write has already
    /// completed synchronously. Flips the pill to "Local changes" immediately
    /// (cheap, main-thread-safe) and (re)schedules a debounced commit+push -
    /// several calls in quick succession collapse into the one commit that
    /// runs `debounceInterval` seconds after the *last* call, never one per
    /// call.
    func markDirty() {
        setStatus(.localChanges)
        queue.async { [weak self] in
            guard let self else { return }
            self.pendingCommit?.cancel()
            let item = DispatchWorkItem { [weak self] in self?.commitAndPushNow() }
            self.pendingCommit = item
            self.queue.asyncAfter(deadline: .now() + self.debounceInterval, execute: item)
        }
    }

    // MARK: Synchronous core (used directly by tests; wrapped above for
    // production callers so nothing here ever runs on the caller's thread)

    /// Clones the repo if the working tree doesn't exist yet; otherwise
    /// leaves an existing checkout as-is (a fresh-forward pull is what
    /// `pullNow()`/the periodic timer are for - this method's job is just
    /// "make sure `dataRoot` is usable"). Migrates legacy pre-git-sync local
    /// data (the old bare `~/Library/Application Support/FirstmateCockpit/
    /// shift/` folder from phases 1-3) into `dataRoot` the first time it
    /// finds real data there and `dataRoot` doesn't have any yet. Never
    /// blocks on network failing: a failed clone still leaves `dataRoot`
    /// creatable so the app can work offline-first, with the failure surfaced
    /// via `status`.
    @discardableResult
    func ensureWorkingTreeNow() -> Bool {
        let fm = FileManager.default
        let gitDir = workingTree.appendingPathComponent(".git")
        if !fm.fileExists(atPath: gitDir.path) {
            setStatus(.syncing)
            // Clones into a fresh sibling temp directory rather than
            // `workingTree` directly, then swaps it into place - not just
            // tidiness. `ShiftStore.init()` calls this on a background queue
            // but constructs its in-memory `ShiftSettings` and (on a brand
            // new root) writes a default `settings.yaml` synchronously on the
            // caller's own thread right afterward; on a machine's very first
            // launch that write can land at `workingTree/personal-tasks`
            // before this clone finishes - confirmed live during this
            // phase's own verification (see the PR description), not
            // hypothetical. Cloning into an unrelated temp path can never
            // collide with that write, and `salvageRacedLocalWrites` below
            // folds any such file into the fresh clone instead of it being
            // silently discarded when the old `workingTree` is finally
            // replaced.
            let tempClone = workingTree.deletingLastPathComponent()
                .appendingPathComponent(".shift-git-sync-clone-\(UUID().uuidString)", isDirectory: true)
            try? fm.createDirectory(at: tempClone.deletingLastPathComponent(), withIntermediateDirectories: true)
            let clone = runGit(["clone", remoteURL, tempClone.path], cwd: nil, authenticated: true)
            guard clone.status == 0 else {
                try? fm.removeItem(at: tempClone)
                try? fm.createDirectory(at: dataRoot, withIntermediateDirectories: true)
                setStatus(.failed("Could not clone \(remoteURL): \(clone.stderr.isEmpty ? "unknown error" : clone.stderr). Working locally offline."))
                return false
            }
            salvageRacedLocalWrites(from: workingTree.appendingPathComponent(Self.shiftSubpath), into: tempClone.appendingPathComponent(Self.shiftSubpath))
            try? fm.removeItem(at: workingTree)
            do {
                try fm.moveItem(at: tempClone, to: workingTree)
            } catch {
                setStatus(.failed("Could not finalize local clone at \(workingTree.path): \(error)"))
                return false
            }
        }
        migrateRepoLayoutIfNeeded()
        try? fm.createDirectory(at: dataRoot, withIntermediateDirectories: true)
        if migratesLegacyData { migrateLegacyDataIfNeeded() }
        let dirty = !uncommittedFiles().isEmpty
        setStatus(dirty ? .localChanges : .synced)
        if dirty { markDirty() }
        return true
    }

    /// Copies any file present at `raced` but not yet at `into` - never
    /// overwriting a file the fresh clone already has, since that's the
    /// authoritative remote content. In practice `raced` is either absent
    /// (the overwhelmingly common case - no write happened during the
    /// clone) or holds nothing but a freshly-defaulted `settings.yaml`, but
    /// this walks every file rather than special-casing that one name, so it
    /// stays correct if that race window is ever hit with real task data in
    /// it too.
    private func salvageRacedLocalWrites(from raced: URL, into cloned: URL) {
        let fm = FileManager.default
        // `enumerator(at:)` can hand back paths resolved through a symlinked
        // ancestor (e.g. macOS's own `/tmp` -> `/private/tmp`) even when
        // `raced` itself was built from the unresolved form - naive prefix
        // stripping (`replacingOccurrences(of: raced.path, with: "")`) can
        // then match a *partial* occurrence of that prefix inside the
        // resolved path instead of the real leading one, corrupting the
        // relative path (confirmed live: it turned `settings.yaml` into
        // `privatesettings.yaml`). Resolving both sides through
        // `resolvingSymlinksInPath` first keeps them on the same footing.
        let racedResolved = (raced.path as NSString).resolvingSymlinksInPath
        guard let enumerator = fm.enumerator(at: raced, includingPropertiesForKeys: [.isRegularFileKey]) else { return }
        for case let file as URL in enumerator {
            guard (try? file.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
            let fileResolved = (file.path as NSString).resolvingSymlinksInPath
            guard fileResolved.hasPrefix(racedResolved + "/") else { continue }
            let relative = String(fileResolved.dropFirst(racedResolved.count + 1))
            let destination = cloned.appendingPathComponent(relative)
            guard !fm.fileExists(atPath: destination.path) else { continue }
            try? fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? fm.copyItem(at: file, to: destination)
        }
    }

    /// Migrates the *repo's own* layout from a top-level `personal-tasks/`
    /// folder (every Shift git-sync task before `fm/grandline-docs-knowledge-
    /// foundation`) to `GrandLineDocs/personal-tasks/` - a real `git mv`,
    /// committed and pushed immediately, not just a local rename. Runs
    /// unconditionally (not gated by `migratesLegacyData`, unlike the local-
    /// folder migration below) since this is about the shape of whatever repo
    /// `remoteURL` points at, not about this one machine's own app-support
    /// folder - a disposable test repo seeded with the old layout needs this
    /// to fire too, which is exactly how this migration's own self-test
    /// verifies it before it ever touches the real `manjesh-config` repo.
    /// Self-limiting: it only does anything when the OLD top-level folder
    /// exists and the NEW location doesn't yet, so once any one client has
    /// pushed the move, every later clone already reflects it and this
    /// becomes a permanent no-op.
    private func migrateRepoLayoutIfNeeded() {
        let fm = FileManager.default
        let oldTop = workingTree.appendingPathComponent("personal-tasks", isDirectory: true)
        guard fm.fileExists(atPath: oldTop.appendingPathComponent("tasks/active.yaml").path) else { return }
        guard !fm.fileExists(atPath: dataRoot.appendingPathComponent("tasks/active.yaml").path) else { return }
        setStatus(.syncing)
        let newParent = workingTree.appendingPathComponent("GrandLineDocs", isDirectory: true)
        try? fm.createDirectory(at: newParent, withIntermediateDirectories: true)
        // A plain `git mv personal-tasks GrandLineDocs/personal-tasks` is
        // only a straight rename when the destination does NOT already exist
        // as a directory - if it does (confirmed live: `ShiftStore.init()`'s
        // own premature-write race, documented above in `ensureWorkingTreeNow`,
        // can salvage a lone `settings.yaml` into this exact new dataRoot
        // path *before* this migration ever runs), `git mv` instead nests the
        // whole source directory one level too deep
        // (`GrandLineDocs/personal-tasks/personal-tasks/...`), silently -
        // reproduced and confirmed against a real disposable repo before this
        // fix, see the PR description. Moving each child of the old
        // directory individually side-steps that ambiguity entirely: each
        // child's destination is a normal file-or-directory rename, never a
        // "does the whole destination already exist" question.
        if fm.fileExists(atPath: dataRoot.path) {
            guard let children = try? fm.contentsOfDirectory(atPath: oldTop.path) else {
                setStatus(.failed("Could not list \(oldTop.path) to migrate it under GrandLineDocs/"))
                return
            }
            for child in children {
                let mv = runGit(["mv", "personal-tasks/\(child)", "\(Self.shiftSubpath)/\(child)"], cwd: workingTree, authenticated: false)
                guard mv.status == 0 else {
                    setStatus(.failed("Could not migrate personal-tasks/\(child) under GrandLineDocs/: \(mv.stderr.isEmpty ? "unknown error" : mv.stderr)"))
                    return
                }
            }
            // `git mv` only ever touched files, so the now-empty
            // `personal-tasks/` directory itself needs no further git
            // action - an empty directory isn't tracked by git at all.
            try? fm.removeItem(at: oldTop)
        } else {
            let mv = runGit(["mv", "personal-tasks", Self.shiftSubpath], cwd: workingTree, authenticated: false)
            guard mv.status == 0 else {
                setStatus(.failed("Could not migrate personal-tasks/ under GrandLineDocs/: \(mv.stderr.isEmpty ? "unknown error" : mv.stderr)"))
                return
            }
        }
        let commit = runGit(["commit", "-m", "Move personal-tasks/ under GrandLineDocs/"], cwd: workingTree, authenticated: false)
        guard commit.status == 0 else {
            setStatus(.failed("Could not commit the GrandLineDocs/ layout migration: \(commit.stderr.isEmpty ? "unknown error" : commit.stderr)"))
            return
        }
        _ = pushOnly()
    }

    /// The old, non-git `ShiftStore.resolveRoot()` default from phases 1-3.
    /// Copied here (not imported from `ShiftStore`) since that file's default
    /// changed - see `ShiftStore.resolveRoot()`'s own doc comment.
    private static func legacyLocalRoot() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("FirstmateCockpit", isDirectory: true).appendingPathComponent("shift", isDirectory: true)
    }

    /// Only ever runs once in practice - guarded by both "legacy data
    /// actually exists" and "the new location doesn't have any yet" (so a
    /// second machine's already-synced `dataRoot` is never clobbered by a
    /// stale local copy). The legacy folder is renamed aside, never deleted,
    /// so a captain can always recover it by hand if this ever guesses wrong.
    private func migrateLegacyDataIfNeeded() {
        let fm = FileManager.default
        let legacy = ShiftGitSync.legacyLocalRoot()
        guard fm.fileExists(atPath: legacy.appendingPathComponent("tasks/active.yaml").path) else { return }
        guard !fm.fileExists(atPath: dataRoot.appendingPathComponent("tasks/active.yaml").path) else { return }
        for entry in ["tasks", "follow-ups", "projects", "notes", "activity", "settings.yaml"] {
            let src = legacy.appendingPathComponent(entry)
            guard fm.fileExists(atPath: src.path) else { continue }
            let dst = dataRoot.appendingPathComponent(entry)
            try? fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? fm.copyItem(at: src, to: dst)
        }
        let migratedMarker = legacy.deletingLastPathComponent().appendingPathComponent("shift.migrated-\(Int(Date().timeIntervalSince1970))")
        try? fm.moveItem(at: legacy, to: migratedMarker)
    }

    /// `git add -A -- GrandLineDocs/personal-tasks && git commit && git push`,
    /// scoped deliberately to just Shift's own subtree so a commit here
    /// can never pick up unrelated content that might exist elsewhere in this
    /// clone. A commit that succeeds locally but fails to push (offline, bad
    /// auth, remote has diverged) leaves `status` at `.failed` while the
    /// local commit - and therefore the local edit - stays fully intact
    /// (`git commit` already happened; only the network step failed).
    @discardableResult
    func commitAndPushNow() -> Bool {
        guard FileManager.default.fileExists(atPath: workingTree.appendingPathComponent(".git").path) else {
            setStatus(.failed("No local git checkout at \(workingTree.path)"))
            return false
        }
        let dirty = uncommittedFiles()
        guard !dirty.isEmpty else {
            // Nothing to commit - a debounced call that lost the race to an
            // identical prior write, or a spurious markDirty(). Still worth
            // trying to push in case an earlier commit never made it out.
            return pushOnly()
        }
        setStatus(.syncing)
        let add = runGit(["add", "-A", "--", Self.shiftSubpath], cwd: workingTree, authenticated: false)
        guard add.status == 0 else {
            setStatus(.failed("git add failed: \(add.stderr)"))
            return false
        }
        let commit = runGit(["commit", "-m", "Shift: \(dirty.count) file(s) updated"], cwd: workingTree, authenticated: false)
        guard commit.status == 0 else {
            setStatus(.failed("git commit failed: \(commit.stderr)"))
            return false
        }
        return pushOnly()
    }

    private func pushOnly() -> Bool {
        let push = runGit(["push", "origin", "HEAD:\(branch)"], cwd: workingTree, authenticated: true)
        guard push.status == 0 else {
            setStatus(.failed("git push failed: \(push.stderr.isEmpty ? "unknown error" : push.stderr)"))
            return false
        }
        setStatus(.synced)
        return true
    }

    enum PullOutcome: Equatable {
        case upToDate
        case fastForwarded
        case diverged
        case failed(String)
    }

    /// `git fetch` + `git merge --ff-only` - deliberately never `--rebase`,
    /// never `-X ours`/`-X theirs`, never a forced reset. A clean fast-forward
    /// applies silently; anything else (diverged history) stops immediately
    /// and reports `.diverged` without touching the working tree or local
    /// commits at all - real conflict-resolution UI is
    /// `cockpit-shift-conflict-handling`, the next queued phase, not this one.
    @discardableResult
    func pullNow() -> PullOutcome {
        guard FileManager.default.fileExists(atPath: workingTree.appendingPathComponent(".git").path) else {
            let outcome = PullOutcome.failed("No local git checkout at \(workingTree.path)")
            setStatus(.failed("git pull failed: no local checkout"))
            return outcome
        }
        setStatus(.syncing)
        let fetch = runGit(["fetch", "origin", branch], cwd: workingTree, authenticated: true)
        guard fetch.status == 0 else {
            let reason = "git fetch failed: \(fetch.stderr.isEmpty ? "unreachable remote" : fetch.stderr)"
            setStatus(.failed(reason))
            return .failed(reason)
        }
        // `headBehindOrEqual`: HEAD is an ancestor of origin/branch (local has
        // nothing origin doesn't - safe to fast-forward, or already equal).
        // `originBehindOrEqual`: origin/branch is an ancestor of HEAD (origin
        // has nothing local doesn't - local is already ahead of or equal to
        // origin). Both true means the two refs are equal.
        let headBehindOrEqual = runGit(["merge-base", "--is-ancestor", "HEAD", "origin/\(branch)"], cwd: workingTree, authenticated: false).status == 0
        let originBehindOrEqual = runGit(["merge-base", "--is-ancestor", "origin/\(branch)", "HEAD"], cwd: workingTree, authenticated: false).status == 0

        guard headBehindOrEqual || originBehindOrEqual else {
            // Neither ref is an ancestor of the other - real divergence.
            // Do NOT force, rebase, or discard anything.
            let reason = "Local and remote history have diverged - manual resolution needed (see the next Shift phase)."
            setStatus(.failed(reason))
            return .diverged
        }

        if originBehindOrEqual {
            // Nothing new to pull. If local has commits origin doesn't yet
            // have, push them; a no-op push (nothing ahead either) is a
            // harmless success.
            if !uncommittedFiles().isEmpty {
                setStatus(.localChanges)
            } else if !pushOnly() {
                return .failed("git push failed after an up-to-date pull")
            }
            return .upToDate
        }

        let merge = runGit(["merge", "--ff-only", "origin/\(branch)"], cwd: workingTree, authenticated: false)
        guard merge.status == 0 else {
            let reason = "git merge --ff-only failed: \(merge.stderr.isEmpty ? "would not fast-forward" : merge.stderr)"
            setStatus(.failed(reason))
            return .failed(reason)
        }
        let dirty = !uncommittedFiles().isEmpty
        setStatus(dirty ? .localChanges : .synced)
        return .fastForwarded
    }

    // MARK: Conflict detection and resolution (cockpit-shift-conflict-handling)

    enum ConflictResolutionOutcome: Equatable {
        case autoMerged(recordCount: Int)
        case needsResolution
        case failed(String)
    }

    /// Called after `pullNow()` reports `.diverged` - never anywhere else,
    /// and never changes what `pullNow()` itself does (see that method's own
    /// doc comment). Commits any still-uncommitted local edit first (so
    /// "local" below means the real current state, not a stale HEAD), then
    /// runs a record-level 3-way merge across the merge-base/local/origin
    /// revisions of Shift's three list files. If every difference turns out
    /// to be unambiguous (the common shape in practice - e.g. two different
    /// tasks added on two machines with no overlapping ids), this applies
    /// and pushes the merge itself with no captain interaction at all,
    /// exactly like a normal sync. Only genuine per-record conflicts (the
    /// same record edited differently on both sides) stop here and wait for
    /// `resolveConflicts(choices:)`.
    @discardableResult
    func detectAndResolveConflicts() -> ConflictResolutionOutcome {
        commitLocalIfDirty()
        guard let base = mergeBaseRef() else {
            let reason = "Could not compute a merge base with origin/\(branch)."
            setStatus(.failed(reason))
            return .failed(reason)
        }
        let set = computeConflictSet(base: base)
        if !set.hasConflicts {
            guard applyConflictResolution(set, choices: [:]) else {
                return .failed("Automatic merge failed - see the sync pill for the reason.")
            }
            return .autoMerged(recordCount: set.autoMergeNotes.count)
        }
        pendingConflictSet = set
        setStatus(.conflict(fileCount: set.affectedFileCount))
        return .needsResolution
    }

    /// Applies the captain's resolution of `pendingConflictSet` - every
    /// conflicting record must have an explicit choice in `choices` (keyed
    /// by record id), or this refuses to write anything. Synchronous core
    /// method (used directly by tests); `resolveConflictsAsync` wraps it for
    /// UI callers.
    @discardableResult
    func resolveConflicts(choices: [String: ShiftConflictChoice]) -> Bool {
        guard let set = pendingConflictSet else { return false }
        guard applyConflictResolution(set, choices: choices) else { return false }
        pendingConflictSet = nil
        return true
    }

    /// UI-facing wrapper - runs on the sync queue (never blocking the
    /// caller's thread) and delivers `completion` on the main thread.
    func resolveConflictsAsync(choices: [String: ShiftConflictChoice], completion: @escaping (Bool) -> Void) {
        queue.async { [weak self] in
            let ok = self?.resolveConflicts(choices: choices) ?? false
            DispatchQueue.main.async { completion(ok) }
        }
    }

    /// Writes the final per-file record lists (the conflict set's own
    /// unambiguous `resolved*` arrays, plus - for every conflict - whichever
    /// side `choices` picked) straight to the working tree, then completes a
    /// real two-parent merge commit via `git merge -s ours --no-commit`,
    /// which stages the merge parents without touching any file, followed by
    /// overwriting the working tree with this method's own resolved content
    /// and committing that. Deliberately never lets git's own line-based
    /// merge algorithm decide file content - two different fields on the
    /// same record edited on different lines could textually merge with no
    /// git-level conflict marker at all, silently producing a record that's
    /// part-local/part-remote in a way neither side chose and nothing here
    /// would notice.
    @discardableResult
    private func applyConflictResolution(_ set: ShiftConflictSet, choices: [String: ShiftConflictChoice]) -> Bool {
        let allConflictIDs = set.taskConflicts.map(\.id) + set.followUpConflicts.map(\.id) + set.projectConflicts.map(\.id)
        guard allConflictIDs.allSatisfy({ choices[$0] != nil }) else {
            setStatus(.failed("Conflict resolution incomplete - not every conflicting record has a choice."))
            return false
        }

        var finalTasks = set.resolvedTasks
        for c in set.taskConflicts {
            if let chosen: ShiftTask = choices[c.id] == .keepLocal ? c.local : c.remote { finalTasks.append(chosen) }
        }
        var finalFollowUps = set.resolvedFollowUps
        for c in set.followUpConflicts {
            if let chosen: ShiftFollowUp = choices[c.id] == .keepLocal ? c.local : c.remote { finalFollowUps.append(chosen) }
        }
        var finalProjects = set.resolvedProjects
        for c in set.projectConflicts {
            if let chosen: ShiftProject = choices[c.id] == .keepLocal ? c.local : c.remote { finalProjects.append(chosen) }
        }

        setStatus(.syncing)
        let mergeStart = runGit(["merge", "-s", "ours", "--no-commit", "origin/\(branch)"], cwd: workingTree, authenticated: false)
        guard mergeStart.status == 0 else {
            setStatus(.failed("Could not start merge: \(mergeStart.stderr.isEmpty ? "unknown error" : mergeStart.stderr)"))
            return false
        }
        do {
            try ShiftYaml.writeList(path: dataRoot.appendingPathComponent("tasks/active.yaml").path, key: "tasks", items: finalTasks.map(ShiftYaml.toYaml))
            try ShiftYaml.writeList(path: dataRoot.appendingPathComponent("follow-ups/follow-ups.yaml").path, key: "follow_ups", items: finalFollowUps.map(ShiftYaml.toYaml))
            try ShiftYaml.writeList(path: dataRoot.appendingPathComponent("projects/projects.yaml").path, key: "projects", items: finalProjects.map(ShiftYaml.toYaml))
        } catch {
            _ = runGit(["merge", "--abort"], cwd: workingTree, authenticated: false)
            setStatus(.failed("Could not write resolved files: \(error)"))
            return false
        }
        let add = runGit(["add", "-A", "--", Self.shiftSubpath], cwd: workingTree, authenticated: false)
        guard add.status == 0 else {
            _ = runGit(["merge", "--abort"], cwd: workingTree, authenticated: false)
            setStatus(.failed("git add failed: \(add.stderr)"))
            return false
        }
        let commit = runGit(["commit", "-m", "Shift: resolve \(set.totalConflictCount) conflict(s) with origin/\(branch)"], cwd: workingTree, authenticated: false)
        guard commit.status == 0 else {
            setStatus(.failed("git commit failed: \(commit.stderr)"))
            return false
        }
        return pushOnly()
    }

    /// Commits (never pushes - the caller is about to attempt a merge that
    /// needs its own commit) any still-uncommitted local edit so HEAD
    /// reflects the true current local state before a 3-way comparison.
    private func commitLocalIfDirty() {
        guard !uncommittedFiles().isEmpty else { return }
        _ = runGit(["add", "-A", "--", Self.shiftSubpath], cwd: workingTree, authenticated: false)
        _ = runGit(["commit", "-m", "Shift: local changes before conflict resolution"], cwd: workingTree, authenticated: false)
    }

    private func mergeBaseRef() -> String? {
        let result = runGit(["merge-base", "HEAD", "origin/\(branch)"], cwd: workingTree, authenticated: false)
        guard result.status == 0, !result.stdout.isEmpty else { return nil }
        return result.stdout
    }

    /// Runs the generic 3-way merge for all three known record kinds against
    /// one merge-base commit. `origin/<branch>` must already be up to date -
    /// true whenever this is called right after `pullNow()`'s own `git
    /// fetch`, which is the only production call path.
    private func computeConflictSet(base: String) -> ShiftConflictSet {
        var set = ShiftConflictSet()

        let taskPath = "\(Self.shiftSubpath)/tasks/active.yaml"
        let taskMerge = ShiftThreeWayMerge.run(
            kind: .task,
            base: loadRecords(ref: base, path: taskPath, key: "tasks", parse: ShiftYaml.task),
            local: loadRecords(ref: "HEAD", path: taskPath, key: "tasks", parse: ShiftYaml.task),
            remote: loadRecords(ref: "origin/\(branch)", path: taskPath, key: "tasks", parse: ShiftYaml.task)
        )
        set.taskConflicts = taskMerge.conflicts
        set.resolvedTasks = taskMerge.resolved

        let followUpPath = "\(Self.shiftSubpath)/follow-ups/follow-ups.yaml"
        let followUpMerge = ShiftThreeWayMerge.run(
            kind: .followUp,
            base: loadRecords(ref: base, path: followUpPath, key: "follow_ups", parse: ShiftYaml.followUp),
            local: loadRecords(ref: "HEAD", path: followUpPath, key: "follow_ups", parse: ShiftYaml.followUp),
            remote: loadRecords(ref: "origin/\(branch)", path: followUpPath, key: "follow_ups", parse: ShiftYaml.followUp)
        )
        set.followUpConflicts = followUpMerge.conflicts
        set.resolvedFollowUps = followUpMerge.resolved

        let projectPath = "\(Self.shiftSubpath)/projects/projects.yaml"
        let projectMerge = ShiftThreeWayMerge.run(
            kind: .project,
            base: loadRecords(ref: base, path: projectPath, key: "projects", parse: ShiftYaml.project),
            local: loadRecords(ref: "HEAD", path: projectPath, key: "projects", parse: ShiftYaml.project),
            remote: loadRecords(ref: "origin/\(branch)", path: projectPath, key: "projects", parse: ShiftYaml.project)
        )
        set.projectConflicts = projectMerge.conflicts
        set.resolvedProjects = projectMerge.resolved

        set.autoMergeNotes = taskMerge.notes + followUpMerge.notes + projectMerge.notes
        return set
    }

    /// `git show <ref>:<path>` - a file absent at that revision (never
    /// created yet on that side) is treated as an empty record list, not an
    /// error.
    private func loadRecords<T>(ref: String, path: String, key: String, parse: (Yaml) -> T?) -> [T] {
        let result = runGit(["show", "\(ref):\(path)"], cwd: workingTree, authenticated: false)
        guard result.status == 0, !result.stdout.isEmpty else { return [] }
        guard let doc = try? Yaml.load(result.stdout) else { return [] }
        let arr = doc.dictionary?[.string(key, quoted: .double)]?.array ?? []
        return arr.compactMap(parse)
    }

    /// `git status --short -- GrandLineDocs/personal-tasks` lines - what decides whether
    /// there's anything worth committing, and what `.localChanges` actually
    /// means (never a timer-driven guess).
    private func uncommittedFiles() -> [String] {
        let result = runGit(["status", "--short", "--", Self.shiftSubpath], cwd: workingTree, authenticated: false)
        return result.stdout.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
    }

    // MARK: Process plumbing

    private struct GitResult {
        let status: Int32
        let stdout: String
        let stderr: String
    }

    /// `authenticated: true` for any operation that talks to the remote
    /// (`clone`/`fetch`/`push`) - injects `DocsSyncSource.ghAuthToken()` as a
    /// Basic-auth `http.extraHeader` (GitHub's own documented shape for
    /// token-based git-over-HTTPS, the same "x-access-token" basic-auth
    /// convention GitHub Actions' own built-in token uses) via
    /// `GIT_CONFIG_COUNT`/`GIT_CONFIG_KEY_0`/`GIT_CONFIG_VALUE_0` environment
    /// variables rather than a `-c` argument, so the token never appears in
    /// `ps`'s argument listing. A local path or `file://` remote (this
    /// phase's disposable-bare-repo test setup) has no such host, so the
    /// header is skipped whenever no token is available or the remote isn't
    /// an `https://` URL - a local remote never needs it.
    private func runGit(_ args: [String], cwd: URL?, authenticated: Bool) -> GitResult {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        proc.arguments = args
        if let cwd { proc.currentDirectoryURL = cwd }
        var env = childEnvironmentDict()
        if authenticated, remoteURL.hasPrefix("https://"), let token = DocsSyncSource.ghAuthToken() {
            let basic = Data("x-access-token:\(token)".utf8).base64EncodedString()
            env["GIT_CONFIG_COUNT"] = "1"
            env["GIT_CONFIG_KEY_0"] = "http.extraheader"
            env["GIT_CONFIG_VALUE_0"] = "Authorization: Basic \(basic)"
        }
        proc.environment = env
        let out = Pipe(), err = Pipe()
        proc.standardOutput = out
        proc.standardError = err
        do {
            try proc.run()
        } catch {
            return GitResult(status: -1, stdout: "", stderr: "\(error)")
        }
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        return GitResult(
            status: proc.terminationStatus,
            stdout: String(data: outData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            stderr: String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        )
    }
}
