// Manjesh Grand Line - native macOS app.
//
// New/Edit/Duplicate command sheet for the DevOps Command Library
// (fm/grandline-devops-command-library-phase2 - see AGENTS.md's "Shift"
// section and the design doc's phasing table). "Add Command" and "Duplicate"
// both open this same sheet with `editingID == nil` (a duplicate is pre-filled
// from the original command but always saves as a brand-new command, never
// overwrites it - see `CommandLibraryPageView.duplicateClicked`).
//
// Phase 6 of the full-app UI audit moved it onto the shared form scaffold
// (`HelmForm.swift`) - a scrolling one, since this is the longest of the six
// forms. Category and Risk became `HelmFieldCard`s like every other enum-like
// choice in the app; the `NSGridView` label column is gone.
//
// Parameters stay a small list of rows built fresh on every add/remove
// (`addParameterRow`) - this app's usual `NSStackView`-of-permanent-rows
// approach is fine here since a single command's parameter count is always
// tiny, nowhere near the row count that would justify an `NSTableView` (see
// `ShiftProjectDetailView.swift`'s own header for where that line gets
// crossed). Those rows keep `HelmPopUpButton` rather than a `HelmFieldCard`
// for the kind picker: a 50pt card inside a six-control inline row would be
// absurd. Card for a form field, popup for a table cell.

import AppKit

final class CommandEditorController: NSViewController, NSTextFieldDelegate {

    /// `nil` for a brand-new command (including a duplicate, which always
    /// saves as new - see this file's header).
    private let editingID: String?
    private let prefill: DevOpsCommand?
    private let config: CommandLibraryConfig

    /// Called with the fully-assembled field values on Save - the caller
    /// (`CommandLibraryPageView`) owns the store and decides whether to
    /// call `createCommand`/`updateCommand`.
    var onSave: ((_ name: String, _ description: String, _ category: String, _ subcategory: String?, _ commandTemplate: String, _ parameters: [CommandParameter], _ tags: [String], _ risk: CommandRiskLevel) -> Void)?

    private let nameField = HelmTextField(placeholder: "What does this command do?", style: .lead)
    private let descriptionField = HelmTextField(placeholder: "One line about when to reach for it")
    private let categoryCard = HelmFieldCard(label: "Category")
    private let subcategoryField = HelmTextField(placeholder: "Optional")
    private let templateTextView = HelmTextView(height: 90, monospaced: true)
    private let tagsField = HelmTextField(placeholder: "Comma separated")
    private let riskDot = HelmDotAccessory()
    private lazy var riskCard = HelmFieldCard(label: "Risk", accessory: riskDot)

    private var selectedCategoryIndex = 0
    private var selectedRisk: CommandRiskLevel = .readOnly

    private let parametersStack = NSStackView()
    private struct ParameterRow {
        let container: NSView
        let nameField: NSTextField
        let labelField: NSTextField
        let kindPopup: NSPopUpButton
        let requiredCheckbox: NSButton
        let defaultField: NSTextField
        let optionsField: NSTextField
    }
    private var parameterRows: [ParameterRow] = []

