// Manjesh Grand Line - native macOS app.
//
// The "DevOps Commands" tab UI (fm/grandline-devops-command-library,
// Phase 1) - see AGENTS.md's "Shift" section and the captain-approved
// design doc (data/grandline-devops-command-library/design-reference.html)
// for the mockup this matches. `CommandLibraryPageView` is a plain
// `NSObject`-owned view component (not its own `NSViewController`),
// following `ShiftProjectDetailView.swift`'s own convention for a
// self-contained sub-page `ShiftController` embeds and toggles visibility
// on, rather than owns view-by-view inline.
//
// Layout mirrors the mockup: a search field above a two-column row (a
// ~220pt Favorites+Categories rail on the left, a detail pane on the
// right). Category browsing is a two-level drill-down within the left
// rail (categories -> a category's own command list -> back) rather than
// an always-expanded tree, since `NSStackView` rebuilds are cheap at this
// row count (a captain's command library is nowhere near the scale that
// would justify an `NSTableView` here - see `ShiftProjectDetailView.swift`'s
// header for where that line actually gets crossed).
//
// Phase 2 (fm/grandline-devops-command-library-phase2) wires up everything
// Phase 1 left disabled: Send to Terminal (`onSendToTerminal`, forwarded by
// `ShiftController`/`AppShellController` to `ConsoleController.
// sendCommandLibraryTextToActiveTab`), Edit/Add Command/Duplicate (all open
// `CommandEditorController` via `onPresentEditor`, since this class isn't
// itself an `NSViewController` and can't call `presentAsSheet` directly),
// recent-used tracking (a "RECENTLY USED" section, sorted most-recent-first
// by `CommandLibraryStore.recentUsage`), and the destructive-confirmation
// gate (`confirmIfNeeded`, guarding both Copy and Send to Terminal - see the
// design doc's mockup for the exact copy). Explain stays disabled - AI
// actions are Phase 3.

import AppKit

final class CommandLibraryPageView: NSObject {
    let view = NSView()

    private let store: CommandLibraryStore
    private var theme: HelmTheme = ThemeManager.shared.theme

    // MARK: Navigation state

    private enum LeftPanelState: Equatable {
        case browse
        case category(String)
    }
    private var leftPanelState: LeftPanelState = .browse
    private var selectedCommandID: String?
    private var searchQuery: String = ""
    /// Reset every time `selectedCommandID` changes - see `selectCommand`.
    private var paramValues: [String: String] = [:]

    // MARK: Chrome

    private let searchField = NSTextField()
    private let searchIcon = NSImageView()
    private let searchRow = NSView()

    private let leftPanel = NSView()
    private let leftPanelStack = NSStackView()

    private let detailPanel = NSView()
    private let detailStack = NSStackView()
    private let emptyDetailState = HelmEmptyState(symbol: "terminal", body: "Pick a command from the list\nto see its details here.")

    // Detail pane's live views (built once, mutated per-selection - see
    // `renderDetail(for:)`).
    private let detailNameLabel = NSTextField(labelWithString: "")
    private let detailRiskPill = NSView()
    private let detailRiskPillLabel = NSTextField(labelWithString: "")
    private let detailMetaLabel = NSTextField(wrappingLabelWithString: "")
    private let detailCommandBox = NSView()
    private let detailCommandLabel = NSTextField(wrappingLabelWithString: "")
    private let detailParamsStack = NSStackView()
    // **The action row has a hierarchy now.** As shipped it was seven
    // same-weight buttons in a line, so nothing said which one the captain
    // reaches for. The prototype (`10-proposed-devops-commands.png`) leads
    // with a filled "Send to Terminal", follows it with two bordered
    // secondaries (Copy, Add to Runbook) and pushes a lightweight "Explain"
    // to the far right. Every action this page had is still here - the
    // prototype simply doesn't model Edit/Duplicate/Favorite - they move into
    // the quiet trailing group with Explain rather than competing with the
    // primary action.
    private let detailCopyButton = HelmButton(title: "Copy", variant: .secondary, symbol: "doc.on.doc", target: nil, action: nil)
    private let detailSendButton = HelmButton(title: "Send to Terminal", variant: .primary, symbol: "play.fill", target: nil, action: nil)
    private let detailEditButton = HelmButton(title: "Edit", variant: .quiet, target: nil, action: nil)
    private let detailDuplicateButton = HelmButton(title: "Duplicate", variant: .quiet, target: nil, action: nil)
    private let detailWorkflowButton = HelmButton(title: "Add to Runbook", variant: .secondary, symbol: "plus", target: nil, action: nil)
    private let detailExplainButton = HelmButton(title: "Explain", variant: .quiet, symbol: "sparkles", target: nil, action: nil)
    private let detailFavoriteButton = HelmButton(title: "Favorite", variant: .quiet, symbol: "star", target: nil, action: nil)
    private let detailContentContainer = NSView()

    /// Every live parameter input control, keyed by parameter name, for the
    /// currently-rendered command - read from on every keystroke/selection to
    /// regenerate the preview, and rebuilt fresh on every `renderDetail`.
    private var paramControls: [String: NSControl] = [:]

    /// Forwarded to `ConsoleController.sendCommandLibraryTextToActiveTab`
    /// (see `ShiftController`/`AppShellController`'s wiring) - this class
    /// knows nothing about the console.
    var onSendToTerminal: ((String) -> Void)?
    /// This class isn't an `NSViewController`, so it can't call
    /// `presentAsSheet` itself - the owning `ShiftController` does, via this
    /// closure (same forward-don't-own convention as every other page in
    /// this app that needs its parent to present something).
    var onPresentEditor: ((CommandEditorController) -> Void)?

    private let runbookStore = DocsRunbookStore()

    init(store: CommandLibraryStore) {
        self.store = store
        super.init()
        buildView()
        render()
    }

