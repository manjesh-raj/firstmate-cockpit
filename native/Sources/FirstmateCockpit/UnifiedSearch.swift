// Manjesh Grand Line - native macOS app.
//
// Phase 4 (final phase) of "Knowledge and speed" (fm/grandline-unified-search):
// expands the app's global `⌘K` shortcut from its prior single job
// (`AppShellController.activateConsoleFind` - in-terminal find) into a real
// "search everything" palette, mirroring `ShiftSearchController`'s own small
// `NSPanel`-based shape (borderless input over a results list, arrow keys/
// Return/Escape) - a second, similar palette for a different content domain,
// not a third distinct UI pattern. See AGENTS.md's "Knowledge" section for
// the full phase history.
//
// The actual search backend is phase 1's real `DocsKnowledgeSearch.search` -
// this file does not reimplement matching/snippeting, only wraps its result
// type for the palette's row shape and owns the palette UI itself.
//
// Terminal command history was investigated as a fourth search domain (per
// the phase-4 brief) and deliberately left out: the only structured record of
// "commands the captain has actually run" is Block View's `TerminalBlockTracker`,
// which is off by default and only active on hosts with `Host.blockViewOptIn`
// set (see AGENTS.md's "Block view" section - still an early "Stage 0"
// rollout). That's not a safe, already-real, app-wide data source to search
// against - most captains have it off entirely, and expanding its scope to
// back a search feature is explicitly out of scope for this task. Session
// logging is opt-in, unstructured raw terminal bytes, not a list of commands.
// So this palette searches Runbooks + Postmortems only; terminal-history
// search stays deferred until Block View matures past its current rollout
// stage.

import AppKit

struct UnifiedSearchResult {
    enum Kind: String { case runbook = "Runbook", postmortem = "Postmortem" }
    let kind: Kind
    let id: String
    let title: String
    let snippet: String
}

enum UnifiedSearchIndex {
    /// Thin wrapper over `DocsKnowledgeSearch.search` (`DocsRunbookData.swift`)
    /// - the same real search logic the Docs page's own in-page Search tab
    /// already uses, never a second index/matching implementation.
    static func search(store: DocsRunbookStore, query: String) -> [UnifiedSearchResult] {
        DocsKnowledgeSearch.search(query: query, store: store).map { result in
            let kind: UnifiedSearchResult.Kind = result.scope == .runbook ? .runbook : .postmortem
            return UnifiedSearchResult(kind: kind, id: result.runbook.id, title: result.runbook.title, snippet: result.snippet)
        }
    }
}

/// The palette itself - a small, non-activating, key-accepting panel so
/// typing works immediately without stealing focus from (or hiding) the main
/// window behind it. Structurally identical to `ShiftSearchController`
/// (`ShiftSearch.swift`); kept as its own type since the two search over
/// completely different stores/result shapes and `⌘⇧P` (Shift's own palette)
/// is deliberately left untouched and separate by this task's scope.
final class UnifiedSearchController: NSWindowController, NSTextFieldDelegate {
    private let store: DocsRunbookStore
    var onSelectRunbook: ((String) -> Void)?
    var onSelectPostmortem: ((String) -> Void)?

    private let searchField = NSTextField()
    private let resultsStack = NSStackView()
    private let scroll = NSScrollView()
    private var results: [UnifiedSearchResult] = []
    private var selectedIndex = 0
    private var rowViews: [UnifiedSearchRowView] = []
    // Fix (dismiss bug): a click anywhere outside the palette - on the main
    // window, or in another app entirely (the panel floats at `.floating`
    // level above everything) - should close it, same as Spotlight/any
    // command palette. Neither this class nor `ShiftSearchController` had
    // this before; a bare `NSPanel` (unlike `NSPopover`) has no built-in
    // outside-click dismissal, and nothing here previously installed a
    // monitor to fill that gap. A local monitor covers a click landing in a
    // different window of this same app; a global monitor covers a click in
    // a different app - mirrors `ShiftGlobalHotkey`'s established
    // local+global monitor pair (`ShiftQuickCapture.swift`), just for mouse
    // clicks instead of a hotkey.
    private var outsideClickMonitor: Any?
    private var globalOutsideClickMonitor: Any?

