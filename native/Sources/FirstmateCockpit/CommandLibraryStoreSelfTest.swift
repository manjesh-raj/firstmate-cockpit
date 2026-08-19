// Manjesh Grand Line - native macOS app.
//
// Permanent self-test for the DevOps Command Library's data layer
// (fm/grandline-devops-command-library, Phase 1), run via
// `FM_RUN_COMMAND_LIBRARY_TESTS=1 .build/debug/FirstmateCockpit` - same
// convention as `ShiftStoreSelfTest.swift`/`DocsRunbookDataSelfTest.swift`.
// Runs against a real scratch directory (`FM_COMMAND_LIBRARY_DIR`), never
// the captain's real git-synced data - every check here is a real disk
// read/write, not an in-memory-only assertion.

import Foundation

enum CommandLibraryStoreSelfTest {
    static func run() -> Bool {
        var failures: [String] = []
        func check(_ condition: Bool, _ message: String) {
            if !condition { failures.append(message) }
        }

        let scratchRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("command-library-selftest-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: scratchRoot) }

        setenv("FM_COMMAND_LIBRARY_DIR", scratchRoot.path, 1)
        defer { unsetenv("FM_COMMAND_LIBRARY_DIR") }

        // MARK: Seed on first run

        let store = CommandLibraryStore()
        check(store.commands.count == CommandLibrarySeedData.commands.count, "seed should write every seed command, got \(store.commands.count) expected \(CommandLibrarySeedData.commands.count)")
        check(!store.config.selectOptions.isEmpty, "seed should write a non-empty config.yaml")
        check(store.favoriteIDs.isEmpty, "favorites should start empty")

        let kubernetesGroup = store.commandsByCategory().first { $0.info.id == "kubernetes" }
        check(kubernetesGroup != nil, "commandsByCategory should include kubernetes")
        check((kubernetesGroup?.commands.count ?? 0) > 0, "kubernetes category should have real seeded commands")

        // Re-running the store against the same non-empty folder must never
        // re-seed (would silently duplicate every command on a second
        // launch).
        let reopened = CommandLibraryStore()
        check(reopened.commands.count == store.commands.count, "reopening an already-seeded store should not duplicate commands")

        // MARK: Parameter-token detection from a real command template

        guard let podLogs = store.command(id: "kubernetes/pods/get-pod-logs") else {
            return report(failures + ["seed should include kubernetes/pods/get-pod-logs at its expected path-derived id"])
        }
        let tokens = DevOpsCommand.detectTokens(in: podLogs.commandTemplate)
        check(tokens == ["namespace", "pod", "duration"], "detected tokens should match template order, got \(tokens)")
        check(podLogs.effectiveParameters.map(\.name) == tokens, "effectiveParameters should align with detected tokens")

        // A template with a bare, undeclared token still gets a synthesized
        // parameter for it (auto-detection covering a gap in a hand-written
        // YAML file).
        let adHoc = DevOpsCommand(
            id: "adhoc", name: "Ad Hoc", description: "", category: "general",
            commandTemplate: "echo {{message}} && echo {{unused_declared}}",
            parameters: [CommandParameter(name: "unused_declared", label: "Declared", defaultValue: "hi")]
        )
        let adHocParams = adHoc.effectiveParameters
        check(adHocParams.count == 2, "undeclared token should still produce a synthesized parameter")
        check(adHocParams.first?.name == "message" && adHocParams.first?.label == "message", "undeclared token falls back to itself as the label")

        // MARK: Generated-command substitution given real parameter values

        let generated = podLogs.generatedCommand(values: ["namespace": "raas-prod", "pod": "search-api", "duration": "30m"])
        check(generated == "kubectl logs -n raas-prod search-api --since=30m", "substitution should produce the exact expected command, got: \(generated)")

        // An unfilled parameter with a default falls back to the default;
        // one with no default and no value renders the bare token, so the
        // preview never silently drops a placeholder.
        let partialGenerated = podLogs.generatedCommand(values: ["namespace": "raas-uat"])
        check(partialGenerated.contains("raas-uat"), "filled parameter should substitute")
        check(partialGenerated.contains("search-api"), "unfilled parameter with a default should substitute the default")

        let noDefaultCommand = DevOpsCommand(
            id: "no-default", name: "No Default", description: "", category: "general",
            commandTemplate: "kill -9 {{pid}}", parameters: [CommandParameter(name: "pid", label: "PID", kind: .number)]
        )
        let noDefaultGenerated = noDefaultCommand.generatedCommand(values: [:])
        check(noDefaultGenerated == "kill -9 {{pid}}", "an unfilled parameter with no default should render the bare token, got: \(noDefaultGenerated)")

        // MARK: Search across every field the design doc calls for

        check(!store.search(query: "pod logs").isEmpty, "search by name should find a match")
        check(store.search(query: "kubernetes").contains { $0.category == "kubernetes" }, "search by category should find matches")
        check(store.search(query: "troubleshooting").contains { $0.tags.contains("troubleshooting") }, "search by tag should find matches")
        check(store.search(query: "kubectl logs -n").contains { $0.id == "kubernetes/pods/get-pod-logs" }, "search by command text should find matches")
        check(store.search(query: "zzz-no-such-thing-zzz").isEmpty, "an unmatched query should return nothing")

        // MARK: Favorites persistence round trip through a fresh instance

        store.toggleFavorite("kubernetes/pods/get-pod-logs")
        check(store.isFavorite("kubernetes/pods/get-pod-logs"), "toggling a favorite on should mark it favorited in memory")
        check(store.favoriteCommands().count == 1, "favoriteCommands should reflect the toggle")

        let afterFavoriteReload = CommandLibraryStore()
        check(afterFavoriteReload.isFavorite("kubernetes/pods/get-pod-logs"), "favorite should survive a fresh store instance (real disk round trip)")

        afterFavoriteReload.toggleFavorite("kubernetes/pods/get-pod-logs")
        check(!afterFavoriteReload.isFavorite("kubernetes/pods/get-pod-logs"), "toggling off should un-favorite")
        let afterUnfavoriteReload = CommandLibraryStore()
        check(!afterUnfavoriteReload.isFavorite("kubernetes/pods/get-pod-logs"), "un-favorite should also survive a fresh reload")

        // MARK: Risk levels present across the seed set (Phase 2 will enforce these)

        let riskLevels = Set(store.commands.map(\.risk))
        check(riskLevels.contains(.readOnly), "seed set should include read-only commands")
        check(riskLevels.contains(.potentiallyDisruptive), "seed set should include potentially-disruptive commands")
        check(riskLevels.contains(.destructive), "seed set should include destructive commands")

        // MARK: config.yaml select-option lists round-trip correctly

        check(store.config.selectOptions["namespaces"]?.contains("raas-prod") == true, "seeded config should include the namespaces list")
        let namespaceParam = podLogs.parameters.first { $0.name == "namespace" }
        check(namespaceParam?.configOptionsKey == "namespaces", "a namespace-shaped parameter should reference the config key, not a hardcoded option list")
        check(store.config.options(forKey: "namespaces", fallback: []).contains("raas-prod"), "config.options(forKey:) should resolve the configured list")
        check(store.config.options(forKey: "no-such-key", fallback: ["fallback-value"]) == ["fallback-value"], "an unconfigured key should fall back to the parameter's own literal options")

        // MARK: FM_SHIFT_DIR (not just FM_COMMAND_LIBRARY_DIR) must also
        // fully redirect this store - commands live inside the same
        // `personal-tasks/` root `ShiftStore` manages, so a caller that only
        // sets `FM_SHIFT_DIR` (the established way to bypass
        // `ShiftGitSync.shared`'s real production clone entirely) must never
        // leave this store still reaching into that real clone.

        let shiftDirScratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("command-library-shiftdir-selftest-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: shiftDirScratch) }
        unsetenv("FM_COMMAND_LIBRARY_DIR")
        setenv("FM_SHIFT_DIR", shiftDirScratch.path, 1)
        let shiftDirStore = CommandLibraryStore()
        check(shiftDirStore.gitSync == nil, "a store honoring FM_SHIFT_DIR should have no git sync")
        check(shiftDirStore.root.path == shiftDirScratch.appendingPathComponent("commands").path, "root should be FM_SHIFT_DIR/commands, got \(shiftDirStore.root.path)")
        check(FileManager.default.fileExists(atPath: shiftDirScratch.appendingPathComponent("commands").path), "seeding should have written real files under FM_SHIFT_DIR, not ShiftGitSync.shared's real clone")
        check(shiftDirStore.commands.count == CommandLibrarySeedData.commands.count, "the FM_SHIFT_DIR-redirected store should still seed normally")
        unsetenv("FM_SHIFT_DIR")
        setenv("FM_COMMAND_LIBRARY_DIR", scratchRoot.path, 1)

        return report(failures)
    }

    private static func report(_ failures: [String]) -> Bool {
        if failures.isEmpty {
            print("[CommandLibraryStoreSelfTest] all checks passed")
            return true
        }
        print("[CommandLibraryStoreSelfTest] \(failures.count) failure(s):")
        for f in failures { print("  - \(f)") }
        return false
    }
}
