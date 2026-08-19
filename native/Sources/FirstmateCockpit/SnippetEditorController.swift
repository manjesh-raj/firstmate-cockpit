// Manjesh Grand Line - native macOS app.
//
// The New/Edit Snippet sheet (design report Section B2, Section D Phase 3):
// just a Label and a command text box - deliberately as small as the Termius
// snippet form gets, since the whole point is a fast save-and-run loop.

import AppKit

final class SnippetEditorController: NSViewController {

    private let editing: Snippet?

    /// Called with the assembled snippet on Save. The caller persists it.
    var onSave: ((Snippet) -> Void)?
    /// Called with the snippet id on Delete (only offered when editing).
    var onDelete: ((UUID) -> Void)?

    private let labelField = NSTextField()
    private let commandView = NSTextView()

    init(snippet: Snippet?) {
        self.editing = snippet
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Labels carrying `HelmTheme.mutedInk` instead of a fixed system grey -
    /// see `MutedInkLabels` for why a system grey is wrong here (audit §5.3).
    private let mutedLabels = MutedInkLabels()

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 440, height: 320))
        view = root
        // Theme-audit task: force this sheet's own appearance so any
        // system-semantic color still in its subtree resolves against the
        // active Helm theme's mode instead of whatever the OS happens to be
        // set to. Its own muted text no longer relies on that - it goes
        // through `mutedLabels` (audit §5.3), which is theme-aware rather
        // than merely light/dark-correct.
        ThemeManager.shared.observe { [weak root, weak self] theme in
            root?.appearance = NSAppearance(named: theme.mode == .dark ? .darkAqua : .aqua)
            self?.mutedLabels.apply(theme)
        }

        let title = NSTextField(labelWithString: editing == nil ? "New Snippet" : "Edit Snippet")
        title.font = .systemFont(ofSize: 15, weight: .semibold)

        labelField.placeholderString = "Label (e.g. \"attach tmux\")"
        labelField.stringValue = editing?.label ?? ""
        labelField.translatesAutoresizingMaskIntoConstraints = false

        let commandLabel = NSTextField(labelWithString: "Command")
        commandLabel.font = .systemFont(ofSize: 12)
        mutedLabels.add(commandLabel)

        commandView.string = editing?.command ?? ""
        commandView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        commandView.isRichText = false
        commandView.textContainerInset = NSSize(width: 6, height: 6)
        let scroll = NSScrollView()
        scroll.borderType = .bezelBorder
        scroll.hasVerticalScroller = true
        scroll.documentView = commandView
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let caption = NSTextField(wrappingLabelWithString:
            "\u{201c}Run\u{201d} sends this text, then Enter, to the active terminal tab. "
            + "A snippet can also be set as a host's startup snippet in the host editor."
        )
        caption.font = .systemFont(ofSize: 11)
        mutedLabels.add(caption)
        caption.translatesAutoresizingMaskIntoConstraints = false

        let cancel = HelmButton(title: "Cancel", variant: .secondary, target: self, action: #selector(cancel))
        cancel.keyEquivalent = "\u{1b}"
        let save = HelmButton(title: "Save", variant: .primary, target: self, action: #selector(save))
        save.keyEquivalent = "\r"
        var bottomViews: [NSView] = []
        if editing != nil {
            let del = HelmButton(title: "Delete", variant: .destructive, target: self, action: #selector(deleteSnippet))
            bottomViews.append(del)
        }
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        bottomViews += [spacer, cancel, save]
        let bottom = NSStackView(views: bottomViews)
        bottom.orientation = .horizontal
        bottom.spacing = 10

        let stack = NSStackView(views: [title, labelField, commandLabel, scroll, caption, bottom])
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
            labelField.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scroll.heightAnchor.constraint(equalToConstant: 130),
            caption.widthAnchor.constraint(equalTo: stack.widthAnchor),
            bottom.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(labelField)
    }

    @objc private func save() {
        let label = labelField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let command = commandView.string
        guard !label.isEmpty, !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            view.window?.makeFirstResponder(label.isEmpty ? labelField : commandView)
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