    init(editingID: String?, prefill: DevOpsCommand?, config: CommandLibraryConfig) {
        self.editingID = editingID
        self.prefill = prefill
        self.config = config
        self.selectedRisk = prefill?.risk ?? .readOnly
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        // A scrolling sheet, not a window: cap the field column so the sheet
        // itself lands at exactly `HelmFormSheet.width`, the same as its four
        // non-scrolling siblings. (The Host editor caps at the full width
        // instead, because it *is* a resizable window and its own floor is
        // tuned around that - see `AppDelegate.presentHostEditor`.)
        let form = HelmFormSheet(title: editingID == nil ? "New Command" : "Edit Command",
                                 scrolls: true,
                                 maxContentWidth: HelmFormSheet.width - HelmFormSheet.gutter * 2)
        form.setFrameSize(NSSize(width: HelmFormSheet.width, height: 620))
        view = form
        form.onApplyTheme = { [weak self] theme in self?.applyExtraTheme(theme) }

        nameField.stringValue = prefill?.name ?? ""
        form.addLead(nameField)

        form.addSection("Details")
        descriptionField.stringValue = prefill?.description ?? ""
        form.addField("Description", descriptionField)

        let currentCategoryID = prefill?.category ?? CommandLibraryCategory.all[0].id
        selectedCategoryIndex = CommandLibraryCategory.all.firstIndex(where: { $0.id == currentCategoryID }) ?? 0
        categoryCard.configureChoices(CommandLibraryCategory.all.map(\.displayName),
                                      selectedIndex: selectedCategoryIndex) { [weak self] index in
            self?.selectedCategoryIndex = index
        }
        riskCard.configureChoices(CommandRiskLevel.allCases.map(\.displayName),
                                  selectedIndex: CommandRiskLevel.allCases.firstIndex(of: selectedRisk) ?? 0) { [weak self] index in
            guard let self, CommandRiskLevel.allCases.indices.contains(index) else { return }
            self.selectedRisk = CommandRiskLevel.allCases[index]
            self.updateRiskDot(ThemeManager.shared.theme)
        }
        form.addColumns([categoryCard, riskCard])

        subcategoryField.stringValue = prefill?.subcategory ?? ""
        tagsField.stringValue = (prefill?.tags ?? []).joined(separator: ", ")
        form.addFieldColumns([("Subcategory", subcategoryField), ("Tags", tagsField)])

        form.addSection("Command template")
        templateTextView.string = prefill?.commandTemplate ?? ""
        form.addRow(templateTextView)
        form.addCaption("Use {{token}} placeholders for anything the parameters below fill in.")

        form.addSection("Parameters")
        parametersStack.orientation = .vertical
        parametersStack.alignment = .leading
        parametersStack.spacing = HelmMetrics.s2 - 2
        parametersStack.translatesAutoresizingMaskIntoConstraints = false
        for param in prefill?.parameters ?? [] { addParameterRow(prefilled: param) }
        form.addRow(parametersStack)

        let addParamButton = HelmButton(title: "+ Add Parameter", variant: .secondary, target: self, action: #selector(addParameterClicked))
        addParamButton.controlSize = .small
        let addRow = NSStackView(views: [addParamButton, NSView()])
        addRow.orientation = .horizontal
        addRow.distribution = .fill
        addRow.translatesAutoresizingMaskIntoConstraints = false
        addRow.arrangedSubviews[1].setContentHuggingPriority(.defaultLow, for: .horizontal)
        form.addRow(addRow)

        form.setFooter(target: self,
                       confirmTitle: editingID == nil ? "Create Command" : "Save",
                       confirm: #selector(saveClicked),
                       cancel: #selector(cancelClicked))

        form.refreshTheme()
    }

    private func applyExtraTheme(_ theme: HelmTheme) {
        updateRiskDot(theme)
    }

    private func updateRiskDot(_ theme: HelmTheme) {
        let tint: HelmTint
        switch selectedRisk {
        case .readOnly: tint = .good
        case .potentiallyDisruptive: tint = .warn
        case .destructive: tint = .critical
        }
        riskDot.setColor(HelmTheme.nsColor(tint.hex(in: theme)))
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(nameField)
    }

    // MARK: Parameter rows

    @objc private func addParameterClicked() { addParameterRow(prefilled: nil) }

    private func addParameterRow(prefilled param: CommandParameter?) {
        let nameField = HelmTextField(placeholder: "param_name")
        nameField.stringValue = param?.name ?? ""

        let labelField = HelmTextField(placeholder: "Label")
        labelField.stringValue = param?.label ?? ""

        let kindPopup = HelmPopUpButton()
        kindPopup.translatesAutoresizingMaskIntoConstraints = false
        for kind in CommandParameterKind.allCases { kindPopup.addItem(withTitle: kind.rawValue) }
        kindPopup.selectItem(at: CommandParameterKind.allCases.firstIndex(of: param?.kind ?? .string) ?? 0)

        let requiredCheckbox = NSButton(checkboxWithTitle: "Req", target: nil, action: nil)
        requiredCheckbox.state = (param?.required ?? true) ? .on : .off
        requiredCheckbox.translatesAutoresizingMaskIntoConstraints = false

        let defaultField = HelmTextField(placeholder: "Default")
        defaultField.stringValue = param?.defaultValue ?? ""

        let optionsField = HelmTextField(placeholder: "Options, comma separated")
        optionsField.stringValue = (param?.options ?? []).joined(separator: ", ")

        let removeButton = HelmButton(title: "\u{2715}", variant: .quiet, target: self, action: #selector(removeParameterClicked(_:)))
        removeButton.controlSize = .small
        removeButton.translatesAutoresizingMaskIntoConstraints = false

        let row = NSStackView(views: [nameField, labelField, kindPopup, requiredCheckbox, defaultField, optionsField, removeButton])
        row.orientation = .horizontal
        row.spacing = HelmMetrics.s2 - 2
        row.alignment = .centerY
        row.distribution = .fill
        row.translatesAutoresizingMaskIntoConstraints = false
        nameField.widthAnchor.constraint(equalToConstant: 84).isActive = true
        labelField.widthAnchor.constraint(equalToConstant: 72).isActive = true
        kindPopup.widthAnchor.constraint(equalToConstant: 84).isActive = true
        defaultField.widthAnchor.constraint(equalToConstant: 62).isActive = true
        optionsField.setContentHuggingPriority(.defaultLow, for: .horizontal)

        parametersStack.addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: parametersStack.widthAnchor).isActive = true
        removeButton.tag = parameterRows.count
        parameterRows.append(ParameterRow(
            container: row, nameField: nameField, labelField: labelField, kindPopup: kindPopup,
            requiredCheckbox: requiredCheckbox, defaultField: defaultField, optionsField: optionsField
        ))
    }

    @objc private func removeParameterClicked(_ sender: NSButton) {
        guard let index = parameterRows.firstIndex(where: { $0.container === sender.superview }) else { return }
        parametersStack.removeArrangedSubview(parameterRows[index].container)
        parameterRows[index].container.removeFromSuperview()
        parameterRows.remove(at: index)
    }

    // MARK: Save

    @objc private func saveClicked() {
        let name = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            view.window?.makeFirstResponder(nameField)
            NSSound.beep()
            return
        }
        let categoryID = CommandLibraryCategory.all[selectedCategoryIndex].id
        let subcategory = subcategoryField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let template = templateTextView.string
        let tags = tagsField.stringValue.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let parameters: [CommandParameter] = parameterRows.compactMap { row in
            let paramName = row.nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !paramName.isEmpty else { return nil }
            let label = row.labelField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let defaultValue = row.defaultField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let options = row.optionsField.stringValue.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            return CommandParameter(
                name: paramName,
                label: label.isEmpty ? paramName : label,
                kind: CommandParameterKind.allCases[row.kindPopup.indexOfSelectedItem],
                required: row.requiredCheckbox.state == .on,
                defaultValue: defaultValue.isEmpty ? nil : defaultValue,
                options: options
            )
        }
        onSave?(name, descriptionField.stringValue, categoryID, subcategory.isEmpty ? nil : subcategory, template, parameters, tags, selectedRisk)
        dismiss(self)
    }

    @objc private func cancelClicked() { dismiss(self) }
}
