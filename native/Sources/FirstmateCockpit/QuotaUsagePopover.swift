// Manjesh Grand Line - native macOS app.
//
// The "Claude usage" popover a Herdr-backed tab's toolbar opens
// (`fm/grandline-herdr-utilization-panel`). Structurally mirrors
// `ConsoleComposerPopover.swift` (the "✨ Compose" popover) byte-for-byte -
// transient `NSPopover`, `IconTileView` header, live `ThemeManager`
// observation, a `wantsLayer` root with an explicit theme background rather
// than relying on `NSPopover`'s own system vibrancy (AGENTS.md gotcha #8;
// Compose's own file header documents getting this wrong the first time).
//
// Unlike Compose, this popover shows read-only live status, not a
// generate-review-run flow - the closest existing precedent for that shape
// is `SRELeadStatusPill`'s sliding pane, but that's a heavier full-agentic
// panel; a transient popover is the right weight for a quick "check my
// quota" glance (design plan, following the scout report's own
// recommendation).
//
// Data comes from `QuotaData.swift` (`quota-axi --json --provider claude`),
// Claude only per the captain's explicit scope decision in review - no
// multi-provider picker.
//
// Auto-refresh: every 10 minutes while the popover stays open (captain's
// explicit ask - unlike Compose, which never refreshes on its own), plus once
// immediately on every open (matching Compose's own `content.reset()` open
// behavior). The timer is owned by `QuotaUsageController` and invalidated in
// `close()`/`popoverDidClose` and `shutdown()`, mirroring `FleetNotifier`'s
// `timer?.invalidate(); timer = nil` teardown shape - never left running
// after the popover is dismissed by any path (explicit toggle, outside
// click, or the toolbar icon disappearing because the tab stopped
// qualifying).

import AppKit

/// `gauge.with.dots.needle.33percent` (SF Symbols 4, macOS 13+ - this
/// project's minimum target per `Package.swift`) - a gauge-family glyph for
/// the toolbar icon and the popover's own header tile, deliberately not a
/// circle/dot shape, since the toolbar's own `themeButton` (a half-filled
/// circle) sits right next to where this icon lives and a similar-looking
/// icon would be confusable (flagged directly in visual review of the
/// design mock). Top-level so `ConsoleController`'s toolbar-button
/// construction can share it with the popover's own header tile.
let quotaUsageGaugeSymbol = "gauge.with.dots.needle.33percent"

final class QuotaUsageController: NSObject, NSPopoverDelegate {
    private let popover = NSPopover()
    private let content = QuotaUsageViewController()
    private var themeObservation: ThemeObservation?
    private var refreshTimer: Timer?

    /// 10 minutes, per the captain's explicit review ask.
    private let autoRefreshInterval: TimeInterval = 600

    override init() {
        super.init()
        popover.contentViewController = content
        popover.behavior = .transient
        popover.delegate = self
        content.onSizeChanged = { [weak self] size in
            self?.popover.contentSize = size
        }
        themeObservation = ThemeManager.shared.observe { [weak self] theme in
            guard let self else { return }
            self.popover.appearance = NSAppearance(named: theme.mode == .dark ? .darkAqua : .aqua)
            self.content.applyTheme(theme)
        }
    }

    var isShown: Bool { popover.isShown }

    func toggle(relativeTo view: NSView) {
        if popover.isShown {
            popover.performClose(nil)
        } else {
            content.reset()
            popover.show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
            startAutoRefresh()
        }
    }

    func close() {
        guard popover.isShown else { return }
        popover.performClose(nil)
    }

    /// `NSPopoverDelegate` - fires for every dismissal path (explicit
    /// re-click via `toggle`, a click outside the popover, or the toolbar
    /// icon's own gating hiding it out from under an open popover), so the
    /// timer can never keep firing after the content is no longer visible.
    func popoverDidClose(_ notification: Notification) {
        stopAutoRefresh()
    }

    private func startAutoRefresh() {
        stopAutoRefresh()
        let t = Timer.scheduledTimer(withTimeInterval: autoRefreshInterval, repeats: true) { [weak self] _ in
            self?.content.refresh()
        }
        t.tolerance = 5
        refreshTimer = t
    }

