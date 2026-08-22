// Manjesh Grand Line - native macOS app.
//
// Resolves a saved `SSHKey` into a file `ssh -i` can use. This is the one
// place secret key material touches disk at all in this app, and only for as
// long as a connection needs it (design report Section C3: "for imported PEM
// files that must live on disk ... 0600 in an app-group container, never in
// config.json"). The Keychain read inside `materialize` is what triggers the
// Touch ID / passcode prompt (`KeychainKeyStore`); everything after that is
// plain file plumbing, torn down by `cleanup` once the tab that owns it closes
// or reconnects (see `ConsoleController`).

import Foundation
import LocalAuthentication

enum SSHKeyMaterializer {

    struct Materialized {
        /// 0600 path to the private key, inside a 0700 scratch directory.
        let privateKeyPath: String
    }

    /// Read `key`'s private key blob out of the Keychain and write it to a
    /// private, 0600 temp file so `ssh -i` has a path to point at.
    ///
    /// **Call this off the main thread** (GL-25): the Keychain read presents
    /// the Touch ID / passcode sheet and blocks until it is answered - see
    /// `KeychainKeyStore.authenticate`, which asserts it. If the key
    /// carries a certificate, it is written alongside as
    /// `<name>-cert.pub` (OpenSSH's own convention for auto-loading a
    /// certificate next to its identity file - no extra `ssh` flags needed).
    static func materialize(key: SSHKey) throws -> Materialized {
        let context = LAContext()
        context.localizedReason = "Unlock \"\(key.label)\" to connect"
        let privateKey = try KeychainKeyStore.loadPrivateKey(id: key.id, context: context)

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fm-cockpit-key-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )

        let keyPath = dir.appendingPathComponent("identity")
        try privateKey.write(to: keyPath, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keyPath.path)

        if let certificate = key.certificate, !certificate.isEmpty {
            let certPath = dir.appendingPathComponent("identity-cert.pub")
            try certificate.write(to: certPath, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: certPath.path)
        }

        return Materialized(privateKeyPath: keyPath.path)
    }

    /// Remove a materialized key's whole scratch directory (the identity file
    /// and, if present, its `-cert.pub`). Best-effort - a leftover 0700 temp
    /// dir under `/tmp` after a crash is the same tradeoff `TmuxMirror` already
    /// accepts for stale `cockpit_*` tmux groups.
    static func cleanup(privateKeyPath: String) {
        let dir = (privateKeyPath as NSString).deletingLastPathComponent
        try? FileManager.default.removeItem(atPath: dir)
    }
}
