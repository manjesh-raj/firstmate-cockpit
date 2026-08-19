// Manjesh Grand Line - native macOS app.
//
// Conflict resolution sheet (cockpit-shift-conflict-handling, phase 6 - the
// last queued phase of the Shift build, see AGENTS.md's "Shift" section).
// Presented from `ShiftController.syncPillClicked()` when the sync pill is
// in `.conflict` - one screen listing every record `ShiftGitSync`'s
// record-level 3-way merge (`ShiftConflict.swift`) couldn't resolve on its
// own, grouped by kind (Tasks / Follow-ups / Projects), each with a plain-
// language field-by-field comparison (never a raw YAML diff) and two
// buttons - "Keep mine" / "Keep GitHub's". "Apply & Push" only enables once
// every conflicting record has an explicit choice; there is no default and
// no way to silently skip one.
//
// Follows this app's established plain-`NSStackView`-form sheet shape
// (`ShiftTaskEditorController.swift`) rather than `HostEditorController`'s
// scroll-and-cap window treatment, since this is a sheet on `ShiftController`
// like every other Shift editor.

import AppKit

final class ShiftConflictController: NSViewController {

    private let conflictSet: ShiftConflictSet

    /// The caller (`ShiftController`) wires this to
    /// `ShiftGitSync.resolveConflictsAsync` - this controller never touches
    /// `ShiftGitSync` directly, so it stays testable/reusable independent of
    /// where the conflict set came from.
    var onResolve: ((_ choices: [String: ShiftConflictChoice], _ completion: @escaping (Bool) -> Void) -> Void)?

    private var choices: [String: ShiftConflictChoice] = [:]
    /// (localButton, remoteButton) per conflicting record id, so a click can
    /// re-style just that row's two buttons without rebuilding the page.
    private var choiceButtons: [String: (local: NSButton, remote: NSButton)] = [:]

    private let applyButton = NSButton(title: "Apply & Push", target: nil, action: nil)
    private let statusLabel = NSTextField(labelWithString: "")
    private let progressSpinner = NSProgressIndicator()

