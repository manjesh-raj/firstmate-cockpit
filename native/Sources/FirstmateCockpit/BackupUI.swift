// Manjesh Grand Line - native macOS app.
//
// Export/Import panels for the portable local-state bundle (`BackupData.swift`
// holds the format/diff/apply logic - this is the one AppKit-facing
// implementation, shared by Settings' "Backup & Restore" card and
// Bootstrap's "Restore Grand Line config" step so neither duplicates it).
//
// Export writes to a captain-chosen local file (`NSSavePanel`) or to the
// captain's GitHub config repo (`GitHubBackupSource`, `BackupGitHub.swift`);
// import reads from a local file (`NSOpenPanel`) or fetches the one fixed
// bundle GitHub export writes. Either way, the bytes are decoded into a
// `GrandLineBackup`, diffed against the live stores, and shown in a
// confirmation alert before anything is written - nothing is applied without
// that explicit confirm, regardless of where the bytes came from.

import AppKit
import UniformTypeIdentifiers

enum BackupDestination {
    case local
    case github
}

enum BackupUI {
    private static var backupContentType: UTType {
        UTType(filenameExtension: "glbackup") ?? .json
    }

    /// Export the live stores' state, to a destination the captain picks
    /// first. Shows counts (hosts/snippets/referenced keys) before the write,
    /// and a toast confirming what was written after.
    static func exportFlow(from viewController: NSViewController, hostStore: HostStore, keyStore: SSHKeyStore, snippetStore: SnippetStore, dictationStore: DictationStore) {
        let bundle = GrandLineBackupBuilder.build(hosts: hostStore.hosts, snippets: snippetStore.snippets, allKeys: keyStore.keys, dictationStore: dictationStore)

        guard let destination = chooseDestination(
            in: viewController, verb: "Export", title: "Export Grand Line config",
            localLabel: "Local File…", githubLabel: "Export to \(GitHubBackupSource.destinationLabel)"
        ) else { return }

        switch destination {
        case .local:
            exportToLocal(bundle, from: viewController)
        case .github:
            exportToGitHub(bundle, from: viewController)
        }
    }

