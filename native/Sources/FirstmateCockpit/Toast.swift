// Manjesh Grand Line - native macOS app.
//
// Fix 5 (fixes4): a brief, non-blocking success confirmation. Nothing like
// this existed anywhere in the app before this fix - Save actions (hosts,
// keys) just silently closed with no feedback that anything happened. A
// small pill anchored under the top edge of the given view, styled from the
// active Helm theme, fading in and back out on its own.

import AppKit

enum Toast {
    static func show(in container: NSView, message: String) {
        let theme = ThemeManager.shared.theme

        let glyph = NSTextField(labelWithString: "\u{2713}")
        glyph.font = .systemFont(ofSize: 12, weight: .bold)
        glyph.textColor = HelmTheme.nsColor(theme.ansiHex[2])
        glyph.translatesAutoresizingMaskIntoConstraints = false

        let label = NSTextField(labelWithString: message)
        label.font = .systemFont(ofSize: 12.5, weight: .medium)
        label.textColor = HelmTheme.nsColor(theme.chromeInkHex)
        label.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [glyph, label])
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false

        let pill = NSView()
        pill.wantsLayer = true
        pill.layer?.cornerRadius = 10
        pill.layer?.backgroundColor = HelmTheme.nsColor(theme.chromeBackgroundHex).cgColor
        pill.layer?.borderWidth = 1
        pill.layer?.borderColor = HelmTheme.nsColor(theme.chromeLineHex).withAlphaComponent(0.6).cgColor
        pill.translatesAutoresizingMaskIntoConstraints = false
        pill.alphaValue = 0
        pill.addSubview(stack)

        container.addSubview(pill)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: pill.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: pill.trailingAnchor, constant: -14),
            stack.topAnchor.constraint(equalTo: pill.topAnchor, constant: 9),
            stack.bottomAnchor.constraint(equalTo: pill.bottomAnchor, constant: -9),
            pill.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            pill.topAnchor.constraint(equalTo: container.topAnchor, constant: 20),
        ])

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            pill.animator().alphaValue = 1
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.25
                pill.animator().alphaValue = 0
            }, completionHandler: {
                pill.removeFromSuperview()
            })
        }
    }
}
