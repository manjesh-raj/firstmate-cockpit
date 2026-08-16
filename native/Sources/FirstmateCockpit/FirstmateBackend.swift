// Manjesh Grand Line - native macOS app.
//
// Resolves firstmate's OWN configured/live-detected runtime backend (tmux vs.
// herdr) so the Mirror tab can follow it instead of assuming tmux
// unconditionally (cockpit-mirror-herdr-aware). An explicit override -
// `FM_BACKEND` env, then `config/backend` - is still resolved by sourcing the
// real `bin/fm-backend.sh` and calling its own `fm_backend_name`/
// `fm_backend_herdr_session`, the same "shell out to firstmate's own bin/
// script rather than re-derive its logic" convention `FleetData.swift`'s
// `crewState(taskID:)` already uses for `fm-crew-state.sh`. That keeps the
// cockpit's answer to an explicit override identical to firstmate's own, even
// as `fm-backend.sh`'s config-file/env-var handling evolves.
//
// Absent an explicit override, `fm_backend_name` falls through to
// `fm_backend_detect`'s runtime auto-detection, which answers "what backend
// should a BRAND-NEW CREWMATE SPAWN use" by reading ambient markers
// (`$TMUX`, `HERDR_ENV=1`, ...) from the CALLING PROCESS's own environment -
// correct for a process spawned from within firstmate's own already-running
// session, which genuinely inherits that marker. It is the wrong question for
// this Cockpit app: the app is a standalone GUI launched by Finder/`open`,
// never spawned by herdr or tmux, so its own process environment can
// STRUCTURALLY never carry `HERDR_ENV=1` even when herdr is the fleet's real,
// live backend (cockpit-mirror-backend-resolve-fix, a follow-up to
// cockpit-mirror-herdr-aware found live: this always fell through to the
// final `tmux` default and silently reproduced the pre-herdr-support "no
// server running" bug). So `resolve()` below deliberately does NOT call
// `fm_backend_name` when no explicit override is set - do not "simplify" this
// back to a single `fm_backend_name` shell-out; that would reintroduce the
// exact bug this file was patched for. Instead it asks a genuinely different
// question - "what backend does the ambient fleet actually appear to be
// running on, right now" - via live evidence: a real, running herdr session
// matching `herdrSessionName()`, checked directly against herdr's own current
// CLI surface (`herdr session list --json`). There is no separate live-tmux
// check: `.tmux` is already the answer for every other case (explicit tmux,
// no live herdr evidence, herdr not installed, the shell-out failing), so
// checking for live herdr evidence is the only thing that can flip the
// answer away from that default - which is exactly "prefer whichever backend
// shows live evidence, falling back to tmux when neither does" collapsed to
// its one decision-relevant check.
//
// Only `tmux` and `herdr` are given a native Mirror implementation here
// (`TmuxMirror`/`HerdrMirror`); `fm-backend.sh` also names `zellij`, `orca`,
// and `cmux` as experimental backends, but this task's scope is tmux/herdr
// only (per its brief). Any backend name other than exactly `herdr` resolves
// to `.tmux` here, which reproduces today's pre-existing behavior for those
// backends unchanged (an unsupported-backend fleet already got a tmux-shaped
// "no such session" error before this task; it still does).

import Foundation

enum FirstmateBackendKind: Equatable {
    case tmux
    case herdr
}

enum FirstmateBackend {

    /// Resolve which backend the Mirror tab should follow right now. An
    /// explicit `FM_BACKEND`/`config/backend` override always wins, read via
    /// `explicitOverride()`. Absent one, this asks for live evidence instead
    /// of falling through to `fm_backend_name`'s ambient-marker auto-detect
    /// (see this file's header comment for why that path can never fire for
    /// this standalone app). Falls back to `.tmux` (today's default) on any
    /// failure along the way - never blocks the Mirror tab on a resolution error.
    static func resolve() -> FirstmateBackendKind {
        if let explicit = explicitOverride() {
            return explicit == "herdr" ? .herdr : .tmux
        }
        return hasLiveHerdrSession() ? .herdr : .tmux
    }

