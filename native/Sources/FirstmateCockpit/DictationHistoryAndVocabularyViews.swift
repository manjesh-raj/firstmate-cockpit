// Manjesh Grand Line - native macOS app.
//
// Dictation, phase 2 (fm/grandline-dictation-phase2): rendering for the
// transcription history list and the personal vocabulary chip row - split
// out of `DictationController.swift` to keep that file's existing
// status/shortcut sections readable.
//
// The history list is `NSTableView`-based (`DictationHistoryListView`), not a
// plain `NSStackView` of permanent rows - the same convention
// `ShiftListViews.swift`/`DiffResultView.swift` already established in this
// codebase, since a growing, unbounded-length history is exactly the shape
// that blew up into a multi-second layout pass once row counts hit the
// hundreds (see `DiffResultView.swift`'s header for the full measured
// writeup). An `NSTableView` only builds row views for what's actually
// visible, so this stays fast regardless of how many weeks of dictation
// history accumulate. The vocabulary chip row, by contrast, is a genuinely
// small, bounded list (a captain's personal vocabulary), so a plain
// frame-based flow layout (`ChipFlowView`) is fine there - no table needed.

import AppKit

// MARK: - History list

final class DictationHistoryListView: NSObject {
    let tableView = NSTableView()

    private var theme: HelmTheme = ThemeManager.shared.theme
    private var entries: [DictationHistoryEntry] = []

    private static let columnID = NSUserInterfaceItemIdentifier("dictationHistoryCol")
    private static let rowViewID = NSUserInterfaceItemIdentifier("dictationHistoryRow")
    private static let emptyViewID = NSUserInterfaceItemIdentifier("dictationHistoryEmpty")

    override init() {
        super.init()
        let column = NSTableColumn(identifier: Self.columnID)
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.backgroundColor = .clear
        tableView.selectionHighlightStyle = .none
        tableView.gridStyleMask = []
        tableView.intercellSpacing = NSSize(width: 0, height: 2)
        tableView.autoresizingMask = [.width]
        tableView.dataSource = self
        tableView.delegate = self
    }

    func setEntries(_ entries: [DictationHistoryEntry]) {
        self.entries = entries
        tableView.reloadData()
    }

    func applyTheme(_ theme: HelmTheme) {
        self.theme = theme
        tableView.reloadData()
    }
}

extension DictationHistoryListView: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { max(entries.count, 1) }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        entries.isEmpty ? 100 : 46
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard !entries.isEmpty else {
            let empty = (tableView.makeView(withIdentifier: Self.emptyViewID, owner: nil) as? ShiftEmptyStateView)
                ?? { let v = ShiftEmptyStateView(symbol: "waveform", text: "No dictations yet - hold the shortcut and speak."); v.identifier = Self.emptyViewID; return v }()
            empty.applyTheme(theme)
            return empty
        }
        let rowView = (tableView.makeView(withIdentifier: Self.rowViewID, owner: nil) as? DictationHistoryRowView)
            ?? { let v = DictationHistoryRowView(); v.identifier = Self.rowViewID; return v }()
        rowView.configure(entry: entries[row], theme: theme)
        return rowView
    }
}

