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
    /// An SSH session to a saved (or ad-hoc) host - Phase 1 of the connection
    /// manager. `ssh` is just another interactive PTY child (design report C1),
    /// so this reuses the same `startProcess` path as `shell`. `hostArgs` is
    /// the non-secret part of the argv (agent forwarding, jump chain, port
    /// forwards, port + destination - see `Host.sshArguments(allHosts:)`);
    /// `keyID`, when set, is a saved key (Phase 2) that `ConsoleController`
    /// resolves through the Keychain into a temporary `-i <path>` on every
    /// start/reconnect - never baked into `hostArgs` itself, so duplicating or
    /// reconnecting this tab always re-resolves the key rather than reusing a
    /// stale temp file. `startupSnippetID` (Phase 3, B2/B5) is a saved
    /// snippet `ConsoleController` sends into the shell, best-effort, once
    /// the session looks ready.
    case ssh(label: String, executable: String, hostArgs: [String], keyID: UUID?, startupSnippetID: UUID?)

    /// The default display name for a freshly created tab of this kind.
    var defaultName: String {
        switch self {
        case .shell: return "Shell"
        case .mirror: return "Mirror"
        case .ssh(let label, _, _, _, _): return label
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

    /// True for a tab opened via `ConsoleController.openCommandTab` - a
    /// one-shot provisioning command (e.g. `rebuild.sh`), not a persistent
    /// shell the captain expects to stay alive. `processTerminated` checks
    /// this to never auto-reconnect such a tab, regardless of the global
    /// "Reconnect automatically" setting or the command's exit code -
    /// otherwise a successful one-shot command looks identical to a dropped
    /// shell and gets endlessly re-run (captain-reproduced: an infinite
    /// `darwin-rebuild switch` loop, re-prompting for the sudo password
    /// every cycle).
    var isOneShotCommand = false

    /// Fires once, with the child's exit code, when a one-shot command tab
    /// (`isOneShotCommand`) terminates - lets a caller (Bootstrap's "Run full
    /// setup" sequencer) know a provisioning step actually finished instead of
    /// polling. `nil` for every other tab kind.
    var onOneShotCompletion: ((Int32?) -> Void)?

    /// The tab bar chip for this tab, created alongside it.
    var chip: TabChipView!

    /// Optional per-tab accent (sRGB hex), set for host sessions so the tab chip
    /// carries the host's colour (A3). `nil` falls back to the theme accent.
    var accentHex: String?

    /// The scratch path of a Phase 2 materialized key, when this tab's `.ssh`
    /// launch resolved a saved key - set by `ConsoleController.connectSSH`, torn
    /// down by `cleanupSSHKeyTempFile` on close, reconnect, and process exit.
    var sshKeyTempPath: String?

    init(name: String, launch: TabLaunch, terminal: CockpitTerminalView, accentHex: String? = nil) {
        self.name = name
        self.launch = launch
        self.terminal = terminal
        self.accentHex = accentHex
    }
}
