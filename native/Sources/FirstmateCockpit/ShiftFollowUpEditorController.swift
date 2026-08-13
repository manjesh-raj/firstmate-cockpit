// Manjesh Grand Line - native macOS app.
//
// New/Edit Follow-up sheet (cockpit-shift-create-edit, phase 2 of Shift).
// Fields per the brief: Title, follow-up date/time, Priority, optional
// Notes, related Task, related Project. Same sheet shape as
// `ShiftTaskEditorController.swift`, just a smaller field set and no
// natural-language date detection (not asked for on this form - that's
// specific to the Task title field per the brief).

import AppKit

final class ShiftFollowUpEditorController: NSViewController {

    private let editing: ShiftFollowUp?
    private let tasks: [ShiftTask]
    private let projects: [ShiftProject]

    /// Called with the assembled follow-up on Save.
    var onSave: ((ShiftFollowUp) -> Void)?

    private let titleField = NSTextField()
    private let followUpDatePicker = NSDatePicker()
    private let priorityPopup = NSPopUpButton()
    private let notesView = NSTextView()
    private let taskPopup = NSPopUpButton()
    private let projectPopup = NSPopUpButton()

    /// index 0 is always "None"; index n+1 is `tasks[n]` / `projects[n]`.
    private var taskIDs: [String?] = []
    private var projectIDs: [String?] = []

    init(followUp: ShiftFollowUp?, tasks: [ShiftTask], projects: [ShiftProject]) {
        self.editing = followUp
        self.tasks = tasks
        self.projects = projects
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 440, height: 420))
        view = root
        ThemeManager.shared.observe { [weak root] theme in
            root?.appearance = NSAppearance(named: theme.mode == .dark ? .darkAqua : .aqua)
        }

        let title = NSTextField(labelWithString: editing == nil ? "New Follow-up" : "Edit Follow-up")
        title.font = .systemFont(ofSize: 15, weight: .semibold)

        titleField.placeholderString = "Title"
        titleField.stringValue = editing?.title ?? ""
        titleField.translatesAutoresizingMaskIntoConstraints = false

        followUpDatePicker.datePickerStyle = .textFieldAndStepper
        followUpDatePicker.datePickerElements = [.yearMonthDay, .hourMinute]
        followUpDatePicker.translatesAutoresizingMaskIntoConstraints = false
        let existing = ShiftDateFormatting.dateTime(from: editing?.followUpAt, time: editing?.followUpTime)
        followUpDatePicker.dateValue = existing
            ?? Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: Date()) ?? Date())
            ?? Date()

        priorityPopup.translatesAutoresizingMaskIntoConstraints = false
        for p in ShiftPriority.allCases { priorityPopup.addItem(withTitle: p.rawValue.capitalized) }
        priorityPopup.selectItem(at: ShiftPriority.allCases.firstIndex(of: editing?.priority ?? .normal) ?? 1)

        taskPopup.translatesAutoresizingMaskIntoConstraints = false
        taskIDs = [nil] + tasks.map { $0.id }
        taskPopup.addItem(withTitle: "None")
        for t in tasks { taskPopup.addItem(withTitle: t.title) }
        if let tid = editing?.relatedTaskID, let idx = taskIDs.firstIndex(of: tid) {
            taskPopup.selectItem(at: idx)
        } else {
            taskPopup.selectItem(at: 0)
        }

        projectPopup.translatesAutoresizingMaskIntoConstraints = false
        projectIDs = [nil] + projects.map { $0.id }
        projectPopup.addItem(withTitle: "None")
        for p in projects { projectPopup.addItem(withTitle: p.name) }
        if let pid = editing?.projectID, let idx = projectIDs.firstIndex(of: pid) {
            projectPopup.selectItem(at: idx)
        } else {
            projectPopup.selectItem(at: 0)
        }

        notesView.string = editing?.notes ?? ""
        notesView.font = .systemFont(ofSize: 12)
        notesView.isRichText = false
        notesView.textContainerInset = NSSize(width: 6, height: 6)
        let notesScroll = NSScrollView()
        notesScroll.borderType = .bezelBorder
        notesScroll.hasVerticalScroller = true
        notesScroll.documentView = notesView
        notesScroll.translatesAutoresizingMaskIntoConstraints = false

        let grid = NSGridView(views: [
            [rowLabel("Follow up"), followUpDatePicker],
            [rowLabel("Priority"), priorityPopup],
            [rowLabel("Task"), taskPopup],
            [rowLabel("Project"), projectPopup],
        ])
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.rowSpacing = 12
        grid.columnSpacing = 12
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 0).width = 90
        grid.column(at: 1).xPlacement = .fill

        let notesLabel = rowLabel("Notes")

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

        let stack = NSStackView(views: [title, titleField, grid, notesLabel, notesScroll, bottom])
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
            titleField.widthAnchor.constraint(equalTo: stack.widthAnchor),
            grid.widthAnchor.constraint(equalTo: stack.widthAnchor),
            notesScroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            notesScroll.heightAnchor.constraint(equalToConstant: 90),
            bottom.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
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
        followUp.priority = ShiftPriority.allCases[priorityPopup.indexOfSelectedItem]
        let (dateStr, timeStr) = ShiftDateFormatting.components(from: followUpDatePicker.dateValue)
        followUp.followUpAt = dateStr
        followUp.followUpTime = timeStr
        followUp.relatedTaskID = taskIDs[taskPopup.indexOfSelectedItem]
        followUp.projectID = projectIDs[projectPopup.indexOfSelectedItem]
        let notes = notesView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        followUp.notes = notes.isEmpty ? nil : notes
        onSave?(followUp)
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
