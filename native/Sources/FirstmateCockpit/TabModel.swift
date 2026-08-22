// Manjesh Grand Line - native macOS app.
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

/// Which live mirror a `.mirror` tab is holding - `TmuxMirror` for a
/// tmux-resolved fleet, `HerdrMirror` for a herdr-resolved one
/// (cockpit-mirror-herdr-aware). `ConsoleController.connectMirror` picks the
/// case from the `kind` already frozen into the tab's `TabLaunch.mirror`
/// (see that case's doc comment for why it is never re-resolved here);
/// nothing else in the console needs to know which backend is active,
/// since both cases expose `tearDown()`.
enum MirrorSession {
    case tmux(TmuxMirror)
    case herdr(HerdrMirror)

    func tearDown() {
        switch self {
        case .tmux(let m): m.tearDown()
        case .herdr(let m): m.tearDown()
        }
    }
}

/// How a tab's child process is (re)started. Kept as a value so duplicating a
/// tab and reconnecting one both reduce to "launch this again".
enum TabLaunch {
    /// A login shell (`$SHELL -l`), the Phase 1 terminal.
    case shell(executable: String, args: [String], cwd: String)
    /// A live attach to the first mate's own session, on whichever backend
    /// firstmate itself resolves to - a read-only tmux mirror (`TmuxMirror`,
    /// still named "Mirror" in the tab bar) or, since
    /// fm/cockpit-mirror-herdr-real-attach, a real interactive `herdr
    /// session attach` client (`HerdrMirror`, named "Herdr" in the tab bar -
    /// it isn't a mirror of anything, it's the genuine herdr TUI), see
    /// `TabModel.mirror`/`TabLaunch.defaultName`. Each sets up its own
    /// backend-appropriate session/process on launch, so duplicating this
    /// tab is safe either way.
    ///
    /// `kind` and `target` are always resolved together, by one call to
    /// `FirstmateBackend.resolveMirrorTarget()`, and then frozen here for
    /// this launch spec's whole lifetime (`fm/grandline-mirror-resolve-race-
    /// fix` - see that function's doc comment for the race this fixes).
    /// Every restart of this tab (first start, `⌘R`, auto-reconnect) reuses
    /// this same stored pair rather than re-resolving - so the backend-kind
    /// decision and the target name it uses can never disagree with each
    /// other, by construction.
    case mirror(kind: FirstmateBackendKind, target: String)
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

    /// The default display name for a freshly created tab of this kind. For
    /// `.mirror`, this reads the `kind` already frozen into this launch spec
    /// (see `TabLaunch.mirror`'s doc comment) rather than calling
    /// `FirstmateBackend.resolve()` again: a tmux fleet still gets "Mirror" -
    /// untouched by fm/cockpit-mirror-herdr-real-attach, since that's still
    /// genuinely a read-only mirror of the captain's tmux session - but a
    /// herdr fleet's tab is a real `herdr session attach` client, not a
    /// mirror of anything, so it's named "Herdr" instead (per the captain's
    /// explicit call in that task).
    var defaultName: String {
        switch self {
        case .shell: return "Shell"
        case .mirror(let kind, _): return kind == .herdr ? "Herdr" : "Mirror"
        case .ssh(let label, _, _, _, _): return label
        }
    }

