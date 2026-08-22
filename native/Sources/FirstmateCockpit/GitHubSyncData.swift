// Manjesh Grand Line - native macOS app.
//
// "GitHub Sync" (fm/grandline-setup-github-sync) - the data side. The captain
// maintains several personal GitHub repos that are forks of upstream tools he
// depends on; this pulls the latest upstream changes into each fork from
// inside the app, rather than by hand per repo. Mirrors `UpdatesData.swift`'s
// own shape exactly (a `check`/`sync` pair returning a status + a captain-
// visible detail string + the real command's raw log, never a fabricated
// result) and `VaultData.swift`'s "own purpose-built run/resolveExecutable/
// RunResult trio" convention (`UpdatesData.swift:133-180`,
// `VaultData.swift:347-410`) - consolidating this app's now sixth near-
// duplicate copy of that helper is still out of scope, per this project's
// AGENTS.md.
//
// Two real GitHub CLI operations, never a hand-rolled fetch/merge/push, for a
// repo GitHub itself does record as a real fork:
//   - `gh api repos/{owner}/{repo}` + `gh api repos/{owner}/{repo}/compare/...`
//     to read the fork's real live fork/parent status and how far behind (or
//     diverged from) upstream it is - never a cached guess.
//   - `gh repo sync {owner}/{repo}` (source defaults to the repo's real
//     parent) to actually sync - fast-forwards the fork's default branch to
//     match upstream, and refuses (nonzero exit, "can't sync because there
//     are diverging changes; use `--force` to overwrite the destination
//     branch" on stderr - confirmed by inspecting the real `gh` binary's own
//     embedded strings, `github.com/cli/cli/v2/pkg/cmd/repo/sync`) rather than
//     silently overwriting real diverged work. `--force` is never passed by
//     this file, anywhere, under any condition - see `syncFork(_:)` below.
//
// `fm/grandline-github-sync-manual-upstream` added a second path for a repo
// GitHub does NOT record as a real fork but the captain still wants tracked
// against a real upstream - `automic-vault` (a private mirror the captain
// pushed by hand, not a GitHub-forked copy - `fork: false`, confirmed live).
// `gh api .../compare` only works within a real GitHub fork network - a cross
// repo compare between two repos with no recorded fork relationship 404s
// (confirmed live: `gh api repos/manjesh-raj/automic-vault/compare/
// manjesh-raj:main...automic-vault:main` -> 404 "Not Found", even though both
// repos share real git history). So a repo with `manualUpstreamOwner`/`Name`
// set (`GitHubSyncRepoConfig.manualUpstreamFullName`) goes through
// `checkManual(_:upstreamFullName:)`/`syncManual(_:upstreamFullName:)`
// instead - a small local scratch git clone (`localCloneDir(for:)`, never the
// captain's own working copy of the repo) used only to run the equivalent
// real git operations by hand: `git remote add/set-url upstream`, `git fetch`
// both sides, `git rev-list --left-right --count` for the real ahead/behind
// counts (the exact same semantics as `compare`'s `ahead_by`/`behind_by`,
// just computed locally instead of via GitHub's API), then - only when
// genuinely a clean fast-forward - `git checkout -B <branch> origin/<branch>`
// + `git merge --ff-only upstream/<branch>` + `git push origin <branch>`.
// `--force`/`--rebase`/`-X ours`/`-X theirs` are never used here either, for
// the identical reason `syncFork(_:)` never uses `gh repo sync --force`: a
// repo with real local-only commits must be refused, never overwritten.

import Foundation

// MARK: - Catalog

struct GitHubSyncRepoConfig {
    let owner: String
    let name: String
    /// A manual upstream declaration (`owner`/`name` of the real upstream to
    /// track) for a repo GitHub itself doesn't record as a fork - see the
    /// file header. `nil` for every repo where GitHub's own fork/parent
    /// metadata is authoritative (the `checkFork`/`syncFork` path).
    var manualUpstreamOwner: String?
    var manualUpstreamName: String?
    var fullName: String { "\(owner)/\(name)" }
    var manualUpstreamFullName: String? {
        guard let owner = manualUpstreamOwner, let name = manualUpstreamName else { return nil }
        return "\(owner)/\(name)"
    }

