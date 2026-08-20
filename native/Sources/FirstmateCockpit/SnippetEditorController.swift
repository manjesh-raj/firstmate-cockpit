// Manjesh Grand Line - native macOS app.
//
// The New/Edit Snippet sheet (design report Section B2, Section D Phase 3):
// just a Label and a command text box - deliberately as small as the Termius
// snippet form gets, since the whole point is a fast save-and-run loop.
//
// Phase 6 of the full-app UI audit moved it onto the shared form scaffold
// (`HelmForm.swift`). It was the most system-chrome-dependent of the six
// editors - a 180x326 sheet whose only controls were a stock bezeled field and
// an `NSScrollView` wearing AppKit's own `.bezelBorder` frame. Its field set,
// its validation and its Delete action are unchanged.

import AppKit

final class SnippetEditorController: NSViewController {

    private let editing: Snippet?

    /// Called with the assembled snippet on Save. The caller persists it.
    var onSave: ((Snippet) -> Void)?
    /// Called with the snippet id on Delete (only offered when editing).
    var onDelete: ((UUID) -> Void)?

    private let labelField = HelmTextField(placeholder: "Name this snippet", style: .lead)
    private let commandView = HelmTextView(height: 130, monospaced: true)

    init(snippet: Snippet?) {
        self.editing = snippet
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        let form = HelmFormSheet(title: editing == nil ? "New Snippet" : "Edit Snippet")
        view = form

        labelField.stringValue = editing?.label ?? ""
        form.addLead(labelField)

        form.addSection("Command")
        commandView.string = editing?.command ?? ""
        form.addRow(commandView)
        form.addCaption(
            "\u{201c}Run\u{201d} sends this text, then Enter, to the active terminal tab. "
            + "A snippet can also be set as a host's startup snippet in the host editor."
        )

        form.setFooter(target: self,
                       confirmTitle: "Save",
                       confirm: #selector(save),
                       cancel: #selector(cancel),
                       delete: editing == nil ? nil : (title: "Delete", action: #selector(deleteSnippet)))

        form.refreshTheme()
        form.sizeToFitContent()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(labelField)
    }

    @objc private func save() {
        let label = labelField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let command = commandView.string
        guard !label.isEmpty, !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            view.window?.makeFirstResponder(label.isEmpty ? labelField : commandView.textView)
            NSSound.beep()
            return
        }
        var snippet = editing ?? Snippet(label: "", command: "")
        snippet.label = label
        snippet.command = command
        onSave?(snippet)
        dismiss(self)
    }

    @objc private func deleteSnippet() {
        guard let id = editing?.id else { return }
        onDelete?(id)
        dismiss(self)
    }

    @objc private func cancel() {
        dismiss(self)
    }
}
