// Manjesh Grand Line - native macOS app.
//
// `fm/cockpit-tools-page-multi-session` gives the Tools page the same "many
// independent tabs of the same kind of thing" shape Console already has for
// SSH/Shell tabs (see `TabModel.swift`/`ConsoleController.swift`'s New ⌘T /
// Duplicate ⌘D / Close ⌘W). One `ToolInstance` is one open tab: one tool
// panel (YAML, JSON, Base64, JWT, Timestamp, or Diff) with its own view and
// its own copy of every field the old single-instance `ToolsController` used
// to own directly (inputs, outputs, status, copy-button text). Two open tabs
// of the same kind hold two entirely separate `ToolInstance`s, so editing one
// never touches the other - there is no shared mutable state between them
// beyond the pure, stateless helpers (`YamlBeautify`, `DiffEngine`,
// `JSONSerialization`) every instance already called independently before
// this task.
//
// This is a straight move of `ToolsController`'s phase 1/2 panel-building and
// action-handling code from controller-scoped methods/fields to
// instance-scoped ones - the tool logic itself (YAML/JSON/Base64/JWT/
// timestamp/diff behavior) is unchanged. `ToolsController` now only owns the
// tab strip, the landing-grid picker, and which `ToolInstance`'s view is
// visible.

import AppKit
import Yaml

/// The captured "what's in this tab's input fields right now" used by
/// Duplicate to carry a tab's content into a new one - never its output,
/// which a fresh tab of the same kind can just recompute. `ToolsController`
/// reads this from the source tab and applies it to the freshly created one
/// before that new tab is shown.
enum ToolContentSnapshot {
    case yaml(input: String)
    case json(input: String)
    case base64(input: String)
    case jwt(input: String)
    case timestamp(epochField: String, humanField: String)
    case diff(before: String, after: String, showOnlyDifferences: Bool)
}

/// One open Tools tab. An `NSObject` subclass so its own buttons can target
/// `self` directly (each tab needs its own action targets - a shared
/// controller-wide target/selector would have no way to know which tab's
/// button was actually clicked).
final class ToolInstance: NSObject {
    let id = UUID()
    let kind: ToolKind

    /// The tab-bar chip's display name - defaulted by `ToolsController` (e.g.
    /// "Diff", "Diff 2") and freely renamable via the chip, exactly like a
    /// Console tab's name never touching its underlying process.
    var name: String

    /// The panel view for this tab (the same `panelCard`-wrapped chrome every
    /// tool panel already used) - built once in `init`, never rebuilt.
    /// `private(set)` rather than `let`: the kind-specific builder methods
    /// need `self` fully initialized first (for `@objc` action targets), so
    /// the real view is assigned right after `super.init()`, not in the
    /// member initializer list.
    private(set) var view: NSView

    /// The chip for this tab, created alongside it by `ToolsController`.
    var chip: TabChipView!

    private var theme: HelmTheme

    /// Where `Toast.show` drops its confirmation pill for this tab's Copy
    /// buttons - the shared Tools page view, set once by `ToolsController`.
    weak var toastHost: NSView?

    // Re-themed collections, scoped to this one instance's own view tree -
    // mirrors `ToolsController`'s former page-wide collections, just no
    // longer shared across every open tool.
    private var mutedLabels: [NSTextField] = []
    private var cardBackgroundViews: [NSView] = []
    private var editorScrollViews: [NSScrollView] = []
    private var editorTextViews: [NSTextView] = []
    private var statusLabel: NSTextField!
    private var statusOK: Bool??

    // Per-kind live controls - only the ones for this instance's `kind` are
    // ever populated.
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

    private var yamlCopyButton: NSButton!
    private var jsonCopyButton: NSButton!
    private var base64CopyButton: NSButton!
    private var jwtHeaderCopyButton: NSButton!
    private var jwtPayloadCopyButton: NSButton!
    private var tsHumanCopyButton: NSButton!
    private var tsEpochCopyButton: NSButton!

    private var jwtHeaderCopyText: String?
    private var jwtPayloadCopyText: String?

    init(kind: ToolKind, name: String, theme: HelmTheme, toastHost: NSView?) {
        self.kind = kind
        self.name = name
        self.theme = theme
        self.toastHost = toastHost
        self.view = NSView()
        super.init()
        switch kind {
        case .yaml: view = buildYamlPanel()
        case .json: view = buildJsonPanel()
        case .base64: view = buildBase64Panel()
        case .jwt: view = buildJwtPanel()
        case .timestamp: view = buildTimestampPanel()
        case .diff: view = buildDiffPanel()
        }
        applyTheme(theme)
    }

    // MARK: Content snapshot (Duplicate)

    func snapshotContent() -> ToolContentSnapshot {
        switch kind {
        case .yaml: return .yaml(input: yamlInput.string)
        case .json: return .json(input: jsonInput.string)
        case .base64: return .base64(input: base64Input.string)
        case .jwt: return .jwt(input: jwtInput.string)
        case .timestamp: return .timestamp(epochField: tsEpochField.stringValue, humanField: tsHumanField.stringValue)
        case .diff: return .diff(before: diffBeforeInput.string, after: diffAfterInput.string, showOnlyDifferences: diffShowOnlyDifferences.state == .on)
        }
    }

