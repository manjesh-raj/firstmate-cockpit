// Manjesh Grand Line - native macOS app.
//
// Storage layer for the DevOps Command Library (fm/grandline-devops-command-
// library, Phase 1 - see AGENTS.md's "Shift" section and the design doc at
// data/grandline-devops-command-library/design-reference.html). Zero new git
// plumbing: commands live at `commands/<category>/[<subcategory>/]<slug>.yaml`
// *inside* `ShiftGitSync`'s existing `personal-tasks/` root, the same subtree
// `git add -A -- GrandLineDocs/personal-tasks` already covers on every commit
// - so this store only ever calls `ShiftGitSync.shared.markDirty()` after a
// write, exactly like `ShiftStore` itself does, rather than owning a second
// `DocsRunbookGitSync`-style clone/commit/push class. (Docs' Runbooks needed
// that second class because `GrandLineDocs/runbooks/` is a *sibling* of
// `personal-tasks/`, outside the subtree Shift's own commits are scoped to -
// commands don't have that problem, since the design doc puts them inside
// `personal-tasks/commands/`.)
//
// `CommandLibraryStore` mirrors `DocsRunbookStore`'s shape: a plain
// file-based CRUD/scan layer, `FM_COMMAND_LIBRARY_DIR` overriding the root
// entirely (bypassing git, same convention as `FM_SHIFT_DIR`/
// `FM_DOCS_RUNBOOKS_DIR` - every self-test uses this, never the captain's
// real synced data).

import Foundation
import Yaml

final class CommandLibraryStore {
    private let fm = FileManager.default

    let root: URL
    /// `nil` when `FM_COMMAND_LIBRARY_DIR` overrides `root` - same convention
    /// as `ShiftStore.gitSync`/`DocsRunbookStore.gitSync`.
    let gitSync: ShiftGitSync?

    private(set) var commands: [DevOpsCommand] = []
    private(set) var config: CommandLibraryConfig = .empty
    private(set) var favoriteIDs: Set<String> = []

    private var configPath: String { root.appendingPathComponent("config.yaml").path }
    private var favoritesPath: String { root.appendingPathComponent("favorites.yaml").path }