    init(owner: String, name: String, manualUpstreamOwner: String? = nil, manualUpstreamName: String? = nil) {
        self.owner = owner
        self.name = name
        self.manualUpstreamOwner = manualUpstreamOwner
        self.manualUpstreamName = manualUpstreamName
    }
}

enum GitHubSyncCatalog {
    /// The captain's list of personal forks to keep current with their real
    /// upstream (`kunchenguid/*` for every one of these except
    /// `automic-vault`, which turned out live NOT to be a real GitHub fork -
    /// it's a private mirror the captain pushed by hand. `automic-vault` now
    /// declares a manual upstream (`automic-vault/automic-vault`, the real
    /// upstream per the captain) instead of showing a permanent "Not a Fork"
    /// - see `GitHubSyncStatus.notAFork`, `checkManual`/`syncManual`, and
    /// this task's PR description for its real live sync state as found).
    /// Confirmed live via `gh api repos/manjesh-raj/<repo>` before this
    /// catalog was written, not assumed from the repo name alone.
    static let repos: [GitHubSyncRepoConfig] = [
        .init(owner: "manjesh-raj", name: "chrome-devtools-axi"),
        .init(owner: "manjesh-raj", name: "treehouse"),
        .init(owner: "manjesh-raj", name: "tasks-axi"),
        .init(owner: "manjesh-raj", name: "gh-axi"),
        .init(owner: "manjesh-raj", name: "no-mistakes"),
        .init(owner: "manjesh-raj", name: "lavish-axi"),
        .init(owner: "manjesh-raj", name: "automic-vault", manualUpstreamOwner: "automic-vault", manualUpstreamName: "automic-vault"),
        .init(owner: "manjesh-raj", name: "quota-axi"),
    ]
}

// MARK: - Outcomes

enum GitHubSyncStatus: Equatable {
    case unknown
    case checking
    case inSync
    /// Behind upstream by N commits, no diverged local commits - safe to
    /// fast-forward.
    case behind(Int)
    /// The fork has commits upstream doesn't (`compare`'s `behind_by` > 0) -
    /// `gh repo sync` will refuse a plain fast-forward here. Never synced by
    /// this app; see the file header.
    case diverged(localOnly: Int, upstreamAhead: Int)
    /// A real, confirmed non-fork (`.fork == false`) with no configured
    /// `manualUpstreamFullName` either - nothing to sync, and no way to know
    /// what it should track. A repo with a manual upstream configured (e.g.
    /// `automic-vault`, see `GitHubSyncCatalog.repos`) never reaches this
    /// case even though it's also `.fork == false` - it goes through
    /// `checkManual`/`syncManual` instead and reports real `.inSync`/
    /// `.behind`/`.diverged` status like any other tracked repo.
    case notAFork
    case checkFailed
    case syncing
    /// A real `gh repo sync` failure that ISN'T a divergence refusal (network,
    /// auth, host down, etc.) - distinct from `diverged` so the UI can tell
    /// "left alone on purpose" apart from "genuinely failed."
    case syncFailed

    /// Sync is only ever offered when there's actually something to pull (or
    /// a previous sync attempt failed and deserves a retry) - mirrors
    /// `DependencyStatus.showsUpdateButton`'s exact rule: never shown once
    /// already `.inSync` (nothing to do), never shown for `.diverged`/
    /// `.notAFork` (nothing safe/possible to do). This is also what
    /// `GitHubSyncController.syncAll()` filters on, so "Sync all" only ever
    /// touches a repo genuinely behind upstream - never one already in sync.
    var showsSyncButton: Bool {
        switch self {
        case .behind, .syncFailed: return true
        case .unknown, .checking, .inSync, .diverged, .notAFork, .checkFailed, .syncing: return false
        }
    }

    var isDiverged: Bool {
        if case .diverged = self { return true }
        return false
    }
}

struct GitHubSyncCheckOutcome {
    let status: GitHubSyncStatus
    let upstreamFullName: String?
    /// Ready-to-render one-line summary, crafted by `check(_:)` itself (e.g.
    /// "12 commits behind kunchenguid/gh-axi") rather than re-derived
    /// generically - mirrors `CheckOutcome.detail` (`UpdatesData.swift:114-118`).
    let detail: String
    /// Raw `gh api` output, shown in the row's expandable log - same "every
    /// action's real command output should be visible" principle as
    /// `CheckOutcome.log`.
    let log: String
}

