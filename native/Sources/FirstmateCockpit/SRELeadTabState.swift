// Manjesh Grand Line - native macOS app.
//
// `fm/grandline-sre-lead-per-tab`: per-tab SRE Lead state. Each `.ssh` tab on
// a dedicated host page now holds its own independent investigation -
// session, bridge, runner, and chat - instead of every tab in the page
// sharing one SRE Lead pinned to whichever tab connected first. This mirrors
// `TabModel.blockTracker`/`blockContainer`, which already live directly on
// `TabModel` for the identical reason: per-tab feature state that outlives a
// tab switch and gets automatic cleanup on tab removal for free, rather than
// a dictionary kept on `ConsoleController` that needs manual bookkeeping (see
// the design doc's Option B, rejected for exactly that reason:
// `data/grandline-sre-lead-per-tab/design-reference.html`).
//
// `ConsoleController`'s `sreLeadPane` stays one shared, fixed slide-open
// panel - every started tab's `chatView` is added as a hidden sibling inside
// it, and only the currently selected tab's is ever shown
// (`ConsoleController.updateSRELeadPaneContent`), the same "hide, don't
// rebuild" convention this app uses everywhere else (block view, Docs tabs,
// Shift's dashboard/weekly-review switch).

import Foundation

/// Per-tab SRE Lead state. `nil` on `TabModel` until the captain explicitly
/// starts SRE Lead for that specific tab - a freshly duplicated tab never
/// inherits or auto-starts one, matching this feature's existing default.
final class SRELeadTabState {
    /// Reuses `SRELeadStatusPill.State` directly rather than a second,
    /// parallel enum with the same four cases - the pill's own state is
    /// always exactly this tab's phase (see `ConsoleController.select`/
    /// `updateSRELeadControls`).
    var phase: SRELeadStatusPill.State = .notStarted
    var session: SRELeadSession?
    var bridge: SRELeadBridge?
    var runner: SRELeadRunner?
    /// Built once, the first time this tab's SRE Lead is started - lazily,
    /// not at `TabModel` construction, so a tab that never touches SRE Lead
    /// never allocates one.
    var chatView: SRELeadChatView?

    /// Stops the bridge's poll timer, cancels any in-flight `claude -p`
    /// turn, and removes every scratch file `SRELead.setUp` wrote for this
    /// tab - mirrors the old page-level `tearDownSRELead()`'s cleanup
    /// exactly, just scoped to one tab's own state so tearing this tab down
    /// can never touch a sibling tab's session. Leaves `chatView` and
    /// `phase` alone - the caller (`ConsoleController.tearDownSRELead(for:)`)
    /// decides what happens to those, since a "torn down because the tab
    /// closed" caller and a "torn down because the pill was toggled off"
    /// caller want different follow-up UI.
    func tearDownSession() {
        bridge?.stop()
        bridge = nil
        runner?.cancel()
        runner = nil
        session?.tearDown()
        session = nil
    }
}
