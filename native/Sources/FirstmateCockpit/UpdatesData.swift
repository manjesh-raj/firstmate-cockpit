// Firstmate Cockpit - native macOS app.
//
// "Firstmate Latest Updates" (the new `.updates` rail destination): the data
// side. Every dependency in the captain's ecosystem is checked and updated by
// shelling out to the same real CLIs a human would use at a terminal - npm,
// Homebrew, herdr's own updater, no-mistakes' own updater, and (for firstmate
// itself) a fetch-upstream/merge/push script - never a fabricated version
// number. Meant to run entirely off the main thread; `UpdatesController`
// dispatches every `check`/`update` call to a background queue exactly like
// `FleetController.refresh`/`FleetDataSource.mergePR` already do.

import Foundation

// MARK: - Catalog

enum DependencyKind {
    case npmGlobal(package: String)
    case brewFormula(formula: String)
    case brewCask(cask: String)
    case herdr
    case noMistakes
    case firstmate

    var symbol: String {
        switch self {
        case .npmGlobal: return "shippingbox"
        case .brewFormula, .brewCask: return "wrench.and.screwdriver"
        case .herdr: return "bolt.horizontal.circle"
        case .noMistakes: return "checkmark.shield"
        case .firstmate: return "sailboat"
        }
    }
}

struct DependencyItem {
    let id: String
    let name: String
    let category: String
    let kind: DependencyKind
}

enum DependencyCatalog {
    /// Section order matches the captain's brief: npm-global tools, Homebrew
    /// tools, then the two special self-updaters, then firstmate itself.
    static let items: [DependencyItem] = [
        .init(id: "tasks-axi", name: "tasks-axi", category: "npm packages", kind: .npmGlobal(package: "tasks-axi")),
        .init(id: "gh-axi", name: "gh-axi", category: "npm packages", kind: .npmGlobal(package: "gh-axi")),
        .init(id: "chrome-devtools-axi", name: "chrome-devtools-axi", category: "npm packages", kind: .npmGlobal(package: "chrome-devtools-axi")),
        .init(id: "lavish-axi", name: "lavish-axi", category: "npm packages", kind: .npmGlobal(package: "lavish-axi")),
        .init(id: "quota-axi", name: "quota-axi", category: "npm packages", kind: .npmGlobal(package: "quota-axi")),
        .init(id: "gh", name: "gh (GitHub CLI)", category: "Homebrew", kind: .brewFormula(formula: "gh")),
        .init(id: "tmux", name: "tmux", category: "Homebrew", kind: .brewFormula(formula: "tmux")),
        .init(id: "claude-code", name: "Claude Code", category: "Homebrew", kind: .brewCask(cask: "claude-code")),
        .init(id: "herdr", name: "herdr", category: "Other tools", kind: .herdr),
        .init(id: "no-mistakes", name: "no-mistakes", category: "Other tools", kind: .noMistakes),
        .init(id: "firstmate", name: "firstmate", category: "Firstmate", kind: .firstmate),
    ]

    /// Category display order - `Dictionary`-grouping in `UpdatesController`
    /// would otherwise be unordered.
    static let categoryOrder = ["npm packages", "Homebrew", "Other tools", "Firstmate"]
}

// MARK: - Outcomes

enum DependencyStatus: Equatable {
    case unknown
    case checking
    case upToDate
    case updateAvailable
    case notInstalled
    case checkFailed
    case updating
    case updateFailed

    /// Step 1 of the captain-specified flow: Update is only ever shown once a
    /// Check has run, and never while already up to date - every other
    /// terminal state (update available, not installed, or a failed/unknown
    /// check) is safe to offer Update for, since every update command this
    /// file runs is itself idempotent (installing/upgrading to "latest" when
    /// already current is a safe no-op for npm, brew, herdr, no-mistakes, and
    /// the firstmate sync script alike).
    var showsUpdateButton: Bool {
        switch self {
        case .unknown, .checking, .upToDate, .updating: return false
        case .updateAvailable, .notInstalled, .checkFailed, .updateFailed: return true
        }
    }
}

struct CheckOutcome {
    let installedLabel: String
    let latestLabel: String?
    let status: DependencyStatus
    /// Ready-to-render one-line summary for the row's subtitle - crafted by
    /// whichever `checkXxx` produced it rather than re-derived generically,
    /// since e.g. firstmate's "N commits behind upstream" has no equivalent
    /// in a plain installed/latest version pair.
    let detail: String
    /// Raw command output, shown in the row's expandable log - Safety
    /// principle: "every action's real command/tool output should be visible
    /// to the captain in some form... don't just show a green checkmark with
    /// no evidence."
    let log: String
}

