// Manjesh Grand Line - native macOS app.
//
// Data side of the "Vault" rail destination (fm/grandline-vault-tab). Follows
// this app's established pattern for embedding another system rather than
// reimplementing it (see `FleetData.swift`/`UpdatesData.swift`'s own header
// comments): every read or write goes through Automic Vault's real `av` CLI
// (https://github.com/automic-vault/automic-vault) via `Process`, exactly
// what a captain would type at a terminal - never the Keychain directly, and
// never a cached/logged secret value. `av list`/`av doctor --json` only ever
// return secret *names* and tool *metadata*, never secret material, so those
// are safe to run here like any other read-only check (mirrors
// `NotSyncedData.swift`'s `av hardeners --json` usage). `av save`/`av inject`
// are NOT run from here - see `VaultController`'s header for why those go
// through a real Console terminal tab instead.
//
// The `av` CLI itself is just another entry in `DependencyCatalog`
// (`UpdatesData.swift`, id "automic-vault") - install/update reuses
// `UpdatesSource.check`/`.update` on that exact item rather than a second
// brew-cask mechanism, per the task's explicit instruction to reuse the
// existing update mechanic.

import Foundation

// MARK: - Models

struct VaultSecret: Equatable {
    let name: String
}

enum VaultToolStatus: Equatable {
    case hardened
    /// `issueCount` is `av doctor --json`'s own `issues` array length for
    /// this tool - never a fabricated severity, just what Automic Vault
    /// itself reported.
    case needsAttention(issueCount: Int)

    var label: String {
        switch self {
        case .hardened: return "Hardened"
        case .needsAttention(let count): return count == 1 ? "1 issue" : "\(count) issues"
        }
    }
}

struct VaultTool: Equatable {
    let name: String
    let commands: [String]
    let status: VaultToolStatus
}

enum VaultAvailability: Equatable {
    case checking
    case installed(versionLabel: String)
    case notInstalled
    case checkFailed(String)
}

struct VaultSnapshot {
    let availability: VaultAvailability
    let secrets: [VaultSecret]
    let tools: [VaultTool]
    /// Raw command output for whatever failed, if anything - shown in an
    /// expandable log exactly like `UpdatesController`'s rows do (Safety
    /// principle: show the real command output, not just a status word).
    let log: String
}

enum VaultSource {

    /// The one `DependencyCatalog` entry this page reuses for install/update
    /// - see `UpdatesData.swift`. Force-unwrap is safe: the catalog is a
    /// static, hand-authored literal that already contains this id (Security
    /// category, `automic-vault/isotopes/automic-vault` cask).
    static let dependencyItem: DependencyItem = DependencyCatalog.items.first { $0.id == "automic-vault" }!

    /// Reuses `UpdatesSource.check`/`.update` verbatim - the exact same brew
    /// cask logic the Updates and Bootstrap pages already run for this same
    /// catalog entry, never a second implementation.
    static func checkInstall() -> CheckOutcome { UpdatesSource.check(dependencyItem) }
    static func updateInstall() -> UpdateOutcome { UpdatesSource.update(dependencyItem) }

    /// Full read-only snapshot: whether `av` is on PATH, every saved secret
    /// name (`av list`), and every registered launcher tool's hardening
    /// status (`av doctor --json`, mirroring `NotSyncedSource.checkHardened`'s
    /// use of the sibling `av hardeners --json`). Safe to call from a
    /// background queue; never touches the main thread.
    static func loadSnapshot() -> VaultSnapshot {
        guard let av = resolveExecutable("av") else {
            return VaultSnapshot(availability: .notInstalled, secrets: [], tools: [], log: "")
        }
        let versionResult = run(av, ["--version"])
        let availability: VaultAvailability = versionResult.status == 0 && !versionResult.stdout.isEmpty
            ? .installed(versionLabel: versionResult.stdout)
            : .checkFailed("'av --version' failed")

        let listResult = run(av, ["list"])
        let secrets: [VaultSecret] = listResult.status == 0
            ? listResult.stdout.split(separator: "\n").map { VaultSecret(name: String($0).trimmingCharacters(in: .whitespaces)) }.filter { !$0.name.isEmpty }
            : []

        let doctorResult = run(av, ["doctor", "--json"])
        let tools = parseDoctorTools(doctorResult.stdout)

        let log = [listResult.combinedLog, doctorResult.combinedLog].filter { !$0.isEmpty }.joined(separator: "\n")
        return VaultSnapshot(availability: availability, secrets: secrets, tools: tools, log: log)
    }

    /// Not `private` - exercised directly by `VaultDataSelfTest`.
    static func parseDoctorTools(_ json: String) -> [VaultTool] {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = obj["results"] as? [[String: Any]]
        else { return [] }
        return results.compactMap { entry in
            guard let name = entry["name"] as? String else { return nil }
            let commands = (entry["commands"] as? [String]) ?? []
            let issues = (entry["issues"] as? [Any]) ?? []
            let status: VaultToolStatus = issues.isEmpty ? .hardened : .needsAttention(issueCount: issues.count)
            return VaultTool(name: name, commands: commands, status: status)
        }
    }

    // MARK: Command strings for the Console tab (never executed directly here)

    /// `av save <name>` - reads the secret value from the real terminal's
    /// own `/dev/tty` (confirmed live: piping a value in via stdin fails
    /// with "failed to open /dev/tty"), so this can only ever run inside a
    /// real interactive terminal, never a background `Process`. Returns
    /// `nil` for a name that isn't a safe bare shell token, so the caller
    /// never has to shell-quote arbitrary captain input into a `-lc` string.
    static func saveSecretCommand(name: String) -> String? {
        guard isSafeToken(name) else { return nil }
        return "av save \(name)"
    }

    /// `av inject +NAME -- <command>` - confirmed live to run fine as a
    /// background `Process` with no controlling terminal (Automic Vault's
    /// own approval prompt, if any, is handled by its separate menu-bar app,
    /// not `/dev/tty`), but this app still routes it through a real Console
    /// tab rather than capturing its output itself - the injected command is
    /// caller-authored and may print anything, and Grand Line must never be
    /// the thing that captures/logs a command's real output.
    static func injectCommand(secretName: String, command: String) -> String? {
        guard isSafeToken(secretName), !command.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return "av inject +\(secretName) -- \(command)"
    }

    /// A conservative allowlist (letters, digits, underscore, dash) matching
    /// the shape of every real secret name `av list` returned on this
    /// machine - deliberately stricter than whatever `av save` itself
    /// accepts, since the only purpose here is "safe to splice into a shell
    /// command with no quoting."
    static func isSafeToken(_ s: String) -> Bool {
        !s.isEmpty && s.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }
    }

    // MARK: Process plumbing (mirrors UpdatesData.swift's private helpers)

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
}
