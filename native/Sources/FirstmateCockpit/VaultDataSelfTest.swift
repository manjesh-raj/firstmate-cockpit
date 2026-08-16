// Manjesh Grand Line - native macOS app.
//
// Permanent, env-gated self-test for `VaultData.swift`'s pure logic - run via
// `FM_RUN_VAULT_DATA_TESTS=1 .build/debug/FirstmateCockpit`, same convention
// as `HostStoreSelfTest.swift`/`YamlBeautifySelfTest.swift`. Covers only the
// parts of `VaultSource` that don't need a real `av` binary: token safety
// (what's allowed to be spliced into a shell command unquoted), the two
// command-string builders, and `av doctor --json` parsing against the exact
// shape `av` returned on this machine during development (see
// `VaultController.swift`'s header for the live probes that established the
// rest of this file's behavior - `av list` returning bare names, `av save`
// requiring a real `/dev/tty`, `av inject` working fine as a background
// process).
//
// Also covers `VaultRecipe.build`/`VaultRecipeChecklist.build`
// (fm/grandline-vault-recipe-backup) - a lossless JSON round trip, and the
// missing/matches/new-since-backup diff against a simulated post-wipe
// snapshot. The git/filesystem half (`VaultRecipeGit.swift`) is exercised
// live against a disposable local clone instead - see that task's PR
// description for the exact commands run, since a real `git commit`/`push`
// against a throwaway remote isn't something a pure in-process self-test can
// safely cover.

import Foundation