    // MARK: Building chrome

    private func buildView() {
        view.wantsLayer = true
        view.translatesAutoresizingMaskIntoConstraints = false

        buildSearchRow()
        buildLeftPanel()
        buildDetailPanel()

        let columns = NSStackView(views: [leftPanel, detailPanel])
        columns.orientation = .horizontal
        columns.alignment = .top
        columns.spacing = 16
        // `.fill`, explicitly - AGENTS.md gotcha (10). Left at the default
        // `.gravityAreas` this stack ignored the hugging priorities below
        // entirely and laid both panes out at their natural width, which is
        // why the detail card stopped around 60% of the page with dead space
        // to its right instead of filling the column the way the prototype's
        // right-hand pane does.
        columns.distribution = .fill
        columns.translatesAutoresizingMaskIntoConstraints = false
        leftPanel.widthAnchor.constraint(equalToConstant: 220).isActive = true
        leftPanel.setContentHuggingPriority(.required, for: .horizontal)
        leftPanel.setContentCompressionResistancePriority(.required, for: .horizontal)
        detailPanel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        detailPanel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let root = NSStackView(views: [searchRow, columns])
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 14
        root.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            root.topAnchor.constraint(equalTo: view.topAnchor),
            root.bottomAnchor.constraint(lessThanOrEqualTo: view.bottomAnchor),
            searchRow.widthAnchor.constraint(equalTo: root.widthAnchor),
            columns.widthAnchor.constraint(equalTo: root.widthAnchor),
        ])
    }

    private func buildSearchRow() {
        searchIcon.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 12, weight: .medium))
        searchIcon.translatesAutoresizingMaskIntoConstraints = false

        searchField.placeholderString = "Search commands\u{2026} (try \u{201C}memory\u{201D} or \u{201C}certificate\u{201D})"
        searchField.isBordered = false
        searchField.drawsBackground = false
        searchField.focusRingType = .none
        searchField.font = .systemFont(ofSize: 13)
        searchField.target = self
        searchField.action = #selector(searchChanged)
        searchField.delegate = self
        searchField.translatesAutoresizingMaskIntoConstraints = false

        let inner = NSStackView(views: [searchIcon, searchField])
        inner.orientation = .horizontal
        inner.alignment = .centerY
        inner.spacing = 10
        inner.translatesAutoresizingMaskIntoConstraints = false

        // A touch more generous than the app's usual compact rows - this is
        // the page's single primary entry point (mockup: `py-2` on a
        // full-width bar), so it should read with more visual weight than an
        // ordinary list row.
        searchRow.wantsLayer = true
        searchRow.layer?.cornerRadius = 9
        searchRow.translatesAutoresizingMaskIntoConstraints = false
        searchRow.addSubview(inner)
        NSLayoutConstraint.activate([
            inner.leadingAnchor.constraint(equalTo: searchRow.leadingAnchor, constant: 14),
            inner.trailingAnchor.constraint(equalTo: searchRow.trailingAnchor, constant: -14),
            inner.topAnchor.constraint(equalTo: searchRow.topAnchor, constant: 11),
            inner.bottomAnchor.constraint(equalTo: searchRow.bottomAnchor, constant: -11),
        ])
    }

    private func buildLeftPanel() {
        leftPanel.wantsLayer = true
        leftPanel.layer?.cornerRadius = 10
        leftPanel.translatesAutoresizingMaskIntoConstraints = false

        leftPanelStack.orientation = .vertical
        leftPanelStack.alignment = .leading
        leftPanelStack.spacing = 4
        leftPanelStack.translatesAutoresizingMaskIntoConstraints = false
        leftPanel.addSubview(leftPanelStack)
        NSLayoutConstraint.activate([
            leftPanelStack.leadingAnchor.constraint(equalTo: leftPanel.leadingAnchor, constant: 12),
            leftPanelStack.trailingAnchor.constraint(equalTo: leftPanel.trailingAnchor, constant: -12),
            leftPanelStack.topAnchor.constraint(equalTo: leftPanel.topAnchor, constant: 12),
            leftPanelStack.bottomAnchor.constraint(equalTo: leftPanel.bottomAnchor, constant: -12),
        ])
    }

    private func buildDetailPanel() {
        detailPanel.wantsLayer = true
        detailPanel.layer?.cornerRadius = 10
        detailPanel.translatesAutoresizingMaskIntoConstraints = false

        emptyDetailState.translatesAutoresizingMaskIntoConstraints = false
        emptyDetailState.heightAnchor.constraint(equalToConstant: 220).isActive = true

        buildDetailContent()

        detailPanel.addSubview(emptyDetailState)
        detailPanel.addSubview(detailContentContainer)
        NSLayoutConstraint.activate([
            emptyDetailState.leadingAnchor.constraint(equalTo: detailPanel.leadingAnchor, constant: 16),
            emptyDetailState.trailingAnchor.constraint(equalTo: detailPanel.trailingAnchor, constant: -16),
            emptyDetailState.topAnchor.constraint(equalTo: detailPanel.topAnchor, constant: 16),
            emptyDetailState.bottomAnchor.constraint(equalTo: detailPanel.bottomAnchor, constant: -16),
            detailContentContainer.leadingAnchor.constraint(equalTo: detailPanel.leadingAnchor, constant: 16),
            detailContentContainer.trailingAnchor.constraint(equalTo: detailPanel.trailingAnchor, constant: -16),
            detailContentContainer.topAnchor.constraint(equalTo: detailPanel.topAnchor, constant: 14),
            detailContentContainer.bottomAnchor.constraint(equalTo: detailPanel.bottomAnchor, constant: -14),
        ])
    }

    private func buildDetailContent() {
        detailNameLabel.font = HelmType.pageTitle(.serif)
        detailNameLabel.lineBreakMode = .byTruncatingTail

        detailRiskPillLabel.font = ShiftFont.mono(9.5, weight: .semibold)
        detailRiskPillLabel.translatesAutoresizingMaskIntoConstraints = false
        detailRiskPill.wantsLayer = true
        detailRiskPill.layer?.cornerRadius = 8
        detailRiskPill.translatesAutoresizingMaskIntoConstraints = false
        detailRiskPill.addSubview(detailRiskPillLabel)
        NSLayoutConstraint.activate([
            detailRiskPillLabel.leadingAnchor.constraint(equalTo: detailRiskPill.leadingAnchor, constant: 8),
            detailRiskPillLabel.trailingAnchor.constraint(equalTo: detailRiskPill.trailingAnchor, constant: -8),
            detailRiskPillLabel.topAnchor.constraint(equalTo: detailRiskPill.topAnchor, constant: 3),
            detailRiskPillLabel.bottomAnchor.constraint(equalTo: detailRiskPill.bottomAnchor, constant: -3),
        ])
        detailRiskPill.setContentHuggingPriority(.required, for: .horizontal)

        // The risk pill sits at the row's trailing edge (mockup:
        // `justify-between`), not crowded right up against the title text -
        // it reads as a distinct status badge for the command, not a suffix
        // on its name.
        let titleRowSpacer = NSView()
        titleRowSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let titleRow = NSStackView(views: [detailNameLabel, titleRowSpacer, detailRiskPill])
        titleRow.orientation = .horizontal
        titleRow.alignment = .firstBaseline
        titleRow.spacing = 10
        titleRow.translatesAutoresizingMaskIntoConstraints = false

        detailMetaLabel.font = .systemFont(ofSize: 11)
        detailMetaLabel.lineBreakMode = .byWordWrapping

        detailCommandLabel.font = ShiftFont.mono(12)
        detailCommandLabel.lineBreakMode = .byWordWrapping
        detailCommandLabel.isSelectable = true
        detailCommandLabel.translatesAutoresizingMaskIntoConstraints = false
        detailCommandBox.wantsLayer = true
        detailCommandBox.layer?.cornerRadius = 8
        detailCommandBox.translatesAutoresizingMaskIntoConstraints = false
        detailCommandBox.addSubview(detailCommandLabel)
        NSLayoutConstraint.activate([
            detailCommandLabel.leadingAnchor.constraint(equalTo: detailCommandBox.leadingAnchor, constant: 12),
            detailCommandLabel.trailingAnchor.constraint(equalTo: detailCommandBox.trailingAnchor, constant: -12),
            detailCommandLabel.topAnchor.constraint(equalTo: detailCommandBox.topAnchor, constant: 10),
            detailCommandLabel.bottomAnchor.constraint(equalTo: detailCommandBox.bottomAnchor, constant: -10),
        ])

        detailParamsStack.orientation = .vertical
        detailParamsStack.alignment = .leading
        detailParamsStack.spacing = 12
        detailParamsStack.translatesAutoresizingMaskIntoConstraints = false

        detailExplainButton.controlSize = .small
        detailExplainButton.isEnabled = false
        detailExplainButton.toolTip = "Coming in a later phase"
        detailExplainButton.translatesAutoresizingMaskIntoConstraints = false

        detailCopyButton.controlSize = .small
        detailCopyButton.keyEquivalent = "c"
        detailCopyButton.keyEquivalentModifierMask = [.command]
        detailCopyButton.target = self
        detailCopyButton.action = #selector(copyClicked)
        detailCopyButton.translatesAutoresizingMaskIntoConstraints = false

        detailSendButton.controlSize = .small
        detailSendButton.target = self
        detailSendButton.action = #selector(sendToTerminalClicked)
        detailSendButton.translatesAutoresizingMaskIntoConstraints = false

        detailEditButton.controlSize = .small
        detailEditButton.target = self
        detailEditButton.action = #selector(editClicked)
        detailEditButton.translatesAutoresizingMaskIntoConstraints = false

        detailDuplicateButton.controlSize = .small
        detailDuplicateButton.target = self
        detailDuplicateButton.action = #selector(duplicateClicked)
        detailDuplicateButton.translatesAutoresizingMaskIntoConstraints = false

        detailWorkflowButton.controlSize = .small
        detailWorkflowButton.target = self
        detailWorkflowButton.action = #selector(workflowClicked(_:))
        detailWorkflowButton.toolTip = "Add this command as a step in a Docs \u{2192} Runbook"
        detailWorkflowButton.translatesAutoresizingMaskIntoConstraints = false

        detailFavoriteButton.controlSize = .small
        // The amber emphasis used to be a hand-rolled `attributedTitle`
        // (`contentTintColor` does not colour a string title) - `HelmButton`'s
        // `tint` is that, shared and routed through `HelmContrast` so the hue
        // stays legible on the button's own fill in all 12 palettes.
        detailFavoriteButton.tint = .warn
        detailFavoriteButton.target = self
        detailFavoriteButton.action = #selector(favoriteClicked)
        detailFavoriteButton.translatesAutoresizingMaskIntoConstraints = false

        let buttonsSpacer = NSView()
        buttonsSpacer.translatesAutoresizingMaskIntoConstraints = false
        buttonsSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        buttonsSpacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for b in [detailSendButton, detailCopyButton, detailWorkflowButton,
                  detailEditButton, detailDuplicateButton, detailFavoriteButton, detailExplainButton] {
            b.setContentHuggingPriority(.required, for: .horizontal)
            b.setContentCompressionResistancePriority(.required, for: .horizontal)
        }
        // Primary first, then the two supporting secondaries, then the spacer,
        // then the quiet group at the trailing edge.
        let buttonsRow = NSStackView(views: [
            detailSendButton, detailCopyButton, detailWorkflowButton, buttonsSpacer,
            detailEditButton, detailDuplicateButton, detailFavoriteButton, detailExplainButton,
        ])
        buttonsRow.orientation = .horizontal
        buttonsRow.distribution = .fill
        buttonsRow.spacing = 8
        buttonsRow.translatesAutoresizingMaskIntoConstraints = false

        detailContentContainer.translatesAutoresizingMaskIntoConstraints = false
        let stack = NSStackView(views: [titleRow, detailMetaLabel, detailCommandBox, detailParamsStack, buttonsRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        detailContentContainer.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: detailContentContainer.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: detailContentContainer.trailingAnchor),
            stack.topAnchor.constraint(equalTo: detailContentContainer.topAnchor),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: detailContentContainer.bottomAnchor),
            titleRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            detailMetaLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            detailCommandBox.widthAnchor.constraint(equalTo: stack.widthAnchor),
            detailParamsStack.widthAnchor.constraint(equalTo: stack.widthAnchor),
            buttonsRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
    }

    // MARK: Public entry points

    /// Called from `ShiftController.viewWillAppear()`/theme-switch-triggered
    /// re-render, mirroring how the rest of that page refreshes.
    func reloadAndRender() {
        store.reloadAll()
        render()
    }

    func applyTheme(_ theme: HelmTheme) {
        self.theme = theme
        view.layer?.backgroundColor = .clear
        let ink = HelmTheme.nsColor(theme.chromeInkHex)
        let muted = HelmTheme.mutedInk(theme)
        let surface = HelmTheme.nsColor(theme.chromeBackgroundHex)
        let line = HelmTheme.nsColor(theme.chromeLineHex)

        searchRow.layer?.backgroundColor = surface.cgColor
        searchRow.layer?.borderWidth = 1
        searchRow.layer?.borderColor = line.withAlphaComponent(0.6).cgColor
        searchIcon.contentTintColor = muted
        searchField.textColor = ink

        leftPanel.layer?.backgroundColor = surface.cgColor
        leftPanel.layer?.borderWidth = 1
        leftPanel.layer?.borderColor = line.withAlphaComponent(0.6).cgColor

        detailPanel.layer?.backgroundColor = surface.cgColor
        detailPanel.layer?.borderWidth = 1
        detailPanel.layer?.borderColor = line.withAlphaComponent(0.6).cgColor

        emptyDetailState.applyTheme(theme)
        detailNameLabel.textColor = ink
        detailMetaLabel.textColor = muted
        detailCommandBox.layer?.backgroundColor = HelmTheme.nsColor(theme.backgroundHex).cgColor
        detailCommandBox.layer?.borderWidth = 1
        detailCommandBox.layer?.borderColor = line.withAlphaComponent(0.6).cgColor
        // Both the "Copy is emphasised" and "Favorite reads as gold" hand-rolls
        // that used to live here are gone: emphasis is `HelmButton`'s variant
        // (the audit's own prototype makes "Send to Terminal" the pane's
        // primary and Copy an ordinary secondary), and the amber is its
        // `tint`. `refreshFavoriteButton` now only flips the title text.
        refreshFavoriteButton()

        renderLeftPanel()
        if let id = selectedCommandID, let command = store.command(id: id) {
            renderDetail(for: command)
        }
    }

    // MARK: Rendering

    private func render() {
        renderLeftPanel()
        if let id = selectedCommandID, let command = store.command(id: id) {
            renderDetail(for: command)
        } else {
            selectedCommandID = nil
            emptyDetailState.isHidden = false
            detailContentContainer.isHidden = true
        }
        applyTheme(theme)
    }

    private func clearStack(_ stack: NSStackView) {
        for v in stack.arrangedSubviews {
            stack.removeArrangedSubview(v)
            v.removeFromSuperview()
        }
    }

    /// Adds `view` to `leftPanelStack` and pins its width to the stack's own
    /// width - in that order. A width constraint referencing `leftPanelStack`
    /// must never be activated before `view` is actually in the stack's view
    /// hierarchy (added as an arranged subview) - doing it the other way
    /// round throws AppKit's "no common ancestor" exception, since the two
    /// views share no ancestor yet at that point. See AGENTS.md's AppKit
    /// gotcha catalogue for the general rule this is an instance of.
    private func appendToLeftPanel(_ view: NSView) {
        leftPanelStack.addArrangedSubview(view)
        view.widthAnchor.constraint(equalTo: leftPanelStack.widthAnchor).isActive = true
    }

    /// A section break reads as cramped at the rail's uniform 4pt row
    /// spacing (fine for row-to-row, too tight around a divider - the
    /// mockup gives section boundaries roughly 3x a row's own gap). Rather
    /// than loosen every row's spacing to get that breathing room, this
    /// widens only the two gaps touching the divider itself via
    /// `NSStackView.setCustomSpacing(_:after:)`.
    private func appendDividerToLeftPanel() {
        if let last = leftPanelStack.arrangedSubviews.last {
            leftPanelStack.setCustomSpacing(10, after: last)
        }
        let d = divider()
        appendToLeftPanel(d)
        leftPanelStack.setCustomSpacing(10, after: d)
    }

    private func mutedHeaderLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = ShiftFont.mono(9.5, weight: .semibold)
        label.textColor = HelmTheme.nsColor(theme.accentHex)
        return label
    }

    private func leftPanelRow(text: String, trailing: String? = nil, isSelected: Bool = false, isMuted: Bool = false, action: Selector) -> NSView {
        let container = HoverHighlightView()
        container.cornerRadius = 6

        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 12, weight: isSelected ? .semibold : .regular)
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        var rowViews: [NSView] = [label]
        if let trailing {
            let trailingLabel = NSTextField(labelWithString: trailing)
            trailingLabel.font = ShiftFont.mono(10)
            trailingLabel.textColor = HelmTheme.mutedInk(theme)
            trailingLabel.setContentHuggingPriority(.required, for: .horizontal)
            rowViews.append(trailingLabel)
        }
        let row = NSStackView(views: rowViews)
        row.orientation = .horizontal
        row.distribution = .fill
        row.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            row.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
            row.topAnchor.constraint(equalTo: container.topAnchor, constant: 5),
            row.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -5),
        ])

        let ink = HelmTheme.nsColor(theme.chromeInkHex)
        let muted = HelmTheme.mutedInk(theme)
        let line = HelmTheme.nsColor(theme.chromeLineHex)
        let accentTint = HelmTheme.nsColor(theme.accentHex).withAlphaComponent(theme.mode == .dark ? 0.18 : 0.12)
        label.textColor = isMuted ? muted : (isSelected ? HelmTheme.nsColor(theme.accentHex) : ink)
        container.normalColor = isSelected ? accentTint : .clear
        container.hoverColor = isSelected ? accentTint : line.withAlphaComponent(0.25)
        container.translatesAutoresizingMaskIntoConstraints = false

        let click = NSClickGestureRecognizer(target: self, action: action)
        container.addGestureRecognizer(click)
        return container
    }

    /// A dispatch table from a built row's identity back to the identifier a
    /// click handler needs (a category id, a command id) - simpler than
    /// subclassing `HoverHighlightView` per row kind for this small a UI.
    private var rowCategoryIDs: [ObjectIdentifier: String] = [:]
    private var rowCommandIDs: [ObjectIdentifier: String] = [:]

    private func renderLeftPanel() {
        clearStack(leftPanelStack)
        rowCategoryIDs.removeAll()
        rowCommandIDs.removeAll()

        leftPanelStack.addArrangedSubview(addCommandButton())
        appendDividerToLeftPanel()

        if !searchQuery.trimmingCharacters(in: .whitespaces).isEmpty {
            renderSearchResults()
            return
        }

        // One renderer for both states now - `renderBrowseList` reads
        // `leftPanelState` itself to decide whether to append a selected
        // category's command list under the Categories panel.
        renderBrowseList()
    }

    private func addCommandButton() -> NSView {
        let button = HelmButton(title: "+ Add Command", variant: .secondary, target: self, action: #selector(addCommandClicked))
        button.controlSize = .small
        button.translatesAutoresizingMaskIntoConstraints = false
        return button
    }

    private func renderSearchResults() {
        appendToLeftPanel(mutedHeaderLabel("RESULTS"))
        let results = store.search(query: searchQuery)
        if results.isEmpty {
            let empty = NSTextField(labelWithString: "No matching commands.")
            empty.font = .systemFont(ofSize: 11.5)
            empty.textColor = HelmTheme.mutedInk(theme)
            appendToLeftPanel(empty)
            return
        }
        for command in results {
            let row = leftPanelRow(text: command.name, isSelected: command.id == selectedCommandID, action: #selector(searchResultRowClicked(_:)))
            rowCommandIDs[ObjectIdentifier(row)] = command.id
            appendToLeftPanel(row)
        }
    }

    /// The left column, in both states.
    ///
    /// **The Categories overview never goes away.** As shipped this was a
    /// drill-down: picking a category replaced the whole column with a
    /// "\u{2039} Kubernetes" back row plus that category's commands, so the
    /// other categories - and Favorites and Recently used - were gone until
    /// the captain navigated back. The prototype
    /// (`10-proposed-devops-commands.png`) keeps a "Categories" panel with a
    /// per-category count above the selected category's own list, which is
    /// both what the captain asked for and strictly less navigation. So the
    /// selected category's commands are now *appended* below the same list
    /// the browse state already renders, with the active category
    /// highlighted; nothing is ever hidden, and the back row is gone because
    /// there is no longer anywhere to go back from.
    private func renderBrowseList() {
        let favorites = store.favoriteCommands()
        if !favorites.isEmpty {
            appendToLeftPanel(mutedHeaderLabel("\u{2605} FAVORITES"))
            for command in favorites {
                let row = leftPanelRow(text: command.name, isSelected: command.id == selectedCommandID, action: #selector(favoriteRowClicked(_:)))
                rowCommandIDs[ObjectIdentifier(row)] = command.id
                appendToLeftPanel(row)
            }
            appendDividerToLeftPanel()
        }

        let recent = store.recentlyUsedCommands(limit: 5)
        if !recent.isEmpty {
            appendToLeftPanel(mutedHeaderLabel("\u{1F551} RECENTLY USED"))
            for command in recent {
                let row = leftPanelRow(text: command.name, isSelected: command.id == selectedCommandID, action: #selector(recentRowClicked(_:)))
                rowCommandIDs[ObjectIdentifier(row)] = command.id
                appendToLeftPanel(row)
            }
            appendDividerToLeftPanel()
        }

        var selectedCategoryID: String?
        if case .category(let id) = leftPanelState { selectedCategoryID = id }

        appendToLeftPanel(mutedHeaderLabel("CATEGORIES"))
        for (info, commands) in store.commandsByCategory() where !commands.isEmpty {
            let row = leftPanelRow(text: info.displayName, trailing: "\(commands.count)",
                                   isSelected: info.id == selectedCategoryID,
                                   action: #selector(categoryRowClicked(_:)))
            rowCategoryIDs[ObjectIdentifier(row)] = info.id
            appendToLeftPanel(row)
        }

        if let selectedCategoryID {
            appendDividerToLeftPanel()
            renderCategoryCommandList(selectedCategoryID)
        }

        appendDividerToLeftPanel()
        let workflowsRow = NSTextField(labelWithString: "\u{1F4D6} Workflows (Docs \u{2192} Runbooks)")
        workflowsRow.font = .systemFont(ofSize: 11.5)
        workflowsRow.textColor = HelmTheme.mutedInk(theme)
        workflowsRow.toolTip = "Multi-step command workflows live in Docs \u{2192} Runbooks - use a command's own \u{201C}+ Workflow\u{201D} button to add it as a step."
        appendToLeftPanel(workflowsRow)
    }

    /// The selected category's own command list, rendered *below* the
    /// Categories panel (see `renderBrowseList`). Headed by the category's
    /// name, the same way the prototype's second left-hand card is - not by a
    /// "\u{2039} back" row, which no longer has anything to go back to.
    private func renderCategoryCommandList(_ categoryID: String) {
        appendToLeftPanel(mutedHeaderLabel(CommandLibraryCategory.info(for: categoryID).displayName.uppercased()))

        let commandsInCategory = store.commandsByCategory().first { $0.info.id == categoryID }?.commands ?? []
        for command in commandsInCategory {
            let row = leftPanelRow(text: command.name, isSelected: command.id == selectedCommandID, action: #selector(categoryCommandRowClicked(_:)))
            rowCommandIDs[ObjectIdentifier(row)] = command.id
            appendToLeftPanel(row)
        }
    }

    private func divider() -> NSView {
        let d = NSView()
        d.wantsLayer = true
        d.layer?.backgroundColor = HelmTheme.nsColor(theme.chromeLineHex).withAlphaComponent(0.5).cgColor
        d.translatesAutoresizingMaskIntoConstraints = false
        d.heightAnchor.constraint(equalToConstant: 1).isActive = true
        return d
    }

    // MARK: Row click handlers

    @objc private func categoryRowClicked(_ sender: NSClickGestureRecognizer) {
        guard let view = sender.view, let categoryID = rowCategoryIDs[ObjectIdentifier(view)] else { return }
        // Clicking the already-open category closes it again, so the column
        // can be collapsed back to just the Categories overview without a
        // separate back row.
        if case .category(categoryID) = leftPanelState {
            leftPanelState = .browse
        } else {
            leftPanelState = .category(categoryID)
        }
        render()
    }

    @objc private func favoriteRowClicked(_ sender: NSClickGestureRecognizer) { selectCommandFromRow(sender) }
    @objc private func recentRowClicked(_ sender: NSClickGestureRecognizer) { selectCommandFromRow(sender) }
    @objc private func categoryCommandRowClicked(_ sender: NSClickGestureRecognizer) { selectCommandFromRow(sender) }
    @objc private func searchResultRowClicked(_ sender: NSClickGestureRecognizer) { selectCommandFromRow(sender) }

    private func selectCommandFromRow(_ sender: NSClickGestureRecognizer) {
        guard let view = sender.view, let commandID = rowCommandIDs[ObjectIdentifier(view)] else { return }
        selectCommand(id: commandID)
    }

    private func selectCommand(id: String) {
        guard selectedCommandID != id else { return }
        selectedCommandID = id
        paramValues = [:]
        render()
    }

    @objc private func searchChanged() {
        searchQuery = searchField.stringValue
        renderLeftPanel()
    }

    // MARK: Detail pane

    private func renderDetail(for command: DevOpsCommand) {
        emptyDetailState.isHidden = true
        detailContentContainer.isHidden = false

        detailNameLabel.stringValue = command.name
        ToolRowLayout.pill(text: command.risk.displayName, colorHex: command.risk.tint.hex(in: theme), into: detailRiskPill, label: detailRiskPillLabel, theme: theme)

        var metaParts = [command.description]
        var location = command.category.isEmpty ? "" : CommandLibraryCategory.info(for: command.category).displayName
        if let sub = command.subcategory, !sub.isEmpty { location += " / \(sub.capitalized)" }
        if !location.isEmpty { metaParts.append(location) }
        if !command.tags.isEmpty { metaParts.append(command.tags.joined(separator: ", ")) }
        detailMetaLabel.stringValue = metaParts.joined(separator: " \u{00B7} ")

        rebuildParamControls(for: command)
        updateCommandPreview(for: command)

        refreshFavoriteButton()
    }

    /// Flips the Favorite button's title for the current selection. Its amber
    /// colour is `HelmButton`'s own `tint` now, re-derived on every theme
    /// change by the button itself, so this no longer has to know the theme.
    private func refreshFavoriteButton() {
        let isFavorite = selectedCommandID.map(store.isFavorite) ?? false
        // The star is an SF Symbol on the button now rather than a literal
        // \u{2605}/\u{2606} glyph baked into the title, so filled-vs-outline
        // carries the state and the label stays one word.
        detailFavoriteButton.title = isFavorite ? "Favorited" : "Favorite"
        detailFavoriteButton.symbolName = isFavorite ? "star.fill" : "star"
    }

    private func rebuildParamControls(for command: DevOpsCommand) {
        clearStack(detailParamsStack)
        paramControls.removeAll()

        let params = command.effectiveParameters
        guard !params.isEmpty else { return }
        for chunk in params.chunked(into: 3) {
            let row = NSStackView(views: chunk.map { paramBlock(for: $0, command: command) })
            row.orientation = .horizontal
            row.distribution = .fillEqually
            row.spacing = 12
            row.alignment = .top
            row.translatesAutoresizingMaskIntoConstraints = false
            detailParamsStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: detailParamsStack.widthAnchor).isActive = true
        }
    }

    private func paramBlock(for param: CommandParameter, command: DevOpsCommand) -> NSView {
        let label = NSTextField(labelWithString: param.label.uppercased())
        label.font = ShiftFont.mono(9.5)
        label.textColor = HelmTheme.mutedInk(theme)

        let control: NSControl
        switch param.kind {
        case .boolean:
            let checkbox = NSButton(checkboxWithTitle: "", target: self, action: #selector(paramValueChanged(_:)))
            checkbox.state = (paramValues[param.name] ?? param.defaultValue) == "true" ? .on : .off
            control = checkbox
        case .select:
            let popup = HelmPopUpButton()
            let options = store.config.options(forKey: param.configOptionsKey, fallback: param.options)
            popup.addItems(withTitles: options.isEmpty ? [param.defaultValue ?? ""] : options)
            if let current = paramValues[param.name] ?? param.defaultValue, popup.itemTitles.contains(current) {
                popup.selectItem(withTitle: current)
            }
            popup.target = self
            popup.action = #selector(paramValueChanged(_:))
            control = popup
        default:
            let field = NSTextField()
            field.stringValue = paramValues[param.name] ?? param.defaultValue ?? ""
            field.placeholderString = param.placeholder
            field.font = .systemFont(ofSize: 12)
            field.target = self
            field.action = #selector(paramValueChanged(_:))
            field.delegate = self
            control = field
        }
        control.translatesAutoresizingMaskIntoConstraints = false
        control.identifier = NSUserInterfaceItemIdentifier(param.name)
        paramControls[param.name] = control

        // A `.select` control auto-selects its first option and a checkbox
        // starts at a real on/off state the instant it's created - neither
        // fires its `action`, so `paramValues` would otherwise stay empty for
        // that parameter until the captain actually touches the control,
        // leaving the generated-command preview showing a bare unfilled
        // `{{token}}` even though the control on screen already shows a real
        // selected value. Seed `paramValues` from whatever the control
        // actually displays right after building it, once, so the preview
        // and the visible control state never disagree.
        if paramValues[param.name] == nil {
            switch control {
            case let popup as NSPopUpButton: paramValues[param.name] = popup.titleOfSelectedItem ?? ""
            case let checkbox as NSButton: paramValues[param.name] = checkbox.state == .on ? "true" : "false"
            case let field as NSTextField: paramValues[param.name] = field.stringValue
            default: break
            }
        }

        let stack = NSStackView(views: [label, control])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 3
        stack.translatesAutoresizingMaskIntoConstraints = false
        control.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        return stack
    }

    @objc private func paramValueChanged(_ sender: NSControl) {
        guard let name = sender.identifier?.rawValue else { return }
        // Order matters: `NSPopUpButton` is itself an `NSButton` subclass, so
        // it must be checked before the plain-checkbox case.
        if let popup = sender as? NSPopUpButton {
            paramValues[name] = popup.titleOfSelectedItem ?? ""
        } else if let checkbox = sender as? NSButton {
            paramValues[name] = checkbox.state == .on ? "true" : "false"
        } else if let field = sender as? NSTextField {
            paramValues[name] = field.stringValue
        }
        guard let id = selectedCommandID, let command = store.command(id: id) else { return }
        updateCommandPreview(for: command)
    }

    private func updateCommandPreview(for command: DevOpsCommand) {
        detailCommandLabel.attributedStringValue = Self.attributedGeneratedCommand(for: command, values: paramValues, theme: theme)
    }

    /// Highlights every substituted parameter value in the accent color,
    /// matching the mockup's own highlighted-token treatment - plain literal
    /// text renders in the box's normal ink color.
    static func attributedGeneratedCommand(for command: DevOpsCommand, values: [String: String], theme: HelmTheme) -> NSAttributedString {
        let ink = HelmTheme.nsColor(theme.chromeInkHex)
        let accent = HelmTheme.nsColor(theme.accentHex)
        let font = ShiftFont.mono(12)
        let result = NSMutableAttributedString()
        let params = Dictionary(uniqueKeysWithValues: command.effectiveParameters.map { ($0.name, $0) })

        guard let regex = try? NSRegularExpression(pattern: "\\{\\{\\s*([A-Za-z0-9_]+)\\s*\\}\\}") else {
            return NSAttributedString(string: command.commandTemplate, attributes: [.font: font, .foregroundColor: ink])
        }
        let full = command.commandTemplate
        let nsRange = NSRange(full.startIndex..., in: full)
        var lastEnd = full.startIndex
        regex.enumerateMatches(in: full, range: nsRange) { match, _, _ in
            guard let match, let wholeRange = Range(match.range, in: full), let tokenRange = Range(match.range(at: 1), in: full) else { return }
            if lastEnd < wholeRange.lowerBound {
                result.append(NSAttributedString(string: String(full[lastEnd..<wholeRange.lowerBound]), attributes: [.font: font, .foregroundColor: ink]))
            }
            let token = String(full[tokenRange])
            let param = params[token]
            let replacement = values[token]?.isEmpty == false ? values[token]! : (param?.defaultValue ?? "{{\(token)}}")
            result.append(NSAttributedString(string: replacement, attributes: [.font: NSFont.monospacedSystemFont(ofSize: 12, weight: .semibold), .foregroundColor: accent]))
            lastEnd = wholeRange.upperBound
        }
        if lastEnd < full.endIndex {
            result.append(NSAttributedString(string: String(full[lastEnd...]), attributes: [.font: font, .foregroundColor: ink]))
        }
        return result
    }

    // MARK: Actions

    @objc private func copyClicked() {
        guard let id = selectedCommandID, let command = store.command(id: id) else { return }
        let generated = command.generatedCommand(values: paramValues)
        confirmIfNeeded(for: command, generatedText: generated, actionVerb: "copy") { [weak self] in
            guard let self else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(generated, forType: .string)
            self.store.recordUsage(id)
            Toast.show(in: self.view, message: "Command copied")
        }
    }

    @objc private func sendToTerminalClicked() {
        guard let id = selectedCommandID, let command = store.command(id: id) else { return }
        let generated = command.generatedCommand(values: paramValues)
        confirmIfNeeded(for: command, generatedText: generated, actionVerb: "send to the terminal") { [weak self] in
            guard let self else { return }
            self.store.recordUsage(id)
            self.onSendToTerminal?(generated)
            Toast.show(in: self.view, message: "Sent to terminal")
        }
    }

    @objc private func favoriteClicked() {
        guard let id = selectedCommandID else { return }
        store.toggleFavorite(id)
        render()
    }

    @objc private func addCommandClicked() {
        let editor = CommandEditorController(editingID: nil, prefill: nil, config: store.config)
        editor.onSave = { [weak self] name, description, category, subcategory, template, parameters, tags, risk in
            guard let self else { return }
            let created = self.store.createCommand(
                name: name, description: description, category: category, subcategory: subcategory,
                commandTemplate: template, parameters: parameters, tags: tags, risk: risk
            )
            self.selectedCommandID = created.id
            self.paramValues = [:]
            self.render()
            Toast.show(in: self.view, message: "Command created")
        }
        onPresentEditor?(editor)
    }

    @objc private func editClicked() {
        guard let id = selectedCommandID, let command = store.command(id: id) else { return }
        let editor = CommandEditorController(editingID: id, prefill: command, config: store.config)
        editor.onSave = { [weak self] name, description, category, subcategory, template, parameters, tags, risk in
            guard let self else { return }
            guard let updated = self.store.updateCommand(
                id: id, name: name, description: description, category: category, subcategory: subcategory,
                commandTemplate: template, parameters: parameters, tags: tags, risk: risk
            ) else { return }
            self.selectedCommandID = updated.id
            self.paramValues = [:]
            self.render()
            Toast.show(in: self.view, message: "Command saved")
        }
        onPresentEditor?(editor)
    }

    @objc private func duplicateClicked() {
        guard let id = selectedCommandID, let duplicate = store.duplicateCommand(id: id) else { return }
        selectedCommandID = duplicate.id
        paramValues = [:]
        render()
        Toast.show(in: view, message: "Duplicated as \u{201C}\(duplicate.name)\u{201D}")
    }

    @objc private func workflowClicked(_ sender: NSButton) {
        guard let id = selectedCommandID, let command = store.command(id: id) else { return }
        let generated = command.generatedCommand(values: paramValues)
        let menu = NSMenu()
        menu.addItem(withTitle: "New Runbook\u{2026}", action: #selector(createNewWorkflowRunbook), keyEquivalent: "")
        let existing = runbookStore.listRunbooks()
        if !existing.isEmpty {
            menu.addItem(.separator())
            for runbook in existing {
                let item = NSMenuItem(title: runbook.title, action: #selector(appendToExistingRunbook(_:)), keyEquivalent: "")
                item.representedObject = runbook.id
                menu.addItem(item)
            }
        }
        pendingWorkflowCommand = (command, generated)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height), in: sender)
    }

    /// Stashed by `workflowClicked` just before the menu opens, since an
    /// `NSMenuItem` action has no way to carry extra context beyond
    /// `representedObject` (already used here for the target runbook's id).
    private var pendingWorkflowCommand: (command: DevOpsCommand, generatedText: String)?

    @objc private func createNewWorkflowRunbook() {
        guard let (command, generatedText) = pendingWorkflowCommand else { return }
        let title = "\(command.name) Workflow"
        let content = CommandLibraryWorkflow.newRunbookContent(title: title, command: command, generatedText: generatedText)
        let runbook = runbookStore.createRunbook(title: title, content: content)
        Toast.show(in: view, message: "Created workflow \u{201C}\(runbook.title)\u{201D} in Docs \u{2192} Runbooks")
        pendingWorkflowCommand = nil
    }

    @objc private func appendToExistingRunbook(_ sender: NSMenuItem) {
        guard let (command, generatedText) = pendingWorkflowCommand, let runbookID = sender.representedObject as? String,
              let runbook = runbookStore.listRunbooks().first(where: { $0.id == runbookID }) else { return }
        let updatedContent = CommandLibraryWorkflow.appending(command: command, generatedText: generatedText, to: runbook.content)
        runbookStore.updateRunbook(id: runbook.id, content: updatedContent)
        Toast.show(in: view, message: "Added to \u{201C}\(runbook.title)\u{201D}")
        pendingWorkflowCommand = nil
    }

    // MARK: Destructive-confirmation gate

    /// Both Copy and Send to Terminal route through this - `readOnly` never
    /// interrupts, `potentiallyDisruptive` gets a lighter, still-dismissible
    /// confirmation, `destructive` gets the full "this can modify or delete
    /// infrastructure" warning (matching the design doc's mockup). There is
    /// no silent path from a risky command to the clipboard or a terminal.
    private func confirmIfNeeded(for command: DevOpsCommand, generatedText: String, actionVerb: String, proceed: @escaping () -> Void) {
        switch command.risk {
        case .readOnly:
            proceed()
        case .potentiallyDisruptive:
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Potentially disruptive command"
            alert.informativeText = "This command can change live state:\n\n\(generatedText)"
            alert.addButton(withTitle: "Cancel")
            alert.addButton(withTitle: "Proceed")
            guard alert.runModal() == .alertSecondButtonReturn else { return }
            proceed()
        case .destructive:
            let alert = NSAlert()
            alert.alertStyle = .critical
            alert.messageText = "\u{26A0}\u{FE0F} Destructive command"
            alert.informativeText = "This command can modify or delete infrastructure:\n\n\(generatedText)"
            alert.addButton(withTitle: "Cancel")
            alert.addButton(withTitle: "\(actionVerb == "copy" ? "Copy" : "Send") Anyway")
            guard alert.runModal() == .alertSecondButtonReturn else { return }
            proceed()
        }
    }
}

extension CommandLibraryPageView: NSTextFieldDelegate {
    func controlTextDidChange(_ obj: Notification) {
        guard let field = obj.object as? NSTextField else { return }
        if field === searchField {
            searchChanged()
            return
        }
        paramValueChanged(field)
    }
}
