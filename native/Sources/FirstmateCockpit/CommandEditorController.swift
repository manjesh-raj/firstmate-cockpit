// Manjesh Grand Line - native macOS app.
//
// New/Edit/Duplicate command sheet for the DevOps Command Library
// (fm/grandline-devops-command-library-phase2 - see AGENTS.md's "Shift"
// section and the design doc's phasing table). Follows
// `ShiftTaskEditorController.swift`'s shape exactly: a plain `NSStackView`
// form presented via `presentAsSheet` on `ShiftController` - no standalone
// window, since the field list is short. "Add Command" and "Duplicate" both
// open this same sheet with `editingID == nil` (a duplicate is pre-filled
// from the original command but always saves as a brand-new command, never
// overwrites it - see `CommandLibraryPageView.duplicateClicked`).
//
// Parameters are edited as a small list of rows built fresh on every
// add/remove (`rebuildParameterRows`) - this app's usual `NSStackView`-of-
// permanent-rows approach is fine here since a single command's parameter
// count is always tiny (a handful at most), nowhere near the row count that
// would justify an `NSTableView` (see `ShiftProjectDetailView.swift`'s own
// header for where that line gets crossed).

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

    private let nameField = NSTextField()
    private let descriptionField = NSTextField()
    private let categoryPopup = NSPopUpButton()
    private let subcategoryField = NSTextField()
    private let templateTextView = NSTextView()
    private let tagsField = NSTextField()
    private let riskPopup = NSPopUpButton()

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
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 520, height: 620))
        view = root
        ThemeManager.shared.observe { [weak root] theme in
            root?.appearance = NSAppearance(named: theme.mode == .dark ? .darkAqua : .aqua)
        }

        let titleLabel = NSTextField(labelWithString: editingID == nil ? "New Command" : "Edit Command")
        titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)

        nameField.placeholderString = "Name"
        nameField.stringValue = prefill?.name ?? ""
        nameField.translatesAutoresizingMaskIntoConstraints = false

        descriptionField.placeholderString = "Description"
        descriptionField.stringValue = prefill?.description ?? ""
        descriptionField.translatesAutoresizingMaskIntoConstraints = false

        categoryPopup.translatesAutoresizingMaskIntoConstraints = false
        for info in CommandLibraryCategory.all { categoryPopup.addItem(withTitle: info.displayName) }
        let currentCategoryID = prefill?.category ?? CommandLibraryCategory.all[0].id
        if let idx = CommandLibraryCategory.all.firstIndex(where: { $0.id == currentCategoryID }) {
            categoryPopup.selectItem(at: idx)
        }

        subcategoryField.placeholderString = "Subcategory (optional)"
        subcategoryField.stringValue = prefill?.subcategory ?? ""
        subcategoryField.translatesAutoresizingMaskIntoConstraints = false

        templateTextView.string = prefill?.commandTemplate ?? ""
        templateTextView.font = ShiftFont.mono(12)
        templateTextView.isRichText = false
        templateTextView.textContainerInset = NSSize(width: 6, height: 6)
        let templateScroll = NSScrollView()
        templateScroll.borderType = .bezelBorder
        templateScroll.hasVerticalScroller = true
        templateScroll.documentView = templateTextView
        templateScroll.translatesAutoresizingMaskIntoConstraints = false

        tagsField.placeholderString = "Tags, comma separated"
        tagsField.stringValue = (prefill?.tags ?? []).joined(separator: ", ")
        tagsField.translatesAutoresizingMaskIntoConstraints = false

        riskPopup.translatesAutoresizingMaskIntoConstraints = false
        for level in CommandRiskLevel.allCases { riskPopup.addItem(withTitle: level.displayName) }
        riskPopup.selectItem(at: CommandRiskLevel.allCases.firstIndex(of: prefill?.risk ?? .readOnly) ?? 0)

        let grid = NSGridView(views: [
            [rowLabel("Category"), categoryPopup],
            [rowLabel("Subcategory"), subcategoryField],
            [rowLabel("Tags"), tagsField],
            [rowLabel("Risk"), riskPopup],
        ])
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.rowSpacing = 12
        grid.columnSpacing = 12
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 0).width = 90
        grid.column(at: 1).xPlacement = .fill

        let templateLabel = rowLabel("Command Template ({{token}} placeholders)")

        parametersStack.orientation = .vertical
        parametersStack.alignment = .leading
        parametersStack.spacing = 6
        parametersStack.translatesAutoresizingMaskIntoConstraints = false
        for param in prefill?.parameters ?? [] { addParameterRow(prefilled: param) }

        let addParamButton = NSButton(title: "+ Add Parameter", target: self, action: #selector(addParameterClicked))
        addParamButton.bezelStyle = .rounded
        addParamButton.controlSize = .small

        let paramsHeader = NSTextField(labelWithString: "Parameters")
        paramsHeader.font = .systemFont(ofSize: 12)
        paramsHeader.textColor = HelmTheme.mutedInk(ThemeManager.shared.theme)

        let cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancelClicked))
        cancelButton.bezelStyle = .rounded
        cancelButton.keyEquivalent = "\u{1b}"
        let saveButton = NSButton(title: "Save", target: self, action: #selector(saveClicked))
        saveButton.bezelStyle = .rounded
        saveButton.keyEquivalent = "\r"
        let bottomSpacer = NSView()
        bottomSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let bottomRow = NSStackView(views: [bottomSpacer, cancelButton, saveButton])
        bottomRow.orientation = .horizontal
        bottomRow.spacing = 10
        bottomRow.translatesAutoresizingMaskIntoConstraints = false

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let content = FlippedView()
        content.translatesAutoresizingMaskIntoConstraints = false
        let stack = NSStackView(views: [
            nameField, descriptionField, grid, templateLabel, templateScroll,
            paramsHeader, parametersStack, addParamButton,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            nameField.widthAnchor.constraint(equalTo: stack.widthAnchor),
            descriptionField.widthAnchor.constraint(equalTo: stack.widthAnchor),
            grid.widthAnchor.constraint(equalTo: stack.widthAnchor),
            templateScroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            templateScroll.heightAnchor.constraint(equalToConstant: 90),
            parametersStack.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        scroll.documentView = content

        let outerStack = NSStackView(views: [titleLabel, scroll, bottomRow])
        outerStack.orientation = .vertical
        outerStack.alignment = .leading
        outerStack.spacing = 12
        outerStack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(outerStack)
        NSLayoutConstraint.activate([
            outerStack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            outerStack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            outerStack.topAnchor.constraint(equalTo: root.topAnchor, constant: 18),
            outerStack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -18),
            scroll.widthAnchor.constraint(equalTo: outerStack.widthAnchor),
            content.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            bottomRow.widthAnchor.constraint(equalTo: outerStack.widthAnchor),
        ])
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(nameField)
    }

    // MARK: Parameter rows

    @objc private func addParameterClicked() { addParameterRow(prefilled: nil) }

    private func addParameterRow(prefilled param: CommandParameter?) {
        let nameField = NSTextField()
        nameField.placeholderString = "param_name"
        nameField.stringValue = param?.name ?? ""
        nameField.translatesAutoresizingMaskIntoConstraints = false

        let labelField = NSTextField()
        labelField.placeholderString = "Label"
        labelField.stringValue = param?.label ?? ""
        labelField.translatesAutoresizingMaskIntoConstraints = false

        let kindPopup = NSPopUpButton()
        kindPopup.translatesAutoresizingMaskIntoConstraints = false
        for kind in CommandParameterKind.allCases { kindPopup.addItem(withTitle: kind.rawValue) }
        kindPopup.selectItem(at: CommandParameterKind.allCases.firstIndex(of: param?.kind ?? .string) ?? 0)

        let requiredCheckbox = NSButton(checkboxWithTitle: "Req", target: nil, action: nil)
        requiredCheckbox.state = (param?.required ?? true) ? .on : .off
        requiredCheckbox.translatesAutoresizingMaskIntoConstraints = false

        let defaultField = NSTextField()
        defaultField.placeholderString = "Default"
        defaultField.stringValue = param?.defaultValue ?? ""
        defaultField.translatesAutoresizingMaskIntoConstraints = false

        let optionsField = NSTextField()
        optionsField.placeholderString = "Options (select), comma separated"
        optionsField.stringValue = (param?.options ?? []).joined(separator: ", ")
        optionsField.translatesAutoresizingMaskIntoConstraints = false

        let removeButton = NSButton(title: "\u{2715}", target: self, action: #selector(removeParameterClicked(_:)))
        removeButton.bezelStyle = .rounded
        removeButton.controlSize = .small
        removeButton.translatesAutoresizingMaskIntoConstraints = false

        let row = NSStackView(views: [nameField, labelField, kindPopup, requiredCheckbox, defaultField, optionsField, removeButton])
        row.orientation = .horizontal
        row.spacing = 6
        row.distribution = .fill
        row.translatesAutoresizingMaskIntoConstraints = false
        nameField.widthAnchor.constraint(equalToConstant: 90).isActive = true
        labelField.widthAnchor.constraint(equalToConstant: 80).isActive = true
        kindPopup.widthAnchor.constraint(equalToConstant: 90).isActive = true
        defaultField.widthAnchor.constraint(equalToConstant: 70).isActive = true
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
        let categoryID = CommandLibraryCategory.all[categoryPopup.indexOfSelectedItem].id
        let subcategory = subcategoryField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let template = templateTextView.string
        let tags = tagsField.stringValue.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let risk = CommandRiskLevel.allCases[riskPopup.indexOfSelectedItem]
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
        onSave?(name, descriptionField.stringValue, categoryID, subcategory.isEmpty ? nil : subcategory, template, parameters, tags, risk)
        dismiss(self)
    }

    @objc private func cancelClicked() { dismiss(self) }

    private func rowLabel(_ text: String) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.font = .systemFont(ofSize: 12)
        l.textColor = HelmTheme.mutedInk(ThemeManager.shared.theme)
        return l
    }
}
