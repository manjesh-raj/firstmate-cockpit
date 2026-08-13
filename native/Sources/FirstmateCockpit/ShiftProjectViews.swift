// Manjesh Grand Line - native macOS app.
//
// Project card + status dropdown for Shift's Projects section
// (cockpit-shift-projects, phase 3 - see AGENTS.md's "Shift" section).
// Phase 1 shipped a decorative, non-clickable status pill on the (never-
// built) Projects grid; the captain flagged that directly after the mockup
// shipped it that way, so this file's one hard requirement is that the pill
// is a real control - clicking it pops an `NSMenu` (same convention as
// `ThemeMenu.swift`) and a selection writes straight back to
// `ShiftStore.updateProject`.
//
// The status pill deliberately lives in its own row, a sibling of the
// name/description/progress-bar region rather than nested inside it: an
// `NSClickGestureRecognizer` attached to an ancestor view will contend with
// a real button living inside that same subtree for which one gets the
// click, so "click the card to open detail" and "click the pill to change
// status" are kept as two disjoint view hierarchies rather than relying on
// hit-testing precedence between a gesture recognizer and a nested control.

import AppKit

final class ShiftProjectCardView: NSView {
    private let nameLabel = NSTextField(labelWithString: "")
    private let descriptionLabel = NSTextField(labelWithString: "")
    private let progressLabel = NSTextField(labelWithString: "")
    private let progressTrack = NSView()
    private let progressFill = NSView()
    private var progressFillWidthConstraint: NSLayoutConstraint?

    private let openRegion = HoverHighlightView()
    private let statusPill = NSView()
    private let statusLabel = NSTextField(labelWithString: "")
    private let statusButton = NSButton()

    private var project: ShiftProject?
    private var theme: HelmTheme = ThemeManager.shared.theme

    /// Fired when the card itself (not the status pill) is clicked.
    var onOpenDetail: (() -> Void)?
    /// Fired when a dropdown menu item is chosen - the caller owns writing
    /// it back via `ShiftStore.updateProject`.
    var onStatusChange: ((ShiftProjectStatus) -> Void)?

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 10
        translatesAutoresizingMaskIntoConstraints = false

        nameLabel.font = .systemFont(ofSize: 13.5, weight: .semibold)
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.maximumNumberOfLines = 1

        descriptionLabel.font = .systemFont(ofSize: 11)
        descriptionLabel.lineBreakMode = .byTruncatingTail
        descriptionLabel.maximumNumberOfLines = 2

        progressLabel.font = .systemFont(ofSize: 10.5)

        progressTrack.wantsLayer = true
        progressTrack.layer?.cornerRadius = 2.5
        progressTrack.translatesAutoresizingMaskIntoConstraints = false
        progressTrack.heightAnchor.constraint(equalToConstant: 5).isActive = true

        progressFill.wantsLayer = true
        progressFill.layer?.cornerRadius = 2.5
        progressFill.translatesAutoresizingMaskIntoConstraints = false
        progressTrack.addSubview(progressFill)
        NSLayoutConstraint.activate([
            progressFill.leadingAnchor.constraint(equalTo: progressTrack.leadingAnchor),
            progressFill.topAnchor.constraint(equalTo: progressTrack.topAnchor),
            progressFill.bottomAnchor.constraint(equalTo: progressTrack.bottomAnchor),
        ])

        let infoStack = NSStackView(views: [nameLabel, descriptionLabel, progressLabel, progressTrack])
        infoStack.orientation = .vertical
        infoStack.alignment = .leading
        infoStack.spacing = 5
        infoStack.translatesAutoresizingMaskIntoConstraints = false
        progressTrack.widthAnchor.constraint(equalTo: infoStack.widthAnchor).isActive = true

