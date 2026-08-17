// Manjesh Grand Line - native macOS app.
//
// New/Edit Task sheet (cockpit-shift-create-edit, phase 2 of Shift - see
// AGENTS.md's "Shift" section). Fields per the brief: Title, Priority,
// Due (date+time), Project, Tags, Description. Presented as a sheet on
// `ShiftController` (⌘N / the My Tasks header's "+" button), following
// `SnippetEditorController.swift`'s shape - a plain `NSStackView` form, no
// standalone window, since this list of fields is short enough not to need
// `HostEditorController`'s scroll-and-cap treatment.
//
// The live natural-language date detection lives in `ShiftDateParser.swift`;
// this file only wires the Title field's `controlTextDidChange` to it and
// reflects a match into the Due controls plus a small inline confirmation
// label - see `titleDidChange` below.

import AppKit
import UniformTypeIdentifiers

final class ShiftTaskEditorController: NSViewController, NSTextFieldDelegate {

    private let editing: ShiftTask?
    private let projects: [ShiftProject]
    /// Pre-selects the Project popup for a brand-new task opened from inside
    /// a project's own detail page ("+ Add Task", fm/cockpit-shift-project-
    /// page-redesign) - ignored when editing an existing task, which already
    /// has its own `projectID`.
    private let defaultProjectID: String?
    /// The existing attachment's bytes, if any - fetched by the caller
    /// (`ShiftController`, which owns the store) *before* presenting this
    /// sheet, so this controller never touches `ShiftStore` directly. `nil`
    /// for a brand-new task or one with no attachment.
    private let existingAttachmentData: Data?

    /// Called with the assembled task and the captain's attachment decision
    /// on Save. The caller (`ShiftController`) persists both via
    /// `ShiftStore.addTask`/`updateTask`.
    var onSave: ((ShiftTask, ShiftAttachmentChange) -> Void)?

    private let attachmentWell = ShiftImageAttachmentWell()
    private let chooseImageButton = NSButton(title: "Choose Image\u{2026}", target: nil, action: nil)
    /// `nil` until the captain interacts with the well in this session -
    /// `.unchanged` is reported on Save if this stays `nil`, so an ordinary
    /// edit that never touches the attachment never rewrites the image file.
    private var attachmentChange: ShiftAttachmentChange?

    private let titleField = NSTextField()
    private let detectedRow = NSStackView()
    private let detectedLabel = NSTextField(labelWithString: "")
    private let priorityPopup = NSPopUpButton()
    private let hasDueCheckbox = NSButton(checkboxWithTitle: "Has due date", target: nil, action: nil)
    private let dueDatePicker = NSDatePicker()
    private let projectPopup = NSPopUpButton()
    private let tagsField = NSTextField()
    private let descriptionView = NSTextView()

    /// Once the person edits the due-date controls directly (checkbox or
    /// picker), further title edits stop overwriting their choice - only a
    /// brand-new detected phrase should ever clobber a still-untouched Due
    /// field, never a deliberate manual edit.
    private var dueManuallyEdited = false

    /// index 0 is always "None"; index n+1 is `projects[n]`.
    private var projectIDs: [String?] = []