    /// Groups tabs for the numbered-disambiguation naming convention
    /// (Finding 6, cockpit-audit-core - Console adopting the Tools page's
    /// established "bare kind name for the first instance, N appended for
    /// subsequent concurrent ones" scheme). Unlike `defaultName`, this never
    /// changes with which mirror backend happens to be live right now - two
    /// concurrently open Mirror/Herdr tabs are still the same "kind" for
    /// counting purposes.
    var kindIdentity: String {
        switch self {
        case .shell: return "shell"
        case .mirror: return "mirror"
        case .ssh(let label, _, _, _, _): return "ssh:\(label)"
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
    ///
    /// GL-12 made this `var` for exactly one narrow purpose: the Firstmate
    /// mirror tab is created before its backend has been resolved (resolving it
    /// is three subprocess calls, and doing them synchronously put up to ~9s of
    /// beachball in front of the launch path), so its launch spec is written
    /// once when `FirstmateBackend.resolveMirrorTargetAsync` answers - *before*
    /// the tab's process has ever started. After that it is frozen exactly as
    /// `TabLaunch.mirror`'s doc comment requires: every restart replays this
    /// stored pair and never re-resolves. Nothing else reassigns it.
    var launch: TabLaunch

    /// GL-12: true between "the mirror tab exists" and "its backend has been
    /// resolved". `startTab` refuses to start a tab in this state (there is no
    /// real target to attach to yet) and shows a placeholder line instead; the
    /// resolution's completion starts it.
    var isAwaitingMirrorResolution = false

    /// Set once the captain renames a tab, so a name this app derived (the
    /// mirror tab's "Mirror"/"Herdr", which is only known after resolution)
    /// never overwrites one they chose.
    var hasUserChosenName = false

    /// This tab's terminal. Always a paste-hardening `CockpitTerminalView` so the
    /// screenshot-paste-into-Claude flow works on every tab.
    let terminal: CockpitTerminalView

    /// The live session for a mirror tab (tmux or herdr - see
    /// `MirrorSession`); `nil` for shells or a mirror that failed to attach.
    /// Torn down on reconnect, close, and quit.
    var mirror: MirrorSession?

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

    /// GL-25: true between starting a background Keychain/Touch ID unlock for
    /// this tab and the biometric prompt resolving. Guards against a second
    /// unlock (and therefore a second `startProcess`) being started for the
    /// same tab while the first prompt is still on screen - ⌘R during a
    /// prompt is the easy way to hit that.
    var awaitingKeyUnlock = false

    /// `fm/cockpit-block-view-stage0`: whether this tab is the one, single,
    /// opted-in host page block view applies to (`Host.blockViewOptIn`,
    /// threaded down from `AppShellController.connectHost` through
    /// `ConsoleController.connectSSHIfNeeded`/`openSSH`). `false` for every
    /// other tab, including every other SSH host's tab, the Firstmate
    /// console's Shell/Mirror tabs, and any ad-hoc quick-connect (which has
    /// no `Host` behind it at all) - deliberately narrower than PR #79's
    /// original "every `.shell`/`.ssh` tab" scope and PR #83's "every `.ssh`
    /// tab" scope, per the scout report's recommendation to shrink Stage 0's
    /// blast radius to one captain-chosen host. Combined with
    /// `BlockViewFeature.isEnabled` (both must be true) before
    /// `ConsoleController.addTab` attaches a tracker/container at all.
    var blockViewOptIn = false

    /// Present only when both `blockViewOptIn` and `BlockViewFeature.isEnabled`
    /// were true at tab-creation time - registers the OSC 133 handler on this
    /// tab's `Terminal` and accumulates the parsed block list.
    var blockTracker: TerminalBlockTracker?

    /// Present only alongside `blockTracker` - the block-view rendering,
    /// added as a sibling of `terminal` inside the console's shared content
    /// view, visibility toggled by `ConsoleController.updateBlockViewVisibility`
    /// without ever touching `terminal` or the underlying process.
    var blockContainer: BlockContainerView?

    /// `fm/grandline-sre-lead-per-tab`: this tab's own independent SRE Lead
    /// investigation - `nil` until the captain explicitly starts SRE Lead for
    /// this specific tab (never inherited by a duplicate, never auto-started).
    /// See `SRELeadTabState.swift`'s header for why this lives here rather
    /// than in a dictionary on `ConsoleController`.
    var sreLead: SRELeadTabState?

    init(name: String, launch: TabLaunch, terminal: CockpitTerminalView, accentHex: String? = nil) {
        self.name = name
        self.launch = launch
        self.terminal = terminal
        self.accentHex = accentHex
    }
}