struct GitHubSyncSyncOutcome {
    let ok: Bool
    /// `true` only when the failure is a genuine, confirmed divergence
    /// refusal (matched against `gh`'s own real error text) - the caller uses
    /// this to report `needs-decision`-style, not a generic failure.
    let refusedDiverged: Bool
    let detail: String
    let log: String
}

// MARK: - Process plumbing

enum GitHubSyncSource {

    // GL-15: `resolveExecutable`, `RunResult` and the runner itself all come
    // from `Subprocess` now. The previous local copies drained stdout to EOF
    // before touching stderr, which deadlocks on a `gh`/`git` failure large
    // enough to fill the 64KB stderr buffer - realistic here, since git's
    // "advice" output is exactly what a rejected push emits.

    private static func resolveExecutable(_ name: String) -> String? {
        Subprocess.resolveExecutable(name)
    }

    private typealias RunResult = SubprocessResult

    /// `gh api` calls are network round trips against a rate-limited API; 90s
    /// is generous for one, and a bound where there was none before.
    private static let apiTimeout: TimeInterval = 90

    private static func run(_ executable: String, _ args: [String]) -> RunResult {
        Subprocess.run(executable: executable, arguments: args,
                       timeout: apiTimeout, log: AppLog.network)
    }

    // MARK: Check

    private struct RepoInfo {
        let isFork: Bool
        let parentFullName: String?
        let defaultBranch: String
    }

    private static func parseRepoInfo(_ json: String) -> RepoInfo? {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let defaultBranch = obj["default_branch"] as? String
        else { return nil }
        let isFork = (obj["fork"] as? Bool) ?? false
        let parent = obj["parent"] as? [String: Any]
        let parentFullName = parent?["full_name"] as? String
        return RepoInfo(isFork: isFork, parentFullName: parentFullName, defaultBranch: defaultBranch)
    }

    private static func parseCompare(_ json: String) -> (aheadBy: Int, behindBy: Int)? {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let aheadBy = obj["ahead_by"] as? Int,
              let behindBy = obj["behind_by"] as? Int
        else { return nil }
        return (aheadBy, behindBy)
    }

    /// The one entry point the controller calls - dispatches to the manual-
    /// upstream path (`checkManual`) when the repo declares one, otherwise the
    /// real-fork path (`checkFork`). See the file header for why these need
    /// to be two different mechanisms.
    static func check(_ repo: GitHubSyncRepoConfig) -> GitHubSyncCheckOutcome {
        if let upstream = repo.manualUpstreamFullName {
            // GL-35, and only on the path that actually keeps clones around.
            pruneOrphanedManualClones()
            return checkManual(repo, upstreamFullName: upstream)
        }
        return checkFork(repo)
    }

