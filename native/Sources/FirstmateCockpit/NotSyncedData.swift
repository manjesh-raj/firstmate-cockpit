// Manjesh Grand Line - native macOS app.
//
// Data side for Bootstrap's "Not synced here, by design" card
// (cockpit-bootstrap-not-synced, extended in cockpit-bootstrap-vault-hardeners
// to add AWS/Codex/Homebrew rows alongside the original GitHub/`gh` row).
// SSH keys and `.env`/secrets stay permanently static text - no button, no
// live check, by design (see `BootstrapController`'s card). The four rows
// with a real mechanism all go through Automic Vault's `av harden <name>`
// (automic-vault/src/isotopes/hardeners/{gh_cli,aws_cli,codex,homebrew}.rs),
// and all four are checked the same way: `av hardeners --json` reports a
// `hardened` boolean per tool without side effects, so that's what
// `checkHardened(name:)` parses once for every row rather than each row
// re-parsing it (also confirmed live: `av doctor <name>` reports the same
// issues via its own `issues` array but exits non-zero on any issue, which
// is a worse signal for a plain yes/no than the always-zero-exit
// `hardeners --json`).

import Foundation

/// Shared status shape for a hardener with no extra states beyond
/// hardened/not-hardened (codex, brew). gh and aws each have one additional
/// real state (see `GhHardenState`/`AwsHardenState` below) layered on top of
/// this same underlying check.
enum HardenerStatus: Equatable {
    case checking
    case avNotInstalled
    case hardened
    case notHardened
    case checkFailed(String)
}

/// `automic-vault/isotopes/gh-cli` (the patched `gh` `av harden gh` requires)
/// explicitly conflicts with the plain `gh` Homebrew formula ("Conflicts
/// with: gh" - confirmed live via `brew info automic-vault/isotopes/gh-cli`),
/// so a captain whose dotfiles still declare plain `gh` in
/// `homebrew.brews` gets a bare "gh-cli is not installed" failure with no
/// path forward. `.isotopeMissingPlainGhInstalled` is that specific,
/// fixable case, distinguished from a generic `.notHardened` (isotope
/// already installed, just not yet migrated).
enum GhHardenState: Equatable {
    case checking
    case avNotInstalled
    case hardened
    case notHardened
    case isotopeMissingPlainGhInstalled
    case checkFailed(String)
}

/// `av harden aws` migrates the existing `default` key pair out of
/// `~/.aws/credentials` into the macOS login keychain - on a machine with no
/// local AWS credentials at all, "not hardened" is misleading (it implies an
/// action is due right now); `.noLocalCredentials` is the real third state.
enum AwsHardenState: Equatable {
    case checking
    case avNotInstalled
    case hardened
    case notHardened
    case noLocalCredentials
    case checkFailed(String)
}

enum NotSyncedSource {

    // MARK: Shared `av hardeners --json` check

    static func checkHardened(name: String) -> HardenerStatus {
        guard let av = resolveExecutable("av") else { return .avNotInstalled }
        let result = run(av, ["hardeners", "--json"])
        guard result.status == 0,
              let data = result.stdout.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hardeners = obj["hardeners"] as? [[String: Any]],
              let entry = hardeners.first(where: { $0["name"] as? String == name })
        else {
            return .checkFailed("'av hardeners --json' did not return a parseable \(name) entry")
        }
        return (entry["hardened"] as? Bool) == true ? .hardened : .notHardened
    }

    // MARK: gh

    static func checkGhHardening() -> GhHardenState {
        switch checkHardened(name: "gh") {
        case .checking: return .checking
        case .avNotInstalled: return .avNotInstalled
        case .hardened: return .hardened
        case .checkFailed(let reason): return .checkFailed(reason)
        case .notHardened:
            return ghIsotopeMissingWithPlainGhInstalled() ? .isotopeMissingPlainGhInstalled : .notHardened
        }
    }

    private static func ghIsotopeMissingWithPlainGhInstalled() -> Bool {
        let isotopeInstalled = FileManager.default.isExecutableFile(atPath: "/opt/homebrew/opt/gh-cli/bin/gh")
        guard !isotopeInstalled else { return false }
        return resolveExecutable("gh") != nil
    }

    // MARK: aws

    static func checkAwsHardening() -> AwsHardenState {
        switch checkHardened(name: "aws") {
        case .checking: return .checking
        case .avNotInstalled: return .avNotInstalled
        case .hardened: return .hardened
        case .checkFailed(let reason): return .checkFailed(reason)
        case .notHardened:
            return hasLocalAwsDefaultCredentials() ? .notHardened : .noLocalCredentials
        }
    }

    /// Mirrors `aws_cli.rs`'s own `[default]` section parsing closely enough
    /// to answer "is there anything to migrate" - this app never touches the
    /// file, `av harden aws` does the real read/write.
    private static func hasLocalAwsDefaultCredentials() -> Bool {
        let env = ProcessInfo.processInfo.environment
        let path: String
        if let override = env["AWS_SHARED_CREDENTIALS_FILE"], !override.isEmpty {
            path = override
        } else {
            guard let home = env["HOME"] else { return false }
            path = "\(home)/.aws/credentials"
        }
        guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else { return false }
        var inDefaultSection = false
        for rawLine in contents.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("["), line.hasSuffix("]") {
                let section = line.dropFirst().dropLast().trimmingCharacters(in: .whitespaces)
                inDefaultSection = (section == "default")
                continue
            }
            guard inDefaultSection, let key = line.split(separator: "=").first else { continue }
            if key.trimmingCharacters(in: .whitespaces) == "aws_access_key_id" { return true }
        }
        return false
    }

    // MARK: codex / brew - no extra state beyond the shared check

    static func checkCodexHardening() -> HardenerStatus { checkHardened(name: "codex") }
    static func checkHomebrewHardening() -> HardenerStatus { checkHardened(name: "brew") }

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
