// Manjesh Grand Line - native macOS app.
//
// Filesystem/git side of the Vault recipe backup (fm/grandline-vault-recipe-
// backup) - see `VaultRecipe.swift`'s header for what's recorded and why.
//
// The captain's real local clone of `manjesh-raj/manjesh-config` is not a
// new concept this feature invents a path for - it's the exact clone
// `DotfilesSource` already resolves via the `~/.dotfiles` symlink Bootstrap's
// "Dotfiles & machine config" card maintains (`DotfilesSource.
// resolvedDotfilesPath()`, `DotfilesData.swift`). Reusing it means this
// feature works on the captain's actual machine unmodified, and fails
// honestly (pointing at Bootstrap) on a machine where that clone doesn't
// exist yet, rather than guessing a second hardcoded path.
//
// Committing/pushing reuses `ShiftGitSync.swift`'s exact auth shape for the
// push step (a GitHub Basic-auth `http.extraheader` built from
// `DocsSyncSource.ghAuthToken()`, injected via `GIT_CONFIG_*` env vars rather
// than a `-c` argument so the token never appears in `ps`) - not a second
// git-wrapping mechanism. Unlike `ShiftGitSync`, this feature operates
// directly on the captain's own already-checked-out working tree (no
// separate managed clone, no per-record merge-base/conflict logic like
// `ShiftConflict.swift`) - it's the captain's real repo, with their real
// git identity and credential helper already configured.
//
// `export` fetches and `git merge --ff-only`s before committing (and
// therefore before pushing) - fm/grandline-vault-export-push-fix - the
// captain's clone can be behind `origin` for reasons unrelated to this
// export (another machine pushed, a manual edit elsewhere), and a bare
// commit-then-push then fails with git's own "[rejected] ... fetch first"
// error. The fetch/merge has to happen with the recipe file already
// staged but NOT yet committed - merging *after* the recipe commit exists
// can't fast-forward, since that commit and origin's tip would then be two
// different children of the same old base (a narrow but real divergence,
// even in the "purely behind" case) - live-verified against a disposable
// local repo pair that this exact ordering both fixes the "purely behind"
// case and leaves a staged-but-uncommitted file untouched by the merge.
// `--ff-only` is the same load-bearing choice `DotfilesRunCommand.
// rebuildCommand`'s `git pull --ff-only` and `ShiftGitSync.pullNow()`
// already make: it fast-forwards silently when the local checkout is a
// clean ancestor of the remote, and aborts with a real, visible error -
// never force, never discard - the moment local and remote have genuinely
// diverged (real local-only commits that predate this export). A genuine
// divergence is reported back pointing at Bootstrap's "Dotfiles & machine
// config" card to resolve by hand, same as every other git-writing path in
// this app.

import Foundation

struct VaultRecipeExportResult {
    let ok: Bool
    let message: String
    let filePath: String?
}

enum VaultRecipeGit {

    static let backupFolderName = "automatic-vault-details-backup"
    static let recipeFileName = "automic-vault-recipe.json"

    /// The captain's real local `manjesh-config` clone, or `nil` if it
    /// doesn't exist on this machine yet (a genuinely blank machine, or
    /// Bootstrap's dotfiles step hasn't been run - see `DotfilesSource.
    /// resolvedDotfilesPath()`'s own doc comment).
    static func resolveRepoPath() -> String? {
        DotfilesSource.resolvedDotfilesPath()
    }

    static func recipeFilePath(repoPath: String) -> String {
        ((repoPath as NSString).appendingPathComponent(backupFolderName) as NSString)
            .appendingPathComponent(recipeFileName)
    }

