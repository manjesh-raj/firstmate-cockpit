// Manjesh Grand Line - native macOS app.
//
// New/Edit Task sheet (cockpit-shift-create-edit, phase 2 of Shift - see
// AGENTS.md's "Shift" section), redesigned by fm/grandline-task-editor-redesign
// against a captain-supplied HTML/CSS mockup, and moved onto the shared form
// scaffold by Phase 6 of the full-app UI audit.
//
// **This sheet is where the app's form language came from.** The big
// placeholder-styled title field, the uppercase section kickers, the clickable
// field cards for Priority/Project, the `NSSwitch`-backed due-date card, the
// sunken tag/description fields and the ⌘⏎ footer were all built here first;
// §6.4 of the audit asks for exactly that language to become the default across
// all six editors. Phase 6 promoted every one of those shapes into
// `HelmForm.swift` (`HelmFormSheet`, `HelmFieldCard`, `HelmToggleRow`,
// `HelmTextField`, `HelmTextView`, `HelmDotAccessory`) so the other five sheets
// share them rather than copy them - which means this file now *reads* almost
// entirely as behaviour: date detection, tag chips, the attachment well, and
// what Save writes. None of that behaviour changed.
//
// Three things the scaffold took over that were bugs or near-bugs here:
//
// 1. `shiftEditorFieldFillColor` was one of the three byte-identical copies of
//    the sunken-field fill the audit counted (§3.2). It is now
//    `HelmField.fill`, and this file has no colour derivation of its own left.
// 2. The `sectionLabels` re-tint used to miss its first firing, because
//    `ThemeManager.observe` fires synchronously at registration - before the
//    `sectionLabel(...)` calls further down `loadView` had appended anything -
//    so the four kickers rendered in the system `.labelColor`, *brighter* than
//    the body text they label (audit §5.1). `HelmFormSheet.refreshTheme()` is
//    the general form of the one-line fix, called at the end of every editor's
//    `loadView`.
// 3. `resizeToFitContent()` - `presentAsSheet` reads the root view's frame
//    verbatim, so a hardcoded height leaves slack that `.gravityAreas` injects
//    into an arbitrary row (fm/grandline-task-editor-layout-fix). That is
//    `HelmFormSheet.sizeToFitContent()` now, and all four non-scrolling sheets
//    get it rather than just this one.
//
// The mockup's Attachments drag-and-drop section is deliberately NOT part of
// this - that is a different (already-shipped) attachment mechanism in this
// app; these passes restructure presentation, not the attachment model.

import AppKit
import UniformTypeIdentifiers

final class ShiftTaskEditorController: NSViewController, NSTextFieldDelegate {

    private let editing: ShiftTask?
    private let projects: [ShiftProject]
    /// Pre-selects the Project card for a brand-new task opened from inside
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

    private var form: HelmFormSheet!

    private let attachmentWell = ShiftImageAttachmentWell()
    private let chooseImageButton = HelmButton(title: "Choose Image\u{2026}", variant: .secondary, target: nil, action: nil)
    /// `nil` until the captain interacts with the well in this session -
    /// `.unchanged` is reported on Save if this stays `nil`, so an ordinary
    /// edit that never touches the attachment never rewrites the image file.
    private var attachmentChange: ShiftAttachmentChange?

    private let titleField = HelmTextField(placeholder: "What needs to be done?", style: .lead)
    private var hintLabel: NSTextField?
    private let detectedRow = NSStackView()
    private let detectedIcon = NSImageView(image: NSImage(systemSymbolName: "calendar.badge.checkmark", accessibilityDescription: nil) ?? NSImage())
    private let detectedLabel = NSTextField(labelWithString: "")

    private var selectedPriority: ShiftPriority
    private let priorityDot = HelmDotAccessory()
    private lazy var priorityCard = HelmFieldCard(label: "Priority", accessory: priorityDot)

    private var selectedProjectID: String?
    private let projectIconTile = IconTileView(size: 22, cornerRadius: HelmMetrics.rChip)
    private lazy var projectCard = HelmFieldCard(label: "Project", accessory: projectIconTile)

