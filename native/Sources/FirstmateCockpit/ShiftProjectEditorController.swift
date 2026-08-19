// Manjesh Grand Line - native macOS app.
//
// New Project sheet (cockpit-fix-shift-new-project). Phase 3
// (cockpit-shift-projects) shipped a real edit form for an existing
// project's fields directly on the Projects detail page (`ShiftController.
// rebuildProjectDetail`/`detailSaveClicked`), but never a way to create one -
// `ShiftStore` only had `updateProject`, no `addProject`. This sheet is the
// missing creation path, following `ShiftFollowUpEditorController.swift`'s
// exact shape (a plain `NSStackView` form, no standalone window) rather than
// inventing a new pattern.
//
// Fields per the brief: name, description, status (default "Not Started"),
// start date, due date - the same set `ShiftProject` already supports. Start/
// due date are plain "YYYY-MM-DD" text fields, matching the existing detail
// edit form's own fields (`detailStartDateField`/`detailDueDateField`) rather
// than the Task/Follow-up editors' `NSDatePicker` - a project's dates are
// day-granularity only, no time-of-day component to pick.

import AppKit

final class ShiftProjectEditorController: NSViewController {

    /// Called with the assembled project on Save. The caller
    /// (`ShiftController`) persists it via `ShiftStore.addProject`.
    var onSave: ((ShiftProject) -> Void)?

    private let nameField = NSTextField()
    private let statusPopup = NSPopUpButton()
    private let startDateField = NSTextField()
    private let dueDateField = NSTextField()
    private let descriptionView = NSTextView()

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 440, height: 400))
        root.wantsLayer = true
        view = root
        // Fix for a real theming bug (fm/grandline-task-editor-redesign):
        // forcing `.appearance` alone doesn't paint anything - a plain
        // `NSView` with no `wantsLayer`/`layer.backgroundColor` shows
        // through to the sheet's default (light) window backing regardless
        // of the forced appearance. Same fix as `HostEditorController.
        // loadView()` and `ShiftTaskEditorController.loadView()`.
        ThemeManager.shared.observe { [weak root] theme in
            root?.appearance = NSAppearance(named: theme.mode == .dark ? .darkAqua : .aqua)
            root?.layer?.backgroundColor = HelmTheme.nsColor(theme.backgroundHex).cgColor
        }

        let title = NSTextField(labelWithString: "New Project")
        title.font = .systemFont(ofSize: 15, weight: .semibold)

        nameField.placeholderString = "Name"
        nameField.translatesAutoresizingMaskIntoConstraints = false

        statusPopup.translatesAutoresizingMaskIntoConstraints = false
        for status in ShiftProjectStatus.allCases { statusPopup.addItem(withTitle: status.displayName) }
        statusPopup.selectItem(at: ShiftProjectStatus.allCases.firstIndex(of: .notStarted) ?? 0)

        startDateField.placeholderString = "YYYY-MM-DD"
        startDateField.translatesAutoresizingMaskIntoConstraints = false
        dueDateField.placeholderString = "YYYY-MM-DD"
        dueDateField.translatesAutoresizingMaskIntoConstraints = false

        descriptionView.string = ""
        descriptionView.font = .systemFont(ofSize: 12)
        descriptionView.isRichText = false
        descriptionView.textContainerInset = NSSize(width: 6, height: 6)
        let descScroll = NSScrollView()
        descScroll.borderType = .bezelBorder
        descScroll.hasVerticalScroller = true
        descScroll.documentView = descriptionView
        descScroll.translatesAutoresizingMaskIntoConstraints = false

        let grid = NSGridView(views: [
            [rowLabel("Status"), statusPopup],
            [rowLabel("Start date"), startDateField],
            [rowLabel("Due date"), dueDateField],
        ])
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.rowSpacing = 12
        grid.columnSpacing = 12
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 0).width = 90
        grid.column(at: 1).xPlacement = .fill

        let descLabel = rowLabel("Description")

        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancel.bezelStyle = .rounded
        cancel.keyEquivalent = "\u{1b}"
        let save = NSButton(title: "Save", target: self, action: #selector(save))
        save.bezelStyle = .rounded
        save.keyEquivalent = "\r"
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let bottom = NSStackView(views: [spacer, cancel, save])
        bottom.orientation = .horizontal
        bottom.spacing = 10

        let stack = NSStackView(views: [title, nameField, grid, descLabel, descScroll, bottom])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 18),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -18),
            nameField.widthAnchor.constraint(equalTo: stack.widthAnchor),
            grid.widthAnchor.constraint(equalTo: stack.widthAnchor),
            descScroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            descScroll.heightAnchor.constraint(equalToConstant: 100),
            bottom.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(nameField)
    }

    @objc private func save() {
        let nameText = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !nameText.isEmpty else {
            view.window?.makeFirstResponder(nameField)
            NSSound.beep()
            return
        }
        var project = ShiftProject.fresh()
        project.name = nameText
        project.description = descriptionView.string
        let statusIdx = statusPopup.indexOfSelectedItem
        if statusIdx >= 0, statusIdx < ShiftProjectStatus.allCases.count {
            project.status = ShiftProjectStatus.allCases[statusIdx]
        }
        let startDate = startDateField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        project.startDate = startDate.isEmpty ? nil : startDate
        let dueDate = dueDateField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        project.dueDate = dueDate.isEmpty ? nil : dueDate
        onSave?(project)
        dismiss(self)
    }

    @objc private func cancel() {
        dismiss(self)
    }

    private func rowLabel(_ text: String) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.font = .systemFont(ofSize: 12)
        l.textColor = HelmTheme.mutedInk(ThemeManager.shared.theme)
        return l
    }
}