    /// Writes the recipe JSON into `automatic-vault-details-backup/` inside
    /// `repoPath`, then fetches + fast-forwards past anything new on
    /// `origin` before committing and pushing it (see this file's header for
    /// why that order, not fetch-after-commit). Safe to call from a
    /// background queue - this never touches the main thread.
    static func export(recipe: VaultRecipe, repoPath: String) -> VaultRecipeExportResult {
        // GL-22: this writes the captain's full secret-name inventory to
        // `manjesh-config`. Refuse only on a confirmed-public repo - see
        // `ConfigRepoPrivacy`'s header on why `.unknown` proceeds.
        if !ConfigRepoPrivacy.check().allowsPush {
            return VaultRecipeExportResult(ok: false, message: ConfigRepoPrivacy.publicRepoRefusalMessage, filePath: nil)
        }
        let fm = FileManager.default
        let folderPath = (repoPath as NSString).appendingPathComponent(backupFolderName)
        let relativeFilePath = "\(backupFolderName)/\(recipeFileName)"
        let filePath = recipeFilePath(repoPath: repoPath)

        do {
            try fm.createDirectory(atPath: folderPath, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(recipe)
            try data.write(to: URL(fileURLWithPath: filePath), options: .atomic)
        } catch {
            return VaultRecipeExportResult(ok: false, message: "Failed to write recipe file: \(error.localizedDescription)", filePath: nil)
        }

        let remoteURL = runGit(["remote", "get-url", "origin"], cwd: repoPath, remoteURL: nil, authenticated: false).stdout

        let add = runGit(["add", "--", relativeFilePath], cwd: repoPath, remoteURL: remoteURL, authenticated: false)
        guard add.status == 0 else {
            return VaultRecipeExportResult(ok: false, message: "git add failed: \(add.stderr.isEmpty ? "unknown error" : add.stderr)", filePath: filePath)
        }

        let statusCheck = runGit(["status", "--porcelain", "--", relativeFilePath], cwd: repoPath, remoteURL: remoteURL, authenticated: false)
        if statusCheck.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return VaultRecipeExportResult(ok: true, message: "No changes since the last export - nothing to push.", filePath: filePath)
        }

        let branchResult = runGit(["rev-parse", "--abbrev-ref", "HEAD"], cwd: repoPath, remoteURL: remoteURL, authenticated: false)
        let branch = branchResult.stdout.isEmpty ? "HEAD" : branchResult.stdout

        // The captain's local clone can be behind `origin` for reasons that
        // have nothing to do with this export (another machine pushed, a
        // manual edit elsewhere) - a bare `git commit` + `git push` then
        // fails with git's own "[rejected] ... fetch first" error, since the
        // new commit this export just created is a sibling of, not a
        // descendant of, origin's tip.
        //
        // This has to run BEFORE the commit, not after: fast-forwarding
        // *after* creating the recipe commit can't work, because by then the
        // recipe commit and origin's tip are two different children of the
        // same old base - a genuine (if narrow) divergence, not a pure
        // "behind" case, however clean the captain's own history is. Doing
        // it here - with the recipe file already staged but not yet
        // committed - lets `git merge --ff-only` bring origin's unrelated
        // commits in first, so the recipe commit lands on top of a caught-up
        // base and pushes as an ordinary fast-forward. Verified live against
        // a disposable local repo pair: a staged-but-uncommitted new file
        // survives this fast-forward untouched.
        //
        // Mirrors `DotfilesRunCommand.rebuildCommand`'s own `git pull
        // --ff-only` convention: `--ff-only` fast-forwards silently when the
        // local checkout is a clean ancestor of the remote, and aborts with
        // a real, visible error - never force, never discard - the moment
        // local and remote have genuinely diverged (real local-only commits
        // that predate this export, unrelated to it).
        let fetch = runGit(["fetch", "origin", branch], cwd: repoPath, remoteURL: remoteURL, authenticated: true)
        guard fetch.status == 0 else {
            return VaultRecipeExportResult(
                ok: false,
                message: "Couldn't fetch from GitHub to check for new changes before committing: \(fetch.stderr.isEmpty ? "unknown error" : fetch.stderr)",
                filePath: filePath
            )
        }

        let merge = runGit(["merge", "--ff-only", "origin/\(branch)"], cwd: repoPath, remoteURL: remoteURL, authenticated: false)
        guard merge.status == 0 else {
            return VaultRecipeExportResult(
                ok: false,
                message: "Your manjesh-config clone has diverged from GitHub (there are commits on each side the other doesn't have), so this can't fast-forward automatically. Resolve it by hand from Bootstrap's \"Dotfiles & machine config\" card, then export again - nothing was force-pushed or discarded.",
                filePath: filePath
            )
        }

        let commit = runGit(["commit", "-m", "Vault: update secret recipe backup"], cwd: repoPath, remoteURL: remoteURL, authenticated: false)
        guard commit.status == 0 else {
            return VaultRecipeExportResult(ok: false, message: "git commit failed: \(commit.stderr.isEmpty ? "unknown error" : commit.stderr)", filePath: filePath)
        }

        let push = runGit(["push", "origin", "HEAD:\(branch)"], cwd: repoPath, remoteURL: remoteURL, authenticated: true)
        guard push.status == 0 else {
            return VaultRecipeExportResult(
                ok: false,
                message: "Committed locally, but push failed: \(push.stderr.isEmpty ? "unknown error" : push.stderr)",
                filePath: filePath
            )
        }

        return VaultRecipeExportResult(ok: true, message: "Exported and pushed to \(relativeFilePath).", filePath: filePath)
    }

    /// Reads back a previously-exported recipe, or `nil` if none exists yet
    /// or the file can't be decoded.
    static func loadExistingRecipe(repoPath: String) -> VaultRecipe? {
        let filePath = recipeFilePath(repoPath: repoPath)
        guard let data = FileManager.default.contents(atPath: filePath) else { return nil }
        return try? JSONDecoder().decode(VaultRecipe.self, from: data)
    }

    // MARK: git process plumbing

    // GL-15: shared runner, shared token injection - see
    // `Subprocess.gitAuthEnvironment`. Unchanged in behaviour, including that a
    // `nil`/non-https remote gets no header, which is what the disposable
    // bare-repo verification this file's header describes relies on.

    private typealias GitResult = SubprocessResult

    private static func runGit(_ args: [String], cwd: String, remoteURL: String?, authenticated: Bool) -> GitResult {
        Subprocess.git(args, cwd: URL(fileURLWithPath: cwd),
                       authenticateFor: authenticated ? remoteURL : nil,
                       timeout: 600)
    }
}