    /// Applies a snapshot taken from a same-kind tab. `ToolsController` only
    /// ever calls this right after creating a new instance of the same kind
    /// as the source tab, so a mismatched kind can't happen in practice; a
    /// mismatch is ignored rather than crashing, since a duplicate that
    /// silently opens blank is far less surprising than a crash.
    func restoreContent(_ snapshot: ToolContentSnapshot) {
        switch (kind, snapshot) {
        case (.yaml, .yaml(let input)):
            yamlInput.string = input
        case (.json, .json(let input)):
            jsonInput.string = input
        case (.base64, .base64(let input)):
            base64Input.string = input
        case (.jwt, .jwt(let input)):
            jwtInput.string = input
        case (.timestamp, .timestamp(let epoch, let human)):
            tsEpochField.stringValue = epoch
            tsHumanField.stringValue = human
        case (.diff, .diff(let before, let after, let showOnly)):
            diffBeforeInput.string = before
            diffAfterInput.string = after
            diffShowOnlyDifferences.state = showOnly ? .on : .off
            diffResultView.setShowOnlyDifferences(showOnly)
        default:
            break
        }
    }

    // MARK: Panel chrome (mirrors the old ToolsController.panelCard)

    private func panelCard(icon: String, tint: HelmTint, title: String, subtitle: String, content: NSView) -> NSView {
        let tile = IconTileView()
        tile.configure(symbol: icon, tint: tint)
        cardIconTile = tile

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

    private var cardIconTile: IconTileView!

    private func sectionLabel(_ text: String) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.font = .systemFont(ofSize: 11, weight: .semibold)
        mutedLabels.append(l)
        return l
    }

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

    private func setStatus(_ text: String, ok: Bool?) {
        statusOK = ok
        statusLabel?.stringValue = text
        recolorStatus()
    }

    private func recolorStatus() {
        guard let statusLabel else { return }
        switch statusOK ?? nil {
        case .some(true): statusLabel.textColor = HelmTheme.nsColor(theme.ansiHex[2])
        case .some(false): statusLabel.textColor = HelmTheme.nsColor(theme.ansiHex[1])
        case .none: statusLabel.textColor = HelmTheme.mutedInk(theme)
        }
    }

    private func copyButton(action: Selector) -> NSButton {
        let button = NSButton(title: "Copy", target: self, action: action)
        button.bezelStyle = .rounded
        button.isEnabled = false
        return button
    }

    private func refreshCopyButton(_ button: NSButton, text: String?) {
        button.isEnabled = !(text ?? "").isEmpty
    }

