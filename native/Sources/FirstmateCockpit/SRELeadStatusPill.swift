// Manjesh Grand Line - native macOS app.
//
// The "SRE Lead" toolbar toggle on a dedicated host page (`ConsoleController`,
// design brief Part C): a small dot + label pill, matching the captain's
// mockup aesthetic more closely than this toolbar's plain SF-Symbol icon
// buttons. Not built on `IconTileView`/`HoverHighlightView`
// (`HelmUIComponents.swift`) since those assume a square icon tile, not a
// dot-plus-label pill - a plain `NSView` + `NSClickGestureRecognizer`, the
// same pattern this codebase already uses for its other clickable-card
// controls (see `AGENTS.md`'s `HelmUIComponents` bullet).

import AppKit

final class SRELeadStatusPill: NSView {
    /// `Equatable` (`fm/grandline-sre-lead-per-tab`): also reused directly as
    /// `SRELeadTabState.phase`'s type, so per-tab cap/gating checks
    /// elsewhere can compare phases with `==` instead of a manual switch.
    enum State: Equatable {
        case notStarted, starting, ready, failed

        var text: String {
            switch self {
            case .notStarted: return "SRE Lead"
            case .starting: return "SRE Lead \u{2014} starting\u{2026}"
            case .ready: return "SRE Lead"
            case .failed: return "SRE Lead \u{2014} failed"
            }
        }
    }

    var onClick: (() -> Void)?
    private(set) var state: State = .notStarted

    private let dot = CALayer()
    private let label = NSTextField(labelWithString: "SRE Lead")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.borderWidth = 1
        toolTip = "Toggle the SRE Lead investigation pane"

        label.font = .systemFont(ofSize: 11, weight: .medium)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        let dotView = NSView()
        dotView.wantsLayer = true
        dotView.layer = dot
        dot.cornerRadius = 3
        dotView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(dotView)

        NSLayoutConstraint.activate([
            dotView.widthAnchor.constraint(equalToConstant: 6),
            dotView.heightAnchor.constraint(equalToConstant: 6),
            dotView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            dotView.centerYAnchor.constraint(equalTo: centerYAnchor),

            label.leadingAnchor.constraint(equalTo: dotView.trailingAnchor, constant: 6),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),

            widthAnchor.constraint(greaterThanOrEqualToConstant: 90),
            heightAnchor.constraint(equalToConstant: 24),
        ])

        addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(clicked)))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func clicked() { onClick?() }

    /// Update the label/dot for `newState`. Doesn't need `theme` itself - the
    /// caller re-runs `applyTheme(_:)` right after any `setState` call (see
    /// `ConsoleController`'s SRE Lead methods), so the dot's actual color is
    /// always resolved there against the live palette.
    func setState(_ newState: State) {
        state = newState
        label.stringValue = newState.text
    }

    /// Re-theme the pill's chrome (border/background/text) and the status
    /// dot's color against `theme` - called from `ConsoleController.applyTheme()`
    /// on every theme change and after every `setState`, since the dot color
    /// depends on both the current state and the active theme's ANSI slots.
    func applyTheme(_ theme: HelmTheme) {
        let ink = HelmTheme.nsColor(theme.chromeInkHex)
        label.textColor = ink
        layer?.backgroundColor = HelmTheme.nsColor(theme.chromeBackgroundHex).cgColor
        layer?.borderColor = HelmTheme.nsColor(theme.chromeLineHex).cgColor
        dot.backgroundColor = dotColor(for: theme).cgColor
    }

    /// ANSI slots 1/2/3 are this palette's red/green/yellow (standard ANSI
    /// ordering, confirmed against `HelmTheme.dark`/`.light`'s own `ansiHex`
    /// comments) - the same error/good/warn convention `DotfilesData`'s
    /// banners already use (see `AGENTS.md`'s dotfiles-pull bullet).
    private func dotColor(for theme: HelmTheme) -> NSColor {
        switch state {
        case .notStarted: return HelmTheme.nsColor(theme.chromeInkHex).withAlphaComponent(0.35)
        case .starting: return HelmTheme.nsColor(theme.ansiHex[3])
        case .ready: return HelmTheme.nsColor(theme.ansiHex[2])
        case .failed: return HelmTheme.nsColor(theme.ansiHex[1])
        }
    }
}