    private static func exportToLocal(_ bundle: GrandLineBackup, from viewController: NSViewController) {
        let panel = NSSavePanel()
        panel.title = "Export Grand Line Config"
        panel.prompt = "Export"
        // Deliberately no `.glbackup` suffix here - `allowedContentTypes` owns
        // appending the extension. `.glbackup` has no `UTExportedTypeDeclarations`
        // entry in this app's Info.plist (there is no Info.plist at all - this is
        // a plain SPM executable), so `UTType(filenameExtension:)` synthesizes an
        // unregistered dynamic type; `NSSavePanel` doesn't recognize a name that
        // already ends in that extension as "already correct" and appends its own
        // copy, producing `grand-line-backup.glbackup.glbackup`. Confirmed live via
        // a temporary probe reading `panel.url` after `makeKeyAndOrderFront`.
        panel.nameFieldStringValue = "grand-line-backup"
        panel.allowedContentTypes = [backupContentType]
        panel.message = summaryLine(hostCount: bundle.hosts.count, snippetCount: bundle.snippets.count, keyCount: bundle.keys.count, vocabularyCount: bundle.dictation?.vocabulary?.count ?? 0)

        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try GrandLineBackupFile.encode(bundle)
            try data.write(to: url, options: .atomic)
            Toast.show(in: viewController.view, message: "Exported \(bundle.hosts.count) host(s), \(bundle.snippets.count) snippet(s)")
        } catch {
            presentError(error, in: viewController)
        }
    }

    /// Writing to GitHub is a real, external, remote action - a real commit
    /// to the captain's real repo (create-or-update, see `GitHubBackupSource.
    /// export`'s doc comment) - not a local write. Runs off the main thread
    /// since it's a blocking network call; the confirming toast/error lands
    /// back on the main thread.
    private static func exportToGitHub(_ bundle: GrandLineBackup, from viewController: NSViewController) {
        Toast.show(in: viewController.view, message: "Exporting to \(GitHubBackupSource.destinationLabel)…")
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try GitHubBackupSource.export(bundle)
                DispatchQueue.main.async {
                    Toast.show(in: viewController.view, message: "Exported \(bundle.hosts.count) host(s), \(bundle.snippets.count) snippet(s) to \(GitHubBackupSource.destinationLabel)")
                }
            } catch {
                DispatchQueue.main.async { presentError(error, in: viewController) }
            }
        }
    }

    private static func summaryLine(hostCount: Int, snippetCount: Int, keyCount: Int, vocabularyCount: Int) -> String {
        var bits = ["\(hostCount) host\(hostCount == 1 ? "" : "s")", "\(snippetCount) snippet\(snippetCount == 1 ? "" : "s")"]
        if keyCount > 0 {
            bits.append("\(keyCount) referenced key\(keyCount == 1 ? "" : "s") (metadata only - no private key material)")
        }
        if vocabularyCount > 0 {
            bits.append("\(vocabularyCount) dictation vocabulary word\(vocabularyCount == 1 ? "" : "s")")
        }
        return "About to export: " + bits.joined(separator: ", ") + "."
    }

    /// Read a bundle from a source the captain picks first, diff it against
    /// the live stores, and show that diff for confirmation before writing
    /// anything - identical downstream of the source, whether the bytes came
    /// from a local file or GitHub.
    static func importFlow(from viewController: NSViewController, hostStore: HostStore, keyStore: SSHKeyStore, snippetStore: SnippetStore, dictationStore: DictationStore, onApplied: (() -> Void)? = nil) {
        guard let source = chooseDestination(
            in: viewController, verb: "Import", title: "Import Grand Line config",
            localLabel: "Upload from Local…", githubLabel: "Import from \(GitHubBackupSource.destinationLabel)"
        ) else { return }

        switch source {
        case .local:
            importFromLocal(from: viewController, hostStore: hostStore, keyStore: keyStore, snippetStore: snippetStore, dictationStore: dictationStore, onApplied: onApplied)
        case .github:
            importFromGitHub(from: viewController, hostStore: hostStore, keyStore: keyStore, snippetStore: snippetStore, dictationStore: dictationStore, onApplied: onApplied)
        }
    }

    private static func importFromLocal(from viewController: NSViewController, hostStore: HostStore, keyStore: SSHKeyStore, snippetStore: SnippetStore, dictationStore: DictationStore, onApplied: (() -> Void)?) {
        let panel = NSOpenPanel()
        panel.title = "Import Grand Line Config"
        panel.prompt = "Choose"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [backupContentType]

        guard panel.runModal() == .OK, let url = panel.url else { return }
        let bundle: GrandLineBackup
        do {
            let data = try Data(contentsOf: url)
            bundle = try GrandLineBackupFile.decode(data)
        } catch {
            presentError(error, in: viewController)
            return
        }
        diffAndApply(bundle, from: viewController, hostStore: hostStore, keyStore: keyStore, snippetStore: snippetStore, dictationStore: dictationStore, onApplied: onApplied)
    }

    /// Fetches the one fixed bundle GitHub export writes - no listing or
    /// picker, since there's only ever one file (see `GitHubBackupSource`'s
    /// header). Runs off the main thread since it's a blocking network call;
    /// the diff/confirm alert (and everything downstream of it) runs back on
    /// the main thread exactly like the local-file path.
    private static func importFromGitHub(from viewController: NSViewController, hostStore: HostStore, keyStore: SSHKeyStore, snippetStore: SnippetStore, dictationStore: DictationStore, onApplied: (() -> Void)?) {
        Toast.show(in: viewController.view, message: "Fetching from \(GitHubBackupSource.destinationLabel)…")
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let bundle = try GitHubBackupSource.fetchBundle()
                DispatchQueue.main.async {
                    diffAndApply(bundle, from: viewController, hostStore: hostStore, keyStore: keyStore, snippetStore: snippetStore, dictationStore: dictationStore, onApplied: onApplied)
                }
            } catch {
                DispatchQueue.main.async { presentError(error, in: viewController) }
            }
        }
    }

    /// The shared tail of both import paths: diff against the live stores,
    /// confirm, apply, toast.
    private static func diffAndApply(_ bundle: GrandLineBackup, from viewController: NSViewController, hostStore: HostStore, keyStore: SSHKeyStore, snippetStore: SnippetStore, dictationStore: DictationStore, onApplied: (() -> Void)?) {
        let preview = BackupImport.diff(
            bundle: bundle, existingHosts: hostStore.hosts, existingSnippets: snippetStore.snippets, existingKeys: keyStore.keys,
            existingVocabulary: dictationStore.vocabulary, existingShortcut: AppSettings.shared.dictationShortcut
        )

        guard confirmImport(preview, in: viewController) else { return }
        BackupImport.apply(preview, bundle: bundle, hostStore: hostStore, snippetStore: snippetStore, dictationStore: dictationStore)
        let appliedHosts = preview.newHostsCount + preview.changedHostsCount
        let appliedSnippets = preview.newSnippetsCount + preview.changedSnippetsCount
        Toast.show(in: viewController.view, message: "Imported \(appliedHosts) host(s), \(appliedSnippets) snippet(s)")
        onApplied?()
    }

    /// A real destination/source picker, shown before either flow touches
    /// disk or network. The GitHub button is disabled with an explanation
    /// (never silently skipped or attempted) when `gh` isn't installed/
    /// authenticated - the same guidance-only convention this app already
    /// uses for a missing prerequisite (e.g. the gh-cli isotope row in "Not
    /// synced here, by design").
    private static func chooseDestination(in viewController: NSViewController, verb: String, title: String, localLabel: String, githubLabel: String) -> BackupDestination? {
        let alert = NSAlert()
        alert.messageText = title
        let githubAvailable = GitHubBackupSource.isAvailable()
        alert.informativeText = githubAvailable
            ? "Choose where to \(verb.lowercased()) this config."
            : "Choose where to \(verb.lowercased()) this config.\n\n\(GitHubBackupSource.unavailableReason)"
        alert.addButton(withTitle: localLabel)
        let githubButton = alert.addButton(withTitle: githubLabel)
        alert.addButton(withTitle: "Cancel")
        githubButton.isEnabled = githubAvailable
        if !githubAvailable {
            githubButton.toolTip = GitHubBackupSource.unavailableReason
        }

        switch alert.runModal() {
        case .alertFirstButtonReturn: return .local
        case .alertSecondButtonReturn: return githubAvailable ? .github : nil
        default: return nil
        }
    }

    /// A real confirm/cancel alert whose body is the actual diff, row by
    /// row - never a static description. Returns whether the captain chose
    /// to import.
    private static func confirmImport(_ preview: BackupImport.Preview, in viewController: NSViewController) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Import Grand Line config?"
        alert.informativeText = confirmSummary(preview)
        alert.addButton(withTitle: "Import")
        alert.addButton(withTitle: "Cancel")
        alert.accessoryView = diffScrollView(preview)
        return alert.runModal() == .alertFirstButtonReturn
    }

    private static func confirmSummary(_ preview: BackupImport.Preview) -> String {
        var lines = [
            "Hosts: \(preview.newHostsCount) new, \(preview.changedHostsCount) changed, \(preview.unchangedHostsCount) unchanged.",
            "Snippets: \(preview.newSnippetsCount) new, \(preview.changedSnippetsCount) changed, \(preview.unchangedSnippetsCount) unchanged.",
            "Settings to apply: \(preview.settingsSummary).",
        ]
        if !preview.vocabularyRows.isEmpty {
            lines.append("Dictation vocabulary: \(preview.newVocabularyCount) new, \(preview.unchangedVocabularyCount) already present.")
        }
        if let shortcutDisplay = preview.shortcutDisplay {
            lines.append(preview.shortcutStatus == .changed
                ? "Dictation shortcut will change to \(shortcutDisplay)."
                : "Dictation shortcut unchanged (\(shortcutDisplay)).")
        }
        if !preview.keyWarnings.isEmpty {
            lines.append("\(preview.keyWarnings.count) host reference(s) point at a key not on this machine - see below.")
        }
        return lines.joined(separator: "\n")
    }

    /// The real, per-item diff listing - built entirely from `preview`, never
    /// hardcoded copy.
    private static func diffScrollView(_ preview: BackupImport.Preview) -> NSView {
        var lines: [String] = []
        lines.append("HOSTS (\(preview.hostRows.count))")
        if preview.hostRows.isEmpty {
            lines.append("  (none in this file)")
        } else {
            for row in preview.hostRows { lines.append("  [\(row.status.rawValue.uppercased())] \(row.label)") }
        }
        lines.append("")
        lines.append("SNIPPETS (\(preview.snippetRows.count))")
        if preview.snippetRows.isEmpty {
            lines.append("  (none in this file)")
        } else {
            for row in preview.snippetRows { lines.append("  [\(row.status.rawValue.uppercased())] \(row.label)") }
        }
        if !preview.vocabularyRows.isEmpty {
            lines.append("")
            lines.append("DICTATION VOCABULARY (\(preview.vocabularyRows.count))")
            for row in preview.vocabularyRows { lines.append("  [\(row.status.rawValue.uppercased())] \(row.word)") }
        }
        if let shortcutDisplay = preview.shortcutDisplay, let shortcutStatus = preview.shortcutStatus {
            lines.append("")
            lines.append("DICTATION SHORTCUT")
            lines.append("  [\(shortcutStatus.rawValue.uppercased())] \(shortcutDisplay)")
        }
        if !preview.keyWarnings.isEmpty {
            lines.append("")
            lines.append("KEY REFERENCES NEEDING ATTENTION")
            for warning in preview.keyWarnings { lines.append("  - \(warning)") }
        }

        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 440, height: 220))
        textView.string = lines.joined(separator: "\n")
        textView.isEditable = false
        textView.isSelectable = true
        textView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        textView.textContainerInset = NSSize(width: 6, height: 6)

        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 440, height: 220))
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        // Phase 6 of the UI audit: the shared sunken chrome rather than
        // AppKit's own `.bezelBorder`. Applied once with the current theme and
        // never observed - this view only exists for the lifetime of a modal
        // `NSAlert`, during which no theme change can reach it.
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        let theme = ThemeManager.shared.theme
        HelmField.makeSunken(scroll)
        HelmField.applySunken(to: scroll, theme: theme)
        textView.drawsBackground = true
        textView.backgroundColor = HelmField.fill(theme)
        textView.textColor = HelmField.ink(theme)
        return scroll
    }

    private static func presentError(_ error: Error, in viewController: NSViewController) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Couldn't complete that"
        alert.informativeText = error.localizedDescription
        alert.runModal()
    }
}
