// Manjesh Grand Line - native macOS app.
//
// "Tools" (cockpit-tools-page-core), phase 1 of 3 of a captain-reviewed
// HTML mockup for everyday DevOps utilities. This phase adds the `.tools`
// rail destination scaffold plus five genuinely functional tools: YAML
// validate/beautify, JSON validate/beautify, Base64 encode/decode, JWT
// decode, and a Unix timestamp converter. A Mergely-style diff tool and a
// certificate inspector/cron explainer/resource-unit converter are
// intentionally deferred to phases 2 and 3 - not built here.
//
// Phase 2 (cockpit-tools-page-diff) adds the sixth tool: a Mergely-style
// side-by-side diff (see the "MARK: Diff" section below, plus
// DiffEngine.swift for the line/word LCS algorithm and DiffResultView.swift
// for the two-column rendering) - not a literal port of the reviewed HTML/
// CSS mockup, but re-derived against this app's own HelmTheme/HelmUIComponents
// conventions so it reads as native chrome, not an embedded web widget.
//
// Phase 3 (cockpit-tools-page-specialist) adds the final three tools from
// the reviewed mockup, closing out the originally-scoped three-phase Tools
// page: a certificate inspector (see "MARK: Certificate" below, plus
// CertInspector.swift, which parses PEM certs with Security.framework's own
// SecCertificateCopyValues rather than a hand-rolled ASN.1 parser), a cron
// next-run explainer (see "MARK: Cron" below, plus CronExplainer.swift), and
// a Kubernetes resource-unit converter (see "MARK: Resource units" below,
// plus ResourceUnits.swift). Multi-session tabs (letting a captain keep
// several independent scratch pads per tool) are a separate, later addition
// to this page, not part of this phase's scope.
//
// The landing view is a wrapping grid of clickable tool cards, the same
// icon-tile + hover-card pattern `SettingsController.rebuildAppearanceGrid`
// already uses for its theme picker. Clicking one hides the grid and shows
// that tool's own panel (built once up front, never rebuilt - the same
// "add every destination view once, toggle isHidden" convention every other
// page in this app already follows), with a "Back to tools" link at top.
// This is the same view-swap idea Bootstrap's stepper and the block-view
// toggle use elsewhere in this app, not a new navigation framework.

import AppKit
import Yaml

private enum ToolKind: String, CaseIterable {
    case yaml, json, base64, jwt, timestamp, diff, cert, cron, resource

    var title: String {
        switch self {
        case .yaml: return "YAML Validate & Beautify"
        case .json: return "JSON Validate & Beautify"
        case .base64: return "Base64 Encode/Decode"
        case .jwt: return "JWT Decoder"
        case .timestamp: return "Unix Timestamp Converter"
        case .diff: return "Diff"
        case .cert: return "Certificate Inspector"
        case .cron: return "Cron Next-Run Explainer"
        case .resource: return "Resource Unit Converter"
        }
    }

    var description: String {
        switch self {
        case .yaml: return "Check a YAML document (or multi-resource manifest) for errors, or reformat it."
        case .json: return "Check a JSON document for errors, or reformat it with consistent indentation."
        case .base64: return "Encode plain text to Base64, or decode a Base64 string back to text."
        case .jwt: return "Inspect a JWT's header and payload claims - no signature verification."
        case .timestamp: return "Convert a Unix epoch to a human-readable date, and back."
        case .diff: return "Compare two blocks of text side by side, with word-level highlighting."
        case .cert: return "Paste a PEM certificate to see its subject, issuer, validity, serial, and SANs."
        case .cron: return "Paste a cron expression to see what it means in plain English and its next run times."
        case .resource: return "Convert CPU millicores/cores and Kubernetes memory quantities between units."
        }
    }

    var symbol: String {
        switch self {
        case .yaml: return "doc.text"
        case .json: return "curlybraces"
        case .base64: return "textformat.abc"
        case .jwt: return "key"
        case .timestamp: return "clock"
        case .diff: return "arrow.left.arrow.right"
        case .cert: return "checkmark.seal"
        case .cron: return "calendar.badge.clock"
        case .resource: return "gauge.with.dots.needle.50percent"
        }
    }

    var tint: HelmTint {
        switch self {
        case .yaml: return .info
        case .json: return .warn
        case .base64: return .good
        case .jwt: return .violet
        case .timestamp: return .accent
        case .diff: return .neutral
        case .cert: return .good
        case .cron: return .info
        case .resource: return .warn
        }
    }
}

final class ToolsController: NSViewController {

    private var theme: HelmTheme = ThemeManager.shared.theme

    private let subtitleLabel = NSTextField(labelWithString: "Everyday DevOps utilities - everything runs locally, nothing leaves this machine.")

    private let gridContainer = NSStackView()
    private let backRow = NSStackView()
    private let backButton = NSButton()

    private var panelViews: [ToolKind: NSView] = [:]
    private var scrollView: NSScrollView!

    // Re-themed collections, mirroring SettingsController's convention.
    private var cardIconTiles: [IconTileView] = []
    private var cardBorderViews: [HoverHighlightView] = []
    private var mutedLabels: [NSTextField] = []
    private var cardBackgroundViews: [NSView] = []
    private var editorScrollViews: [NSScrollView] = []
    private var editorTextViews: [NSTextView] = []
    private var statusLabels: [ToolKind: NSTextField] = [:]
    private var statusOK: [ToolKind: Bool?] = [:]

    // Per-tool live controls.
    private var yamlInput: NSTextView!
    private var yamlOutput: NSTextView!
    private var jsonInput: NSTextView!
    private var jsonOutput: NSTextView!
    private var base64Input: NSTextView!
    private var base64Output: NSTextView!
    private var jwtInput: NSTextView!
    private var jwtOutput: NSTextView!
    private var tsEpochField: NSTextField!
    private var tsHumanOutput: NSTextView!
    private var tsHumanField: NSTextField!
    private var tsEpochOutput: NSTextField!
    private var diffBeforeInput: NSTextView!
    private var diffAfterInput: NSTextView!
    private var diffResultView: DiffResultView!
    private var diffShowOnlyDifferences: NSButton!

    private var certInput: NSTextView!
    private var certOutput: NSTextView!

    private var cronInput: NSTextField!
    private var cronHeadlineLabel: NSTextField!
    private var cronOutput: NSTextView!

    private var cpuMillicoresField: NSTextField!
    private var cpuCoresOutput: NSTextField!
    private var cpuCoresField: NSTextField!
    private var cpuMillicoresOutput: NSTextField!
    private var memoryQuantityField: NSTextField!
    private var memoryOutput: NSTextView!

    // Copy buttons (fm/cockpit-tools-page-copy-buttons) and the text each one
    // currently holds - nil/empty means "nothing valid to copy yet," which is
    // what keeps the button disabled rather than a silent no-op.
    private var yamlCopyButton: NSButton!
    private var jsonCopyButton: NSButton!
    private var base64CopyButton: NSButton!
    private var jwtHeaderCopyButton: NSButton!
    private var jwtPayloadCopyButton: NSButton!
    private var tsHumanCopyButton: NSButton!
    private var tsEpochCopyButton: NSButton!

