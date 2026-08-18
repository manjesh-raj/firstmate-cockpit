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
// Two real GitHub CLI operations, never a hand-rolled fetch/merge/push:
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
//     this file, anywhere, under any condition - see `sync(_:)` below.

import Foundation

// MARK: - Catalog

struct GitHubSyncRepoConfig {
    let owner: String
    let name: String
    var fullName: String { "\(owner)/\(name)" }
}

enum GitHubSyncCatalog {
    /// The captain's list of personal forks to keep current with their real
    /// upstream (`kunchenguid/*` for every one of these except
    /// `automic-vault`, which turned out live NOT to be a fork at all - see
    /// `GitHubSyncStatus.notAFork` and this task's PR description). Confirmed
    /// live via `gh api repos/manjesh-raj/<repo>` before this catalog was
    /// written, not assumed from the repo name alone.
    static let repos: [GitHubSyncRepoConfig] = [
        .init(owner: "manjesh-raj", name: "chrome-devtools-axi"),
        .init(owner: "manjesh-raj", name: "treehouse"),
        .init(owner: "manjesh-raj", name: "tasks-axi"),
        .init(owner: "manjesh-raj", name: "gh-axi"),
        .init(owner: "manjesh-raj", name: "no-mistakes"),
        .init(owner: "manjesh-raj", name: "lavish-axi"),
        .init(owner: "manjesh-raj", name: "automic-vault"),
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
    /// A real, confirmed non-fork (`.fork == false`) - `automic-vault`, per
    /// this task's live `gh api` check. Nothing to sync.
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

// MARK: - Process plumbing (mirrors UpdatesData.swift's/VaultData.swift's own private trio)

enum GitHubSyncSource {

    private static func resolveExecutable(_ name: String) -> String? {
        let fm = FileManager.default
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            for dir in path.split(separator: ":") {
                let candidate = "\(dir)/\(name)"
                if fm.isExecutableFile(atPath: candidate) { return candidate }
            }
        }
        for candidate in ["/opt/homebrew/bin/\(name)", "/usr/local/bin/\(name)", "/usr/bin/\(name)", "/bin/\(name)"] {
            if fm.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    private struct RunResult {
        let status: Int32
        let stdout: String
        let stderr: String
        var combinedLog: String { [stdout, stderr].filter { !$0.isEmpty }.joined(separator: "\n") }
    }

    private static func run(_ executable: String, _ args: [String]) -> RunResult {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: executable)
        proc.arguments = args
        proc.environment = childEnvironmentDict()
        let out = Pipe(), err = Pipe()
        proc.standardOutput = out
        proc.standardError = err
        do {
            try proc.run()
        } catch {
            return RunResult(status: -1, stdout: "", stderr: error.localizedDescription)
        }
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        return RunResult(
            status: proc.terminationStatus,
            stdout: String(data: outData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            stderr: String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        )
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

    /// Live check, no caching: fork/parent status via `gh api repos/{full}`,
    /// then how far behind (or diverged from) upstream via `gh api
    /// repos/{full}/compare/{owner}:{branch}...{parentOwner}:{branch}` -
    /// `compare`'s `ahead_by` (commits upstream has this fork doesn't - how
    /// far behind the fork is) and `behind_by` (commits this fork has upstream
    /// doesn't - real diverged local commits) are exactly what `gh repo sync`
    /// itself needs `behind_by == 0` for to fast-forward safely. Confirmed
    /// live against all 8 catalog repos before writing this (see PR
    /// description) - every one of them reported `behind_by: 0`.
    static func check(_ repo: GitHubSyncRepoConfig) -> GitHubSyncCheckOutcome {
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

    /// `gh repo sync {owner}/{repo}` - source defaults to the repo's real
    /// parent (no `--source` override needed, since every catalog entry's
    /// upstream is its own real GitHub-recorded parent). Fast-forward only;
    /// `--force` is never passed, full stop - a refusal is reported back as
    /// `refusedDiverged`, never retried with force. See the file header for
    /// the exact refusal string this matches against, confirmed against the
    /// real `gh` binary shipped on this machine (`gh version 2.97.0`).
    static func sync(_ repo: GitHubSyncRepoConfig) -> GitHubSyncSyncOutcome {
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
}
