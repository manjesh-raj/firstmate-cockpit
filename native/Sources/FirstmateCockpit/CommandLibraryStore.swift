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
    /// Most-recent-first - see `CommandLibraryUsageEntry`'s doc comment.
    private(set) var recentUsage: [CommandLibraryUsageEntry] = []

    /// Recent-used tracking (Phase 2) keeps at most this many entries -
    /// unbounded growth would mean re-writing an ever-larger file on every
    /// single Copy/Send, for a list only ever rendered a handful of rows at
    /// a time.
    private static let maxRecentUsageEntries = 50

    private var configPath: String { root.appendingPathComponent("config.yaml").path }
    private var favoritesPath: String { root.appendingPathComponent("favorites.yaml").path }
    private var recentUsagePath: String { root.appendingPathComponent("recent.yaml").path }

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
        recentUsage = CommandLibraryYaml.readRecentUsage(path: recentUsagePath)
    }

    // MARK: Scanning

    /// Recursively walks `root` for `<category>/[<subcategory>/]<slug>.yaml`
    /// files, skipping `config.yaml`/`favorites.yaml` (which live at `root`
    /// itself, not under a category folder, so they're never mistaken for a
    /// command file regardless).
    private func scanCommands() -> [DevOpsCommand] {
        scanCommandsChecked().commands
    }

    /// GL-21: `scanCommands` returns `[]` both for "this library is genuinely
    /// empty" and for "the directory could not be enumerated at all", and
    /// `seedIfEmpty` then wrote 73 seed files - overwriting any real command
    /// sitting at a seed path. This variant reports which of the two it was,
    /// so the seeder can refuse to act on a failed read.
    ///
    /// Note the failure is specifically about *enumerating the root*. A
    /// category directory that fails to enumerate, or a single unparseable
    /// command file, is a partial read, not a reason to refuse seeding - but
    /// it also cannot make the library look empty unless the root read failed
    /// too, so the root check is the one that matters here.
    private func scanCommandsChecked() -> (commands: [DevOpsCommand], enumerationFailed: Bool) {
        guard let categoryDirs = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else {
            NSLog("[cockpit] command library: could not enumerate \(root.path) - not seeding (GL-21)")
            return ([], true)
        }
        var results: [DevOpsCommand] = []
        for categoryDir in categoryDirs.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard (try? categoryDir.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { continue }
            let category = categoryDir.lastPathComponent
            results.append(contentsOf: scanCategoryDir(categoryDir, category: category, subcategory: nil))
        }
        return (results.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }, false)
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

    // MARK: Recent usage (Phase 2 - fm/grandline-devops-command-library-phase2)

    /// Called only when a command's generated text actually leaves the app
    /// (Copy, Send to Terminal) - never on merely selecting/viewing a
    /// command's detail pane, per the phase-2 brief. Moves `id` to the front
    /// rather than re-sorting by timestamp, so ordering is correct even when
    /// two uses land in the same second.
    func recordUsage(_ id: String) {
        recentUsage.removeAll { $0.id == id }
        recentUsage.insert(CommandLibraryUsageEntry(id: id, usedAt: Date()), at: 0)
        if recentUsage.count > Self.maxRecentUsageEntries {
            recentUsage.removeLast(recentUsage.count - Self.maxRecentUsageEntries)
        }
        try? CommandLibraryYaml.writeRecentUsage(recentUsage, path: recentUsagePath)
        gitSync?.markDirty()
    }

    /// Most-recent-first, skipping any id whose command no longer exists
    /// (e.g. deleted since it was last used) rather than showing a dead row.
    func recentlyUsedCommands(limit: Int = 8) -> [DevOpsCommand] {
        var result: [DevOpsCommand] = []
        for entry in recentUsage {
            guard let command = command(id: entry.id) else { continue }
            result.append(command)
            if result.count >= limit { break }
        }
        return result
    }

    /// Renames every reference to `oldID` into `newID` in favorites/recent-
    /// usage state - called only when editing a command moves its file to a
    /// new category/subcategory (see `updateCommand`), so that move never
    /// silently orphans a favorite or a recent-use entry.
    private func migrateID(from oldID: String, to newID: String) {
        if favoriteIDs.remove(oldID) != nil {
            favoriteIDs.insert(newID)
            try? CommandLibraryYaml.writeFavorites(favoriteIDs, path: favoritesPath)
        }
        var changedUsage = false
        recentUsage = recentUsage.map { entry in
            guard entry.id == oldID else { return entry }
            changedUsage = true
            return CommandLibraryUsageEntry(id: newID, usedAt: entry.usedAt)
        }
        if changedUsage {
            try? CommandLibraryYaml.writeRecentUsage(recentUsage, path: recentUsagePath)
        }
    }

    // MARK: Add / edit / duplicate / delete (Phase 2)

    private static func slugify(_ name: String) -> String {
        var slug = ""
        var lastWasDash = false
        for scalar in name.lowercased().unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                slug.unicodeScalars.append(scalar)
                lastWasDash = false
            } else if !lastWasDash && !slug.isEmpty {
                slug.append("-")
                lastWasDash = true
            }
        }
        let trimmed = slug.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return trimmed.isEmpty ? "command" : trimmed
    }

    private static func pathID(category: String, subcategory: String?, slug: String) -> String {
        ([category, subcategory, slug].compactMap { $0 }.filter { !$0.isEmpty }).joined(separator: "/")
    }

    private func filePath(for id: String) -> String {
        root.appendingPathComponent(id).appendingPathExtension("yaml").path
    }

    /// A slug unique within `category`/`subcategory` - appends `-2`, `-3`, ...
    /// until no file already exists at that path. Only used when creating a
    /// brand-new command; an edit reuses its existing slug (see
    /// `updateCommand`) so editing a command's name never changes its id.
    private func uniqueSlug(base: String, category: String, subcategory: String?) -> String {
        var slug = base
        var n = 2
        while fm.fileExists(atPath: filePath(for: Self.pathID(category: category, subcategory: subcategory, slug: slug))) {
            slug = "\(base)-\(n)"
            n += 1
        }
        return slug
    }

    /// "Add Command" - always creates a new file/id, never collides with an
    /// existing one (see `uniqueSlug`).
    @discardableResult
    func createCommand(
        name: String, description: String, category: String, subcategory: String?,
        commandTemplate: String, parameters: [CommandParameter], tags: [String], risk: CommandRiskLevel
    ) -> DevOpsCommand {
        let slug = uniqueSlug(base: Self.slugify(name), category: category, subcategory: subcategory)
        let id = Self.pathID(category: category, subcategory: subcategory, slug: slug)
        let command = DevOpsCommand(
            id: id, name: name, description: description, category: category, subcategory: subcategory,
            commandTemplate: commandTemplate, parameters: parameters, tags: tags, risk: risk
        )
        try? CommandLibraryYaml.writeCommand(command, path: filePath(for: id))
        gitSync?.markDirty()
        reloadAll()
        return command
    }

    /// "Duplicate" - clones an existing command's fields into a brand-new
    /// id/file (its own name suffixed " Copy"), leaving the original
    /// untouched. Returns `nil` if `id` no longer exists.
    @discardableResult
    func duplicateCommand(id: String) -> DevOpsCommand? {
        guard let original = command(id: id) else { return nil }
        return createCommand(
            name: "\(original.name) Copy", description: original.description, category: original.category,
            subcategory: original.subcategory, commandTemplate: original.commandTemplate,
            parameters: original.parameters, tags: original.tags, risk: original.risk
        )
    }

    /// Edits an existing command in place. The on-disk slug (the id's last
    /// path component) never changes on an edit - only a `createCommand`
    /// picks a fresh slug from the name - so renaming a command's `name`
    /// field never moves its file. Changing `category`/`subcategory` does
    /// move the file (the id *is* the on-disk category/subcategory/slug
    /// path - see this file's header) - favorite/recent-usage state for the
    /// old id is carried over to the new one rather than silently orphaned.
    @discardableResult
    func updateCommand(
        id: String, name: String, description: String, category: String, subcategory: String?,
        commandTemplate: String, parameters: [CommandParameter], tags: [String], risk: CommandRiskLevel
    ) -> DevOpsCommand? {
        guard command(id: id) != nil else { return nil }
        let slug = (id as NSString).lastPathComponent
        let newID = Self.pathID(category: category, subcategory: subcategory, slug: slug)
        let updated = DevOpsCommand(
            id: newID, name: name, description: description, category: category, subcategory: subcategory,
            commandTemplate: commandTemplate, parameters: parameters, tags: tags, risk: risk
        )
        if newID != id {
            try? fm.removeItem(atPath: filePath(for: id))
            migrateID(from: id, to: newID)
        }
        try? CommandLibraryYaml.writeCommand(updated, path: filePath(for: newID))
        gitSync?.markDirty()
        reloadAll()
        return updated
    }

    func deleteCommand(id: String) {
        try? fm.removeItem(atPath: filePath(for: id))
        favoriteIDs.remove(id)
        try? CommandLibraryYaml.writeFavorites(favoriteIDs, path: favoritesPath)
        recentUsage.removeAll { $0.id == id }
        try? CommandLibraryYaml.writeRecentUsage(recentUsage, path: recentUsagePath)
        gitSync?.markDirty()
        reloadAll()
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
        let scan = scanCommandsChecked()
        // GL-21: only seed a library that is *known* to be empty. An
        // enumeration failure looks identical to emptiness from the outside
        // and used to trigger a full 73-file re-seed over real data.
        guard !scan.enumerationFailed, scan.commands.isEmpty else { return }
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
