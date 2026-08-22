// Manjesh Grand Line - native macOS app.
//
// Global search (phase 5, cockpit-shift-power-features): a command-palette
// overlay searching Shift's real tasks, follow-ups, and projects (notes were
// dropped as a separate thread before this phase - see AGENTS.md - so there
// is nothing to search there yet). Matches the captain-reviewed mockup's
// palette shape (data/cockpit-shift-ui-polish/reviewed-mockup-reference.html,
// `.palette-overlay`/`.palette-row`) - a borderless input over a results
// list, `kind` label + title per row, arrow keys to move, Return to select.
//
// The mockup's own shortcut is ⌘K, but this app already binds ⌘K to
// "Find in Terminal" (`AppShellController.activateConsoleFind`, predating
// this phase) - see main.swift's Edit menu comment. This phase uses ⌘⇧P
// instead (wired in the Shift menu as "Search Shift…") rather than stealing
// an already-shipped shortcut.
//
// Built as a small `NSStackView` list rather than an `NSTableView` - unlike
// the task/follow-up lists (which learned the hard way, via `DiffResultView`'s
// history, that a growing list needs a table view), a captain's real task +
// follow-up + project count is nowhere near the scale that lesson was about,
// so the simpler stack-view rebuild is the right amount of engineering here.

import AppKit

struct ShiftSearchResult {
    enum Kind: String { case task = "Task", followUp = "Follow-up", project = "Project" }
    let kind: Kind
    let id: String
    let title: String
    let subtitle: String
}

enum ShiftSearchIndex {
    /// Every currently-searchable item, or (if `query` is non-empty) just
    /// the ones whose title/name contains it, case-insensitively. Active
    /// tasks only (a completed task isn't editable through `openTask`'s
    /// sheet - see `ShiftController.openTask`'s header), pending and done
    /// follow-ups alike, and every project.
    static func search(store: ShiftStore, query: String) -> [ShiftSearchResult] {
        var all: [ShiftSearchResult] = []
        for task in store.activeTasks {
            let projectName = task.projectID.flatMap { pid in store.projects.first(where: { $0.id == pid })?.name }
            all.append(ShiftSearchResult(kind: .task, id: task.id, title: task.title, subtitle: projectName ?? "Task"))
        }
        for followUp in store.followUps {
            all.append(ShiftSearchResult(kind: .followUp, id: followUp.id, title: followUp.title, subtitle: "Follow-up"))
        }
        for project in store.projects {
            all.append(ShiftSearchResult(kind: .project, id: project.id, title: project.name, subtitle: "Project"))
        }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return all }
        let needle = trimmed.lowercased()
        return all.filter { $0.title.lowercased().contains(needle) }
    }
}

/// The palette itself - a small, non-activating, key-accepting panel so
/// typing works immediately without stealing focus from (or hiding) the main
/// window behind it.
final class ShiftSearchController: NSWindowController, NSTextFieldDelegate {
    private let store: ShiftStore
    var onSelectTask: ((String) -> Void)?
    var onSelectFollowUp: ((String) -> Void)?
    var onSelectProject: ((String) -> Void)?

    private let searchField = NSTextField()
    private let resultsStack = NSStackView()
    private let scroll = NSScrollView()
    private var results: [ShiftSearchResult] = []
    private var selectedIndex = 0
    private var rowViews: [ShiftSearchRowView] = []