    private func stopAutoRefresh() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    /// Called from `ConsoleController.shutdown()`, mirroring
    /// `ConsoleComposerController.shutdown()`'s own theme-observer teardown -
    /// a per-console (not strictly app-lifetime) property that can be
    /// deallocated mid-session on a deleted host's dedicated page.
    func shutdown() {
        stopAutoRefresh()
        if let themeObservation {
            ThemeManager.shared.unobserve(themeObservation)
            self.themeObservation = nil
        }
    }
}

/// The popover's content: a tinted-icon header with a plan/refreshed
/// subtitle, one row per window (session, weekly - each with a label,
/// percentage, a colored bar, the reset time, and a pace chip), a critical-
/// threshold warning when applicable, and a footer with the data source/
/// latency plus a Copy Summary button. No history kept between opens -
/// `reset()` always starts fresh, matching Compose's own scope decision.
private final class QuotaUsageViewController: NSViewController {
    private var theme = ThemeManager.shared.theme

    static let width: CGFloat = 320

    private let iconTile = IconTileView(size: 30, cornerRadius: 8)
    private let titleLabel = NSTextField(labelWithString: "Claude usage")
    private let subtitleLabel = NSTextField(labelWithString: "")

    private let statusLabel = NSTextField(labelWithString: "Loading…")

    private let sessionRow = QuotaWindowRowView()
    private let weeklyRow = QuotaWindowRowView()
    private let rowsStack = NSStackView()

    private let warningLabel = NSTextField(labelWithString: "")

    private let footerLabel = NSTextField(labelWithString: "")
    private let copyButton = NSButton(title: "Copy Summary", target: nil, action: nil)

    var onSizeChanged: ((NSSize) -> Void)?

