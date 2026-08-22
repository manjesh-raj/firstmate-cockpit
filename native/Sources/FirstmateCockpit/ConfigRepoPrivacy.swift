// Manjesh Grand Line - native macOS app.
//
// GL-22: assert that the repo this app pushes to is private, instead of
// assuming it.
//
// What actually goes to `DotfilesSource.cloneURL` (`manjesh-config`): personal
// tasks and their attached screenshots (`ShiftGitSync`), runbooks and
// postmortems (`DocsRunbookGitSync`), the vault *recipe* - i.e. the list of
// secret names (`VaultRecipeGit`), and `.glbackup` bundles carrying the full
// host inventory and SSH key metadata including fingerprints
// (`GitHubBackupSource`). None of that is a secret *value*, and the review
// verified the repo was private on 2026-08-22 - but "private" was a standing
// assumption with nothing in the app checking it. A visibility flip (a
// mis-click in GitHub's settings, a repo transfer, an org policy change) would
// publish a bastion inventory and a task history silently.
//
// Design decisions worth not re-litigating:
//
//  - **`.unknown` never blocks a push.** No `gh`, no network, a rate limit, a
//    token without repo scope - all of those are ordinary and must not stop the
//    captain's tasks from syncing. Only a *confirmed* `"private": false`
//    refuses. A check that fails closed would make this app unusable offline,
//    which is a far more likely daily event than a visibility flip.
//  - **Cached for the process's lifetime once confirmed private.** The
//    alternative is a `gh api` round trip before every debounced Shift commit,
//    i.e. every few seconds of typing. A flip mid-session is caught on the next
//    launch; a flip is not something that happens while the app is open.
//    A confirmed-public result is *not* cached as final - it is re-checked, so
//    fixing the visibility and continuing to work does not need a relaunch.
//  - **Uses `gh` rather than an unauthenticated request.** A private repo
//    returns 404 to an anonymous caller, which is indistinguishable from "no
//    such repo" - exactly the wrong way round for a check whose whole job is
//    telling private from public.

import Foundation

enum ConfigRepoPrivacy {

    enum Visibility: Equatable {
        /// Confirmed private - safe to push.
        case privateRepo
        /// Confirmed public. Pushing personal data here is a leak.
        case publicRepo
        /// Could not determine (no `gh`, not authenticated, offline, API
        /// error). Pushes proceed - see this file's header.
        case unknown(String)

        /// Whether a push carrying personal data may proceed.
        var allowsPush: Bool { self != .publicRepo }
    }

    /// Set only once a check has *confirmed* private. See the header for why a
    /// public/unknown result is deliberately not cached as final.
    private static let cacheLock = NSLock()
    private static var confirmedPrivate = false

    /// `owner/repo` parsed from `DotfilesSource.cloneURL` - never a second
    /// hardcoded copy, matching `GitHubBackupSource.ownerAndRepo`'s own rule.
    static var repoFullName: String? {
        guard let url = URL(string: DotfilesSource.cloneURL) else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }
        guard parts.count >= 2 else { return nil }
        return "\(parts[0])/\(parts[1].replacingOccurrences(of: ".git", with: ""))"
    }

    /// Runs the check (or returns the cached "private" result).
    ///
    /// Blocking, with a bounded timeout - call it off the main thread. Every
    /// current caller already runs on a background queue (`ShiftGitSync`'s
    /// serial sync queue, `VaultRecipeGit.export`'s caller, `BackupUI`'s
    /// export flow).
    static func check() -> Visibility {
        cacheLock.lock()
        let cached = confirmedPrivate
        cacheLock.unlock()
        if cached { return .privateRepo }

        guard let fullName = repoFullName else {
            return .unknown("Could not parse a repo from DotfilesSource.cloneURL.")
        }
        guard let gh = resolveGh() else {
            return .unknown("`gh` is not installed, so repo visibility could not be verified.")
        }

        // GL-15: the bounded watchdog and the both-streams drain this function
        // hand-rolled are now the shared runner's defaults.
        let result = Subprocess.run(
            executable: gh, arguments: ["api", "repos/\(fullName)", "--jq", ".private"],
            timeout: timeout, stderr: .discard, log: AppLog.network
        )
        if result.timedOut {
            return .unknown("Timed out asking GitHub whether \(fullName) is private.")
        }
        if result.launchFailed {
            return .unknown("Could not run `gh`: \(result.stderr)")
        }
        guard result.ok else {
            return .unknown("`gh api repos/\(fullName)` failed - not authenticated, offline, or no access.")
        }
        let text = result.stdout
        switch text {
        case "true":
            cacheLock.lock(); confirmedPrivate = true; cacheLock.unlock()
            return .privateRepo
        case "false":
            AppLog.gitSync.critical("SECURITY: \(fullName, privacy: .public) is PUBLIC. Refusing to push personal data to it (GL-22).")
            return .publicRepo
        default:
            return .unknown("Unexpected response asking whether \(fullName) is private: \"\(text)\".")
        }
    }

    private static let timeout: TimeInterval = 10

    /// One short line for a status pill / log when a push is refused.
    static var publicRepoRefusalMessage: String {
        "\(repoFullName ?? "The config repo") is PUBLIC - refusing to push. "
        + "Personal tasks, host inventory and key fingerprints sync there. Make it private, then retry."
    }

    private static func resolveGh() -> String? {
        Subprocess.resolveExecutable("gh")
    }
}