    private func copyToClipboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        if let host = toastHost {
            Toast.show(in: host, message: "Copied to clipboard")
        }
    }

    // MARK: YAML

    private func buildYamlPanel() -> NSView {
        let (inputScroll, inputView) = codeEditor(height: 180, readOnly: false)
        yamlInput = inputView
        let (outputScroll, outputView) = codeEditor(height: 180, readOnly: true)
        yamlOutput = outputView

        let sLabel = NSTextField(wrappingLabelWithString: "")
        sLabel.font = .systemFont(ofSize: 11.5, weight: .medium)
        statusLabel = sLabel

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
            note, sectionLabel("Input"), inputScroll, buttonRow, sLabel, outputHeaderRow, outputScroll,
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
            setStatus("Valid YAML - \(docs.count) document\(docs.count == 1 ? "" : "s").", ok: true)
        } catch {
            setStatus("Invalid YAML: \(yamlErrorMessage(error))", ok: false)
        }
    }

    @objc private func yamlBeautifyClicked() {
        let text = yamlInput.string
        do {
            let docs = try Yaml.loadMultiple(text)
            yamlOutput.string = YamlBeautify.dump(docs)
            setStatus("Beautified \(docs.count) document\(docs.count == 1 ? "" : "s").", ok: true)
        } catch {
            yamlOutput.string = ""
            setStatus("Invalid YAML: \(yamlErrorMessage(error))", ok: false)
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

        let sLabel = NSTextField(wrappingLabelWithString: "")
        sLabel.font = .systemFont(ofSize: 11.5, weight: .medium)
        statusLabel = sLabel

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
            sectionLabel("Input"), inputScroll, buttonRow, sLabel, outputHeaderRow, outputScroll,
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
            setStatus("Input isn't valid UTF-8 text.", ok: false)
            return
        }
        do {
            _ = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
            setStatus("Valid JSON.", ok: true)
        } catch {
            setStatus("Invalid JSON: \(error.localizedDescription)", ok: false)
        }
    }

    @objc private func jsonBeautifyClicked() {
        guard let data = jsonInput.string.data(using: .utf8) else {
            setStatus("Input isn't valid UTF-8 text.", ok: false)
            return
        }
        do {
            let obj = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
            let pretty = try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed])
            jsonOutput.string = String(data: pretty, encoding: .utf8) ?? ""
            setStatus("Beautified.", ok: true)
        } catch {
            jsonOutput.string = ""
            setStatus("Invalid JSON: \(error.localizedDescription)", ok: false)
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

        let sLabel = NSTextField(wrappingLabelWithString: "")
        sLabel.font = .systemFont(ofSize: 11.5, weight: .medium)
        statusLabel = sLabel

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
            sectionLabel("Input"), inputScroll, buttonRow, sLabel, outputHeaderRow, outputScroll,
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
        setStatus("Encoded \(data.count) byte\(data.count == 1 ? "" : "s").", ok: true)
        refreshCopyButton(base64CopyButton, text: base64Output.string)
    }

    @objc private func base64DecodeClicked() {
        let trimmed = base64Input.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = Data(base64Encoded: trimmed, options: [.ignoreUnknownCharacters]), !trimmed.isEmpty else {
            base64Output.string = ""
            setStatus("Not valid Base64.", ok: false)
            refreshCopyButton(base64CopyButton, text: base64Output.string)
            return
        }
        if let text = String(data: data, encoding: .utf8) {
            base64Output.string = text
            setStatus("Decoded \(data.count) byte\(data.count == 1 ? "" : "s").", ok: true)
        } else {
            base64Output.string = data.map { String(format: "%02x", $0) }.joined(separator: " ")
            setStatus("Decoded \(data.count) byte\(data.count == 1 ? "" : "s") - not valid UTF-8 text, showing hex.", ok: true)
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

        let sLabel = NSTextField(wrappingLabelWithString: "")
        sLabel.font = .systemFont(ofSize: 11.5, weight: .medium)
        statusLabel = sLabel

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
            note, sectionLabel("Token"), inputScroll, buttonRow, sLabel, sectionLabel("Header / Payload / Claims"), outputScroll,
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
            setStatus("Invalid JWT - expected header.payload.signature, base64url-encoded.", ok: false)
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
            setStatus("Decoded - signature not verified.", ok: true)
        } catch {
            jwtOutput.string = ""
            jwtHeaderCopyText = nil
            jwtPayloadCopyText = nil
            setStatus("Header/payload isn't valid JSON.", ok: false)
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

        let sLabel = NSTextField(wrappingLabelWithString: "")
        sLabel.font = .systemFont(ofSize: 11.5, weight: .medium)
        statusLabel = sLabel

        let humanOutputHeaderRow = NSStackView(views: [sectionLabel("Epoch \u{2192} Human"), tsHumanCopyButton])
        humanOutputHeaderRow.orientation = .horizontal
        humanOutputHeaderRow.spacing = 8

        let content = NSStackView(views: [
            humanOutputHeaderRow, epochRow, humanOutputScroll,
            sectionLabel("Human \u{2192} Epoch"), humanRow, epochOutputRow,
            sLabel,
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
            setStatus("Enter a numeric Unix timestamp, in seconds.", ok: false)
            return
        }
        let date = Date(timeIntervalSince1970: epoch)
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        let df = DateFormatter()
        df.dateStyle = .full
        df.timeStyle = .full
        tsHumanOutput.string = "\(iso.string(from: date))\n\(df.string(from: date))"
        setStatus("Converted.", ok: true)
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
            setStatus("Enter an ISO 8601 date (e.g. 2026-08-12T10:00:00Z) or yyyy-MM-dd HH:mm:ss (UTC).", ok: false)
            return
        }
        tsEpochOutput.stringValue = String(Int(date.timeIntervalSince1970))
        setStatus("Converted.", ok: true)
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

        let sLabel = NSTextField(wrappingLabelWithString: "")
        sLabel.font = .systemFont(ofSize: 11.5, weight: .medium)
        statusLabel = sLabel

        let buttonRow = NSStackView(views: [compareButton, diffShowOnlyDifferences, sLabel])
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
            setStatus("No differences.", ok: true)
        } else {
            setStatus("\(changed) line\(changed == 1 ? "" : "s") differ.", ok: true)
        }
    }

    @objc private func diffShowOnlyDifferencesToggled() {
        diffResultView.setShowOnlyDifferences(diffShowOnlyDifferences.state == .on)
    }

    // MARK: Theme

    func applyTheme(_ theme: HelmTheme) {
        self.theme = theme
        let muted = HelmTheme.mutedInk(theme)
        let line = HelmTheme.nsColor(theme.chromeLineHex)
        let surface = HelmTheme.nsColor(theme.chromeBackgroundHex)
        let bg = HelmTheme.nsColor(theme.backgroundHex)
        let accent = HelmTheme.nsColor(theme.accentHex)

        cardIconTile?.applyTheme(theme)
        for label in mutedLabels { label.textColor = muted }
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
            tv.textColor = HelmTheme.nsColor(theme.chromeInkHex)
            tv.backgroundColor = bg
            tv.insertionPointColor = accent
            tv.selectedTextAttributes = [.backgroundColor: accent.withAlphaComponent(0.3)]
        }
        recolorStatus()
        diffResultView?.applyTheme(theme)
    }
}
