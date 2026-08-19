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
// Only Copy and Favorite are wired to real behavior in this phase - Send to
// Terminal / Edit / Explain render as disabled buttons (matching the
// mockup's own row) since those are explicitly Phase 2/3 per the design
// doc's phasing table.

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
    private let emptyDetailState = ShiftEmptyStateView(symbol: "terminal", text: "Pick a command from the list\nto see its details here.")

    // Detail pane's live views (built once, mutated per-selection - see
    // `renderDetail(for:)`).
    private let detailNameLabel = NSTextField(labelWithString: "")
    private let detailRiskPill = NSView()
    private let detailRiskPillLabel = NSTextField(labelWithString: "")
    private let detailMetaLabel = NSTextField(wrappingLabelWithString: "")
    private let detailCommandBox = NSView()
    private let detailCommandLabel = NSTextField(wrappingLabelWithString: "")
    private let detailParamsStack = NSStackView()
    private let detailCopyButton = NSButton(title: "Copy", target: nil, action: nil)
    private let detailSendButton = NSButton(title: "Send to Terminal", target: nil, action: nil)
    private let detailEditButton = NSButton(title: "Edit", target: nil, action: nil)
    private let detailExplainButton = NSButton(title: "\u{2728} Explain", target: nil, action: nil)
    private let detailFavoriteButton = NSButton(title: "\u{2606} Favorite", target: nil, action: nil)
    private let detailContentContainer = NSView()

    /// Every live parameter input control, keyed by parameter name, for the
    /// currently-rendered command - read from on every keystroke/selection to
    /// regenerate the preview, and rebuilt fresh on every `renderDetail`.
    private var paramControls: [String: NSControl] = [:]

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
        columns.translatesAutoresizingMaskIntoConstraints = false
        leftPanel.widthAnchor.constraint(equalToConstant: 220).isActive = true
        leftPanel.setContentHuggingPriority(.required, for: .horizontal)
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
        searchField.font = .systemFont(ofSize: 12.5)
        searchField.target = self
        searchField.action = #selector(searchChanged)
        searchField.delegate = self
        searchField.translatesAutoresizingMaskIntoConstraints = false

        let inner = NSStackView(views: [searchIcon, searchField])
        inner.orientation = .horizontal
        inner.alignment = .centerY
        inner.spacing = 8
        inner.translatesAutoresizingMaskIntoConstraints = false

        searchRow.wantsLayer = true
        searchRow.layer?.cornerRadius = 8
        searchRow.translatesAutoresizingMaskIntoConstraints = false
        searchRow.addSubview(inner)
        NSLayoutConstraint.activate([
            inner.leadingAnchor.constraint(equalTo: searchRow.leadingAnchor, constant: 12),
            inner.trailingAnchor.constraint(equalTo: searchRow.trailingAnchor, constant: -12),
            inner.topAnchor.constraint(equalTo: searchRow.topAnchor, constant: 9),
            inner.bottomAnchor.constraint(equalTo: searchRow.bottomAnchor, constant: -9),
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
        detailNameLabel.font = ShiftFont.serif(17)
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

        let titleRow = NSStackView(views: [detailNameLabel, detailRiskPill])
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
        detailParamsStack.spacing = 10
        detailParamsStack.translatesAutoresizingMaskIntoConstraints = false

        for button in [detailSendButton, detailEditButton, detailExplainButton] {
            button.bezelStyle = .rounded
            button.controlSize = .small
            button.isEnabled = false
            button.toolTip = "Coming in a later phase"
            button.translatesAutoresizingMaskIntoConstraints = false
        }
        detailCopyButton.bezelStyle = .rounded
        detailCopyButton.controlSize = .small
        detailCopyButton.keyEquivalent = "c"
        detailCopyButton.keyEquivalentModifierMask = [.command]
        detailCopyButton.target = self
        detailCopyButton.action = #selector(copyClicked)
        detailCopyButton.translatesAutoresizingMaskIntoConstraints = false

        detailFavoriteButton.bezelStyle = .rounded
        detailFavoriteButton.controlSize = .small
        detailFavoriteButton.target = self
        detailFavoriteButton.action = #selector(favoriteClicked)
        detailFavoriteButton.translatesAutoresizingMaskIntoConstraints = false

        let buttonsSpacer = NSView()
        buttonsSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let buttonsRow = NSStackView(views: [detailCopyButton, detailSendButton, detailEditButton, detailExplainButton, buttonsSpacer, detailFavoriteButton])
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
        let accent = HelmTheme.nsColor(theme.accentHex)

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
        detailFavoriteButton.contentTintColor = accent

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

        if !searchQuery.trimmingCharacters(in: .whitespaces).isEmpty {
            renderSearchResults()
            return
        }

        switch leftPanelState {
        case .browse:
            renderBrowseList()
        case .category(let categoryID):
            renderCategoryCommandList(categoryID)
        }
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

    private func renderBrowseList() {
        let favorites = store.favoriteCommands()
        if !favorites.isEmpty {
            appendToLeftPanel(mutedHeaderLabel("\u{2605} FAVORITES"))
            for command in favorites {
                let row = leftPanelRow(text: command.name, isSelected: command.id == selectedCommandID, action: #selector(favoriteRowClicked(_:)))
                rowCommandIDs[ObjectIdentifier(row)] = command.id
                appendToLeftPanel(row)
            }
            appendToLeftPanel(divider())
        }

        for (info, commands) in store.commandsByCategory() where !commands.isEmpty {
            let row = leftPanelRow(text: info.displayName, trailing: "\(commands.count)", action: #selector(categoryRowClicked(_:)))
            rowCategoryIDs[ObjectIdentifier(row)] = info.id
            appendToLeftPanel(row)
        }

        appendToLeftPanel(divider())
        let workflowsRow = NSTextField(labelWithString: "\u{1F4D6} Workflows (Docs \u{2192} Runbooks)")
        workflowsRow.font = .systemFont(ofSize: 11.5)
        workflowsRow.textColor = HelmTheme.mutedInk(theme)
        workflowsRow.toolTip = "Multi-step command workflows live in Docs \u{2192} Runbooks - see AGENTS.md. Coming in a later phase."
        appendToLeftPanel(workflowsRow)
    }

    private func renderCategoryCommandList(_ categoryID: String) {
        let backRow = HoverHighlightView()
        backRow.cornerRadius = 6
        let backLabel = NSTextField(labelWithString: "\u{2039} \(CommandLibraryCategory.info(for: categoryID).displayName)")
        backLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        backLabel.translatesAutoresizingMaskIntoConstraints = false
        backRow.addSubview(backLabel)
        NSLayoutConstraint.activate([
            backLabel.leadingAnchor.constraint(equalTo: backRow.leadingAnchor, constant: 8),
            backLabel.trailingAnchor.constraint(equalTo: backRow.trailingAnchor, constant: -8),
            backLabel.topAnchor.constraint(equalTo: backRow.topAnchor, constant: 5),
            backLabel.bottomAnchor.constraint(equalTo: backRow.bottomAnchor, constant: -5),
        ])
        backLabel.textColor = HelmTheme.nsColor(theme.chromeInkHex)
        backRow.normalColor = .clear
        backRow.hoverColor = HelmTheme.nsColor(theme.chromeLineHex).withAlphaComponent(0.25)
        backRow.translatesAutoresizingMaskIntoConstraints = false
        backRow.addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(backToBrowseClicked)))
        appendToLeftPanel(backRow)
        appendToLeftPanel(divider())

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
        leftPanelState = .category(categoryID)
        render()
    }

    @objc private func backToBrowseClicked() {
        leftPanelState = .browse
        render()
    }

    @objc private func favoriteRowClicked(_ sender: NSClickGestureRecognizer) { selectCommandFromRow(sender) }
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
        ToolRowLayout.pill(text: command.risk.displayName, colorHex: command.risk.tint.hex(in: theme), into: detailRiskPill, label: detailRiskPillLabel)

        var metaParts = [command.description]
        var location = command.category.isEmpty ? "" : CommandLibraryCategory.info(for: command.category).displayName
        if let sub = command.subcategory, !sub.isEmpty { location += " / \(sub.capitalized)" }
        if !location.isEmpty { metaParts.append(location) }
        if !command.tags.isEmpty { metaParts.append(command.tags.joined(separator: ", ")) }
        detailMetaLabel.stringValue = metaParts.joined(separator: " \u{00B7} ")

        rebuildParamControls(for: command)
        updateCommandPreview(for: command)

        let isFavorite = store.isFavorite(command.id)
        detailFavoriteButton.title = isFavorite ? "\u{2605} Favorited" : "\u{2606} Favorite"
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
            row.spacing = 10
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
            let popup = NSPopUpButton()
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
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(generated, forType: .string)
        Toast.show(in: view, message: "Command copied")
    }

    @objc private func favoriteClicked() {
        guard let id = selectedCommandID else { return }
        store.toggleFavorite(id)
        render()
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