    /// Atomically resolves both which backend a Mirror tab should use AND
    /// the target name it should attach to, from a single live-evidence
    /// check - the two must never be decided by separate calls to
    /// `resolve()`/`hasLiveHerdrSession()`.
    ///
    /// `fm/grandline-mirror-resolve-race-fix`: right after a machine
    /// restart, herdr's own background server can take a few seconds to
    /// come up. The previous code called `resolve()` twice for one Mirror
    /// tab - once at tab-creation time (`mirrorTarget()`, to pick the
    /// launch spec's target string) and again, moments later, at actual
    /// connect time (`ConsoleController.connectMirror`, to pick
    /// `TmuxMirror` vs. `HerdrMirror`). If herdr flipped from down to up in
    /// that window, the first call fell back to `.tmux` (baking in the
    /// tmux-era literal target `"firstmate"`) while the second call
    /// resolved `.herdr` - so the tab ran the herdr connection path against
    /// a stale, wrong target name, producing exactly the captain-reported
    /// `[herdr] Cannot mirror 'firstmate': no running herdr session named
    /// 'firstmate'` error even though herdr's real session (`default`) was
    /// genuinely live. Every caller that needs both pieces together
    /// (`TabLaunch.defaultName`, `ConsoleController.openFirstmateHost`) must
    /// get them from this one function - never pair a separate `resolve()`
    /// call with a separately-derived target. `TabModel.launch` then keeps
    /// this result frozen for the tab's whole lifetime (per `TabLaunch`'s
    /// own "reusable recipe" contract - see its header comment): `⌘R`/
    /// auto-reconnect replay the same resolved kind+target rather than
    /// resolving again, so a reconnect can never introduce a fresh
    /// disagreement either. This preserves the existing override contract
    /// unchanged (`FM_MIRROR_TARGET`/Settings' "Mirror target" still wins,
    /// verbatim, regardless of which backend is live).
    static func resolveMirrorTarget() -> (kind: FirstmateBackendKind, target: String) {
        let kind = resolve()
        if let override = explicitMirrorTargetOverride() {
            return (kind, override)
        }
        return (kind, kind == .herdr ? herdrSessionName() : "firstmate")
    }

