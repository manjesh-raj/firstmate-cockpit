// Manjesh Grand Line - native macOS app.
//
// Renders a `SRELeadMarkdown.parse(_:)` result (paragraphs, bullet lists,
// fenced code, and the Finding/Recommended-next-action callouts) as a
// vertical stack of real AppKit views. Extracted from `SRELeadChatView`
// (`fm/cockpit-block-view-error-explain`) so the block-view "Explain this"
// action (`BlockView.swift`) can reuse the exact same rendering the SRE Lead
// pane already established, instead of a second copy of it - the visual
// output is byte-for-byte unchanged from what `SRELeadChatView` used to build
// inline; only the "which view builds these blocks" boundary moved.
// `SRELeadChatView.assistantBlock` now just wraps one of these in its own
// message-bubble chrome.

import AppKit

final class SRELeadMarkdownView: NSView {
    private let stack = NSStackView()
    private var theme: HelmTheme

    init(text: String, theme: HelmTheme) {
        self.theme = theme
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        rebuild(text: text)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Re-renders with new text and/or theme - used when a caller needs to
    /// update in place rather than replace the view (e.g. an "Explain this"
    /// panel whose text arrives after the view was already created for a
    /// loading state).
    func configure(text: String, theme: HelmTheme) {
        self.theme = theme
        rebuild(text: text)
    }

    private func rebuild(text: String) {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for block in SRELeadMarkdown.parse(text) {
            let view = renderBlock(block)
            stack.addArrangedSubview(view)
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
    }

    private func renderBlock(_ block: SRELeadMarkdownBlock) -> NSView {
        switch block {
        case .paragraph(let runs):
            return wrappingLabel(attributedInline(runs))
        case .bulletList(let items):
            return bulletListView(items)
        case .codeBlock(let code):
            return codeBlockView(code)
        case .callout(let kind, let runs):
            return calloutView(kind: kind, runs: runs)
        }
    }

    /// A non-editable but selectable, word-wrapping label showing pre-built
    /// attributed text - `NSTextField(wrappingLabelWithString:)` only
    /// accepts a plain `String`, so mixed bold/code runs need this manual
    /// equivalent instead. `isSelectable = true` (with `isEditable` left
    /// false) is what makes click-drag-select + Cmd-C and the right-click
    /// Copy menu work on this text.
    private func wrappingLabel(_ text: NSAttributedString) -> NSTextField {
        let label = NSTextField()
        label.isEditable = false
        label.isSelectable = true
        label.isBordered = false
        label.drawsBackground = false
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 0
        label.attributedStringValue = text
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return label
    }

    /// Renders inline runs into one attributed string: bold text gets a
    /// semibold weight, code spans get a monospace font plus a subtle tinted
    /// background (`theme.chromeLineHex`, the same "line/border" token every
    /// other themed view already uses for subtle chrome - not a new literal
    /// color), everything else the base ink color at the base weight.
    private func attributedInline(_ runs: [SRELeadInlineRun], baseSize: CGFloat = 12.5) -> NSAttributedString {
        let ink = HelmTheme.nsColor(theme.chromeInkHex)
        let codeBackground = HelmTheme.nsColor(theme.chromeLineHex).withAlphaComponent(0.35)
        let result = NSMutableAttributedString()
        for run in runs {
            var attributes: [NSAttributedString.Key: Any] = [.foregroundColor: ink]
            if run.code {
                attributes[.font] = NSFont.monospacedSystemFont(ofSize: baseSize - 1, weight: .regular)
                attributes[.backgroundColor] = codeBackground
            } else if run.bold {
                attributes[.font] = NSFont.systemFont(ofSize: baseSize, weight: .semibold)
            } else {
                attributes[.font] = NSFont.systemFont(ofSize: baseSize)
            }
            result.append(NSAttributedString(string: run.text, attributes: attributes))
        }
        return result
    }

    private func bulletListView(_ items: [[SRELeadInlineRun]]) -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false

        for item in items {
            let bullet = NSTextField(labelWithString: "\u{2022}")
            bullet.font = .systemFont(ofSize: 12.5)
            bullet.textColor = HelmTheme.nsColor(theme.chromeInkHex)
            bullet.translatesAutoresizingMaskIntoConstraints = false
            bullet.setContentHuggingPriority(.required, for: .horizontal)
            bullet.setContentCompressionResistancePriority(.required, for: .horizontal)

            let body = wrappingLabel(attributedInline(item))

            let row = NSStackView(views: [bullet, body])
            row.orientation = .horizontal
            row.alignment = .top
            row.spacing = 6
            row.distribution = .fill
            row.translatesAutoresizingMaskIntoConstraints = false

            stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        return stack
    }

    /// A fenced code block: monospace text on a subtly tinted, rounded
    /// panel - `theme.chromeLineHex` again, at a slightly stronger alpha than
    /// an inline code span since this is the block's whole background, not
    /// a small highlight behind a few characters.
    private func codeBlockView(_ code: String) -> NSView {
        let label = NSTextField(wrappingLabelWithString: code)
        label.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        label.textColor = HelmTheme.nsColor(theme.chromeInkHex)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.lineBreakMode = .byWordWrapping
        label.isSelectable = true

        let panel = NSView()
        panel.wantsLayer = true
        panel.layer?.cornerRadius = 6
        panel.layer?.backgroundColor = HelmTheme.nsColor(theme.chromeLineHex).withAlphaComponent(0.22).cgColor
        panel.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -8),
            label.topAnchor.constraint(equalTo: panel.topAnchor, constant: 6),
            label.bottomAnchor.constraint(equalTo: panel.bottomAnchor, constant: -6),
        ])
        return panel
    }

    /// The Finding/Recommended-next-action blocks' distinct callout styling
    /// (beyond plain bold): a small house-style pill (`ToolRowLayout.pill`,
    /// the same pill every Updates/Bootstrap row status already uses) as the
    /// label, over the body text, on a rounded panel tinted with the same hue
    /// as the pill. Finding gets `.accent` (the app's own "this is the
    /// headline" hue); Recommended next action gets `.good` (green, reads as
    /// "the actionable step") - both resolved against the active theme's own
    /// hues via `HelmTint`, never a literal color.
    private func calloutView(kind: SRELeadCalloutKind, runs: [SRELeadInlineRun]) -> NSView {
        let tint: HelmTint = kind == .finding ? .accent : .good
        let colorHex = tint.hex(in: theme)

        let pill = NSView()
        let pillLabel = NSTextField(labelWithString: "")
        ToolRowLayout.pill(text: kind.label, colorHex: colorHex, into: pill, label: pillLabel)
        pill.setContentHuggingPriority(.required, for: .horizontal)
        pill.setContentCompressionResistancePriority(.required, for: .horizontal)

        let body = wrappingLabel(attributedInline(runs))

        let inner = NSStackView(views: [pill, body])
        inner.orientation = .vertical
        inner.alignment = .leading
        inner.spacing = 6
        inner.translatesAutoresizingMaskIntoConstraints = false
        body.widthAnchor.constraint(equalTo: inner.widthAnchor).isActive = true

        let panel = NSView()
        panel.wantsLayer = true
        panel.layer?.cornerRadius = 8
        panel.layer?.backgroundColor = HelmTheme.nsColor(colorHex).withAlphaComponent(0.12).cgColor
        panel.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(inner)
        NSLayoutConstraint.activate([
            inner.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 10),
            inner.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -10),
            inner.topAnchor.constraint(equalTo: panel.topAnchor, constant: 8),
            inner.bottomAnchor.constraint(equalTo: panel.bottomAnchor, constant: -8),
        ])
        return panel
    }
}
