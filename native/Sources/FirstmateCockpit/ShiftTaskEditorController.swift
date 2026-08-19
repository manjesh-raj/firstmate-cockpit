// Manjesh Grand Line - native macOS app.
//
// New/Edit Task sheet (cockpit-shift-create-edit, phase 2 of Shift - see
// AGENTS.md's "Shift" section), restyled by fm/grandline-task-editor-
// redesign against a captain-supplied HTML/CSS mockup
// (data/grandline-task-editor-redesign/reference-mockup.html) - translated
// into this app's own dark Helm design language (HelmTheme/ShiftFont/
// HelmCard/IconTileView/HoverHighlightView), not the mockup's literal
// light colors, matching how every other reference-mockup redesign in this
// session has been approached.
//
// Two things changed here:
//
// 1. A real theming bug, the same class this codebase has hit and fixed
//    repeatedly (see AGENTS.md's "Contrast" note and the many
//    `.appearance = .darkAqua/.aqua`-forcing fixes across
//    `SettingsController`/`HostEditorController`/etc.): this sheet's root
//    view forced `.appearance` via `ThemeManager.shared.observe`, but never
//    gave itself an explicit `HelmTheme`-derived background - a plain
//    `NSView` with no `wantsLayer`/`layer.backgroundColor` paints nothing
//    of its own, so blank areas showed through to the sheet's own default
//    (light) window backing regardless of the forced appearance. Fixed the
//    same way `HostEditorController.loadView()` already does it:
//    `root.wantsLayer = true` plus an explicit
//    `root.layer?.backgroundColor = HelmTheme.nsColor(theme.backgroundHex).cgColor`
//    inside the same observer. `ShiftFollowUpEditorController` and
//    `ShiftProjectEditorController` had the identical gap and got the same
//    two-line fix, since leaving two of the three editor sheets broken
//    would just be the same bug found and left half-fixed.
//
// 2. The redesign itself: a large placeholder-styled title field (separated
//    from a small natural-language-date hint line underneath, instead of
//    baking the hint into the placeholder text), a "DETAILS" section of
//    clickable field cards for Priority/Project (each popping an `NSMenu`,
//    mirroring `ShiftProjectViews`' own status-pill click pattern) instead
//    of plain `NSGridView` label:popup rows, a distinct toggle-row card for
//    "Set due date" that reveals the existing date/time controls only once
//    enabled, and a tags field that renders entered tags as small removable
//    chips (reusing `VocabularyChipView`/`ChipFlowView` from Dictation's own
//    chip treatment) instead of a single comma-separated field with no
//    per-tag feedback. Every existing behavior - natural-language date
//    detection on the title field (`ShiftDateParser`), priority/project
//    selection, save/cancel actions, and the existing attachment feature
//    (`ShiftImageAttachmentWell`) - is preserved; only its presentation
//    changed. The footer's "⌘Enter to save" hint is now a real shortcut,
//    not just copy: `save.keyEquivalentModifierMask = [.command]` fires via
//    `NSWindow.performKeyEquivalent:` regardless of first responder, the
//    same mechanism `ConsoleComposerPopover`'s Generate button already uses
//    - it also fixes the pre-existing gap where a plain Return inside the
//    multi-line Description field just inserted a newline and never saved.
//
// The mockup's Attachments drag-and-drop section is deliberately NOT part
// of this pass - that's a different (already-shipped) attachment mechanism
// in this app; this task only restructures presentation, not the
// attachment model.

import AppKit
import UniformTypeIdentifiers

