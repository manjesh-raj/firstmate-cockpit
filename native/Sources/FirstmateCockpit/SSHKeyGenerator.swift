// Manjesh Grand Line - native macOS app.
//
// Key generation and import inspection. Phase 2 (design report Section C3:
// "prefer delegating ... rather than reimplementing crypto" - the same
// principle applies to generating and parsing keys, not just host-key trust).
// Rather than hand-rolling the OpenSSH private-key binary format (and its
// bcrypt-pbkdf passphrase KDF) in Swift, this shells out to the system
// `ssh-keygen`, which already implements both formats correctly. All work
// happens in a private 0700 scratch directory that is deleted immediately
// after the bytes are read into memory, so key material never lingers on disk
// longer than one `ssh-keygen` invocation.

import Foundation

enum SSHKeyOperationError: LocalizedError {
    case toolFailed(String)
    case ppkUnsupported
    case invalidInput(String)

    var errorDescription: String? {
        switch self {
        case .toolFailed(let message):
            return message
        case .ppkUnsupported:
            return "PuTTY (.ppk) keys aren't supported yet. Convert it first, e.g.:\n"
                + "  puttygen key.ppk -O private-openssh -o key.pem"
        case .invalidInput(let message):
            return message
        }
    }
}

enum SSHKeyGenerator {
    private static let sshKeygen = "/usr/bin/ssh-keygen"

    struct Generated {
        let privateKey: Data
        let publicKeyLine: String
        let fingerprint: String
    }

    /// Generate a fresh key of `type` with `ssh-keygen -t`, comment `label`,
    /// and optional `passphrase` (an empty string means "no passphrase" -
    /// `-N` is always passed explicitly so `ssh-keygen` never falls back to an
    /// interactive tty prompt).
    static func generate(type: SSHKeyType, label: String, passphrase: String) throws -> Generated {
        guard type == .ed25519 || type == .rsa else {
            throw SSHKeyOperationError.invalidInput("Only Ed25519 and RSA can be generated here.")
        }
        let dir = try scratchDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let keyPath = dir.appendingPathComponent("key")

        var args = ["-f", keyPath.path, "-C", label, "-N", passphrase, "-q"]
        args = (type == .ed25519 ? ["-t", "ed25519"] : ["-t", "rsa", "-b", "3072"]) + args
        try run(sshKeygen, args)

        let privateKey = try Data(contentsOf: keyPath)
        let pubPath = keyPath.appendingPathExtension("pub")
        let publicKeyLine = try String(contentsOf: pubPath, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let fingerprint = try self.fingerprint(ofPublicKeyFile: pubPath)
        return Generated(privateKey: privateKey, publicKeyLine: publicKeyLine, fingerprint: fingerprint)
    }

    struct Imported {
        let publicKeyLine: String
        let fingerprint: String
        let type: SSHKeyType
    }

    /// Validate an already-formed private key blob (PEM or OpenSSH) and
    /// derive its public key, fingerprint, and type - without a pty. The
    /// passphrase, when the key needs one, is passed via `ssh-keygen -P`,
    /// which OpenSSH provides exactly so callers do not need to answer an
    /// interactive `readpassphrase()` prompt.
    static func inspect(privateKey: Data, passphrase: String) throws -> Imported {
        guard let text = String(data: privateKey, encoding: .utf8) else {
            throw SSHKeyOperationError.invalidInput("That file isn't readable as text.")
        }
        if text.hasPrefix("PuTTY-User-Key-File-") {
            throw SSHKeyOperationError.ppkUnsupported
        }
        guard text.contains("PRIVATE KEY-----") else {
            throw SSHKeyOperationError.invalidInput("Doesn't look like a PEM or OpenSSH private key.")
        }

        let dir = try scratchDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let keyPath = dir.appendingPathComponent("key")
        try privateKey.write(to: keyPath, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keyPath.path)

        var args = ["-y", "-f", keyPath.path]
        if !passphrase.isEmpty { args += ["-P", passphrase] }
        let publicKeyLine = try run(sshKeygen, args).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !publicKeyLine.isEmpty else {
            throw SSHKeyOperationError.invalidInput("Incorrect passphrase, or an unsupported key format.")
        }

        let pubPath = dir.appendingPathComponent("key.pub")
        try publicKeyLine.write(to: pubPath, atomically: true, encoding: .utf8)
        let fingerprint = try self.fingerprint(ofPublicKeyFile: pubPath)
        return Imported(publicKeyLine: publicKeyLine, fingerprint: fingerprint, type: .from(publicKeyLine: publicKeyLine))
    }

    // MARK: Helpers

    private static func scratchDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fm-cockpit-keygen-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )
        return dir
    }

    /// `ssh-keygen -lf` prints `"<bits> <fingerprint> <comment> (<type>)"`.
    /// Only the fingerprint (index 1) is used - the comment may itself contain
    /// spaces, which would shift anything after it, but never what comes before.
    private static func fingerprint(ofPublicKeyFile url: URL) throws -> String {
        let out = try run(sshKeygen, ["-lf", url.path])
        let parts = out.split(separator: " ", maxSplits: 2)
        return parts.count > 1 ? String(parts[1]) : out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @discardableResult
    private static func run(_ executable: String, _ args: [String]) throws -> String {
        // GL-15: `Subprocess` owns the concurrent drain Phase 1 hand-rolled
        // here, plus a bound this call never had. That bound matters more here
        // than almost anywhere else in the app, because this runs on the main
        // thread (GL-04 lists it, and moving it off is Phase 3's GL-25) - so an
        // `ssh-keygen` that never exits used to freeze the whole UI with no
        // recovery short of force-quitting.
        //
        // stdin stays `/dev/null` (the runner's default), which is load-bearing
        // for the same reason as before: with no controlling tty, a `-P`/`-N`
        // that somehow fails to suppress the prompt makes `readpassphrase()`
        // fail fast rather than hang.
        let result = Subprocess.run(executable: executable, arguments: args,
                                    timeout: keygenTimeout, log: AppLog.keychain)
        guard result.ok else {
            if result.timedOut {
                throw SSHKeyOperationError.toolFailed("ssh-keygen did not finish within \(Int(keygenTimeout))s.")
            }
            let trimmed = result.stderr
            throw SSHKeyOperationError.toolFailed(trimmed.isEmpty ? "ssh-keygen failed." : trimmed)
        }
        return String(data: result.stdoutData, encoding: .utf8) ?? ""
    }

    /// Generating an RSA-4096 key is a second or two of real CPU work; this is
    /// far above that and still a bound on a main-thread call.
    private static let keygenTimeout: TimeInterval = 60
}