enum VaultDataSelfTest {
    @discardableResult
    static func run() -> Bool {
        var failures: [String] = []
        func check(_ name: String, _ condition: Bool) {
            if !condition { failures.append(name) }
        }

        // MARK: isSafeToken

        check("plain name is safe", VaultSource.isSafeToken("MANJESH_GITHUB_TOKEN"))
        check("dash/underscore mix is safe", VaultSource.isSafeToken("my-secret_1"))
        check("empty is unsafe", !VaultSource.isSafeToken(""))
        check("space is unsafe", !VaultSource.isSafeToken("has space"))
        check("shell metachar is unsafe", !VaultSource.isSafeToken("a;rm -rf /"))
        check("quote is unsafe", !VaultSource.isSafeToken("a'b"))
        check("dollar is unsafe", !VaultSource.isSafeToken("$HOME"))

        // MARK: saveSecretCommand

        check("save command for a safe name", VaultSource.saveSecretCommand(name: "MY_TOKEN") == "av save MY_TOKEN")
        check("save command rejects an unsafe name", VaultSource.saveSecretCommand(name: "a; rm -rf /") == nil)

        // MARK: injectCommand

        check(
            "inject command for a safe name + command",
            VaultSource.injectCommand(secretName: "MY_TOKEN", command: "gh auth status") == "av inject +MY_TOKEN -- gh auth status"
        )
        check("inject command rejects an unsafe secret name", VaultSource.injectCommand(secretName: "a b", command: "echo hi") == nil)
        check("inject command rejects an empty command", VaultSource.injectCommand(secretName: "MY_TOKEN", command: "   ") == nil)

        // MARK: parseDoctorTools

        let hardenedOnly = VaultSource.parseDoctorTools(#"{"results":[{"commands":["claude"],"issues":[],"name":"claude"}]}"#)
        check("one hardened tool parsed", hardenedOnly.count == 1)
        check("hardened tool name/commands", hardenedOnly.first?.name == "claude" && hardenedOnly.first?.commands == ["claude"])
        check("hardened tool status", hardenedOnly.first?.status == .hardened)

        let withIssues = VaultSource.parseDoctorTools(
            #"{"results":[{"commands":["gh"],"issues":[{"explanation":"x"},{"explanation":"y"}],"name":"gh"}]}"#
        )
        check("tool with issues parsed", withIssues.count == 1)
        check("tool with issues status", withIssues.first?.status == .needsAttention(issueCount: 2))

        let malformed = VaultSource.parseDoctorTools("not json")
        check("malformed JSON yields no tools, not a crash", malformed.isEmpty)

        let empty = VaultSource.parseDoctorTools(#"{"results":[]}"#)
        check("empty results yields no tools", empty.isEmpty)

        // MARK: VaultRecipe.build / VaultRecipeChecklist (fm/grandline-vault-recipe-backup)

        let snapshotA = VaultSnapshot(
            availability: .installed(versionLabel: "av 1.2.3"),
            secrets: [VaultSecret(name: "GH_TOKEN"), VaultSecret(name: "AWS_SECRET")],
            tools: [
                VaultTool(name: "claude", commands: ["claude"], status: .hardened),
                VaultTool(name: "gh", commands: ["gh"], status: .hardened),
            ],
            log: ""
        )
        let recipeA = VaultRecipe.build(from: snapshotA, generatedAt: "2026-01-01T00:00:00Z")
        check("recipe records av version", recipeA.avVersion == "av 1.2.3")
        check("recipe secrets sorted by name", recipeA.secrets.map(\.name) == ["AWS_SECRET", "GH_TOKEN"])
        check("recipe tools sorted by name", recipeA.tools.map(\.name) == ["claude", "gh"])
        check("recipe tool records hardened + launchers", recipeA.tools.first { $0.name == "gh" }?.verifiedLaunchers == ["gh"])

        // A round trip through JSON never contains a value - only names ever
        // flow into this model, but encode/decode should still be lossless.
        if let data = try? JSONEncoder().encode(recipeA), let decoded = try? JSONDecoder().decode(VaultRecipe.self, from: data) {
            check("recipe JSON round trip is lossless", decoded == recipeA)
        } else {
            failures.append("recipe JSON round trip failed to encode/decode")
        }

        // A machine wiped since export: AWS_SECRET and the `gh` hardening are
        // gone, a brand-new secret NEW_TOKEN was saved, `claude` is still
        // hardened.
        let snapshotB = VaultSnapshot(
            availability: .installed(versionLabel: "av 1.2.3"),
            secrets: [VaultSecret(name: "GH_TOKEN"), VaultSecret(name: "NEW_TOKEN")],
            tools: [
                VaultTool(name: "claude", commands: ["claude"], status: .hardened),
                VaultTool(name: "gh", commands: ["gh"], status: .needsAttention(issueCount: 1)),
            ],
            log: ""
        )
        let items = VaultRecipeChecklist.build(recipe: recipeA, currentSnapshot: snapshotB)
        let secretItems = Dictionary(uniqueKeysWithValues: items.filter { $0.kind == .secret }.map { ($0.name, $0.status) })
        let toolItems = Dictionary(uniqueKeysWithValues: items.filter { $0.kind == .tool }.map { ($0.name, $0.status) })
        check("missing secret detected (the important case)", secretItems["AWS_SECRET"] == .missingLocally)
        check("matching secret detected", secretItems["GH_TOKEN"] == .matches)
        check("new secret since backup detected", secretItems["NEW_TOKEN"] == .newSinceBackup)
        check("dehardened tool detected as missing", toolItems["gh"] == .missingLocally)
        check("still-hardened tool detected as matching", toolItems["claude"] == .matches)
        check("checklist item count is secrets+tools union", items.count == 5) // AWS_SECRET, GH_TOKEN, NEW_TOKEN, claude, gh

        // Nothing changed since export -> everything matches, nothing flagged missing.
        let itemsUnchanged = VaultRecipeChecklist.build(recipe: recipeA, currentSnapshot: snapshotA)
        check("no drift yields all-matches", itemsUnchanged.allSatisfy { $0.status == .matches })

        // MARK: isServiceRunning (fm/grandline-vault-no-unnecessary-relaunch)
        //
        // Real-machine check, not a mock: this development machine keeps
        // Automic Vault's helper alive via its own `RunAtLoad: true`
        // LaunchAgent, independent of this app - so `pgrep -x
        // AutomicVaultMenubar` should report it running here. This can't be
        // asserted unconditionally on every machine (the helper might
        // genuinely be absent), so it's a soft/logged check rather than a
        // hard failure either way - the real regression this task fixes
        // (`ensureServiceRunning()` calling `open` even when already
        // running, which reopens Automic Vault's real window) was verified
        // live separately, outside this pure self-test, per this file's own
        // header convention.
        print("VaultDataSelfTest: isServiceRunning() reports \(VaultSource.isServiceRunning()) on this machine")

        if failures.isEmpty {
            print("VaultDataSelfTest: all checks passed")
            return true
        } else {
            print("VaultDataSelfTest: FAILED - \(failures.joined(separator: "; "))")
            return false
        }
    }
}