struct UpdateOutcome {
    let ok: Bool
    let newVersionLabel: String?
    let detail: String
    let log: String
}

// MARK: - Process plumbing (mirrors OpenPRsSource's resolveExecutable/childEnvironmentDict use)

private func resolveExecutable(_ name: String) -> String? {
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
    var combinedLog: String {
        [stdout, stderr].filter { !$0.isEmpty }.joined(separator: "\n")
    }
}

private func run(_ executable: String, _ args: [String], cwd: URL? = nil) -> RunResult {
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

private func missingToolOutcome(_ tool: String) -> CheckOutcome {
    CheckOutcome(installedLabel: "\u{2014}", latestLabel: nil, status: .checkFailed, detail: "'\(tool)' not found on PATH", log: "")
}

// MARK: - Checking / updating

enum UpdatesSource {

    static func check(_ item: DependencyItem) -> CheckOutcome {
        switch item.kind {
        case .npmGlobal(let package): return checkNpm(package)
        case .brewFormula(let formula): return checkBrewFormula(formula)
        case .brewCask(let cask): return checkBrewCask(cask)
        case .herdr: return checkHerdr()
        case .noMistakes: return checkNoMistakes()
        case .firstmate: return checkFirstmate()
        }
    }

    static func update(_ item: DependencyItem) -> UpdateOutcome {
        switch item.kind {
        case .npmGlobal(let package): return updateNpm(package)
        case .brewFormula(let formula): return updateBrewFormula(formula)
        case .brewCask(let cask): return updateBrewCask(cask)
        case .herdr: return updateHerdr()
        case .noMistakes: return updateNoMistakes()
        case .firstmate: return updateFirstmate()
        }
    }

    // MARK: npm-global

    private static func checkNpm(_ package: String) -> CheckOutcome {
        guard let npm = resolveExecutable("npm") else { return missingToolOutcome("npm") }
        let installed = installedNpmVersion(npm: npm, package: package)
        let latestResult = run(npm, ["view", package, "version"])
        let latest = latestResult.status == 0 && !latestResult.stdout.isEmpty ? latestResult.stdout : nil
        let log = [installedNpmLog(npm: npm, package: package), latestResult.combinedLog].filter { !$0.isEmpty }.joined(separator: "\n")

        guard let installed else {
            return CheckOutcome(
                installedLabel: "not installed", latestLabel: latest, status: .notInstalled,
                detail: latest != nil ? "Not installed - \(latest!) available" : "Not installed", log: log
            )
        }
        guard let latest else {
            return CheckOutcome(installedLabel: installed, latestLabel: nil, status: .checkFailed, detail: "Installed \(installed) - could not reach npm registry for the latest version", log: log)
        }
        if installed == latest {
            return CheckOutcome(installedLabel: installed, latestLabel: latest, status: .upToDate, detail: "\(installed) - up to date", log: log)
        }
        return CheckOutcome(installedLabel: installed, latestLabel: latest, status: .updateAvailable, detail: "\(installed) \u{2192} \(latest)", log: log)
    }

    private static func installedNpmVersion(npm: String, package: String) -> String? {
        let result = run(npm, ["ls", "-g", package, "--depth=0", "--json"])
        guard let data = result.stdout.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let deps = obj["dependencies"] as? [String: Any],
              let entry = deps[package] as? [String: Any],
              let version = entry["version"] as? String
        else { return nil }
        return version
    }

    private static func installedNpmLog(npm: String, package: String) -> String {
        run(npm, ["ls", "-g", package, "--depth=0"]).combinedLog
    }

    private static func updateNpm(_ package: String) -> UpdateOutcome {
        guard let npm = resolveExecutable("npm") else {
            return UpdateOutcome(ok: false, newVersionLabel: nil, detail: "'npm' not found on PATH", log: "")
        }
        let result = run(npm, ["install", "-g", package])
        guard result.status == 0 else {
            return UpdateOutcome(ok: false, newVersionLabel: nil, detail: "npm install -g \(package) failed", log: result.combinedLog)
        }
        let version = installedNpmVersion(npm: npm, package: package)
        return UpdateOutcome(ok: true, newVersionLabel: version, detail: "Installed \(version ?? "latest")", log: result.combinedLog)
    }

    // MARK: Homebrew formula

    private static func checkBrewFormula(_ formula: String) -> CheckOutcome {
        guard let brew = resolveExecutable("brew") else { return missingToolOutcome("brew") }
        let installed = installedBrewVersion(brew: brew, formula: formula, cask: false)
        let infoResult = run(brew, ["info", "--json=v2", formula])
        let latest = latestBrewFormulaVersion(from: infoResult.stdout)
        let log = infoResult.combinedLog

        guard let installed else {
            return CheckOutcome(installedLabel: "not installed", latestLabel: latest, status: .notInstalled, detail: latest != nil ? "Not installed - \(latest!) available" : "Not installed", log: log)
        }
        guard let latest else {
            return CheckOutcome(installedLabel: installed, latestLabel: nil, status: .checkFailed, detail: "Installed \(installed) - could not reach Homebrew for the latest version", log: log)
        }
        if installed == latest {
            return CheckOutcome(installedLabel: installed, latestLabel: latest, status: .upToDate, detail: "\(installed) - up to date", log: log)
        }
        return CheckOutcome(installedLabel: installed, latestLabel: latest, status: .updateAvailable, detail: "\(installed) \u{2192} \(latest)", log: log)
    }

    private static func installedBrewVersion(brew: String, formula: String, cask: Bool) -> String? {
        var args = ["list", "--versions"]
        if cask { args.append("--cask") }
        args.append(formula)
        let result = run(brew, args)
        guard result.status == 0, !result.stdout.isEmpty else { return nil }
        // "<name> <version>[ <version>...]" - the installed formula/cask name
        // followed by one version per installed copy; the last is the newest.
        return result.stdout.split(separator: " ").last.map(String.init)
    }

    private static func latestBrewFormulaVersion(from json: String) -> String? {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let formulae = obj["formulae"] as? [[String: Any]],
              let first = formulae.first,
              let versions = first["versions"] as? [String: Any],
              let stable = versions["stable"] as? String
        else { return nil }
        return stable
    }

    private static func updateBrewFormula(_ formula: String) -> UpdateOutcome {
        guard let brew = resolveExecutable("brew") else {
            return UpdateOutcome(ok: false, newVersionLabel: nil, detail: "'brew' not found on PATH", log: "")
        }
        let result = run(brew, ["upgrade", formula])
        guard result.status == 0 else {
            return UpdateOutcome(ok: false, newVersionLabel: nil, detail: "brew upgrade \(formula) failed", log: result.combinedLog)
        }
        let version = installedBrewVersion(brew: brew, formula: formula, cask: false)
        return UpdateOutcome(ok: true, newVersionLabel: version, detail: "Upgraded to \(version ?? "latest")", log: result.combinedLog)
    }

    // MARK: Homebrew cask (Claude Code)

    private static func checkBrewCask(_ cask: String) -> CheckOutcome {
        guard let brew = resolveExecutable("brew") else { return missingToolOutcome("brew") }
        let installed = installedBrewVersion(brew: brew, formula: cask, cask: true)
        let infoResult = run(brew, ["info", "--cask", "--json=v2", cask])
        let latest = latestBrewCaskVersion(from: infoResult.stdout)
        let log = infoResult.combinedLog

        guard let installed else {
            return CheckOutcome(installedLabel: "not installed", latestLabel: latest, status: .notInstalled, detail: latest != nil ? "Not installed - \(latest!) available" : "Not installed", log: log)
        }
        guard let latest else {
            return CheckOutcome(installedLabel: installed, latestLabel: nil, status: .checkFailed, detail: "Installed \(installed) - could not reach Homebrew for the latest version", log: log)
        }
        if installed == latest {
            return CheckOutcome(installedLabel: installed, latestLabel: latest, status: .upToDate, detail: "\(installed) - up to date", log: log)
        }
        return CheckOutcome(installedLabel: installed, latestLabel: latest, status: .updateAvailable, detail: "\(installed) \u{2192} \(latest)", log: log)
    }

    private static func latestBrewCaskVersion(from json: String) -> String? {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let casks = obj["casks"] as? [[String: Any]],
              let first = casks.first,
              let version = first["version"] as? String
        else { return nil }
        return version
    }

    private static func updateBrewCask(_ cask: String) -> UpdateOutcome {
        guard let brew = resolveExecutable("brew") else {
            return UpdateOutcome(ok: false, newVersionLabel: nil, detail: "'brew' not found on PATH", log: "")
        }
        // Matches the exact hint text Claude Code itself prints ("Update
        // available! Run: brew upgrade claude-code") rather than the more
        // explicit `--cask` form - brew resolves it unambiguously on this
        // machine since no formula shares the name.
        let result = run(brew, ["upgrade", cask])
        guard result.status == 0 else {
            return UpdateOutcome(ok: false, newVersionLabel: nil, detail: "brew upgrade \(cask) failed", log: result.combinedLog)
        }
        let version = installedBrewVersion(brew: brew, formula: cask, cask: true)
        return UpdateOutcome(ok: true, newVersionLabel: version, detail: "Upgraded to \(version ?? "latest")", log: result.combinedLog)
    }

    // MARK: herdr

    /// Installed version comes from `herdr status --json`'s `.client.version`
    /// - the same field firstmate's own `fm_backend_herdr_version_check`
    /// (`bin/backends/herdr.sh`) reads before every herdr-backed spawn.
    /// herdr's CLI has no "check for a newer release without installing it"
    /// flag; the latest-available version is instead read from Homebrew,
    /// since herdr happens to be homebrew-core tapped on this machine
    /// (confirmed live: `brew list --versions herdr` succeeds). The actual
    /// Update action below also goes through Homebrew (`brew update && brew
    /// upgrade herdr`), not `herdr update` - a Homebrew-installed herdr
    /// refuses to self-update by design ("self-update is disabled for
    /// Homebrew installs; run `brew update && brew upgrade herdr`"),
    /// confirmed live, so `herdr update` fails 100% of the time here.
    private static func checkHerdr() -> CheckOutcome {
        guard let herdrPath = resolveExecutable("herdr") else { return missingToolOutcome("herdr") }
        let statusResult = run(herdrPath, ["status", "--json"])
        guard statusResult.status == 0,
              let data = statusResult.stdout.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let client = obj["client"] as? [String: Any],
              let installed = client["version"] as? String
        else {
            return CheckOutcome(installedLabel: "\u{2014}", latestLabel: nil, status: .checkFailed, detail: "'herdr status --json' failed", log: statusResult.combinedLog)
        }

        guard let brew = resolveExecutable("brew") else {
            return CheckOutcome(installedLabel: installed, latestLabel: nil, status: .checkFailed, detail: "Installed \(installed) - Homebrew not found, cannot determine latest", log: statusResult.combinedLog)
        }
        let infoResult = run(brew, ["info", "--json=v2", "herdr"])
        let log = [statusResult.combinedLog, infoResult.combinedLog].filter { !$0.isEmpty }.joined(separator: "\n")
        guard let latest = latestBrewFormulaVersion(from: infoResult.stdout) else {
            return CheckOutcome(installedLabel: installed, latestLabel: nil, status: .checkFailed, detail: "Installed \(installed) - could not determine the latest herdr release", log: log)
        }
        if installed == latest {
            return CheckOutcome(installedLabel: installed, latestLabel: latest, status: .upToDate, detail: "\(installed) - up to date", log: log)
        }
        return CheckOutcome(installedLabel: installed, latestLabel: latest, status: .updateAvailable, detail: "\(installed) \u{2192} \(latest)", log: log)
    }

    private static func updateHerdr() -> UpdateOutcome {
        guard let brew = resolveExecutable("brew") else {
            return UpdateOutcome(ok: false, newVersionLabel: nil, detail: "'brew' not found on PATH", log: "")
        }
        let updateResult = run(brew, ["update"])
        let upgradeResult = run(brew, ["upgrade", "herdr"])
        let log = [updateResult.combinedLog, upgradeResult.combinedLog].filter { !$0.isEmpty }.joined(separator: "\n")
        guard upgradeResult.status == 0 else {
            return UpdateOutcome(ok: false, newVersionLabel: nil, detail: "brew upgrade herdr failed", log: log)
        }
        let version = installedBrewVersion(brew: brew, formula: "herdr", cask: false)
        return UpdateOutcome(ok: true, newVersionLabel: version, detail: "Upgraded to \(version ?? "latest")", log: log)
    }

    // MARK: no-mistakes

    /// no-mistakes has no `--check`/JSON flag either, but every subcommand's
    /// `--help` (itself a safe, side-effect-free no-op that never touches the
    /// shared daemon) prints a stderr banner - "A new version of no-mistakes
    /// is available: vX -> vY" - whenever it's outdated, and prints nothing
    /// when current. That banner is the one real signal available without
    /// running the update itself, so it is parsed rather than guessed at.
    private static func checkNoMistakes() -> CheckOutcome {
        guard let path = resolveExecutable("no-mistakes") else { return missingToolOutcome("no-mistakes") }
        let versionResult = run(path, ["--version"])
        guard versionResult.status == 0, let installed = parseNoMistakesVersion(versionResult.stdout) else {
            return CheckOutcome(installedLabel: "\u{2014}", latestLabel: nil, status: .checkFailed, detail: "'no-mistakes --version' failed", log: versionResult.combinedLog)
        }
        // `--help` on a subcommand is a pure no-op (cobra prints usage and
        // exits before touching the daemon) but still triggers the update
        // banner check.
        let helpResult = run(path, ["doctor", "--help"])
        let log = [versionResult.combinedLog, helpResult.combinedLog].filter { !$0.isEmpty }.joined(separator: "\n")
        guard let latest = parseNoMistakesBannerLatest(helpResult.stderr) else {
            return CheckOutcome(installedLabel: installed, latestLabel: installed, status: .upToDate, detail: "\(installed) - up to date", log: log)
        }
        return CheckOutcome(installedLabel: installed, latestLabel: latest, status: .updateAvailable, detail: "\(installed) \u{2192} \(latest)", log: log)
    }

    /// `"no-mistakes version v1.37.0 (78e4dcb) 2026-07-13T03:11:57Z"` -> `"1.37.0"`.
    /// Scans whitespace-separated tokens for one shaped like `v<digit>...`
    /// rather than the first bare "v" in the string - the literal word
    /// "version" starts with a "v" too, and matching that instead left the
    /// rest of the string ("ersion v1.37.0...") with no leading digits,
    /// silently failing every check (caught live: this is exactly what
    /// happened before this fix).
    private static func parseNoMistakesVersion(_ text: String) -> String? {
        for token in text.split(separator: " ") {
            guard token.hasPrefix("v"), let firstAfterV = token.dropFirst().first, firstAfterV.isNumber else { continue }
            let version = token.dropFirst().prefix { $0.isNumber || $0 == "." }
            return version.isEmpty ? nil : String(version)
        }
        return nil
    }

    /// `"A new version of no-mistakes is available: v1.37.0 -> v1.41.2"` -> `"1.41.2"`.
    private static func parseNoMistakesBannerLatest(_ stderr: String) -> String? {
        guard let arrow = stderr.range(of: "-> v") else { return nil }
        let rest = stderr[arrow.upperBound...]
        let version = rest.prefix { $0.isNumber || $0 == "." }
        return version.isEmpty ? nil : String(version)
    }

    /// Never called by this task's own verification (rule: never restart or
    /// update the shared no-mistakes daemon from an agent session) - wired
    /// for the captain's own explicit click in the running app, same as every
    /// other row. `no-mistakes update` is its own idempotent self-updater
    /// (also resets the shared daemon, which is exactly why only an explicit
    /// human click may trigger it - never an automatic check).
    private static func updateNoMistakes() -> UpdateOutcome {
        guard let path = resolveExecutable("no-mistakes") else {
            return UpdateOutcome(ok: false, newVersionLabel: nil, detail: "'no-mistakes' not found on PATH", log: "")
        }
        let result = run(path, ["update", "-y"])
        guard result.status == 0 else {
            return UpdateOutcome(ok: false, newVersionLabel: nil, detail: "no-mistakes update failed", log: result.combinedLog)
        }
        let versionResult = run(path, ["--version"])
        let version = parseNoMistakesVersion(versionResult.stdout)
        return UpdateOutcome(ok: true, newVersionLabel: version, detail: "Updated to \(version ?? "latest")", log: result.combinedLog)
    }

    // MARK: firstmate (fetch upstream, ff-merge, push to origin)

    /// Runs `bin/fm-sync-upstream.sh --check` (a new script this task's PR
    /// describes but cannot commit into the firstmate repo itself - see the
    /// PR description). Until the captain adds it, this reports `.notInstalled`
    /// rather than failing or fabricating a result.
    private static func checkFirstmate() -> CheckOutcome {
        let script = FirstmateHome.bin.appendingPathComponent("fm-sync-upstream.sh")
        guard FileManager.default.fileExists(atPath: script.path) else {
            return CheckOutcome(
                installedLabel: firstmateLocalLabel(), latestLabel: nil, status: .notInstalled,
                detail: "bin/fm-sync-upstream.sh not found - see this PR's description for the script to add to the firstmate repo",
                log: ""
            )
        }
        let result = run("/bin/bash", [script.path, "--check"], cwd: FirstmateHome.root)
        guard result.status == 0, let parsed = parseSyncLine(result.stdout) else {
            return CheckOutcome(installedLabel: firstmateLocalLabel(), latestLabel: nil, status: .checkFailed, detail: "fm-sync-upstream.sh --check failed", log: result.combinedLog)
        }
        let installed = firstmateLocalLabel()
        switch parsed.status {
        case "already-current":
            return CheckOutcome(installedLabel: installed, latestLabel: "level with upstream", status: .upToDate, detail: parsed.detail, log: result.combinedLog)
        case "would-update":
            return CheckOutcome(installedLabel: installed, latestLabel: "\(parsed.behind) commit(s) behind", status: .updateAvailable, detail: parsed.detail, log: result.combinedLog)
        case "would-merge":
            return CheckOutcome(installedLabel: installed, latestLabel: "\(parsed.behind) commit(s) to merge", status: .updateAvailable, detail: parsed.detail, log: result.combinedLog)
        default:
            // merge-conflict, dirty tree, no upstream remote, etc. - never
            // treated as "safe to auto-update", surfaced as a failed check
            // with the script's own explanation as the detail.
            return CheckOutcome(installedLabel: installed, latestLabel: nil, status: .checkFailed, detail: parsed.detail, log: result.combinedLog)
        }
    }

    private static func updateFirstmate() -> UpdateOutcome {
        let script = FirstmateHome.bin.appendingPathComponent("fm-sync-upstream.sh")
        guard FileManager.default.fileExists(atPath: script.path) else {
            return UpdateOutcome(ok: false, newVersionLabel: nil, detail: "bin/fm-sync-upstream.sh not found", log: "")
        }
        let result = run("/bin/bash", [script.path], cwd: FirstmateHome.root)
        guard result.status == 0, let parsed = parseSyncLine(result.stdout) else {
            return UpdateOutcome(ok: false, newVersionLabel: nil, detail: "fm-sync-upstream.sh failed", log: result.combinedLog)
        }
        switch parsed.status {
        case "updated":
            return UpdateOutcome(ok: true, newVersionLabel: firstmateLocalLabel(), detail: parsed.detail, log: result.combinedLog)
        case "merged":
            return UpdateOutcome(ok: true, newVersionLabel: firstmateLocalLabel(), detail: parsed.detail, log: result.combinedLog)
        case "already-current":
            return UpdateOutcome(ok: true, newVersionLabel: firstmateLocalLabel(), detail: parsed.detail, log: result.combinedLog)
        default:
            return UpdateOutcome(ok: false, newVersionLabel: nil, detail: parsed.detail, log: result.combinedLog)
        }
    }

    private static func firstmateLocalLabel() -> String {
        let branchResult = run("/usr/bin/git", ["-C", FirstmateHome.root.path, "symbolic-ref", "--short", "HEAD"])
        let shaResult = run("/usr/bin/git", ["-C", FirstmateHome.root.path, "rev-parse", "--short", "HEAD"])
        let branch = branchResult.status == 0 && !branchResult.stdout.isEmpty ? branchResult.stdout : "detached"
        let sha = shaResult.status == 0 && !shaResult.stdout.isEmpty ? shaResult.stdout : "unknown"
        return "\(branch) @ \(sha)"
    }

    /// `"status: would-update \u{00B7} ahead: 0 \u{00B7} behind: 12 \u{00B7} 12 commit(s) behind..."`
    /// - the same "key: value \u{00B7} ..." convention `fm-crew-state.sh`
    /// already uses, so this parser mirrors `FleetDataSource.parseCrewLine`.
    private static func parseSyncLine(_ line: String) -> (status: String, ahead: Int, behind: Int, detail: String)? {
        let parts = line.components(separatedBy: "\u{00B7}").map { $0.trimmingCharacters(in: .whitespaces) }
        var status = "", ahead = 0, behind = 0
        var detailParts: [String] = []
        var sawBehind = false
        for part in parts {
            if part.hasPrefix("status:") {
                status = part.dropFirst("status:".count).trimmingCharacters(in: .whitespaces)
            } else if part.hasPrefix("ahead:") {
                ahead = Int(part.dropFirst("ahead:".count).trimmingCharacters(in: .whitespaces)) ?? 0
            } else if part.hasPrefix("behind:") {
                behind = Int(part.dropFirst("behind:".count).trimmingCharacters(in: .whitespaces)) ?? 0
                sawBehind = true
            } else if sawBehind {
                detailParts.append(part)
            }
        }
        guard !status.isEmpty else { return nil }
        return (status, ahead, behind, detailParts.joined(separator: " \u{00B7} "))
    }
}
