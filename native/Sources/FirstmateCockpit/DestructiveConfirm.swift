// Manjesh Grand Line - native macOS app.
//
// GL-06: the one confirmation prompt for an irreversible delete.
//
// The bug this closes: the row-level `⋯` menus in `HostsController` correctly
// confirmed before deleting a host, an SSH key or a snippet - the key one's
// copy even warned that the Keychain private key and passphrase go with it -
// but each editor *sheet's* own Delete button called the same store method
// straight through with no prompt at all. For a key that is unrecoverable
// private-key loss one misclick away, since key material lives only in the
// Keychain and is deliberately excluded from `.glbackup` exports.
//
// This exists as a shared function rather than being fixed three times because
// the third caller lives in `main.swift` (the host editor is a window owned by
// the app delegate, not by `HostsController`), so there was no existing
// `private func confirm` for it to reach.

import AppKit

enum DestructiveConfirm {

    /// A modal, two-button "are you sure" with the destructive action as the
    /// *second* button, so Return means Cancel and Escape means Cancel. Both
    /// safe keys do the safe thing - the point of a confirmation is that a
    /// reflexive keypress cannot complete the deletion.
    ///
    /// - Parameters:
    ///   - message: the headline, e.g. `Delete "Prod Bastion"?`.
    ///   - detail: what is actually lost. Say it plainly - this is the last
    ///     thing standing between a click and unrecoverable data.
    ///   - confirmTitle: the destructive button's title (default "Delete").
    ///   - window: present as a sheet on this window when given; app-modal
    ///     otherwise. An editor sheet that is about to close should pass `nil`
    ///     and let this run app-modally.
    /// - Returns: `true` only if the captain explicitly chose the destructive
    ///   button.
    @discardableResult
    static func confirm(message: String,
                        detail: String,
                        confirmTitle: String = "Delete",
                        window: NSWindow? = nil) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = message
        alert.informativeText = detail
        alert.addButton(withTitle: "Cancel")
        let destructive = alert.addButton(withTitle: confirmTitle)
        if #available(macOS 11.0, *) { destructive.hasDestructiveAction = true }
        return alert.runModal() == .alertSecondButtonReturn
    }
}
