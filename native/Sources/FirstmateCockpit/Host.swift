// Manjesh Grand Line - native macOS app.
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
//
// Phase 3 (design report Section B1/B4/B5, Section D Phase 3) adds the
// "power features" that make this usable against real infra, all as extra
// non-secret fields plus extra `ssh` argv - never new transport code:
// agent forwarding (`-A`), a jump-host chain (`-J`, `jumpVia`), local/remote/
// dynamic port-forwarding rules, and an optional startup snippet. `group` and
// `tags` (B4) already existed as unused fields; Phase 3 is what wires them
// into the sidebar.

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

    /// Organisation (B4): a free-form folder name the sidebar groups hosts
    /// under. `nil`/empty hosts land in the "Ungrouped" section.
    var group: String?
    /// Free-form filter labels (B4), searchable from quick-connect and
    /// selectable as chips in the sidebar.
    var tags: [String] = []

    /// Agent forwarding (B1): adds `-A` to the `ssh` invocation so the
    /// *system* agent's keys (via the inherited `SSH_AUTH_SOCK`, see
    /// `childEnvironmentDict`) are usable on the remote host without ever
    /// putting them in this app's own Keychain store.
    var agentForward: Bool = false

    /// Jump host / ProxyJump (B1): either another saved host's `label`, or a
    /// raw `user@bastion[:port]`. Resolved - and, if that host itself has a
    /// `jumpVia`, chained - into a `-J a,b,c` argument by
    /// `HostCatalog.proxyJumpChain`, which needs the full host list, so it is
    /// resolved outside this value type at connect time.
    var jumpVia: String?

    /// Local/remote/dynamic port-forwarding rules (B1), turned into `-L`/`-R`/
    /// `-D` flags by `PortForwardRule.sshArguments`.
    var portForwards: [PortForwardRule] = []

    /// Optional saved snippet (B2/B5) auto-run once this host's session looks
    /// ready. Resolved through `SnippetStore` by `ConsoleController` - a host
    /// only ever carries the id, never the command text.
    var startupSnippetID: UUID?

    /// A typed-in password. **Session-only** - excluded from `CodingKeys`, so it
    /// is never written to disk (Phase 2 owns secure secret storage). Plain
    /// `ssh` prompts for it interactively on the PTY regardless.
    var password: String?

    /// Everything persisted - note `password` is intentionally absent.
    private enum CodingKeys: String, CodingKey {
        case id, label, address, port, username, keyID, iconSymbol, accentHex, group, tags,
             agentForward, jumpVia, portForwards, startupSnippetID
    }

    /// The full `ssh` argument vector for this host, minus any identity file
    /// (added separately by `ConsoleController` once a saved key is
    /// materialized - that needs a live Keychain read, which does not belong
    /// in a value type). Order: agent forwarding, the resolved jump chain,
    /// port-forwarding rules, an optional non-default port, then the
    /// `[user@]address` destination last. `ssh` owns the transport and
    /// interactive auth throughout (design report C1) - this method only ever
    /// appends flags, never re-implements what they do.
    ///
    /// - Parameter allHosts: the full saved-host list, needed to resolve
    ///   `jumpVia` when it names another saved host rather than a raw
    ///   `user@bastion`. Pass `[]` for an ad-hoc host with no jump chain.
    func sshArguments(allHosts: [Host] = []) -> [String] {
        var args: [String] = []
        if agentForward { args.append("-A") }
        let chain = HostCatalog.proxyJumpChain(for: self, hosts: allHosts)
        if !chain.isEmpty { args += ["-J", chain.joined(separator: ",")] }
        for rule in portForwards { args += rule.sshArguments }
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

/// A single port-forwarding rule (B1): Local (`-L`), Remote (`-R`), or
/// Dynamic/SOCKS (`-D`). `Codable` and persisted as part of `Host.portForwards`
/// - none of this is secret, it is just `ssh` argv shaped as data so the
/// editor can list/add/remove rules.
struct PortForwardRule: Codable, Identifiable, Equatable {
    enum Kind: String, Codable, CaseIterable {
        case local, remote, dynamic

        var displayName: String {
            switch self {
            case .local: return "Local"
            case .remote: return "Remote"
            case .dynamic: return "Dynamic (SOCKS)"
            }
        }
    }

    var id = UUID()
    var kind: Kind = .local

    /// Optional bind address, e.g. `127.0.0.1` or `*`. Empty means `ssh`'s
    /// own default bind for the flag in question.
    var bindAddress: String = ""
    var listenPort: Int = 8080
    /// Unused for `.dynamic` - a SOCKS proxy has no destination, only a
    /// listening port.
    var destHost: String = ""
    var destPort: Int = 80

    private var listenSpec: String {
        bindAddress.isEmpty ? String(listenPort) : "\(bindAddress):\(listenPort)"
    }

    /// The `ssh` flag(s) for this rule, e.g. `["-L", "8080:localhost:80"]`.
    var sshArguments: [String] {
        switch kind {
        case .local: return ["-L", "\(listenSpec):\(destHost):\(destPort)"]
        case .remote: return ["-R", "\(listenSpec):\(destHost):\(destPort)"]
        case .dynamic: return ["-D", listenSpec]
        }
    }

    /// A short human-readable summary for list rows, e.g. `"L 8080 -> localhost:80"`.
    var summary: String {
        switch kind {
        case .local: return "L \(listenSpec) \u{2192} \(destHost):\(destPort)"
        case .remote: return "R \(listenSpec) \u{2192} \(destHost):\(destPort)"
        case .dynamic: return "D \(listenSpec) (SOCKS)"
        }
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
    /// `ssh deploy@10.0.0.4:2222` or `db.internal`. An IPv6 literal needs
    /// bracket notation to pair with an explicit port - `[::1]:2222` - the
    /// same convention URLs/`scp` use; a bare, unbracketed IPv6 literal
    /// (`::1`, `2001:db8::1`) is treated as the whole host with the default
    /// port, never mis-split on its last colon. Returns `nil` when there is
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

        var host: String
        var port = 22

        if rest.hasPrefix("[") {
            // Bracketed IPv6 literal: `[<addr>]` or `[<addr>]:<port>`.
            guard let close = rest.firstIndex(of: "]") else { return nil }
            host = String(rest[rest.index(after: rest.startIndex)..<close])
            guard !host.isEmpty else { return nil }
            let afterBracket = rest[rest.index(after: close)...]
            if afterBracket.isEmpty {
                // No port suffix - default port, bracket-only form.
            } else if afterBracket.hasPrefix(":") {
                let portStr = String(afterBracket.dropFirst())
                guard let p = Int(portStr), p > 0, p <= 65_535 else { return nil }
                port = p
            } else {
                // Trailing garbage after `]` that isn't `:port` - malformed.
                return nil
            }
        } else if rest.filter({ $0 == ":" }).count > 1 {
            // More than one colon with no brackets: a bare IPv6 literal, not
            // a `host:port` pair - splitting on the last colon would corrupt
            // it (e.g. "::1" -> host ":", port 1). Treat the whole thing as
            // the host, default port; use bracket notation for an explicit
            // port on a literal.
            host = rest
        } else if let colon = rest.lastIndex(of: ":") {
            let portStr = String(rest[rest.index(after: colon)...])
            host = String(rest[..<colon])
            if let p = Int(portStr), p > 0, p <= 65_535 {
                port = p
            }
            // else: non-numeric/empty port suffix (e.g. "myhost:") - fall
            // through with the colon already stripped from `host` above and
            // the default port, rather than leaving a stray trailing colon
            // attached to the destination `ssh` receives.
        } else {
            host = rest
        }
        guard !host.isEmpty else { return nil }

        let dest = user.isEmpty ? host : "\(user)@\(host)"
        var args: [String] = []
        if port != 22 { args += ["-p", String(port)] }
        args.append(dest)
        return (dest, args)
    }

    /// Resolve `host.jumpVia` into an ordered `-J` chain (B1: "Support
    /// chaining if the jump host itself has a jump host"). Each hop is either
    /// a saved host's `destination` (looked up by label, case-insensitively,
    /// then followed through *its* `jumpVia`) or, once a hop fails to match
    /// any saved host, taken verbatim as a raw `user@bastion[:port]` and the
    /// chain stops there (a raw hop has no further `jumpVia` to follow).
    /// A hop count cap guards against a label cycle (e.g. two hosts pointing
    /// at each other) turning into an infinite loop.
    static func proxyJumpChain(for host: Host, hosts: [Host]) -> [String] {
        var chain: [String] = []
        var next = host.jumpVia
        var hops = 0
        while let via = next?.trimmingCharacters(in: .whitespacesAndNewlines), !via.isEmpty, hops < 8 {
            hops += 1
            if let match = hosts.first(where: { $0.label.caseInsensitiveCompare(via) == .orderedSame }) {
                chain.append(match.destination)
                next = match.jumpVia
            } else {
                chain.append(via)
                next = nil
            }
        }
        return chain
    }
}
