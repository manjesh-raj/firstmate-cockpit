// Manjesh Grand Line - native macOS app.
//
// Export/Import panels for the portable local-state bundle (`BackupData.swift`
// holds the format/diff/apply logic - this is the one AppKit-facing
// implementation, shared by Settings' "Backup & Restore" card and
// Bootstrap's "Restore Grand Line config" step so neither duplicates it).
//
// Export writes a real `NSSavePanel` selection; import reads a real
// `NSOpenPanel` selection, computes a genuine diff against the live stores,
// and shows it in a confirmation alert before anything is written - nothing
// is applied without that explicit confirm.

import AppKit
import UniformTypeIdentifiers

enum BackupUI {
    private static var backupContentType: UTType {
        UTType(filenameExtension: "glbackup") ?? .json
    }

    /// Export the live stores' state to a captain-chosen file. Shows counts
    /// (hosts/snippets/referenced keys) in the panel's own message before the
    /// save, and a toast confirming what was written after.
    static func exportFlow(from viewController: NSViewController, hostStore: HostStore, keyStore: SSHKeyStore, snippetStore: SnippetStore) {
        let bundle = GrandLineBackupBuilder.build(hosts: hostStore.hosts, snippets: snippetStore.snippets, allKeys: keyStore.keys)

        let panel = NSSavePanel()
        panel.title = "Export Grand Line Config"
        panel.prompt = "Export"
        panel.nameFieldStringValue = "grand-line-backup.glbackup"
        panel.allowedContentTypes = [backupContentType]
        panel.message = summaryLine(hostCount: bundle.hosts.count, snippetCount: bundle.snippets.count, keyCount: bundle.keys.count)

        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try GrandLineBackupFile.encode(bundle)
            try data.write(to: url, options: .atomic)
            Toast.show(in: viewController.view, message: "Exported \(bundle.hosts.count) host(s), \(bundle.snippets.count) snippet(s)")
        } catch {
            presentError(error, in: viewController)
        }
    }

    private static func summaryLine(hostCount: Int, snippetCount: Int, keyCount: Int) -> String {
        var bits = ["\(hostCount) host\(hostCount == 1 ? "" : "s")", "\(snippetCount) snippet\(snippetCount == 1 ? "" : "s")"]
        if keyCount > 0 {
            bits.append("\(keyCount) referenced key\(keyCount == 1 ? "" : "s") (metadata only - no private key material)")
        }
        return "About to export: " + bits.joined(separator: ", ") + "."
    }

    /// Read a captain-chosen file, diff it against the live stores, and show
    /// that diff for confirmation before writing anything.
    static func importFlow(from viewController: NSViewController, hostStore: HostStore, keyStore: SSHKeyStore, snippetStore: SnippetStore, onApplied: (() -> Void)? = nil) {
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

        let preview = BackupImport.diff(
            bundle: bundle, existingHosts: hostStore.hosts, existingSnippets: snippetStore.snippets, existingKeys: keyStore.keys
        )

        guard confirmImport(preview, in: viewController) else { return }
        BackupImport.apply(preview, bundle: bundle, hostStore: hostStore, snippetStore: snippetStore)
        let appliedHosts = preview.newHostsCount + preview.changedHostsCount
        let appliedSnippets = preview.newSnippetsCount + preview.changedSnippetsCount
        Toast.show(in: viewController.view, message: "Imported \(appliedHosts) host(s), \(appliedSnippets) snippet(s)")
        onApplied?()
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
        scroll.borderType = .bezelBorder
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