private final class DictationHistoryRowView: NSView {
    private let hoverBackground = HoverHighlightView()
    private let textLabel = NSTextField(labelWithString: "")
    private let metaLabel = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        hoverBackground.cornerRadius = 6
        hoverBackground.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hoverBackground)
        NSLayoutConstraint.activate([
            hoverBackground.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            hoverBackground.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            hoverBackground.topAnchor.constraint(equalTo: topAnchor, constant: 1),
            hoverBackground.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -1),
        ])

        textLabel.font = .systemFont(ofSize: 12.5)
        textLabel.lineBreakMode = .byTruncatingTail
        textLabel.maximumNumberOfLines = 1
        textLabel.translatesAutoresizingMaskIntoConstraints = false

        metaLabel.font = .systemFont(ofSize: 10.5)
        metaLabel.lineBreakMode = .byTruncatingTail
        metaLabel.maximumNumberOfLines = 1
        metaLabel.translatesAutoresizingMaskIntoConstraints = false

        let textStack = NSStackView(views: [textLabel, metaLabel])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 2
        textStack.translatesAutoresizingMaskIntoConstraints = false

        addSubview(textStack)
        NSLayoutConstraint.activate([
            textStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            textStack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12),
            textStack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    func configure(entry: DictationHistoryEntry, theme: HelmTheme) {
        textLabel.stringValue = entry.text
        metaLabel.stringValue = "\(DictationRelativeTime.string(from: entry.date)) · \(DictationRelativeTime.duration(entry.durationSeconds))"
        textLabel.textColor = HelmTheme.nsColor(theme.chromeInkHex)
        metaLabel.textColor = HelmTheme.mutedInk(theme)
        hoverBackground.normalColor = .clear
        hoverBackground.hoverColor = HelmTheme.nsColor(theme.chromeLineHex).withAlphaComponent(0.35)
    }
}

// MARK: - Vocabulary chips

/// A simple frame-based flow layout - AppKit's `NSStackView` has no built-in
/// wrapping, so chips are laid out and wrapped manually against the view's
/// own width on every `layout()` pass. `isFlipped` so rows read top-to-bottom
/// in insertion order, matching every other flipped-document convention in
/// this app (see `AGENTS.md`'s AppKit gotcha catalogue, item 9).
final class ChipFlowView: NSView {
    private var chips: [NSView] = []
    private var heightConstraint: NSLayoutConstraint!

    override init(frame: NSRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        heightConstraint = heightAnchor.constraint(equalToConstant: 0)
        heightConstraint.isActive = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override var isFlipped: Bool { true }

    func setChips(_ views: [NSView]) {
        subviews.forEach { $0.removeFromSuperview() }
        chips = views
        for v in views {
            v.translatesAutoresizingMaskIntoConstraints = true
            addSubview(v)
        }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let hSpacing: CGFloat = 6
        let vSpacing: CGFloat = 8
        let width = max(bounds.width, 1)
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        for v in chips {
            let size = v.fittingSize
            if x > 0 && x + size.width > width {
                x = 0
                y += rowHeight + vSpacing
                rowHeight = 0
            }
            v.frame = NSRect(x: x, y: y, width: size.width, height: size.height)
            x += size.width + hSpacing
            rowHeight = max(rowHeight, size.height)
        }
        let totalHeight = chips.isEmpty ? 0 : y + rowHeight
        if heightConstraint.constant != totalHeight {
            heightConstraint.constant = totalHeight
            superview?.needsLayout = true
        }
    }
}

/// A single removable vocabulary word/phrase pill.
final class VocabularyChipView: NSView {
    private let label = NSTextField(labelWithString: "")
    private let removeButton = NSButton()
    var onRemove: (() -> Void)?

    init(word: String) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 11

        label.stringValue = word
        label.font = .systemFont(ofSize: 11.5, weight: .medium)
        label.translatesAutoresizingMaskIntoConstraints = false

        removeButton.title = ""
        removeButton.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Remove \(word)")
        removeButton.isBordered = false
        removeButton.target = self
        removeButton.action = #selector(removeTapped)
        removeButton.translatesAutoresizingMaskIntoConstraints = false

        addSubview(label)
        addSubview(removeButton)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 5),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -5),

            removeButton.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 4),
            removeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            removeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            removeButton.widthAnchor.constraint(equalToConstant: 14),
            removeButton.heightAnchor.constraint(equalToConstant: 14),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    @objc private func removeTapped() { onRemove?() }

    func applyTheme(_ theme: HelmTheme) {
        layer?.backgroundColor = HelmTheme.nsColor(theme.accentHex).withAlphaComponent(0.16).cgColor
        layer?.borderWidth = 1
        layer?.borderColor = HelmTheme.nsColor(theme.accentHex).withAlphaComponent(0.4).cgColor
        label.textColor = HelmTheme.nsColor(theme.chromeInkHex)
        removeButton.contentTintColor = HelmTheme.mutedInk(theme)
    }
}
