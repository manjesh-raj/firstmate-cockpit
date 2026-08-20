// Manjesh Grand Line - native macOS app.
//
// New/Edit Follow-up sheet (cockpit-shift-create-edit, phase 2 of Shift).
// Fields per the brief: Title, follow-up date/time, Priority, optional
// Notes, related Task, related Project. No natural-language date detection -
// that is specific to the Task title field per the brief.
//
// Phase 6 of the full-app UI audit moved it onto the shared form scaffold
// (`HelmForm.swift`). This is the sheet the audit used as its own example of
// the split (§4.7, `helm-dark-sheet-followup-editor.png` next to
// `helm-dark-sheet-task-editor.png`): Priority was a clickable field card in
// the task editor and a stock `NSPopUpButton` here, one rail click apart. All
// three popups are `HelmFieldCard`s now, and the `NSGridView` label column is
// gone. The field set, the validation and what Save writes are unchanged.

import AppKit

final class ShiftFollowUpEditorController: NSViewController {

    private let editing: ShiftFollowUp?
    private let tasks: [ShiftTask]
    private let projects: [ShiftProject]

    /// Called with the assembled follow-up on Save.
    var onSave: ((ShiftFollowUp) -> Void)?

    private let titleField = HelmTextField(placeholder: "What needs checking on?", style: .lead)
    private let followUpDatePicker = HelmDatePicker()
    private let priorityDot = HelmDotAccessory()
    private lazy var priorityCard = HelmFieldCard(label: "Priority", accessory: priorityDot)
    private let taskCard = HelmFieldCard(label: "Related task")
    private let projectCard = HelmFieldCard(label: "Related project")
    private let notesView = HelmTextView(height: 90)

    private var selectedPriority: ShiftPriority
    /// index 0 is always "None"; index n+1 is `tasks[n]` / `projects[n]`.
    private var taskIDs: [String?] = []
    private var projectIDs: [String?] = []
    private var selectedTaskIndex = 0
    private var selectedProjectIndex = 0

    init(followUp: ShiftFollowUp?, tasks: [ShiftTask], projects: [ShiftProject]) {
        self.editing = followUp
        self.tasks = tasks
        self.projects = projects
        self.selectedPriority = followUp?.priority ?? .normal
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        let form = HelmFormSheet(title: editing == nil ? "New Follow-up" : "Edit Follow-up")
        view = form
        form.onApplyTheme = { [weak self] theme in self?.applyExtraTheme(theme) }

        titleField.stringValue = editing?.title ?? ""
        form.addLead(titleField)

        form.addSection("Details")
        let existing = ShiftDateFormatting.dateTime(from: editing?.followUpAt, time: editing?.followUpTime)
        followUpDatePicker.dateValue = existing
            ?? Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: Date()) ?? Date())
            ?? Date()

        priorityCard.configureChoices(ShiftPriority.allCases.map { $0.rawValue.capitalized },
                                      selectedIndex: ShiftPriority.allCases.firstIndex(of: selectedPriority) ?? 1) { [weak self] index in
            guard let self, ShiftPriority.allCases.indices.contains(index) else { return }
            self.selectedPriority = ShiftPriority.allCases[index]
            self.updatePriorityDot(ThemeManager.shared.theme)
        }
        form.addColumns([labelledDatePicker(form), priorityCard])

        form.addSection("Related")
        taskIDs = [nil] + tasks.map { $0.id }
        selectedTaskIndex = editing?.relatedTaskID.flatMap { taskIDs.firstIndex(of: $0) } ?? 0
        taskCard.configureChoices(["None"] + tasks.map { $0.title }, selectedIndex: selectedTaskIndex) { [weak self] index in
            self?.selectedTaskIndex = index
        }
        projectIDs = [nil] + projects.map { $0.id }
        selectedProjectIndex = editing?.projectID.flatMap { projectIDs.firstIndex(of: $0) } ?? 0
        projectCard.configureChoices(["None"] + projects.map { $0.name }, selectedIndex: selectedProjectIndex) { [weak self] index in
            self?.selectedProjectIndex = index
        }
        form.addColumns([taskCard, projectCard])

        form.addSection("Notes")
        notesView.string = editing?.notes ?? ""
        form.addRow(notesView)

        form.setFooter(target: self,
                       confirmTitle: editing == nil ? "Create Follow-up" : "Save",
                       confirm: #selector(save),
                       cancel: #selector(cancel))

        form.refreshTheme()
        form.sizeToFitContent()
    }

    /// The date picker inside the scaffold's own label-over-control wrapper,
    /// so it sits on the same rhythm as the Priority card beside it.
    private func labelledDatePicker(_ form: HelmFormSheet) -> NSView {
        followUpDatePicker.heightAnchor.constraint(equalToConstant: HelmField.controlHeight).isActive = true
        return form.labelledField("Follow up", followUpDatePicker)
    }

    private func applyExtraTheme(_ theme: HelmTheme) {
        updatePriorityDot(theme)
    }

    private func updatePriorityDot(_ theme: HelmTheme) {
        let tint: HelmTint
        switch selectedPriority {
        case .high: tint = .critical
        case .normal: tint = .info
        case .low: tint = .neutral
        }
        priorityDot.setColor(HelmTheme.nsColor(tint.hex(in: theme)))
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(titleField)
    }

    @objc private func save() {
        let titleText = titleField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !titleText.isEmpty else {
            view.window?.makeFirstResponder(titleField)
            NSSound.beep()
            return
        }
        var followUp = editing ?? ShiftFollowUp.fresh()
        followUp.title = titleText
        followUp.priority = selectedPriority
        let (dateStr, timeStr) = ShiftDateFormatting.components(from: followUpDatePicker.dateValue)
        followUp.followUpAt = dateStr
        followUp.followUpTime = timeStr
        followUp.relatedTaskID = taskIDs.indices.contains(selectedTaskIndex) ? taskIDs[selectedTaskIndex] : nil
        followUp.projectID = projectIDs.indices.contains(selectedProjectIndex) ? projectIDs[selectedProjectIndex] : nil
        let notes = notesView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        followUp.notes = notes.isEmpty ? nil : notes
        onSave?(followUp)
        dismiss(self)
    }

    @objc private func cancel() {
        dismiss(self)
    }
}