    init(task: ShiftTask?, projects: [ShiftProject], defaultProjectID: String? = nil, existingAttachmentData: Data? = nil) {
        self.editing = task
        self.projects = projects
        self.defaultProjectID = defaultProjectID
        self.existingAttachmentData = existingAttachmentData
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 460, height: 660))
        view = root
        ThemeManager.shared.observe { [weak root, weak attachmentWell] theme in
            root?.appearance = NSAppearance(named: theme.mode == .dark ? .darkAqua : .aqua)
            attachmentWell?.applyTheme(theme)
        }

        let title = NSTextField(labelWithString: editing == nil ? "New Task" : "Edit Task")
        title.font = .systemFont(ofSize: 15, weight: .semibold)

        titleField.placeholderString = "Title (try \u{201c}tomorrow 3pm\u{201d} or \u{201c}next mon\u{201d})"
        titleField.stringValue = editing?.title ?? ""
        titleField.translatesAutoresizingMaskIntoConstraints = false
        titleField.delegate = self

        detectedLabel.font = .systemFont(ofSize: 11)
        detectedLabel.textColor = .secondaryLabelColor
        let clearDetected = NSButton(title: "", target: self, action: #selector(dismissDetected))
        clearDetected.isBordered = false
        clearDetected.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Dismiss")
        clearDetected.imageScaling = .scaleProportionallyDown
        clearDetected.translatesAutoresizingMaskIntoConstraints = false
        detectedRow.addArrangedSubview(NSImageView(image: NSImage(systemSymbolName: "calendar.badge.checkmark", accessibilityDescription: nil) ?? NSImage()))
        detectedRow.addArrangedSubview(detectedLabel)
        detectedRow.addArrangedSubview(clearDetected)
        detectedRow.orientation = .horizontal
        detectedRow.spacing = 6
        detectedRow.alignment = .centerY
        detectedRow.translatesAutoresizingMaskIntoConstraints = false
        detectedRow.isHidden = true

        priorityPopup.translatesAutoresizingMaskIntoConstraints = false
        for p in ShiftPriority.allCases { priorityPopup.addItem(withTitle: p.rawValue.capitalized) }
        priorityPopup.selectItem(at: ShiftPriority.allCases.firstIndex(of: editing?.priority ?? .normal) ?? 1)

        hasDueCheckbox.target = self
        hasDueCheckbox.action = #selector(hasDueToggled)
        hasDueCheckbox.translatesAutoresizingMaskIntoConstraints = false

        dueDatePicker.datePickerStyle = .textFieldAndStepper
        dueDatePicker.datePickerElements = [.yearMonthDay, .hourMinute]
        dueDatePicker.target = self
        dueDatePicker.action = #selector(dueDatePickerChanged)
        dueDatePicker.translatesAutoresizingMaskIntoConstraints = false

        let existingDue = ShiftDateFormatting.dateTime(from: editing?.dueDate, time: editing?.dueTime)
        if let existingDue {
            hasDueCheckbox.state = .on
            dueDatePicker.dateValue = existingDue
            dueDatePicker.isEnabled = true
        } else {
            hasDueCheckbox.state = .off
            dueDatePicker.dateValue = Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: Date()) ?? Date()
            dueDatePicker.isEnabled = false
        }

        let dueRow = NSStackView(views: [hasDueCheckbox, dueDatePicker])
        dueRow.orientation = .horizontal
        dueRow.spacing = 10
        dueRow.alignment = .centerY
        dueRow.translatesAutoresizingMaskIntoConstraints = false

        projectPopup.translatesAutoresizingMaskIntoConstraints = false
        projectIDs = [nil] + projects.map { $0.id }
        projectPopup.addItem(withTitle: "None")
        for p in projects { projectPopup.addItem(withTitle: p.name) }
        if let pid = editing?.projectID ?? defaultProjectID, let idx = projectIDs.firstIndex(of: pid) {
            projectPopup.selectItem(at: idx)
        } else {
            projectPopup.selectItem(at: 0)
        }

        tagsField.placeholderString = "Tags, comma separated"
        tagsField.stringValue = (editing?.tags ?? []).joined(separator: ", ")
        tagsField.translatesAutoresizingMaskIntoConstraints = false

        descriptionView.string = editing?.description ?? ""
        descriptionView.font = .systemFont(ofSize: 12)
        descriptionView.isRichText = false
        descriptionView.textContainerInset = NSSize(width: 6, height: 6)
        let descScroll = NSScrollView()
        descScroll.borderType = .bezelBorder
        descScroll.hasVerticalScroller = true
        descScroll.documentView = descriptionView
        descScroll.translatesAutoresizingMaskIntoConstraints = false

        let grid = NSGridView(views: [
            [rowLabel("Priority"), priorityPopup],
            [rowLabel("Due"), dueRow],
            [rowLabel("Project"), projectPopup],
            [rowLabel("Tags"), tagsField],
        ])
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.rowSpacing = 12
        grid.columnSpacing = 12
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 0).width = 90
        grid.column(at: 1).xPlacement = .fill

        let descLabel = rowLabel("Description")

        let attachmentLabel = rowLabel("Attachment")
        attachmentWell.translatesAutoresizingMaskIntoConstraints = false
        attachmentWell.onImageChosen = { [weak self] data in self?.attachmentChange = .set(data) }
        attachmentWell.onRemove = { [weak self] in self?.attachmentChange = .removed }
        if let existingAttachmentData {
            attachmentWell.showExisting(data: existingAttachmentData)
        }
        chooseImageButton.target = self
        chooseImageButton.action = #selector(chooseImageClicked)
        chooseImageButton.bezelStyle = .rounded
        chooseImageButton.controlSize = .small
        let attachmentRowSpacer = NSView()
        attachmentRowSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let attachmentRow = NSStackView(views: [attachmentLabel, attachmentRowSpacer, chooseImageButton])
        attachmentRow.orientation = .horizontal
        attachmentRow.distribution = .fill
        attachmentRow.translatesAutoresizingMaskIntoConstraints = false

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

        let stack = NSStackView(views: [
            title, titleField, detectedRow, grid, descLabel, descScroll,
            attachmentRow, attachmentWell, bottom,
        ])
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
            detectedRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            grid.widthAnchor.constraint(equalTo: stack.widthAnchor),
            descScroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            descScroll.heightAnchor.constraint(equalToConstant: 100),
            attachmentRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            attachmentWell.widthAnchor.constraint(equalTo: stack.widthAnchor),
            bottom.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(titleField)
    }

    // MARK: Live date detection

    func controlTextDidChange(_ notification: Notification) {
        guard notification.object as? NSTextField === titleField else { return }
        guard !dueManuallyEdited else { return }
        guard let parsed = ShiftDateParser.parse(titleField.stringValue) else {
            detectedRow.isHidden = true
            return
        }
        hasDueCheckbox.state = .on
        dueDatePicker.isEnabled = true
        if parsed.hasTime {
            dueDatePicker.dateValue = parsed.date
        } else {
            // Keep whatever time-of-day is already in the picker (default
            // 9:00 AM) - a date-only phrase like "next mon" shouldn't
            // silently zero out the time to midnight.
            let existingTime = Calendar.current.dateComponents([.hour, .minute], from: dueDatePicker.dateValue)
            var comps = Calendar.current.dateComponents([.year, .month, .day], from: parsed.date)
            comps.hour = existingTime.hour
            comps.minute = existingTime.minute
            dueDatePicker.dateValue = Calendar.current.date(from: comps) ?? parsed.date
        }
        let (dateStr, timeStr) = ShiftDateFormatting.components(from: dueDatePicker.dateValue)
        detectedLabel.stringValue = "Detected: \(ShiftDateFormatting.friendly(dateStr, time: parsed.hasTime ? timeStr : nil))"
        detectedRow.isHidden = false
    }

    @objc private func dismissDetected() {
        detectedRow.isHidden = true
        dueManuallyEdited = true
    }

    @objc private func hasDueToggled() {
        dueManuallyEdited = true
        dueDatePicker.isEnabled = hasDueCheckbox.state == .on
        detectedRow.isHidden = true
    }

    @objc private func dueDatePickerChanged() {
        dueManuallyEdited = true
        detectedRow.isHidden = true
    }

    // MARK: Attachment

    @objc private func chooseImageClicked() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.image]
        guard let window = view.window else { return }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url, let image = NSImage(contentsOf: url) else { return }
            self?.attachmentWell.handle(image: image)
        }
    }

    // MARK: Save

    @objc private func save() {
        let titleText = titleField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !titleText.isEmpty else {
            view.window?.makeFirstResponder(titleField)
            NSSound.beep()
            return
        }
        var task = editing ?? ShiftTask.fresh()
        task.title = titleText
        task.description = descriptionView.string
        task.priority = ShiftPriority.allCases[priorityPopup.indexOfSelectedItem]
        if hasDueCheckbox.state == .on {
            let (dateStr, timeStr) = ShiftDateFormatting.components(from: dueDatePicker.dateValue)
            task.dueDate = dateStr
            task.dueTime = timeStr
        } else {
            task.dueDate = nil
            task.dueTime = nil
        }
        task.projectID = projectIDs[projectPopup.indexOfSelectedItem]
        task.tags = tagsField.stringValue
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        onSave?(task, attachmentChange ?? .unchanged)
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