    private let dueDatePicker = HelmDatePicker()
    private lazy var dueRow = HelmToggleRow(title: "Set due date",
                                            subtitle: "Add a date and optional time",
                                            trailing: dueDatePicker)

    private let tagsField = HelmTextField(placeholder: "Add tags, separated by commas")
    private let tagsChipsFlow = ChipFlowView()
    private var tagChips: [String] = []

    private let descriptionView = HelmTextView(height: 110)

    /// Once the person edits the due-date controls directly (switch or
    /// picker), further title edits stop overwriting their choice - only a
    /// brand-new detected phrase should ever clobber a still-untouched Due
    /// field, never a deliberate manual edit.
    private var dueManuallyEdited = false

    init(task: ShiftTask?, projects: [ShiftProject], defaultProjectID: String? = nil, existingAttachmentData: Data? = nil) {
        self.editing = task
        self.projects = projects
        self.defaultProjectID = defaultProjectID
        self.existingAttachmentData = existingAttachmentData
        self.selectedPriority = task?.priority ?? .normal
        let candidateProjectID = task?.projectID ?? defaultProjectID
        self.selectedProjectID = projects.contains { $0.id == candidateProjectID } ? candidateProjectID : nil
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        let form = HelmFormSheet(title: editing == nil ? "New Task" : "Edit Task")
        self.form = form
        view = form
        form.onApplyTheme = { [weak self] theme in self?.applyExtraTheme(theme) }

        // MARK: Title + natural-language date hint

        titleField.stringValue = editing?.title ?? ""
        titleField.delegate = self
        form.addLead(titleField)
        hintLabel = form.addLeadHint(hintAttributedString(muted: .labelColor, emphasis: .labelColor))

        let clearDetected = HelmButton(symbol: "xmark.circle.fill", variant: .quiet, size: .small,
                                       target: self, action: #selector(dismissDetected))
        detectedLabel.font = HelmType.caption()
        detectedRow.addArrangedSubview(detectedIcon)
        detectedRow.addArrangedSubview(detectedLabel)
        detectedRow.addArrangedSubview(clearDetected)
        detectedRow.orientation = .horizontal
        detectedRow.spacing = HelmMetrics.s2 - 2
        detectedRow.alignment = .centerY
        detectedRow.isHidden = true
        form.addRow(detectedRow)

        // MARK: Details - Priority / Project field cards

        form.addSection("Details")
        priorityCard.onClick = { [weak self] in self?.priorityCardClicked() }
        projectIconTile.configure(symbol: "folder.fill", tint: .info, pointSize: 11)
        projectCard.onClick = { [weak self] in self?.projectCardClicked() }
        updatePriorityCard()
        updateProjectCard()
        form.addColumns([priorityCard, projectCard])

        // MARK: Due date

        dueDatePicker.target = self
        dueDatePicker.action = #selector(dueDatePickerChanged)
        let existingDue = ShiftDateFormatting.dateTime(from: editing?.dueDate, time: editing?.dueTime)
        if let existingDue {
            dueRow.isOn = true
            dueDatePicker.dateValue = existingDue
            dueDatePicker.isEnabled = true
        } else {
            dueRow.isOn = false
            dueDatePicker.dateValue = Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: Date()) ?? Date()
            dueDatePicker.isEnabled = false
        }
        dueDatePicker.isHidden = !dueRow.isOn
        dueRow.onToggle = { [weak self] in self?.hasDueToggled() }
        form.addRow(dueRow)

        // MARK: Tags

        form.addSection("Tags")
        tagsField.delegate = self
        form.addRow(tagsField)
        form.setSpacingAfterLastRow(HelmMetrics.s2)
        form.addRow(tagsChipsFlow)
        tagChips = editing?.tags ?? []
        renderTagChips()

        // MARK: Description

        form.addSection("Description")
        descriptionView.string = editing?.description ?? ""
        form.addRow(descriptionView)

        // MARK: Attachment (existing feature, unchanged)

        chooseImageButton.target = self
        chooseImageButton.action = #selector(chooseImageClicked)
        chooseImageButton.controlSize = .small
        form.addSection("Attachment", actions: [chooseImageButton])
        attachmentWell.onImageChosen = { [weak self] data in self?.attachmentChange = .set(data) }
        attachmentWell.onRemove = { [weak self] in self?.attachmentChange = .removed }
        if let existingAttachmentData {
            attachmentWell.showExisting(data: existingAttachmentData)
        }
        form.addRow(attachmentWell)

        // MARK: Footer

        form.setFooter(target: self,
                       confirmTitle: editing == nil ? "Create Task" : "Save",
                       confirm: #selector(save),
                       cancel: #selector(cancel),
                       // ⌘Return rather than a plain Return, because this
                       // sheet's multi-line Description field consumes Return
                       // as a newline. `performKeyEquivalent:` reaches the
                       // button regardless of first responder.
                       confirmModifiers: [.command],
                       hint: "\u{2318}\u{23ce} to save")

        form.refreshTheme()
        form.sizeToFitContent()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(titleField)
    }