    /// Live check, no caching: fork/parent status via `gh api repos/{full}`,
    /// then how far behind (or diverged from) upstream via `gh api
    /// repos/{full}/compare/{owner}:{branch}...{parentOwner}:{branch}` -
    /// `compare`'s `ahead_by` (commits upstream has this fork doesn't - how
    /// far behind the fork is) and `behind_by` (commits this fork has upstream
    /// doesn't - real diverged local commits) are exactly what `gh repo sync`
    /// itself needs `behind_by == 0` for to fast-forward safely. Confirmed
    /// live against all 8 catalog repos before writing this (see PR
    /// description) - every one of them reported `behind_by: 0`.
    private static func checkFork(_ repo: GitHubSyncRepoConfig) -> GitHubSyncCheckOutcome {
        guard let gh = resolveExecutable("gh") else {
            return GitHubSyncCheckOutcome(status: .checkFailed, upstreamFullName: nil, detail: "'gh' not found on PATH", log: "")
        }
        let infoResult = run(gh, ["api", "repos/\(repo.fullName)"])
        guard infoResult.status == 0, let info = parseRepoInfo(infoResult.stdout) else {
            return GitHubSyncCheckOutcome(status: .checkFailed, upstreamFullName: nil, detail: "gh api repos/\(repo.fullName) failed", log: infoResult.combinedLog)
        }
        guard info.isFork, let parentFullName = info.parentFullName, let parentOwner = parentFullName.split(separator: "/").first else {
            return GitHubSyncCheckOutcome(status: .notAFork, upstreamFullName: nil, detail: "\(repo.fullName) is not a GitHub fork - nothing to sync", log: infoResult.combinedLog)
        }
        let branch = info.defaultBranch
        let compareResult = run(gh, ["api", "repos/\(repo.fullName)/compare/\(repo.owner):\(branch)...\(parentOwner):\(branch)"])
        let log = [infoResult.combinedLog, compareResult.combinedLog].filter { !$0.isEmpty }.joined(separator: "\n")
        guard compareResult.status == 0, let compare = parseCompare(compareResult.stdout) else {
            return GitHubSyncCheckOutcome(status: .checkFailed, upstreamFullName: parentFullName, detail: "Could not compare against \(parentFullName)", log: log)
        }
        if compare.behindBy > 0 {
            return GitHubSyncCheckOutcome(
                status: .diverged(localOnly: compare.behindBy, upstreamAhead: compare.aheadBy),
                upstreamFullName: parentFullName,
                detail: "Diverged - \(compare.behindBy) commit(s) unique to this fork, \(compare.aheadBy) behind \(parentFullName)",
                log: log
            )
        }
        if compare.aheadBy > 0 {
            return GitHubSyncCheckOutcome(
                status: .behind(compare.aheadBy),
                upstreamFullName: parentFullName,
                detail: "\(compare.aheadBy) commit(s) behind \(parentFullName)",
                log: log
            )
        }
        return GitHubSyncCheckOutcome(status: .inSync, upstreamFullName: parentFullName, detail: "In sync with \(parentFullName)", log: log)
    }

    // MARK: Sync

    /// The one entry point the controller calls - dispatches to the manual-
    /// upstream path (`syncManual`) when the repo declares one, otherwise the
    /// real-fork path (`syncFork`). Same "never force" guarantee either way.
    static func sync(_ repo: GitHubSyncRepoConfig) -> GitHubSyncSyncOutcome {
        if let upstream = repo.manualUpstreamFullName {
            return syncManual(repo, upstreamFullName: upstream)
        }
        return syncFork(repo)
    }

    /// `gh repo sync {owner}/{repo}` - source defaults to the repo's real
    /// parent (no `--source` override needed, since every catalog entry's
    /// upstream is its own real GitHub-recorded parent). Fast-forward only;
    /// `--force` is never passed, full stop - a refusal is reported back as
    /// `refusedDiverged`, never retried with force. See the file header for
    /// the exact refusal string this matches against, confirmed against the
    /// real `gh` binary shipped on this machine (`gh version 2.97.0`).
    private static func syncFork(_ repo: GitHubSyncRepoConfig) -> GitHubSyncSyncOutcome {
        guard let gh = resolveExecutable("gh") else {
            return GitHubSyncSyncOutcome(ok: false, refusedDiverged: false, detail: "'gh' not found on PATH", log: "")
        }
        let result = run(gh, ["repo", "sync", repo.fullName])
        if result.status == 0 {
            return GitHubSyncSyncOutcome(ok: true, refusedDiverged: false, detail: "Synced \(repo.fullName) with upstream", log: result.combinedLog)
        }
        let lower = result.combinedLog.lowercased()
        let refused = lower.contains("diverging changes") || lower.contains("fast forward") || lower.contains("fast-forward")
        let detail = refused
            ? "Refused - \(repo.fullName) has diverged from upstream with commits of its own. Left untouched; never force-synced."
            : "gh repo sync \(repo.fullName) failed"
        return GitHubSyncSyncOutcome(ok: false, refusedDiverged: refused, detail: detail, log: result.combinedLog)
    }

    // MARK: Manual upstream (repos GitHub doesn't record as a real fork)

    private struct RepoDefaultBranch {
        let branch: String
        let log: String
    }

    /// `gh api repos/{full}`'s `default_branch` only - works regardless of
    /// fork status, so this is used for both origin and the manual upstream.
    private static func fetchDefaultBranch(_ fullName: String) -> RepoDefaultBranch? {
        guard let gh = resolveExecutable("gh") else { return nil }
        let result = run(gh, ["api", "repos/\(fullName)"])
        guard result.status == 0, let info = parseRepoInfo(result.stdout) else { return nil }
        return RepoDefaultBranch(branch: info.defaultBranch, log: result.combinedLog)
    }

