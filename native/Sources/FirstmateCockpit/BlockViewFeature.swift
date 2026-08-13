// Manjesh Grand Line - native macOS app.
//
// `fm/cockpit-block-view-stage0`: the Stage 0 kill switch for block view.
// This feature has shipped a launch crash and a real window-layout
// corruption bug on a live SSH session in two prior attempts (both fully
// reverted - see `data/cockpit-block-view-scout/report.md` and
// `data/learnings.md`'s block-view entry). The scout report's explicit
// recommendation for a third attempt was: default OFF (not `AppSettings`
// default-on, which is what turned a niche-feature bug into "crashes on
// every launch" the first time), and env-var gated matching this app's
// existing `FM_LOG_SESSIONS_DEFAULT`/`FM_DOCS_DIR`/etc. convention - see
// `ConsoleController.defaultLoggingEnabled` for the identical pattern this
// mirrors. Re-read on every check (not cached), so flipping the env var
// only takes effect for a fresh process anyway (env vars don't change
// mid-run), but this keeps the shape consistent with every other flag here.
//
// Deliberately NOT an `AppSettings`-backed, UI-toggleable, persisted
// preference in Stage 0 - there is no in-app way to turn this on. Turning it
// on requires launching with `FM_BLOCK_VIEW_ENABLED=1` set, a deliberate
// extra step for a feature with this specific history of shipping broken
// twice. See AGENTS.md's block-view section for what stage this is and
// what's still gated behind it.
import Foundation

enum BlockViewFeature {
    static var isEnabled: Bool {
        guard let v = ProcessInfo.processInfo.environment["FM_BLOCK_VIEW_ENABLED"]?.lowercased() else {
            return false
        }
        return v == "1" || v == "true" || v == "yes"
    }
}
