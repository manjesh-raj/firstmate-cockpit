// Manjesh Grand Line - native macOS app.
//
// New Project sheet (cockpit-fix-shift-new-project). Phase 3
// (cockpit-shift-projects) shipped a real edit form for an existing
// project's fields directly on the Projects detail page (`ShiftController.
// rebuildProjectDetail`/`detailSaveClicked`), but never a way to create one -
// `ShiftStore` only had `updateProject`, no `addProject`. This sheet is the
// missing creation path.
//
// Fields per the brief: name, description, status (default "Not Started"),
// start date, due date - the same set `ShiftProject` already supports. Start/
// due date stay plain "YYYY-MM-DD" text fields, matching the existing detail
// edit form's own fields (`detailStartDateField`/`detailDueDateField`) rather
// than the Task/Follow-up editors' date picker: a project's dates are
// day-granularity only, and - the reason that actually matters - a blank field
// is how "no date set" is expressed, which a date picker cannot represent.
//
// Phase 6 of the full-app UI audit moved it onto the shared form scaffold
// (`HelmForm.swift`); Status became a `HelmFieldCard` like every other
// enum-like choice in the app. Its field set and validation are unchanged.

import AppKit

final class ShiftProjectEditorController: NSViewController {

    /// Called with the assembled project on Save. The caller
    /// (`ShiftController`) persists it via `ShiftStore.addProject`.
    var onSave: ((ShiftProject) -> Void)?

    private let nameField = HelmTextField(placeholder: "What is this project?", style: .lead)
    private let statusCard = HelmFieldCard(label: "Status")
    private let startDateField = HelmTextField(placeholder: "YYYY-MM-DD")
    private let dueDateField = HelmTextField(placeholder: "YYYY-MM-DD")
    private let descriptionView = HelmTextView(height: 100)

    private var selectedStatus: ShiftProjectStatus = .notStarted

    override func loadView() {
        let form = HelmFormSheet(title: "New Project")
        view = form

        form.addLead(nameField)

        form.addSection("Details")
        statusCard.configureChoices(ShiftProjectStatus.allCases.map(\.displayName),
                                    selectedIndex: ShiftProjectStatus.allCases.firstIndex(of: .notStarted) ?? 0) { [weak self] index in
            guard let self, ShiftProjectStatus.allCases.indices.contains(index) else { return }
            self.selectedStatus = ShiftProjectStatus.allCases[index]
        }
        form.addRow(statusCard)
        form.addFieldColumns([("Start date", startDateField), ("Due date", dueDateField)])

        form.addSection("Description")
        form.addRow(descriptionView)

        form.setFooter(target: self,
                       confirmTitle: "Create Project",
                       confirm: #selector(save),
                       cancel: #selector(cancel))

        form.refreshTheme()
        form.sizeToFitContent()
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
        project.status = selectedStatus
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
}
