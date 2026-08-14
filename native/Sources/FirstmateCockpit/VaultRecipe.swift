// Manjesh Grand Line - native macOS app.
//
// "Backup the recipe, not the values" (fm/grandline-vault-recipe-backup): a
// literal "export my secrets" feature was already rejected earlier in this
// app's history (see `VaultController.swift`'s own header) as recreating the
// exact plaintext-exfiltration risk Automic Vault exists to prevent. What's
// safe and useful to back up is the *recipe* - which secrets were hardened,
// for which tools/launchers - pure configuration, never secret material.
//
// This file is pure logic (model + build + diff), no AppKit, no `Process` -
// see `VaultRecipeGit.swift` for the git/filesystem side.
//
// A real CLI-surface finding from building this, not an assumption: `av`
// (checked via `av --help`, `av doctor`, `av hardeners --json`, and the
// `automic-vault` README's own "Secret Gates"/"Access Levels" section) has NO
// command that reports a secret's or tool's configured Access Level
// (Approval Required / Read Only / ... / Full Access) or a captain's own
// per-Launcher override rules - those live only in the menu-bar app's own
// local state (confirmed by reading that app's source directly), never
// surfaced to the CLI. `av hardeners --json`'s `secret_gate.routes[].
// caller_identifiers` is a STATIC catalog value (the same for every install,
// e.g. gh's hardener always lists `["gh", "com.github.cli"]`) describing the
// built-in patched CLI's own identity, not a captain-configured Verified
// Launcher list - so it is not meaningfully more informative than `av doctor
// --json`'s own per-tool `commands` field, which this recipe already reuses.
// Given that, this recipe honestly records only what's genuinely exposed:
// saved secret *names* (`av list`) and per-tool hardened status + launcher
// command names (`av doctor --json`, already modeled as `VaultTool` in
// `VaultData.swift`) - never a fabricated access-level field.

import Foundation

struct VaultRecipeSecret: Codable, Equatable {
    let name: String
}

struct VaultRecipeTool: Codable, Equatable {
    let name: String
    let hardened: Bool
    /// The tool's own verified launcher command names, exactly as `av doctor
    /// --json` reports them (`VaultTool.commands`) - see this file's header
    /// for why a deeper "Access Level"/captain-configured-launcher field
    /// isn't available to record here.
    let verifiedLaunchers: [String]
}

struct VaultRecipe: Codable, Equatable {
    /// ISO 8601, set once at export time by the caller - this file never
    /// calls `Date()` itself, so it stays trivially testable.
    let generatedAt: String
    let avVersion: String?
    let secrets: [VaultRecipeSecret]
    let tools: [VaultRecipeTool]

    static func build(from snapshot: VaultSnapshot, generatedAt: String) -> VaultRecipe {
        let versionLabel: String? = {
            if case .installed(let v) = snapshot.availability { return v }
            return nil
        }()
        return VaultRecipe(
            generatedAt: generatedAt,
            avVersion: versionLabel,
            secrets: snapshot.secrets
                .map { VaultRecipeSecret(name: $0.name) }
                .sorted { $0.name < $1.name },
            tools: snapshot.tools
                .map { tool in
                    let hardened: Bool
                    if case .hardened = tool.status { hardened = true } else { hardened = false }
                    return VaultRecipeTool(name: tool.name, hardened: hardened, verifiedLaunchers: tool.commands)
                }
                .sorted { $0.name < $1.name }
        )
    }
}

// MARK: - Replay checklist

enum VaultRecipeItemKind: Equatable {
    case secret
    case tool
}

/// Whether a recorded backup item still matches live `av` state. The
/// "missing" case is the important one per the task brief - it's what a
/// captain needs to re-do after a fresh machine/wipe.
enum VaultRecipeItemStatus: Equatable {
    /// Recorded in the backup and still true right now.
    case matches
    /// Recorded in the backup, but not true right now - a secret that needs
    /// re-saving, or a tool that needs re-hardening.
    case missingLocally
    /// True right now, but not recorded in the backup - fine to show, per
    /// the task brief, just not the important case.
    case newSinceBackup
}

struct VaultRecipeChecklistItem: Equatable {
    let kind: VaultRecipeItemKind
    let name: String
    let status: VaultRecipeItemStatus
    /// Verified launchers for a tool row, `nil` for a secret row.
    let detail: String?
}

enum VaultRecipeChecklist {
    /// Compares a previously-exported recipe against the current `av list`/
    /// `av doctor --json` snapshot. Never touches disk or a `Process` itself -
    /// pure comparison, so it's directly testable with in-memory fixtures.
    static func build(recipe: VaultRecipe, currentSnapshot: VaultSnapshot) -> [VaultRecipeChecklistItem] {
        var items: [VaultRecipeChecklistItem] = []

        let backupSecretNames = Set(recipe.secrets.map(\.name))
        let currentSecretNames = Set(currentSnapshot.secrets.map(\.name))
        for name in backupSecretNames.union(currentSecretNames).sorted() {
            let inBackup = backupSecretNames.contains(name)
            let inCurrent = currentSecretNames.contains(name)
            let status: VaultRecipeItemStatus = inBackup == inCurrent ? .matches : (inBackup ? .missingLocally : .newSinceBackup)
            items.append(VaultRecipeChecklistItem(kind: .secret, name: name, status: status, detail: nil))
        }

        let backupHardenedTools: [String: VaultRecipeTool] = Dictionary(uniqueKeysWithValues: recipe.tools.filter(\.hardened).map { ($0.name, $0) })
        var currentHardenedTools: [String: VaultTool] = [:]
        for tool in currentSnapshot.tools {
            if case .hardened = tool.status { currentHardenedTools[tool.name] = tool }
        }
        let allToolNames = Set(backupHardenedTools.keys).union(currentHardenedTools.keys)
        for name in allToolNames.sorted() {
            let inBackup = backupHardenedTools[name] != nil
            let inCurrent = currentHardenedTools[name] != nil
            let status: VaultRecipeItemStatus = inBackup == inCurrent ? .matches : (inBackup ? .missingLocally : .newSinceBackup)
            let launchers = (backupHardenedTools[name]?.verifiedLaunchers ?? currentHardenedTools[name]?.commands ?? [])
            items.append(VaultRecipeChecklistItem(
                kind: .tool, name: name, status: status,
                detail: launchers.isEmpty ? nil : launchers.joined(separator: ", ")
            ))
        }

        return items
    }
}
