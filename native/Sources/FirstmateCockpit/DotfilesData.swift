// Manjesh Grand Line - native macOS app.
//
// Data side of the Bootstrap page's "Dotfiles & machine config" card and its
// "Global agent instructions" verification section (cockpit-bootstrap-
// dotfiles, phase 2 of the Bootstrap plan - phase 1 shipped the page shell +
// the Firstmate-home card, see `BootstrapController.swift`).
//
// The captain's real machine config lives in a Nix flake at `~/manjesh/dotfiles`
// (nix-darwin + home-manager + nix-homebrew), symlinked to the well-known
// `~/.dotfiles` by that repo's own `bootstrap.sh`/`rebuild.sh`. Every check
// here shells out to the real `git`/`ssh-keygen`-style CLIs a human would use
// (mirrors `UpdatesData.swift`'s `run`/`resolveExecutable` plumbing) or reads
// real files - nothing here is a hardcoded "looks fine" status.
//
// `home.nix` declares `home.file.<path>.source = mkOutOfStoreSymlink
// "${dotfiles}/home/<path>"` for a handful of dotfiles, and three separate
// harness-expected filenames (`.claude/CLAUDE.md`, `.codex/AGENTS.md`,
// `.config/opencode/AGENTS.md`) all pointed at the one `home/AGENTS.md`.
// Verified live on this machine: each resolves through an intermediate
// `/nix/store/.../home-manager-files/...` -> `/nix/store/.../hm_AGENTS.md`
// hop before landing on the real repo file, so a single `destination(atPath:)`
// call is not enough - checks below fully resolve the symlink chain via
// `resolvingSymlinksInPath` (equivalent to `readlink -f`) rather than
// reading just the first link's target. `.zshrc` is genuinely different: its
// `home.nix` entry is `programs.zsh` (home-manager *generates* the file)
// rather than a `home.file` source symlink, so it resolves straight into the
// Nix store with no repo path in the chain at all - the managed-items check
// below will correctly report it as "not linked to repo", which is accurate,
// not a bug.

import Foundation

// MARK: - Dotfiles repo state

struct DotfilesRepoState {
    let repoPath: String
    let remoteURL: String?
    let branch: String?
    /// Non-empty `git status --short` lines - a real "uncommitted changes"
    /// state, not assumed clean.
    let dirtyFiles: [String]
    /// The live `user = "..."` value parsed out of `flake.nix`, or `nil` if
    /// the file is missing or the line couldn't be found.
    let flakeUsername: String?
    /// How many commits `origin/<branch>` has that `HEAD` doesn't, computed
    /// via a real `git fetch` against GitHub (never trusting stale local
    /// remote-tracking refs). `nil` when unknown - no network, no remote, or
    /// the fetch failed - never coerced to `0`.
    let commitsBehindOrigin: Int?
}

enum ManagedItemStatus: Equatable {
    case linked
    case notLinked
    case missing
}

struct ManagedItem {
    let label: String
    let path: String
    let status: ManagedItemStatus
}

enum AgentInstructionsRow: Equatable {
    case linked
    case wrongTarget(String)
    case notLinked
}

struct AgentInstructionsItem {
    let label: String
    let path: String
    let status: AgentInstructionsRow
}

enum DotfilesSource {

    static let defaultClonePath = "~/manjesh/dotfiles"
    static let cloneURL = "https://github.com/manjesh-raj/manjesh-config"
    static let dotfilesMarker = "~/.dotfiles"

    /// The paths `home.nix` declares as a plain `home.file` -> repo symlink
    /// (Part A's managed-items table). `.zshrc` is intentionally included even
    /// though it is expected to report "not linked" - see file header.
    static let managedItemPaths: [(label: String, path: String)] = [
        ("WezTerm config", "~/.config/wezterm"),
        ("Neovim config", "~/.config/nvim"),
        ("herdr config", "~/.config/herdr"),
        ("zsh / starship", "~/.zshrc"),
        ("Claude Code settings", "~/.claude/settings.json"),
    ]

    /// The three harness-expected filenames that should all resolve to the
    /// same `<dotfiles>/home/AGENTS.md` (Part B).
    static let agentInstructionPaths: [(label: String, path: String)] = [
        ("Claude Code", "~/.claude/CLAUDE.md"),
        ("Codex", "~/.codex/AGENTS.md"),
        ("opencode", "~/.config/opencode/AGENTS.md"),
    ]

    /// `~/.dotfiles`'s resolved target, or `nil` if it doesn't exist (a
    /// genuinely blank machine, per the task brief's Part A.2).
    static func resolvedDotfilesPath() -> String? {
        let expanded = (dotfilesMarker as NSString).expandingTildeInPath
        guard FileManager.default.fileExists(atPath: expanded) else { return nil }
        return (expanded as NSString).resolvingSymlinksInPath
    }

    static func repoState(at repoPath: String) -> DotfilesRepoState {
        let remote = run("/usr/bin/git", ["-C", repoPath, "remote", "get-url", "origin"]).stdout
        let branch = run("/usr/bin/git", ["-C", repoPath, "rev-parse", "--abbrev-ref", "HEAD"]).stdout
        let statusOut = run("/usr/bin/git", ["-C", repoPath, "status", "--short"]).stdout
        let dirty = statusOut.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
        let branchName = branch.isEmpty ? nil : branch
        return DotfilesRepoState(
            repoPath: repoPath,
            remoteURL: remote.isEmpty ? nil : remote,
            branch: branchName,
            dirtyFiles: dirty,
            flakeUsername: parseFlakeUsername(repoPath: repoPath),
            commitsBehindOrigin: commitsBehindOrigin(repoPath: repoPath, branch: branchName)
        )
    }

