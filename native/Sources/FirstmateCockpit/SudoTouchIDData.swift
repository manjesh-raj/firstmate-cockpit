// Manjesh Grand Line - native macOS app.
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
//
// cockpit-settings-sudo-nixdarwin: on a nix-darwin-managed Mac,
// `/etc/pam.d/sudo_local` is a symlink chain into the immutable Nix store
// (`/etc/pam.d/sudo_local` -> `/etc/static/pam.d/sudo_local` ->
// `/nix/store/.../etc-sudo_local`). `av harden sudo` refuses to write
// through a symlink (a correct guard against symlink attacks on root-owned
// PAM files) and fails with ELOOP there, and even bypassing that would be
// pointless: the file is regenerated from the flake on every rebuild, so a
// manual edit is wiped on the next `rebuild.sh` anyway. The real fix on
// that class of machine is nix-darwin's own declarative
// `security.pam.services.sudo_local.touchIdAuth = true;` option in
// `configuration.nix`, not `av harden sudo` - see `.notEnabledNixDarwin`
// below and its guidance text in `SettingsController.sudoTouchIDRow()`.
// Reading the file's *content* for `pam_tid.so` is unaffected either way,
// since reading through a symlink is transparently fine - only writing
// through one is what `av harden sudo` refuses to do.

import Foundation

enum SudoTouchIDStatus: Equatable {
    case checking
    case enabled
    case notEnabled
    /// Not enabled, and `/etc/pam.d/sudo_local` resolves into `/nix/store/` -
    /// this Mac is managed by nix-darwin, so `av harden sudo` would fail
    /// with ELOOP (it refuses to write through a symlink) even if run, and
    /// any manual edit would be wiped on the next `rebuild.sh` regardless.
    case notEnabledNixDarwin
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
        return isManagedByNixDarwin() ? .notEnabledNixDarwin : .notEnabled
    }

    /// Resolves `/etc/pam.d/sudo_local`'s real path (following the full
    /// symlink chain, not just the first hop) and checks whether it lands
    /// in `/nix/store/` - nix-darwin's tell, since it regenerates that file
    /// from the evaluated flake config on every rebuild.
    private static func isManagedByNixDarwin() -> Bool {
        let resolved = (("\(pamDir)/sudo_local") as NSString).resolvingSymlinksInPath
        return resolved.hasPrefix("/nix/store/")
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
