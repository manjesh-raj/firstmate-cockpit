// Manjesh Grand Line - native macOS app.
//
// `fm/cockpit-block-view-ssh-only`: the global "block view vs. raw
// scrollback" preference, architected exactly like `ThemeManager` - one
// process-wide flag, persisted through `AppSettings.blockViewEnabled`,
// broadcast to every observer (every open `ConsoleController`) so a toggle
// anywhere flips every currently-open terminal tab immediately. This stays a
// single global flag deliberately, even after scope narrowed to SSH-only
// (`TabModel.supportsBlockView`): the flag itself doesn't know or care which
// tabs it applies to, and `ConsoleController.updateTabViewVisibility` already
// gates on `supportsBlockView` per tab, so a global toggle only ever visibly
// affects an SSH host page's tabs regardless of where it's flipped from.
import Foundation

final class BlockViewObservation {}

final class BlockViewManager {
    static let shared = BlockViewManager()

    private(set) var isEnabled: Bool
    private var observers: [(token: BlockViewObservation, fn: (Bool) -> Void)] = []

    private init() {
        isEnabled = AppSettings.shared.blockViewEnabled
    }

    /// Register for changes. Fires once immediately with the current value
    /// (matching `ThemeManager.observe`'s "no separate apply-once step"
    /// contract) so a fresh `ConsoleController` doesn't need to read
    /// `isEnabled` separately before it starts observing.
    @discardableResult
    func observe(_ fn: @escaping (Bool) -> Void) -> BlockViewObservation {
        let token = BlockViewObservation()
        observers.append((token, fn))
        fn(isEnabled)
        return token
    }

    func unobserve(_ token: BlockViewObservation) {
        observers.removeAll { $0.token === token }
    }

    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        AppSettings.shared.blockViewEnabled = enabled
        observers.forEach { $0.fn(enabled) }
    }

    func toggle() {
        setEnabled(!isEnabled)
    }
}