        openRegion.cornerRadius = 8
        openRegion.translatesAutoresizingMaskIntoConstraints = false
        openRegion.addSubview(infoStack)
        NSLayoutConstraint.activate([
            infoStack.leadingAnchor.constraint(equalTo: openRegion.leadingAnchor, constant: 6),
            infoStack.trailingAnchor.constraint(equalTo: openRegion.trailingAnchor, constant: -6),
            infoStack.topAnchor.constraint(equalTo: openRegion.topAnchor, constant: 6),
            infoStack.bottomAnchor.constraint(equalTo: openRegion.bottomAnchor, constant: -6),
        ])
        let openClick = NSClickGestureRecognizer(target: self, action: #selector(openClicked))
        openRegion.addGestureRecognizer(openClick)

        statusLabel.font = .systemFont(ofSize: 10.5, weight: .semibold)
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusPill.wantsLayer = true
        statusPill.layer?.cornerRadius = 9
        statusPill.translatesAutoresizingMaskIntoConstraints = false
        statusPill.addSubview(statusLabel)
        NSLayoutConstraint.activate([
            statusLabel.leadingAnchor.constraint(equalTo: statusPill.leadingAnchor, constant: 9),
            statusLabel.trailingAnchor.constraint(equalTo: statusPill.trailingAnchor, constant: -9),
            statusLabel.topAnchor.constraint(equalTo: statusPill.topAnchor, constant: 3),
            statusLabel.bottomAnchor.constraint(equalTo: statusPill.bottomAnchor, constant: -3),
        ])
        statusPill.setContentHuggingPriority(.required, for: .horizontal)
        statusPill.setContentCompressionResistancePriority(.required, for: .horizontal)

        statusButton.title = ""
        statusButton.isBordered = false
        statusButton.target = self
        statusButton.action = #selector(statusButtonClicked)
        statusButton.translatesAutoresizingMaskIntoConstraints = false
        statusPill.addSubview(statusButton)
        NSLayoutConstraint.activate([
            statusButton.leadingAnchor.constraint(equalTo: statusPill.leadingAnchor),
            statusButton.trailingAnchor.constraint(equalTo: statusPill.trailingAnchor),
            statusButton.topAnchor.constraint(equalTo: statusPill.topAnchor),
            statusButton.bottomAnchor.constraint(equalTo: statusPill.bottomAnchor),
        ])

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let statusRow = NSStackView(views: [spacer, statusPill])
        statusRow.orientation = .horizontal
        statusRow.distribution = .fill
        statusRow.translatesAutoresizingMaskIntoConstraints = false

        let outer = NSStackView(views: [openRegion, statusRow])
        outer.orientation = .vertical
        outer.alignment = .leading
        outer.spacing = 10
        outer.translatesAutoresizingMaskIntoConstraints = false
        addSubview(outer)
        NSLayoutConstraint.activate([
            outer.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            outer.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            outer.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            outer.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
        ])
        openRegion.widthAnchor.constraint(equalTo: outer.widthAnchor).isActive = true
        statusRow.widthAnchor.constraint(equalTo: outer.widthAnchor).isActive = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    func configure(project: ShiftProject, completed: Int, total: Int, theme: HelmTheme) {
        self.project = project
        self.theme = theme

        nameLabel.stringValue = project.name
        nameLabel.textColor = HelmTheme.nsColor(theme.chromeInkHex)

        descriptionLabel.isHidden = project.description.isEmpty
        descriptionLabel.stringValue = project.description
        descriptionLabel.textColor = HelmTheme.mutedInk(theme)

        progressLabel.stringValue = "\(completed) of \(total) tasks completed"
        progressLabel.textColor = HelmTheme.mutedInk(theme)

        progressFillWidthConstraint?.isActive = false
        let fraction = total > 0 ? CGFloat(completed) / CGFloat(total) : 0
        progressFillWidthConstraint = progressFill.widthAnchor.constraint(
            equalTo: progressTrack.widthAnchor, multiplier: max(0, min(1, fraction))
        )
        progressFillWidthConstraint?.isActive = true
        progressTrack.layer?.backgroundColor = HelmTheme.nsColor(theme.chromeLineHex).withAlphaComponent(0.3).cgColor
        progressFill.layer?.backgroundColor = HelmTheme.nsColor(theme.accentHex).cgColor

        layer?.backgroundColor = HelmTheme.nsColor(theme.chromeBackgroundHex).cgColor
        layer?.borderWidth = 1
        layer?.borderColor = HelmTheme.nsColor(theme.chromeLineHex).withAlphaComponent(0.5).cgColor

        openRegion.normalColor = .clear
        openRegion.hoverColor = HelmTheme.nsColor(theme.chromeLineHex).withAlphaComponent(0.18)

        applyStatusPill(project.status)
    }

    private func applyStatusPill(_ status: ShiftProjectStatus) {
        let tint: HelmTint = {
            switch status {
            case .notStarted: return .neutral
            case .inProgress: return .info
            case .onHold: return .warn
            case .completed: return .good
            case .archived: return .critical
            }
        }()
        let color = HelmTheme.nsColor(tint.hex(in: theme))
        statusPill.layer?.backgroundColor = color.withAlphaComponent(0.16).cgColor
        statusLabel.stringValue = status.displayName + " \u{2304}"
        statusLabel.textColor = color
    }

    @objc private func openClicked() { onOpenDetail?() }

    @objc private func statusButtonClicked() {
        let menu = NSMenu()
        let current = project?.status
        for status in ShiftProjectStatus.allCases {
            let item = NSMenuItem(title: status.displayName, action: #selector(statusItemSelected(_:)), keyEquivalent: "")
            item.target = self
            item.state = status == current ? .on : .off
            item.representedObject = status.rawValue
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: statusPill.bounds.height + 4), in: statusPill)
    }

    @objc private func statusItemSelected(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let status = ShiftProjectStatus(rawValue: raw) else { return }
        onStatusChange?(status)
    }
}