    init(store: DocsRunbookStore) {
        self.store = store
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 60),
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
        // Fix (theme bug): without this, the content view has no layer at
        // all until a descendant view (e.g. a result row's `HoverHighlightView`)
        // is added and forces layer-backing on its ancestor chain - which
        // hasn't happened yet the first time `applyTheme` runs (called
        // immediately by `ThemeManager.shared.observe` below, before
        // `present()` has ever built a row). That first call's
        // `contentView.layer?.backgroundColor = ...` silently no-ops against
        // a nil layer, so the palette renders as plain unthemed system gray
        // until some *later* theme change happens to re-run `applyTheme`
        // after rows exist. Setting `wantsLayer` here guarantees the layer
        // exists before `applyTheme` is ever called. See AGENTS.md's
        // `ThemeManager`/`HelmTheme` checklist, gotcha #8.
        content.wantsLayer = true

        searchField.placeholderString = "Search runbooks and postmortems\u{2026}"
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
        installOutsideClickMonitors()
    }

    private func installOutsideClickMonitors() {
        removeOutsideClickMonitors()
        outsideClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            if event.window !== self?.window { self?.dismiss() }
            return event
        }
        globalOutsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.dismiss()
        }
    }

    private func removeOutsideClickMonitors() {
        if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
        if let globalOutsideClickMonitor { NSEvent.removeMonitor(globalOutsideClickMonitor) }
        outsideClickMonitor = nil
        globalOutsideClickMonitor = nil
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
        results = UnifiedSearchIndex.search(store: store, query: query)
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
            let row = UnifiedSearchRowView()
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
        let rowHeight: CGFloat = results.isEmpty ? 46 : 48
        let count = max(results.count, 1)
        let resultsHeight = min(CGFloat(count) * rowHeight, 360)
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
        dismiss()
        switch result.kind {
        case .runbook: onSelectRunbook?(result.id)
        case .postmortem: onSelectPostmortem?(result.id)
        }
    }

    func dismiss() {
        window?.orderOut(nil)
        removeOutsideClickMonitors()
    }

    private func applyTheme(_ theme: HelmTheme) {
        window?.contentView?.layer?.backgroundColor = HelmTheme.nsColor(theme.chromeBackgroundHex).cgColor
        searchField.textColor = HelmTheme.nsColor(theme.chromeInkHex)
        dividerRef?.wantsLayer = true
        dividerRef?.layer?.backgroundColor = HelmTheme.nsColor(theme.chromeLineHex).withAlphaComponent(0.6).cgColor
        for row in rowViews { row.applyTheme(theme) }
    }
}

/// A single search-result row: a small mono "kind" label, the title, and a
/// muted excerpt snippet - matching `ShiftSearchRowView`'s kind+title shape,
/// with a second line for the snippet `DocsKnowledgeSearch` already computes.
private final class UnifiedSearchRowView: NSView {
    private let kindLabel = NSTextField(labelWithString: "")
    private let titleLabel = NSTextField(labelWithString: "")
    private let snippetLabel = NSTextField(labelWithString: "")
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

        kindLabel.font = .monospacedSystemFont(ofSize: 9.5, weight: .semibold)
        kindLabel.translatesAutoresizingMaskIntoConstraints = false
        kindLabel.setContentHuggingPriority(.required, for: .horizontal)
        kindLabel.widthAnchor.constraint(equalToConstant: 78).isActive = true

        titleLabel.font = .systemFont(ofSize: 13, weight: .medium)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let titleRow = NSStackView(views: [kindLabel, titleLabel])
        titleRow.orientation = .horizontal
        titleRow.spacing = 10
        titleRow.alignment = .firstBaseline
        titleRow.translatesAutoresizingMaskIntoConstraints = false

        snippetLabel.font = .systemFont(ofSize: 11)
        snippetLabel.lineBreakMode = .byTruncatingTail
        snippetLabel.translatesAutoresizingMaskIntoConstraints = false

        let column = NSStackView(views: [titleRow, snippetLabel])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 3
        column.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(column)
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 12),
            column.trailingAnchor.constraint(lessThanOrEqualTo: background.trailingAnchor, constant: -12),
            column.topAnchor.constraint(equalTo: background.topAnchor, constant: 7),
            column.bottomAnchor.constraint(equalTo: background.bottomAnchor, constant: -7),
        ])

        let click = NSClickGestureRecognizer(target: self, action: #selector(clicked))
        background.addGestureRecognizer(click)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    @objc private func clicked() { onClick?() }

    func configure(result: UnifiedSearchResult, theme: HelmTheme, selected: Bool) {
        self.theme = theme
        kindLabel.stringValue = result.kind.rawValue.uppercased()
        titleLabel.stringValue = result.title
        snippetLabel.stringValue = result.snippet
        snippetLabel.isHidden = result.snippet.isEmpty || result.snippet == result.title
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
        snippetLabel.textColor = muted
        background.normalColor = isSelected ? line.withAlphaComponent(0.3) : .clear
        background.hoverColor = line.withAlphaComponent(0.3)
    }
}