    /// `FM_MIRROR_TARGET`, then Settings > General's "Mirror target" - see
    /// `TerminalEnvironment.swift`'s `mirrorTarget()` header for the full
    /// override contract. Factored out so `resolveMirrorTarget()` can apply
    /// it without a second, independent resolve.
    private static func explicitMirrorTargetOverride() -> String? {
        let env = ProcessInfo.processInfo.environment
        if let t = env["FM_MIRROR_TARGET"], !t.trimmingCharacters(in: .whitespaces).isEmpty {
            return t.trimmingCharacters(in: .whitespaces)
        }
        if let saved = AppSettings.shared.mirrorTarget, !saved.trimmingCharacters(in: .whitespaces).isEmpty {
            return saved.trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    /// The explicit `FM_BACKEND`/`config/backend` override, if any, resolved
    /// by sourcing `bin/fm-backend.sh` and calling its own `fm_backend_name` -
    /// but with `fm_backend_detect` stubbed out first so a missing override
    /// falls through to a sentinel instead of real ambient-marker
    /// auto-detection (which this caller must never invoke; see the header
    /// comment). `nil` means no explicit override is set - NOT that the
    /// answer is `tmux` - so callers can tell "explicitly configured tmux"
    /// apart from "nothing configured, go do live-evidence detection".
    private static func explicitOverride() -> String? {
        let sentinel = "__FM_COCKPIT_NO_EXPLICIT_OVERRIDE__"
        let stub = "fm_backend_detect() { FM_BACKEND_DETECTED=\"\(sentinel)\"; FM_BACKEND_DETECT_SIGNAL=\"\"; return 0; }"
        guard let out = runBackendScript("\(stub); fm_backend_name") else { return nil }
        let trimmed = out.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed == sentinel ? nil : trimmed
    }

    /// Live evidence that the ambient fleet is actually running on herdr
    /// right now: a named herdr session matching `herdrSessionName()` that
    /// herdr itself reports as running, via `herdr session list --json` (the
    /// current CLI surface for this - verified live, no assumed flags).
    /// `false` on any failure (herdr not installed, no server, bad JSON) -
    /// that is indistinguishable from "no live herdr evidence" here, which is
    /// correct: it means fall back to `.tmux`.
    private static func hasLiveHerdrSession() -> Bool {
        guard let herdr = HerdrMirror.resolveHerdr() else { return false }
        let session = herdrSessionName()
        // Finding 10 (cockpit-audit-core): `resolve()` runs synchronously on
        // the main thread at several call sites (app launch, every Mirror tab
        // (re)start, `reconnectActive`, `renameTab`'s empty-name fallback).
        // 73ms measured live is cheap, but nothing bounded it - a slow/hung
        // `herdr` invocation would freeze the whole UI for however long that
        // takes. `HerdrMirror.run` doesn't expose its `Process` to kill
        // outright, so bound the wait itself: run it on a background queue
        // and give up after `subprocessTimeout` if it hasn't returned,
        // falling back to "no live evidence" (-> `.tmux`, today's existing
        // default for every other failure mode here) rather than hanging.
        guard let result = runWithTimeout(subprocessTimeout, work: {
            HerdrMirror.run(herdr, ["session", "list", "--json"], session: session, env: childEnvironmentDict())
        }) else { return false }
        guard result.status == 0, let data = result.stdout.data(using: .utf8) else { return false }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sessions = obj["sessions"] as? [[String: Any]] else { return false }
        return sessions.contains { ($0["name"] as? String) == session && ($0["running"] as? Bool) == true }
    }

    /// How long `resolve()`'s subprocess calls are allowed to block the
    /// caller (usually the main thread) before giving up and falling back to
    /// this file's existing "any failure -> `.tmux`" default.
    private static let subprocessTimeout: TimeInterval = 3

    /// Runs `work` (itself a blocking call) on a background queue and waits
    /// up to `timeout` - `nil` if it hasn't finished by then. The background
    /// work is left to finish on its own in that case (there's no handle to
    /// cancel it), but the caller is no longer blocked on it.
    private static func runWithTimeout<T>(_ timeout: TimeInterval, work: @escaping () -> T) -> T? {
        let sema = DispatchSemaphore(value: 0)
        var result: T?
        DispatchQueue.global(qos: .userInitiated).async {
            result = work()
            sema.signal()
        }
        _ = sema.wait(timeout: .now() + timeout)
        return result
    }

    /// The herdr session firstmate itself would target for its own ambient
    /// commands, by sourcing `bin/fm-backend.sh`, loading the herdr adapter,
    /// and calling `fm_backend_herdr_session` (`${HERDR_SESSION:-default}`).
    /// Falls back to the same `"default"` literal that function itself falls
    /// back to when the shell-out fails.
    static func herdrSessionName() -> String {
        guard let out = runBackendScript("fm_backend_source herdr >/dev/null 2>&1 && fm_backend_herdr_session") else {
            return "default"
        }
        let trimmed = out.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "default" : trimmed
    }

    /// Source `bin/fm-backend.sh` under `/bin/bash` and run `command`,
    /// returning its stdout (stderr discarded - `fm_backend_name` prints an
    /// informational NOTICE there on auto-detect, which is not part of the
    /// answer). `nil` on any failure to launch or a nonzero exit.
    private static func runBackendScript(_ command: String) -> String? {
        let script = FirstmateHome.bin.appendingPathComponent("fm-backend.sh")
        guard FileManager.default.fileExists(atPath: script.path) else { return nil }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/bash")
        proc.arguments = ["-c", "source \"$1\" >/dev/null 2>&1 && \(command)", "--", script.path]
        proc.currentDirectoryURL = FirstmateHome.root
        var env = childEnvironmentDict()
        env["FM_HOME"] = FirstmateHome.root.path
        proc.environment = env
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = Pipe()
        do { try proc.run() } catch { return nil }

        // Finding 10: bound this the same way `FleetData.crewState`'s
        // watchdog does - a real, hard-kill timeout, since this call owns
        // its own `Process` and can terminate it directly (unlike
        // `hasLiveHerdrSession`'s wrapped `HerdrMirror.run` call above).
        let exited = DispatchSemaphore(value: 0)
        proc.terminationHandler = { _ in exited.signal() }
        if exited.wait(timeout: .now() + subprocessTimeout) == .timedOut {
            proc.terminationHandler = nil
            if proc.isRunning { proc.terminate() }
            return nil
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        guard proc.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