    init(store: ShiftStore) {
        self.store = store
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 60),
            styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel, .resizable],
            backing: .buffered, defer: false
        )
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        super.init(window: panel)

        buildUI(in: panel)
        _ = panel.followHelmTheme()
        ThemeManager.shared.observe { [weak self] theme in self?.applyTheme(theme) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    private func buildUI(in panel: NSPanel) {
        guard let content = panel.contentView else { return }

        searchField.placeholderString = "Search tasks, follow-ups, projects\u{2026}"
        searchField.font = .systemFont(ofSize: 16)
        searchField.isBordered = false
        searchField.focusRingType = .none
        searchField.drawsBackground = false
        searchField.delegate = self
        searchField.translatesAutoresizingMaskIntoConstraints = false

        let divider = NSView()
        divider.wantsLayer = true
        divider.translatesAutoresizingMaskIntoConstraints = false

        resultsStack.orientation = .vertical
        resultsStack.alignment = .leading
        resultsStack.spacing = 0
        resultsStack.translatesAutoresizingMaskIntoConstraints = false

        scroll.documentView = resultsStack
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false

        content.addSubview(searchField)
        content.addSubview(divider)
        content.addSubview(scroll)
        NSLayoutConstraint.activate([
            searchField.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 18),
            searchField.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -18),
            searchField.topAnchor.constraint(equalTo: content.topAnchor, constant: 14),
            searchField.heightAnchor.constraint(equalToConstant: 26),

            divider.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            divider.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 14),
            divider.heightAnchor.constraint(equalToConstant: 1),

            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: divider.bottomAnchor),
            scroll.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            resultsStack.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
        ])
        self.dividerRef = divider
    }

    private var dividerRef: NSView?

    /// Centers the palette near the top of the main window, Spotlight-style,
    /// and focuses the search field so typing works immediately.
    func present() {
        // GL-09: this palette is a `.floating` `NSPanel`, so it renders above
        // the lock overlay (which only covers the main window's own view tree)
        // and its results disclose real task/runbook titles. A locked app does
        // not open it.
        guard AppLockGate.shared.allows(.quickCapture) else {
            AppLog.lifecycle.info("search palette refused - app is locked (GL-09)")
            return
        }
        guard let window else { return }
        searchField.stringValue = ""
        reload(query: "")
        if let main = NSApp.mainWindow ?? NSApp.windows.first(where: { $0.isVisible }) {
            let mainFrame = main.frame
            let x = mainFrame.midX - window.frame.width / 2
            let y = mainFrame.maxY - 120
            window.setFrameTopLeftPoint(NSPoint(x: x, y: max(y, mainFrame.minY + 40)))
        } else {
            window.center()
        }
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(searchField)
    }

    // MARK: NSTextFieldDelegate

    func controlTextDidChange(_ obj: Notification) {
        reload(query: searchField.stringValue)
    }

    /// Arrow keys move the selection, Return picks the current row, Escape
    /// dismisses - the field editor forwards its command keys here rather
    /// than through a plain `keyDown` override, since AppKit routes an
    /// editing text field's key events to the shared field editor, not the
    /// `NSTextField` itself.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.moveDown(_:)):
            moveSelection(by: 1)
            return true
        case #selector(NSResponder.moveUp(_:)):
            moveSelection(by: -1)
            return true
        case #selector(NSResponder.insertNewline(_:)):
            selectCurrent()
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            dismiss()
            return true
        default:
            return false
        }
    }

    private func reload(query: String) {
        results = ShiftSearchIndex.search(store: store, query: query)
        selectedIndex = 0
        rebuildRows()
        resizeToFit()
    }

    private func rebuildRows() {
        for v in resultsStack.arrangedSubviews {
            resultsStack.removeArrangedSubview(v)
            v.removeFromSuperview()
        }
        rowViews.removeAll()
        guard !results.isEmpty else {
            let empty = NSTextField(labelWithString: "No matches.")
            empty.font = .systemFont(ofSize: 13)
            empty.textColor = HelmTheme.mutedInk(ThemeManager.shared.theme)
            empty.translatesAutoresizingMaskIntoConstraints = false
            let padded = NSView()
            padded.translatesAutoresizingMaskIntoConstraints = false
            padded.addSubview(empty)
            NSLayoutConstraint.activate([
                empty.leadingAnchor.constraint(equalTo: padded.leadingAnchor, constant: 18),
                empty.topAnchor.constraint(equalTo: padded.topAnchor, constant: 14),
                empty.bottomAnchor.constraint(equalTo: padded.bottomAnchor, constant: -14),
            ])
            resultsStack.addArrangedSubview(padded)
            padded.widthAnchor.constraint(equalTo: resultsStack.widthAnchor).isActive = true
            return
        }
        for (index, result) in results.enumerated() {
            let row = ShiftSearchRowView()
            row.configure(result: result, theme: ThemeManager.shared.theme, selected: index == selectedIndex)
            row.onClick = { [weak self] in
                self?.selectedIndex = index
                self?.selectCurrent()
            }
            row.translatesAutoresizingMaskIntoConstraints = false
            resultsStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: resultsStack.widthAnchor).isActive = true
            rowViews.append(row)
        }
    }

    private func resizeToFit() {
        guard let window else { return }
        let rowHeight: CGFloat = results.isEmpty ? 46 : 40
        let count = max(results.count, 1)
        let resultsHeight = min(CGFloat(count) * rowHeight, 320)
        let total = 61 + resultsHeight // search field + divider + padding
        let frame = window.frame
        window.setFrame(NSRect(x: frame.minX, y: frame.maxY - total, width: frame.width, height: total), display: true)
    }

    private func moveSelection(by delta: Int) {
        guard !results.isEmpty else { return }
        selectedIndex = max(0, min(results.count - 1, selectedIndex + delta))
        for (index, row) in rowViews.enumerated() {
            row.setSelected(index == selectedIndex)
        }
    }

    private func selectCurrent() {
        guard selectedIndex >= 0, selectedIndex < results.count else { return }
        let result = results[selectedIndex]
        window?.orderOut(nil)
        switch result.kind {
        case .task: onSelectTask?(result.id)
        case .followUp: onSelectFollowUp?(result.id)
        case .project: onSelectProject?(result.id)
        }
    }

    func dismiss() {
        window?.orderOut(nil)
    }

    private func applyTheme(_ theme: HelmTheme) {
        window?.contentView?.layer?.backgroundColor = HelmTheme.nsColor(theme.chromeBackgroundHex).cgColor
        searchField.textColor = HelmTheme.nsColor(theme.chromeInkHex)
        dividerRef?.wantsLayer = true
        dividerRef?.layer?.backgroundColor = HelmTheme.nsColor(theme.chromeLineHex).withAlphaComponent(0.6).cgColor
        for row in rowViews { row.applyTheme(theme) }
    }
}

