// Manjesh Grand Line - native macOS app.
//
// Shared "is this setup step done" logic (fm/grandline-automation-pipeline),
// extracted out of `BootstrapController` so the new `.automation` destination
// (`AutomationController`) can decide whether to skip or run a step using the
// *exact* same rules Bootstrap's own vertical stepper and drift check already
// use - not a second, possibly-drifting reimplementation of "is dotfiles up
// to date," "is the software checklist clean," etc. `BootstrapController`'s
// own `stepIsDone(_:)` is now a thin wrapper delegating to these functions;
// `AutomationController` calls them directly against its own independently-
// fetched state (mirroring how `UpdatesController` and `BootstrapController`
// already each keep their own cached check results for the same underlying
// `DependencyCatalog`, rather than sharing one mutable cache).
//
// `SetupStepKind` itself lives here too, since both pages iterate the same
// five steps. `SetupStepKind.isPartOfFullSetupSequence` (Bootstrap-specific:
// its own "Run full setup" sequencer deliberately excludes `.restoreConfig`)
// stays defined in `BootstrapController.swift` as an extension, per this
// task's brief - it must not change, and it has no meaning for Automation's
// own sequencer, which always runs all five steps.

import Foundation

enum SetupStepKind: CaseIterable, Hashable {
    case firstmateHome, dotfiles, agentInstructions, software, restoreConfig

    var title: String {
        switch self {
        case .firstmateHome: return "Firstmate home"
        case .dotfiles: return "Dotfiles & machine config"
        case .agentInstructions: return "Global agent instructions"
        case .software: return "Software checklist"
        case .restoreConfig: return "Restore Grand Line config"
        }
    }

    /// Mirrors the concept each step's own content already represents
    /// elsewhere (the home path field, the dotfiles repo state, the
    /// AGENTS.md/CLAUDE.md symlinks, the software catalog, the backup
    /// import).
    var symbol: String {
        switch self {
        case .firstmateHome: return "house"
        case .dotfiles: return "gearshape"
        case .agentInstructions: return "doc.text"
        case .software: return "checklist"
        case .restoreConfig: return "tray.and.arrow.down"
        }
    }
}

/// Pure "is this step satisfied right now" predicates - every function takes
/// already-fetched state as parameters rather than reading `self` off a
/// specific controller, so both `BootstrapController` and
/// `AutomationController` can call the identical logic against their own
/// independently-cached copies of the same underlying checks.
enum SetupStepChecks {
    static func firstmateHomeDone() -> Bool {
        FirstmateHome.homeOk(at: FirstmateHome.root)
    }

    /// `nil` means "still checking" - the background dotfiles refresh this
    /// depends on hasn't returned yet.
    static func dotfilesDone(isLoading: Bool, repoPath: String?, state: DotfilesRepoState?) -> Bool? {
        guard !isLoading else { return nil }
        guard repoPath != nil else { return false }
        guard let state else { return false }
        guard state.dirtyFiles.isEmpty else { return false }
        if let behind = state.commitsBehindOrigin, behind > 0 { return false }
        return true
    }

    static func agentInstructionsDone(isLoading: Bool, items: [AgentInstructionsItem]) -> Bool? {
        guard !isLoading else { return nil }
        return !items.isEmpty && items.allSatisfy { $0.status == .linked }
    }

    static func softwareDone(isLoading: Bool, statuses: [DependencyStatus]) -> Bool? {
        guard !isLoading else { return nil }
        return !statuses.contains(.notInstalled)
    }

    /// "Done" once there's something local to show for it - either a real
    /// import already happened, or the captain built up hosts/snippets by
    /// hand. Never depends on a bundle file existing, so it's never stuck
    /// "pending" on a machine that doesn't use this feature at all.
    static func restoreConfigDone(hostCount: Int, snippetCount: Int) -> Bool {
        hostCount > 0 || snippetCount > 0
    }
}

/// The one command Bootstrap's dotfiles step and Automation's own dotfiles
/// step both run - fetches first, fast-forwards only, never a forced
/// overwrite (see `BootstrapController`'s own doc comment on the equivalent
/// wrapper for the live-verified `--ff-only` behavior this relies on).
enum DotfilesRunCommand {
    static func rebuildCommand(repoPath: String) -> String {
        "cd \"\(repoPath)\" && git pull --ff-only && ./rebuild.sh"
    }

    /// Picks clone-and-bootstrap vs. rebuild depending on whether `~/.dotfiles`
    /// was already found, exactly like `BootstrapController.runSetupStepDotfiles`.
    static func runOrCloneCommand(repoPath: String?, clonePathFieldValue: String) -> (label: String, command: String) {
        if let repoPath {
            return ("rebuild.sh", rebuildCommand(repoPath: repoPath))
        }
        let raw = clonePathFieldValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let destination = raw.isEmpty ? DotfilesSource.defaultClonePath : raw
        let expanded = (destination as NSString).expandingTildeInPath
        return ("Bootstrap", "git clone \(DotfilesSource.cloneURL) \"\(expanded)\" && cd \"\(expanded)\" && ./bootstrap.sh")
    }
}