    private var latestSnapshot: QuotaSnapshot?
    private var lastRefreshedAt: Date?

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: Self.width, height: 200))
        root.wantsLayer = true
        view = root

        iconTile.configure(symbol: quotaUsageGaugeSymbol, tint: .violet)

        titleLabel.font = .systemFont(ofSize: 13.5, weight: .semibold)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        subtitleLabel.font = .systemFont(ofSize: 10.5)
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false

        let titleTextStack = NSStackView(views: [titleLabel, subtitleLabel])
        titleTextStack.orientation = .vertical
        titleTextStack.alignment = .leading
        titleTextStack.spacing = 1
        titleTextStack.translatesAutoresizingMaskIntoConstraints = false

        let titleRow = NSStackView(views: [iconTile, titleTextStack])
        titleRow.orientation = .horizontal
        titleRow.alignment = .centerY
        titleRow.spacing = 10
        titleRow.translatesAutoresizingMaskIntoConstraints = false

        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.lineBreakMode = .byWordWrapping
        statusLabel.maximumNumberOfLines = 3
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        rowsStack.orientation = .vertical
        rowsStack.alignment = .leading
        rowsStack.spacing = 10
        rowsStack.translatesAutoresizingMaskIntoConstraints = false
        rowsStack.addArrangedSubview(sessionRow)
        rowsStack.addArrangedSubview(weeklyRow)
        rowsStack.isHidden = true

        warningLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        warningLabel.lineBreakMode = .byWordWrapping
        warningLabel.maximumNumberOfLines = 2
        warningLabel.translatesAutoresizingMaskIntoConstraints = false
        warningLabel.isHidden = true

        footerLabel.font = .systemFont(ofSize: 9.5)
        footerLabel.translatesAutoresizingMaskIntoConstraints = false

        copyButton.target = self
        copyButton.action = #selector(copyClicked)
        copyButton.bezelStyle = .rounded
        copyButton.controlSize = .small
        copyButton.isEnabled = false

        let footerRow = NSStackView(views: [footerLabel, copyButton])
        footerRow.orientation = .horizontal
        footerRow.alignment = .centerY
        footerRow.distribution = .fill
        footerRow.translatesAutoresizingMaskIntoConstraints = false
        footerLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        footerLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        copyButton.setContentHuggingPriority(.required, for: .horizontal)
        copyButton.setContentCompressionResistancePriority(.required, for: .horizontal)

        let separator = NSView()
        separator.wantsLayer = true
        separator.translatesAutoresizingMaskIntoConstraints = false
        separator.heightAnchor.constraint(equalToConstant: 1).isActive = true

        let stack = NSStackView(views: [titleRow, statusLabel, rowsStack, warningLabel, separator, footerRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)

        NSLayoutConstraint.activate([
            root.widthAnchor.constraint(equalToConstant: Self.width),
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 12),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: root.bottomAnchor, constant: -12),
            titleRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            statusLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            rowsStack.widthAnchor.constraint(equalTo: stack.widthAnchor),
            warningLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            separator.widthAnchor.constraint(equalTo: stack.widthAnchor),
            footerRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            // `rowsStack.alignment = .leading` only left-aligns its arranged
            // subviews - it does NOT stretch them to the stack's own width
            // (that needs an explicit width constraint, or
            // `alignment = .width`). Without this, `sessionRow`/`weeklyRow`
            // each sized to their own narrower intrinsic content width,
            // leaving a wide blank gap between the bar/pill row and the
            // popover's right edge - confirmed live via pixel measurement of
            // a real running popover (the bar's track stopped well short of
            // the card's actual right inset).
            sessionRow.widthAnchor.constraint(equalTo: rowsStack.widthAnchor),
            weeklyRow.widthAnchor.constraint(equalTo: rowsStack.widthAnchor),
        ])

        applyTheme(theme)
    }

    func reset() {
        statusLabel.stringValue = "Loading…"
        statusLabel.isHidden = false
        rowsStack.isHidden = true
        warningLabel.isHidden = true
        copyButton.isEnabled = false
        latestSnapshot = nil
        subtitleLabel.stringValue = ""
        updateSize()
        refresh()
    }

    /// Re-runs the same fetch and updates the displayed values in place - the
    /// captain's explicit ask that this happen every 10 minutes while open,
    /// plus once immediately on every open (`reset()` calls this too). Only
    /// the numbers change; the row/label view instances themselves are never
    /// torn down and rebuilt, so a same-size refresh produces no
    /// flicker/resize jank.
    func refresh() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = QuotaSource.fetch()
            DispatchQueue.main.async {
                self?.apply(result)
            }
        }
    }

    private func apply(_ result: QuotaFetchResult) {
        lastRefreshedAt = Date()
        switch result {
        case .success(let snapshot):
            latestSnapshot = snapshot
            statusLabel.isHidden = true
            rowsStack.isHidden = false
            copyButton.isEnabled = true

            var subtitleParts: [String] = []
            if let plan = snapshot.plan, !plan.isEmpty {
                subtitleParts.append(plan.capitalized)
            }
            subtitleParts.append("refreshed just now")
            subtitleLabel.stringValue = subtitleParts.joined(separator: " · ")

            sessionRow.configure(title: "Session", window: snapshot.session, theme: theme)
            weeklyRow.configure(title: "Weekly", window: snapshot.weekly, theme: theme)

            // Threshold, exactly as specified in review: .good below 80%,
            // .warn 80-90%, .critical above 90% - a critical state on
            // *either* window gets an explicit warning message, not just a
            // color change.
            let critical = [snapshot.session, snapshot.weekly].compactMap { $0 }.first { $0.percentUsed > 90 }
            if let critical {
                warningLabel.isHidden = false
                warningLabel.stringValue = critical.kind == .weekly
                    ? "Approaching your weekly limit"
                    : "Approaching your session limit"
                warningLabel.textColor = HelmTheme.nsColor(HelmTint.critical.hex(in: theme))
            } else {
                warningLabel.isHidden = true
            }

            let latencyLabel = String(format: "%.1fs", snapshot.latency)
            footerLabel.stringValue = "quota-axi · \(latencyLabel)"
        case .failure(let message):
            latestSnapshot = nil
            statusLabel.isHidden = false
            statusLabel.stringValue = message
            statusLabel.textColor = .systemRed
            rowsStack.isHidden = true
            warningLabel.isHidden = true
            copyButton.isEnabled = false
            footerLabel.stringValue = "quota-axi"
        }
        updateSize()
    }

    private func updateSize() {
        view.layoutSubtreeIfNeeded()
        onSizeChanged?(view.fittingSize)
    }

    /// Re-themes every colored element - registered against a live
    /// `ThemeManager.shared.observe` by `QuotaUsageController` (this file's
    /// header), matching `ConsoleComposerViewController.applyTheme`.
    func applyTheme(_ theme: HelmTheme) {
        self.theme = theme
        let ink = HelmTheme.nsColor(theme.chromeInkHex)
        let muted = HelmTheme.mutedInk(theme)
        let line = HelmTheme.nsColor(theme.chromeLineHex)

        view.layer?.backgroundColor = HelmTheme.nsColor(theme.chromeBackgroundHex).cgColor
        iconTile.applyTheme(theme)
        titleLabel.textColor = ink
        subtitleLabel.textColor = muted
        if statusLabel.textColor != .systemRed {
            statusLabel.textColor = muted
        }
        footerLabel.textColor = muted
        sessionRow.applyTheme(theme)
        weeklyRow.applyTheme(theme)
        if let snapshot = latestSnapshot {
            let critical = [snapshot.session, snapshot.weekly].compactMap { $0 }.first { $0.percentUsed > 90 }
            warningLabel.textColor = critical != nil ? HelmTheme.nsColor(HelmTint.critical.hex(in: theme)) : muted
        }
        for v in view.subviews {
            for sub in v.subviews where sub.frame.height == 1 {
                sub.layer?.backgroundColor = line.cgColor
            }
        }
    }

    @objc private func copyClicked() {
        guard let snapshot = latestSnapshot else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(Self.summary(for: snapshot), forType: .string)
    }

    /// Plain-text usage summary for the Copy Summary button - per this app's
    /// standing Tools-page convention that tool output ships with a Copy
    /// button by default. Not `private` so it's easy to exercise
    /// standalone/from a future test.
    static func summary(for snapshot: QuotaSnapshot) -> String {
        var lines: [String] = ["Claude usage"]
        if let plan = snapshot.plan { lines.append("Plan: \(plan.capitalized)") }
        for (label, window) in [("Session", snapshot.session), ("Weekly", snapshot.weekly)] {
            guard let window else { continue }
            var line = "\(label): \(Int(window.percentUsed.rounded()))% used, pace \(window.pace.label.lowercased())"
            if let resetsAt = window.resetsAt {
                line += ", resets \(resetsAt.formatted(date: .abbreviated, time: .shortened))"
            }
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }
}