/// The one "form surface on top of this sheet's own background" fill both
/// the field cards and the sunken text fields use - blends `chromeInkHex`
/// into `chromeBackgroundHex` rather than reusing either token bare, so the
/// surface stays visibly distinct from the sheet's `backgroundHex` root even
/// in the themes where `chromeBackgroundHex` and `backgroundHex` are
/// numerically identical (`gruvbox-light`/`tokyo-night-dark`/`tokyo-night-
/// light` - see `ConsoleComposerPopover.fieldFillColor(for:)`'s own doc
/// comment for the confirmed list). Mirrors `ShiftController.
/// detailFieldFillColor(for:)` exactly.
private func shiftEditorFieldFillColor(for theme: HelmTheme) -> NSColor {
    let chromeBackground = HelmTheme.nsColor(theme.chromeBackgroundHex)
    let ink = HelmTheme.nsColor(theme.chromeInkHex)
    return chromeBackground.blended(withFraction: 0.08, of: ink) ?? chromeBackground
}

/// A small "icon-in-a-22pt-square" container holding a centered colored dot
/// - gives the Priority field card's dot the same footprint as the Project
/// field card's `IconTileView(size: 22)`, so both cards' text columns start
/// at the same offset.
private final class PriorityDotView: NSView {
    private let dot = NSView()

    init(size: CGFloat = 22, dotDiameter: CGFloat = 10) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        dot.wantsLayer = true
        dot.layer?.cornerRadius = dotDiameter / 2
        dot.translatesAutoresizingMaskIntoConstraints = false
        addSubview(dot)
        NSLayoutConstraint.activate([
            dot.centerXAnchor.constraint(equalTo: centerXAnchor),
            dot.centerYAnchor.constraint(equalTo: centerYAnchor),
            dot.widthAnchor.constraint(equalToConstant: dotDiameter),
            dot.heightAnchor.constraint(equalToConstant: dotDiameter),
            widthAnchor.constraint(equalToConstant: size),
            heightAnchor.constraint(equalToConstant: size),
        ])
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    func setColor(_ color: NSColor) {
        dot.layer?.backgroundColor = color.cgColor
    }
}

/// The mockup's `.field` - a clickable card showing a small leading
/// accessory (a colored dot for Priority, a mini `IconTileView` for
/// Project), a muted field label over a bold value, and a trailing chevron.
/// Clicking anywhere on the card pops an `NSMenu` positioned just under it,
/// the same interaction `ShiftProjectViews`' status pill already uses.
private final class TaskFieldCardView: NSView {
    let card = HoverHighlightView()
    let valueLabel = NSTextField(labelWithString: "")
    private let fieldLabelView: NSTextField
    private let chevron = NSImageView()
    private let clickButton = NSButton()
    var onClick: (() -> Void)?

