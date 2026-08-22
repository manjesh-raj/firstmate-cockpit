// Manjesh Grand Line - native macOS app.
//
// GL-11 (production-readiness review, section 20): before this file, all
// production logging in ~80k lines of Swift was seven `NSLog` calls and a
// handful of stray `print`s. There was no `os.Logger`/`os_log` anywhere, and
// the dominant error-handling shape was `catch { return nil }` - so when the
// Overview PR list came back empty, "gh isn't installed", "the JSON was
// malformed" and "the network is down" were literally indistinguishable, and
// when the 15-minute background poller wedged, notifications went stale
// forever with no signal to anyone.
//
// This is the one logging surface. Two rules, both of which the review's
// section 20 asks for explicitly:
//
//  1. **Every catch-and-degrade site logs the underlying error before it
//     degrades.** Degrading quietly is what made the failures above
//     invisible; degrading loudly is still degrading, and costs nothing.
//  2. **Nothing here leaves the machine.** `os.Logger` writes to the local
//     unified log, readable in Console.app or `log show`. There is no
//     telemetry in this app and this file does not introduce any - which is
//     also why every message is `public` rather than redacted-by-default:
//     these logs are for the one person who owns the machine.
//
// On secrets: this app's own convention is that a secret never reaches a log
// (swept and verified during the review). `os.Logger`'s default string
// interpolation privacy is `.private` in the unified log, but do not rely on
// that as a redaction mechanism - the rule is still "don't log the value",
// exactly as it was before. Where a value is genuinely sensitive and still
// worth logging *something* about, log its shape (a kind, a length, a
// fingerprint), the way `LogRedactor` already does.
//
// Category names are the review's own list: subprocess runs, pollers, git
// sync, keychain, stores. Two more (`ui`, `ai`) exist because they carry real
// failure paths that would otherwise land in the wrong bucket.

import Foundation
import os

enum AppLog {

    /// One subsystem for the whole app, matching the bundle identifier the
    /// packaged app actually ships with (`build_native_app.sh`) so `log show
    /// --predicate 'subsystem == "com.firstmate.cockpit.native"'` finds
    /// everything at once. Deliberately a literal rather than
    /// `Bundle.main.bundleIdentifier`, which is `nil` for the plain
    /// `swift build` binary this project's own README documents as the normal
    /// dev workflow - an unbundled run must still log to the same place.
    static let subsystem = "com.firstmate.cockpit.native"

    /// Every `Process` this app spawns, through `Subprocess` (GL-15). The
    /// review calls this "the natural first call site" for logging because a
    /// single choke point instantly covers most of the app's failure paths.
    static let subprocess = Logger(subsystem: subsystem, category: "subprocess")

    /// `BackgroundSignalsPoller`, `FleetNotifier`, `ShiftNotificationScheduler`
    /// - the three surfaces that had zero log statements and whose death is
    /// invisible by construction (GL-03).
    static let poller = Logger(subsystem: subsystem, category: "poller")

    /// `ShiftGitSync`, `DocsRunbookGitSync`, `VaultRecipeGit`,
    /// `GitHubSyncSource` - anything that fetches, commits or pushes.
    static let gitSync = Logger(subsystem: subsystem, category: "git-sync")

    /// `KeychainKeyStore`, `SSHKeyGenerator`, `SSHKeyMaterializer`, the
    /// LAContext gate. Never the material itself.
    static let keychain = Logger(subsystem: subsystem, category: "keychain")

    /// Load/decode/persist paths for every store, including the durability
    /// failures Phase 1's `StoreLoadFailure` already backs up (GL-01) and the
    /// write failures Phase 2 now surfaces (GL-10).
    static let store = Logger(subsystem: subsystem, category: "store")

    /// Network fetches that are not git: the GitHub REST calls in
    /// `DocsData`/`BackupGitHub`/`GitHubSyncData`, the Whisper model download.
    static let network = Logger(subsystem: subsystem, category: "network")

    /// `claude -p` one-shots (`ClaudeOneShot`) and the SRE Lead bridge.
    static let ai = Logger(subsystem: subsystem, category: "ai")

    /// Controller-level failures worth a breadcrumb: a missing SF Symbol, a
    /// destination that could not present, a background refresh that came
    /// back degraded.
    static let ui = Logger(subsystem: subsystem, category: "ui")

    /// App lifecycle: launch, lock/unlock, single-instance, shutdown.
    static let lifecycle = Logger(subsystem: subsystem, category: "lifecycle")
}
