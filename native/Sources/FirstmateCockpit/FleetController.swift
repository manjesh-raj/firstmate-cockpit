// Firstmate Cockpit - native macOS app.
//
// Fix 1: the real Fleet dashboard for the Overview rail destination,
// replacing the "coming soon" `PlaceholderViewController`. Structure mirrors
// `backend/static/index.html`'s Fleet view: a greeting header, an answer
// banner that goes calm/loud depending on whether anything needs the
// captain, a row of quiet stat readouts, an "In flight" section of working
// crew, and a "Ready to merge" section of open PRs with Review/Merge
// actions. All data comes from `FleetData.swift`, which reads this
// machine's real firstmate home - nothing here is fabricated.

import AppKit

final class FleetController: NSViewController {

    private let scroll = NSScrollView()
    private let contentStack = NSStackView()

    private let greetingLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let refreshButton = NSButton()

    private let bannerView = NSView()
    private let bannerGlyph = NSTextField(labelWithString: "")
    private let bannerTitle = NSTextField(labelWithString: "")
    private let bannerBody = NSTextField(wrappingLabelWithString: "")

    private let statsRow = NSStackView()

    private let inFlightHeader = NSTextField(labelWithString: "")
    private let inFlightStack = NSStackView()

    private let readyHeader = NSTextField(labelWithString: "")
    private let readyStack = NSStackView()