    /// `FM_COMMAND_LIBRARY_DIR` is a narrower override scoped to just this
    /// store; `FM_SHIFT_DIR` is `ShiftStore`'s own existing bypass-git-sync
    /// override - since commands live *inside* `ShiftGitSync`'s
    /// `personal-tasks/` root (this file's header), this store must honor
    /// that same env var too, or setting `FM_SHIFT_DIR` (the established way
    /// to fully avoid touching the captain's real git-synced clone, used by
    /// every Shift/Docs self-test) would silently leave this one store still
    /// reaching into `ShiftGitSync.shared`'s real production clone -
    /// including seeding real starter commands into it. Checked in that
    /// order so a caller can still isolate just the command library's own
    /// test data while a sibling `ShiftStore` in the same process uses its
    /// real `FM_SHIFT_DIR` override.
    init() {
        let env = ProcessInfo.processInfo.environment
        if let override = env["FM_COMMAND_LIBRARY_DIR"], !override.isEmpty {
            root = URL(fileURLWithPath: (override as NSString).expandingTildeInPath, isDirectory: true)
            gitSync = nil
        } else if let override = env["FM_SHIFT_DIR"], !override.isEmpty {
            root = URL(fileURLWithPath: (override as NSString).expandingTildeInPath, isDirectory: true)
                .appendingPathComponent("commands", isDirectory: true)
            gitSync = nil
        } else {
            let sync = ShiftGitSync.shared
            sync.start()
            root = sync.dataRoot.appendingPathComponent("commands", isDirectory: true)
            gitSync = sync
        }
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)
        seedIfEmpty()
        reloadAll()
    }

    func reloadAll() {
        commands = scanCommands()
        config = CommandLibraryYaml.readConfig(path: configPath)
        favoriteIDs = CommandLibraryYaml.readFavorites(path: favoritesPath)
    }

    // MARK: Scanning

    /// Recursively walks `root` for `<category>/[<subcategory>/]<slug>.yaml`
    /// files, skipping `config.yaml`/`favorites.yaml` (which live at `root`
    /// itself, not under a category folder, so they're never mistaken for a
    /// command file regardless).
    private func scanCommands() -> [DevOpsCommand] {
        guard let categoryDirs = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { return [] }
        var results: [DevOpsCommand] = []
        for categoryDir in categoryDirs.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard (try? categoryDir.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { continue }
            let category = categoryDir.lastPathComponent
            results.append(contentsOf: scanCategoryDir(categoryDir, category: category, subcategory: nil))
        }
        return results.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func scanCategoryDir(_ dir: URL, category: String, subcategory: String?) -> [DevOpsCommand] {
        guard let entries = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { return [] }
        var results: [DevOpsCommand] = []
        for entry in entries {
            let isDir = (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
            if isDir {
                // One level of subcategory nesting only, matching the design
                // doc's own `kubernetes/pods/get-pod-logs.yaml` example.
                results.append(contentsOf: scanCategoryDir(entry, category: category, subcategory: entry.lastPathComponent))
            } else if entry.pathExtension.lowercased() == "yaml" {
                let slug = entry.deletingPathExtension().lastPathComponent
                let id = ([category, subcategory, slug].compactMap { $0 }).joined(separator: "/")
                if let command = CommandLibraryYaml.readCommand(path: entry.path, fallbackID: id, fallbackCategory: category, fallbackSubcategory: subcategory) {
                    results.append(command)
                }
            }
        }
        return results
    }

    /// Commands grouped by category, in `CommandLibraryCategory.all`'s fixed
    /// display order - the mockup's own category rail order - with any
    /// category id not in that catalog (a captain-added custom folder)
    /// appended afterward rather than dropped.
    func commandsByCategory() -> [(info: CommandLibraryCategoryInfo, commands: [DevOpsCommand])] {
        let grouped = Dictionary(grouping: commands, by: \.category)
        var ordered: [(CommandLibraryCategoryInfo, [DevOpsCommand])] = []
        var seen = Set<String>()
        for info in CommandLibraryCategory.all {
            seen.insert(info.id)
            ordered.append((info, grouped[info.id] ?? []))
        }
        for key in grouped.keys.sorted() where !seen.contains(key) {
            ordered.append((CommandLibraryCategory.info(for: key), grouped[key] ?? []))
        }
        return ordered
    }

    func favoriteCommands() -> [DevOpsCommand] {
        commands.filter { favoriteIDs.contains($0.id) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func command(id: String) -> DevOpsCommand? { commands.first { $0.id == id } }

    func search(query: String) -> [DevOpsCommand] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }
        return commands.filter { $0.matches(query: q) }
    }

    // MARK: Favorites

    func isFavorite(_ id: String) -> Bool { favoriteIDs.contains(id) }

    func toggleFavorite(_ id: String) {
        if favoriteIDs.contains(id) {
            favoriteIDs.remove(id)
        } else {
            favoriteIDs.insert(id)
        }
        try? CommandLibraryYaml.writeFavorites(favoriteIDs, path: favoritesPath)
        gitSync?.markDirty()
    }

    // MARK: Seeding

    /// Writes the built-in starter set the first time this store ever runs
    /// against an empty `commands/` folder - never overwrites/re-seeds once
    /// any real command file exists (a category folder with at least one
    /// `.yaml` file in it, checked *before* `config.yaml`/`favorites.yaml`
    /// exist, since those are written by this very method). Mirrors
    /// `ShiftStore.seedIfEmpty`'s "only ever fires once, from a genuinely
    /// empty store" shape, except this one runs unconditionally in `init`
    /// (not gated behind a captain action or a self-test call) since an
    /// empty Command Library page is a worse first-run experience than
    /// Shift's own deliberately-blank task list - the whole point of this
    /// tab is browsing a pre-populated reference.
    private func seedIfEmpty() {
        guard scanCommands().isEmpty else { return }
        for command in CommandLibrarySeedData.commands {
            // `command.id` in the seed literals is a bare slug (e.g.
            // "get-pod-logs") - the file's path (category/[subcategory/]slug)
            // is what actually becomes its on-disk identity once scanned
            // back; the `id` field written into the YAML itself is never
            // read back (see `CommandLibraryYaml.command(from:)`, which
            // always trusts the caller's `fallbackID` derived from the path).
            let relativePath = ([command.category, command.subcategory, command.id]).compactMap { $0 }
            let path = root.appendingPathComponent(relativePath.joined(separator: "/")).appendingPathExtension("yaml").path
            try? CommandLibraryYaml.writeCommand(command, path: path)
        }
        try? CommandLibraryYaml.writeConfig(CommandLibrarySeedData.config, path: configPath)
        gitSync?.markDirty()
    }
}