    // MARK: Theming

    /// Everything the scaffold does not own: this sheet's own hint line,
    /// detected-date row, priority dot, tag chips and attachment well.
    private func applyExtraTheme(_ theme: HelmTheme) {
        let ink = HelmTheme.nsColor(theme.chromeInkHex)
        let muted = HelmTheme.mutedInk(theme)
        hintLabel?.attributedStringValue = hintAttributedString(muted: muted, emphasis: ink)
        detectedIcon.contentTintColor = HelmTheme.nsColor(theme.accentHex)
        detectedLabel.textColor = muted
        updatePriorityDotColor(theme: theme)
        tagsChipsFlow.subviews.compactMap { $0 as? VocabularyChipView }.forEach { $0.applyTheme(theme) }
        attachmentWell.applyTheme(theme)
    }

    private func hintAttributedString(muted: NSColor, emphasis: NSColor) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let base: [NSAttributedString.Key: Any] = [.font: HelmType.caption(), .foregroundColor: muted]
        let bold: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11.5, weight: .semibold), .foregroundColor: emphasis]
        result.append(NSAttributedString(string: "Tip: type natural dates like ", attributes: base))
        result.append(NSAttributedString(string: "tomorrow 3pm", attributes: bold))
        result.append(NSAttributedString(string: " or ", attributes: base))
        result.append(NSAttributedString(string: "next Monday", attributes: bold))
        result.append(NSAttributedString(string: ".", attributes: base))
        return result
    }

    // MARK: Priority / Project field cards

    private func priorityTint(_ priority: ShiftPriority) -> HelmTint {
        switch priority {
        case .high: return .critical
        case .normal: return .info
        case .low: return .neutral
        }
    }

    private func updatePriorityDotColor(theme: HelmTheme) {
        priorityDot.setColor(HelmTheme.nsColor(priorityTint(selectedPriority).hex(in: theme)))
    }

    private func updatePriorityCard() {
        priorityCard.value = selectedPriority.rawValue.capitalized
        updatePriorityDotColor(theme: ThemeManager.shared.theme)
    }

    private func updateProjectCard() {
        projectCard.value = projects.first(where: { $0.id == selectedProjectID })?.name ?? "No project"
    }

    private func priorityCardClicked() {
        let menu = NSMenu()
        for priority in ShiftPriority.allCases {
            let item = NSMenuItem(title: priority.rawValue.capitalized, action: #selector(priorityItemSelected(_:)), keyEquivalent: "")
            item.target = self
            item.state = priority == selectedPriority ? .on : .off
            item.representedObject = priority.rawValue
            menu.addItem(item)
        }
        priorityCard.popMenu(menu)
    }

    @objc private func priorityItemSelected(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let priority = ShiftPriority(rawValue: raw) else { return }
        selectedPriority = priority
        updatePriorityCard()
    }

    private func projectCardClicked() {
        let menu = NSMenu()
        let noneItem = NSMenuItem(title: "No project", action: #selector(projectItemSelected(_:)), keyEquivalent: "")
        noneItem.target = self
        noneItem.state = selectedProjectID == nil ? .on : .off
        menu.addItem(noneItem)
        for project in projects {
            let item = NSMenuItem(title: project.name, action: #selector(projectItemSelected(_:)), keyEquivalent: "")
            item.target = self
            item.state = project.id == selectedProjectID ? .on : .off
            item.representedObject = project.id
            menu.addItem(item)
        }
        projectCard.popMenu(menu)
    }

    @objc private func projectItemSelected(_ sender: NSMenuItem) {
        selectedProjectID = sender.representedObject as? String
        updateProjectCard()
    }

    // MARK: Live date detection

    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSTextField else { return }
        if field === tagsField {
            tagsFieldDidChange()
            return
        }
        guard field === titleField else { return }
        guard !dueManuallyEdited else { return }
        guard let parsed = ShiftDateParser.parse(titleField.stringValue) else {
            let wasHidden = detectedRow.isHidden
            detectedRow.isHidden = true
            if !wasHidden { form.sizeToFitContent() }
            return
        }
        dueRow.isOn = true
        dueDatePicker.isEnabled = true
        dueDatePicker.isHidden = false
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
        let wasHidden = detectedRow.isHidden
        detectedRow.isHidden = false
        if wasHidden { form.sizeToFitContent() }
    }

    @objc private func dismissDetected() {
        let wasHidden = detectedRow.isHidden
        detectedRow.isHidden = true
        dueManuallyEdited = true
        if !wasHidden { form.sizeToFitContent() }
    }

    private func hasDueToggled() {
        dueManuallyEdited = true
        let on = dueRow.isOn
        dueDatePicker.isEnabled = on
        dueDatePicker.isHidden = !on
        detectedRow.isHidden = true
        form.sizeToFitContent()
    }

    @objc private func dueDatePickerChanged() {
        dueManuallyEdited = true
        let wasHidden = detectedRow.isHidden
        detectedRow.isHidden = true
        if !wasHidden { form.sizeToFitContent() }
    }

    // MARK: Tags

    /// A typed trailing comma commits everything before it as a chip and
    /// clears the field, matching the mockup's own tag-entry interaction.
    private func tagsFieldDidChange() {
        let text = tagsField.stringValue
        guard text.hasSuffix(",") else { return }
        let candidate = String(text.dropLast())
        tagsField.stringValue = ""
        commitTagText(candidate)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard control === tagsField, commandSelector == #selector(NSResponder.insertNewline(_:)) else { return false }
        commitTagText(tagsField.stringValue)
        tagsField.stringValue = ""
        return true
    }

    private func commitTagText(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        guard !tagChips.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) else { return }
        tagChips.append(trimmed)
        renderTagChips()
    }

    private func renderTagChips() {
        let theme = ThemeManager.shared.theme
        let chips: [NSView] = tagChips.map { tag in
            let chip = VocabularyChipView(word: tag)
            chip.applyTheme(theme)
            chip.onRemove = { [weak self] in
                self?.tagChips.removeAll { $0 == tag }
                self?.renderTagChips()
            }
            return chip
        }
        tagsChipsFlow.setChips(chips)
        // Needed for every call after the first, once a tag is added/removed
        // while the sheet is already showing - `ChipFlowView`'s wrap-to-width
        // height changes with the chip count. The first call happens from
        // inside `loadView()` before the window exists, and `loadView()`'s own
        // final `sizeToFitContent()` supersedes it.
        form?.sizeToFitContent()
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
        commitTagText(tagsField.stringValue)
        tagsField.stringValue = ""

        var task = editing ?? ShiftTask.fresh()
        task.title = titleText
        task.description = descriptionView.string
        task.priority = selectedPriority
        if dueRow.isOn {
            let (dateStr, timeStr) = ShiftDateFormatting.components(from: dueDatePicker.dateValue)
            task.dueDate = dateStr
            task.dueTime = timeStr
        } else {
            task.dueDate = nil
            task.dueTime = nil
        }
        task.projectID = selectedProjectID
        task.tags = tagChips
        onSave?(task, attachmentChange ?? .unchanged)
        dismiss(self)
    }

    @objc private func cancel() {
        dismiss(self)
    }
}