/// A single search-result row: a small mono "kind" label plus the title,
/// matching the mockup's `.palette-row` (`.kind` + text) shape.
private final class ShiftSearchRowView: NSView {
    private let kindLabel = NSTextField(labelWithString: "")
    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let background = HoverHighlightView()
    var onClick: (() -> Void)?
    private var isSelected = false
    private var theme: HelmTheme = ThemeManager.shared.theme

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        background.cornerRadius = 6
        background.translatesAutoresizingMaskIntoConstraints = false
        addSubview(background)
        NSLayoutConstraint.activate([
            background.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            background.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            background.topAnchor.constraint(equalTo: topAnchor, constant: 1),
            background.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -1),
        ])

        kindLabel.font = ShiftFont.mono(9.5, weight: .semibold)
        kindLabel.translatesAutoresizingMaskIntoConstraints = false
        kindLabel.setContentHuggingPriority(.required, for: .horizontal)
        kindLabel.widthAnchor.constraint(equalToConstant: 64).isActive = true

        titleLabel.font = .systemFont(ofSize: 13)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        subtitleLabel.font = .systemFont(ofSize: 11)
        subtitleLabel.setContentHuggingPriority(.required, for: .horizontal)

        let row = NSStackView(views: [kindLabel, titleLabel, subtitleLabel])
        row.orientation = .horizontal
        row.spacing = 10
        row.alignment = .firstBaseline
        row.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 12),
            row.trailingAnchor.constraint(lessThanOrEqualTo: background.trailingAnchor, constant: -12),
            row.topAnchor.constraint(equalTo: background.topAnchor, constant: 9),
            row.bottomAnchor.constraint(equalTo: background.bottomAnchor, constant: -9),
        ])

        let click = NSClickGestureRecognizer(target: self, action: #selector(clicked))
        background.addGestureRecognizer(click)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    @objc private func clicked() { onClick?() }

    func configure(result: ShiftSearchResult, theme: HelmTheme, selected: Bool) {
        self.theme = theme
        kindLabel.stringValue = result.kind.rawValue.uppercased()
        titleLabel.stringValue = result.title
        subtitleLabel.stringValue = result.subtitle
        setSelected(selected)
        applyTheme(theme)
    }

    func setSelected(_ selected: Bool) {
        isSelected = selected
        applyTheme(theme)
    }

    func applyTheme(_ theme: HelmTheme) {
        self.theme = theme
        let muted = HelmTheme.mutedInk(theme)
        let ink = HelmTheme.nsColor(theme.chromeInkHex)
        let line = HelmTheme.nsColor(theme.chromeLineHex)
        kindLabel.textColor = muted
        titleLabel.textColor = ink
        subtitleLabel.textColor = muted
        background.normalColor = isSelected ? line.withAlphaComponent(0.3) : .clear
        background.hoverColor = line.withAlphaComponent(0.3)
    }
}
