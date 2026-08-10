// Firstmate Cockpit - native macOS app.
//
// Data side for Settings' "Touch ID for sudo" row (cockpit-settings-sudo-
// touchid). `av harden sudo` (automic-vault/src/isotopes/hardeners/sudo.rs)
// appends `auth sufficient pam_tid.so` to `/etc/pam.d/sudo_local`, but only
// takes effect if `/etc/pam.d/sudo` already `include`s `sudo_local` - that's
// a real macOS caveat (documented in the hardener's own sudo.md), not
// something to assume true on every Mac, so this file checks both files'
// actual content rather than trusting a cached flag. Mirrors
// `NotSyncedSource`'s plumbing style but needs no `av` invocation for the
// status check itself - `av`'s own `sudo` hardener isn't in its
// `hardeners --json` listing (that command is root-only and file-content
// driven, unlike the account-based hardeners it does list), so this reads
// the PAM files directly, the same way `sudo.rs`'s own `pam_tid_enabled`
// does.

import Foundation

enum SudoTouchIDStatus: Equatable {
    case checking
    case enabled
    case notEnabled
    /// `/etc/pam.d/sudo` doesn't `include` `sudo_local` on this Mac, so
    /// `av harden sudo` would have no effect even if run - the hardener's
    /// own documented caveat.
    case pamNotConfigured
    case checkFailed(String)
}

enum SudoTouchIDSource {

    private static let pamDir = "/etc/pam.d"

    static func checkStatus() -> SudoTouchIDStatus {
        guard let sudoContents = try? String(contentsOfFile: "\(pamDir)/sudo", encoding: .utf8) else {
            return .checkFailed("could not read /etc/pam.d/sudo")
        }
        guard includesSudoLocal(sudoContents) else {
            return .pamNotConfigured
        }
        let sudoLocalContents = try? String(contentsOfFile: "\(pamDir)/sudo_local", encoding: .utf8)
        if enablesPamTid(sudoContents) || enablesPamTid(sudoLocalContents ?? "") {
            return .enabled
        }
        return .notEnabled
    }

    /// Mirrors `sudo.rs`'s `line_enables_pam_tid`: an uncommented `auth` line
    /// naming `pam_tid.so` among its fields.
    private static func enablesPamTid(_ contents: String) -> Bool {
        contents.split(separator: "\n").contains { rawLine in
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.hasPrefix("#") else { return false }
            let fields = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            return fields.first == "auth" && fields.contains("pam_tid.so")
        }
    }

    /// Mirrors the hardener's documented caveat: `/etc/pam.d/sudo` must
    /// `include` `sudo_local` for the appended line to ever take effect.
    private static func includesSudoLocal(_ contents: String) -> Bool {
        contents.split(separator: "\n").contains { rawLine in
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.hasPrefix("#") else { return false }
            let fields = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            return fields.first == "auth" && fields.contains("include") && fields.last == "sudo_local"
        }
    }
}
