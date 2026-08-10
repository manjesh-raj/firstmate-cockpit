// Manjesh Grand Line - native macOS app.
//
// Locates the firstmate home exactly like `backend/config.py`'s
// `_find_fm_home` does, so the native Fleet dashboard (Fix 1) reads the same
// on-disk state the web cockpit does: `FM_HOME`/`FIRSTMATE_HOME` first, then
// the Bootstrap page's `AppSettings.fmHome` (cockpit-bootstrap-scaffold - the
// user-editable override for a machine/account where neither env var nor the
// hardcoded candidates below are correct), then a couple of conventional
// locations, falling back to the first candidate so callers can surface a
// clear "home not found" state instead of crashing.

import Foundation

enum FirstmateHome {
    static let root: URL = resolve()
    static var bin: URL { root.appendingPathComponent("bin") }
    static var data: URL { root.appendingPathComponent("data") }
    static var state: URL { root.appendingPathComponent("state") }
    static var projects: URL { root.appendingPathComponent("projects") }

    /// `at` defaults to the live, already-resolved `root` - callers
    /// validating a not-yet-saved Bootstrap candidate path pass it
    /// explicitly instead.
    static func homeOk(at candidate: URL = root) -> Bool {
        FileManager.default.fileExists(atPath: candidate.appendingPathComponent("bin/fm-crew-state.sh").path)
    }

    private static func resolve() -> URL {
        let env = ProcessInfo.processInfo.environment
        if let v = (env["FM_HOME"] ?? env["FIRSTMATE_HOME"]), !v.isEmpty {
            return URL(fileURLWithPath: (v as NSString).expandingTildeInPath).standardizedFileURL
        }
        if let v = AppSettings.shared.fmHome, !v.isEmpty {
            return URL(fileURLWithPath: (v as NSString).expandingTildeInPath).standardizedFileURL
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = [
            home.appendingPathComponent("manjesh/firstmate"),
            home.appendingPathComponent("firstmate"),
        ]
        let fm = FileManager.default
        for c in candidates {
            if fm.fileExists(atPath: c.appendingPathComponent("AGENTS.md").path)
                || fm.fileExists(atPath: c.appendingPathComponent("bin/fm-crew-state.sh").path) {
                return c
            }
        }
        return candidates[0]
    }
}