    private var theme: HelmTheme = ThemeManager.shared.theme
    private var isLoading = false

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 940, height: 720))
        root.wantsLayer = true
        view = root

        let content = NSView()
        content.translatesAutoresizingMaskIntoConstraints = false

        let header = buildHeader()
        buildBanner()
        buildStatsRow()
        let inFlightSection = buildSection(header: inFlightHeader, iconSymbol: "clock", title: "In flight", stack: inFlightStack)
        let readySection = buildSection(header: readyHeader, iconSymbol: "arrow.triangle.pull", title: "Ready to merge", stack: readyStack)

        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = 20
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        contentStack.addArrangedSubview(header)
        contentStack.addArrangedSubview(bannerView)
        contentStack.addArrangedSubview(statsRow)
        contentStack.addArrangedSubview(inFlightSection)
        contentStack.addArrangedSubview(readySection)

        content.addSubview(contentStack)
        NSLayoutConstraint.activate([
            contentStack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 28),
            contentStack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -28),
            contentStack.topAnchor.constraint(equalTo: content.topAnchor, constant: 24),
            contentStack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -28),
            bannerView.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
            statsRow.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
            inFlightSection.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
            readySection.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
        ])

        scroll.documentView = content
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: root.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            content.widthAnchor.constraint(equalTo: scroll.widthAnchor),
        ])

        ThemeManager.shared.observe { [weak self, weak root] theme in
            self?.theme = theme
            // Fix 8 (fixes4): this view never forced its appearance to the
            // active Helm theme, so every system-semantic color used below
            // (`.secondaryLabelColor` on PR/task subtitles) resolved against
            // the OS's actual light/dark setting instead - producing
            // near-invisible text whenever that setting disagreed with the
            // chosen Helm theme (e.g. system Light + a dark Helm theme gives
            // light-mode dark text on a dark background).
            root?.appearance = NSAppearance(named: theme.mode == .dark ? .darkAqua : .aqua)
            self?.applyTheme()
        }
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        refresh()
    }

    // MARK: Building the static chrome

    private func buildHeader() -> NSView {
        greetingLabel.font = .systemFont(ofSize: 22, weight: .semibold)
        greetingLabel.translatesAutoresizingMaskIntoConstraints = false

        subtitleLabel.font = .systemFont(ofSize: 12)
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false

        refreshButton.title = ""
        refreshButton.isBordered = false
        refreshButton.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "Refresh")
        refreshButton.target = self
        refreshButton.action = #selector(refreshTapped)
        refreshButton.toolTip = "Refresh fleet data"
        refreshButton.translatesAutoresizingMaskIntoConstraints = false

        let textStack = NSStackView(views: [greetingLabel, subtitleLabel])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 4

        let row = NSStackView(views: [textStack, refreshButton])
        row.orientation = .horizontal
        row.spacing = 12
        row.translatesAutoresizingMaskIntoConstraints = false
        return row
    }

    private func buildBanner() {
        bannerView.wantsLayer = true
        bannerView.layer?.cornerRadius = 12
        bannerView.translatesAutoresizingMaskIntoConstraints = false

        bannerGlyph.font = .systemFont(ofSize: 22)
        bannerGlyph.translatesAutoresizingMaskIntoConstraints = false

        bannerTitle.font = .systemFont(ofSize: 14, weight: .semibold)
        bannerTitle.translatesAutoresizingMaskIntoConstraints = false

        bannerBody.font = .systemFont(ofSize: 12)
        bannerBody.translatesAutoresizingMaskIntoConstraints = false

        let textStack = NSStackView(views: [bannerTitle, bannerBody])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 3
        textStack.translatesAutoresizingMaskIntoConstraints = false

        bannerView.addSubview(bannerGlyph)
        bannerView.addSubview(textStack)
        NSLayoutConstraint.activate([
            bannerGlyph.leadingAnchor.constraint(equalTo: bannerView.leadingAnchor, constant: 16),
            bannerGlyph.centerYAnchor.constraint(equalTo: bannerView.centerYAnchor),
            textStack.leadingAnchor.constraint(equalTo: bannerGlyph.trailingAnchor, constant: 14),
            textStack.trailingAnchor.constraint(lessThanOrEqualTo: bannerView.trailingAnchor, constant: -16),
            textStack.topAnchor.constraint(equalTo: bannerView.topAnchor, constant: 14),
            textStack.bottomAnchor.constraint(equalTo: bannerView.bottomAnchor, constant: -14),
        ])
    }

    private func buildStatsRow() {
        statsRow.orientation = .horizontal
        statsRow.distribution = .fillEqually
        statsRow.spacing = 10
        statsRow.translatesAutoresizingMaskIntoConstraints = false
    }

    private func statTile(icon: String, value: String, label: String) -> NSView {
        let container = NSView()
        container.wantsLayer = true
        container.layer?.cornerRadius = 10
        container.translatesAutoresizingMaskIntoConstraints = false

        let iconView = NSImageView()
        iconView.image = NSImage(systemSymbolName: icon, accessibilityDescription: label)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 11, weight: .medium))
        iconView.translatesAutoresizingMaskIntoConstraints = false

        let valueLabel = NSTextField(labelWithString: value)
        valueLabel.font = .monospacedDigitSystemFont(ofSize: 15, weight: .semibold)
        valueLabel.translatesAutoresizingMaskIntoConstraints = false

        let nameLabel = NSTextField(labelWithString: label)
        nameLabel.font = .systemFont(ofSize: 9.5)
        nameLabel.translatesAutoresizingMaskIntoConstraints = false

        let topRow = NSStackView(views: [iconView, valueLabel])
        topRow.orientation = .horizontal
        topRow.spacing = 5
        topRow.alignment = .firstBaseline
        topRow.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [topRow, nameLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 3
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 10),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -8),
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 8),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -8),
            container.heightAnchor.constraint(equalToConstant: 50),
        ])
        stashedTileParts.append((container, iconView, valueLabel, nameLabel))
        return container
    }

    /// Stat-tile subviews needing per-theme restyling, kept alongside the
    /// containers built each refresh (the row is rebuilt from scratch every
    /// time, so this list is cleared and repopulated in `rebuildStats`).
    private var stashedTileParts: [(NSView, NSImageView, NSTextField, NSTextField)] = []

    private func buildSection(header: NSTextField, iconSymbol: String, title: String, stack: NSStackView) -> NSView {
        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: iconSymbol, accessibilityDescription: title)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold))
        icon.translatesAutoresizingMaskIntoConstraints = false

        header.font = .systemFont(ofSize: 14, weight: .semibold)
        header.stringValue = title
        header.translatesAutoresizingMaskIntoConstraints = false

        let headerRow = NSStackView(views: [icon, header])
        headerRow.orientation = .horizontal
        headerRow.spacing = 8
        headerRow.alignment = .firstBaseline
        headerRow.translatesAutoresizingMaskIntoConstraints = false

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false

        let section = NSStackView(views: [headerRow, stack])
        section.orientation = .vertical
        section.alignment = .leading
        section.spacing = 8
        section.translatesAutoresizingMaskIntoConstraints = false
        stack.widthAnchor.constraint(equalTo: section.widthAnchor).isActive = true
        return section
    }

    // MARK: Refresh

    @objc private func refreshTapped() { refresh() }

    private func refresh() {
        guard !isLoading else { return }
        isLoading = true
        refreshButton.isEnabled = false
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let snapshot = FleetDataSource.snapshot()
            let openPRs = OpenPRsSource.fetch()
            let merged = FleetDataSource.mergedPRs(openPRs: openPRs, tasks: snapshot.tasks)
            DispatchQueue.main.async {
                guard let self else { return }
                self.isLoading = false
                self.refreshButton.isEnabled = true
                self.render(snapshot: snapshot, mergedPRs: merged)
            }
        }
    }

    // MARK: Rendering

    private func render(snapshot: FleetSnapshot, mergedPRs: [MergedPR]) {
        rowContainers.removeAll()
        emptyStateLabels.removeAll()

        let working = snapshot.tasks.filter { $0.status == "working" }
        let needs = snapshot.tasks.filter { $0.status == "needs_decision" || $0.status == "blocked" }

        let hour = Calendar.current.component(.hour, from: Date())
        let part = hour < 5 ? "Still up" : hour < 12 ? "Good morning" : hour < 17 ? "Good afternoon" : "Good evening"
        greetingLabel.stringValue = "\(part), \(snapshot.captain)"
        let df = DateFormatter()
        df.setLocalizedDateFormatFromTemplate("EEEE")
        subtitleLabel.stringValue = snapshot.homeOk
            ? "\(df.string(from: Date())) \u{00B7} the fleet is yours"
            : "firstmate home not found at \(FirstmateHome.root.path) - set FM_HOME"

        renderBanner(needs: needs, working: working, readyCount: mergedPRs.count)
        rebuildStats(working: working.count, ready: mergedPRs.count, snapshot: snapshot)
        rebuildTaskRows(into: inFlightStack, tasks: working, emptyTitle: "All hands idle", emptyBody: "No crew are working right now. Send your first mate a task from the console and this board lights up.")
        inFlightHeader.stringValue = "In flight (\(working.count))"
        rebuildPRRows(mergedPRs)
        readyHeader.stringValue = "Ready to merge (\(mergedPRs.count))"

        applyTheme()
    }

    private func renderBanner(needs: [FleetTask], working: [FleetTask], readyCount: Int) {
        if needs.isEmpty {
            bannerGlyph.stringValue = "\u{2713}"
            bannerTitle.stringValue = "All clear - nothing needs you"
            bannerBody.stringValue = "\(working.count) crew working, \(readyCount) PR\(readyCount == 1 ? "" : "s") ready to merge. Nobody is parked on a decision."
            bannerIsAlert = false
        } else {
            let decisions = needs.filter { $0.status == "needs_decision" }.count
            let blocked = needs.filter { $0.status == "blocked" }.count
            var bits: [String] = []
            if decisions > 0 { bits.append("\(decisions) decision\(decisions > 1 ? "s" : "") waiting") }
            if blocked > 0 { bits.append("\(blocked) blocked") }
            bannerGlyph.stringValue = "\u{26A0}\u{FE0F}"
            bannerTitle.stringValue = "\(needs.count) task\(needs.count > 1 ? "s" : "") need your call"
            bannerBody.stringValue = bits.joined(separator: " \u{00B7} ") + " - the crew is holding for you."
            bannerIsAlert = true
        }
    }

    private var bannerIsAlert = false

    private func rebuildStats(working: Int, ready: Int, snapshot: FleetSnapshot) {
        for v in statsRow.arrangedSubviews {
            statsRow.removeArrangedSubview(v)
            v.removeFromSuperview()
        }
        stashedTileParts.removeAll()

        let watcherLabel: String
        switch snapshot.watcher.status {
        case "healthy": watcherLabel = "watcher healthy"
        case "stale": watcherLabel = "watcher stale"
        default: watcherLabel = "watcher off"
        }

        statsRow.addArrangedSubview(statTile(icon: "clock", value: "\(working)", label: "working"))
        statsRow.addArrangedSubview(statTile(icon: "arrow.triangle.pull", value: "\(ready)", label: "ready to merge"))
        statsRow.addArrangedSubview(statTile(icon: "line.3.horizontal", value: "\(snapshot.queuedCount)", label: "queued"))
        statsRow.addArrangedSubview(statTile(icon: "checkmark.circle", value: "\(snapshot.doneCount)", label: "done today"))
        statsRow.addArrangedSubview(statTile(icon: "shippingbox", value: "\(snapshot.projectsCount)", label: "projects"))
        statsRow.addArrangedSubview(statTile(icon: "waveform.path.ecg", value: "", label: watcherLabel))
    }

    private func rebuildTaskRows(into stack: NSStackView, tasks: [FleetTask], emptyTitle: String, emptyBody: String) {
        for v in stack.arrangedSubviews {
            stack.removeArrangedSubview(v)
            v.removeFromSuperview()
        }
        if tasks.isEmpty {
            stack.addArrangedSubview(emptyStateView(icon: "tray", title: emptyTitle, body: emptyBody))
            return
        }
        for task in tasks {
            let row = taskRowView(task)
            stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
    }

    private func rebuildPRRows(_ prs: [MergedPR]) {
        for v in readyStack.arrangedSubviews {
            readyStack.removeArrangedSubview(v)
            v.removeFromSuperview()
        }
        if prs.isEmpty {
            readyStack.addArrangedSubview(emptyStateView(icon: "checkmark.seal", title: "Nothing waiting on you", body: "No open pull requests across your projects. They show up here the moment a crewmate opens one."))
            return
        }
        for pr in prs {
            let row = prRowView(pr)
            readyStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: readyStack.widthAnchor).isActive = true
        }
    }

    private func emptyStateView(icon: String, title: String, body: String) -> NSView {
        let iconView = NSImageView()
        iconView.image = NSImage(systemSymbolName: icon, accessibilityDescription: title)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 24, weight: .light))
        iconView.translatesAutoresizingMaskIntoConstraints = false

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)

        let bodyLabel = NSTextField(wrappingLabelWithString: body)
        bodyLabel.font = .systemFont(ofSize: 11.5)
        bodyLabel.preferredMaxLayoutWidth = 420

        let stack = NSStackView(views: [iconView, titleLabel, bodyLabel])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.wantsLayer = true
        container.layer?.cornerRadius = 10
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 22),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -22),
        ])
        emptyStateLabels.append((container, iconView, titleLabel, bodyLabel))
        return container
    }

    private var emptyStateLabels: [(NSView, NSImageView, NSTextField, NSTextField)] = []

    private func taskRowView(_ task: FleetTask) -> NSView {
        let (symbol, colorHex, pillLabel) = taskVisuals(task)

        let iconView = NSImageView()
        iconView.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 14, weight: .medium))
        iconView.contentTintColor = HelmTheme.nsColor(colorHex)
        iconView.translatesAutoresizingMaskIntoConstraints = false

        let idLabel = NSTextField(labelWithString: task.id)
        idLabel.font = .systemFont(ofSize: 12.5, weight: .medium)
        idLabel.lineBreakMode = .byTruncatingTail
        idLabel.maximumNumberOfLines = 1

        let subBits = [task.repo, task.detail.isEmpty ? "source: \(task.source)" : task.detail].compactMap { $0 }.filter { !$0.isEmpty }
        let subLabel = NSTextField(labelWithString: subBits.joined(separator: " \u{00B7} "))
        subLabel.font = .systemFont(ofSize: 10.5)
        subLabel.textColor = HelmTheme.mutedInk(theme)
        subLabel.lineBreakMode = .byTruncatingTail
        subLabel.maximumNumberOfLines = 1

        let textStack = NSStackView(views: [idLabel, subLabel])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 2
        textStack.setContentHuggingPriority(.defaultLow, for: .horizontal)
        textStack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let pill = pillLabelView(text: pillLabel, colorHex: colorHex)

        let row = NSStackView(views: [iconView, textStack, pill])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false
        // Keep the icon and status pill at their natural size and let the
        // title/subtitle text truncate first under narrow widths, so the pill
        // never gets squeezed into wrapping onto a second line.
        iconView.setContentHuggingPriority(.required, for: .horizontal)
        iconView.setContentCompressionResistancePriority(.required, for: .horizontal)
        pill.setContentHuggingPriority(.required, for: .horizontal)
        pill.setContentCompressionResistancePriority(.required, for: .horizontal)

        return wrapRow(row, minHeight: 38)
    }

    private func taskVisuals(_ task: FleetTask) -> (symbol: String, colorHex: String, label: String) {
        switch task.status {
        case "needs_decision": return ("exclamationmark.triangle.fill", theme.ansiHex[3], "needs you")
        case "blocked": return ("xmark.octagon.fill", theme.ansiHex[1], "blocked")
        case "failed": return ("xmark.octagon.fill", theme.ansiHex[1], "failed")
        case "done": return ("checkmark.circle.fill", theme.ansiHex[2], "done")
        case "working": return ("clock.fill", theme.accentHex, "working")
        default: return ("circle.dashed", theme.chromeInkHex, "idle")
        }
    }

    private func prRowView(_ pr: MergedPR) -> NSView {
        let iconView = NSImageView()
        iconView.image = NSImage(systemSymbolName: "checkmark.circle", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 14, weight: .medium))
        iconView.contentTintColor = HelmTheme.nsColor(theme.accentHex)
        iconView.translatesAutoresizingMaskIntoConstraints = false

        let heading = pr.title.isEmpty ? (pr.number != nil ? "PR #\(pr.number!)" : "PR") : pr.title
        let titleLabel = NSTextField(labelWithString: heading)
        titleLabel.font = .systemFont(ofSize: 12.5, weight: .medium)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1

        var subBits: [String] = []
        if !pr.repo.isEmpty { subBits.append(pr.repo) }
        subBits.append(pr.number != nil ? "PR #\(pr.number!)" : "PR")
        if let forge = pr.forge { subBits.append(forge) }
        let subLabel = NSTextField(labelWithString: subBits.joined(separator: " \u{00B7} "))
        subLabel.font = .systemFont(ofSize: 10.5)
        subLabel.textColor = HelmTheme.mutedInk(theme)
        subLabel.lineBreakMode = .byTruncatingTail
        subLabel.maximumNumberOfLines = 1

        let textStack = NSStackView(views: [titleLabel, subLabel])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 2
        textStack.setContentHuggingPriority(.defaultLow, for: .horizontal)
        textStack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let (checksLabel, checksColorHex) = checksVisuals(pr.checks)
        let checksPill = pillLabelView(text: checksLabel, colorHex: checksColorHex)

        let reviewButton = NSButton(title: "Review", target: self, action: #selector(reviewPR(_:)))
        reviewButton.bezelStyle = .rounded
        reviewButton.controlSize = .small
        reviewButton.identifier = NSUserInterfaceItemIdentifier(pr.url)

        var trailing: [NSView] = [checksPill, reviewButton]
        if pr.source == "work", let taskID = pr.taskID {
            let mergeButton = NSButton(title: "Merge", target: self, action: #selector(mergePR(_:)))
            mergeButton.bezelStyle = .rounded
            mergeButton.controlSize = .small
            mergeButton.identifier = NSUserInterfaceItemIdentifier("\(taskID)\u{0}\(pr.url)")
            trailing.append(mergeButton)
        }

        let row = NSStackView(views: [iconView, textStack] + trailing)
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false
        // Same rule as taskRowView: icon and every trailing control (badge,
        // Review, Merge) stay fixed-size under narrow widths; only the
        // title/subtitle text truncates. Previously nothing set compression
        // resistance on the trailing controls, so a long PR title could
        // squeeze the checks pill below its fitting width and force it (and
        // the buttons after it) onto a visually wrapped second line.
        iconView.setContentHuggingPriority(.required, for: .horizontal)
        iconView.setContentCompressionResistancePriority(.required, for: .horizontal)
        for t in trailing {
            t.setContentHuggingPriority(.required, for: .horizontal)
            t.setContentCompressionResistancePriority(.required, for: .horizontal)
        }

        return wrapRow(row, minHeight: 38)
    }

    private func checksVisuals(_ checks: String) -> (label: String, colorHex: String) {
        switch checks {
        case "green": return ("checks pass", theme.ansiHex[2])
        case "red": return ("checks failing", theme.ansiHex[1])
        case "pending": return ("checks running", theme.ansiHex[3])
        default: return ("no checks", theme.chromeInkHex)
        }
    }

    private func pillLabelView(text: String, colorHex: String) -> NSView {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 10, weight: .semibold)
        label.textColor = HelmTheme.nsColor(colorHex)
        let container = NSView()
        container.wantsLayer = true
        container.layer?.cornerRadius = 8
        container.layer?.backgroundColor = HelmTheme.nsColor(colorHex).withAlphaComponent(0.15).cgColor
        container.translatesAutoresizingMaskIntoConstraints = false
        label.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 7),
            label.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -7),
            label.topAnchor.constraint(equalTo: container.topAnchor, constant: 2),
            label.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -2),
        ])
        return container
    }

    private func wrapRow(_ row: NSStackView, minHeight: CGFloat) -> NSView {
        let container = NSView()
        container.wantsLayer = true
        container.layer?.cornerRadius = 9
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 10),
            row.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -10),
            row.topAnchor.constraint(equalTo: container.topAnchor, constant: 6),
            row.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -6),
            container.heightAnchor.constraint(greaterThanOrEqualToConstant: minHeight),
        ])
        rowContainers.append(container)
        return container
    }

    private var rowContainers: [NSView] = []

    // MARK: Actions

    @objc private func reviewPR(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue, let url = URL(string: raw) else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func mergePR(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue else { return }
        let parts = raw.components(separatedBy: "\u{0}")
        guard parts.count == 2 else { return }
        let prURL = parts[1]

        let alert = NSAlert()
        alert.messageText = "Merge this PR?"
        alert.informativeText = prURL
        alert.addButton(withTitle: "Merge")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .informational
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        sender.isEnabled = false
        sender.title = "Merging\u{2026}"
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = FleetDataSource.mergePR(url: prURL)
            DispatchQueue.main.async {
                if result.ok {
                    self?.refresh()
                } else {
                    sender.isEnabled = true
                    sender.title = "Merge"
                    let failAlert = NSAlert()
                    failAlert.messageText = "Merge failed"
                    failAlert.informativeText = result.message
                    failAlert.alertStyle = .warning
                    failAlert.runModal()
                }
            }
        }
    }

    // MARK: Theme

    private func applyTheme() {
        view.layer?.backgroundColor = HelmTheme.nsColor(theme.backgroundHex).cgColor
        let ink = HelmTheme.nsColor(theme.chromeInkHex)
        let surface = HelmTheme.nsColor(theme.chromeBackgroundHex)
        let line = HelmTheme.nsColor(theme.chromeLineHex)

        // Fix 8 (fixes4): every "muted" text style below now routes through
        // `HelmTheme.mutedInk`, not its own ad hoc alpha - `0.55`/`0.6` looked
        // fine in the dark palettes but measured below WCAG AA (as low as
        // 3.33:1) in all four light ones. See `mutedInk`'s doc comment for
        // the measured numbers.
        let muted = HelmTheme.mutedInk(theme)
        greetingLabel.textColor = ink
        subtitleLabel.textColor = muted
        refreshButton.contentTintColor = ink.withAlphaComponent(0.7)

        let bannerColorHex = bannerIsAlert ? theme.ansiHex[3] : theme.ansiHex[2]
        let bannerColor = HelmTheme.nsColor(bannerColorHex)
        bannerView.layer?.backgroundColor = bannerColor.withAlphaComponent(0.12).cgColor
        bannerTitle.textColor = ink
        bannerBody.textColor = muted

        inFlightHeader.textColor = ink
        readyHeader.textColor = ink

        for (container, iconView, valueLabel, nameLabel) in stashedTileParts {
            container.layer?.backgroundColor = surface.cgColor
            container.layer?.borderWidth = 1
            container.layer?.borderColor = line.withAlphaComponent(0.5).cgColor
            iconView.contentTintColor = ink.withAlphaComponent(0.65)
            valueLabel.textColor = ink
            nameLabel.textColor = muted
        }
        for (container, iconView, titleLabel, bodyLabel) in emptyStateLabels {
            container.layer?.backgroundColor = surface.cgColor
            container.layer?.borderWidth = 1
            container.layer?.borderColor = line.withAlphaComponent(0.4).cgColor
            iconView.contentTintColor = ink.withAlphaComponent(0.4)
            titleLabel.textColor = ink
            bodyLabel.textColor = muted
        }
        for container in rowContainers {
            container.layer?.backgroundColor = surface.cgColor
            container.layer?.borderWidth = 1
            container.layer?.borderColor = line.withAlphaComponent(0.4).cgColor
        }
    }
}