    /// `~/Library/Application Support/FirstmateCockpit/github-sync-repos/`,
    /// overridable via `FM_GITHUB_SYNC_CLONE_ROOT` - same env-var convention
    /// as every other `FM_*` local-state override in this app
    /// (`ShiftGitSync.resolveDefaultWorkingTree`'s `FM_SHIFT_GIT_CLONE_PATH`).
    private static func defaultCloneRoot() -> URL {
        if let override = ProcessInfo.processInfo.environment["FM_GITHUB_SYNC_CLONE_ROOT"], !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath, isDirectory: true)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("FirstmateCockpit", isDirectory: true).appendingPathComponent("github-sync-repos", isDirectory: true)
    }

    /// A small per-repo scratch clone used only to compute real ahead/behind
    /// counts and, when safe, perform the actual fast-forward - never the
    /// captain's own working copy of the repo, never shown or offered as one.
    private static func localCloneDir(for repo: GitHubSyncRepoConfig) -> URL {
        defaultCloneRoot().appendingPathComponent("\(repo.owner)__\(repo.name)", isDirectory: true)
    }

    private typealias GitResult = SubprocessResult

    /// `authenticated: true` for any operation that talks to a remote
    /// (`clone`/`fetch`/`push`). GL-15 moved the token injection itself into
    /// `Subprocess.gitAuthEnvironment` - the single copy of what four files
    /// each carried verbatim; see its doc comment for why the token travels as
    /// a `GIT_CONFIG_*` environment variable rather than a `-c` argument.
    ///
    /// The remote passed to it is `https://github.com` rather than the repo's
    /// own URL because this file only ever talks to github.com (its catalog is
    /// a fixed list of the captain's own forks). That keeps the header shape
    /// identical to before, while inheriting the "never authenticate a local or
    /// `file://` remote" rule the shared helper enforces.
    private static func runGit(_ args: [String], cwd: URL?, authenticated: Bool) -> GitResult {
        Subprocess.git(args, cwd: cwd,
                       authenticateFor: authenticated ? "https://github.com" : nil,
                       timeout: gitTimeout)
    }

    /// A `git clone`/`fetch` of a real repository over a slow link is minutes,
    /// not seconds - this is deliberately far above `Subprocess.defaultTimeout`
    /// and still a bound.
    private static let gitTimeout: TimeInterval = 600

    /// Clones `originURL` into `localCloneDir(for:)` if it isn't there yet -
    /// a no-op on every later check/sync. Never re-clones an existing
    /// checkout; `checkManual`/`syncManual` always re-fetch fresh instead.
    private static func ensureManualClone(_ repo: GitHubSyncRepoConfig, originURL: String) -> (ok: Bool, log: String) {
        let fm = FileManager.default
        let dir = localCloneDir(for: repo)
        if fm.fileExists(atPath: dir.appendingPathComponent(".git").path) {
            return (true, "")
        }
        try? fm.createDirectory(at: dir.deletingLastPathComponent(), withIntermediateDirectories: true)
        // GL-35: `--single-branch --no-tags` rather than a full clone. This
        // scratch checkout only ever needs the default branch's history (to
        // count ahead/behind against `upstream`, fast-forward, and push it
        // back), so every other branch and every tag was pure disk.
        //
        // `--filter=blob:none` was considered and deliberately *not* used: a
        // blobless partial clone would have to lazily re-fetch the blobs for
        // the commits `syncManual` pushes to `origin`, turning a local
        // fast-forward-and-push into an unpredictable network operation on a
        // path whose whole point is not to surprise the captain. Skipping
        // branches is free; skipping blobs is not.
        let clone = runGit(["clone", "--single-branch", "--no-tags", originURL, dir.path], cwd: nil, authenticated: true)
        guard clone.status == 0 else {
            try? fm.removeItem(at: dir)
            return (false, clone.combinedLog.isEmpty ? "git clone failed" : clone.combinedLog)
        }
        return (true, clone.combinedLog)
    }

    /// GL-35: remove scratch clones for repos this catalog no longer lists.
    ///
    /// `ensureManualClone` never re-clones, which is right, but nothing ever
    /// removed a clone either - so a repo dropped from `GitHubSyncCatalog`
    /// (or renamed) left its whole checkout on disk permanently, with no UI
    /// anywhere that even mentioned it. Called from `check` so it costs one
    /// directory listing on a path that is already doing network work.
    static func pruneOrphanedManualClones() {
        let fm = FileManager.default
        let root = defaultCloneRoot()
        guard let existing = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil,
                                                         options: [.skipsHiddenFiles]) else { return }
        let live = Set(GitHubSyncCatalog.repos.map { localCloneDir(for: $0).lastPathComponent })
        for dir in existing where !live.contains(dir.lastPathComponent) {
            do {
                try fm.removeItem(at: dir)
                AppLog.gitSync.info("pruned an orphaned GitHub Sync scratch clone")
            } catch {
                AppLog.gitSync.error("could not prune \(dir.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Points the clone's `upstream` remote at `upstreamURL` - adds it if
    /// missing, updates it in place if it's already there (e.g. pointing at a
    /// stale URL from before this task).
    private static func ensureUpstreamRemote(dir: URL, upstreamURL: String) {
        let setURL = runGit(["remote", "set-url", "upstream", upstreamURL], cwd: dir, authenticated: false)
        if setURL.status != 0 {
            _ = runGit(["remote", "add", "upstream", upstreamURL], cwd: dir, authenticated: false)
        }
    }

    private struct AheadBehindCounts {
        /// Commits `originRef` has that `upstreamRef` doesn't - real
        /// diverged, local-only commits. `gh repo sync`/`compare`'s
        /// `behind_by` equivalent.
        let localOnly: Int
        /// Commits `upstreamRef` has that `originRef` doesn't - how far
        /// behind upstream this repo is. `compare`'s `ahead_by` equivalent.
        let upstreamAhead: Int
        let log: String
    }

    /// `git rev-list --left-right --count originRef...upstreamRef` - the
    /// exact same ahead/behind semantics `parseCompare` reads off GitHub's
    /// own `compare` API response, just computed locally against two fetched
    /// remote-tracking refs instead.
    private static func aheadBehindCounts(dir: URL, originRef: String, upstreamRef: String) -> AheadBehindCounts? {
        let result = runGit(["rev-list", "--left-right", "--count", "\(originRef)...\(upstreamRef)"], cwd: dir, authenticated: false)
        guard result.status == 0 else { return nil }
        let parts = result.stdout.split(whereSeparator: { $0 == "\t" || $0 == " " }).compactMap { Int($0) }
        guard parts.count == 2 else { return nil }
        return AheadBehindCounts(localOnly: parts[0], upstreamAhead: parts[1], log: result.combinedLog)
    }

    /// Manual-upstream check: no GitHub-recorded fork relationship to lean on
    /// (see the file header for why `compare` 404s here), so this maintains a
    /// small local scratch clone instead, purely to fetch both remotes and
    /// compute real ahead/behind counts via `git rev-list --left-right
    /// --count` - never a cached guess, same "live check, no caching"
    /// guarantee as `checkFork`.
    private static func checkManual(_ repo: GitHubSyncRepoConfig, upstreamFullName: String) -> GitHubSyncCheckOutcome {
        guard resolveExecutable("gh") != nil else {
            return GitHubSyncCheckOutcome(status: .checkFailed, upstreamFullName: upstreamFullName, detail: "'gh' not found on PATH", log: "")
        }
        guard let originInfo = fetchDefaultBranch(repo.fullName) else {
            return GitHubSyncCheckOutcome(status: .checkFailed, upstreamFullName: upstreamFullName, detail: "gh api repos/\(repo.fullName) failed", log: "")
        }
        guard let upstreamInfo = fetchDefaultBranch(upstreamFullName) else {
            return GitHubSyncCheckOutcome(status: .checkFailed, upstreamFullName: upstreamFullName, detail: "gh api repos/\(upstreamFullName) failed", log: originInfo.log)
        }
        var logParts = [originInfo.log, upstreamInfo.log]

        let originURL = "https://github.com/\(repo.fullName).git"
        let upstreamURL = "https://github.com/\(upstreamFullName).git"
        let clone = ensureManualClone(repo, originURL: originURL)
        logParts.append(clone.log)
        guard clone.ok else {
            return GitHubSyncCheckOutcome(status: .checkFailed, upstreamFullName: upstreamFullName, detail: "Could not clone \(repo.fullName) locally: \(clone.log)", log: logParts.filter { !$0.isEmpty }.joined(separator: "\n"))
        }
        let dir = localCloneDir(for: repo)
        ensureUpstreamRemote(dir: dir, upstreamURL: upstreamURL)

        let fetchOrigin = runGit(["fetch", "origin", originInfo.branch], cwd: dir, authenticated: true)
        logParts.append(fetchOrigin.combinedLog)
        guard fetchOrigin.status == 0 else {
            return GitHubSyncCheckOutcome(status: .checkFailed, upstreamFullName: upstreamFullName, detail: "git fetch origin failed", log: logParts.filter { !$0.isEmpty }.joined(separator: "\n"))
        }
        let fetchUpstream = runGit(["fetch", "upstream", upstreamInfo.branch], cwd: dir, authenticated: true)
        logParts.append(fetchUpstream.combinedLog)
        guard fetchUpstream.status == 0 else {
            return GitHubSyncCheckOutcome(status: .checkFailed, upstreamFullName: upstreamFullName, detail: "git fetch upstream failed", log: logParts.filter { !$0.isEmpty }.joined(separator: "\n"))
        }
        guard let counts = aheadBehindCounts(dir: dir, originRef: "origin/\(originInfo.branch)", upstreamRef: "upstream/\(upstreamInfo.branch)") else {
            return GitHubSyncCheckOutcome(status: .checkFailed, upstreamFullName: upstreamFullName, detail: "Could not compare against \(upstreamFullName)", log: logParts.filter { !$0.isEmpty }.joined(separator: "\n"))
        }
        logParts.append(counts.log)
        let log = logParts.filter { !$0.isEmpty }.joined(separator: "\n")

        if counts.localOnly > 0 {
            return GitHubSyncCheckOutcome(
                status: .diverged(localOnly: counts.localOnly, upstreamAhead: counts.upstreamAhead),
                upstreamFullName: upstreamFullName,
                detail: "Diverged - \(counts.localOnly) commit(s) unique to this fork, \(counts.upstreamAhead) behind \(upstreamFullName)",
                log: log
            )
        }
        if counts.upstreamAhead > 0 {
            return GitHubSyncCheckOutcome(status: .behind(counts.upstreamAhead), upstreamFullName: upstreamFullName, detail: "\(counts.upstreamAhead) commit(s) behind \(upstreamFullName)", log: log)
        }
        return GitHubSyncCheckOutcome(status: .inSync, upstreamFullName: upstreamFullName, detail: "In sync with \(upstreamFullName)", log: log)
    }

    /// Manual-upstream sync: fetches both remotes, re-derives ahead/behind
    /// counts fresh (never trusts a possibly-stale prior Check result for a
    /// decision this consequential), refuses outright - no local branch
    /// touched, no push attempted - the moment there's even one local-only
    /// commit, and otherwise fast-forwards the local scratch clone's default
    /// branch onto upstream's and pushes that to `origin`. `--force`,
    /// `--rebase`, and `-X ours`/`-X theirs` are never used, full stop.
    private static func syncManual(_ repo: GitHubSyncRepoConfig, upstreamFullName: String) -> GitHubSyncSyncOutcome {
        guard resolveExecutable("gh") != nil else {
            return GitHubSyncSyncOutcome(ok: false, refusedDiverged: false, detail: "'gh' not found on PATH", log: "")
        }
        guard let originInfo = fetchDefaultBranch(repo.fullName) else {
            return GitHubSyncSyncOutcome(ok: false, refusedDiverged: false, detail: "gh api repos/\(repo.fullName) failed", log: "")
        }
        guard let upstreamInfo = fetchDefaultBranch(upstreamFullName) else {
            return GitHubSyncSyncOutcome(ok: false, refusedDiverged: false, detail: "gh api repos/\(upstreamFullName) failed", log: originInfo.log)
        }
        let originURL = "https://github.com/\(repo.fullName).git"
        let upstreamURL = "https://github.com/\(upstreamFullName).git"
        let clone = ensureManualClone(repo, originURL: originURL)
        guard clone.ok else {
            return GitHubSyncSyncOutcome(ok: false, refusedDiverged: false, detail: "Could not clone \(repo.fullName) locally: \(clone.log)", log: clone.log)
        }
        let dir = localCloneDir(for: repo)
        ensureUpstreamRemote(dir: dir, upstreamURL: upstreamURL)

        var log: [String] = [clone.log]
        let fetchOrigin = runGit(["fetch", "origin", originInfo.branch], cwd: dir, authenticated: true)
        log.append(fetchOrigin.combinedLog)
        guard fetchOrigin.status == 0 else {
            return GitHubSyncSyncOutcome(ok: false, refusedDiverged: false, detail: "git fetch origin failed", log: log.filter { !$0.isEmpty }.joined(separator: "\n"))
        }
        let fetchUpstream = runGit(["fetch", "upstream", upstreamInfo.branch], cwd: dir, authenticated: true)
        log.append(fetchUpstream.combinedLog)
        guard fetchUpstream.status == 0 else {
            return GitHubSyncSyncOutcome(ok: false, refusedDiverged: false, detail: "git fetch upstream failed", log: log.filter { !$0.isEmpty }.joined(separator: "\n"))
        }

        guard let counts = aheadBehindCounts(dir: dir, originRef: "origin/\(originInfo.branch)", upstreamRef: "upstream/\(upstreamInfo.branch)") else {
            return GitHubSyncSyncOutcome(ok: false, refusedDiverged: false, detail: "Could not compare against \(upstreamFullName)", log: log.filter { !$0.isEmpty }.joined(separator: "\n"))
        }
        log.append(counts.log)
        guard counts.localOnly == 0 else {
            return GitHubSyncSyncOutcome(
                ok: false, refusedDiverged: true,
                detail: "Refused - \(repo.fullName) has \(counts.localOnly) commit(s) of its own that \(upstreamFullName) doesn't have. Left untouched; never force-synced.",
                log: log.filter { !$0.isEmpty }.joined(separator: "\n")
            )
        }
        guard counts.upstreamAhead > 0 else {
            return GitHubSyncSyncOutcome(ok: true, refusedDiverged: false, detail: "Already in sync with \(upstreamFullName)", log: log.filter { !$0.isEmpty }.joined(separator: "\n"))
        }

        // The scratch clone's local branch is reset to match origin's real
        // current tip first - this clone is dedicated sync scratch space,
        // never the captain's own working copy, so this can never discard
        // anything the captain hasn't already pushed to `origin` themselves.
        let checkout = runGit(["checkout", "-B", originInfo.branch, "origin/\(originInfo.branch)"], cwd: dir, authenticated: false)
        log.append(checkout.combinedLog)
        guard checkout.status == 0 else {
            return GitHubSyncSyncOutcome(ok: false, refusedDiverged: false, detail: "git checkout failed", log: log.filter { !$0.isEmpty }.joined(separator: "\n"))
        }
        let merge = runGit(["merge", "--ff-only", "upstream/\(upstreamInfo.branch)"], cwd: dir, authenticated: false)
        log.append(merge.combinedLog)
        guard merge.status == 0 else {
            // Should be unreachable given the counts check above (both were
            // computed moments apart against the same fetched refs), but a
            // merge refusal is still never forced past, regardless of cause.
            return GitHubSyncSyncOutcome(
                ok: false, refusedDiverged: true,
                detail: "git merge --ff-only refused - \(repo.fullName) is not a clean fast-forward of \(upstreamFullName). Left untouched.",
                log: log.filter { !$0.isEmpty }.joined(separator: "\n")
            )
        }
        let push = runGit(["push", "origin", "\(originInfo.branch):\(originInfo.branch)"], cwd: dir, authenticated: true)
        log.append(push.combinedLog)
        guard push.status == 0 else {
            return GitHubSyncSyncOutcome(ok: false, refusedDiverged: false, detail: "git push origin failed", log: log.filter { !$0.isEmpty }.joined(separator: "\n"))
        }
        return GitHubSyncSyncOutcome(ok: true, refusedDiverged: false, detail: "Fast-forwarded \(repo.fullName) to \(upstreamFullName) and pushed to origin", log: log.filter { !$0.isEmpty }.joined(separator: "\n"))
    }
}