/// One window's row: label, percentage, a horizontal bar, the reset time,
/// and a pace chip - all colored via `HelmTint`'s existing `.good`/`.warn`/
/// `.critical` slots per the captain's specified 80%/90% thresholds, never a
/// new literal color.
private final class QuotaWindowRowView: NSView {
    private let titleLabel = NSTextField(labelWithString: "")
    private let percentLabel = NSTextField(labelWithString: "")
    private let barTrack = NSView()
    private let barFill = NSView()
    private var barFillWidthConstraint: NSLayoutConstraint!
    private let resetLabel = NSTextField(labelWithString: "")
    private let paceChip = NSView()
    private let paceChipLabel = NSTextField(labelWithString: "")

    private var currentTint: HelmTint = .good

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        build()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    private func build() {
        titleLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

        percentLabel.font = .monospacedSystemFont(ofSize: 12, weight: .semibold)
        percentLabel.alignment = .right
        percentLabel.translatesAutoresizingMaskIntoConstraints = false
        percentLabel.setContentHuggingPriority(.required, for: .horizontal)

        let topRow = NSStackView(views: [titleLabel, percentLabel])
        topRow.orientation = .horizontal
        topRow.distribution = .fill
        topRow.translatesAutoresizingMaskIntoConstraints = false

        barTrack.wantsLayer = true
        barTrack.layer?.cornerRadius = 3
        barTrack.translatesAutoresizingMaskIntoConstraints = false
        barTrack.heightAnchor.constraint(equalToConstant: 6).isActive = true

        barFill.wantsLayer = true
        barFill.layer?.cornerRadius = 3
        barFill.translatesAutoresizingMaskIntoConstraints = false
        barTrack.addSubview(barFill)
        barFillWidthConstraint = barFill.widthAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            barFill.leadingAnchor.constraint(equalTo: barTrack.leadingAnchor),
            barFill.topAnchor.constraint(equalTo: barTrack.topAnchor),
            barFill.bottomAnchor.constraint(equalTo: barTrack.bottomAnchor),
            barFillWidthConstraint,
        ])

        resetLabel.font = .systemFont(ofSize: 10)
        resetLabel.translatesAutoresizingMaskIntoConstraints = false
        resetLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

        paceChipLabel.font = .systemFont(ofSize: 9.5, weight: .semibold)
        paceChipLabel.translatesAutoresizingMaskIntoConstraints = false
        paceChip.wantsLayer = true
        paceChip.layer?.cornerRadius = 7
        paceChip.translatesAutoresizingMaskIntoConstraints = false
        paceChip.setContentHuggingPriority(.required, for: .horizontal)
        paceChip.addSubview(paceChipLabel)
        NSLayoutConstraint.activate([
            paceChipLabel.leadingAnchor.constraint(equalTo: paceChip.leadingAnchor, constant: 7),
            paceChipLabel.trailingAnchor.constraint(equalTo: paceChip.trailingAnchor, constant: -7),
            paceChipLabel.topAnchor.constraint(equalTo: paceChip.topAnchor, constant: 2),
            paceChipLabel.bottomAnchor.constraint(equalTo: paceChip.bottomAnchor, constant: -2),
        ])

        let bottomRow = NSStackView(views: [resetLabel, paceChip])
        bottomRow.orientation = .horizontal
        bottomRow.distribution = .fill
        bottomRow.alignment = .centerY
        bottomRow.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [topRow, barTrack, bottomRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            topRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            barTrack.widthAnchor.constraint(equalTo: stack.widthAnchor),
            bottomRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
    }

    /// Thresholds exactly as specified in review: `.good` below 80% used,
    /// `.warn` at 80-90%, `.critical` above 90%.
    private static func tint(for percentUsed: Double) -> HelmTint {
        if percentUsed > 90 { return .critical }
        if percentUsed >= 80 { return .warn }
        return .good
    }

    func configure(title: String, window: QuotaWindow?, theme: HelmTheme) {
        titleLabel.stringValue = title
        guard let window else {
            percentLabel.stringValue = "—"
            resetLabel.stringValue = "No data"
            paceChip.isHidden = true
            currentTint = .neutral
            barFillWidthConstraint.constant = 0
            applyTheme(theme)
            return
        }
        let percent = max(0, min(100, window.percentUsed))
        percentLabel.stringValue = "\(Int(percent.rounded()))%"
        if let resetsAt = window.resetsAt {
            resetLabel.stringValue = "Resets \(resetsAt.formatted(date: .abbreviated, time: .shortened))"
        } else {
            resetLabel.stringValue = "Reset time unavailable"
        }
        paceChip.isHidden = false
        paceChipLabel.stringValue = window.pace.label
        currentTint = Self.tint(for: window.percentUsed)
        // 292pt = the row's own available width (320pt popover - 2*14pt
        // stack insets) - the bar fill grows proportionally within it.
        let trackWidth: CGFloat = Self.rowWidth
        barFillWidthConstraint.constant = trackWidth * CGFloat(percent / 100)
        applyTheme(theme)
    }

    static let rowWidth: CGFloat = QuotaUsageViewController.width - 28

    func applyTheme(_ theme: HelmTheme) {
        let ink = HelmTheme.nsColor(theme.chromeInkHex)
        let muted = HelmTheme.mutedInk(theme)
        let line = HelmTheme.nsColor(theme.chromeLineHex)
        titleLabel.textColor = ink
        percentLabel.textColor = ink
        resetLabel.textColor = muted
        barTrack.layer?.backgroundColor = line.withAlphaComponent(0.35).cgColor
        let tintColor = HelmTheme.nsColor(currentTint.hex(in: theme))
        barFill.layer?.backgroundColor = tintColor.cgColor
        paceChip.layer?.backgroundColor = tintColor.withAlphaComponent(0.16).cgColor
        paceChipLabel.textColor = tintColor
    }
}
