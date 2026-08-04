// Firstmate Cockpit - native macOS app.
//
// The tab model. Phase 0 of the "cockpit as a connection manager" work (design
// report `data/cockpit-ssh-manager-research/report.md`, Section A4/A5 + Section D
// Phase 0) replaces the old fixed `enum Tab { case shell, mirror }` with a
// flexible collection: the console owns `[TabModel]`, each tab carrying its own
// terminal view, an argv/launch spec, a display name, and its tab-bar chip.
//
// A `TabLaunch` is the reusable "how to (re)start this tab's process" recipe.
// It is what makes **duplicate** trivial - a duplicated tab is a brand new tab
// with the *same* launch - and what **reconnect** re-runs. Adding SSH hosts
// later (Phase 1) is just another `TabLaunch` case.

import AppKit

/// How a tab's child process is (re)started. Kept as a value so duplicating a
/// tab and reconnecting one both reduce to "launch this again".
enum TabLaunch {
    /// A login shell (`$SHELL -l`), the Phase 1 terminal.
    case shell(executable: String, args: [String], cwd: String)
    /// A live mirror of a first-mate tmux target. Each mirror tab sets up its
    /// own grouped session on launch (see `TmuxMirror`), so duplicating a mirror
    /// is safe - the two get different `cockpit_*` group names.
    case mirror(target: String)

    /// The default display name for a freshly created tab of this kind.
    var defaultName: String {
        switch self {
        case .shell: return "Shell"
        case .mirror: return "Mirror"
        }
    }
}

/// One console tab. A reference type because it owns a live terminal view, a
/// mutable name, and (for mirror tabs) a live grouped tmux session. The console
/// keeps these in an ordered array and renders one chip per tab.
final class TabModel {
    let id = UUID()

    /// The user-facing tab name. Renaming changes only this - never the
    /// underlying process (design report A5).
    var name: String

    /// How to (re)start this tab. Duplicate copies it verbatim; reconnect re-runs it.
    let launch: TabLaunch

    /// This tab's terminal. Always a paste-hardening `CockpitTerminalView` so the
    /// screenshot-paste-into-Claude flow works on every tab.
    let terminal: CockpitTerminalView

    /// The live grouped session for a mirror tab; `nil` for shells or a mirror
    /// that failed to attach. Torn down on reconnect, close, and quit.
    var mirror: TmuxMirror?

    /// Whether the child process has been started yet. Tabs created before the
    /// view is on screen defer their launch to `viewDidAppear`.
    var started = false

    /// Set while a tab is being closed so the natural `processTerminated`
    /// callback does not draw a "reconnect" hint into a view we are discarding.
    var isClosing = false

    /// The tab bar chip for this tab, created alongside it.
    var chip: TabChipView!

    init(name: String, launch: TabLaunch, terminal: CockpitTerminalView) {
        self.name = name
        self.launch = launch
        self.terminal = terminal
    }
}
