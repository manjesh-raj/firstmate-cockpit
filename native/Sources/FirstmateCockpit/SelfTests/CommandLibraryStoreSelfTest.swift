// Manjesh Grand Line - native macOS app.
//
// Permanent self-test for the DevOps Command Library's data layer
// (fm/grandline-devops-command-library, Phase 1; extended in Phase 2 -
// fm/grandline-devops-command-library-phase2 - for add/edit/duplicate and
// recent-used tracking), run via
// `FM_RUN_COMMAND_LIBRARY_TESTS=1 .build/debug/FirstmateCockpit` - same
// convention as `ShiftStoreSelfTest.swift`/`DocsRunbookDataSelfTest.swift`.
// Runs against a real scratch directory (`FM_COMMAND_LIBRARY_DIR`), never
// the captain's real git-synced data - every check here is a real disk
// read/write, not an in-memory-only assertion.

// GL-27: compiled into debug builds only.
//
// The 51 self-test suites are ~10,500 lines of test code, fault-injection
// seams and fixture data that used to be linked into the binary the captain
// actually runs. `FM_SELFTESTS` is defined by `Package.swift` for the debug
// configuration only, so `swift build` (and therefore CI and
// `Scripts/run-all-tests.sh`) still has every suite, while
// `swift build -c release` - what `native/build_native_app.sh` assembles the
// shipped `.app` from - has none of it.
//
// Do not remove this guard when editing a suite: `Phase3PolishSelfTest`
// asserts that every file in this directory carries it.
#if FM_SELFTESTS

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

        // MARK: Phase 2 - add / edit / duplicate, surviving a fresh reload

        let created = store.createCommand(
            name: "Restart Deployment", description: "Rolling restart", category: "kubernetes", subcategory: "deployments",
            commandTemplate: "kubectl rollout restart deployment/{{name}} -n {{namespace}}",
            parameters: [CommandParameter(name: "name", label: "Name"), CommandParameter(name: "namespace", label: "Namespace", defaultValue: "default")],
            tags: ["restart"], risk: .potentiallyDisruptive
        )
        check(created.id == "kubernetes/deployments/restart-deployment", "createCommand should derive a path-shaped id from category/subcategory/name, got \(created.id)")
        check(store.command(id: created.id) != nil, "created command should be findable in memory immediately")
        let afterCreateReload = CommandLibraryStore()
        check(afterCreateReload.command(id: created.id)?.name == "Restart Deployment", "created command should survive a fresh store reload")
        check(afterCreateReload.command(id: created.id)?.risk == .potentiallyDisruptive, "risk should round-trip through save/reload")

        // A second command with the same name/category disambiguates its
        // slug rather than colliding with the first.
        let createdAgain = store.createCommand(
            name: "Restart Deployment", description: "", category: "kubernetes", subcategory: "deployments",
            commandTemplate: "kubectl rollout restart deployment/{{name}}", parameters: [], tags: [], risk: .readOnly
        )
        check(createdAgain.id != created.id, "a same-named command should get a disambiguated slug, not collide")

        // Editing in place: same category/subcategory keeps the same id.
        let editedSameLocation = store.updateCommand(
            id: created.id, name: "Restart Deployment (renamed)", description: "Rolling restart, edited",
            category: "kubernetes", subcategory: "deployments", commandTemplate: created.commandTemplate,
            parameters: created.parameters, tags: created.tags, risk: .destructive
        )
        check(editedSameLocation?.id == created.id, "editing without changing category/subcategory should keep the same id")
        let afterEditReload = CommandLibraryStore()
        check(afterEditReload.command(id: created.id)?.name == "Restart Deployment (renamed)", "an edit should survive a fresh reload")
        check(afterEditReload.command(id: created.id)?.risk == .destructive, "an edited risk level should round-trip through save/reload")

        // Editing to a different category moves the file to a new id, and
        // favorite/recent-usage state for the old id migrates rather than
        // being silently orphaned.
        store.toggleFavorite(created.id)
        store.recordUsage(created.id)
        check(store.isFavorite(created.id), "sanity: favorited before the move")
        let movedCommand = store.updateCommand(
            id: created.id, name: "Restart Deployment (renamed)", description: "moved",
            category: "general", subcategory: nil, commandTemplate: created.commandTemplate,
            parameters: created.parameters, tags: created.tags, risk: .destructive
        )
        check(movedCommand?.category == "general", "changing category should be reflected in the saved command")
        check(movedCommand?.id != created.id, "changing category should move the file to a new id")
        if let movedID = movedCommand?.id {
            check(store.isFavorite(movedID), "favorite state should migrate to the new id after a category move")
            check(!store.isFavorite(created.id), "the old id should no longer be favorited after the move")
            check(store.recentUsage.contains { $0.id == movedID }, "recent-usage state should also migrate to the new id")
            check(store.command(id: created.id) == nil, "the old id's file should no longer exist after the move")
        }

        // Duplicate clones fields into a brand-new id, leaving the original
        // untouched.
        guard let duplicateSource = store.command(id: "kubernetes/pods/describe-pod") else {
            return report(failures + ["expected seed command kubernetes/pods/describe-pod for the duplicate test"])
        }
        let duplicated = store.duplicateCommand(id: duplicateSource.id)
        check(duplicated?.id != duplicateSource.id, "duplicate should get its own id")
        check(duplicated?.name == "\(duplicateSource.name) Copy", "duplicate's name should be suffixed \" Copy\"")
        check(duplicated?.commandTemplate == duplicateSource.commandTemplate, "duplicate should carry over the original template")
        check(store.command(id: duplicateSource.id) != nil, "duplicating should never touch the original command")

        // MARK: Phase 2 - recent-used tracking only on Copy/Send, never on
        // mere selection, most-recent-first ordering.

        check(store.recentlyUsedCommands().isEmpty == false, "sanity: recordUsage above should have produced at least one recent entry")
        let podLogsID = "kubernetes/pods/get-pod-logs"
        let describePodID = duplicateSource.id
        store.recordUsage(podLogsID)
        store.recordUsage(describePodID)
        let recent = store.recentlyUsedCommands()
        check(recent.first?.id == describePodID, "the most recently recorded usage should sort first, got \(recent.first?.id ?? "nil")")
        check(recent.contains { $0.id == podLogsID }, "an earlier recorded usage should still be present")
        // Re-recording an id moves it back to the front rather than
        // duplicating the entry.
        store.recordUsage(podLogsID)
        check(store.recentlyUsedCommands().first?.id == podLogsID, "re-recording usage should move the id back to the front")
        check(store.recentUsage.filter { $0.id == podLogsID }.count == 1, "recording usage for an already-present id should not duplicate its entry")
        let afterUsageReload = CommandLibraryStore()
        check(afterUsageReload.recentlyUsedCommands().first?.id == podLogsID, "recent-used order should survive a fresh reload")

        // MARK: Phase 2 - workflow content formatting (pure logic, no store/
        // disk involved - `CommandLibraryWorkflow` never touches
        // `DocsRunbookStore` itself).

        let workflowCommand = DevOpsCommand(
            id: "kubernetes/pods/get-pod-logs", name: "Get Pod Logs", description: "Get logs from a pod",
            category: "kubernetes", commandTemplate: "kubectl logs -n prod search-api"
        )
        let newRunbook = CommandLibraryWorkflow.newRunbookContent(title: "Investigate Latency", command: workflowCommand, generatedText: "kubectl logs -n prod search-api")
        check(newRunbook.hasPrefix("# Investigate Latency"), "a new workflow runbook should start with the given title as a heading")
        check(newRunbook.contains("```\nkubectl logs -n prod search-api\n```"), "a new workflow runbook should fence the generated command exactly")

        let appended = CommandLibraryWorkflow.appending(command: workflowCommand, generatedText: "kubectl logs -n prod search-api --since=30m", to: "# Existing Runbook\n\nSome prose.\n")
        check(appended.hasPrefix("# Existing Runbook"), "appending should preserve the existing runbook's own heading")
        check(appended.contains("```\nkubectl logs -n prod search-api --since=30m\n```"), "appending should fence the new step's generated command exactly")

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

#endif