    /// Fetches `origin/<branch>` for real (updating the local remote-tracking
    /// ref, never the working tree or local branch) and counts how many
    /// commits it has that `HEAD` doesn't. Returns `nil` on any failure - no
    /// network, no `origin`, no such branch on the remote - rather than
    /// trusting whatever stale remote-tracking ref happened to already be on
    /// disk.
    private static func commitsBehindOrigin(repoPath: String, branch: String?) -> Int? {
        guard let branch else { return nil }
        let fetch = run("/usr/bin/git", ["-C", repoPath, "fetch", "origin", branch])
        guard fetch.status == 0 else { return nil }
        let countResult = run("/usr/bin/git", ["-C", repoPath, "rev-list", "--count", "HEAD..origin/\(branch)"])
        guard countResult.status == 0, let count = Int(countResult.stdout) else { return nil }
        return count
    }

    /// Parses the live `user = "..."` line out of `<repoPath>/flake.nix` -
    /// never a literal name in this app's own source.
    static func parseFlakeUsername(repoPath: String) -> String? {
        let flakePath = (repoPath as NSString).appendingPathComponent("flake.nix")
        guard let contents = try? String(contentsOfFile: flakePath, encoding: .utf8) else { return nil }
        for line in contents.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("user") else { continue }
            guard let firstQuote = trimmed.firstIndex(of: "\""),
                  let lastQuote = trimmed.lastIndex(of: "\""), firstQuote != lastQuote else { continue }
            return String(trimmed[trimmed.index(after: firstQuote)..<lastQuote])
        }
        return nil
    }

    /// Rewrites the `user = "..."` line in `<repoPath>/flake.nix` to
    /// `newUsername` - the same rewrite `bootstrap.sh` does interactively.
    static func writeFlakeUsername(repoPath: String, newUsername: String) throws {
        let flakePath = (repoPath as NSString).appendingPathComponent("flake.nix")
        let contents = try String(contentsOfFile: flakePath, encoding: .utf8)
        var replaced = false
        let newLines = contents.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !replaced, trimmed.hasPrefix("user"),
                  let firstQuote = line.firstIndex(of: "\""),
                  let lastQuote = line.lastIndex(of: "\""), firstQuote != lastQuote else {
                return String(line)
            }
            replaced = true
            return line[line.startIndex..<line.index(after: firstQuote)] + newUsername + line[lastQuote...]
        }
        guard replaced else {
            throw NSError(domain: "Dotfiles", code: 1, userInfo: [NSLocalizedDescriptionKey: "No user = \"...\" line found in flake.nix"])
        }
        try newLines.joined(separator: "\n").write(toFile: flakePath, atomically: true, encoding: .utf8)
    }

    /// Part A's managed-items table: for each `home.nix`-declared path, checks
    /// live whether it is a symlink whose fully-resolved target lands inside
    /// `repoPath`.
    static func managedItems(repoPath: String) -> [ManagedItem] {
        managedItemPaths.map { entry in
            ManagedItem(label: entry.label, path: entry.path, status: linkStatus(path: entry.path, repoPath: repoPath))
        }
    }

    /// Part B's verification rows: for each of the three harness filenames,
    /// checks live whether it fully resolves to exactly
    /// `<repoPath>/home/AGENTS.md`.
    static func agentInstructionItems(repoPath: String) -> [AgentInstructionsItem] {
        let expectedTarget = (((repoPath as NSString).appendingPathComponent("home")) as NSString)
            .appendingPathComponent("AGENTS.md")
        let expectedResolved = (expectedTarget as NSString).resolvingSymlinksInPath
        return agentInstructionPaths.map { entry in
            let expanded = (entry.path as NSString).expandingTildeInPath
            let fm = FileManager.default
            guard fm.fileExists(atPath: expanded) else {
                return AgentInstructionsItem(label: entry.label, path: entry.path, status: .notLinked)
            }
            let resolved = (expanded as NSString).resolvingSymlinksInPath
            if resolved == expectedResolved {
                return AgentInstructionsItem(label: entry.label, path: entry.path, status: .linked)
            }
            return AgentInstructionsItem(label: entry.label, path: entry.path, status: .wrongTarget(resolved))
        }
    }

    private static func linkStatus(path: String, repoPath: String) -> ManagedItemStatus {
        let expanded = (path as NSString).expandingTildeInPath
        let fm = FileManager.default
        guard fm.fileExists(atPath: expanded) else { return .missing }
        let resolved = (expanded as NSString).resolvingSymlinksInPath
        let resolvedRepo = (repoPath as NSString).resolvingSymlinksInPath
        return resolved.hasPrefix(resolvedRepo + "/") ? .linked : .notLinked
    }

    // MARK: Process plumbing (mirrors UpdatesData.swift's `run`)

    private struct RunResult {
        let status: Int32
        let stdout: String
    }

    private static func run(_ executable: String, _ args: [String], cwd: URL? = nil) -> RunResult {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: executable)
        proc.arguments = args
        if let cwd { proc.currentDirectoryURL = cwd }
        proc.environment = childEnvironmentDict()
        let out = Pipe(), err = Pipe()
        proc.standardOutput = out
        proc.standardError = err
        do {
            try proc.run()
        } catch {
            return RunResult(status: -1, stdout: "")
        }
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        _ = err.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        return RunResult(
            status: proc.terminationStatus,
            stdout: String(data: outData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        )
    }
}