    init(conflictSet: ShiftConflictSet) {
        self.conflictSet = conflictSet
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 620, height: 640))
        view = root
        let theme = ThemeManager.shared.theme
        root.wantsLayer = true
        root.layer?.backgroundColor = HelmTheme.nsColor(theme.backgroundHex).cgColor
        ThemeManager.shared.observe { [weak root] theme in
            root?.appearance = NSAppearance(named: theme.mode == .dark ? .darkAqua : .aqua)
            root?.layer?.backgroundColor = HelmTheme.nsColor(theme.backgroundHex).cgColor
        }

        let title = NSTextField(labelWithString: "Sync conflict")
        title.font = ShiftFont.serif(19)
        title.textColor = HelmTheme.nsColor(theme.chromeInkHex)

        let subtitleText: String
        if conflictSet.totalConflictCount == 1 {
            subtitleText = "1 record was edited differently on this machine and on GitHub. Choose which version to keep."
        } else {
            subtitleText = "\(conflictSet.totalConflictCount) records were edited differently on this machine and on GitHub. Choose which version to keep for each."
        }
        let subtitle = NSTextField(wrappingLabelWithString: subtitleText)
        subtitle.font = .systemFont(ofSize: 12)
        subtitle.textColor = HelmTheme.mutedInk(theme)

        let headerStack = NSStackView(views: [title, subtitle])
        headerStack.orientation = .vertical
        headerStack.alignment = .leading
        headerStack.spacing = 4
        headerStack.translatesAutoresizingMaskIntoConstraints = false

        let bodyStack = NSStackView()
        bodyStack.orientation = .vertical
        bodyStack.alignment = .leading
        bodyStack.spacing = 18
        bodyStack.translatesAutoresizingMaskIntoConstraints = false

        if !conflictSet.autoMergeNotes.isEmpty {
            bodyStack.addArrangedSubview(buildAutoMergeSection(theme: theme))
        }
        if !conflictSet.taskConflicts.isEmpty {
            bodyStack.addArrangedSubview(buildConflictSection(title: "Tasks", conflicts: conflictSet.taskConflicts, theme: theme))
        }
        if !conflictSet.followUpConflicts.isEmpty {
            bodyStack.addArrangedSubview(buildConflictSection(title: "Follow-ups", conflicts: conflictSet.followUpConflicts, theme: theme))
        }
        if !conflictSet.projectConflicts.isEmpty {
            bodyStack.addArrangedSubview(buildConflictSection(title: "Projects", conflicts: conflictSet.projectConflicts, theme: theme))
        }

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(bodyStack)
        NSLayoutConstraint.activate([
            bodyStack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            bodyStack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            bodyStack.topAnchor.constraint(equalTo: document.topAnchor),
            bodyStack.bottomAnchor.constraint(equalTo: document.bottomAnchor),
        ])
        scroll.documentView = document
        NSLayoutConstraint.activate([document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor)])

        statusLabel.font = .systemFont(ofSize: 11.5)
        statusLabel.textColor = HelmTheme.nsColor(theme.ansiHex[1])
        statusLabel.isHidden = true

        progressSpinner.style = .spinning
        progressSpinner.controlSize = .small
        progressSpinner.isDisplayedWhenStopped = false
        progressSpinner.translatesAutoresizingMaskIntoConstraints = false

        let cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancelClicked))
        applyButton.keyEquivalent = "\r"
        applyButton.target = self
        applyButton.action = #selector(applyClicked)
        refreshApplyEnabled()

        let footerSpacer = NSView()
        footerSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let footer = NSStackView(views: [statusLabel, footerSpacer, progressSpinner, cancelButton, applyButton])
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.spacing = 10
        footer.translatesAutoresizingMaskIntoConstraints = false

        let outer = NSStackView(views: [headerStack, scroll, footer])
        outer.orientation = .vertical
        outer.alignment = .leading
        outer.spacing = 16
        outer.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(outer)
        NSLayoutConstraint.activate([
            outer.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            outer.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),
            outer.topAnchor.constraint(equalTo: root.topAnchor, constant: 22),
            outer.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -20),
            headerStack.widthAnchor.constraint(equalTo: outer.widthAnchor),
            scroll.widthAnchor.constraint(equalTo: outer.widthAnchor),
            footer.widthAnchor.constraint(equalTo: outer.widthAnchor),
        ])
    }

    // MARK: Sections

    private func buildAutoMergeSection(theme: HelmTheme) -> NSView {
        let panel = HelmCard()
        let header = NSTextField(labelWithString: "Merged automatically (\(conflictSet.autoMergeNotes.count))")
        header.font = ShiftFont.serif(14)
        header.textColor = HelmTheme.nsColor(theme.chromeInkHex)
        panel.setHeader(header)

        let list = NSStackView()
        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 4
        list.translatesAutoresizingMaskIntoConstraints = false
        for note in conflictSet.autoMergeNotes {
            let line = NSTextField(wrappingLabelWithString: "\(note.kind.rawValue) \u{201c}\(note.title)\u{201d} \u{2013} \(note.action)")
            line.font = .systemFont(ofSize: 11.5)
            line.textColor = HelmTheme.mutedInk(theme)
            list.addArrangedSubview(line)
            line.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true
        }
        panel.setBody(list, insets: HelmCard.contentInsets)
        panel.applyTheme(theme)
        panel.widthAnchor.constraint(equalToConstant: 572).isActive = true
        return panel
    }

    private func buildConflictSection<T: ShiftConflictRecordType>(
        title: String, conflicts: [ShiftRecordConflict<T>], theme: HelmTheme
    ) -> NSView {
        let panel = HelmCard()
        let header = NSTextField(labelWithString: "\(title) (\(conflicts.count))")
        header.font = ShiftFont.serif(14)
        header.textColor = HelmTheme.nsColor(theme.chromeInkHex)
        panel.setHeader(header)

        let list = NSStackView()
        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 14
        list.translatesAutoresizingMaskIntoConstraints = false
        for conflict in conflicts {
            let row = buildConflictRow(conflict, theme: theme)
            list.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true
        }
        panel.setBody(list, insets: HelmCard.contentInsets)
        panel.applyTheme(theme)
        panel.widthAnchor.constraint(equalToConstant: 572).isActive = true
        return panel
    }

    private func buildConflictRow<T: ShiftConflictRecordType>(_ conflict: ShiftRecordConflict<T>, theme: HelmTheme) -> NSView {
        let titleLabel = NSTextField(labelWithString: conflict.title)
        titleLabel.font = .systemFont(ofSize: 12.5, weight: .semibold)
        titleLabel.textColor = HelmTheme.nsColor(theme.chromeInkHex)

        let diffStack = NSStackView()
        diffStack.orientation = .vertical
        diffStack.alignment = .leading
        diffStack.spacing = 3
        diffStack.translatesAutoresizingMaskIntoConstraints = false

        if conflict.local == nil || conflict.remote == nil {
            let text = conflict.local == nil ? "Deleted on this machine, but edited on GitHub." : "Edited on this machine, but deleted on GitHub."
            let line = NSTextField(wrappingLabelWithString: text)
            line.font = .systemFont(ofSize: 11)
            line.textColor = HelmTheme.mutedInk(theme)
            diffStack.addArrangedSubview(line)
            line.widthAnchor.constraint(equalTo: diffStack.widthAnchor).isActive = true
        } else {
            for diff in conflict.fieldDiffs {
                let line = NSTextField(wrappingLabelWithString: "\(diff.field): \u{201c}\(diff.local)\u{201d} here \u{2192} \u{201c}\(diff.remote)\u{201d} on GitHub")
                line.font = .monospacedSystemFont(ofSize: 10.5, weight: .regular)
                line.textColor = HelmTheme.mutedInk(theme)
                diffStack.addArrangedSubview(line)
                line.widthAnchor.constraint(equalTo: diffStack.widthAnchor).isActive = true
            }
        }

        // Neither button is ever disabled: when a side is `nil` (deleted on
        // that side), choosing it is still a meaningful, valid resolution -
        // it means letting that deletion stand - so the label says so
        // instead of the button being unavailable.
        let localButton = NSButton(title: conflict.local != nil ? "Keep mine" : "Keep deleted (mine)", target: self, action: #selector(choiceClicked(_:)))
        localButton.identifier = NSUserInterfaceItemIdentifier("\(conflict.id)\u{0}local")
        localButton.bezelStyle = .rounded
        localButton.wantsLayer = true
        localButton.layer?.cornerRadius = 5

        let remoteButton = NSButton(title: conflict.remote != nil ? "Keep GitHub's" : "Keep deleted (GitHub's)", target: self, action: #selector(choiceClicked(_:)))
        remoteButton.identifier = NSUserInterfaceItemIdentifier("\(conflict.id)\u{0}remote")
        remoteButton.bezelStyle = .rounded
        remoteButton.wantsLayer = true
        remoteButton.layer?.cornerRadius = 5

        choiceButtons[conflict.id] = (localButton, remoteButton)
        styleChoiceButtons(id: conflict.id, theme: theme)

        let buttonRow = NSStackView(views: [localButton, remoteButton])
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 8

        let row = NSStackView(views: [titleLabel, diffStack, buttonRow])
        row.orientation = .vertical
        row.alignment = .leading
        row.spacing = 6
        row.translatesAutoresizingMaskIntoConstraints = false
        diffStack.widthAnchor.constraint(equalTo: row.widthAnchor).isActive = true
        return row
    }

    // MARK: Choice handling

    @objc private func choiceClicked(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue else { return }
        let parts = raw.components(separatedBy: "\u{0}")
        guard parts.count == 2 else { return }
        let id = parts[0]
        choices[id] = parts[1] == "local" ? .keepLocal : .keepRemote
        styleChoiceButtons(id: id, theme: ThemeManager.shared.theme)
        refreshApplyEnabled()
    }

    private func styleChoiceButtons(id: String, theme: HelmTheme) {
        guard let pair = choiceButtons[id] else { return }
        let choice = choices[id]
        for (button, side) in [(pair.local, ShiftConflictChoice.keepLocal), (pair.remote, ShiftConflictChoice.keepRemote)] {
            let selected = choice == side
            button.contentTintColor = selected ? HelmTheme.nsColor(theme.accentHex) : nil
            button.layer?.borderWidth = selected ? 2 : 0
        }
    }

    private var totalConflictIDs: [String] {
        conflictSet.taskConflicts.map(\.id) + conflictSet.followUpConflicts.map(\.id) + conflictSet.projectConflicts.map(\.id)
    }

    private func refreshApplyEnabled() {
        applyButton.isEnabled = totalConflictIDs.allSatisfy { choices[$0] != nil }
    }

    @objc private func cancelClicked() {
        dismiss(self)
    }

    @objc private func applyClicked() {
        guard let onResolve else { return }
        applyButton.isEnabled = false
        progressSpinner.startAnimation(nil)
        statusLabel.isHidden = true
        onResolve(choices) { [weak self] ok in
            guard let self else { return }
            self.progressSpinner.stopAnimation(nil)
            if ok {
                self.dismiss(self)
            } else {
                self.statusLabel.stringValue = "Could not push the resolution - check the sync pill's tooltip and try again."
                self.statusLabel.isHidden = false
                self.applyButton.isEnabled = true
            }
        }
    }
}
