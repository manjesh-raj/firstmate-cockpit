// Firstmate Cockpit - native macOS app.
//
// Child-process launch details for the two terminals, mirroring the choices the
// Python backend makes in `backend/shell.py` and `backend/terminal.py`. Kept as
// free functions so both the Shell tab and the Mirror tab share exactly one
// definition of "how a cockpit terminal child is spawned".

import AppKit
import Foundation

// MARK: - Shell launch (mirrors backend/shell.py)

/// The operator's login shell (`$SHELL -l`), falling back to `bash -i`, exactly
/// like `_shell_argv()` in `backend/shell.py`.
func shellArgv() -> (executable: String, args: [String]) {
    if let shell = ProcessInfo.processInfo.environment["SHELL"],
       FileManager.default.fileExists(atPath: shell) {
        return (shell, ["-l"])
    }
    return ("/bin/bash", ["-i"])
}

/// Where the shell opens: `FM_SHELL_CWD` if it is a directory, else `$HOME`.
/// (The Python app also considers the firstmate home; the native console has no
/// backend yet, so we keep just the honoured override plus home.)
func shellCwd() -> String {
    let env = ProcessInfo.processInfo.environment
    if let override = env["FM_SHELL_CWD"] {
        let expanded = (override as NSString).expandingTildeInPath
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: expanded, isDirectory: &isDir), isDir.boolValue {
            return expanded
        }
    }
    return FileManager.default.homeDirectoryForCurrentUser.path
}

/// Environment for a terminal child, mirroring `terminal.py`/`shell.py`:
/// force `TERM=xterm-256color` and a UTF-8 locale (a Finder-launched GUI app
/// inherits no LANG/LC_ALL), and drop `TMUX` so this is a fresh, un-nested
/// shell/client. Returned as SwiftTerm's `KEY=VALUE` array form.
func childEnvironment() -> [String] {
    childEnvironmentDict().map { "\($0.key)=\($0.value)" }
}

/// The same environment as a dictionary, for the `Process`-based tmux plumbing
/// (see `TmuxMirror`), which needs a `[String: String]` rather than the
/// `KEY=VALUE` array SwiftTerm's `startProcess` wants.
func childEnvironmentDict() -> [String: String] {
    var env = ProcessInfo.processInfo.environment
    env["TERM"] = "xterm-256color"
    env["LANG"] = "en_US.UTF-8"
    env["LC_ALL"] = "en_US.UTF-8"
    env.removeValue(forKey: "TMUX")
    return env
}

// MARK: - Mirror target

/// The first mate's tmux target the Mirror tab attaches to. Configurable via
/// `FM_MIRROR_TARGET` (e.g. `firstmate` or `firstmate:1`), defaulting to the
/// `firstmate` session. Full target-detection UI is Phase 3; this is the simple
/// single-target hook the brief asks for.
func mirrorTarget() -> String {
    let env = ProcessInfo.processInfo.environment
    if let t = env["FM_MIRROR_TARGET"], !t.trimmingCharacters(in: .whitespaces).isEmpty {
        return t.trimmingCharacters(in: .whitespaces)
    }
    return "firstmate"
}