    private var jwtHeaderCopyText: String?
    private var jwtPayloadCopyText: String?

    private var certCopyButton: NSButton!
    private var cronCopyButton: NSButton!
    private var cpuCoresCopyButton: NSButton!
    private var cpuMillicoresCopyButton: NSButton!
    private var memoryCopyButton: NSButton!

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 720))
        root.wantsLayer = true
        view = root
        ThemeManager.shared.observe { [weak root, weak self] theme in
            root?.appearance = NSAppearance(named: theme.mode == .dark ? .darkAqua : .aqua)
            root?.layer?.backgroundColor = HelmTheme.nsColor(theme.backgroundHex).cgColor
            self?.theme = theme
            self?.applyTheme()
        }

        subtitleLabel.font = .systemFont(ofSize: 12)
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false

        backButton.title = "\u{2190} Back to tools"
        backButton.isBordered = false
        backButton.font = .systemFont(ofSize: 12, weight: .medium)
        backButton.target = self
        backButton.action = #selector(backClicked)
        backRow.addArrangedSubview(backButton)
        backRow.translatesAutoresizingMaskIntoConstraints = false
        backRow.isHidden = true

        gridContainer.orientation = .vertical
        gridContainer.alignment = .leading
        gridContainer.spacing = 10
        gridContainer.translatesAutoresizingMaskIntoConstraints = false
        rebuildGrid()

        var stackViews: [NSView] = [subtitleLabel, backRow, gridContainer]
        for kind in ToolKind.allCases {
            let panel = buildPanel(for: kind)
            panel.isHidden = true
            panelViews[kind] = panel
            stackViews.append(panel)
        }

        let stack = NSStackView(views: stackViews)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        for v in stackViews {
            v.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }

        let content = FlippedView()
        content.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 18),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
        ])

        let scroll = NSScrollView()
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
        scrollView = scroll

        applyTheme()
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        scrollView?.contentView.scroll(to: .zero)
        scrollView?.reflectScrolledClipView(scrollView.contentView)
    }

    // MARK: Grid <-> panel swap

    private func rebuildGrid() {
        for v in gridContainer.arrangedSubviews {
            gridContainer.removeArrangedSubview(v)
            v.removeFromSuperview()
        }
        let columnsPerRow = 3
        for chunk in ToolKind.allCases.chunked(into: columnsPerRow) {
            let row = NSStackView(views: chunk.map { toolCard($0) })
            row.orientation = .horizontal
            row.spacing = 10
            row.translatesAutoresizingMaskIntoConstraints = false
            gridContainer.addArrangedSubview(row)
        }
    }

    private func showGrid() {
        gridContainer.isHidden = false
        backRow.isHidden = true
        for (_, panel) in panelViews { panel.isHidden = true }
    }

    private func showPanel(_ kind: ToolKind) {
        gridContainer.isHidden = true
        backRow.isHidden = false
        for (k, panel) in panelViews { panel.isHidden = k != kind }
    }

    @objc private func backClicked() {
        showGrid()
    }

    @objc private func toolCardClicked(_ sender: NSClickGestureRecognizer) {
        guard let raw = sender.view?.identifier?.rawValue, let kind = ToolKind(rawValue: raw) else { return }
        showPanel(kind)
    }

    // MARK: Landing grid card

    private func toolCard(_ kind: ToolKind) -> NSView {
        let tile = IconTileView()
        tile.configure(symbol: kind.symbol, tint: kind.tint)
        cardIconTiles.append(tile)

        let titleLabel = NSTextField(labelWithString: kind.title)
        titleLabel.font = .systemFont(ofSize: 12.5, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail

        let descLabel = NSTextField(wrappingLabelWithString: kind.description)
        descLabel.font = .systemFont(ofSize: 10.5)
        descLabel.preferredMaxLayoutWidth = 220
        mutedLabels.append(descLabel)

        let textStack = NSStackView(views: [titleLabel, descLabel])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 3
        textStack.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let row = NSStackView(views: [tile, textStack])
        row.orientation = .horizontal
        row.alignment = .top
        row.spacing = 10
        row.translatesAutoresizingMaskIntoConstraints = false

        let card = HoverHighlightView()
        card.cornerRadius = 10
        card.layer?.borderWidth = 1
        card.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 12),
            row.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -12),
            row.topAnchor.constraint(equalTo: card.topAnchor, constant: 12),
            row.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -12),
            card.widthAnchor.constraint(equalToConstant: 268),
        ])
        cardBorderViews.append(card)

        let click = NSClickGestureRecognizer(target: self, action: #selector(toolCardClicked(_:)))
        card.addGestureRecognizer(click)
        card.identifier = NSUserInterfaceItemIdentifier(kind.rawValue)
        return card
    }

    // MARK: Panel chrome (mirrors SettingsController.card)

    private func panelCard(icon: String, tint: HelmTint, title: String, subtitle: String, content: NSView) -> NSView {
        let tile = IconTileView()
        tile.configure(symbol: icon, tint: tint)
        cardIconTiles.append(tile)

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 14, weight: .semibold)

        let subtitleLabel = NSTextField(wrappingLabelWithString: subtitle)
        subtitleLabel.font = .systemFont(ofSize: 11.5)
        subtitleLabel.preferredMaxLayoutWidth = 640
        mutedLabels.append(subtitleLabel)

        let titleStack = NSStackView(views: [titleLabel, subtitleLabel])
        titleStack.orientation = .vertical
        titleStack.alignment = .leading
        titleStack.spacing = 1

        let header = NSStackView(views: [tile, titleStack])
        header.orientation = .horizontal
        header.spacing = 12
        header.alignment = .top

        content.translatesAutoresizingMaskIntoConstraints = false
        let inner = NSStackView(views: [header, content])
        inner.orientation = .vertical
        inner.alignment = .leading
        inner.spacing = 14
        inner.translatesAutoresizingMaskIntoConstraints = false
        content.widthAnchor.constraint(equalTo: inner.widthAnchor).isActive = true

        let background = NSView()
        background.wantsLayer = true
        background.layer?.cornerRadius = 14
        background.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(inner)
        NSLayoutConstraint.activate([
            inner.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 18),
            inner.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -18),
            inner.topAnchor.constraint(equalTo: background.topAnchor, constant: 16),
            inner.bottomAnchor.constraint(equalTo: background.bottomAnchor, constant: -16),
        ])
        cardBackgroundViews.append(background)
        return background
    }

    private func sectionLabel(_ text: String) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.font = .systemFont(ofSize: 11, weight: .semibold)
        mutedLabels.append(l)
        return l
    }

    /// A monospace, theme-tinted `NSTextView` in a bordered `NSScrollView` -
    /// the shared input/output surface every tool's panel uses.
    private func codeEditor(height: CGFloat, readOnly: Bool) -> (NSScrollView, NSTextView) {
        let textView = NSTextView()
        textView.isEditable = !readOnly
        textView.isSelectable = true
        textView.isRichText = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.font = .monospacedSystemFont(ofSize: 11.5, weight: .regular)
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true

        let scroll = NSScrollView()
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        scroll.wantsLayer = true
        scroll.layer?.cornerRadius = 8
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.heightAnchor.constraint(equalToConstant: height).isActive = true

        editorScrollViews.append(scroll)
        editorTextViews.append(textView)
        return (scroll, textView)
    }

    private func setStatus(_ kind: ToolKind, _ text: String, ok: Bool?) {
        statusOK[kind] = ok
        statusLabels[kind]?.stringValue = text
        recolorStatus(kind)
    }

    private func recolorStatus(_ kind: ToolKind) {
        guard let label = statusLabels[kind] else { return }
        switch statusOK[kind] ?? nil {
        case .some(true): label.textColor = HelmTheme.nsColor(theme.ansiHex[2])
        case .some(false): label.textColor = HelmTheme.nsColor(theme.ansiHex[1])
        case .none: label.textColor = HelmTheme.mutedInk(theme)
        }
    }

    /// A small "Copy" button, disabled by default until real output exists.
    private func copyButton(action: Selector) -> NSButton {
        let button = NSButton(title: "Copy", target: self, action: action)
        button.bezelStyle = .rounded
        button.isEnabled = false
        return button
    }

    /// Enables/disables a copy button based on whether `text` is non-empty -
    /// the one place that decides "is there something valid to copy right now."
    private func refreshCopyButton(_ button: NSButton, text: String?) {
        button.isEnabled = !(text ?? "").isEmpty
    }

    private func copyToClipboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        Toast.show(in: view, message: "Copied to clipboard")
    }

    // MARK: Panel dispatch

    private func buildPanel(for kind: ToolKind) -> NSView {
        switch kind {
        case .yaml: return buildYamlPanel()
        case .json: return buildJsonPanel()
        case .base64: return buildBase64Panel()
        case .jwt: return buildJwtPanel()
        case .timestamp: return buildTimestampPanel()
        case .diff: return buildDiffPanel()
        case .cert: return buildCertPanel()
        case .cron: return buildCronPanel()
        case .resource: return buildResourcePanel()
        }
    }

    // MARK: YAML

    private func buildYamlPanel() -> NSView {
        let (inputScroll, inputView) = codeEditor(height: 180, readOnly: false)
        yamlInput = inputView
        let (outputScroll, outputView) = codeEditor(height: 180, readOnly: true)
        yamlOutput = outputView

        let statusLabel = NSTextField(wrappingLabelWithString: "")
        statusLabel.font = .systemFont(ofSize: 11.5, weight: .medium)
        statusLabels[.yaml] = statusLabel

        let note = NSTextField(wrappingLabelWithString: "Beautify sorts map keys alphabetically - the underlying parser doesn't preserve the source document's key order.")
        note.font = .systemFont(ofSize: 10.5)
        note.preferredMaxLayoutWidth = 640
        mutedLabels.append(note)

        let validateButton = NSButton(title: "Validate", target: self, action: #selector(yamlValidateClicked))
        validateButton.bezelStyle = .rounded
        let beautifyButton = NSButton(title: "Beautify", target: self, action: #selector(yamlBeautifyClicked))
        beautifyButton.bezelStyle = .rounded
        let buttonRow = NSStackView(views: [validateButton, beautifyButton])
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 8

        yamlCopyButton = copyButton(action: #selector(yamlCopyClicked))
        let outputHeaderRow = NSStackView(views: [sectionLabel("Output"), yamlCopyButton])
        outputHeaderRow.orientation = .horizontal
        outputHeaderRow.spacing = 8

        let content = NSStackView(views: [
            note, sectionLabel("Input"), inputScroll, buttonRow, statusLabel, outputHeaderRow, outputScroll,
        ])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 8
        for v in [inputScroll, outputScroll] { v.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true }

        return panelCard(
            icon: ToolKind.yaml.symbol, tint: ToolKind.yaml.tint, title: ToolKind.yaml.title,
            subtitle: ToolKind.yaml.description, content: content
        )
    }

    private func yamlErrorMessage(_ error: Error) -> String {
        if case let Yaml.ResultError.message(msg) = error { return msg ?? "Unknown parse error." }
        return "\(error)"
    }

    @objc private func yamlValidateClicked() {
        let text = yamlInput.string
        do {
            let docs = try Yaml.loadMultiple(text)
            setStatus(.yaml, "Valid YAML - \(docs.count) document\(docs.count == 1 ? "" : "s").", ok: true)
        } catch {
            setStatus(.yaml, "Invalid YAML: \(yamlErrorMessage(error))", ok: false)
        }
    }

    @objc private func yamlBeautifyClicked() {
        let text = yamlInput.string
        do {
            let docs = try Yaml.loadMultiple(text)
            yamlOutput.string = YamlBeautify.dump(docs)
            setStatus(.yaml, "Beautified \(docs.count) document\(docs.count == 1 ? "" : "s").", ok: true)
        } catch {
            yamlOutput.string = ""
            setStatus(.yaml, "Invalid YAML: \(yamlErrorMessage(error))", ok: false)
        }
        refreshCopyButton(yamlCopyButton, text: yamlOutput.string)
    }

    @objc private func yamlCopyClicked() {
        guard !yamlOutput.string.isEmpty else { return }
        copyToClipboard(yamlOutput.string)
    }

    // MARK: JSON

    private func buildJsonPanel() -> NSView {
        let (inputScroll, inputView) = codeEditor(height: 180, readOnly: false)
        jsonInput = inputView
        let (outputScroll, outputView) = codeEditor(height: 180, readOnly: true)
        jsonOutput = outputView

        let statusLabel = NSTextField(wrappingLabelWithString: "")
        statusLabel.font = .systemFont(ofSize: 11.5, weight: .medium)
        statusLabels[.json] = statusLabel

        let validateButton = NSButton(title: "Validate", target: self, action: #selector(jsonValidateClicked))
        validateButton.bezelStyle = .rounded
        let beautifyButton = NSButton(title: "Beautify", target: self, action: #selector(jsonBeautifyClicked))
        beautifyButton.bezelStyle = .rounded
        let buttonRow = NSStackView(views: [validateButton, beautifyButton])
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 8

        jsonCopyButton = copyButton(action: #selector(jsonCopyClicked))
        let outputHeaderRow = NSStackView(views: [sectionLabel("Output"), jsonCopyButton])
        outputHeaderRow.orientation = .horizontal
        outputHeaderRow.spacing = 8

        let content = NSStackView(views: [
            sectionLabel("Input"), inputScroll, buttonRow, statusLabel, outputHeaderRow, outputScroll,
        ])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 8
        for v in [inputScroll, outputScroll] { v.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true }

        return panelCard(
            icon: ToolKind.json.symbol, tint: ToolKind.json.tint, title: ToolKind.json.title,
            subtitle: ToolKind.json.description, content: content
        )
    }

    @objc private func jsonValidateClicked() {
        guard let data = jsonInput.string.data(using: .utf8) else {
            setStatus(.json, "Input isn't valid UTF-8 text.", ok: false)
            return
        }
        do {
            _ = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
            setStatus(.json, "Valid JSON.", ok: true)
        } catch {
            setStatus(.json, "Invalid JSON: \(error.localizedDescription)", ok: false)
        }
    }

    @objc private func jsonBeautifyClicked() {
        guard let data = jsonInput.string.data(using: .utf8) else {
            setStatus(.json, "Input isn't valid UTF-8 text.", ok: false)
            return
        }
        do {
            let obj = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
            let pretty = try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed])
            jsonOutput.string = String(data: pretty, encoding: .utf8) ?? ""
            setStatus(.json, "Beautified.", ok: true)
        } catch {
            jsonOutput.string = ""
            setStatus(.json, "Invalid JSON: \(error.localizedDescription)", ok: false)
        }
        refreshCopyButton(jsonCopyButton, text: jsonOutput.string)
    }

    @objc private func jsonCopyClicked() {
        guard !jsonOutput.string.isEmpty else { return }
        copyToClipboard(jsonOutput.string)
    }

    // MARK: Base64

    private func buildBase64Panel() -> NSView {
        let (inputScroll, inputView) = codeEditor(height: 140, readOnly: false)
        base64Input = inputView
        let (outputScroll, outputView) = codeEditor(height: 140, readOnly: true)
        base64Output = outputView

        let statusLabel = NSTextField(wrappingLabelWithString: "")
        statusLabel.font = .systemFont(ofSize: 11.5, weight: .medium)
        statusLabels[.base64] = statusLabel

        let encodeButton = NSButton(title: "Encode", target: self, action: #selector(base64EncodeClicked))
        encodeButton.bezelStyle = .rounded
        let decodeButton = NSButton(title: "Decode", target: self, action: #selector(base64DecodeClicked))
        decodeButton.bezelStyle = .rounded
        let buttonRow = NSStackView(views: [encodeButton, decodeButton])
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 8

        base64CopyButton = copyButton(action: #selector(base64CopyClicked))
        let outputHeaderRow = NSStackView(views: [sectionLabel("Output"), base64CopyButton])
        outputHeaderRow.orientation = .horizontal
        outputHeaderRow.spacing = 8

        let content = NSStackView(views: [
            sectionLabel("Input"), inputScroll, buttonRow, statusLabel, outputHeaderRow, outputScroll,
        ])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 8
        for v in [inputScroll, outputScroll] { v.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true }

        return panelCard(
            icon: ToolKind.base64.symbol, tint: ToolKind.base64.tint, title: ToolKind.base64.title,
            subtitle: ToolKind.base64.description, content: content
        )
    }

    @objc private func base64EncodeClicked() {
        let data = Data(base64Input.string.utf8)
        base64Output.string = data.base64EncodedString()
        setStatus(.base64, "Encoded \(data.count) byte\(data.count == 1 ? "" : "s").", ok: true)
        refreshCopyButton(base64CopyButton, text: base64Output.string)
    }

    @objc private func base64DecodeClicked() {
        let trimmed = base64Input.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = Data(base64Encoded: trimmed, options: [.ignoreUnknownCharacters]), !trimmed.isEmpty else {
            base64Output.string = ""
            setStatus(.base64, "Not valid Base64.", ok: false)
            refreshCopyButton(base64CopyButton, text: base64Output.string)
            return
        }
        if let text = String(data: data, encoding: .utf8) {
            base64Output.string = text
            setStatus(.base64, "Decoded \(data.count) byte\(data.count == 1 ? "" : "s").", ok: true)
        } else {
            base64Output.string = data.map { String(format: "%02x", $0) }.joined(separator: " ")
            setStatus(.base64, "Decoded \(data.count) byte\(data.count == 1 ? "" : "s") - not valid UTF-8 text, showing hex.", ok: true)
        }
        refreshCopyButton(base64CopyButton, text: base64Output.string)
    }

    @objc private func base64CopyClicked() {
        guard !base64Output.string.isEmpty else { return }
        copyToClipboard(base64Output.string)
    }

    // MARK: JWT

    private func buildJwtPanel() -> NSView {
        let (inputScroll, inputView) = codeEditor(height: 90, readOnly: false)
        jwtInput = inputView
        let (outputScroll, outputView) = codeEditor(height: 220, readOnly: true)
        jwtOutput = outputView

        let statusLabel = NSTextField(wrappingLabelWithString: "")
        statusLabel.font = .systemFont(ofSize: 11.5, weight: .medium)
        statusLabels[.jwt] = statusLabel

        let note = NSTextField(wrappingLabelWithString: "This is a local inspector only - the signature is never checked, so a decoded token should never be treated as verified or trusted.")
        note.font = .systemFont(ofSize: 10.5, weight: .medium)
        note.preferredMaxLayoutWidth = 640
        mutedLabels.append(note)

        let decodeButton = NSButton(title: "Decode", target: self, action: #selector(jwtDecodeClicked))
        decodeButton.bezelStyle = .rounded

        jwtHeaderCopyButton = copyButton(action: #selector(jwtCopyHeaderClicked))
        jwtHeaderCopyButton.title = "Copy header"
        jwtPayloadCopyButton = copyButton(action: #selector(jwtCopyPayloadClicked))
        jwtPayloadCopyButton.title = "Copy payload"
        let buttonRow = NSStackView(views: [decodeButton, jwtHeaderCopyButton, jwtPayloadCopyButton])
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 8

        let content = NSStackView(views: [
            note, sectionLabel("Token"), inputScroll, buttonRow, statusLabel, sectionLabel("Header / Payload / Claims"), outputScroll,
        ])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 8
        for v in [inputScroll, outputScroll] { v.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true }

        return panelCard(
            icon: ToolKind.jwt.symbol, tint: ToolKind.jwt.tint, title: ToolKind.jwt.title,
            subtitle: ToolKind.jwt.description, content: content
        )
    }

    private func base64URLDecode(_ s: String) -> Data? {
        var base64 = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        let padding = (4 - base64.count % 4) % 4
        base64 += String(repeating: "=", count: padding)
        return Data(base64Encoded: base64)
    }

    private func prettyJSONString(_ obj: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed]),
              let text = String(data: data, encoding: .utf8) else { return "\(obj)" }
        return text
    }

    private func humanDate(_ epochSeconds: Double) -> String {
        let date = Date(timeIntervalSince1970: epochSeconds)
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        return iso.string(from: date)
    }

    @objc private func jwtDecodeClicked() {
        let token = jwtInput.string.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2,
              let headerData = base64URLDecode(String(parts[0])),
              let payloadData = base64URLDecode(String(parts[1])) else {
            jwtOutput.string = ""
            jwtHeaderCopyText = nil
            jwtPayloadCopyText = nil
            setStatus(.jwt, "Invalid JWT - expected header.payload.signature, base64url-encoded.", ok: false)
            refreshCopyButton(jwtHeaderCopyButton, text: jwtHeaderCopyText)
            refreshCopyButton(jwtPayloadCopyButton, text: jwtPayloadCopyText)
            return
        }
        do {
            let header = try JSONSerialization.jsonObject(with: headerData, options: [.fragmentsAllowed])
            let payload = try JSONSerialization.jsonObject(with: payloadData, options: [.fragmentsAllowed])
            let headerJSON = prettyJSONString(header)
            let payloadJSON = prettyJSONString(payload)

            var out = "Header:\n\(headerJSON)\n\nPayload:\n\(payloadJSON)"
            if let dict = payload as? [String: Any] {
                var claims: [String] = []
                if let sub = dict["sub"] { claims.append("sub: \(sub)") }
                if let iat = dict["iat"] as? NSNumber { claims.append("iat: \(humanDate(iat.doubleValue))") }
                if let exp = dict["exp"] as? NSNumber { claims.append("exp: \(humanDate(exp.doubleValue))") }
                if !claims.isEmpty { out += "\n\nClaims:\n" + claims.joined(separator: "\n") }
            }
            jwtOutput.string = out
            jwtHeaderCopyText = headerJSON
            jwtPayloadCopyText = payloadJSON
            setStatus(.jwt, "Decoded - signature not verified.", ok: true)
        } catch {
            jwtOutput.string = ""
            jwtHeaderCopyText = nil
            jwtPayloadCopyText = nil
            setStatus(.jwt, "Header/payload isn't valid JSON.", ok: false)
        }
        refreshCopyButton(jwtHeaderCopyButton, text: jwtHeaderCopyText)
        refreshCopyButton(jwtPayloadCopyButton, text: jwtPayloadCopyText)
    }

    @objc private func jwtCopyHeaderClicked() {
        guard let text = jwtHeaderCopyText, !text.isEmpty else { return }
        copyToClipboard(text)
    }

    @objc private func jwtCopyPayloadClicked() {
        guard let text = jwtPayloadCopyText, !text.isEmpty else { return }
        copyToClipboard(text)
    }

    // MARK: Timestamp

    private func buildTimestampPanel() -> NSView {
        tsEpochField = NSTextField()
        tsEpochField.placeholderString = "e.g. 1734000000"
        tsEpochField.translatesAutoresizingMaskIntoConstraints = false

        let nowButton = NSButton(title: "Now", target: self, action: #selector(nowClicked))
        nowButton.bezelStyle = .rounded
        let toHumanButton = NSButton(title: "\u{2192} Human", target: self, action: #selector(epochToHumanClicked))
        toHumanButton.bezelStyle = .rounded

        let epochRow = NSStackView(views: [tsEpochField, nowButton, toHumanButton])
        epochRow.orientation = .horizontal
        epochRow.spacing = 8
        tsEpochField.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let (humanOutputScroll, humanOutputView) = codeEditor(height: 70, readOnly: true)
        tsHumanOutput = humanOutputView
        tsHumanCopyButton = copyButton(action: #selector(tsCopyHumanClicked))

        tsHumanField = NSTextField()
        tsHumanField.placeholderString = "e.g. 2026-08-12T10:00:00Z"
        tsHumanField.translatesAutoresizingMaskIntoConstraints = false
        let toEpochButton = NSButton(title: "\u{2192} Epoch", target: self, action: #selector(humanToEpochClicked))
        toEpochButton.bezelStyle = .rounded
        let humanRow = NSStackView(views: [tsHumanField, toEpochButton])
        humanRow.orientation = .horizontal
        humanRow.spacing = 8
        tsHumanField.setContentHuggingPriority(.defaultLow, for: .horizontal)

        tsEpochOutput = NSTextField(labelWithString: "")
        tsEpochOutput.font = .monospacedSystemFont(ofSize: 13, weight: .medium)
        tsEpochOutput.translatesAutoresizingMaskIntoConstraints = false
        tsEpochCopyButton = copyButton(action: #selector(tsCopyEpochClicked))
        let epochOutputRow = NSStackView(views: [tsEpochOutput, tsEpochCopyButton])
        epochOutputRow.orientation = .horizontal
        epochOutputRow.spacing = 8

        let statusLabel = NSTextField(wrappingLabelWithString: "")
        statusLabel.font = .systemFont(ofSize: 11.5, weight: .medium)
        statusLabels[.timestamp] = statusLabel

        let humanOutputHeaderRow = NSStackView(views: [sectionLabel("Epoch \u{2192} Human"), tsHumanCopyButton])
        humanOutputHeaderRow.orientation = .horizontal
        humanOutputHeaderRow.spacing = 8

        let content = NSStackView(views: [
            humanOutputHeaderRow, epochRow, humanOutputScroll,
            sectionLabel("Human \u{2192} Epoch"), humanRow, epochOutputRow,
            statusLabel,
        ])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 8
        for v in [epochRow, humanOutputScroll, humanRow] { v.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true }

        return panelCard(
            icon: ToolKind.timestamp.symbol, tint: ToolKind.timestamp.tint, title: ToolKind.timestamp.title,
            subtitle: ToolKind.timestamp.description, content: content
        )
    }

    @objc private func nowClicked() {
        tsEpochField.stringValue = String(Int(Date().timeIntervalSince1970))
    }

    @objc private func epochToHumanClicked() {
        guard let epoch = Double(tsEpochField.stringValue.trimmingCharacters(in: .whitespaces)) else {
            setStatus(.timestamp, "Enter a numeric Unix timestamp, in seconds.", ok: false)
            return
        }
        let date = Date(timeIntervalSince1970: epoch)
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        let df = DateFormatter()
        df.dateStyle = .full
        df.timeStyle = .full
        tsHumanOutput.string = "\(iso.string(from: date))\n\(df.string(from: date))"
        setStatus(.timestamp, "Converted.", ok: true)
        refreshCopyButton(tsHumanCopyButton, text: tsHumanOutput.string)
    }

    @objc private func tsCopyHumanClicked() {
        guard !tsHumanOutput.string.isEmpty else { return }
        copyToClipboard(tsHumanOutput.string)
    }

    @objc private func humanToEpochClicked() {
        let text = tsHumanField.stringValue.trimmingCharacters(in: .whitespaces)
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        var date = iso.date(from: text)
        if date == nil {
            iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            date = iso.date(from: text)
        }
        if date == nil {
            let df = DateFormatter()
            df.dateFormat = "yyyy-MM-dd HH:mm:ss"
            df.timeZone = TimeZone(identifier: "UTC")
            date = df.date(from: text)
        }
        guard let date else {
            setStatus(.timestamp, "Enter an ISO 8601 date (e.g. 2026-08-12T10:00:00Z) or yyyy-MM-dd HH:mm:ss (UTC).", ok: false)
            return
        }
        tsEpochOutput.stringValue = String(Int(date.timeIntervalSince1970))
        setStatus(.timestamp, "Converted.", ok: true)
        refreshCopyButton(tsEpochCopyButton, text: tsEpochOutput.stringValue)
    }

    @objc private func tsCopyEpochClicked() {
        guard !tsEpochOutput.stringValue.isEmpty else { return }
        copyToClipboard(tsEpochOutput.stringValue)
    }

    // MARK: Diff

    private static let diffBeforeExample = """
    apiVersion: apps/v1
    kind: Deployment
    metadata:
      name: web-app
      labels:
        app: web-app
        tier: frontend
    spec:
      replicas: 2
      selector:
        matchLabels:
          app: web-app
      template:
        metadata:
          labels:
            app: web-app
        spec:
          containers:
            - name: web-app
              image: registry.example.com/web-app:1.4.0
              ports:
                - containerPort: 8080
              env:
                - name: LOG_LEVEL
                  value: "info"
              resources:
                limits:
                  cpu: "500m"
                  memory: "256Mi"
    """

    private static let diffAfterExample = """
    apiVersion: apps/v1
    kind: Deployment
    metadata:
      name: web-app
      labels:
        app: web-app
    spec:
      replicas: 2
      selector:
        matchLabels:
          app: web-app
      template:
        metadata:
          labels:
            app: web-app
        spec:
          containers:
            - name: web-app
              image: registry.example.com/web-app:1.5.0
              ports:
                - containerPort: 8080
              env:
                - name: LOG_LEVEL
                  value: "info"
                - name: APP_ENV
                  value: "production"
              resources:
                limits:
                  cpu: "500m"
                  memory: "256Mi"
    """

    private func buildDiffPanel() -> NSView {
        let (beforeScroll, beforeView) = codeEditor(height: 220, readOnly: false)
        beforeView.string = Self.diffBeforeExample
        diffBeforeInput = beforeView
        let (afterScroll, afterView) = codeEditor(height: 220, readOnly: false)
        afterView.string = Self.diffAfterExample
        diffAfterInput = afterView

        let beforeColumn = NSStackView(views: [sectionLabel("Before"), beforeScroll])
        beforeColumn.orientation = .vertical
        beforeColumn.alignment = .leading
        beforeColumn.spacing = 6
        beforeScroll.widthAnchor.constraint(equalTo: beforeColumn.widthAnchor).isActive = true

        let afterColumn = NSStackView(views: [sectionLabel("After"), afterScroll])
        afterColumn.orientation = .vertical
        afterColumn.alignment = .leading
        afterColumn.spacing = 6
        afterScroll.widthAnchor.constraint(equalTo: afterColumn.widthAnchor).isActive = true

        let inputsRow = NSStackView(views: [beforeColumn, afterColumn])
        inputsRow.orientation = .horizontal
        inputsRow.spacing = 12
        inputsRow.distribution = .fillEqually
        inputsRow.translatesAutoresizingMaskIntoConstraints = false

        let compareButton = NSButton(title: "Compare", target: self, action: #selector(diffCompareClicked))
        compareButton.bezelStyle = .rounded
        compareButton.keyEquivalent = "\r"

        diffShowOnlyDifferences = NSButton(checkboxWithTitle: "Show only differences", target: self, action: #selector(diffShowOnlyDifferencesToggled))

        let statusLabel = NSTextField(wrappingLabelWithString: "")
        statusLabel.font = .systemFont(ofSize: 11.5, weight: .medium)
        statusLabels[.diff] = statusLabel

        let buttonRow = NSStackView(views: [compareButton, diffShowOnlyDifferences, statusLabel])
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 12
        buttonRow.alignment = .centerY

        let result = DiffResultView()
        diffResultView = result

        let resultScroll = NSScrollView()
        resultScroll.documentView = result
        resultScroll.hasVerticalScroller = true
        resultScroll.borderType = .noBorder
        resultScroll.wantsLayer = true
        resultScroll.layer?.cornerRadius = 8
        resultScroll.translatesAutoresizingMaskIntoConstraints = false
        resultScroll.heightAnchor.constraint(equalToConstant: 380).isActive = true
        result.widthAnchor.constraint(equalTo: resultScroll.contentView.widthAnchor).isActive = true
        editorScrollViews.append(resultScroll)

        let content = NSStackView(views: [
            inputsRow, buttonRow, sectionLabel("Comparison"), resultScroll,
        ])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 8
        inputsRow.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        resultScroll.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true

        return panelCard(
            icon: ToolKind.diff.symbol, tint: ToolKind.diff.tint, title: ToolKind.diff.title,
            subtitle: ToolKind.diff.description, content: content
        )
    }

    @objc private func diffCompareClicked() {
        let rows = DiffEngine.lineDiff(before: diffBeforeInput.string, after: diffAfterInput.string)
        diffResultView.setRows(rows)
        let changed = rows.filter { $0.kind != .unchanged }.count
        if changed == 0 {
            setStatus(.diff, "No differences.", ok: true)
        } else {
            setStatus(.diff, "\(changed) line\(changed == 1 ? "" : "s") differ.", ok: true)
        }
    }

    @objc private func diffShowOnlyDifferencesToggled() {
        diffResultView.setShowOnlyDifferences(diffShowOnlyDifferences.state == .on)
    }

    // MARK: Certificate

    private static let certExample = """
    -----BEGIN CERTIFICATE-----
    Paste a PEM certificate here (starts with "-----BEGIN CERTIFICATE-----").
    -----END CERTIFICATE-----
    """

    private func buildCertPanel() -> NSView {
        let (inputScroll, inputView) = codeEditor(height: 160, readOnly: false)
        inputView.string = Self.certExample
        certInput = inputView
        let (outputScroll, outputView) = codeEditor(height: 220, readOnly: true)
        certOutput = outputView

        let statusLabel = NSTextField(wrappingLabelWithString: "")
        statusLabel.font = .systemFont(ofSize: 11.5, weight: .medium)
        statusLabels[.cert] = statusLabel

        let inspectButton = NSButton(title: "Inspect", target: self, action: #selector(certInspectClicked))
        inspectButton.bezelStyle = .rounded

        certCopyButton = copyButton(action: #selector(certCopyClicked))
        let outputHeaderRow = NSStackView(views: [sectionLabel("Details"), certCopyButton])
        outputHeaderRow.orientation = .horizontal
        outputHeaderRow.spacing = 8

        let content = NSStackView(views: [
            sectionLabel("PEM Certificate"), inputScroll, inspectButton, statusLabel, outputHeaderRow, outputScroll,
        ])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 8
        for v in [inputScroll, outputScroll] { v.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true }

        return panelCard(
            icon: ToolKind.cert.symbol, tint: ToolKind.cert.tint, title: ToolKind.cert.title,
            subtitle: ToolKind.cert.description, content: content
        )
    }

    private static let certDateFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH:mm:ss zzz"
        df.timeZone = TimeZone(identifier: "UTC")
        return df
    }()

    @objc private func certInspectClicked() {
        do {
            let info = try CertInspector.parse(pem: certInput.string)
            var lines: [String] = []
            lines.append("Subject:  \(info.subject)")
            lines.append("Issuer:   \(info.issuer)")
            lines.append("Not before: \(Self.certDateFormatter.string(from: info.notBefore))")
            lines.append("Not after:  \(Self.certDateFormatter.string(from: info.notAfter))")
            lines.append("Serial:   \(info.serialHex)")
            lines.append("")
            lines.append("Subject Alternative Names:")
            lines.append(info.sans.isEmpty ? "  (none)" : info.sans.map { "  - \($0)" }.joined(separator: "\n"))
            certOutput.string = lines.joined(separator: "\n")

            if info.isExpired {
                setStatus(.cert, "Certificate is EXPIRED (expired \(Self.certDateFormatter.string(from: info.notAfter))).", ok: false)
            } else if info.isNotYetValid {
                setStatus(.cert, "Certificate is not yet valid (starts \(Self.certDateFormatter.string(from: info.notBefore))).", ok: false)
            } else {
                setStatus(.cert, "Valid certificate structure - not expired.", ok: true)
            }
        } catch {
            certOutput.string = ""
            setStatus(.cert, "Could not parse certificate: \(error)", ok: false)
        }
        refreshCopyButton(certCopyButton, text: certOutput.string)
    }

    @objc private func certCopyClicked() {
        guard !certOutput.string.isEmpty else { return }
        copyToClipboard(certOutput.string)
    }

    // MARK: Cron

    private func buildCronPanel() -> NSView {
        cronInput = NSTextField()
        cronInput.stringValue = "*/15 2 * * 1-5"
        cronInput.placeholderString = "e.g. */15 2 * * 1-5, or a shortcut like @daily"
        cronInput.translatesAutoresizingMaskIntoConstraints = false
        cronInput.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let explainButton = NSButton(title: "Explain", target: self, action: #selector(cronExplainClicked))
        explainButton.bezelStyle = .rounded
        let randomButton = NSButton(title: "Random", target: self, action: #selector(cronRandomClicked))
        randomButton.bezelStyle = .rounded
        let inputRow = NSStackView(views: [cronInput, explainButton, randomButton])
        inputRow.orientation = .horizontal
        inputRow.spacing = 8

        cronHeadlineLabel = NSTextField(wrappingLabelWithString: "")
        cronHeadlineLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        cronHeadlineLabel.preferredMaxLayoutWidth = 640

        let statusLabel = NSTextField(wrappingLabelWithString: "")
        statusLabel.font = .systemFont(ofSize: 11.5, weight: .medium)
        statusLabels[.cron] = statusLabel

        let (outputScroll, outputView) = codeEditor(height: 110, readOnly: true)
        cronOutput = outputView
        cronCopyButton = copyButton(action: #selector(cronCopyClicked))
        let outputHeaderRow = NSStackView(views: [sectionLabel("Next 5 runs"), cronCopyButton])
        outputHeaderRow.orientation = .horizontal
        outputHeaderRow.spacing = 8

        let legend = NSTextField(wrappingLabelWithString:
            "*  any value        ,  a list (1,3,5)        -  a range (1-5)        /  a step (*/15 = every 15)\n"
            + "@yearly / @annually  (0 0 1 1 *)     @monthly  (0 0 1 * *)     @weekly  (0 0 * * 0)\n"
            + "@daily / @midnight  (0 0 * * *)     @hourly  (0 * * * *)     @reboot  - runs at startup, not on a schedule")
        legend.font = .systemFont(ofSize: 10.5)
        legend.preferredMaxLayoutWidth = 640
        mutedLabels.append(legend)

        let content = NSStackView(views: [
            sectionLabel("Cron expression"), inputRow, statusLabel, cronHeadlineLabel,
            outputHeaderRow, outputScroll, sectionLabel("Legend"), legend,
        ])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 8
        for v in [inputRow, outputScroll] { v.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true }

        cronExplain(cronInput.stringValue)

        return panelCard(
            icon: ToolKind.cron.symbol, tint: ToolKind.cron.tint, title: ToolKind.cron.title,
            subtitle: ToolKind.cron.description, content: content
        )
    }

    private static let cronRunDateFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "EEE yyyy-MM-dd HH:mm"
        return df
    }()

    private func cronExplain(_ expression: String) {
        do {
            let cron = try CronExplainer.parse(expression)
            cronHeadlineLabel.stringValue = CronExplainer.headline(cron)
            if cron.isReboot {
                cronOutput.string = ""
                setStatus(.cron, "@reboot has no next-run times.", ok: true)
            } else {
                let runs = CronExplainer.nextRuns(cron, after: Date(), count: 5)
                cronOutput.string = runs.map { Self.cronRunDateFormatter.string(from: $0) }.joined(separator: "\n")
                setStatus(.cron, runs.isEmpty ? "No matching run found in the next 8 years." : "Showing the next \(runs.count) runs.", ok: true)
            }
        } catch {
            cronHeadlineLabel.stringValue = ""
            cronOutput.string = ""
            setStatus(.cron, "Could not parse cron expression: \(error)", ok: false)
        }
        refreshCopyButton(cronCopyButton, text: cronOutput.string)
    }

    @objc private func cronExplainClicked() {
        cronExplain(cronInput.stringValue)
    }

    @objc private func cronRandomClicked() {
        let expr = CronExplainer.randomExpression()
        cronInput.stringValue = expr
        cronExplain(expr)
    }

    @objc private func cronCopyClicked() {
        guard !cronOutput.string.isEmpty else { return }
        copyToClipboard(cronOutput.string)
    }

    // MARK: Resource units

    private func buildResourcePanel() -> NSView {
        cpuMillicoresField = NSTextField()
        cpuMillicoresField.placeholderString = "e.g. 500m"
        cpuMillicoresField.translatesAutoresizingMaskIntoConstraints = false
        cpuMillicoresField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let toCoresButton = NSButton(title: "\u{2192} Cores", target: self, action: #selector(cpuToCoresClicked))
        toCoresButton.bezelStyle = .rounded
        let millicoresRow = NSStackView(views: [cpuMillicoresField, toCoresButton])
        millicoresRow.orientation = .horizontal
        millicoresRow.spacing = 8

        cpuCoresOutput = NSTextField(labelWithString: "")
        cpuCoresOutput.font = .monospacedSystemFont(ofSize: 13, weight: .medium)
        cpuCoresCopyButton = copyButton(action: #selector(cpuCoresCopyClicked))
        let coresOutputRow = NSStackView(views: [sectionLabel("Millicores \u{2192} Cores"), cpuCoresCopyButton])
        coresOutputRow.orientation = .horizontal
        coresOutputRow.spacing = 8
        let coresResultRow = NSStackView(views: [cpuCoresOutput])
        coresResultRow.orientation = .horizontal

        cpuCoresField = NSTextField()
        cpuCoresField.placeholderString = "e.g. 0.5"
        cpuCoresField.translatesAutoresizingMaskIntoConstraints = false
        cpuCoresField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let toMillicoresButton = NSButton(title: "\u{2192} Millicores", target: self, action: #selector(cpuToMillicoresClicked))
        toMillicoresButton.bezelStyle = .rounded
        let coresRow = NSStackView(views: [cpuCoresField, toMillicoresButton])
        coresRow.orientation = .horizontal
        coresRow.spacing = 8

        cpuMillicoresOutput = NSTextField(labelWithString: "")
        cpuMillicoresOutput.font = .monospacedSystemFont(ofSize: 13, weight: .medium)
        cpuMillicoresCopyButton = copyButton(action: #selector(cpuMillicoresCopyClicked))
        let millicoresOutputRow = NSStackView(views: [sectionLabel("Cores \u{2192} Millicores"), cpuMillicoresCopyButton])
        millicoresOutputRow.orientation = .horizontal
        millicoresOutputRow.spacing = 8
        let millicoresResultRow = NSStackView(views: [cpuMillicoresOutput])
        millicoresResultRow.orientation = .horizontal

        let cpuStatusLabel = NSTextField(wrappingLabelWithString: "")
        cpuStatusLabel.font = .systemFont(ofSize: 11.5, weight: .medium)
        statusLabels[.resource] = cpuStatusLabel

        memoryQuantityField = NSTextField()
        memoryQuantityField.placeholderString = "e.g. 256Mi, 1.5Gi, 500M, or a plain byte count"
        memoryQuantityField.translatesAutoresizingMaskIntoConstraints = false
        memoryQuantityField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let convertButton = NSButton(title: "Convert", target: self, action: #selector(memoryConvertClicked))
        convertButton.bezelStyle = .rounded
        let memoryRow = NSStackView(views: [memoryQuantityField, convertButton])
        memoryRow.orientation = .horizontal
        memoryRow.spacing = 8

        let (memoryScroll, memoryView) = codeEditor(height: 110, readOnly: true)
        memoryOutput = memoryView
        memoryCopyButton = copyButton(action: #selector(memoryCopyClicked))
        let memoryOutputHeaderRow = NSStackView(views: [sectionLabel("All units"), memoryCopyButton])
        memoryOutputHeaderRow.orientation = .horizontal
        memoryOutputHeaderRow.spacing = 8

        let content = NSStackView(views: [
            sectionLabel("CPU"),
            millicoresRow, coresOutputRow, coresResultRow,
            coresRow, millicoresOutputRow, millicoresResultRow,
            cpuStatusLabel,
            sectionLabel("Memory"), memoryRow, memoryOutputHeaderRow, memoryScroll,
        ])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 8
        for v in [millicoresRow, coresRow, memoryRow, memoryScroll] { v.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true }

        return panelCard(
            icon: ToolKind.resource.symbol, tint: ToolKind.resource.tint, title: ToolKind.resource.title,
            subtitle: ToolKind.resource.description, content: content
        )
    }

    @objc private func cpuToCoresClicked() {
        guard let millicores = Double(cpuMillicoresField.stringValue.trimmingCharacters(in: .whitespaces)) else {
            setStatus(.resource, "Enter a numeric millicore value, e.g. 500.", ok: false)
            return
        }
        let cores = ResourceUnits.millicoresToCores(millicores)
        cpuCoresOutput.stringValue = "\(ResourceUnits.formatNumber(cores)) cores"
        setStatus(.resource, "Converted.", ok: true)
        refreshCopyButton(cpuCoresCopyButton, text: cpuCoresOutput.stringValue)
    }

    @objc private func cpuToMillicoresClicked() {
        guard let cores = Double(cpuCoresField.stringValue.trimmingCharacters(in: .whitespaces)) else {
            setStatus(.resource, "Enter a numeric core value, e.g. 0.5.", ok: false)
            return
        }
        let millicores = ResourceUnits.coresToMillicores(cores)
        cpuMillicoresOutput.stringValue = "\(ResourceUnits.formatNumber(millicores))m"
        setStatus(.resource, "Converted.", ok: true)
        refreshCopyButton(cpuMillicoresCopyButton, text: cpuMillicoresOutput.stringValue)
    }

    @objc private func cpuCoresCopyClicked() {
        guard !cpuCoresOutput.stringValue.isEmpty else { return }
        copyToClipboard(cpuCoresOutput.stringValue)
    }

    @objc private func cpuMillicoresCopyClicked() {
        guard !cpuMillicoresOutput.stringValue.isEmpty else { return }
        copyToClipboard(cpuMillicoresOutput.stringValue)
    }

    @objc private func memoryConvertClicked() {
        do {
            let bytes = try ResourceUnits.parseMemoryBytes(memoryQuantityField.stringValue)
            let c = ResourceUnits.convertMemory(bytes: bytes)
            let lines = [
                "\(ResourceUnits.formatNumber(c.bytes, decimals: 0)) bytes",
                "\(ResourceUnits.formatNumber(c.ki)) Ki",
                "\(ResourceUnits.formatNumber(c.mi)) Mi",
                "\(ResourceUnits.formatNumber(c.gi)) Gi",
                "\(ResourceUnits.formatNumber(c.kDecimal)) K",
                "\(ResourceUnits.formatNumber(c.mDecimal)) M",
                "\(ResourceUnits.formatNumber(c.gDecimal)) G",
            ]
            memoryOutput.string = lines.joined(separator: "\n")
            setStatus(.resource, "Converted.", ok: true)
        } catch {
            memoryOutput.string = ""
            setStatus(.resource, "Not a valid quantity - use a plain byte count or a suffix like Mi/Gi/M/G.", ok: false)
        }
        refreshCopyButton(memoryCopyButton, text: memoryOutput.string)
    }

    @objc private func memoryCopyClicked() {
        guard !memoryOutput.string.isEmpty else { return }
        copyToClipboard(memoryOutput.string)
    }

    // MARK: Theme

    private func applyTheme() {
        let ink = HelmTheme.nsColor(theme.chromeInkHex)
        let muted = HelmTheme.mutedInk(theme)
        let line = HelmTheme.nsColor(theme.chromeLineHex)
        let surface = HelmTheme.nsColor(theme.chromeBackgroundHex)
        let bg = HelmTheme.nsColor(theme.backgroundHex)
        let accent = HelmTheme.nsColor(theme.accentHex)

        subtitleLabel.textColor = muted
        backButton.contentTintColor = accent

        for tile in cardIconTiles { tile.applyTheme(theme) }
        for label in mutedLabels { label.textColor = muted }
        for card in cardBorderViews {
            card.normalColor = .clear
            card.hoverColor = line.withAlphaComponent(0.18)
            card.layer?.borderColor = line.withAlphaComponent(0.5).cgColor
        }
        for v in cardBackgroundViews {
            v.layer?.backgroundColor = surface.withAlphaComponent(0.6).cgColor
            v.layer?.borderWidth = 1
            v.layer?.borderColor = line.withAlphaComponent(0.5).cgColor
        }
        for scroll in editorScrollViews {
            scroll.layer?.backgroundColor = bg.cgColor
            scroll.layer?.borderWidth = 1
            scroll.layer?.borderColor = line.withAlphaComponent(0.5).cgColor
        }
        for tv in editorTextViews {
            tv.textColor = ink
            tv.backgroundColor = bg
            tv.insertionPointColor = accent
            tv.selectedTextAttributes = [.backgroundColor: accent.withAlphaComponent(0.3)]
        }
        for kind in ToolKind.allCases { recolorStatus(kind) }
        diffResultView?.applyTheme(theme)
    }
}
