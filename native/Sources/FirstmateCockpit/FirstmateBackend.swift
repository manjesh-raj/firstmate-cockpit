// Manjesh Grand Line - native macOS app.
//
// Resolves firstmate's OWN configured/auto-detected runtime backend (tmux vs.
// herdr) so the Mirror tab can follow it instead of assuming tmux
// unconditionally (cockpit-mirror-herdr-aware). Firstmate already owns this
// resolution logic end to end - precedence `FM_BACKEND` env, then
// `config/backend`, then runtime auto-detection from markers like
// `HERDR_ENV=1`, then a `tmux` default - in `bin/fm-backend.sh`'s
// `fm_backend_name`/`fm_backend_herdr_session`. This deliberately does not
// reimplement that precedence: it sources the real script and calls the real
// functions, the same "shell out to firstmate's own bin/ script rather than
// re-derive its logic" convention `FleetData.swift`'s `crewState(taskID:)`
// already uses for `fm-crew-state.sh`. That keeps the cockpit's answer
// identical to firstmate's own, even as `fm-backend.sh`'s detection evolves.
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

    /// Resolve the backend firstmate itself would select for a new spawn
    /// right now, by sourcing `bin/fm-backend.sh` and calling its own
    /// `fm_backend_name`. Falls back to `.tmux` (today's default) when the
    /// script is missing or the shell-out fails for any reason - never blocks
    /// the Mirror tab on a resolution error.
    static func resolve() -> FirstmateBackendKind {
        guard let out = runBackendScript("fm_backend_name") else { return .tmux }
        return out.trimmingCharacters(in: .whitespacesAndNewlines) == "herdr" ? .herdr : .tmux
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
        let data = out.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
