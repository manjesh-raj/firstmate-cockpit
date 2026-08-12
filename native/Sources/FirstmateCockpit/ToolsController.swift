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
    case yaml, json, base64, jwt, timestamp, diff

    var title: String {
        switch self {
        case .yaml: return "YAML Validate & Beautify"
        case .json: return "JSON Validate & Beautify"
        case .base64: return "Base64 Encode/Decode"
        case .jwt: return "JWT Decoder"
        case .timestamp: return "Unix Timestamp Converter"
        case .diff: return "Diff"
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
