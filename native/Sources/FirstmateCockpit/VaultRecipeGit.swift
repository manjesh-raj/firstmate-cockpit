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
// separate managed clone, no merge-base/conflict logic) - it's the
// captain's real repo, with their real git identity and credential helper
// already configured, so a plain add/commit/push is the whole job.

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
    /// `repoPath`, then commits and pushes it. Safe to call from a
    /// background queue - this never touches the main thread.
    static func export(recipe: VaultRecipe, repoPath: String) -> VaultRecipeExportResult {
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

        let commit = runGit(["commit", "-m", "Vault: update secret recipe backup"], cwd: repoPath, remoteURL: remoteURL, authenticated: false)
        guard commit.status == 0 else {
            return VaultRecipeExportResult(ok: false, message: "git commit failed: \(commit.stderr.isEmpty ? "unknown error" : commit.stderr)", filePath: filePath)
        }

        let branchResult = runGit(["rev-parse", "--abbrev-ref", "HEAD"], cwd: repoPath, remoteURL: remoteURL, authenticated: false)
        let branch = branchResult.stdout.isEmpty ? "HEAD" : branchResult.stdout
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

    // MARK: git process plumbing (mirrors ShiftGitSync.runGit's auth shape)

    private struct GitResult {
        let status: Int32
        let stdout: String
        let stderr: String
    }

    private static func runGit(_ args: [String], cwd: String, remoteURL: String?, authenticated: Bool) -> GitResult {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        proc.arguments = args
        proc.currentDirectoryURL = URL(fileURLWithPath: cwd)
        var env = childEnvironmentDict()
        if authenticated, let remoteURL, remoteURL.hasPrefix("https://"), let token = DocsSyncSource.ghAuthToken() {
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
