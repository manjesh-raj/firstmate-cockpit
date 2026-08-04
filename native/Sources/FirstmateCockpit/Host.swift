// Firstmate Cockpit - native macOS app.
//
// The SSH **host** model. Phase 1 of the connection-manager work (design report
// `data/cockpit-ssh-manager-research/report.md`, Section A2/A3 + Section D
// Phase 1): a saved SSH profile the captain can connect to. Persistence lives in
// `HostStore`; this file is just the value type, the icon/colour catalogue, and
// the `ssh` argv builder.
//
// Phase 2 replaces the Phase 1 "on-disk key path" credential with a real
// saved-key reference (`keyID`, into `SSHKeyStore` / `KeychainKeyStore`) - the
// only thing persisted here is a `UUID`, never key material. With no key
// chosen, `ssh` falls back to the system agent / `known_hosts` and prompts
// interactively on the PTY, same as Phase 1. A typed-in `password` is held in
// memory for the session and is deliberately excluded from `Codable`.

import Foundation

/// A saved SSH host. `Codable` for JSON persistence, but `password` is left out
/// of the coding keys so it never touches disk (see `CodingKeys`).
struct Host: Codable, Identifiable, Equatable {
    var id = UUID()

    /// Display name, e.g. "Prod bastion". Also the default tab name on connect.
    var label: String
    /// Hostname or IP the `ssh` destination resolves to.
    var address: String
    /// TCP port. `ssh` defaults to 22; only passed via `-p` when it differs.
    var port: Int = 22
    /// Login user. When empty, `ssh` uses the current local user.
    var username: String = ""

    /// Optional reference to a saved key in `SSHKeyStore` (Phase 2). The
    /// key's secret material is resolved through `SSHKeyMaterializer` at
    /// connect time - a host never carries anything more sensitive than this id.
    var keyID: UUID?

    /// SF Symbol name for this host's row/tab icon (A3). Defaults sensibly.
    var iconSymbol: String = HostCatalog.defaultIcon
    /// sRGB hex (no `#`) for this host's accent (A3). Tints the row icon and the
    /// connected tab's chip.
    var accentHex: String = HostCatalog.defaultAccent

    /// Optional organisation, kept for later phases (groups/tags, Section B4).
    var group: String?
    var tags: [String] = []

    /// A typed-in password. **Session-only** - excluded from `CodingKeys`, so it
    /// is never written to disk (Phase 2 owns secure secret storage). Plain
    /// `ssh` prompts for it interactively on the PTY regardless.
    var password: String?

    /// Everything persisted - note `password` is intentionally absent.
    private enum CodingKeys: String, CodingKey {
        case id, label, address, port, username, keyID, iconSymbol, accentHex, group, tags
    }

    /// The `ssh` argument vector for this host, minus any identity file: an
    /// optional non-default port, then the `[user@]address` destination.
    /// `ssh` owns the transport and interactive auth (design report C1). The
    /// `-i <path>` for `keyID`, if set, is prepended separately by
    /// `ConsoleController` once the key is materialized (it needs a live
    /// Keychain read, which does not belong in a value type).
    func sshArguments() -> [String] {
        var args: [String] = []
        if port != 22 { args += ["-p", String(port)] }
        args.append(destination)
        return args
    }

    /// `[user@]address`, the last `ssh` positional argument.
    var destination: String {
        let user = username.trimmingCharacters(in: .whitespaces)
        let host = address.trimmingCharacters(in: .whitespaces)
        return user.isEmpty ? host : "\(user)@\(host)"
    }

    /// A short one-line subtitle for the host row: `user@address[:port]`.
    var subtitle: String {
        var s = destination
        if port != 22 { s += ":\(port)" }
        return s
    }
}

/// Static bits shared across the host UI: the `ssh` binary, the icon palette, and
/// the accent palette. The icons are SF Symbols (already used for the toolbar
/// buttons) and the accents are drawn from the Helm palette so a host harmonises
/// with the rest of the cockpit.
enum HostCatalog {
    /// The system `ssh`. A genuine local PTY child (design report C1), so it
    /// slots into `startProcess` exactly like the login shell and tmux do.
    static let sshExecutable = "/usr/bin/ssh"

    /// The user-selectable host icons (A3). Distinct, recognisable infra shapes.
    static let icons = [
        "server.rack", "desktopcomputer", "laptopcomputer", "cloud.fill",
        "network", "cpu", "externaldrive.fill", "shippingbox.fill",
        "bolt.horizontal.circle.fill", "terminal.fill", "cube.fill", "leaf.fill",
    ]
    static let defaultIcon = "server.rack"

    /// The user-selectable host accents (A3), as sRGB hex. Pulled from the Helm
    /// dark ANSI set so every choice already meets the cockpit's palette.
    static let accents = [
        "6cd7e3", "7fe998", "ffd972", "ff8179",
        "e9a1e3", "7dc7f7", "f2bf4e", "96e8ef",
    ]
    static let defaultAccent = "6cd7e3"

    /// Parse a quick-connect string into a tab label + `ssh` argv. Accepts an
    /// optional leading `ssh ` and the classic `[user@]host[:port]` form, e.g.
    /// `ssh deploy@10.0.0.4:2222` or `db.internal`. Returns `nil` when there is
    /// no host to connect to.
    static func parseQuickConnect(_ raw: String) -> (label: String, args: [String])? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.lowercased().hasPrefix("ssh ") {
            s = String(s.dropFirst(4)).trimmingCharacters(in: .whitespaces)
        }
        guard !s.isEmpty else { return nil }

        var user = ""
        var rest = s
        if let at = s.firstIndex(of: "@") {
            user = String(s[..<at])
            rest = String(s[s.index(after: at)...])
        }
        guard !rest.isEmpty else { return nil }

        var host = rest
        var port = 22
        if let colon = rest.lastIndex(of: ":") {
            let portStr = String(rest[rest.index(after: colon)...])
            if let p = Int(portStr), p > 0, p <= 65_535 {
                host = String(rest[..<colon])
                port = p
            }
        }
        guard !host.isEmpty else { return nil }

        let dest = user.isEmpty ? host : "\(user)@\(host)"
        var args: [String] = []
        if port != 22 { args += ["-p", String(port)] }
        args.append(dest)
        return (dest, args)
    }
}
