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

    // MARK: App-level password lock (fm/grandline-app-lock)

    /// The one fixed secret name the app-level lock screen checks/verifies
    /// against - the captain sets its value themselves via `av save` or the
    /// Vault tab's own save flow; this app never writes it and never builds
    /// a first-run setup screen for it.
    static let appPasswordSecretName = "GRANDLINE_APP_PASSWORD"

    /// GL-31: the exact command a captain has to run to set the app password
    /// on a fresh machine, in one place, so the lock screen's copyable row and
    /// `setup-guide.md` cannot drift apart.
    static var appPasswordSetupCommand: String { "av save \(appPasswordSecretName)" }

    enum AppPasswordAvailability {
        case configured
        case notConfigured
        /// `av` itself isn't on PATH at all - genuinely not installed on
        /// this Mac. Distinct from `.serviceNotRunning` below: there is no
        /// service to start here, `av` has to be installed first.
        case avUnavailable
        /// `av` is on PATH but `av list` failed specifically because its
        /// background approval service (the "Automic Vault" menu-bar app)
        /// isn't running - e.g. right after a reboot, before the app has
        /// been launched, or if it was quit. The password secret may well
        /// already exist; `av` just can't reach the service to say so, so
        /// this must never be reported/treated as `.notConfigured`.
        case serviceNotRunning
        /// `av list` failed (or never returned at all) for a reason that is
        /// neither a clean success, a clean "genuinely no secret" result,
        /// nor the specific `serviceNotRunningMarker` text - e.g. the
        /// approval helper being transiently unresponsive right after a
        /// long sleep/wake. Confirmed live (fm/grandline-vault-wake-recheck-
        /// fix): suspending the "Automic Vault" menu-bar helper process
        /// makes a plain `av list` hang indefinitely with no output at all
        /// (still blocked after 90+s, no internal timeout of its own) - the
        /// exact captain-reported symptom this case exists to fix, since
        /// the previous code had no third bucket and silently reclassified
        /// *any* non-marker failure as `.avUnavailable` ("isn't installed"),
        /// which is false whenever av is genuinely installed and the
        /// service is merely slow to respond. The password secret may well
        /// already exist here too; never report/treat this as
        /// `.notConfigured`/`.avUnavailable`. `AppShellController` retries
        /// on the same cadence as `.serviceNotRunning`.
        case transientFailure
    }

    /// Substring `av list` prints (to stdout or stderr - `combinedLog`
    /// covers both) when its background approval service isn't reachable,
    /// confirmed live against a real `av list` call with the "Automic Vault"
    /// menu-bar app quit. Matched case-insensitively since av's exact
    /// capitalization isn't a documented contract.
    private static let serviceNotRunningMarker = "approval service is not running"

    /// The real executable behind "Automic Vault.app" - confirmed live via
    /// `launchctl print gui/<uid>/com.automicvault.menubar-helper` that the
    /// app bundle, its `LSUIElement: true` menu-bar helper role, and its full
    /// "Detectors/Hardened Tools/Secrets" window UI are all ONE process, not
    /// two - `pgrep -x` against this name is what `isServiceRunning()` below
    /// checks.
    private static let menubarHelperProcessName = "AutomicVaultMenubar"

    /// Whether Automic Vault's helper process is already running, via a
    /// plain `pgrep -x` (confirmed live: exits 0 with the real PID when
    /// running, 1 with no output when not) - checked so
    /// `ensureServiceRunning()` below can skip calling `open` entirely on the
    /// (near-universal, since the helper is kept alive by its own
    /// `RunAtLoad: true` LaunchAgent independent of this app) already-running
    /// case. Not `private` - exercised directly by `VaultDataSelfTest`.
    static func isServiceRunning() -> Bool {
        // GL-02: both of those `Pipe()`s used to be attached and never read -
        // the third deadlock shape. `pgrep` output is tiny so it never bit,
        // but nothing about the code said so.
        return Subprocess.run(executable: "/usr/bin/pgrep",
                              arguments: ["-x", menubarHelperProcessName],
                              timeout: 10, stdout: .discard, stderr: .discard).ok
    }

    /// Fire-and-forget attempt to start Automic Vault's background approval
    /// service (its menu-bar app) if - and only if - it isn't already
    /// running.
    ///
    /// Real, live-root-caused bug this guards against
    /// (fm/grandline-vault-no-unnecessary-relaunch): Automic Vault's real
    /// main window (its "Detectors/Hardened Tools/Secrets" browser, not just
    /// a menu-bar icon) was still visibly popping up on every Grand Line
    /// launch/relock, despite the `-g` flag below. `-g` only stops *this*
    /// `open` call from bringing Automic Vault to the foreground/giving it
    /// keyboard focus - it does not stop the app's own code from
    /// creating/showing a window on reactivation, which is exactly what
    /// macOS's `open -a`/"reopen" handling triggers when told to open an
    /// app that is already running. Since the helper is kept alive
    /// independently by its own `RunAtLoad: true` LaunchAgent
    /// (`~/Library/LaunchAgents/com.automicvault.menubar-helper.plist`), it
    /// is almost always already running by the time this is called - so the
    /// old unconditional `open -g -a` fired the reopen/window-restore path
    /// on nearly every single launch. The actual fix is to never call `open`
    /// at all when the service is already alive - `isServiceRunning()`
    /// above is the check - not to look for a stronger "stay hidden" flag,
    /// since `open` has none for an already-running app's own reactivation
    /// behavior.
    ///
    /// Safe to call before the captain has unlocked anything - this only
    /// starts Automic Vault's own helper, never touches this app's lock
    /// state - and never blocks: `open` returns almost immediately
    /// regardless of whether the launched app has finished starting.
    static func ensureServiceRunning() {
        guard !isServiceRunning() else { return }
        Subprocess.run(executable: "/usr/bin/open",
                       arguments: ["-g", "-a", "Automic Vault"],
                       timeout: 15, stdout: .discard, stderr: .discard)
    }

    /// Bounds how long the app-lock recheck waits for `av list` before
    /// treating it as a transient failure rather than blocking forever -
    /// see `AppPasswordAvailability.transientFailure`'s doc comment for the
    /// live-confirmed hang this guards against. `loadSnapshot()`'s own
    /// (unbounded) `run` calls are unaffected - this timeout is scoped to
    /// the app-lock check only.
    private static let appPasswordCheckTimeout: TimeInterval = 5

    /// Read-only - reuses the exact `av list` call `loadSnapshot()` already
    /// makes, just without the heavier `--version`/`doctor --json` calls the
    /// full Vault-page snapshot also needs.
    static func checkAppPasswordConfigured() -> AppPasswordAvailability {
        guard let av = resolveExecutable("av") else { return .avUnavailable }
        guard let result = runWithTimeout(av, ["list"], timeout: appPasswordCheckTimeout) else {
            // Didn't return at all within the timeout - see
            // `transientFailure`'s doc comment for the live-reproduced hang.
            return .transientFailure
        }
        guard result.status == 0 else {
            if result.combinedLog.lowercased().contains(serviceNotRunningMarker) {
                return .serviceNotRunning
            }
            // Any other non-zero exit is an unrecognized/ambiguous failure
            // (e.g. a real approval-XPC error distinct from the "not
            // running" marker) - not a clean "no av"/"no secret" result, so
            // it must not be silently reclassified as either hard state.
            return .transientFailure
        }
        let names = result.stdout.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        return names.contains(appPasswordSecretName) ? .configured : .notConfigured
    }

    /// Verifies `typed` against the real secret value without ever letting
    /// the value - or the typed guess - pass through this app's own memory
    /// beyond one environment variable handed to the comparison shell.
    /// Mirrors `injectCommand`'s "av inject +NAME -- command" mechanism used
    /// by the Vault page's "Run injected..." action, but run directly as a
    /// background `Process` (like `av list`/`av doctor` above) rather than
    /// through a visible Console tab: a password check has no output worth
    /// showing the captain and must not depend on a terminal tab being open.
    /// The typed guess travels via `GRANDLINE_LOCK_CANDIDATE` in the child's
    /// environment, never spliced into the shell command text or argv, so it
    /// never appears in a process listing's command column.
    static func verifyAppPassword(_ typed: String) -> Bool {
        guard let av = resolveExecutable("av") else { return false }
        // The typed candidate travels as an environment variable, never argv -
        // `Subprocess`'s `extraEnv` is the one channel for that, and its own
        // self-test asserts such a value never reaches the child's argv.
        return Subprocess.run(
            executable: av,
            arguments: [
                "inject", "+\(appPasswordSecretName)", "--",
                "/bin/sh", "-c", "[ \"$\(appPasswordSecretName)\" = \"$GRANDLINE_LOCK_CANDIDATE\" ]",
            ],
            extraEnv: ["GRANDLINE_LOCK_CANDIDATE": typed],
            timeout: appPasswordCheckTimeout,
            log: AppLog.keychain, label: "av inject (app lock)"
        ).ok
    }

    // MARK: Process plumbing

    // GL-15: `resolveExecutable`, `RunResult`, `run` and `runWithTimeout` all
    // come from `Subprocess` now. `runWithTimeout`'s bounded-wait shape (which
    // `QuotaData` had also copied) is what became the shared runner's default
    // behaviour, so the distinction between the two local runners is gone: every
    // `av` call is bounded, including the `loadSnapshot()` ones that previously
    // were not.

    private static func resolveExecutable(_ name: String) -> String? {
        Subprocess.resolveExecutable(name)
    }

    private typealias RunResult = SubprocessResult

    /// `av list`/`av doctor --json` are local Keychain reads that normally
    /// answer in milliseconds; the documented failure mode is the approval
    /// helper being unresponsive, which used to hang forever.
    private static let avTimeout: TimeInterval = 30

    /// Returns `nil` on timeout, preserving the caller shape
    /// `checkAppPasswordConfigured` already branches on (`nil` means
    /// `.transientFailure`).
    private static func runWithTimeout(_ executable: String, _ args: [String], timeout: TimeInterval) -> RunResult? {
        let result = Subprocess.run(executable: executable, arguments: args,
                                    timeout: timeout, log: AppLog.keychain)
        return result.timedOut ? nil : result
    }

    private static func run(_ executable: String, _ args: [String]) -> RunResult {
        Subprocess.run(executable: executable, arguments: args,
                       timeout: avTimeout, log: AppLog.keychain)
    }
}
