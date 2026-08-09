// Firstmate Cockpit - native macOS app.
//
// Data side for Bootstrap's "Not synced here, by design" card
// (cockpit-bootstrap-not-synced). Only the GitHub/`gh` row has a live check -
// SSH keys and `.env`/secrets are permanently static explanatory text, by
// design (see `BootstrapController`'s card). `av harden gh` is Automic
// Vault's real credential-migration command for `gh`
// (automic-vault/src/isotopes/hardeners/gh_cli.rs): it requires a patched
// `gh` at `/opt/homebrew/opt/gh-cli/bin/gh` (installed via
// `brew install automic-vault/isotopes/gh-cli`) and fails with a plain
// "gh-cli is not installed" message (exit 1) when that's missing - confirmed
// live on this machine, where only the plain Homebrew `gh` is installed.
// `av hardeners --json` reports a `hardened` boolean per tool (including
// "gh") without side effects, so that's what this file checks rather than
// `av doctor gh` (also confirmed live: reports the same missing-patched-gh-cli
// issue via its own `issues` array, but exits non-zero, which is less
// convenient to parse than the always-zero-exit `hardeners --json`).

import Foundation

enum GhHardenStatus: Equatable {
    case checking
    case avNotInstalled
    case hardened
    case notHardened
    case checkFailed(String)
}

enum NotSyncedSource {

    static func checkGhHardening() -> GhHardenStatus {
        guard let av = resolveExecutable("av") else { return .avNotInstalled }
        let result = run(av, ["hardeners", "--json"])
        guard result.status == 0,
              let data = result.stdout.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hardeners = obj["hardeners"] as? [[String: Any]],
              let gh = hardeners.first(where: { $0["name"] as? String == "gh" })
        else {
            return .checkFailed("'av hardeners --json' did not return a parseable gh entry")
        }
        return (gh["hardened"] as? Bool) == true ? .hardened : .notHardened
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