    init(label: String, accessory: NSView) {
        fieldLabelView = NSTextField(labelWithString: label)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        card.cornerRadius = 10
        card.translatesAutoresizingMaskIntoConstraints = false
        addSubview(card)
        NSLayoutConstraint.activate([
            card.leadingAnchor.constraint(equalTo: leadingAnchor),
            card.trailingAnchor.constraint(equalTo: trailingAnchor),
            card.topAnchor.constraint(equalTo: topAnchor),
            card.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightAnchor.constraint(equalToConstant: 50),
        ])

        accessory.translatesAutoresizingMaskIntoConstraints = false

        fieldLabelView.font = .systemFont(ofSize: 10.5)
        fieldLabelView.translatesAutoresizingMaskIntoConstraints = false

        valueLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        valueLabel.lineBreakMode = .byTruncatingTail
        valueLabel.translatesAutoresizingMaskIntoConstraints = false

        let textStack = NSStackView(views: [fieldLabelView, valueLabel])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 1
        textStack.translatesAutoresizingMaskIntoConstraints = false
        textStack.setContentHuggingPriority(.defaultLow, for: .horizontal)
        textStack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        chevron.image = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 9, weight: .semibold))
        chevron.translatesAutoresizingMaskIntoConstraints = false
        chevron.setContentHuggingPriority(.required, for: .horizontal)

        let row = NSStackView(views: [accessory, textStack, chevron])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 9
        row.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 12),
            row.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -11),
            row.centerYAnchor.constraint(equalTo: card.centerYAnchor),
        ])

        clickButton.title = ""
        clickButton.isBordered = false
        clickButton.target = self
        clickButton.action = #selector(clicked)
        clickButton.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(clickButton)
        NSLayoutConstraint.activate([
            clickButton.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            clickButton.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            clickButton.topAnchor.constraint(equalTo: card.topAnchor),
            clickButton.bottomAnchor.constraint(equalTo: card.bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    @objc private func clicked() { onClick?() }

    func popMenu(_ menu: NSMenu) {
        menu.popUp(positioning: nil, at: NSPoint(x: 12, y: bounds.height + 4), in: self)
    }

    func applyTheme(_ theme: HelmTheme) {
        let fill = shiftEditorFieldFillColor(for: theme)
        card.normalColor = fill
        card.hoverColor = fill.hoverShifted(by: 0.10, forMode: theme.mode)
        card.layer?.borderWidth = 1
        card.layer?.borderColor = HelmTheme.nsColor(theme.chromeLineHex).withAlphaComponent(0.5).cgColor
        fieldLabelView.textColor = HelmTheme.mutedInk(theme)
        valueLabel.textColor = HelmTheme.nsColor(theme.chromeInkHex)
        chevron.contentTintColor = HelmTheme.mutedInk(theme)
    }
}

final class ShiftTaskEditorController: NSViewController, NSTextFieldDelegate {

    /// This sheet's fixed width - `ShiftFollowUpEditorController`/
    /// `ShiftProjectEditorController` pick one fixed literal frame size and
    /// leave it, which works for them since their content never changes
    /// shape enough to expose the bug below; this sheet's due-date toggle,
    /// natural-language "Detected:" row, and tag chips all show/hide real
    /// content, so its height has to track that instead. See
    /// `resizeToFitContent()`.
    private static let sheetWidth: CGFloat = 520

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

    private let attachmentWell = ShiftImageAttachmentWell()
    private let chooseImageButton = NSButton(title: "Choose Image\u{2026}", target: nil, action: nil)
    /// `nil` until the captain interacts with the well in this session -
    /// `.unchanged` is reported on Save if this stays `nil`, so an ordinary
    /// edit that never touches the attachment never rewrites the image file.
    private var attachmentChange: ShiftAttachmentChange?

    private let headingLabel = NSTextField(labelWithString: "")
    private let titleField = NSTextField()
    private let hintLabel = NSTextField(labelWithString: "")
    private let detectedRow = NSStackView()
    private let detectedIcon = NSImageView(image: NSImage(systemSymbolName: "calendar.badge.checkmark", accessibilityDescription: nil) ?? NSImage())
    private let detectedLabel = NSTextField(labelWithString: "")

    private var selectedPriority: ShiftPriority
    private let priorityDot = PriorityDotView()
    private lazy var priorityCard = TaskFieldCardView(label: "Priority", accessory: priorityDot)

    private var selectedProjectID: String?
    private let projectIconTile = IconTileView(size: 22, cornerRadius: 6)
    private lazy var projectCard = TaskFieldCardView(label: "Project", accessory: projectIconTile)

    private let dueCard = NSView()
    private let dueSwitch = NSSwitch()
    private let dueTitleLabel = NSTextField(labelWithString: "Set due date")
    private let dueSubtitleLabel = NSTextField(labelWithString: "Add a date and optional time")
    private let dueDatePicker = NSDatePicker()

    private let tagsField = NSTextField()
    private let tagsChipsFlow = ChipFlowView()
    private var tagChips: [String] = []

    private let descriptionView = NSTextView()
    private let descScroll = NSScrollView()

    private let shortcutHintLabel = NSTextField(labelWithString: "\u{2318}\u{23ce} to save")

    /// Every uppercase section-kicker label ("DETAILS"/"TAGS"/etc.), so
    /// `applyTheme` can re-tint all of them in one loop instead of each
    /// caller wiring its own theme observer.
    private var sectionLabels: [NSTextField] = []

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
        let root = NSView(frame: NSRect(x: 0, y: 0, width: Self.sheetWidth, height: 780))
        root.wantsLayer = true
        // A fixed width, rather than just an initial-frame guess, is what
        // makes `resizeToFitContent()`'s `fittingSize` read below reliable -
        // without it, Auto Layout has to also guess a width when computing
        // the fitting height, which text wrapping/`ChipFlowView`'s own
        // wrap-to-width layout would otherwise make unstable.
        root.widthAnchor.constraint(equalToConstant: Self.sheetWidth).isActive = true
        view = root
        // The fix for the real theming bug (see this file's header): an
        // explicit `HelmTheme`-derived background, not just a forced
        // `.appearance` - a plain, unpainted `NSView` shows through to the
        // sheet's own default (light) window backing regardless of what
        // appearance its subviews resolve colors against.
        ThemeManager.shared.observe { [weak self] theme in
            self?.view.appearance = NSAppearance(named: theme.mode == .dark ? .darkAqua : .aqua)
            self?.view.layer?.backgroundColor = HelmTheme.nsColor(theme.backgroundHex).cgColor
            self?.applyTheme(theme)
        }

        headingLabel.stringValue = editing == nil ? "New Task" : "Edit Task"
        headingLabel.font = .systemFont(ofSize: 15, weight: .semibold)

        // MARK: Big title field + hint

        titleField.placeholderAttributedString = NSAttributedString(
            string: "What needs to be done?",
            attributes: [.font: NSFont.systemFont(ofSize: 22, weight: .semibold)]
        )
        titleField.stringValue = editing?.title ?? ""
        titleField.font = .systemFont(ofSize: 22, weight: .semibold)
        titleField.isBordered = false
        titleField.isBezeled = false
        titleField.drawsBackground = false
        titleField.focusRingType = .none
        titleField.translatesAutoresizingMaskIntoConstraints = false
        titleField.delegate = self

        hintLabel.lineBreakMode = .byWordWrapping
        hintLabel.maximumNumberOfLines = 1
        hintLabel.translatesAutoresizingMaskIntoConstraints = false

        detectedLabel.font = .systemFont(ofSize: 11)
        let clearDetected = NSButton(title: "", target: self, action: #selector(dismissDetected))
        clearDetected.isBordered = false
        clearDetected.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Dismiss")
        clearDetected.imageScaling = .scaleProportionallyDown
        clearDetected.translatesAutoresizingMaskIntoConstraints = false
        detectedRow.addArrangedSubview(detectedIcon)
        detectedRow.addArrangedSubview(detectedLabel)
        detectedRow.addArrangedSubview(clearDetected)
        detectedRow.orientation = .horizontal
        detectedRow.spacing = 6
        detectedRow.alignment = .centerY
        detectedRow.translatesAutoresizingMaskIntoConstraints = false
        detectedRow.isHidden = true

        // MARK: DETAILS - Priority / Project field cards

        let detailsLabel = sectionLabel("Details")
        priorityDot.setColor(.clear)
        priorityCard.onClick = { [weak self] in self?.priorityCardClicked() }
        projectIconTile.configure(symbol: "folder.fill", tint: .info, pointSize: 11)
        projectCard.onClick = { [weak self] in self?.projectCardClicked() }
        updatePriorityCard()
        updateProjectCard()

        let metaGrid = NSStackView(views: [priorityCard, projectCard])
        metaGrid.orientation = .horizontal
        metaGrid.distribution = .fillEqually
        metaGrid.spacing = 10
        metaGrid.translatesAutoresizingMaskIntoConstraints = false

        // MARK: "Set due date" toggle row

        dueCard.wantsLayer = true
        dueCard.layer?.cornerRadius = 10
        dueCard.translatesAutoresizingMaskIntoConstraints = false

        dueSwitch.target = self
        dueSwitch.action = #selector(hasDueToggled)
        dueSwitch.setContentHuggingPriority(.required, for: .horizontal)
        dueSwitch.translatesAutoresizingMaskIntoConstraints = false

        dueTitleLabel.font = .systemFont(ofSize: 12.5, weight: .semibold)
        dueTitleLabel.translatesAutoresizingMaskIntoConstraints = false
        dueSubtitleLabel.font = .systemFont(ofSize: 10.5)
        dueSubtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        let dueTextStack = NSStackView(views: [dueTitleLabel, dueSubtitleLabel])
        dueTextStack.orientation = .vertical
        dueTextStack.alignment = .leading
        dueTextStack.spacing = 1
        dueTextStack.translatesAutoresizingMaskIntoConstraints = false

        let dueLeft = NSStackView(views: [dueSwitch, dueTextStack])
        dueLeft.orientation = .horizontal
        dueLeft.alignment = .centerY
        dueLeft.spacing = 10
        dueLeft.translatesAutoresizingMaskIntoConstraints = false
        dueLeft.setContentHuggingPriority(.defaultLow, for: .horizontal)

        dueDatePicker.datePickerStyle = .textFieldAndStepper
        dueDatePicker.datePickerElements = [.yearMonthDay, .hourMinute]
        dueDatePicker.target = self
        dueDatePicker.action = #selector(dueDatePickerChanged)
        dueDatePicker.translatesAutoresizingMaskIntoConstraints = false
        dueDatePicker.setContentHuggingPriority(.required, for: .horizontal)
        dueDatePicker.setContentCompressionResistancePriority(.required, for: .horizontal)

        let existingDue = ShiftDateFormatting.dateTime(from: editing?.dueDate, time: editing?.dueTime)
        if let existingDue {
            dueSwitch.state = .on
            dueDatePicker.dateValue = existingDue
            dueDatePicker.isEnabled = true
        } else {
            dueSwitch.state = .off
            dueDatePicker.dateValue = Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: Date()) ?? Date()
            dueDatePicker.isEnabled = false
        }
        dueDatePicker.isHidden = dueSwitch.state != .on

        let dueRow = NSStackView(views: [dueLeft, dueDatePicker])
        dueRow.orientation = .horizontal
        dueRow.distribution = .fill
        dueRow.alignment = .centerY
        dueRow.spacing = 10
        dueRow.translatesAutoresizingMaskIntoConstraints = false
        dueCard.addSubview(dueRow)
        NSLayoutConstraint.activate([
            dueRow.leadingAnchor.constraint(equalTo: dueCard.leadingAnchor, constant: 13),
            dueRow.trailingAnchor.constraint(equalTo: dueCard.trailingAnchor, constant: -13),
            dueRow.topAnchor.constraint(equalTo: dueCard.topAnchor, constant: 12),
            dueRow.bottomAnchor.constraint(equalTo: dueCard.bottomAnchor, constant: -12),
        ])

        // MARK: Tags

        let tagsLabel = sectionLabel("Tags")
        tagsField.placeholderString = "Add tags, separated by commas"
        styleSunkenField(tagsField)
        tagsField.translatesAutoresizingMaskIntoConstraints = false
        tagsField.delegate = self
        tagChips = editing?.tags ?? []
        renderTagChips()

        // MARK: Description

        let descLabel = sectionLabel("Description")
        descriptionView.string = editing?.description ?? ""
        descriptionView.font = .systemFont(ofSize: 12)
        descriptionView.isRichText = false
        descriptionView.textContainerInset = NSSize(width: 8, height: 8)
        descriptionView.drawsBackground = true
        descScroll.wantsLayer = true
        descScroll.layer?.cornerRadius = 8
        descScroll.layer?.masksToBounds = true
        descScroll.layer?.borderWidth = 1
        descScroll.borderType = .noBorder
        descScroll.hasVerticalScroller = true
        descScroll.documentView = descriptionView
        descScroll.translatesAutoresizingMaskIntoConstraints = false

        // MARK: Attachment (existing feature, unchanged - out of this
        // redesign's scope, see this file's header)

        let attachmentLabel = sectionLabel("Attachment")
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

        // MARK: Footer

        shortcutHintLabel.font = .systemFont(ofSize: 11)
        shortcutHintLabel.translatesAutoresizingMaskIntoConstraints = false

        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancel.bezelStyle = .rounded
        cancel.keyEquivalent = "\u{1b}"
        let save = NSButton(title: editing == nil ? "Create Task" : "Save", target: self, action: #selector(save))
        save.bezelStyle = .rounded
        // Fires via `NSWindow.performKeyEquivalent:` regardless of first
        // responder - same mechanism `ConsoleComposerPopover`'s Generate
        // button uses, so ⌘Enter saves even while focus is in the
        // multi-line Description field (where a plain Return just inserts
        // a newline, per `descriptionView`'s own default key binding).
        save.keyEquivalent = "\r"
        save.keyEquivalentModifierMask = [.command]
        let actionsSpacer = NSView()
        actionsSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let footer = NSStackView(views: [shortcutHintLabel, actionsSpacer, cancel, save])
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.spacing = 10
        footer.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [
            headingLabel, titleField, hintLabel, detectedRow,
            detailsLabel, metaGrid, dueCard,
            tagsLabel, tagsField, tagsChipsFlow,
            descLabel, descScroll,
            attachmentRow, attachmentWell,
            footer,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.setCustomSpacing(2, after: titleField)
        stack.setCustomSpacing(16, after: hintLabel)
        stack.setCustomSpacing(8, after: detailsLabel)
        stack.setCustomSpacing(8, after: tagsField)
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 22),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -22),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -18),
            titleField.widthAnchor.constraint(equalTo: stack.widthAnchor),
            hintLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            detectedRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            metaGrid.widthAnchor.constraint(equalTo: stack.widthAnchor),
            dueCard.widthAnchor.constraint(equalTo: stack.widthAnchor),
            tagsField.widthAnchor.constraint(equalTo: stack.widthAnchor),
            tagsField.heightAnchor.constraint(equalToConstant: 30),
            tagsChipsFlow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            descScroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            descScroll.heightAnchor.constraint(equalToConstant: 110),
            attachmentRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            attachmentWell.widthAnchor.constraint(equalTo: stack.widthAnchor),
            footer.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])

        // `ThemeManager.observe` fires synchronously at registration (this
        // codebase's documented convention), and that registration happens
        // near the top of this method - long before the four
        // `sectionLabel(...)` calls below it have appended anything to
        // `sectionLabels`. So that first, and absent a theme change *only*,
        // firing found an empty array and `applyTheme`'s
        // `sectionLabels.forEach { ... }` was a no-op: the DETAILS / TAGS /
        // DESCRIPTION / ATTACHMENT kickers rendered in the system
        // `.labelColor` (measured #ffffff@0.85) instead of
        // `HelmTheme.mutedInk` (#f0f4f7@0.70), i.e. *brighter* than the body
        // text they label, inverting the intended hierarchy - and it
        // self-healed on any later theme switch, which is why this sheet's
        // own theme-sweep verification never caught it.
        //
        // One explicit re-apply at the end of `loadView`, once everything a
        // theme observer iterates actually exists, is the fix. See
        // `ThemeManager.swift`'s checklist - this was the third confirmed
        // instance of the same trap in this codebase.
        applyTheme(ThemeManager.shared.theme)

        resizeToFitContent()
    }

    /// The real fix for two captain-reported layout bugs
    /// (fm/grandline-task-editor-layout-fix): a large dead gap between "Set
    /// due date" and "TAGS" with the toggle off, and dead space below the
    /// footer with it on. Root cause: `root`'s frame height used to be a
    /// hardcoded literal (780) that didn't track this sheet's actual content
    /// height (~605-620pt, measured live) - `presentAsSheet` reads that
    /// literal frame size verbatim (it does not itself resize the sheet to
    /// fit Auto Layout content), so the sheet was always ~140-160pt taller
    /// than its content needed. With `stack`'s top and bottom both pinned as
    /// required constraints to `root`'s edges, that ~140pt of slack still
    /// had to go SOMEWHERE for the constraint system to be satisfiable - and
    /// since `stack`'s distribution is the vertical-stack default,
    /// `.gravityAreas` (never set explicitly), which has no defined rule for
    /// *which* arranged subview absorbs leftover space (see AGENTS.md's
    /// NSStackView gravityAreas gotcha), Auto Layout's own tie-breaking
    /// picked a different, sibling-content-dependent spot each time: with
    /// the due-date picker hidden, `dueCard` (an unconstrained-height plain
    /// `NSView`) was the path of least resistance and silently stretched to
    /// ~190pt (natural ~53pt) - the dead gap before "TAGS"; with the picker
    /// visible, `dueCard` resolved to its natural size and the same ~137pt
    /// instead landed as trailing space after the footer, since nothing else
    /// in the graph offered a cheaper place to put it. Confirmed live via a
    /// temporary debug probe (`FM_DEBUG_TASK_EDITOR_LAYOUT`, reverted before
    /// commit) dumping every arranged subview's real frame in both states.
    ///
    /// Fix: never let `root`'s frame drift from what its content actually
    /// needs. `root`'s width is now a real, required constraint (520pt, see
    /// `sheetWidth`) rather than just an initial-frame guess, which makes
    /// `fittingSize`'s height read stable and correct (text wrapping and
    /// `ChipFlowView`'s wrap-to-width tag layout both depend on a real,
    /// fixed width to size themselves). This is called once at the end of
    /// `loadView()` (fixes the initial-open case for both a fresh task and
    /// editing an existing one, due-off or due-on) and again from every
    /// action that can change how much this sheet actually shows - the due
    /// toggle, the natural-language "Detected:" row appearing/dismissing,
    /// and a tag chip being added/removed - so the sheet's height keeps
    /// tracking real content instead of drifting back into a mismatch (and
    /// therefore back into `gravityAreas` needing to inject slack again) as
    /// the captain interacts with the form.
    private func resizeToFitContent() {
        view.layoutSubtreeIfNeeded()
        let height = view.fittingSize.height
        guard height > 0 else { return }
        let size = NSSize(width: Self.sheetWidth, height: height)
        if let window = view.window {
            window.setContentSize(size)
        } else {
            view.setFrameSize(size)
        }
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(titleField)
    }

    // MARK: Theming

    private func sectionLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: "")
        label.attributedStringValue = NSAttributedString(string: text.uppercased(), attributes: [
            .font: NSFont.systemFont(ofSize: 10.5, weight: .semibold),
            .kern: 0.7,
        ])
        label.translatesAutoresizingMaskIntoConstraints = false
        sectionLabels.append(label)
        return label
    }

    /// Removes the stock system bezel and hands the whole look to an
    /// explicit `HelmTheme`-derived fill/border, matching
    /// `ShiftController.styleDetailFormField`/`ConsoleComposerViewController`'s
    /// identical fix for the same off-theme-bezel problem.
    private func styleSunkenField(_ field: NSTextField) {
        field.isBordered = false
        field.isBezeled = false
        field.focusRingType = .none
        field.drawsBackground = true
        field.wantsLayer = true
        field.layer?.masksToBounds = true
        field.layer?.cornerRadius = 8
        field.layer?.borderWidth = 1
    }

    private func applyTheme(_ theme: HelmTheme) {
        let ink = HelmTheme.nsColor(theme.chromeInkHex)
        let muted = HelmTheme.mutedInk(theme)
        let fieldFill = shiftEditorFieldFillColor(for: theme)
        let lineColor = HelmTheme.nsColor(theme.chromeLineHex).withAlphaComponent(0.5)

        headingLabel.textColor = ink

        titleField.textColor = ink
        titleField.placeholderAttributedString = NSAttributedString(
            string: "What needs to be done?",
            attributes: [.font: NSFont.systemFont(ofSize: 22, weight: .semibold), .foregroundColor: muted]
        )

        hintLabel.attributedStringValue = hintAttributedString(muted: muted, emphasis: ink)

        detectedIcon.contentTintColor = HelmTheme.nsColor(theme.accentHex)
        detectedLabel.textColor = muted

        sectionLabels.forEach { $0.textColor = muted }

        priorityCard.applyTheme(theme)
        projectCard.applyTheme(theme)
        updatePriorityDotColor(theme: theme)

        dueCard.layer?.backgroundColor = fieldFill.cgColor
        dueCard.layer?.borderWidth = 1
        dueCard.layer?.borderColor = lineColor.cgColor
        dueTitleLabel.textColor = ink
        dueSubtitleLabel.textColor = muted

        tagsField.textColor = ink
        tagsField.placeholderAttributedString = NSAttributedString(
            string: "Add tags, separated by commas",
            attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: muted]
        )
        tagsField.layer?.backgroundColor = fieldFill.cgColor
        tagsField.layer?.borderColor = lineColor.cgColor
        tagsChipsFlow.subviews.compactMap { $0 as? VocabularyChipView }.forEach { $0.applyTheme(theme) }

        descScroll.layer?.backgroundColor = fieldFill.cgColor
        descScroll.layer?.borderColor = lineColor.cgColor
        descriptionView.backgroundColor = fieldFill
        descriptionView.textColor = ink
        descriptionView.insertionPointColor = ink

        shortcutHintLabel.textColor = muted

        attachmentWell.applyTheme(theme)
    }

    private func hintAttributedString(muted: NSColor, emphasis: NSColor) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let base: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: muted]
        let bold: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11, weight: .semibold), .foregroundColor: emphasis]
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
        priorityCard.valueLabel.stringValue = selectedPriority.rawValue.capitalized
        updatePriorityDotColor(theme: ThemeManager.shared.theme)
    }

    private func updateProjectCard() {
        let name = projects.first(where: { $0.id == selectedProjectID })?.name ?? "No project"
        projectCard.valueLabel.stringValue = name
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
            if !wasHidden { resizeToFitContent() }
            return
        }
        dueSwitch.state = .on
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
        if wasHidden { resizeToFitContent() }
    }

    @objc private func dismissDetected() {
        let wasHidden = detectedRow.isHidden
        detectedRow.isHidden = true
        dueManuallyEdited = true
        if !wasHidden { resizeToFitContent() }
    }

    @objc private func hasDueToggled() {
        dueManuallyEdited = true
        let on = dueSwitch.state == .on
        dueDatePicker.isEnabled = on
        dueDatePicker.isHidden = !on
        detectedRow.isHidden = true
        resizeToFitContent()
    }

    @objc private func dueDatePickerChanged() {
        dueManuallyEdited = true
        let wasHidden = detectedRow.isHidden
        detectedRow.isHidden = true
        if !wasHidden { resizeToFitContent() }
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
        // A harmless no-op the first time this runs, from inside `loadView()`
        // itself (before the stack/window exist) - `loadView()`'s own final
        // `resizeToFitContent()` call supersedes it. Needed for every later
        // call, once a tag is added/removed after the sheet is already
        // showing, since `ChipFlowView`'s wrap-to-width height changes with
        // the chip count.
        resizeToFitContent()
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
        if dueSwitch.state == .on {
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
